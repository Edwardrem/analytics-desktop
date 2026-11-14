import Foundation
import FacetCore

/// Converts a legacy Layout `report.json` — the format Power BI Desktop stored inside .pbix files
/// before the PBIR project format — into a Facet report. The legacy format stores field roles
/// implicitly in the projection order, so well assignment is a best effort and may need a nudge.
public enum LegacyReportLayout {
    /// Reads a parsed legacy `report.json`. `resource` loads a registered resource by file name.
    public static func convert(_ json: JSONValue, resource: (String) -> Data?) -> (report: Report, warnings: [ImportWarning]) {
        var report = Report()
        var warnings: [ImportWarning] = []
        report.pages = []

        for (i, s) in (json["sections"]?.arrayValue ?? []).enumerated() {
            let location = "section \(i + 1)"
            let page = readSection(s, index: i, warnings: &warnings, location: location)
            report.pages.append(page)
        }

        report.filters = parseFilterString(json["filters"], warnings: &warnings, location: "report.json")
        warnings.append(ImportWarning("The legacy layout format doesn't carry the report theme or bookmarks; the defaults are used.",
                                      severity: .info, location: "report.json"))
        return (report, warnings)
    }

    // MARK: Pages

    private static func readSection(_ s: JSONValue, index: Int, warnings: inout [ImportWarning], location: String) -> Page {
        var page = Page(name: s["displayName"]?.stringValue ?? s["name"]?.stringValue ?? "Page \(index + 1)")
        page.size = PageSize(width: s["width"]?.doubleValue ?? 1280, height: s["height"]?.doubleValue ?? 720)
        page.filters = parseFilterString(s["filters"], warnings: &warnings, location: location)

        for (i, vc) in (s["visualContainers"]?.arrayValue ?? []).enumerated() {
            let vloc = "\(location), visual \(i + 1)"
            guard let configText = vc["config"]?.stringValue, let config = try? JSONValue.parse(configText) else { continue }

            // A group container registers its name; its children stay separate visuals.
            if let group = config["singleVisualGroup"] {
                let name = group["displayName"]?.stringValue ?? "Group \(page.groups.count + 1)"
                page.groups[stableUUID(from: name)] = name
                continue
            }
            guard var spec = readVisual(config, vc: vc, warnings: &warnings, location: vloc) else { continue }
            // Visuals can carry the groups they belong to alongside their definition.
            if let g = config["groups"]?.arrayValue?.first, let name = g["displayName"]?.stringValue ?? g["name"]?.stringValue {
                page.groups[stableUUID(from: name)] = name
                spec.groupID = stableUUID(from: name)
            }
            page.visuals.append(spec)
        }
        return page
    }

    // MARK: Visuals

    private static func readVisual(_ config: JSONValue, vc: JSONValue, warnings: inout [ImportWarning], location: String) -> VisualSpec? {
        guard let visual = config["singleVisual"] else { return nil }
        let pbiType = visual["visualType"]?.stringValue ?? ""
        let type: VisualType
        if let t = PowerBIMapping.facetType(forPowerBI: pbiType) { type = t }
        else {
            type = visual["projections"]?.arrayValue?.isEmpty == false || visual["projections"]?.objectValue?.isEmpty == false ? .table : .shape
            warnings.append(ImportWarning("Visual type “\(pbiType)” isn't supported; it was imported as a \(type.displayName.lowercased()).", location: location))
        }

        var spec = VisualSpec(type: type, frame: Frame(x: vc["x"]?.doubleValue ?? 0, y: vc["y"]?.doubleValue ?? 0,
                                                       width: vc["width"]?.doubleValue ?? 300, height: vc["height"]?.doubleValue ?? 200))
        spec.zIndex = vc["z"]?.intValue ?? 0

        // Fields: the projections name the fields by query reference; the prototype query says which are measures.
        var aliases: [String: String] = [:]
        for src in visual["prototypeQuery"]?["From"]?.arrayValue ?? [] {
            if let n = src["Name"]?.stringValue, let e = src["Entity"]?.stringValue { aliases[n] = e }
        }
        var byName: [String: FieldRef] = [:]
        for entry in visual["prototypeQuery"]?["Select"]?.arrayValue ?? [] {
            if let n = entry["Name"]?.stringValue, let f = PBIExpr.parseField(entry, aliases: aliases) { byName[n] = f }
        }
        func resolve(_ p: JSONValue) -> FieldRef? {
            guard let ref = p["queryRef"]?.stringValue else { return nil }
            if let f = byName[ref] ?? parseQueryRef(ref) { return f }
            warnings.append(ImportWarning("A field (“\(ref)”) of a \(type.displayName) couldn't be read and was skipped.", location: location))
            return nil
        }
        if let byRole = visual["projections"]?.objectValue {
            // Power BI Desktop writes projections keyed by data role ("Category", "Y"…), which names the well exactly.
            var unplaced: [FieldRef] = []
            for role in byRole.keys.sorted() {
                let fields = (byRole[role]?.arrayValue ?? []).compactMap(resolve)
                if let well = PowerBIMapping.well(forRole: role, in: type) { spec.wells[well.rawValue, default: []].append(contentsOf: fields) }
                else { unplaced.append(contentsOf: fields) }
            }
            if !unplaced.isEmpty {
                for (well, fs) in assignWells(type, unplaced) { spec.wells[well, default: []].append(contentsOf: fs) }
            }
        } else {
            // Older files list the projections without roles; assign them by position.
            let fields = (visual["projections"]?.arrayValue ?? []).compactMap(resolve)
            if !fields.isEmpty {
                for (well, fs) in assignWells(type, fields) { spec.wells[well] = fs }
            }
        }

        spec.format = PBIExpr.parseObjects([visual["objects"], visual["vcObjects"], visual["visualContainerObjects"]])
        if type == .textBox, let paragraphs = visual["objects"]?["general"]?[0]?["properties"]?["paragraphs"] {
            spec.content = PBIR.text(fromParagraphs: paragraphs) ?? ""
        }
        spec.sort = (visual["sortDefinition"]?["sort"]?.arrayValue ?? []).compactMap { s in
            PBIExpr.parseField(s["field"], aliases: aliases).map { SortSpec(field: $0, descending: (s["direction"]?.intValue ?? 2) != 1) }
        }

        // In the legacy format a slicer's selection is stored as a filter on its container.
        let filters = parseFilterString(vc["filters"], warnings: &warnings, location: location)
        if type.isSlicer {
            spec.slicerState = slicerState(from: filters)
        } else {
            spec.filters = filters
        }
        return spec
    }

    // MARK: Field references

    /// Parses a query reference like "Sales.Region" or "Sum(Sales.Amount)" when no prototype query names it.
    private static func parseQueryRef(_ s: String) -> FieldRef? {
        let aggNames: [String: Aggregation] = ["Sum": .sum, "Avg": .average, "Count": .distinctCount, "CountNonNull": .count,
                                               "Min": .min, "Max": .max, "Median": .median, "StandardDeviation": .stdDev, "Variance": .variance]
        if let open = s.firstIndex(of: "("), s.hasSuffix(")"), open > s.startIndex,
           let agg = aggNames[String(s[..<open])] {
            let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
            return split(inner).map { .column($0.table, $0.member, agg) }
        }
        // "Sales.Order Date.Variation.Date Hierarchy.Year": a level of the column's auto date/time hierarchy.
        let marker = ".\(PBIExpr.dateVariation).\(PBIExpr.dateHierarchy)."
        if let r = s.range(of: marker, options: .backwards), let column = split(String(s[..<r.lowerBound])) {
            let level = String(s[r.upperBound...])
            if !level.isEmpty { return .dateLevel(column.table, column.member, level) }
        }
        return split(s).map { .column($0.table, $0.member) }
    }

    /// Splits "Table.Column" on the first dot.
    private static func split(_ s: String) -> (table: String, member: String)? {
        guard let dot = s.firstIndex(of: "."), dot > s.startIndex, dot < s.index(before: s.endIndex) else { return nil }
        return (String(s[..<dot]), String(s[s.index(after: dot)...]))
    }

    // MARK: Wells

    /// Assigns projections to wells by position, following each visual family's role order.
    private static func assignWells(_ type: VisualType, _ fields: [FieldRef]) -> [String: [FieldRef]] {
        var wells: [String: [FieldRef]] = [:]
        func put(_ w: Well, _ f: FieldRef) { wells[w.rawValue, default: []].append(f) }
        func putAll(_ w: Well, _ fs: [FieldRef]) { fs.forEach { put(w, $0) } }
        var rest = fields
        func take(_ n: Int) -> [FieldRef] { let t = Array(rest.prefix(n)); rest.removeFirst(min(n, rest.count)); return t }
        let aggregates = fields.filter(\.isAggregate)
        let dimensions = fields.filter { !$0.isAggregate }

        switch type {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .ribbon, .dotPlot:
            putAll(.category, take(1))
            let remaining = Array(rest)
            let aggregates = remaining.filter(\.isAggregate)
            let dimensions = remaining.filter { !$0.isAggregate }
            if !aggregates.isEmpty {
                putAll(.values, aggregates)
                if let legend = dimensions.first { put(.legend, legend) }
                putAll(.smallMultiples, Array(dimensions.dropFirst()))
            } else {
                // Columns used as implicit measures: the first is the value, the rest legend and small multiples.
                if let v = dimensions.first { put(.values, v) }
                if let legend = dimensions.dropFirst().first { put(.legend, legend) }
                putAll(.smallMultiples, Array(dimensions.dropFirst(2)))
            }
        case .lineStackedColumn, .lineClusteredColumn:
            putAll(.category, take(1))
            let remaining = Array(rest)
            let aggregates = remaining.filter(\.isAggregate)
            let dimensions = remaining.filter { !$0.isAggregate }
            if aggregates.isEmpty {
                if let v = dimensions.first { put(.values, v) }
                if let l = dimensions.dropFirst().first { put(.lineValues, l) }
                if let legend = dimensions.dropFirst(2).first { put(.legend, legend) }
            } else {
                if let first = aggregates.first { put(.values, first) }
                putAll(.lineValues, Array(aggregates.dropFirst()))
                if let legend = dimensions.first { put(.legend, legend) }
            }
        case .waterfall:
            putAll(.category, take(1))
            if let v = rest.popLast() { put(.values, v) }
            putAll(.breakdown, rest)
        case .pie, .donut:
            putAll(.legend, take(1))
            if !rest.isEmpty { putAll(.values, take(1)) }
            putAll(.details, rest)
        case .treemap, .sunburst:
            putAll(.category, take(1))
            if !rest.isEmpty { putAll(.values, take(1)) }
            putAll(.details, rest)
        case .funnel, .radar, .wordCloud, .calendarHeatmap:
            putAll(.category, take(1))
            putAll(.values, rest)
        case .scatter:
            putAll(.x, take(1))
            putAll(.y, take(1))
            putAll(.size, take(1))
            putAll(.legend, take(1))
            putAll(.details, rest)
        case .map, .azureMap:
            putAll(.location, take(1))
            if let next = rest.first {
                put(next.isAggregate ? .size : .latitude, next)
                rest.removeFirst()
            }
            if !rest.isEmpty { putAll(.longitude, take(1)) }
            if !rest.isEmpty { putAll(.legend, take(1)) }
            putAll(.size, rest)
        case .filledMap, .shapeMap:
            putAll(.location, take(1))
            if !rest.isEmpty { putAll(.values, take(1)) }
            putAll(.legend, rest)
        case .kpi:
            putAll(.values, take(1))
            putAll(.trendAxis, take(1))
            putAll(.target, take(1))
        case .gauge, .bullet:
            putAll(.values, take(1))
            putAll(.minimum, take(1))
            putAll(.maximum, take(1))
            putAll(.target, take(1))
        case .matrix, .heatmap:
            putAll(.values, aggregates)
            var dims = dimensions
            if dims.count >= 2, let col = dims.popLast() {
                put(.columns, col)
                putAll(.rows, dims)
            } else {
                putAll(.rows, dims)
            }
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer:
            putAll(.field, fields)
        case .keyInfluencers, .decompositionTree:
            putAll(.analyze, take(1))
            putAll(.explainBy, rest)
        case .gantt:
            putAll(.task, take(1))
            putAll(.start, take(1))
            putAll(.end, take(1))
            putAll(.progress, take(1))
            putAll(.legend, rest)
        case .candlestick:
            putAll(.category, take(1))
            putAll(.open, take(1))
            putAll(.high, take(1))
            putAll(.low, take(1))
            putAll(.close, take(1))
        default:
            if type.wells.contains(.values) || !fields.isEmpty { putAll(.values, fields) }
        }
        return wells
    }

    // MARK: Filters and slicer state

    /// Legacy filters are JSON strings wrapping `{"filters": [...]}`.
    private static func parseFilterString(_ s: JSONValue?, warnings: inout [ImportWarning], location: String) -> [FilterSpec] {
        guard let text = s?.stringValue, var parsed = try? JSONValue.parse(text) else { return [] }
        // Power BI Desktop stores a bare array of filters; tolerate the wrapped form too.
        if parsed.arrayValue != nil { parsed = jo(["filters": parsed]) }
        return PBIR.parseFilters(parsed, warnings: &warnings, location: location).filters
    }

    /// Reads a slicer's selection back from the filter its container carries.
    private static func slicerState(from filters: [FilterSpec]) -> SlicerState? {
        guard let f = filters.first(where: { !$0.isEmpty }) else { return nil }
        var s = SlicerState()
        switch f.kind {
        case .basic: s.selected = f.values
        case .advanced:
            for c in f.conditions {
                switch c.op {
                case .greaterThan, .greaterOrEqual: s.rangeLow = c.value
                case .lessThan, .lessOrEqual: s.rangeHigh = c.value
                default: break
                }
            }
        case .relativeDate, .relativeTime: s.relative = f.relative
        case .topN: return nil
        }
        return s.isActive ? s : nil
    }
}
