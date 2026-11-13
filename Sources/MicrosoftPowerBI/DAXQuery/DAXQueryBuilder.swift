import Foundation
import FacetCore

/// Generates the ready-made queries offered by the DAX query view, and finds measure dependencies.
enum DAXQueryBuilder {
    // MARK: Quoting

    static func tableRef(_ name: String) -> String { "'" + name.replacingOccurrences(of: "'", with: "''") + "'" }
    static func bracket(_ name: String) -> String { "[" + name.replacingOccurrences(of: "]", with: "]]") + "]" }
    static func columnRef(_ table: String, _ column: String) -> String { tableRef(table) + bracket(column) }
    static func string(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    // MARK: Tables

    static func topRows(_ table: String, count: Int = 100) -> String {
        "EVALUATE\n    TOPN(\(count), \(tableRef(table)))"
    }

    static func preview(_ table: String) -> String {
        "// Data preview: the first 1,000 rows of \(table)\nEVALUATE\n    TOPN(1000, \(tableRef(table)))"
    }

    /// One summary row per column: minimum, maximum, distinct count, blanks and row count.
    static func tableStatistics(_ table: ModelTable) -> String {
        let t = tableRef(table.name)
        let rows = table.columns.map { c -> String in
            let ref = columnRef(table.name, c.name)
            // Minimum and maximum are shown as text so columns of different types can share one result column.
            let comparable = c.dataType != .boolean && c.dataType != .binary
            let lo = comparable ? "\"\" & MIN(\(ref))" : "BLANK()"
            let hi = comparable ? "\"\" & MAX(\(ref))" : "BLANK()"
            return "ROW(\"Column\", \(string(c.name)), \"Min\", \(lo), \"Max\", \(hi), "
                + "\"Distinct count\", DISTINCTCOUNT(\(ref)), \"Blanks\", COUNTBLANK(\(ref)), \"Rows\", COUNTROWS(\(t)))"
        }
        guard !rows.isEmpty else { return "EVALUATE\n    ROW(\"Rows\", COUNTROWS(\(t)))" }
        if rows.count == 1 { return "EVALUATE\n    \(rows[0])" }
        return "EVALUATE\n    UNION(\n" + rows.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
    }

    // MARK: Columns

    static func distinctValues(table: String, column: String) -> String {
        """
        EVALUATE
            SUMMARIZECOLUMNS(
                \(columnRef(table, column)),
                "Count", COUNTROWS(\(tableRef(table)))
            )
            ORDER BY [Count] DESC
        """
    }

    static func columnStatistics(table: String, column: ModelColumn) -> String {
        let ref = columnRef(table, column.name)
        var parts: [String] = []
        if column.dataType != .boolean && column.dataType != .binary {
            parts.append("\"Min\", MIN(\(ref))")
            parts.append("\"Max\", MAX(\(ref))")
        }
        parts.append("\"Distinct count\", DISTINCTCOUNT(\(ref))")
        parts.append("\"Blanks\", COUNTBLANK(\(ref))")
        parts.append("\"Rows\", COUNTROWS(\(tableRef(table)))")
        return "EVALUATE\n    ROW(\n" + parts.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
    }

    // MARK: Measures

    static func evaluate(measures names: [String]) -> String {
        let args = names.map { "\(string($0)), \(bracket($0))" }
        if args.count <= 1 { return "EVALUATE\n    ROW(\(args.first ?? "\"Value\", BLANK()"))" }
        return "EVALUATE\n    ROW(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
    }

    /// `MEASURE 'Table'[Name] = expression`, with `///` description lines, indented for a `DEFINE` block.
    static func measureDefinition(table: String, measure: Measure) -> String {
        var lines: [String] = []
        for d in measure.description.components(separatedBy: .newlines) where !d.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("    /// " + d.trimmingCharacters(in: .whitespaces))
        }
        let expr = DAXText.normalize(measure.expression)
        let head = "    MEASURE \(columnRef(table, measure.name)) ="
        if expr.contains("\n") {
            lines.append(head)
            lines.append(contentsOf: expr.components(separatedBy: "\n").map { $0.isEmpty ? "" : "        " + $0 })
        } else {
            lines.append(head + " " + expr)
        }
        return lines.joined(separator: "\n")
    }

    static func define(_ measures: [(table: String, measure: Measure)], evaluate names: [String]) -> String {
        guard !measures.isEmpty else { return evaluate(measures: names) }
        return "DEFINE\n" + measures.map { measureDefinition(table: $0.table, measure: $0.measure) }.joined(separator: "\n\n")
            + "\n\n" + evaluate(measures: names)
    }

    static func defineAndEvaluate(table: String, measure: Measure) -> String {
        define([(table, measure)], evaluate: [measure.name])
    }

    /// Defines the measure and, before it, every measure it depends on (transitively).
    static func defineWithReferences(table: String, measure: Measure, model: SemanticModel) -> String {
        define(dependencyClosure(of: measure.name, model: model), evaluate: [measure.name])
    }

    static func defineAll(model: SemanticModel) -> String {
        let all = model.allMeasures.map { (table: $0.table, measure: $0.measure) }
        return define(all, evaluate: all.map(\.measure.name))
    }

    // MARK: Reference discovery

    /// Names of model measures referenced directly by `expression`, in order of first appearance.
    /// A `[Name]` token counts when it matches a model measure and is not a column of the table qualifying it.
    static func measureReferences(in expression: String, model: SemanticModel) -> [String] {
        let tokens = DAXLexer.tokens(expression)
        var seen = Set<String>()
        var out: [String] = []
        for (i, t) in tokens.enumerated() where t.kind == .bracket {
            var qualifier: String?
            if i > 0 {
                let p = tokens[i - 1]
                if p.end == t.start, p.kind == .quotedName || p.kind == .word { qualifier = p.text }
            }
            var found: Measure?
            if let q = qualifier, let table = model.table(q) {
                found = table.measure(t.text)
                if found == nil, table.column(t.text) == nil { found = model.measure(t.text)?.measure }
            } else {
                found = model.measure(t.text)?.measure
            }
            if let m = found, seen.insert(m.name.lowercased()).inserted { out.append(m.name) }
        }
        return out
    }

    /// The measure and everything it references, dependencies first. Cycles are visited once.
    static func dependencyClosure(of name: String, model: SemanticModel) -> [(table: String, measure: Measure)] {
        var visited = Set<String>()
        var out: [(table: String, measure: Measure)] = []
        func visit(_ n: String) {
            guard let hit = model.measure(n), visited.insert(hit.measure.name.lowercased()).inserted else { return }
            for dep in measureReferences(in: hit.measure.expression, model: model) { visit(dep) }
            out.append((hit.table.name, hit.measure))
        }
        visit(name)
        return out
    }

    // MARK: INFO helpers

    static let infoQueries: [(title: String, query: String)] = [
        ("Tables", "EVALUATE\n    INFO.VIEW.TABLES()"),
        ("Columns", "EVALUATE\n    INFO.VIEW.COLUMNS()"),
        ("Measures", "EVALUATE\n    INFO.VIEW.MEASURES()"),
        ("Relationships", "EVALUATE\n    INFO.VIEW.RELATIONSHIPS()"),
        ("Functions", "EVALUATE\n    INFO.FUNCTIONS()"),
        ("Calculation groups", "EVALUATE\n    INFO.CALCULATIONGROUPS()"),
        ("Roles", "EVALUATE\n    INFO.ROLES()"),
    ]
}
