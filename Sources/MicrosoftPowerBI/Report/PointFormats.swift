import Foundation
import FacetCore

/// Dynamic format strings per data point, as Power BI applies them: a measure whose format string
/// is an expression ("IF(SELECTEDMEASURE() >= 1000, "#,0,K", "#,0")"), or a calculation item with
/// a format string on the visual's axis, can give each data point its own format. The visual's
/// format (evaluated under its filters) stays the default; a row gets its own only when the format
/// can depend on it, and only rows whose format differs make the visual store any.
enum PointFormats {
    /// Most rows given their own format strings; rows past it show the visual's format.
    static let maxRows = 2_000

    /// True when a format expression is the same in every context: nothing but text literals, joined
    /// with `&` and parentheses (`"#,0.00"`, `"0" & "%"`), once comments are left out.
    static func isConstant(_ expression: String) -> Bool {
        var rest = ""
        var chars = Array(expression)[...]
        while let c = chars.first {
            let next = chars.dropFirst().first
            if c == "\"" {
                chars = chars.dropFirst()
                // A text literal; "" inside it is one quote.
                while let d = chars.first {
                    chars = chars.dropFirst()
                    if d == "\"" {
                        if chars.first == "\"" { chars = chars.dropFirst() } else { break }
                    }
                }
            } else if (c == "/" && next == "/") || (c == "-" && next == "-") {
                while let d = chars.first, d != "\n" { chars = chars.dropFirst() }
            } else if c == "/" && next == "*" {
                chars = chars.dropFirst(2)
                while !chars.isEmpty, !(chars.first == "*" && chars.dropFirst().first == "/") { chars = chars.dropFirst() }
                chars = chars.dropFirst(2)
            } else {
                rest.append(c)
                chars = chars.dropFirst()
            }
        }
        return rest.allSatisfy { $0.isWhitespace || $0 == "&" || $0 == "(" || $0 == ")" }
    }

    /// The visual's grouping fields that are a calculation group's column with a formatted item.
    static func formattedCalculationGroups(_ groups: [FieldRef], model: SemanticModel) -> [Int] {
        groups.indices.filter { i in
            let g = groups[i]
            return g.kind == .column && model.calculationGroups.contains { cg in
                ModelDAX.same(cg.name, g.table) && ModelDAX.same(cg.columnName, g.name) && cg.items.contains { $0.formatExpression != nil }
            }
        }
    }

    /// A filter table keeping one value of a grouping field: one data point's row context.
    static func filter(_ field: FieldRef, _ value: Value) -> String {
        let ref = ModelDAX.reference(field)
        return value.isNull ? "FILTER(ALL(\(ref)), ISBLANK(\(ref)))" : "FILTER(ALL(\(ref)), \(ref) IN { \(ModelDAX.literal(value)) })"
    }

    /// Per value column whose format differs between rows, the format of each row (the first
    /// `maxRows`). The grouping fields are the result's first columns.
    /// - Parameters:
    ///   - visual: the format of each column under the visual's filters.
    ///   - evaluate: a measure's format string under extra filter tables (the engine's).
    static func formats(result: DataTable, groups: [FieldRef], values: [(column: Int, field: FieldRef)], visual: [String],
                        filters: [String], model: SemanticModel, evaluate: (String, [String]) -> String?) -> [Int: [String]] {
        guard !groups.isEmpty, groups.count <= result.columnCount, result.rowCount > 0 else { return [:] }
        let calculation = formattedCalculationGroups(groups, model: model)
        var out: [Int: [String]] = [:]
        for v in values where v.field.kind == .measure && v.column < result.columnCount {
            guard let measure = model.measure(v.field.name)?.measure else { continue }
            let own = measure.formatExpression.map { !isConstant($0) } ?? false
            guard own || !calculation.isEmpty else { continue }
            // Only the calculation items can change a constant format, so rows with the same items share it.
            let keys = own ? Array(groups.indices) : calculation
            let base = visual[safe: v.column] ?? measure.formatString
            var memo: [[Value]: String] = [:]
            var list: [String] = []
            for r in 0..<min(result.rowCount, maxRows) {
                let key = keys.map { result[r, $0] }
                if let known = memo[key] { list.append(known); continue }
                let format = evaluate(measure.name, filters + keys.map { filter(groups[$0], result[r, $0]) }) ?? base
                memo[key] = format
                list.append(format)
            }
            if list.contains(where: { $0 != base }) { out[v.column] = list }
        }
        return out
    }
}
