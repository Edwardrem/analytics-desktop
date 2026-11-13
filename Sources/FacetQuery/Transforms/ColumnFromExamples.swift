import Foundation
import FacetCore

/// "Column from examples": finds an M expression over a row that reproduces the values the user typed.
///
/// Candidates are tried from the simplest to the most specific — copy, case and trim, length, date parts,
/// text before/after/between delimiters, leading/trailing characters, simple arithmetic and two-column merges —
/// and each is checked by evaluating it with the M engine on the example rows, so the returned expression is
/// exactly what `Transform.addColumnFromExamples` will run.
public enum ColumnFromExamples {
    public struct Result: Sendable {
        /// Per-row M expression (the body of `each …`), e.g. `Text.Upper([Name])`.
        public var expression: String
        /// What the expression does, for the dialog ("Uppercase of Name").
        public var description: String
        /// The new column's values for every row of the preview.
        public var values: [Value]
    }

    /// `examples` maps row index → the text typed for that row. `columns` restricts the source columns (default: all).
    /// Returns nil when no candidate reproduces every example.
    public static func infer(table: DataTable, examples: [Int: String], columns: [String]? = nil) -> Result? {
        let wanted = examples.filter { $0.key >= 0 && $0.key < table.rowCount }
        guard !wanted.isEmpty else { return nil }
        let sources = table.columns.filter { columns?.contains($0.name) ?? true }
        let full = MTable(table)
        let exampleRows = wanted.keys.sorted()
        guard let sample = try? full.selecting(rows: exampleRows) else { return nil }
        let interpreter = MInterpreter()
        guard case .function(let addColumn)? = interpreter.library.values["Table.AddColumn"] else { return nil }

        func column(_ t: MTable, _ expression: String) -> [MValue]? {
            guard let f = try? interpreter.evaluate("each " + expression),
                  case .table(let out)? = try? interpreter.call(addColumn, [.table(t), .text("\u{1}result"), f]) else { return nil }
            return try? out.columns.last
        }
        func text(_ v: MValue) -> String? {
            let cell = v.forcedCell()
            if cell.isNull || cell.isError { return nil }
            return try? MConvert.text(cell, culture: "en-US")
        }
        for candidate in candidates(sources) {
            guard let got = column(sample, candidate.expression), got.count == exampleRows.count else { continue }
            let matches = zip(exampleRows, got).allSatisfy { row, value in text(value) == wanted[row] }
            guard matches, let all = column(full, candidate.expression) else { continue }
            return Result(expression: candidate.expression, description: candidate.description, values: all.map { $0.toValue() })
        }
        return nil
    }

    private static func candidates(_ columns: [DataColumn]) -> [(expression: String, description: String)] {
        var out: [(String, String)] = []
        let delimiters = [" ", ",", "-", "_", "/", ".", "@", ":", ";", "|"]
        let pairs = [("(", ")"), ("[", "]"), ("<", ">"), ("{", "}"), ("\"", "\"")]
        func q(_ s: String) -> String { MSyntax.text(s) }
        func shown(_ d: String) -> String { d == " " ? "space" : "\"\(d)\"" }
        for c in columns {
            let field = MSyntax.field(c.name), isText = c.type == .text || c.type == .any
            let asText = isText ? field : "Text.From(\(field))"
            out.append((field, "Copy of \(c.name)"))
            if !isText { out.append((asText, "\(c.name) as text")) }
            if c.type == .date || c.type == .dateTime {
                out += [("Date.Year(\(field))", "Year of \(c.name)"), ("Date.Month(\(field))", "Month of \(c.name)"), ("Date.Day(\(field))", "Day of \(c.name)"),
                        ("Date.MonthName(\(field))", "Month name of \(c.name)"), ("Date.DayOfWeekName(\(field))", "Day name of \(c.name)"),
                        ("Date.QuarterOfYear(\(field))", "Quarter of \(c.name)"), ("\"Q\" & Text.From(Date.QuarterOfYear(\(field)))", "Quarter label of \(c.name)"),
                        ("Date.DayOfYear(\(field))", "Day of year of \(c.name)"), ("Date.StartOfMonth(\(field))", "Start of month of \(c.name)"),
                        ("Date.EndOfMonth(\(field))", "End of month of \(c.name)")]
            }
            if c.type == .integer || c.type == .decimal || c.type == .currency {
                out += [("Number.Abs(\(field))", "Absolute value of \(c.name)"), ("Number.Round(\(field))", "\(c.name) rounded"),
                        ("\(field) * 2", "\(c.name) doubled"), ("\(field) * 100", "\(c.name) times 100"), ("\(field) / 100", "\(c.name) divided by 100"),
                        ("-\(field)", "\(c.name) negated")]
            }
            guard isText else { continue }
            let cases = [("Text.Upper", "Uppercase"), ("Text.Lower", "Lowercase"), ("Text.Proper", "Capitalized")]
            for (fn, label) in cases { out.append(("\(fn)(\(field))", "\(label) of \(c.name)")) }
            out.append(("Text.Trim(\(field))", "\(c.name) trimmed"))
            out.append(("Text.Length(\(field))", "Length of \(c.name)"))
            var extracts: [(String, String)] = []
            for d in delimiters {
                extracts.append(("Text.BeforeDelimiter(\(field), \(q(d)))", "Text before \(shown(d)) in \(c.name)"))
                extracts.append(("Text.AfterDelimiter(\(field), \(q(d)))", "Text after \(shown(d)) in \(c.name)"))
                extracts.append(("Text.AfterDelimiter(\(field), \(q(d)), {0, RelativePosition.FromEnd})", "Text after the last \(shown(d)) in \(c.name)"))
                extracts.append(("Text.BeforeDelimiter(\(field), \(q(d)), {0, RelativePosition.FromEnd})", "Text before the last \(shown(d)) in \(c.name)"))
                extracts.append(("Text.BetweenDelimiters(\(field), \(q(d)), \(q(d)))", "Text between \(shown(d)) and \(shown(d)) in \(c.name)"))
            }
            for (open, close) in pairs {
                extracts.append(("Text.BetweenDelimiters(\(field), \(q(open)), \(q(close)))", "Text between \"\(open)\" and \"\(close)\" in \(c.name)"))
            }
            for a in delimiters {
                for b in delimiters where a != b {
                    extracts.append(("Text.BetweenDelimiters(\(field), \(q(a)), \(q(b)))", "Text between \(shown(a)) and \(shown(b)) in \(c.name)"))
                }
            }
            for n in 1...10 {
                extracts.append(("Text.Start(\(field), \(n))", "First \(n) characters of \(c.name)"))
                extracts.append(("Text.End(\(field), \(n))", "Last \(n) characters of \(c.name)"))
            }
            out += extracts
            for (e, d) in extracts {
                for (fn, label) in cases { out.append(("\(fn)(\(e))", "\(label) of \(d.prefix(1).lowercased() + d.dropFirst())")) }
                out.append(("Text.Trim(\(e))", "\(d), trimmed"))
            }
        }
        for a in columns {
            for b in columns where a.name != b.name {
                func t(_ c: DataColumn) -> String { c.type == .text || c.type == .any ? MSyntax.field(c.name) : "Text.From(\(MSyntax.field(c.name)))" }
                for sep in [" ", "", ", ", "-", "_", "/", " - "] {
                    out.append(("Text.Combine({\(t(a)), \(t(b))}, \(q(sep)))", "\(a.name) and \(b.name) joined with \(sep.isEmpty ? "nothing" : "\"\(sep)\"")"))
                }
            }
        }
        return out
    }
}
