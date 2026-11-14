import Foundation
import FacetCore

/// A SQL database reached over its own wire protocol. Each call opens a connection, runs one statement and closes it.
protocol RemoteDatabase: AnyObject {
    var dialect: SQLDialect { get }
    /// Data source kind and location as the engine records them, e.g. "PostgreSQL" and "server;database".
    var kind: String { get }
    var location: String { get }
    /// Two tables can be joined in one query only when their keys are equal (same server, database and sign-in).
    var connectionKey: String { get }
    /// Column names and types of a statement's result, without reading rows.
    func describe(_ sql: String, parameters: [MValue]) throws -> [RemoteColumn]
    /// Run a statement; `limit` caps the rows read.
    func query(_ sql: String, parameters: [MValue], limit: Int?) throws -> RemoteResult
}

/// A lazily run server query that folds row filters, column selection, sorting, top/skip, distinct, row counts,
/// grouping and joins into the SQL it sends.
final class RemoteSQLSource: MTableSource {
    struct Query {
        var from: String
        var columns: [String]
        var types: [MType]
        var wheres: [String] = []
        var order: [(column: String, descending: Bool)] = []
        var limit: Int?
        var offset = 0
        var distinct = false
        var parameters: [MValue] = []
        /// Replaces the column list (used for `COUNT(*)`); such a query folds no further.
        var selectList: String?
    }
    let database: RemoteDatabase
    let query: Query
    private let interpreter: MInterpreter

    init(database: RemoteDatabase, query: Query, interpreter: MInterpreter) {
        self.database = database; self.query = query; self.interpreter = interpreter
    }

    private var d: SQLDialect { database.dialect }
    var columnNames: [String] { query.columns }
    var columnTypes: [MType] { query.types }
    var sourceDescription: String { "\(database.kind): \(database.location)" }
    var nativeQuery: String? { sql(limit: nil) }

    func sql(limit extra: Int?) -> String {
        let list = query.selectList ?? query.columns.map(d.quote).joined(separator: ", ")
        var s = "SELECT " + (query.distinct ? "DISTINCT " : "") + list + " FROM " + query.from
        if !query.wheres.isEmpty { s += " WHERE " + query.wheres.joined(separator: " AND ") }
        if !query.order.isEmpty {
            s += " ORDER BY " + query.order.map { d.quote($0.column) + ($0.descending ? " DESC" : "") }.joined(separator: ", ")
        }
        return s + d.limitClause(limit: [query.limit, extra].compactMap { $0 }.min(), offset: query.offset)
    }

    func load(limit: Int?) throws -> [[MValue]] {
        let text = sql(limit: limit)
        interpreter.noteNativeQuery(text)
        let result = try database.query(text, parameters: query.parameters, limit: limit)
        guard result.columns.count == query.columns.count else {
            throw MError.dataSource("\(database.kind) returned \(result.columns.count) columns where \(query.columns.count) were expected. Refresh the query's preview.")
        }
        return result.cells
    }

    /// This query as a derived table, so a later operation applies to its result.
    func nested(alias: String = "_") -> Query {
        Query(from: "(" + sql(limit: nil) + ") AS " + d.quote(alias), columns: query.columns, types: query.types, parameters: query.parameters)
    }
    private var isSliced: Bool { query.limit != nil || query.offset > 0 }
    private func next(_ q: Query) -> RemoteSQLSource { RemoteSQLSource(database: database, query: q, interpreter: interpreter) }
    private func translator(_ ctx: MInterpreter) -> SQLTranslator {
        SQLTranslator(dialect: d, columns: Dictionary(query.columns.map { ($0, d.quote($0)) }, uniquingKeysWith: { a, _ in a }), interpreter: ctx)
    }

    func folding(_ operation: MFoldOperation, _ ctx: MInterpreter) -> MTableSource? {
        if query.selectList != nil { return nil }
        switch operation {
        case .selectRows(let predicate):
            guard let condition = translator(ctx).predicate(predicate) else { return nil }
            var q = isSliced || query.distinct ? nested() : query
            q.wheres.append(condition)
            return next(q)
        case .selectColumns(let names):
            guard Set(names).count == names.count, names.allSatisfy(query.columns.contains) else { return nil }
            var q = query.distinct || isSliced ? nested() : query
            q.types = names.map { n in query.types[query.columns.firstIndex(of: n) ?? 0] }
            q.columns = names
            // A sort on a column no longer selected still applies; both servers order by unselected columns.
            return next(q)
        case .sort(let keys):
            guard keys.allSatisfy({ query.columns.contains($0.column) }) else { return nil }
            var q = isSliced ? nested() : query
            q.order = keys
            return next(q)
        case .firstN(let n):
            var q = query
            q.limit = min(n, query.limit ?? n)
            return next(q)
        case .skip(let n):
            var q = query
            q.offset += n
            if let l = query.limit { q.limit = max(0, l - n) }
            return next(q)
        case .distinct:
            // SELECT DISTINCT can only order by selected columns.
            guard query.order.allSatisfy({ query.columns.contains($0.column) }) else { return nil }
            var q = isSliced ? nested() : query
            q.distinct = true
            return next(q)
        case .rowCount:
            var q = isSliced || query.distinct ? nested() : query
            q.columns = ["Count"]; q.types = [.int64]; q.order = []
            q.selectList = "COUNT(*) AS " + d.quote("Count")
            return next(q)
        case .group(let keys, let aggregates):
            return group(keys: keys, aggregates: aggregates, ctx)
        case .nestedJoin(let leftKeys, let right, let rightKeys, let newColumn, let kind):
            guard let plan = JoinPlan(left: self, leftKeys: leftKeys, right: right, rightKeys: rightKeys, kind: kind),
                  !query.columns.contains(newColumn) else { return nil }
            return PendingNestedJoin(plan: plan, newColumn: newColumn, rightType: right.tableType, interpreter: interpreter)
        case .join(let leftKeys, let right, let rightKeys, let kind):
            guard let plan = JoinPlan(left: self, leftKeys: leftKeys, right: right, rightKeys: rightKeys, kind: kind) else { return nil }
            return plan.flat(interpreter: interpreter)
        case .expandTableColumn: return nil
        }
    }

    private func group(keys: [String], aggregates: [(name: String, function: MFunction, type: MType)], _ ctx: MInterpreter) -> MTableSource? {
        guard keys.allSatisfy(query.columns.contains), Set(keys).count == keys.count else { return nil }
        let names = keys + aggregates.map(\.name)
        guard Set(names).count == names.count else { return nil }
        let t = translator(ctx)
        var list = keys.map(d.quote)
        for a in aggregates {
            guard let sql = t.aggregate(a.function) else { return nil }
            list.append(sql + " AS " + d.quote(a.name))
        }
        let inner = isSliced || query.distinct || !query.order.isEmpty ? nested() : query
        var s = "SELECT " + list.joined(separator: ", ") + " FROM " + inner.from
        if !inner.wheres.isEmpty { s += " WHERE " + inner.wheres.joined(separator: " AND ") }
        if !keys.isEmpty { s += " GROUP BY " + keys.map(d.quote).joined(separator: ", ") }
        let keyTypes = keys.map { k in query.types[query.columns.firstIndex(of: k) ?? 0] }
        return next(Query(from: "(" + s + ") AS " + d.quote("_"), columns: names, types: keyTypes + aggregates.map(\.type),
                          parameters: query.parameters))
    }
}

/// Two server tables on the same connection, joined on null-safe key equality (null matches null, as in M).
struct JoinPlan {
    let left: RemoteSQLSource
    let right: RemoteSQLSource
    let leftKeys: [String]
    let rightKeys: [String]
    /// M `JoinKind`: 0 inner, 1 left outer, 2 right outer, 3 full outer.
    let kind: Int

    init?(left: RemoteSQLSource, leftKeys: [String], right: MTable, rightKeys: [String], kind: Int) {
        guard right.isLazy, let r = right.source as? RemoteSQLSource, r.query.selectList == nil, left.query.selectList == nil,
              r.database.connectionKey == left.database.connectionKey, r.database.dialect == left.database.dialect,
              left.query.parameters.isEmpty, r.query.parameters.isEmpty,
              !leftKeys.isEmpty, leftKeys.count == rightKeys.count,
              leftKeys.allSatisfy(left.query.columns.contains), rightKeys.allSatisfy(r.query.columns.contains),
              (0...3).contains(kind), kind != 3 || left.database.dialect.supportsFullOuterJoin else { return nil }
        self.left = left; self.right = r; self.leftKeys = leftKeys; self.rightKeys = rightKeys; self.kind = kind
    }

    private var d: SQLDialect { left.database.dialect }
    private var joinWord: String { ["INNER JOIN", "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN"][kind] }
    private func l(_ c: String) -> String { d.quote("_l") + "." + d.quote(c) }
    private func r(_ c: String) -> String { d.quote("_r") + "." + d.quote(c) }

    /// `FROM (left) AS _l JOIN (right) AS _r ON …`.
    private var fromClause: String {
        let on = zip(leftKeys, rightKeys).map { d.nullSafeEqual(l($0), r($1)) }.joined(separator: " AND ")
        return "(" + left.sql(limit: nil) + ") AS " + d.quote("_l") + " " + joinWord + " (" + right.sql(limit: nil) + ") AS "
            + d.quote("_r") + " ON " + on
    }

    private func source(_ select: [(sql: String, name: String, type: MType)], interpreter: MInterpreter) -> RemoteSQLSource? {
        guard Set(select.map(\.name)).count == select.count else { return nil }
        let s = "SELECT " + select.map { $0.sql + " AS " + d.quote($0.name) }.joined(separator: ", ") + " FROM " + fromClause
        return RemoteSQLSource(database: left.database,
                               query: .init(from: "(" + s + ") AS " + d.quote("_"), columns: select.map(\.name), types: select.map(\.type)),
                               interpreter: interpreter)
    }

    private var leftColumns: [(sql: String, name: String, type: MType)] {
        let nullable = kind == 2 || kind == 3
        return zip(left.query.columns, left.query.types).map { (l($0), $0, nullable ? $1.asNullable : $1) }
    }
    private func rightColumn(_ c: String, as name: String) -> (sql: String, name: String, type: MType) {
        let type = right.query.types[right.query.columns.firstIndex(of: c) ?? 0]
        return (r(c), name, kind == 1 || kind == 3 ? type.asNullable : type)
    }

    /// `Table.Join`: same-named key columns merge into the left one (the right value when the left row is missing).
    func flat(interpreter: MInterpreter) -> RemoteSQLSource? {
        var merged: [String: String] = [:]
        for (lk, rk) in zip(leftKeys, rightKeys) where lk == rk { merged[lk] = rk }
        var select = leftColumns.map { c -> (sql: String, name: String, type: MType) in
            guard let rk = merged[c.name], kind == 2 || kind == 3 else { return c }
            return ("COALESCE(\(c.sql), \(r(rk)))", c.name, c.type)
        }
        for c in right.query.columns where merged[c] == nil { select.append(rightColumn(c, as: c)) }
        return source(select, interpreter: interpreter)
    }

    /// `Table.NestedJoin` followed by `Table.ExpandTableColumn`.
    func expanded(fields: [String], newNames: [String], interpreter: MInterpreter) -> RemoteSQLSource? {
        guard fields.count == newNames.count, fields.allSatisfy(right.query.columns.contains) else { return nil }
        return source(leftColumns + zip(fields, newNames).map { rightColumn($0, as: $1) }, interpreter: interpreter)
    }
}

/// The result of `Table.NestedJoin` between two tables of one server. Expanding the new column folds into a SQL join;
/// anything else reads both tables and nests the matches here, exactly as M does.
final class PendingNestedJoin: MTableSource {
    let plan: JoinPlan
    let newColumn: String
    private let rightType: MType
    private let interpreter: MInterpreter

    init(plan: JoinPlan, newColumn: String, rightType: MType, interpreter: MInterpreter) {
        self.plan = plan; self.newColumn = newColumn; self.rightType = rightType; self.interpreter = interpreter
    }

    var columnNames: [String] { plan.left.query.columns + [newColumn] }
    var columnTypes: [MType] { plan.left.query.types + [rightType] }
    var sourceDescription: String { plan.left.sourceDescription }
    /// The join the server runs once the column is expanded (all of the right table's columns).
    var nativeQuery: String? {
        plan.expanded(fields: plan.right.query.columns, newNames: plan.right.query.columns.map { newColumn + "." + $0 }, interpreter: interpreter)?.nativeQuery
    }

    func load(limit: Int?) throws -> [[MValue]] {
        let left = MTable(source: plan.left), right = MTable(source: plan.right)
        let lk = try left.requiredIndices(plan.leftKeys), rk = try right.requiredIndices(plan.rightKeys)
        let joined = try MLibrary.nestedJoin(left, right, try MLibrary.exactMatches(left, lk, right, rk), newColumn: newColumn, kind: plan.kind)
        return try joined.columns(limit: limit)
    }

    func folding(_ operation: MFoldOperation, _ ctx: MInterpreter) -> MTableSource? {
        guard case .expandTableColumn(let column, let fields, let newNames) = operation, column == newColumn else { return nil }
        return plan.expanded(fields: fields, newNames: newNames, interpreter: interpreter)
    }
}
