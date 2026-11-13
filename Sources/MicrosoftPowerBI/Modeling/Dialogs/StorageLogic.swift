import Foundation
import FacetCore

/// Incremental refresh policies: validation, the RangeStart/RangeEnd parameters and the date windows a policy means.
enum IncrementalRefreshLogic {
    static let units = ["day", "month", "quarter", "year"]
    static let parameterNames = ["RangeStart", "RangeEnd"]

    static func unitTitle(_ unit: String, count: Int) -> String {
        let base: String
        switch unit {
        case "day": base = "day"
        case "month": base = "month"
        case "quarter": base = "quarter"
        default: base = "year"
        }
        return count == 1 ? base : base + "s"
    }
    private static func months(_ unit: String) -> Int? {
        switch unit {
        case "month": return 1
        case "quarter": return 3
        case "year": return 12
        default: return nil
        }
    }
    /// Approximate length in days, for comparing periods of different units.
    static func approximateDays(count: Int, unit: String) -> Double {
        switch unit {
        case "day": return Double(count)
        case "month": return Double(count) * 30.4375
        case "quarter": return Double(count) * 91.3125
        default: return Double(count) * 365.25
        }
    }

    /// Real-time data needs whole periods in the import partitions.
    static func normalized(_ p: IncrementalRefreshPolicy) -> IncrementalRefreshPolicy {
        var p = p
        if p.realTimeDirectQuery { p.onlyCompletePeriods = true }
        if let c = p.detectChangesColumn, c.isEmpty { p.detectChangesColumn = nil }
        return p
    }

    /// RangeStart / RangeEnd parameters the document doesn't have yet (they must be Date/Time parameters).
    static func missingParameters(_ queries: [QueryDefinition]) -> [String] {
        parameterNames.filter { name in
            !queries.contains { $0.kind == .parameter && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// A Date/Time parameter query, as the Power Query editor writes it.
    static func parameterQuery(_ name: String, value: Date) -> QueryDefinition {
        let c = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        let literal = "#datetime(\(c.year ?? 2000), \(c.month ?? 1), \(c.day ?? 1), \(c.hour ?? 0), \(c.minute ?? 0), \(c.second ?? 0))"
        var q = QueryDefinition(name: name, mScript: "\(literal) meta [IsParameterQuery=true, Type=\"DateTime\", IsParameterQueryRequired=true]")
        q.kind = .parameter
        q.loadEnabled = false
        var parameter = QueryParameter()
        parameter.type = .dateTime
        parameter.currentValue = .date(value)
        parameter.defaultValue = .date(value)
        q.parameter = parameter
        return q
    }

    /// The filter step the table's query needs so the service can partition it.
    static func filterStep(column: String, previousStep: String = "Source") -> String {
        let field = "[" + column.replacingOccurrences(of: "]", with: "]]") + "]"
        return "Table.SelectRows(\(previousStep), each \(field) >= RangeStart and \(field) < RangeEnd)"
    }

    /// True when a query's script filters on both parameters.
    static func queryUsesRange(_ script: String) -> Bool {
        script.range(of: "RangeStart", options: .caseInsensitive) != nil && script.range(of: "RangeEnd", options: .caseInsensitive) != nil
    }

    static func problems(_ policy: IncrementalRefreshPolicy, table: ModelTable) -> [String] {
        var out: [String] = []
        if table.isCalculated { out.append("\(table.name) is a calculated table. Incremental refresh needs a table loaded by a query.") }
        if policy.dateColumn.isEmpty {
            out.append("Choose the date column that partitions \(table.name).")
        } else if let c = table.column(policy.dateColumn) {
            if !(c.dataType == .date || c.dataType == .dateTime) {
                out.append("\(policy.dateColumn) is \(c.dataType.displayName.lowercased()). The partition column must be Date or Date/Time.")
            }
            if c.isCalculated { out.append("\(policy.dateColumn) is a calculated column. The partition column must come from the source.") }
        } else {
            out.append("“\(policy.dateColumn)” is not a column of \(table.name).")
        }
        if policy.archiveCount < 1 { out.append("Archive at least 1 \(unitTitle(policy.archiveUnit, count: 1)).") }
        if policy.refreshCount < 1 { out.append("Refresh at least 1 \(unitTitle(policy.refreshUnit, count: 1)).") }
        if !units.contains(policy.archiveUnit) || !units.contains(policy.refreshUnit) { out.append("Periods are counted in days, months, quarters or years.") }
        if policy.archiveCount >= 1, policy.refreshCount >= 1,
           approximateDays(count: policy.refreshCount, unit: policy.refreshUnit) > approximateDays(count: policy.archiveCount, unit: policy.archiveUnit) {
            out.append("The refresh period can't be longer than the archive period.")
        }
        if let d = policy.detectChangesColumn, !d.isEmpty {
            if let c = table.column(d) {
                if !(c.dataType == .date || c.dataType == .dateTime) { out.append("Detect data changes needs a Date/Time column; \(d) is \(c.dataType.displayName.lowercased()).") }
            } else {
                out.append("“\(d)” is not a column of \(table.name).")
            }
        }
        return out
    }

    struct Windows: Equatable {
        /// First instant kept in the model.
        var archiveStart: Date
        /// First instant that is re-loaded on every refresh.
        var refreshStart: Date
        /// End of the refreshed range (exclusive).
        var end: Date
    }

    private static func startOfPeriod(_ date: Date, unit: String) -> Date {
        let cal = Calendar.utc
        var c = cal.dateComponents([.year, .month, .day], from: date)
        switch unit {
        case "day": break
        case "month": c.day = 1
        case "quarter": c.day = 1; c.month = (((c.month ?? 1) - 1) / 3) * 3 + 1
        default: c.day = 1; c.month = 1
        }
        return cal.date(from: c) ?? date
    }
    private static func add(_ count: Int, unit: String, to date: Date) -> Date {
        let cal = Calendar.utc
        if let m = months(unit) { return cal.date(byAdding: .month, value: count * m, to: date) ?? date }
        return cal.date(byAdding: .day, value: count, to: date) ?? date
    }

    /// The ranges a policy keeps and refreshes when a refresh runs at `now`.
    /// The refreshed range is the last N whole refresh periods (ending with the current period, or the
    /// last finished one with "only complete periods"); the archive keeps N whole archive periods before it.
    static func windows(_ policy: IncrementalRefreshPolicy, now: Date) -> Windows {
        let p = normalized(policy)
        let currentStart = startOfPeriod(now, unit: p.refreshUnit)
        let end = p.onlyCompletePeriods ? currentStart : add(1, unit: p.refreshUnit, to: currentStart)
        let refreshStart = add(-max(1, p.refreshCount), unit: p.refreshUnit, to: end)
        let archiveStart = add(-max(1, p.archiveCount), unit: p.archiveUnit, to: startOfPeriod(refreshStart, unit: p.archiveUnit))
        return Windows(archiveStart: archiveStart, refreshStart: refreshStart, end: end)
    }
}

/// "Manage aggregations": mapping an aggregation table's columns onto a detail table.
enum AggregationLogic {
    enum Summarization: String, CaseIterable, Identifiable {
        case none, count, groupBy, max, min, sum, countRows
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Don't map"
            case .count: return "Count"
            case .groupBy: return "GroupBy"
            case .max: return "Max"
            case .min: return "Min"
            case .sum: return "Sum"
            case .countRows: return "Count table rows"
            }
        }
        var needsDetailColumn: Bool { self != .none && self != .countRows }
    }

    /// One row of the dialog: an aggregation-table column and what it stands for.
    struct Row: Identifiable, Equatable {
        var id: String { column }
        var column: String
        var summarization: Summarization = .none
        var detailTable = ""
        var detailColumn = ""
    }

    static func summarization(of m: AggregationMapping) -> Summarization {
        switch m.summarization {
        case .none: return .groupBy
        case .sum: return .sum
        case .min: return .min
        case .max: return .max
        case .count: return m.detailColumn.isEmpty ? .countRows : .count
        default: return .none
        }
    }

    static func rows(for table: ModelTable, model: SemanticModel) -> [Row] {
        table.columns.map { c in
            guard let m = model.aggregations.first(where: { ModelDAX.same($0.aggTable, table.name) && ModelDAX.same($0.aggColumn, c.name) }) else {
                return Row(column: c.name)
            }
            return Row(column: c.name, summarization: summarization(of: m), detailTable: m.detailTable, detailColumn: m.detailColumn)
        }
    }

    static func mappings(from rows: [Row], aggTable: String) -> [AggregationMapping] {
        rows.compactMap { r in
            let summarization: Aggregation
            switch r.summarization {
            case .none: return nil
            case .groupBy: summarization = .none
            case .sum: summarization = .sum
            case .min: summarization = .min
            case .max: summarization = .max
            case .count, .countRows: summarization = .count
            }
            return AggregationMapping(aggTable: aggTable, aggColumn: r.column, summarization: summarization,
                                      detailTable: r.detailTable, detailColumn: r.summarization == .countRows ? "" : r.detailColumn)
        }
    }

    static func problems(_ rows: [Row], aggTable: ModelTable, model: SemanticModel) -> [String] {
        var out: [String] = []
        let mapped = rows.filter { $0.summarization != .none }
        let detailTables = Set(mapped.map { $0.detailTable.lowercased() }.filter { !$0.isEmpty })
        if detailTables.count > 1 { out.append("All rows must map to the same detail table.") }
        for r in mapped {
            guard let aggColumn = aggTable.column(r.column) else { out.append("“\(r.column)” is not a column of \(aggTable.name)."); continue }
            if r.detailTable.isEmpty { out.append("Choose a detail table for \(r.column)."); continue }
            if ModelDAX.same(r.detailTable, aggTable.name) { out.append("\(aggTable.name) can't aggregate itself. Choose another detail table."); continue }
            guard let detail = model.table(r.detailTable) else { out.append("“\(r.detailTable)” is not a table in the model."); continue }
            if model.aggregations.contains(where: { ModelDAX.same($0.aggTable, detail.name) }) {
                out.append("\(detail.name) is itself an aggregation table. Aggregations can't be chained.")
                continue
            }
            switch r.summarization {
            case .none: break
            case .countRows:
                if aggColumn.dataType != .integer { out.append("\(r.column) must be a whole number to count table rows.") }
            case .count, .groupBy, .max, .min, .sum:
                if r.detailColumn.isEmpty { out.append("Choose a detail column for \(r.column)."); continue }
                guard let detailColumn = detail.column(r.detailColumn) else {
                    out.append("“\(r.detailColumn)” is not a column of \(detail.name).")
                    continue
                }
                if r.summarization == .count {
                    if aggColumn.dataType != .integer { out.append("\(r.column) must be a whole number to hold a count.") }
                } else if aggColumn.dataType != detailColumn.dataType {
                    out.append("\(r.column) is \(aggColumn.dataType.displayName.lowercased()) but \(detail.name)[\(detailColumn.name)] is \(detailColumn.dataType.displayName.lowercased()). \(r.summarization.title) needs matching data types.")
                }
                if r.summarization == .sum, !aggColumn.dataType.isNumeric { out.append("Sum needs a number column; \(r.column) is \(aggColumn.dataType.displayName.lowercased()).") }
            }
        }
        let pairs = mapped.filter { $0.summarization.needsDetailColumn && !$0.detailColumn.isEmpty }
            .map { "\($0.summarization.rawValue)|\($0.detailTable.lowercased())|\($0.detailColumn.lowercased())" }
        if Set(pairs).count < pairs.count { out.append("Two columns map the same summarization of the same detail column.") }
        if mapped.filter({ $0.summarization == .countRows }).count > 1 { out.append("Only one column can count table rows.") }
        return out
    }

    /// Replaces a table's mappings and hides the aggregation table from report authors, as it is only there for the engine.
    static func apply(_ rows: [Row], aggTable: String, to model: inout SemanticModel) {
        model.aggregations.removeAll { ModelDAX.same($0.aggTable, aggTable) }
        let new = mappings(from: rows, aggTable: aggTable)
        model.aggregations.append(contentsOf: new)
        if !new.isEmpty, let i = model.tableIndex(aggTable) { model.tables[i].isHidden = true }
    }
}
