import SwiftUI
import FacetCore

/// Rules of the Build pane that aren't views: what each well accepts, what applies to which visual type.
enum BuildLogic {

    // MARK: Wells

    /// Maximum number of fields a well holds (nil = any number). Dropping onto a full single-field well replaces it.
    static func capacity(_ well: Well, in type: VisualType) -> Int? {
        switch well {
        case .x, .y, .size, .playAxis, .target, .minimum, .maximum, .trendAxis, .latitude, .longitude,
             .start, .end, .progress, .open, .high, .low, .close, .breakdown, .source, .destination, .analyze, .smallMultiples:
            return 1
        case .legend:
            return (type == .pie || type == .donut) ? nil : 1
        case .values:
            switch type {
            case .kpi, .gauge, .bullet, .cardLegacy, .filledMap, .shapeMap, .waterfall, .funnel, .treemap, .sunburst, .wordCloud,
                 .histogram, .boxPlot, .sankey, .calendarHeatmap:
                return 1
            default: return nil
            }
        default: return nil
        }
    }

    /// Wells where a plain, unaggregated column is meaningful.
    static func acceptsRawColumns(_ well: Well, in type: VisualType) -> Bool {
        if well.isGrouping { return true }
        switch type {
        case .table, .pythonVisual, .rVisual, .paginatedReport, .histogram, .boxPlot: return well == .values
        default: return false
        }
    }

    enum Rejection: Error { case measureInGroupingWell }

    /// Shapes a field for the well it is entering: grouping wells take plain columns, value wells take aggregates.
    /// - Parameter isNew: true for fields coming from the model; false when moving an existing chip (its choices are kept where valid).
    @MainActor
    static func adapt(_ field: FieldRef, to well: Well, in type: VisualType, isNew: Bool, store: DocumentStore) -> Result<FieldRef, Rejection> {
        var f = field
        if well.isGrouping {
            if f.kind == .measure { return .failure(.measureInGroupingWell) }
            f.aggregation = .none
            f.showAs = ""
            f.isHidden = false
            return .success(f)
        }
        guard f.kind == .column else { return .success(f) }
        let column = store.model.column(f)
        if acceptsRawColumns(well, in: type) {
            if isNew, f.aggregation == .none, let c = column, c.dataType.isNumeric, c.summarizeBy != .none {
                f.aggregation = store.defaultAggregation(for: f)
            }
            return .success(f)
        }
        if f.aggregation == .none {
            if let c = column, c.dataType.isTemporal, well == .start || well == .end {
                f.aggregation = well == .end ? .max : .min
            } else if let c = column, c.dataType.isNumeric, well == .latitude || well == .longitude {
                f.aggregation = .average
            } else {
                f.aggregation = store.defaultAggregation(for: f)
            }
        }
        return .success(f)
    }

    /// The well whose fields form the drill hierarchy, if this visual drills.
    static func drillWell(_ spec: VisualSpec) -> Well? {
        if spec.type == .matrix { return .rows }
        return spec.type.wells.contains(.category) ? .category : nil
    }

    /// Keep drill state and sorting valid after fields change.
    static func clampDrill(_ v: inout VisualSpec) {
        let levels = drillWell(v).map { v.fields($0).count } ?? 0
        let maxLevel = max(0, levels - 1)
        if v.drillLevel > maxLevel { v.drillLevel = maxLevel }
        if v.drillPath.count > v.drillLevel { v.drillPath = Array(v.drillPath.prefix(v.drillLevel)) }
        if v.drillLevel == 0 { v.expandedAllLevels = false; v.drillPath = [] }
        let keys = Set(v.allFields.map(\.key))
        v.sort.removeAll { !keys.contains($0.field.key) }
    }

    // MARK: Type suggestions

    static func suggestedTypes(for spec: VisualSpec, model: SemanticModel) -> [VisualType] {
        let groups = spec.type.wells.filter(\.isGrouping).flatMap { spec.fields($0) }
        let values = spec.type.wells.filter { !$0.isGrouping && $0 != .tooltips }.flatMap { spec.fields($0) }.filter(\.isAggregate)
        let raw = spec.allFields.filter { !$0.isAggregate }
        let firstGroup = (groups.first ?? raw.first).flatMap { model.column($0) }
        let isTime = firstGroup?.dataType.isTemporal ?? false
        let isGeo: Bool = {
            switch firstGroup?.dataCategory ?? .uncategorized {
            case .city, .country, .continent, .county, .stateOrProvince, .postalCode, .place, .address: return true
            default: return false
            }
        }()
        let g = max(groups.count, values.isEmpty ? 0 : (raw.isEmpty ? 0 : 1)), n = values.count
        var out: [VisualType]
        switch (g, n) {
        case (0, 0): out = spec.allFields.isEmpty ? [] : [.table, .slicer, .listSlicer]
        case (0, 1): out = [.card, .gauge, .kpi]
        case (0, _): out = [.multiRowCard, .card, .table]
        case (_, 0): out = [.table, .slicer, .listSlicer, .buttonSlicer]
        case (1, 1):
            out = isTime ? [.line, .area, .clusteredColumn, .calendarHeatmap]
                : isGeo ? [.filledMap, .azureMap, .clusteredBar, .treemap]
                : [.clusteredBar, .clusteredColumn, .donut, .treemap]
        case (1, 2): out = isTime ? [.line, .lineClusteredColumn, .area, .table] : [.clusteredColumn, .lineClusteredColumn, .scatter, .table]
        case (1, _): out = isTime ? [.line, .stackedArea, .table, .matrix] : [.clusteredColumn, .table, .radar, .scatter]
        default: out = isTime ? [.line, .stackedColumn, .matrix, .ribbon] : [.matrix, .stackedColumn, .treemap, .heatmap]
        }
        return Array(out.filter { $0 != spec.type }.prefix(4))
    }

    // MARK: Analytics

    static func analyticsKinds(for spec: VisualSpec, model: SemanticModel) -> [AnalyticsItem.Kind] {
        let refLines: [AnalyticsItem.Kind] = [.constantLine, .minLine, .maxLine, .averageLine, .medianLine, .percentileLine]
        let axis = spec.fields(.category).first.flatMap { model.column($0) }
        let continuousAxis = axis.map { $0.dataType.isTemporal || $0.dataType.isNumeric } ?? false
        switch spec.type {
        case .clusteredBar, .clusteredColumn:
            return refLines + [.trendLine, .errorBars]
        case .stackedBar, .stackedColumn, .ribbon, .waterfall:
            return refLines + [.trendLine]
        case .stackedBar100, .stackedColumn100, .stackedArea100:
            return [.constantLine]
        case .line:
            return refLines + [.trendLine] + (continuousAxis ? [.forecast] : []) + [.errorBars, .anomalies]
        case .area:
            return refLines + [.trendLine] + (continuousAxis ? [.forecast] : []) + [.errorBars]
        case .stackedArea:
            return refLines + [.trendLine]
        case .lineStackedColumn, .lineClusteredColumn:
            return refLines + [.trendLine, .errorBars]
        case .scatter:
            return [.trendLine, .symmetryShading, .ratioLine, .clusters, .minLine, .maxLine, .averageLine, .medianLine]
        default:
            return []
        }
    }

    static func title(_ kind: AnalyticsItem.Kind) -> String {
        switch kind {
        case .constantLine: return "Constant line"
        case .minLine: return "Min line"
        case .maxLine: return "Max line"
        case .averageLine: return "Average line"
        case .medianLine: return "Median line"
        case .percentileLine: return "Percentile line"
        case .trendLine: return "Trend line"
        case .forecast: return "Forecast"
        case .errorBars: return "Error bars"
        case .anomalies: return "Anomalies"
        case .symmetryShading: return "Symmetry shading"
        case .ratioLine: return "Ratio line"
        case .clusters: return "Clusters"
        }
    }
    static func symbol(_ kind: AnalyticsItem.Kind) -> String {
        switch kind {
        case .constantLine, .minLine, .maxLine, .averageLine, .medianLine, .percentileLine: return "minus"
        case .trendLine, .ratioLine: return "line.diagonal"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .errorBars: return "arrow.up.and.down"
        case .anomalies: return "exclamationmark.circle"
        case .symmetryShading: return "square.lefthalf.filled"
        case .clusters: return "circle.hexagongrid"
        }
    }
    /// Kinds of which a visual holds at most one.
    static func isSingleton(_ kind: AnalyticsItem.Kind) -> Bool {
        switch kind {
        case .forecast, .errorBars, .anomalies, .symmetryShading, .ratioLine, .clusters, .trendLine: return true
        default: return false
        }
    }
    static func newItem(_ kind: AnalyticsItem.Kind) -> AnalyticsItem {
        var i = AnalyticsItem(kind: kind)
        switch kind {
        case .percentileLine: i.value = 50
        case .forecast: i.value = 10; i.secondaryValue = 95
        case .errorBars: i.secondaryValue = 10; i.style = "solid"
        case .anomalies: i.value = 70; i.secondaryValue = 95
        case .clusters: i.secondaryValue = 0
        case .trendLine, .ratioLine: i.style = "dashed"
        default: break
        }
        return i
    }

    // MARK: Conditional formatting

    static func conditionalTargets(for type: VisualType) -> [ConditionalFormat.Target] {
        if type.isPageElement { return [] }
        switch type {
        case .table, .matrix: return [.background, .fontColor, .dataBars, .icons, .webURL, .image, .title]
        case .card, .cardLegacy, .multiRowCard, .kpi: return [.fontColor, .title]
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer, .narrative, .qna, .pythonVisual, .rVisual,
             .paginatedReport, .powerApps, .powerAutomate, .metrics, .keyInfluencers, .decompositionTree:
            return [.title]
        default: return [.dataPointColor, .title]
        }
    }
    static func title(_ t: ConditionalFormat.Target) -> String {
        switch t {
        case .background: return "Background colour"
        case .fontColor: return "Font colour"
        case .dataBars: return "Data bars"
        case .icons: return "Icons"
        case .dataPointColor: return "Data point colour"
        case .webURL: return "Web URL"
        case .image: return "Image"
        case .title: return "Title"
        case .columnWidth: return "Column width"
        }
    }
    static func symbol(_ t: ConditionalFormat.Target) -> String {
        switch t {
        case .background: return "square.fill"
        case .fontColor: return "textformat"
        case .dataBars: return "chart.bar.fill"
        case .icons: return "flag"
        case .dataPointColor: return "paintpalette"
        case .webURL: return "link"
        case .image: return "photo"
        case .title: return "textformat.size"
        case .columnWidth: return "arrow.left.and.right"
        }
    }
    static func modes(for t: ConditionalFormat.Target) -> [ConditionalFormat.Mode] {
        switch t {
        case .background, .fontColor, .dataPointColor: return [.gradient, .rules, .fieldValue]
        case .dataBars: return [.gradient]
        case .icons: return [.rules]
        case .webURL, .image, .title, .columnWidth: return [.fieldValue]
        }
    }
    static func title(_ m: ConditionalFormat.Mode) -> String {
        switch m { case .gradient: return "Gradient"; case .rules: return "Rules"; case .fieldValue: return "Field value" }
    }
    /// Whether the target formats one field of the visual (cells) rather than the visual as a whole.
    static func isPerField(_ t: ConditionalFormat.Target) -> Bool {
        switch t { case .background, .fontColor, .dataBars, .icons, .webURL, .image: return true; default: return false }
    }
}

// MARK: - Field operations on a visual

extension DocumentStore {
    /// Insert a model field into a well at `index` (nil = end), shaped by the well's semantics.
    func dropField(_ raw: FieldRef, on visualID: UUID, well: Well, at index: Int? = nil) {
        guard let spec = visual(visualID) else { return }
        var fresh = raw
        fresh.id = UUID()
        switch BuildLogic.adapt(fresh, to: well, in: spec.type, isNew: true, store: self) {
        case .failure:
            status = StatusMessage(kind: .info, text: "“\(raw.name)” is a measure, so it can't group data. Drop it on a values well instead.")
        case .success(let f):
            if well.isGrouping, spec.fields(well).contains(where: { $0.key == f.key }) {
                status = StatusMessage(kind: .info, text: "“\(f.name)” is already in \(well.displayName).")
                return
            }
            let cap = BuildLogic.capacity(well, in: spec.type)
            updateVisual(visualID, name: "Add Field") { v in
                var list = v.fields(well)
                if cap == 1 { list = [f] }
                else {
                    list.insert(f, at: min(max(index ?? list.count, 0), list.count))
                    if let cap, list.count > cap { list = Array(list.prefix(cap)) }
                }
                v.setFields(well, list)
                BuildLogic.clampDrill(&v)
            }
        }
    }

    /// Reorder a chip within its well or move it to another well.
    func moveChip(_ chip: PaneDrag.ChipRef, to well: Well, at index: Int? = nil) {
        guard let spec = visual(chip.visual), let field = spec.fields(chip.well).first(where: { $0.id == chip.field }) else { return }
        if chip.well == well {
            let list = spec.fields(well)
            guard let from = list.firstIndex(where: { $0.id == chip.field }) else { return }
            var to = min(max(index ?? list.count, 0), list.count)
            if to > from { to -= 1 }
            guard to != from else { return }
            updateVisual(chip.visual, name: "Reorder Fields") { v in
                var l = v.fields(well)
                let f = l.remove(at: from)
                l.insert(f, at: min(to, l.count))
                v.setFields(well, l)
                BuildLogic.clampDrill(&v)
            }
            return
        }
        switch BuildLogic.adapt(field, to: well, in: spec.type, isNew: false, store: self) {
        case .failure:
            status = StatusMessage(kind: .info, text: "“\(field.caption)” is a measure, so it can't go in \(well.displayName).")
        case .success(let f):
            if well.isGrouping, spec.fields(well).contains(where: { $0.key == f.key }) {
                status = StatusMessage(kind: .info, text: "“\(f.name)” is already in \(well.displayName).")
                return
            }
            let cap = BuildLogic.capacity(well, in: spec.type)
            updateVisual(chip.visual, name: "Move Field") { v in
                v.setFields(chip.well, v.fields(chip.well).filter { $0.id != chip.field })
                var list = v.fields(well)
                if cap == 1 { list = [f] }
                else {
                    list.insert(f, at: min(max(index ?? list.count, 0), list.count))
                    if let cap, list.count > cap { list = Array(list.prefix(cap)) }
                }
                v.setFields(well, list)
                BuildLogic.clampDrill(&v)
            }
        }
    }

    func removeField(_ fieldID: UUID, from well: Well, in visualID: UUID) {
        updateVisual(visualID, name: "Remove Field") { v in
            v.setFields(well, v.fields(well).filter { $0.id != fieldID })
            BuildLogic.clampDrill(&v)
        }
    }

    /// Change one field in place. References to it by key (sort, conditional formats, analytics) follow the change.
    func updateField(_ fieldID: UUID, in well: Well, of visualID: UUID, name: String, invalidates: Invalidation? = nil,
                     _ change: @escaping (inout FieldRef) -> Void) {
        updateVisual(visualID, name: name, invalidates: invalidates) { v in
            var list = v.fields(well)
            guard let i = list.firstIndex(where: { $0.id == fieldID }) else { return }
            let oldKey = list[i].key
            change(&list[i])
            let new = list[i]
            v.setFields(well, list)
            guard new.key != oldKey, !v.allFields.contains(where: { $0.key == oldKey }) else { return }
            for s in v.sort.indices where v.sort[s].field.key == oldKey { v.sort[s].field.aggregation = new.aggregation }
            for c in v.conditionalFormats.indices where v.conditionalFormats[c].appliesToKey == oldKey { v.conditionalFormats[c].appliesToKey = new.key }
            for a in v.analytics.indices where v.analytics[a].seriesKey == oldKey { v.analytics[a].seriesKey = new.key }
        }
    }

    /// Handle a drop of pane payloads (model fields or chips) on a well. Returns whether anything was accepted.
    @discardableResult
    func handleWellDrop(_ items: [String], visualID: UUID, well: Well, at index: Int?) -> Bool {
        if let chip = items.compactMap(PaneDrag.decodeChip).first {
            guard chip.visual == visualID else { return false }
            moveChip(chip, to: well, at: index)
            return true
        }
        let fields = items.compactMap(FieldDrag.decode)
        guard !fields.isEmpty else { return false }
        var at = index
        for f in fields {
            dropField(f, on: visualID, well: well, at: at)
            if let a = at { at = a + 1 }
        }
        return true
    }
}
