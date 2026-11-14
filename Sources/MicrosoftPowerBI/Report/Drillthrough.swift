import SwiftUI
import FacetCore
import FacetDesign

/// Drillthrough rules: which pages a data point can open, which filters travel with it, and the
/// back button a drillthrough page gets.
enum Drillthrough {
    /// Drillthrough matches on the column, whatever aggregation or caption the visual uses.
    static func fieldKey(_ f: FieldRef) -> String { "\(f.table)|\(f.name)" }

    /// Pages the point can drill through to: other, non-tooltip pages with a drillthrough field among the point's fields.
    static func targets(for point: DataPointSelection, in report: Report, from current: UUID) -> [Page] {
        let keys = Set(point.fields.map(fieldKey))
        return report.pages.filter { p in
            p.id != current && !p.isTooltipPage && p.drillthroughFilters.contains { keys.contains(fieldKey($0.field)) }
        }
    }

    /// A basic "is one of" filter on a column.
    static func basic(_ field: FieldRef, _ values: [Value]) -> FilterSpec {
        var f = FilterSpec(field: FieldRef(kind: .column, table: field.table, name: field.name), kind: .basic)
        f.values = values
        return f
    }

    /// The filter a slicer's state amounts to, or nil when it has none that a filter can express
    /// (hierarchy selections are not carried).
    static func filter(forSlicer fields: [FieldRef], state: SlicerState) -> FilterSpec? {
        guard let field = fields.first else { return nil }
        if !state.selected.isEmpty { return basic(field, state.selected) }
        if !state.rangeLow.isNull || !state.rangeHigh.isNull {
            var f = FilterSpec(field: FieldRef(kind: .column, table: field.table, name: field.name), kind: .advanced)
            if !state.rangeLow.isNull { f.conditions.append(FilterCondition(op: .greaterOrEqual, value: state.rangeLow)) }
            if !state.rangeHigh.isNull { f.conditions.append(FilterCondition(op: .lessOrEqual, value: state.rangeHigh)) }
            return f
        }
        if let relative = state.relative {
            var f = FilterSpec(field: FieldRef(kind: .column, table: field.table, name: field.name), kind: .relativeDate)
            f.relative = relative
            return f
        }
        if !state.text.isEmpty {
            var f = FilterSpec(field: FieldRef(kind: .column, table: field.table, name: field.name), kind: .advanced)
            f.conditions = [FilterCondition(op: .contains, value: .string(state.text))]
            return f
        }
        return nil
    }

    /// The filters applied to `target` when `point` is drilled through.
    ///
    /// The point's values land on the page's drillthrough fields (keeping each field's id, lock and hide
    /// flags). With "keep all filters" on, everything else that shaped the point comes too: its other
    /// fields, the source page's filters, the source visual's own filters, the slicers on the source page
    /// and the cross-filter selections of other visuals. Report filters apply to every page already.
    static func filters(point: DataPointSelection, target: Page, sourcePage: Page, sourceVisual: VisualSpec?,
                        selections: [UUID: [DataPointSelection]]) -> [FilterSpec] {
        var out: [FilterSpec] = []
        var covered = Set<String>()
        for definition in target.drillthroughFilters {
            guard let i = point.fields.firstIndex(where: { fieldKey($0) == fieldKey(definition.field) }),
                  let value = point.values[safe: i] else { continue }
            var f = definition
            f.kind = .basic; f.values = [value]; f.isInverted = false
            out.append(f)
            covered.insert(fieldKey(definition.field))
        }
        guard target.keepAllFiltersOnDrillthrough else { return out }
        func add(_ f: FilterSpec) {
            guard !f.isEmpty, covered.insert(fieldKey(f.field)).inserted else { return }
            out.append(f)
        }
        for (field, value) in zip(point.fields, point.values) { add(basic(field, [value])) }
        for f in sourcePage.filters { add(f) }
        // A visual's Top N is ranked inside that visual; it means nothing on another page.
        for f in sourceVisual?.filters ?? [] where f.kind != .topN { add(f) }
        for v in sourcePage.visuals where v.type.isSlicer && v.id != sourceVisual?.id {
            if let source = sourceVisual, sourcePage.interactions[v.id]?[source.id] == InteractionMode.none { continue }
            if let state = v.slicerState, let f = filter(forSlicer: v.fields(.field), state: state) { add(f) }
        }
        for v in sourcePage.visuals where v.id != sourceVisual?.id {
            guard let points = selections[v.id], !points.isEmpty else { continue }
            if let source = sourceVisual, sourcePage.interactions[v.id]?[source.id] == InteractionMode.none { continue }
            // One filter per selected field, holding every selected value of that field.
            var order: [FieldRef] = [], values: [String: [Value]] = [:]
            for p in points {
                for (field, value) in zip(p.fields, p.values) {
                    let key = fieldKey(field)
                    if values[key] == nil { order.append(field) }
                    if !(values[key] ?? []).contains(value) { values[key, default: []].append(value) }
                }
            }
            for field in order { add(basic(field, values[fieldKey(field)] ?? [])) }
        }
        return out
    }

    /// What the Filters pane lists under Drillthrough: the page's drillthrough fields, each showing the
    /// value that arrived, followed by the other filters that were kept.
    static func display(definitions: [FilterSpec], applied: [FilterSpec]) -> [FilterSpec] {
        let ids = Set(definitions.map(\.id))
        return definitions.map { d in applied.first { $0.id == d.id } ?? d } + applied.filter { !ids.contains($0.id) }
    }

    /// The back button added to a page when it becomes a drillthrough page; nil when it already has one.
    static func backButton(for page: Page) -> VisualSpec? {
        guard !page.visuals.contains(where: { $0.type == .button && $0.action?.kind == .back }) else { return nil }
        var button = VisualSpec(type: .button, frame: Frame(x: 16, y: 16, width: 40, height: 40), name: "Back")
        button.setFmt("button", "icon", .string("back"))
        var action = ActionSpec()
        action.kind = .back
        action.tooltip = "Back"
        button.action = action
        button.zIndex = (page.visuals.map(\.zIndex).max() ?? 0) + 1
        button.tabOrder = page.visuals.count
        return button
    }
}

extension DocumentStore {
    /// Makes the current page a drillthrough destination for a column, adding a back button the first time.
    func addDrillthroughField(_ field: FieldRef) {
        guard field.kind == .column else {
            status = StatusMessage(kind: .info, text: "Drillthrough works on columns. Add the column a measure is grouped by instead.")
            return
        }
        guard !currentPage.drillthroughFilters.contains(where: { Drillthrough.fieldKey($0.field) == Drillthrough.fieldKey(field) }) else { return }
        var filter = FilterSpec(field: FieldRef(kind: .column, table: field.table, name: field.name))
        filter.drillthroughUsedAsCategory = true
        updatePage(name: "Add Drillthrough Field") { p in
            if let button = Drillthrough.backButton(for: p) { p.visuals.append(button) }
            p.drillthroughFilters.append(filter)
        }
    }

    /// Drillthrough fields of the current page with the values that arrived, plus the kept filters.
    var drillthroughDisplay: [FilterSpec] {
        Drillthrough.display(definitions: currentPage.drillthroughFilters, applied: drillthroughFilters[currentPageID] ?? [])
    }

    /// Pages a data point can drill through to.
    func drillthroughTargets(for point: DataPointSelection) -> [Page] {
        Drillthrough.targets(for: point, in: report, from: currentPageID)
    }

    func drillthrough(_ point: DataPointSelection, to pageID: UUID?, from visualID: UUID? = nil) {
        let targets = drillthroughTargets(for: point)
        guard let target = pageID.flatMap({ id in targets.first { $0.id == id } }) ?? (pageID == nil ? targets.first : nil) else {
            status = StatusMessage(kind: .info, text: pageID == nil
                ? "No drillthrough page is set up for this field. Add the field under Drillthrough on the destination page."
                : "That page has no drillthrough field matching this data point.")
            return
        }
        let page = currentPage
        let filters = Drillthrough.filters(point: point, target: target, sourcePage: page,
                                           sourceVisual: visualID.flatMap(page.visual), selections: pointSelections)
        setAppliedDrillthrough(filters, for: target.id)
        goToPage(target.id)
    }
}

/// Page settings for the roles a page can play: tooltip (with its tooltip fields) and drillthrough destination.
struct PageRolesSettings: View {
    @EnvironmentObject var store: DocumentStore
    private var page: Page { store.currentPage }

    var body: some View {
        if page.isTooltipPage {
            SectionLabel("Tooltip fields").padding(.top, Design.Space.s)
            ForEach(page.tooltipFields ?? []) { field in
                fieldRow(field) {
                    store.updatePage(name: "Remove Tooltip Field") { p in
                        p.tooltipFields?.removeAll { $0.key == field.key }
                        if p.tooltipFields?.isEmpty == true { p.tooltipFields = nil }
                    }
                }
            }
            FieldPickerButton(selection: nil, placeholder: "Add a field", allowsClear: false) { field in
                guard let field else { return }
                store.updatePage(name: "Add Tooltip Field") { p in
                    guard !(p.tooltipFields ?? []).contains(where: { $0.key == field.key }) else { return }
                    p.tooltipFields = (p.tooltipFields ?? []) + [field]
                }
            }
            PaneNote("Visuals on the automatic tooltip show this page when they use one of these fields. A visual can also pick this page by name in its Tooltip settings.")
        }
        SectionLabel("Drillthrough").padding(.top, Design.Space.s)
        ForEach(page.drillthroughFilters) { filter in
            fieldRow(filter.field) { store.removeFilter(id: filter.id, scope: .drillthrough) }
        }
        FieldPickerButton(selection: nil, placeholder: "Add a drillthrough field", allowsMeasures: false, allowsClear: false) { field in
            if let field { store.addDrillthroughField(field) }
        }
        if page.isDrillthroughPage {
            Toggle("Keep all filters", isOn: Binding(
                get: { page.keepAllFiltersOnDrillthrough },
                set: { on in store.updatePage(name: "Keep All Filters") { $0.keepAllFiltersOnDrillthrough = on } }))
                .help("Carry the source page's filters, slicers and selections along, not only the drilled value")
            Toggle("Cross-report", isOn: Binding(
                get: { page.allowCrossReportDrillthrough },
                set: { on in store.updatePage(name: "Cross-report Drillthrough") { $0.allowCrossReportDrillthrough = on } }))
                .help("Marks this page as a drillthrough target for other reports when the report is published to the Power BI service")
            PaneNote("Right-click a data point that uses one of these fields and choose Drill through to open this page filtered to it. Cross-report drillthrough is saved with the report and takes effect in the Power BI service.")
        } else {
            PaneNote("Add a column to make this page a drillthrough destination. A back button is added for you.")
        }
    }

    private func fieldRow(_ field: FieldRef, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Design.Space.xs) {
            Text(field.caption).font(Design.Typeface.body).lineLimit(1)
            Text(field.table).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            IconButton("xmark", help: "Remove \(field.caption)") { remove() }
        }
    }
}
