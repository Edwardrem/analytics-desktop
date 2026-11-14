import Foundation
import FacetCore

// MARK: - Aggregations (`alternateOf`)

/// Aggregation mappings in their Tabular form: an `alternateOf` object on each column of the aggregation
/// table, naming the detail column (or, to count rows, the detail table) and the summarization.
///
/// The model's `Facet_aggregations` annotation still lists every mapping in order, with its id; the
/// entries also written as `alternateOf` carry `"alternateOf": true`. A reader can then tell a file that
/// predates `alternateOf` (keep the annotation's entry) from one where the `alternateOf` was removed
/// (drop it), and the `alternateOf` wins over the annotation wherever both exist.
enum TMDLAggregations {
    /// The Tabular summarization, or nil where Tabular has none (Facet's average, median and the like).
    static func summarization(_ m: AggregationMapping) -> String? {
        guard !m.detailTable.isEmpty else { return nil }
        let column = !m.detailColumn.isEmpty
        switch m.summarization {
        case .none: return column ? "groupBy" : nil
        case .sum: return column ? "sum" : nil
        case .min: return column ? "min" : nil
        case .max: return column ? "max" : nil
        case .count: return "count"             // without a detail column: count the detail table's rows
        default: return nil
        }
    }

    static func key(_ table: String, _ column: String) -> String { table.lowercased() + "\u{1F}" + column.lowercased() }

    /// The mappings written as `alternateOf`, by aggregation column: the first mapping of each column that
    /// Tabular can express and whose tables and columns exist.
    static func native(in model: SemanticModel) -> [String: AggregationMapping] {
        var out: [String: AggregationMapping] = [:]
        for m in model.aggregations where summarization(m) != nil {
            let k = key(m.aggTable, m.aggColumn)
            guard out[k] == nil, model.table(m.aggTable)?.column(m.aggColumn) != nil, let detail = model.table(m.detailTable),
                  m.detailColumn.isEmpty || detail.column(m.detailColumn) != nil else { continue }
            out[k] = m
        }
        return out
    }

    static func emit(_ e: TMDLEmitter, _ l: Int, _ m: AggregationMapping) {
        guard let s = summarization(m) else { return }
        e.raw(l, "alternateOf")
        if m.detailColumn.isEmpty { e.prop(l + 1, "baseTable", TMDLName.quote(m.detailTable)) }
        else { e.prop(l + 1, "baseColumn", TMDLName.qualified(m.detailTable, m.detailColumn)) }
        e.prop(l + 1, "summarization", s)
    }

    /// `Facet_aggregations`: every mapping, with those written natively flagged.
    static func annotation(_ mappings: [AggregationMapping], native: Set<UUID>) -> JSONValue? {
        guard case .array(let items)? = try? JSONValue(encoding: mappings) else { return nil }
        return .array(zip(items, mappings).map { item, m in
            guard native.contains(m.id), case .object(var o) = item else { return item }
            o["alternateOf"] = .bool(true)
            return .object(o)
        })
    }

    /// Ids of the annotation's entries that were also written as `alternateOf`.
    static func flagged(in annotation: JSONValue?) -> Set<UUID> {
        Set((annotation?.arrayValue ?? []).compactMap { item in
            item["alternateOf"]?.boolValue == true ? item["id"]?.stringValue.flatMap(UUID.init(uuidString:)) : nil
        })
    }

    /// Reads a column's `alternateOf`; the message explains one that can't be used.
    static func parse(_ node: TMDLNode, table: String, column: String) -> (AggregationMapping?, problem: String?) {
        let s = node.prop("summarization")?.lowercased() ?? ""
        let summarization: Aggregation
        switch s {
        case "groupby": summarization = .none
        case "sum": summarization = .sum
        case "min": summarization = .min
        case "max": summarization = .max
        case "count": summarization = .count
        default: return (nil, "Ignored alternateOf on \(table)[\(column)]: summarization “\(s)” isn't supported.")
        }
        if let base = node.prop("baseColumn") {
            let parts = TMDLName.splitQualified(base)
            guard parts.count == 2 else { return (nil, "Ignored alternateOf on \(table)[\(column)]: baseColumn must be Table.Column.") }
            return (AggregationMapping(aggTable: table, aggColumn: column, summarization: summarization, detailTable: parts[0], detailColumn: parts[1]), nil)
        }
        if let base = node.prop("baseTable"), summarization == .count {
            return (AggregationMapping(aggTable: table, aggColumn: column, summarization: .count, detailTable: TMDLName.unquote(base), detailColumn: ""), nil)
        }
        return (nil, "Ignored alternateOf on \(table)[\(column)]: it needs a baseColumn, or a baseTable to count rows.")
    }

    /// A table node's columns, each with its `alternateOf` if it has one, and messages for those that can't be used.
    static func columns(of node: TMDLNode, table: String) -> (columns: [(name: String, native: AggregationMapping?)], problems: [(String, TMDLNode)]) {
        var columns: [(name: String, native: AggregationMapping?)] = []
        var problems: [(String, TMDLNode)] = []
        for c in node.children("column") {
            guard let a = c.children("alternateOf").first else { columns.append((c.name, nil)); continue }
            let (m, problem) = parse(a, table: table, column: c.name)
            columns.append((c.name, m))
            if let problem { problems.append((problem, a)) }
            for p in a.properties where !["basecolumn", "basetable", "summarization"].contains(p.key.lowercased()) {
                problems.append(("Ignored alternateOf property “\(p.key)”.", a))
            }
        }
        return (columns, problems)
    }

    /// What a reader remembers between files.
    struct ReadState {
        /// Applying a script to a model in memory: there are no flags, and every mapping Tabular can express
        /// would have been written as `alternateOf`, so one that's missing from a scripted column was removed.
        var scriptMode = false
        var flagged = Set<UUID>()
        /// `alternateOf`s with no annotation entry, placed in table order once every file is read.
        var pending: [AggregationMapping] = []
    }

    /// Brings `model.aggregations` in line with the columns of one table node (each with its `alternateOf`, if any).
    static func reconcile(table: String, columns: [(name: String, native: AggregationMapping?)],
                          model: inout SemanticModel, state: inout ReadState) {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        for (column, native) in columns {
            let mine = model.aggregations.indices.filter { same(model.aggregations[$0].aggTable, table) && same(model.aggregations[$0].aggColumn, column) }
            let match = mine.first { state.flagged.contains(model.aggregations[$0].id) }
                ?? mine.first { summarization(model.aggregations[$0]) != nil }
            if var n = native {
                if let i = match {
                    n.id = model.aggregations[i].id
                    model.aggregations[i] = n
                } else if state.scriptMode {
                    model.aggregations.append(n)
                } else {
                    state.pending.append(n)
                }
            } else if let i = match, state.scriptMode || state.flagged.contains(model.aggregations[i].id) {
                model.aggregations.remove(at: i)
            }
        }
    }

    /// Appends the `alternateOf`s that had no annotation entry, in table and column order.
    static func finish(_ model: inout SemanticModel, state: inout ReadState) {
        guard !state.pending.isEmpty else { return }
        func rank(_ m: AggregationMapping) -> (Int, Int) {
            guard let t = model.tableIndex(m.aggTable) else { return (Int.max, Int.max) }
            return (t, model.tables[t].columns.firstIndex { $0.name.caseInsensitiveCompare(m.aggColumn) == .orderedSame } ?? Int.max)
        }
        model.aggregations += state.pending.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        state.pending = []
    }
}

// MARK: - Incremental refresh (`refreshPolicy`)

/// An incremental refresh policy as a Tabular `refreshPolicy`. The partition column isn't a property in
/// Tabular: it is the column the source query filters with `RangeStart`, so it is read from there, and
/// kept in a `Facet_refreshPolicyDateColumn` annotation only when the query doesn't say.
enum TMDLRefreshPolicy {
    static let dateColumnAnnotation = "refreshPolicyDateColumn"
    static let properties: Set<String> = ["policytype", "rollingwindowgranularity", "rollingwindowperiods", "incrementalgranularity",
                                          "incrementalperiods", "incrementalperiodsoffset", "mode"]
    static let expressions: Set<String> = ["pollingexpression", "sourceexpression"]

    /// Writes the policy; `source` is the M of the table's partition, if it has one.
    static func emit(_ e: TMDLEmitter, _ l: Int, _ p: IncrementalRefreshPolicy, source: String?, table: String) {
        e.raw(l, "refreshPolicy")
        e.prop(l + 1, "policyType", "basic")
        e.prop(l + 1, "rollingWindowGranularity", p.archiveUnit)
        e.prop(l + 1, "rollingWindowPeriods", String(p.archiveCount))
        e.prop(l + 1, "incrementalGranularity", p.refreshUnit)
        e.prop(l + 1, "incrementalPeriods", String(p.refreshCount))
        // Tabular's "only refresh complete periods": the refreshed range ends one period before the current one.
        if p.onlyCompletePeriods { e.prop(l + 1, "incrementalPeriodsOffset", "-1") }
        // Hybrid: the latest period is a DirectQuery partition.
        if p.realTimeDirectQuery { e.prop(l + 1, "mode", "hybrid") }
        if let c = p.detectChangesColumn { e.expression(l + 1, "pollingExpression", pollingExpression(column: c, source: source, table: table)) }
        if let source { e.expression(l + 1, "sourceExpression", source) }
    }

    /// True when the date column has to be written down because the source doesn't filter on it.
    static func needsDateColumnAnnotation(_ p: IncrementalRefreshPolicy, source: String?) -> Bool {
        source.flatMap(dateColumn(filteredIn:)) != p.dateColumn
    }

    /// Reads a `refreshPolicy`. `partitionSource` is the table's partition M; `annotatedDateColumn` the Facet annotation.
    static func parse(_ node: TMDLNode, partitionSource: String?, annotatedDateColumn: String?) -> (IncrementalRefreshPolicy, problems: [String]) {
        var problems: [String] = []
        let source = node.expr("sourceExpression") ?? partitionSource
        let date = annotatedDateColumn ?? source.flatMap(dateColumn(filteredIn:))
        if date == nil { problems.append("The refresh policy's source doesn't filter a column with RangeStart; choose the date column again.") }
        var p = IncrementalRefreshPolicy(dateColumn: date ?? "")
        if let v = node.prop("rollingWindowGranularity") { p.archiveUnit = v.lowercased() }
        if let v = node.prop("rollingWindowPeriods").flatMap({ Int($0) }) { p.archiveCount = v }
        if let v = node.prop("incrementalGranularity") { p.refreshUnit = v.lowercased() }
        if let v = node.prop("incrementalPeriods").flatMap({ Int($0) }) { p.refreshCount = v }
        p.onlyCompletePeriods = (node.prop("incrementalPeriodsOffset").flatMap { Int($0) } ?? 0) < 0
        p.realTimeDirectQuery = node.prop("mode")?.lowercased() == "hybrid"
        if let polling = node.expr("pollingExpression") {
            if let c = maxColumn(in: polling) { p.detectChangesColumn = c }
            else { problems.append("The refresh policy's polling expression isn't List.Max of a column; detect data changes is off.") }
        }
        if let t = node.prop("policyType"), t.lowercased() != "basic" { problems.append("Refresh policy type “\(t)” isn't supported; read as basic.") }
        return (p, problems)
    }

    // MARK: M

    /// `[Name]`, or `[#"Name"]` when the name isn't a plain identifier.
    static func field(_ name: String) -> String {
        let plain = name.first.map { $0.isLetter || $0 == "_" } == true && name.last.map { $0 != " " } == true
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == " " }
        return plain ? "[\(name)]" : "[#\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"]"
    }

    /// The latest value of the column, which the service compares between refreshes. With the partition's M
    /// the expression reads the source itself, as Power BI's does; without one it names the table's query.
    static func pollingExpression(column: String, source: String?, table: String) -> String {
        guard let source else { return "List.Max(#\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + field(column) + ")" }
        // The source stays as written (indenting it would change multi-line text literals in it), and the
        // comma has a line of its own so a trailing comment can't swallow it.
        return "let\n    Source =\n\(source)\n    ,\n    MaxValue = List.Max(Source\(field(column)))\nin\n    MaxValue"
    }

    private static let fieldPattern = #"\[\s*(#"(?:[^"]|"")*"|(?:[^\]\[]|\]\])+?)\s*\]"#

    private static func unescapeField(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#\""), t.hasSuffix("\""), t.count >= 3 {
            return String(t.dropFirst(2).dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return t.replacingOccurrences(of: "]]", with: "]")
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return unescapeField(String(s[r]))
    }

    /// The column a query compares with `RangeStart` (`each [Order Date] >= RangeStart and …`).
    static func dateColumn(filteredIn m: String) -> String? {
        firstMatch(fieldPattern + #"\s*>=?\s*RangeStart\b"#, in: m)
    }

    /// The column in the last `List.Max(…[Column])` of a polling expression.
    static func maxColumn(in m: String) -> String? {
        guard let start = m.range(of: "List.Max(", options: .backwards) else { return nil }
        var depth = 1, inText = false
        var i = start.upperBound
        while i < m.endIndex {
            let ch = m[i]
            if ch == "\"" { inText.toggle() }
            else if !inText, ch == "(" { depth += 1 }
            else if !inText, ch == ")" { depth -= 1; if depth == 0 { break } }
            i = m.index(after: i)
        }
        guard depth == 0 else { return nil }
        let inner = String(m[start.upperBound..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
        return firstMatch(fieldPattern + #"\s*$"#, in: inner)
    }
}
