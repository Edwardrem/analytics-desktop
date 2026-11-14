import Foundation
import SQLite3
import FacetCore

/// Runs read-only statements against a SQLite database file.
enum SQLiteRunner {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Result { var names: [String]; var declaredTypes: [String?]; var columns: [[MValue]] }

    static func quote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func literal(_ v: MValue) -> String? {
        switch v {
        case .null: return "NULL"
        case .number(let d): return d.isFinite ? MSyntax.number(d) : nil
        case .text(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .logical(let b): return b ? "1" : "0"
        default: return nil
        }
    }

    /// Execute `sql`. With `describeOnly` the statement is prepared but not stepped (column names and declared types only).
    static func run(path: String, sql: String, parameters: [(name: String?, value: MValue)] = [], describeOnly: Bool = false) throws -> Result {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw MError.dataSource("Could not open the SQLite database '\(path)': \(message).")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        func failure() -> MError { MError.dataSource("SQLite: \(String(cString: sqlite3_errmsg(db))). The query was: \(sql)") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (k, p) in parameters.enumerated() {
            var index = Int32(k + 1)
            if let n = p.name {
                index = ["@", ":", "$"].map { sqlite3_bind_parameter_index(statement, $0 + n) }.first { $0 > 0 } ?? 0
                guard index > 0 else { throw MError.dataSource("The native query has no parameter named '\(n)'.") }
            }
            let rc: Int32
            switch p.value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .number(let d): rc = d == d.rounded() && abs(d) < 9e15 ? sqlite3_bind_int64(statement, index, Int64(d)) : sqlite3_bind_double(statement, index, d)
            case .logical(let b): rc = sqlite3_bind_int64(statement, index, b ? 1 : 0)
            case .text(let s): rc = sqlite3_bind_text(statement, index, s, -1, transient)
            case .binary(let d): rc = d.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(d.count), transient) }
            default: rc = sqlite3_bind_text(statement, index, (try? MConvert.text(p.value)) ?? "", -1, transient)
            }
            guard rc == SQLITE_OK else { throw failure() }
        }
        let width = Int(sqlite3_column_count(statement))
        var result = Result(names: (0..<width).map { String(cString: sqlite3_column_name(statement, Int32($0))) },
                            declaredTypes: (0..<width).map { sqlite3_column_decltype(statement, Int32($0)).map { String(cString: $0) } },
                            columns: [[MValue]](repeating: [], count: width))
        if describeOnly { return result }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw failure() }
            for c in 0..<width {
                let i = Int32(c)
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: result.columns[c].append(.number(Double(sqlite3_column_int64(statement, i))))
                case SQLITE_FLOAT: result.columns[c].append(.number(sqlite3_column_double(statement, i)))
                case SQLITE_TEXT: result.columns[c].append(.text(sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(statement, i))
                    result.columns[c].append(.binary(sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: n) } ?? Data()))
                default: result.columns[c].append(.null)
                }
            }
        }
        return result
    }

    /// M column type for a declared SQLite type, following SQLite's affinity rules.
    static func type(declared: String?) -> MType {
        guard let d = declared?.uppercased(), !d.isEmpty else { return .any }
        if d.contains("INT") { return .nullable(.int64) }
        if d.contains("CHAR") || d.contains("CLOB") || d.contains("TEXT") { return .nullable(.text) }
        if d.contains("BLOB") { return .nullable(.binary) }
        if d.contains("REAL") || d.contains("FLOA") || d.contains("DOUB") || d.contains("DEC") || d.contains("NUMERIC") { return .nullable(.plainNumber) }
        return .any
    }
}

/// A lazily evaluated SQLite query that folds row filters, column selection, sorting, top/skip, distinct and row counts.
final class SQLiteSource: MTableSource {
    struct Query {
        var from: String
        var columns: [String]
        var types: [MType]
        var wheres: [String] = []
        var order: [(column: String, descending: Bool)] = []
        var limit: Int?
        var offset = 0
        var distinct = false
        var parameters: [(name: String?, value: MValue)] = []
        /// Replaces the column list (used for `count(*)`); such a query folds no further.
        var selectList: String?
    }
    let path: String
    let query: Query
    private let interpreter: MInterpreter

    init(path: String, query: Query, interpreter: MInterpreter) { self.path = path; self.query = query; self.interpreter = interpreter }

    var columnNames: [String] { query.columns }
    var columnTypes: [MType] { query.types }
    var sourceDescription: String { "SQLite: \(path)" }
    var nativeQuery: String? { sql(limit: nil) }

    func sql(limit extra: Int?) -> String {
        var s = "select " + (query.distinct ? "distinct " : "") + (query.selectList ?? query.columns.map(SQLiteRunner.quote).joined(separator: ", ")) + " from " + query.from
        if !query.wheres.isEmpty { s += " where " + query.wheres.joined(separator: " and ") }
        if !query.order.isEmpty { s += " order by " + query.order.map { SQLiteRunner.quote($0.column) + ($0.descending ? " desc" : "") }.joined(separator: ", ") }
        let limit = [query.limit, extra].compactMap { $0 }.min()
        if limit != nil || query.offset > 0 { s += " limit \(limit ?? -1)" + (query.offset > 0 ? " offset \(query.offset)" : "") }
        return s
    }
    func load(limit: Int?) throws -> [[MValue]] {
        let text = sql(limit: limit)
        interpreter.noteNativeQuery(text)
        return try SQLiteRunner.run(path: path, sql: text, parameters: query.parameters).columns
    }
    /// This query as a sub-select, so that a later operation applies to its result.
    private func nested() -> Query {
        Query(from: "(" + sql(limit: nil) + ") as \"_\"", columns: query.columns, types: query.types, parameters: query.parameters)
    }
    private var isSliced: Bool { query.limit != nil || query.offset > 0 }
    private func next(_ q: Query) -> SQLiteSource { SQLiteSource(path: path, query: q, interpreter: interpreter) }

    func folding(_ operation: MFoldOperation, _ ctx: MInterpreter) -> MTableSource? {
        if query.selectList != nil { return nil }
        switch operation {
        case .selectRows(let predicate):
            guard let condition = SQLPredicate(columns: Set(query.columns), interpreter: ctx).translate(predicate) else { return nil }
            var q = isSliced ? nested() : query
            q.wheres.append(condition)
            return next(q)
        case .selectColumns(let names):
            guard Set(names).count == names.count, names.allSatisfy(query.columns.contains) else { return nil }
            var q = query.distinct ? nested() : query
            q.types = names.map { n in query.types[query.columns.firstIndex(of: n) ?? 0] }
            q.columns = names
            // A sort on a column that is no longer selected still applies; SQLite allows ordering by unselected columns.
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
            var q = isSliced ? nested() : query
            q.distinct = true
            return next(q)
        case .rowCount:
            var q = isSliced || query.distinct ? nested() : query
            q.columns = ["Count"]; q.types = [.int64]; q.order = []
            q.selectList = "count(*) as \"Count\""
            return next(q)
        case .group, .nestedJoin, .join, .expandTableColumn:
            return nil
        }
    }
}

/// Translates an M row predicate (`each [Amount] > 10 and Text.StartsWith([Name], "A")`) to a SQLite condition.
/// Returns nil for anything that cannot be expressed with identical results, which stops folding at that step.
struct SQLPredicate {
    let columns: Set<String>
    let interpreter: MInterpreter

    func translate(_ f: MFunction) -> String? {
        guard let (body, env) = f.closure, f.parameters.count == 1 else { return nil }
        return condition(body, env, row: f.parameters[0].name)
    }

    private func isRow(_ target: MExpr?, _ row: String) -> Bool {
        guard let target else { return true }
        if case .identifier(let n, _) = target { return n == row }
        return false
    }
    private func isNullLiteral(_ e: MExpr) -> Bool { if case .literal(.null) = e { return true }; return false }

    /// A scalar SQL expression.
    private func scalar(_ e: MExpr, _ env: MEnv, row: String) -> String? {
        switch e {
        case .literal(let v): return SQLiteRunner.literal(v)
        case .fieldAccess(let target, let name, false) where isRow(target, row):
            return columns.contains(name) ? SQLiteRunner.quote(name) : nil
        case .identifier(let name, _):
            guard name != row, let v = try? interpreter.eval(e, env).forced() else { return nil }
            return SQLiteRunner.literal(v)
        case .unary(.minus, let x): return scalar(x, env, row: row).map { "(-\($0))" }
        case .binary(let op, let l, let r) where [.add, .subtract, .multiply, .concat].contains(op):
            guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
            return "(\(a) \(op == .concat ? "||" : op.rawValue) \(b))"
        default: return nil
        }
    }

    /// A boolean SQL expression with M's three-valued logic preserved.
    private func condition(_ e: MExpr, _ env: MEnv, row: String) -> String? {
        switch e {
        case .literal(.logical(let b)): return b ? "(1 = 1)" : "(1 = 0)"
        case .unary(.not, let x): return condition(x, env, row: row).map { "(not \($0))" }
        case .binary(let op, let l, let r):
            switch op {
            case .and, .or:
                guard let a = condition(l, env, row: row), let b = condition(r, env, row: row) else { return nil }
                return "(\(a) \(op.rawValue) \(b))"
            case .equal, .notEqual:
                // `is` / `is not` are null-safe in SQLite, matching M where null = null is true and null <> 1 is true.
                guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
                if isNullLiteral(r) { return "(\(a) \(op == .equal ? "is null" : "is not null"))" }
                if isNullLiteral(l) { return "(\(b) \(op == .equal ? "is null" : "is not null"))" }
                return "(\(a) \(op == .equal ? "is" : "is not") \(b))"
            case .less, .lessEqual, .greater, .greaterEqual:
                guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
                return "(\(a) \(op.rawValue) \(b))"
            default: return nil
            }
        case .invoke(.identifier(let name, _), let args):
            var fold: (String) -> String = { $0 }
            if ["Text.Contains", "Text.StartsWith", "Text.EndsWith"].contains(name) {
                guard args.count == 2 || args.count == 3 else { return nil }
                if args.count == 3 {
                    guard case .identifier(let comparer, _) = args[2] else { return nil }
                    if comparer == "Comparer.OrdinalIgnoreCase" { fold = { "lower(\($0))" } } else if comparer != "Comparer.Ordinal" { return nil }
                }
                guard let text = scalar(args[0], env, row: row).map(fold), let part = scalar(args[1], env, row: row).map(fold) else { return nil }
                switch name {
                case "Text.Contains": return "(instr(\(text), \(part)) > 0)"
                case "Text.StartsWith": return "(substr(\(text), 1, length(\(part))) = \(part))"
                default: return "(length(\(part)) = 0 or substr(\(text), -length(\(part))) = \(part))"
                }
            }
            if name == "List.Contains", args.count == 2, let value = scalar(args[1], env, row: row) {
                var items: [String] = []
                if case .list(let exprs) = args[0] {
                    for x in exprs { guard let s = scalar(x, env, row: row) else { return nil }; items.append(s) }
                } else if case .identifier = args[0], case .list(let values)? = try? interpreter.eval(args[0], env).forced() {
                    for v in values { guard let s = SQLiteRunner.literal(v.forcedCell()) else { return nil }; items.append(s) }
                } else { return nil }
                if items.isEmpty { return "(1 = 0)" }
                if items.contains("NULL") { return nil }
                return "(\(value) is not null and \(value) in (\(items.joined(separator: ", "))))"
            }
            return nil
        default: return nil
        }
    }
}
