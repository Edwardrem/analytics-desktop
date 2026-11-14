import Foundation

/// T-SQL text helpers.
enum TSQL {
    static func quote(_ identifier: String) -> String { "[" + identifier.replacingOccurrences(of: "]", with: "]]") + "]" }
    static func string(_ s: String) -> String { "N'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    private static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .current; return c }()
    private static func stamp(_ d: Date, time: Bool) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
        var s = String(format: "%04d-%02d-%02d", c.year ?? 1, c.month ?? 1, c.day ?? 1)
        if time {
            let ticks = Int((Double(c.nanosecond ?? 0) / 100).rounded())
            s += String(format: " %02d:%02d:%02d.%07d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, min(ticks, 9_999_999))
        }
        return s
    }
    static func clock(_ seconds: Double) -> String {
        let ticks = Int((seconds * 10_000_000).rounded())
        let s = ticks / 10_000_000
        return String(format: "%02d:%02d:%02d.%07d", s / 3600, (s / 60) % 60, s % 60, ticks % 10_000_000)
    }

    /// A T-SQL literal for an M value, or nil when the value has no exact literal.
    static func literal(_ v: MValue) -> String? {
        switch v {
        case .null: return "NULL"
        case .logical(let b): return b ? "1" : "0"
        case .number(let d):
            guard d.isFinite else { return nil }
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return MSyntax.number(d)
        case .text(let s): return string(s)
        case .date(let d): return "convert(date, '\(stamp(d, time: false))')"
        case .datetime(let d): return "convert(datetime2, '\(stamp(d, time: true))')"
        case .datetimezone(let d, let offset):
            let local = d.addingTimeInterval(Double(offset * 60))
            let sign = offset < 0 ? "-" : "+", a = abs(offset)
            return "convert(datetimeoffset, '\(stamp(local, time: true)) \(sign)\(String(format: "%02d:%02d", a / 60, a % 60))')"
        case .time(let s): return "convert(time, '\(clock(s))')"
        default: return nil
        }
    }
}

/// A SELECT statement built up by folding. Each operation either edits this statement or wraps it as a derived table.
struct TSQLQuery {
    var from: String
    var columns: [String]
    var types: [MType]
    /// Explicit select list (`expr as [name]`) for grouped, joined or counted queries; later operations wrap it.
    var selectItems: [String]?
    var wheres: [String] = []
    var groupBy: [String] = []
    var order: [(column: String, descending: Bool)] = []
    var top: Int?
    var offset = 0
    var distinct = false
    var parameters: [TDSParameter] = []
    /// `count_big(*)`: nothing folds after it.
    var isCount = false

    init(from: String, columns: [String], types: [MType], parameters: [TDSParameter] = []) {
        self.from = from; self.columns = columns; self.types = types; self.parameters = parameters
    }

    var isSliced: Bool { top != nil || offset > 0 }
    var isClosed: Bool { selectItems != nil || !groupBy.isEmpty }

    func sql(limit extra: Int? = nil) -> String { render(limit: extra, keepOrder: true) }

    private func render(limit extra: Int?, keepOrder: Bool) -> String {
        let limit = [top, extra].compactMap { $0 }.min()
        var s = "select "
        if distinct { s += "distinct " }
        if let limit, offset == 0 { s += "top (\(limit)) " }
        s += (selectItems ?? columns.map(TSQL.quote)).joined(separator: ", ")
        s += " from " + from
        if !wheres.isEmpty { s += " where " + wheres.joined(separator: " and ") }
        if !groupBy.isEmpty { s += " group by " + groupBy.joined(separator: ", ") }
        let ordered = keepOrder || limit != nil || offset > 0
        if ordered, !order.isEmpty {
            s += " order by " + order.map { TSQL.quote($0.column) + ($0.descending ? " desc" : "") }.joined(separator: ", ")
        } else if offset > 0 {
            s += " order by (select null)"
        }
        if offset > 0 {
            s += " offset \(offset) rows"
            if let limit { s += " fetch next \(limit) rows only" }
        }
        return s
    }

    /// This query as a derived table, so the next operation applies to its result. A derived table cannot be ordered
    /// without TOP, so an unsliced sort moves to the outer query; nil when it cannot (a sort on an unselected column).
    func nested(alias: String = "_") -> TSQLQuery? {
        var outer = TSQLQuery(from: "(" + render(limit: nil, keepOrder: false) + ") as " + TSQL.quote(alias), columns: columns, types: types, parameters: parameters)
        if !isSliced, !order.isEmpty {
            guard order.allSatisfy({ columns.contains($0.column) }) else { return nil }
            outer.order = order
        }
        return outer
    }
    /// The query as a derived table for a join (order is meaningless there unless sliced).
    var derivedTable: String { "(" + render(limit: nil, keepOrder: false) + ")" }
}

/// Translates an M row predicate to a T-SQL search condition with M's results: `=` treats null as a value
/// (null = null is true), `<>` keeps nulls, comparisons and functions with null are unknown (the row is dropped).
/// Negation is pushed down so that two-valued M equality is never negated as three-valued SQL.
struct TSQLPredicate {
    let columns: [String: MType]
    let interpreter: MInterpreter

    func translate(_ f: MFunction) -> String? {
        guard let (body, env) = f.closure, f.parameters.count == 1 else { return nil }
        return condition(body, env, row: f.parameters[0].name, negate: false)
    }

    private func isRow(_ target: MExpr?, _ row: String) -> Bool {
        guard let target else { return true }
        if case .identifier(let n, _) = target { return n == row }
        return false
    }

    /// Evaluate an expression that does not read the row (a literal, `#date(…)`, a parameter); nil when it reads the row.
    private func constant(_ e: MExpr, _ env: MEnv, row: String) -> MValue? {
        let guarded = MEnv(parent: env, name: row, value: .lazy(MThunk { throw MError("row") }))
        return try? interpreter.eval(e, guarded).forced()
    }

    /// A scalar expression and whether it can be null.
    private func scalar(_ e: MExpr, _ env: MEnv, row: String) -> (sql: String, nullable: Bool)? {
        switch e {
        case .fieldAccess(let target, let name, false) where isRow(target, row):
            return columns[name].map { (TSQL.quote(name), $0.isNullable) }
        case .unary(.minus, let x):
            if let v = constant(e, env, row: row) { return TSQL.literal(v).map { ($0, v.isNull) } }
            return scalar(x, env, row: row).map { ("(-\($0.sql))", $0.nullable) }
        case .binary(let op, let l, let r) where [.add, .subtract, .multiply, .concat].contains(op):
            if let v = constant(e, env, row: row) { return TSQL.literal(v).map { ($0, v.isNull) } }
            guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
            return ("(\(a.sql) \(op == .concat ? "+" : op.rawValue) \(b.sql))", a.nullable || b.nullable)
        default:
            guard let v = constant(e, env, row: row), let s = TSQL.literal(v) else { return nil }
            return (s, v.isNull)
        }
    }

    private func condition(_ e: MExpr, _ env: MEnv, row: String, negate: Bool) -> String? {
        switch e {
        case .literal(.logical(let b)): return b != negate ? "(1 = 1)" : "(1 = 0)"
        case .unary(.not, let x): return condition(x, env, row: row, negate: !negate)
        case .fieldAccess(let target, let name, false) where isRow(target, row):
            guard let t = columns[name], t.nonNullable == .logical else { return nil }
            return "(\(TSQL.quote(name)) = \(negate ? 0 : 1))"
        case .binary(let op, let l, let r):
            switch op {
            case .and, .or:
                guard let a = condition(l, env, row: row, negate: negate), let b = condition(r, env, row: row, negate: negate) else { return nil }
                let joined = (op == .and) != negate ? "and" : "or"
                return "(\(a) \(joined) \(b))"
            case .equal, .notEqual:
                guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
                return equality(a, b, equal: (op == .equal) != negate)
            case .less, .lessEqual, .greater, .greaterEqual:
                guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
                let c = "(\(a.sql) \(op.rawValue) \(b.sql))"
                return negate ? "(not \(c))" : c
            default: return nil
            }
        case .invoke(.identifier(let name, _), let args):
            guard let c = call(name, args, env, row: row, negate: negate) else { return nil }
            return c
        default: return nil
        }
    }

    private func equality(_ a: (sql: String, nullable: Bool), _ b: (sql: String, nullable: Bool), equal: Bool) -> String {
        if a.sql == "NULL" || b.sql == "NULL" {
            let other = a.sql == "NULL" ? b.sql : a.sql
            if other == "NULL" { return equal ? "(1 = 1)" : "(1 = 0)" }
            return "(\(other) is \(equal ? "" : "not ")null)"
        }
        switch (a.nullable, b.nullable, equal) {
        case (false, false, _): return "(\(a.sql) \(equal ? "=" : "<>") \(b.sql))"
        case (true, false, true): return "(\(a.sql) = \(b.sql))"
        case (false, true, true): return "(\(a.sql) = \(b.sql))"
        case (true, false, false): return "(\(a.sql) <> \(b.sql) or \(a.sql) is null)"
        case (false, true, false): return "(\(a.sql) <> \(b.sql) or \(b.sql) is null)"
        case (true, true, true): return "(\(a.sql) = \(b.sql) or (\(a.sql) is null and \(b.sql) is null))"
        case (true, true, false):
            return "(\(a.sql) <> \(b.sql) or (\(a.sql) is null and \(b.sql) is not null) or (\(a.sql) is not null and \(b.sql) is null))"
        }
    }

    /// `%`, `_` and `[` are wildcards in LIKE; bracket them.
    private func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "[[]").replacingOccurrences(of: "%", with: "[%]").replacingOccurrences(of: "_", with: "[_]")
    }

    private func call(_ name: String, _ args: [MExpr], _ env: MEnv, row: String, negate: Bool) -> String? {
        if ["Text.Contains", "Text.StartsWith", "Text.EndsWith"].contains(name) {
            guard args.count == 2 || args.count == 3, let text = scalar(args[0], env, row: row),
                  case .text(var part)? = constant(args[1], env, row: row) else { return nil }
            var subject = text.sql
            if args.count == 3 {
                guard case .identifier(let comparer, _) = args[2] else { return nil }
                if comparer == "Comparer.OrdinalIgnoreCase" { subject = "lower(\(subject))"; part = part.lowercased() } else if comparer != "Comparer.Ordinal" { return nil }
            }
            let p = likeEscaped(part)
            let pattern = name == "Text.Contains" ? "%\(p)%" : name == "Text.StartsWith" ? "\(p)%" : "%\(p)"
            let c = "(\(subject) like \(TSQL.string(pattern)))"
            return negate ? "(not \(c))" : c
        }
        if name == "List.Contains", args.count == 2, let value = scalar(args[1], env, row: row),
           case .list(let items)? = constant(args[0], env, row: row) {
            var literals: [String] = []
            var hasNull = false
            for item in items {
                let v = item.forcedCell()
                if v.isNull { hasNull = true; continue }
                guard let s = TSQL.literal(v) else { return nil }
                literals.append(s)
            }
            let inList = literals.isEmpty ? "(1 = 0)" : "(\(value.sql) in (\(literals.joined(separator: ", "))))"
            if negate {
                let notIn = literals.isEmpty ? "(1 = 1)" : "(\(value.sql) not in (\(literals.joined(separator: ", "))))"
                return hasNull ? "(\(notIn) and \(value.sql) is not null)" : "(\(notIn) or \(value.sql) is null)"
            }
            return hasNull ? "(\(inList) or \(value.sql) is null)" : inList
        }
        return nil
    }
}

/// Translates `Table.Group` aggregations (`each List.Sum([Amount])`, `each Table.RowCount(_)`, …) to T-SQL.
enum TSQLAggregate {
    /// The select item and M type for one aggregation, or nil when it has no T-SQL equivalent.
    static func translate(_ a: MGroupAggregation, columns: [String: MType]) -> (sql: String, type: MType)? {
        guard let (body, _) = a.function.closure, a.function.parameters.count == 1 else { return nil }
        let row = a.function.parameters[0].name
        guard case .invoke(.identifier(let name, _), let args) = body, args.count == 1 else { return nil }
        let alias = " as " + TSQL.quote(a.name)
        if name == "Table.RowCount", case .identifier(let n, _) = args[0], n == row { return ("count_big(*)" + alias, a.type ?? .int64) }
        guard case .fieldAccess(let target, let column, false) = args[0], let columnType = columns[column] else { return nil }
        if let target { guard case .identifier(let n, _) = target, n == row else { return nil } }
        let c = TSQL.quote(column)
        switch name {
        case "List.Sum": return ("sum(\(c))" + alias, a.type ?? columnType)
        case "List.Min": return ("min(\(c))" + alias, a.type ?? columnType)
        case "List.Max": return ("max(\(c))" + alias, a.type ?? columnType)
        case "List.Average": return ("avg(convert(float, \(c)))" + alias, a.type ?? .nullable(.plainNumber))
        case "List.Count": return ("count_big(*)" + alias, a.type ?? .int64)
        case "List.NonNullCount": return ("count_big(\(c))" + alias, a.type ?? .int64)
        default: return nil
        }
    }
}
