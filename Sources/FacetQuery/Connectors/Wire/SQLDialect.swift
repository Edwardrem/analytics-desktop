import Foundation
import FacetCore

/// The SQL spelling of one server family, used when M steps fold into a query.
struct SQLDialect: Sendable, Equatable {
    enum Flavor: String, Sendable { case postgres, redshift, mysql }
    let flavor: Flavor

    static let postgres = SQLDialect(flavor: .postgres)
    static let redshift = SQLDialect(flavor: .redshift)
    static let mysql = SQLDialect(flavor: .mysql)

    var isMySQL: Bool { flavor == .mysql }
    var supportsFullOuterJoin: Bool { !isMySQL }

    /// A quoted identifier.
    func quote(_ id: String) -> String {
        if isMySQL { return "`" + id.replacingOccurrences(of: "`", with: "``") + "`" }
        return "\"" + id.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    /// `schema.name`, each part quoted.
    func qualified(_ schema: String, _ name: String) -> String { quote(schema) + "." + quote(name) }

    /// A literal for an M value, or nil when the value can't be written so that the server reads it back unchanged
    /// (which stops folding).
    func literal(_ v: MValue) -> String? {
        switch v {
        case .null: return "NULL"
        case .logical(let b): return b ? "TRUE" : "FALSE"
        case .number(let d):
            guard d.isFinite else { return nil }
            return MSyntax.number(d)
        case .text(let s): return text(s)
        case .date(let d): return "DATE '\(Self.format(d, "yyyy-MM-dd"))'"
        case .datetime(let d): return "TIMESTAMP '\(Self.format(d, "yyyy-MM-dd HH:mm:ss.SSSSSS"))'"
        case .datetimezone(let d, let offset):
            guard !isMySQL else { return nil }
            let sign = offset < 0 ? "-" : "+", m = abs(offset)
            let wall = d.addingTimeInterval(Double(offset) * 60)
            return "TIMESTAMPTZ '\(Self.format(wall, "yyyy-MM-dd HH:mm:ss.SSSSSS"))\(sign)\(String(format: "%02d:%02d", m / 60, m % 60))'"
        default: return nil
        }
    }

    /// A text literal. NUL can't be sent; backslashes are spelled so the server reads them literally whatever its settings.
    func text(_ s: String) -> String? {
        guard !s.contains("\u{0}") else { return nil }
        let quoted = s.replacingOccurrences(of: "'", with: "''")
        guard s.contains("\\") else { return "'" + quoted + "'" }
        switch flavor {
        case .postgres: return "E'" + quoted.replacingOccurrences(of: "\\", with: "\\\\") + "'"
        case .redshift: return "'" + quoted.replacingOccurrences(of: "\\", with: "\\\\") + "'"
        // Hex never depends on NO_BACKSLASH_ESCAPES.
        case .mysql: return "CONVERT(X'\(Data(s.utf8).hexString)' USING utf8mb4)"
        }
    }

    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// `limit` / `offset` clause (with a leading space), or empty.
    func limitClause(limit: Int?, offset: Int) -> String {
        guard limit != nil || offset > 0 else { return "" }
        if isMySQL {
            // MySQL has no OFFSET without LIMIT; the documented idiom is the largest unsigned value.
            let l = limit.map(String.init) ?? "18446744073709551615"
            return offset > 0 ? " LIMIT \(offset), \(l)" : " LIMIT \(l)"
        }
        var s = ""
        if let limit { s += " LIMIT \(limit)" }
        if offset > 0 { s += " OFFSET \(offset)" }
        return s
    }

    /// Equality where null equals null, as in M.
    func nullSafeEqual(_ a: String, _ b: String) -> String {
        switch flavor {
        case .postgres: return "(\(a) IS NOT DISTINCT FROM \(b))"
        case .redshift: return "((\(a) = \(b)) OR (\(a) IS NULL AND \(b) IS NULL))"
        case .mysql: return "(\(a) <=> \(b))"
        }
    }
    func concat(_ a: String, _ b: String) -> String { isMySQL ? "CONCAT(\(a), \(b))" : "(\(a) || \(b))" }
    func lower(_ a: String) -> String { "LOWER(\(a))" }
    func contains(_ text: String, _ part: String) -> String {
        isMySQL ? "(LOCATE(\(part), \(text)) > 0)" : "(STRPOS(\(text), \(part)) > 0)"
    }
    func startsWith(_ text: String, _ part: String) -> String { "(LEFT(\(text), CHAR_LENGTH(\(part))) = \(part))" }
    func endsWith(_ text: String, _ part: String) -> String {
        "(CHAR_LENGTH(\(part)) = 0 OR RIGHT(\(text), CHAR_LENGTH(\(part))) = \(part))"
    }
}

/// Translates M row predicates and scalar expressions into a dialect's SQL. Returns nil for anything that can't be
/// expressed with the same result, which stops folding at that step.
struct SQLTranslator {
    let dialect: SQLDialect
    /// Column name → SQL expression for it.
    let columns: [String: String]
    let interpreter: MInterpreter

    func predicate(_ f: MFunction) -> String? {
        guard case .closure(let body, let env) = f.implementation, f.parameters.count == 1 else { return nil }
        return condition(body, env, row: f.parameters[0].name)
    }

    private func isRow(_ target: MExpr?, _ row: String) -> Bool {
        guard let target else { return true }
        if case .identifier(let n, _) = target { return n == row }
        return false
    }
    private func isNullLiteral(_ e: MExpr) -> Bool { if case .literal(.null) = e { return true }; return false }

    /// The column a field access `[Name]` (or `_[Name]`) names, if it is one of the table's.
    func column(_ e: MExpr, row: String) -> String? {
        if case .fieldAccess(let target, let name, false) = e, isRow(target, row) { return columns[name] }
        return nil
    }

    func scalar(_ e: MExpr, _ env: MEnv, row: String) -> String? {
        switch e {
        case .literal(let v): return dialect.literal(v)
        case .fieldAccess: return column(e, row: row)
        case .identifier(let name, _):
            guard name != row, let v = try? interpreter.eval(e, env).forced() else { return nil }
            return dialect.literal(v)
        case .unary(.minus, let x): return scalar(x, env, row: row).map { "(-\($0))" }
        case .binary(let op, let l, let r) where [.add, .subtract, .multiply, .concat].contains(op):
            guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
            return op == .concat ? dialect.concat(a, b) : "(\(a) \(op.rawValue) \(b))"
        default: return nil
        }
    }

    func condition(_ e: MExpr, _ env: MEnv, row: String) -> String? {
        switch e {
        case .literal(.logical(let b)): return b ? "(1 = 1)" : "(1 = 0)"
        case .unary(.not, let x): return condition(x, env, row: row).map { "(NOT \($0))" }
        case .binary(let op, let l, let r):
            switch op {
            case .and, .or:
                guard let a = condition(l, env, row: row), let b = condition(r, env, row: row) else { return nil }
                return "(\(a) \(op == .and ? "AND" : "OR") \(b))"
            case .equal, .notEqual:
                guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
                if isNullLiteral(r) { return "(\(a) \(op == .equal ? "IS NULL" : "IS NOT NULL"))" }
                if isNullLiteral(l) { return "(\(b) \(op == .equal ? "IS NULL" : "IS NOT NULL"))" }
                let eq = dialect.nullSafeEqual(a, b)
                return op == .equal ? eq : "(NOT \(eq))"
            case .less, .lessEqual, .greater, .greaterEqual:
                // In M a comparison with null is null, which keeps no row; SQL's NULL comparison also keeps none.
                guard let a = scalar(l, env, row: row), let b = scalar(r, env, row: row) else { return nil }
                return "(\(a) \(op.rawValue) \(b))"
            default: return nil
            }
        case .invoke(.identifier(let name, _), let args):
            if ["Text.Contains", "Text.StartsWith", "Text.EndsWith"].contains(name) {
                guard args.count == 2 || args.count == 3 else { return nil }
                var fold: (String) -> String = { $0 }
                if args.count == 3 {
                    guard case .identifier(let comparer, _) = args[2] else { return nil }
                    if comparer == "Comparer.OrdinalIgnoreCase" { fold = dialect.lower } else if comparer != "Comparer.Ordinal" { return nil }
                }
                guard let text = scalar(args[0], env, row: row).map(fold), let part = scalar(args[1], env, row: row).map(fold) else { return nil }
                // M's Text functions on null are null (no row kept); the SQL functions are NULL too.
                switch name {
                case "Text.Contains": return dialect.contains(text, part)
                case "Text.StartsWith": return dialect.startsWith(text, part)
                default: return dialect.endsWith(text, part)
                }
            }
            if name == "List.Contains", args.count == 2, let value = scalar(args[1], env, row: row) {
                var items: [String] = []
                if case .list(let exprs) = args[0] {
                    for x in exprs { guard let s = scalar(x, env, row: row) else { return nil }; items.append(s) }
                } else if case .identifier = args[0], case .list(let values)? = try? interpreter.eval(args[0], env).forced() {
                    guard values.count <= 10_000 else { return nil }
                    for v in values { guard let s = dialect.literal(v.forcedCell()) else { return nil }; items.append(s) }
                } else { return nil }
                if items.isEmpty { return "(1 = 0)" }
                if items.contains("NULL") { return nil }
                return "(\(value) IS NOT NULL AND \(value) IN (\(items.joined(separator: ", "))))"
            }
            return nil
        default: return nil
        }
    }

    /// An aggregate for `Table.Group` (`each List.Sum([Amount])`, `each Table.RowCount(_)`, `Table.RowCount`…).
    func aggregate(_ f: MFunction) -> String? {
        if case .native = f.implementation { return f.name == "Table.RowCount" ? "COUNT(*)" : nil }
        guard case .closure(let body, _) = f.implementation, f.parameters.count == 1 else { return nil }
        let row = f.parameters[0].name
        guard case .invoke(.identifier(let name, _), let args) = body, args.count == 1 else { return nil }
        if name == "Table.RowCount" {
            if case .identifier(let n, _) = args[0], n == row { return "COUNT(*)" }
            return nil
        }
        if name == "List.Count", case .invoke(.identifier("List.Distinct", _), let inner) = args[0], inner.count == 1,
           let c = column(inner[0], row: row) {
            // M counts null as one distinct value; SQL's COUNT(DISTINCT) skips it.
            return "(COUNT(DISTINCT \(c)) + MAX(CASE WHEN \(c) IS NULL THEN 1 ELSE 0 END))"
        }
        guard let c = column(args[0], row: row) else { return nil }
        switch name {
        case "List.Sum": return "SUM(\(c))"
        case "List.Min": return "MIN(\(c))"
        case "List.Max": return "MAX(\(c))"
        case "List.Average": return "AVG(\(c))"
        case "List.Count": return "COUNT(*)"
        case "List.NonNullCount": return "COUNT(\(c))"
        default: return nil
        }
    }
}
