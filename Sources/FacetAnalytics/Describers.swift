import Foundation
import FacetCore

/// Produces a compact, deterministic text description of a semantic model for use as LLM grounding context.
public enum ModelDescriber {
    /// - Parameters:
    ///   - model: the semantic model.
    ///   - excluding: identifiers hidden from AI ("Table", "Table[Column]", "Table[Measure]"); defaults to `model.aiExcludedFields`.
    ///   - includeHidden: include hidden tables / columns / measures (marked "hidden").
    ///   - maxExpressionLength: measure and calculated-column expressions are truncated to this many characters.
    ///   - answerVisuals: for verified answers tied to a visual, a short description of that visual by its id
    ///     (for example `"Sales by region" on page "Overview"`).
    public static func schemaSummary(model: SemanticModel, excluding: [String]? = nil, includeHidden: Bool = false,
                                     maxExpressionLength: Int = 240, answerVisuals: [UUID: String] = [:]) -> String {
        let excluded = Set((excluding ?? model.aiExcludedFields).map(normalise))
        func isExcluded(_ table: String, _ field: String? = nil) -> Bool {
            if excluded.contains(normalise(table)) { return true }
            guard let field else { return false }
            return excluded.contains(normalise("\(table)[\(field)]"))
        }
        func oneLine(_ s: String) -> String {
            let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            return flat.count > maxExpressionLength ? String(flat.prefix(maxExpressionLength)) + "…" : flat
        }
        var lines: [String] = ["Model: \(model.name)"]
        var keptTables = Set<String>()
        for t in model.tables {
            if isExcluded(t.name) || (t.isHidden && !includeHidden) { continue }
            keptTables.insert(t.name)
            var head = "Table \(t.name)"
            var notes: [String] = []
            if t.isDateTable { notes.append("date table") }
            if t.isHidden { notes.append("hidden") }
            if t.storageMode != .import { notes.append(t.storageMode.rawValue) }
            if !notes.isEmpty { head += " (\(notes.joined(separator: ", ")))" }
            if !t.description.isEmpty { head += " — \(oneLine(t.description))" }
            if !t.synonyms.isEmpty { head += " [aka \(t.synonyms.joined(separator: ", "))]" }
            lines.append(head)
            let cols = t.columns.filter { !isExcluded(t.name, $0.name) && (!$0.isHidden || includeHidden) }
            if !cols.isEmpty {
                let parts = cols.map { c -> String in
                    var s = "\(c.name):\(c.dataType.rawValue)"
                    var tags: [String] = []
                    if c.isKey { tags.append("key") }
                    if c.dataType.isNumeric, c.summarizeBy != .sum { tags.append(c.summarizeBy == .none ? "no-agg" : c.summarizeBy.rawValue) }
                    if c.dataCategory != .uncategorized { tags.append(c.dataCategory.rawValue) }
                    if c.isHidden { tags.append("hidden") }
                    if !c.synonyms.isEmpty { tags.append("aka " + c.synonyms.joined(separator: "/")) }
                    if !tags.isEmpty { s += "(\(tags.joined(separator: ",")))" }
                    if let e = c.expression { s += " = \(oneLine(e))" }
                    if !c.description.isEmpty { s += " — \(oneLine(c.description))" }
                    return s
                }
                lines.append("  columns: " + parts.joined(separator: "; "))
            }
            for m in t.measures where !isExcluded(t.name, m.name) && (!m.isHidden || includeHidden) {
                var s = "  measure [\(m.name)] = \(oneLine(m.expression))"
                if !m.formatString.isEmpty { s += " {\(m.formatString)}" }
                if !m.description.isEmpty { s += " — \(oneLine(m.description))" }
                lines.append(s)
            }
            for h in t.hierarchies where !h.isHidden { lines.append("  hierarchy \(h.name): \(h.levels.joined(separator: " > "))") }
        }
        let rels = model.relationships.filter { keptTables.contains($0.fromTable) && keptTables.contains($0.toTable)
            && !isExcluded($0.fromTable, $0.fromColumn) && !isExcluded($0.toTable, $0.toColumn) }
        if !rels.isEmpty {
            lines.append("Relationships:")
            for r in rels {
                let card: String
                switch r.cardinality { case .manyToOne: card = "*:1"; case .oneToOne: card = "1:1"; case .oneToMany: card = "1:*"; case .manyToMany: card = "*:*" }
                var s = "  \(r.fromTable)[\(r.fromColumn)] \(card) \(r.toTable)[\(r.toColumn)]"
                if r.crossFilter == .both { s += " both-directions" }
                if !r.isActive { s += " inactive" }
                lines.append(s)
            }
        }
        let instructions = model.aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty { lines.append("Instructions: \(instructions)") }
        let answers = model.verifiedAnswers.filter { !$0.question.isEmpty }
        if !answers.isEmpty {
            lines.append("Verified answers:")
            for a in answers {
                var line = "  Q: \(oneLine(a.question))"
                if !a.answer.isEmpty { line += " → A: \(oneLine(a.answer))" }
                if let id = a.visualID, let visual = answerVisuals[id] { line += " (answered by the visual \(visual))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func normalise(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
    }
}

/// Produces a compact text digest of a report page (its visuals and their top values) for LLM grounding.
public enum ReportDescriber {
    /// - Parameters:
    ///   - page: the page to describe.
    ///   - visualData: query results by visual id; visuals without data are described by their fields only.
    ///   - maxRows: data rows listed per visual.
    public static func describe(page: Page, visualData: [UUID: VisualData], maxRows: Int = 5) -> String {
        var lines: [String] = ["Page: \(page.name)"]
        if !page.filters.isEmpty { lines.append("Page filters: " + page.filters.filter { !$0.isEmpty }.map(describe).joined(separator: "; ")) }
        let visuals = page.visuals.filter { !$0.isHidden }.sorted { a, b in
            if a.frame.y != b.frame.y { return a.frame.y < b.frame.y }
            if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
            return a.name < b.name
        }
        for v in visuals { lines += describe(visual: v, data: visualData[v.id], maxRows: maxRows) }
        return lines.joined(separator: "\n")
    }

    /// A digest of every page a reader can open (hidden and tooltip pages are left out), in page order.
    /// - Parameter visualData: query results for the visuals of every described page, by visual id.
    public static func describe(report: Report, visualData: [UUID: VisualData], maxRows: Int = 3) -> String {
        let pages = report.pages.filter { !$0.isHidden && !$0.isTooltipPage }
        var lines = ["Report: \(pages.count) \(pages.count == 1 ? "page" : "pages")"]
        let filters = report.filters.filter { !$0.isEmpty }
        if !filters.isEmpty { lines.append("Report filters: " + filters.map(describe).joined(separator: "; ")) }
        for p in pages { lines.append(""); lines.append(describe(page: p, visualData: visualData, maxRows: maxRows)) }
        return lines.joined(separator: "\n")
    }

    /// The lines describing one visual: a header with its type, title and fields, then its top data rows.
    /// Images, shapes, buttons and navigators (and empty text boxes) produce no lines.
    public static func describe(visual v: VisualSpec, data: VisualData?, maxRows: Int = 5) -> [String] {
        let title = v.fmtString("title", "text", v.name)
        var line = "- [\(v.type.displayName)] \(title)"
        switch v.type {
        case .textBox:
            let text = v.content.split(whereSeparator: \.isNewline).joined(separator: " ")
            if text.isEmpty { return [] }
            return [line + ": " + (text.count > 200 ? String(text.prefix(200)) + "…" : text)]
        case .image, .shape, .button, .pageNavigator, .bookmarkNavigator: return []
        default: break
        }
        var lines: [String] = []
        let wells = v.type.wells.compactMap { w -> String? in
            let f = v.fields(w)
            return f.isEmpty ? nil : "\(w.displayName)=\(f.map(\.caption).joined(separator: ", "))"
        }
        if !wells.isEmpty { line += " | " + wells.joined(separator: "; ") }
        let active = v.filters.filter { !$0.isEmpty }
        if !active.isEmpty { line += " | filters: " + active.map(describe).joined(separator: "; ") }
        if let s = v.slicerState, s.isActive {
            if !s.selected.isEmpty { line += " | selected: " + s.selected.prefix(8).map { Fmt.label($0) }.joined(separator: ", ") }
            if !s.rangeLow.isNull || !s.rangeHigh.isNull { line += " | range: \(Fmt.label(s.rangeLow))…\(Fmt.label(s.rangeHigh))" }
        }
        lines.append(line)
        guard let data else { return lines }
        if let err = data.error { lines.append("  error: \(err)"); return lines }
        let t = data.table
        guard t.rowCount > 0, t.columnCount > 0 else { lines.append("  (no data)"); return lines }
        let names = (0..<t.columnCount).map { data.fields[safe: $0].flatMap { $0 }?.caption ?? t.columns[$0].name }
        if t.rowCount == 1 {
            lines.append("  " + (0..<t.columnCount).map { "\(names[$0])=\(data.formatted(row: 0, col: $0))" }.joined(separator: ", "))
            return lines
        }
        // Order rows by the first numeric column, largest first, unless the first column is a time axis.
        let measure = (0..<t.columnCount).first { c in
            (data.fields[safe: c].flatMap { $0 }?.isAggregate ?? t.columns[c].type.isNumeric) && t.columns[c].values.contains { $0.isNumber }
        }
        var order = Array(0..<t.rowCount)
        let timeAxis = SmartNarrative.isTimeAxis(t.columns[0])
        if let m = measure, !timeAxis { order.sort { (t[$0, m].asDouble ?? -.infinity) > (t[$1, m].asDouble ?? -.infinity) } }
        lines.append("  " + names.joined(separator: " | "))
        let shown = timeAxis && order.count > maxRows ? Array(order.suffix(maxRows)) : Array(order.prefix(maxRows))
        for r in shown { lines.append("  " + (0..<t.columnCount).map { data.formatted(row: r, col: $0) }.joined(separator: " | ")) }
        if t.rowCount > shown.count { lines.append("  … \(t.rowCount) rows in total" + (timeAxis ? " (latest shown)" : " (top shown)")) }
        let totals = (0..<t.columnCount).compactMap { c -> String? in
            guard let v = data.totals[safe: c], !v.isNull else { return nil }
            return "\(names[c])=\(ValueFormatter.format(v, data.formats[safe: c] ?? ""))"
        }
        if !totals.isEmpty { lines.append("  totals: " + totals.joined(separator: ", ")) }
        return lines
    }

    /// One-line description of a filter.
    public static func describe(_ f: FilterSpec) -> String {
        let name = f.displayName ?? f.field.caption
        switch f.kind {
        case .basic:
            let vals = f.values.prefix(6).map { Fmt.label($0) }.joined(separator: ", ") + (f.values.count > 6 ? ", …" : "")
            return "\(name) \(f.isInverted ? "is not" : "is") \(vals)"
        case .advanced:
            return name + " " + f.conditions.map { $0.op.needsValue ? "\($0.op.displayName) \(Fmt.label($0.value))" : $0.op.displayName }
                .joined(separator: f.conditionsUseOr ? " or " : " and ")
        case .topN:
            return "\(f.topN.isBottom ? "bottom" : "top") \(f.topN.count) \(name)" + (f.topN.by.map { " by \($0.caption)" } ?? "")
        case .relativeDate, .relativeTime:
            let r = f.relative
            return "\(name) in the \(r.direction.rawValue) \(r.count) \(r.unit.rawValue)"
        }
    }
}
