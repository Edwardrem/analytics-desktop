import Foundation
import FacetCore

/// Security roles: row-level filters, object-level security and "View as".
enum RoleLogic {
    /// A comparison the rule builder can write as DAX.
    enum Comparison: String, CaseIterable, Identifiable {
        case equals, notEquals, greater, greaterOrEqual, less, lessOrEqual, contains, startsWith
        var id: String { rawValue }
        var title: String {
            switch self {
            case .equals: return "is"
            case .notEquals: return "is not"
            case .greater: return "is greater than"
            case .greaterOrEqual: return "is at least"
            case .less: return "is less than"
            case .lessOrEqual: return "is at most"
            case .contains: return "contains"
            case .startsWith: return "starts with"
            }
        }
        var symbol: String {
            switch self {
            case .equals: return "="
            case .notEquals: return "<>"
            case .greater: return ">"
            case .greaterOrEqual: return ">="
            case .less: return "<"
            case .lessOrEqual: return "<="
            case .contains, .startsWith: return ""
            }
        }
        static func valid(for type: DataType) -> [Comparison] {
            switch type {
            case .text, .any: return [.equals, .notEquals, .contains, .startsWith]
            case .boolean: return [.equals, .notEquals]
            default: return [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual]
            }
        }
    }

    /// The literal a typed value becomes in a rule; nil when the text isn't a value of that type.
    static func literal(_ text: String, type: DataType) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .text, .any, .binary:
            return ModelDAX.string(text)
        case .boolean:
            guard let b = Value.string(t).asBool else { return nil }
            return b ? "TRUE()" : "FALSE()"
        case .integer, .decimal, .currency, .duration:
            guard let d = Double(t), d.isFinite else { return nil }
            return ModelDAX.number(d)
        case .date, .dateTime, .time:
            guard let d = Value.string(t).asDate else { return nil }
            return ModelDAX.literal(.date(d))
        }
    }

    /// One rule as a DAX boolean expression over a column of the filtered table, e.g. `[Region] = "West"`.
    static func rule(column: String, type: DataType, comparison: Comparison, value: String) -> String? {
        let ref = "[\(ModelDAX.bracket(column))]"
        switch comparison {
        case .contains: return "CONTAINSSTRING(\(ref), \(ModelDAX.string(value)))"
        case .startsWith: return "LEFT(\(ref), \(value.count)) = \(ModelDAX.string(value))"
        default:
            guard let lit = literal(value, type: type) else { return nil }
            return "\(ref) \(comparison.symbol) \(lit)"
        }
    }

    /// Adds a rule to an existing filter with AND / OR.
    static func combine(_ existing: String, with rule: String, any: Bool = false) -> String {
        let e = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return rule }
        return "(\(e)) \(any ? "||" : "&&") \(rule)"
    }

    // MARK: Object-level security

    static func isTableHidden(_ role: SecurityRole, _ table: String) -> Bool {
        role.hiddenTables.contains { ModelDAX.same($0, table) }
    }
    static func isColumnHidden(_ role: SecurityRole, table: String, column: String) -> Bool {
        let id = ModelNames.identifier(table: table, name: column)
        return role.hiddenColumns.contains { ModelDAX.same($0, id) }
    }
    static func setTable(_ table: String, hidden: Bool, in role: inout SecurityRole) {
        role.hiddenTables.removeAll { ModelDAX.same($0, table) }
        if hidden {
            role.hiddenTables.append(table)
            // A hidden table hides all of its columns; per-column entries would be redundant.
            role.hiddenColumns.removeAll { ModelDAX.same(ModelNames.split($0).table, table) }
        }
    }
    static func setColumn(table: String, column: String, hidden: Bool, in role: inout SecurityRole) {
        let id = ModelNames.identifier(table: table, name: column)
        role.hiddenColumns.removeAll { ModelDAX.same($0, id) }
        if hidden, !isTableHidden(role, table) { role.hiddenColumns.append(id) }
    }

    // MARK: Validation

    /// Trims names, drops blank filters and anything that points at objects no longer in the model.
    static func cleaned(_ roles: [SecurityRole], model: SemanticModel) -> [SecurityRole] {
        roles.map { role in
            var r = role
            r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
            r.tableFilters = r.tableFilters.filter { key, value in
                model.table(key) != nil && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            r.hiddenTables = r.hiddenTables.filter { model.table($0) != nil }
            r.hiddenColumns = r.hiddenColumns.filter { id in
                let (table, member) = ModelNames.split(id)
                guard let member, model.table(table)?.column(member) != nil else { return false }
                return !isTableHidden(r, table)
            }
            return r
        }
    }

    static func problems(_ roles: [SecurityRole], model: SemanticModel) -> [String] {
        var out: [String] = []
        for (i, r) in roles.enumerated() {
            let others = roles.enumerated().filter { $0.offset < i }.map(\.element.name)
            if let p = ModelNames.problem(r.name, noun: "role", others: others), !out.contains(p) { out.append(p) }
            if r.name.contains(",") { out.append("Role names can't contain a comma.") }
            for (table, filter) in r.tableFilters.sorted(by: { $0.key < $1.key }) where isTableHidden(r, table) {
                if !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append("“\(r.name)” hides \(table), so it can't also filter its rows.")
                }
            }
        }
        return out
    }

    // MARK: View as

    /// Why the report can't be viewed as these roles; nil when it can.
    static func viewAsProblem(roles: [String], user: String, model: SemanticModel) -> String? {
        if let missing = roles.first(where: { name in !model.roles.contains { ModelDAX.same($0.name, name) } }) {
            return "The role “\(missing)” no longer exists."
        }
        if roles.isEmpty, !user.trimmingCharacters(in: .whitespaces).isEmpty, model.roles.isEmpty {
            return "Define a role first: viewing as another user only changes what USERNAME and USERPRINCIPALNAME return."
        }
        return nil
    }

    /// "Viewing as Sales West, Managers (anna@contoso.com)".
    static func viewAsSummary(roles: [String], user: String) -> String? {
        let u = user.trimmingCharacters(in: .whitespaces)
        if roles.isEmpty, u.isEmpty { return nil }
        var s = "Viewing as " + (roles.isEmpty ? "another user" : roles.joined(separator: ", "))
        if !u.isEmpty { s += " (\(u))" }
        return s
    }
}
