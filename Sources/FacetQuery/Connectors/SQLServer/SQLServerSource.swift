import Foundation
import FacetCore

/// One SQL Server database as M sees it: the address, how to sign in, timeouts, and a pooled way to run T-SQL.
final class SQLServerDatabase: @unchecked Sendable {
    let server: String
    let database: String
    let address: TDSServerAddress
    var commandTimeout: TimeInterval? = 600
    var connectTimeout: TimeInterval = 15
    var strictEncryption = false
    var trustServerCertificate = false
    var maxResultBytes = 4 << 30
    /// Who signs in, for pooling (never the secret itself).
    let identity: String
    private let authenticate: () throws -> TDSAuthentication

    init(server: String, database: String, address: TDSServerAddress, identity: String, authenticate: @escaping () throws -> TDSAuthentication) {
        self.server = server; self.database = database; self.address = address; self.identity = identity; self.authenticate = authenticate
    }

    /// Data source location, as Power BI writes it: `server;database`.
    var location: String { database.isEmpty ? server : server + ";" + database }

    /// The same server, database and sign-in (a join can fold only within one database).
    func isSameSource(as other: SQLServerDatabase) -> Bool {
        poolKey == other.poolKey
    }
    private var poolKey: String {
        [address.host.lowercased(), String(address.port ?? 0), address.instance ?? "", database.lowercased(), identity,
         strictEncryption ? "strict" : "", trustServerCertificate ? "trust" : ""].joined(separator: "|")
    }

    /// Run T-SQL and return the whole response. Errors become `DataSource.Error`s prefixed "Microsoft SQL:".
    func run(_ sql: String, parameters: [TDSParameter] = []) throws -> TDSResponse {
        do {
            return try TDSConnectionPool.shared.with(key: poolKey, open: {
                var o = TDSConnectOptions(address: address, database: database, authentication: try authenticate())
                o.trustServerCertificate = trustServerCertificate
                o.strictEncryption = strictEncryption
                o.connectTimeout = connectTimeout
                o.maxResultBytes = maxResultBytes
                return try TDSConnection.open(o)
            }) { try $0.execute(sql, parameters: parameters, timeout: commandTimeout) }
        } catch let e as TDSError {
            throw MError.dataSource("Microsoft SQL: " + e.message)
        }
    }

    /// The first result set (an empty table when the statement returns none).
    func resultSet(_ sql: String, parameters: [TDSParameter] = []) throws -> TDSResultSet {
        try run(sql, parameters: parameters).resultSets.first ?? TDSResultSet(columns: [], values: [])
    }

    /// Column names and M types of a query, without reading rows.
    func describe(_ from: String, parameters: [TDSParameter] = []) throws -> (names: [String], types: [MType]) {
        let r = try resultSet("select top (0) * from " + from, parameters: parameters)
        return (r.columns.map(\.name), r.columns.map { $0.nullable ? .nullable($0.type.mType) : $0.type.mType })
    }
}

extension TDSResultSet {
    /// The rows as an M table with the server's column types.
    func table() throws -> MTable {
        try MTable.make(columns.map(\.name), columns.map { $0.nullable ? .nullable($0.type.mType) : $0.type.mType }, values, rows: rowCount)
    }
}

/// A lazily evaluated SQL Server query that folds filters, column selection, sorting, top/skip, distinct, row counts,
/// grouping and joins into one T-SQL statement.
final class SQLServerSource: MTableSource {
    /// A `Table.NestedJoin` waiting for its `Table.ExpandTableColumn`, which folds the pair to a SQL join.
    struct PendingJoin {
        var right: SQLServerSource
        var leftKeys: [String]
        var rightKeys: [String]
        var newColumn: String
        var kind: Int
    }
    let database: SQLServerDatabase
    let query: TSQLQuery
    let pending: PendingJoin?
    private let interpreter: MInterpreter

    init(database: SQLServerDatabase, query: TSQLQuery, pending: PendingJoin? = nil, interpreter: MInterpreter) {
        self.database = database; self.query = query; self.pending = pending; self.interpreter = interpreter
    }

    var columnNames: [String] { query.columns + (pending.map { [$0.newColumn] } ?? []) }
    var columnTypes: [MType] { query.types + (pending == nil ? [] : [MType.anyTable]) }
    var sourceDescription: String { "SQL Server: \(database.location)" }
    var nativeQuery: String? { pending == nil ? query.sql() : nil }

    func load(limit: Int?) throws -> [[MValue]] {
        if let p = pending {
            // The nested join was never expanded: read both sides and nest the right rows locally.
            let left = try { let c = try next(query).load(limit: nil); return try MTable.make(query.columns, query.types, c, rows: c.first?.count ?? 0) }()
            let right = MTable(source: p.right)
            let lk = try left.requiredIndices(p.leftKeys), rk = try right.requiredIndices(p.rightKeys)
            let joined = try MLibrary.nestedJoin(left, right, try MLibrary.exactMatches(left, lk, right, rk), newColumn: p.newColumn, kind: p.kind)
            return try joined.columns(limit: limit)
        }
        let text = query.sql(limit: limit)
        interpreter.noteNativeQuery(text)
        let result = try database.resultSet(text, parameters: query.parameters)
        guard result.columns.count == query.columns.count else {
            throw MError.dataSource("Microsoft SQL: the query returned \(result.columns.count) columns where \(query.columns.count) were expected. The table may have changed; refresh the preview.")
        }
        return result.values
    }

    private func next(_ q: TSQLQuery) -> SQLServerSource { SQLServerSource(database: database, query: q, interpreter: interpreter) }
    private var typeMap: [String: MType] { Dictionary(zip(query.columns, query.types), uniquingKeysWith: { a, _ in a }) }

    func folding(_ operation: MFoldOperation, _ ctx: MInterpreter) -> MTableSource? {
        if query.isCount { return nil }
        if let p = pending {
            guard case .expandTableColumn(let column, let names, let newNames) = operation, column == p.newColumn else { return nil }
            return expand(p, names: names, newNames: newNames)
        }
        switch operation {
        case .selectRows(let predicate):
            guard var q = query.isSliced || query.isClosed ? query.nested() : query,
                  let condition = TSQLPredicate(columns: typeMap, interpreter: ctx).translate(predicate) else { return nil }
            q.wheres.append(condition)
            return next(q)
        case .selectColumns(let names):
            guard Set(names).count == names.count, names.allSatisfy(query.columns.contains) else { return nil }
            guard var q = query.distinct || query.isClosed ? query.nested() : query else { return nil }
            q.types = names.map { n in query.types[query.columns.firstIndex(of: n) ?? 0] }
            q.columns = names
            return next(q)
        case .sort(let keys):
            guard keys.allSatisfy({ query.columns.contains($0.column) }),
                  var q = query.isSliced || query.isClosed ? query.nested() : query else { return nil }
            q.order = keys
            return next(q)
        case .firstN(let n):
            var q = query
            q.top = min(n, query.top ?? n)
            return next(q)
        case .skip(let n):
            var q = query
            q.offset += n
            if let t = query.top { q.top = max(0, t - n) }
            return next(q)
        case .distinct:
            guard var q = query.isSliced || query.isClosed ? query.nested() : query,
                  q.order.allSatisfy({ q.columns.contains($0.column) }) else { return nil }
            q.distinct = true
            return next(q)
        case .rowCount:
            guard var q = query.isSliced || query.distinct || query.isClosed ? query.nested() : query else { return nil }
            q.order = []
            q.columns = ["Count"]; q.types = [.int64]
            q.selectItems = ["count_big(*) as [Count]"]
            q.isCount = true
            return next(q)
        case .group(let keys, let aggregations):
            guard Set(keys).count == keys.count, keys.allSatisfy(query.columns.contains) else { return nil }
            guard var q = query.isSliced || query.isClosed || query.distinct ? query.nested() : query else { return nil }
            let types = typeMap
            var items = keys.map(TSQL.quote), names = keys, outTypes = keys.map { types[$0] ?? .any }
            for a in aggregations {
                guard !names.contains(a.name), let (sql, type) = TSQLAggregate.translate(a, columns: types) else { return nil }
                items.append(sql); names.append(a.name); outTypes.append(type)
            }
            q.order = []
            q.selectItems = items; q.columns = names; q.types = outTypes
            q.groupBy = keys.map(TSQL.quote)
            return next(q)
        case .join(let right, let leftKeys, let rightKeys, let kind):
            guard let r = right.source as? SQLServerSource, r.pending == nil else { return nil }
            return join(r, leftKeys: leftKeys, rightKeys: rightKeys, kind: kind, rightColumns: nil)
        case .nestedJoin(let right, let leftKeys, let rightKeys, let newColumn, let kind):
            guard let r = right.source as? SQLServerSource, r.pending == nil, database.isSameSource(as: r.database),
                  !query.columns.contains(newColumn), [0, 1, 2, 3].contains(kind) else { return nil }
            return SQLServerSource(database: database, query: query,
                                   pending: PendingJoin(right: r, leftKeys: leftKeys, rightKeys: rightKeys, newColumn: newColumn, kind: kind),
                                   interpreter: interpreter)
        case .expandTableColumn:
            return nil
        }
    }

    private func expand(_ p: PendingJoin, names: [String], newNames: [String]) -> MTableSource? {
        guard names.allSatisfy(p.right.query.columns.contains) else { return nil }
        return join(p.right, leftKeys: p.leftKeys, rightKeys: p.rightKeys, kind: p.kind, rightColumns: Array(zip(names, newNames)))
    }

    /// `Table.Join` (key columns of the same name merge into one) or an expanded nested join (`rightColumns`).
    private func join(_ r: SQLServerSource, leftKeys: [String], rightKeys: [String], kind: Int, rightColumns: [(String, String)]?) -> MTableSource? {
        guard database.isSameSource(as: r.database), [0, 1, 2, 3].contains(kind), !leftKeys.isEmpty, leftKeys.count == rightKeys.count,
              leftKeys.allSatisfy(query.columns.contains), rightKeys.allSatisfy(r.query.columns.contains),
              query.parameters.isEmpty || r.query.parameters.isEmpty else { return nil }
        let l = "[$l]", rr = "[$r]"
        var items: [String] = [], names: [String] = [], types: [MType] = []
        let rightTypes = r.typeMap
        var merged: [String: String] = [:]                       // right key → left key of the same name
        if rightColumns == nil { for (a, b) in zip(leftKeys, rightKeys) where a == b { merged[b] = a } }
        for (c, t) in zip(query.columns, query.types) {
            if merged.values.contains(c), kind == 2 || kind == 3 {
                items.append("coalesce(\(l).\(TSQL.quote(c)), \(rr).\(TSQL.quote(c))) as \(TSQL.quote(c))")
            } else {
                items.append("\(l).\(TSQL.quote(c)) as \(TSQL.quote(c))")
            }
            names.append(c); types.append(kind == 2 || kind == 3 ? t.nullableVariant : t)
        }
        let picked = rightColumns ?? r.query.columns.filter { merged[$0] == nil }.map { ($0, $0) }
        for (source, target) in picked {
            guard !names.contains(target) else { return nil }        // M raises the duplicate-column error locally
            items.append("\(rr).\(TSQL.quote(source)) as \(TSQL.quote(target))")
            names.append(target)
            let t = rightTypes[source] ?? .any
            types.append(kind == 1 || kind == 3 ? t.nullableVariant : t)
        }
        let joinKind = ["inner join", "left outer join", "right outer join", "full outer join"][kind]
        let on = zip(leftKeys, rightKeys).map { "\(l).\(TSQL.quote($0)) = \(rr).\(TSQL.quote($1))" }.joined(separator: " and ")
        var q = TSQLQuery(from: "\(query.derivedTable) as \(l) \(joinKind) \(r.query.derivedTable) as \(rr) on \(on)",
                          columns: names, types: types, parameters: query.parameters + r.query.parameters)
        q.selectItems = items
        return next(q)
    }
}

private extension MType {
    /// The type as it is after an outer join may fill it with null.
    var nullableVariant: MType { isNullable ? self : .nullable(self) }
}
