import SwiftUI
import FacetCore
import FacetDesign

/// Filter rules shared by the Filters pane, the reading view and the filter commands.
enum FilterTools {
    /// A basic filter after clicking one value: toggled, or — when the author requires a single
    /// selection — replaced (clicking the selected value again keeps it; a single-select filter is never empty by click).
    static func toggling(_ filter: FilterSpec, _ value: Value) -> FilterSpec {
        var f = filter
        if f.requireSingleSelection {
            f.values = [value]
        } else if let i = f.values.firstIndex(of: value) {
            f.values.remove(at: i)
        } else {
            f.values.append(value)
        }
        return f
    }

    /// Turning "require single selection" on keeps only the first selected value.
    static func requiringSingleSelection(_ filter: FilterSpec, _ on: Bool) -> FilterSpec {
        var f = filter
        f.requireSingleSelection = on
        if on, f.kind == .basic, f.values.count > 1 { f.values = Array(f.values.prefix(1)); f.isInverted = false }
        return f
    }

    /// The filter with its condition removed (it stays in the pane, restricting nothing).
    static func cleared(_ filter: FilterSpec) -> FilterSpec {
        var f = filter
        switch f.kind {
        case .basic: f.values = []; f.isInverted = false
        case .advanced: f.conditions = []
        case .topN: f.topN = TopNFilter()
        case .relativeDate, .relativeTime: f.kind = .basic; f.values = []
        }
        return f
    }

    /// Clears every filter on a page — its visuals', its own, and the report's — except locked ones,
    /// which only their author changes. Returns how many filters were cleared.
    @discardableResult
    static func clearAll(_ report: inout Report, pageIndex: Int) -> Int {
        var count = 0
        func clear(_ list: inout [FilterSpec]) {
            for i in list.indices where !list[i].isLocked && !list[i].isEmpty {
                list[i] = cleared(list[i]); count += 1
            }
        }
        clear(&report.filters)
        guard report.pages.indices.contains(pageIndex) else { return count }
        clear(&report.pages[pageIndex].filters)
        for v in report.pages[pageIndex].visuals.indices { clear(&report.pages[pageIndex].visuals[v].filters) }
        return count
    }

    /// The list with one filter moved up (negative) or down (positive) by `delta` places.
    static func moved(_ list: [FilterSpec], id: UUID, by delta: Int) -> [FilterSpec] {
        guard let from = list.firstIndex(where: { $0.id == id }) else { return list }
        let to = max(0, min(list.count - 1, from + delta))
        guard to != from else { return list }
        var out = list
        let f = out.remove(at: from)
        out.insert(f, at: to)
        return out
    }

    /// Every filter that applies to a visual — the report's, the page's, the drillthrough's and its
    /// own — with any list held for the Apply button in place of the live one.
    static func effective(report: Report, page: Page, visual: VisualSpec, drillthrough: [FilterSpec],
                          held: HeldFilters?) -> [FilterSpec] {
        let r = held?.effective(.report, live: report.filters) ?? report.filters
        let p = held?.effective(.page(page.id), live: page.filters) ?? page.filters
        let v = held?.effective(.visual(visual.id), live: visual.filters) ?? visual.filters
        return (r + p + drillthrough + v).filter { !$0.isEmpty }
    }

    /// Filters a reader sees: hidden ones still apply but are not listed.
    static func readerVisible(_ filters: [FilterSpec]) -> [FilterSpec] { filters.filter { !$0.isHidden } }
    /// A reader may change a filter unless its author locked it.
    static func readerCanEdit(_ filter: FilterSpec) -> Bool { !filter.isLocked }

    /// One line describing what a filter keeps.
    static func summary(_ filter: FilterSpec) -> String {
        switch filter.kind {
        case .basic:
            guard !filter.values.isEmpty else { return "is (All)" }
            let values = filter.values.prefix(6).map { $0.asString.isEmpty ? "(Blank)" : $0.asString }.joined(separator: ", ")
            let more = filter.values.count > 6 ? ", …" : ""
            return filter.isInverted ? "is not \(values)\(more)" : "is \(values)\(more)"
        case .advanced:
            guard !filter.conditions.isEmpty else { return "is (All)" }
            return filter.conditions.map { $0.op.needsValue ? "\($0.op.displayName) \($0.value.asString)" : $0.op.displayName }
                .joined(separator: filter.conditionsUseOr ? " or " : " and ")
        case .topN:
            guard let by = filter.topN.by else { return "is (All)" }
            return "\(filter.topN.isBottom ? "Bottom" : "Top") \(filter.topN.count) by \(by.caption)"
        case .relativeDate, .relativeTime:
            let unit: String
            switch filter.relative.unit {
            case .minutes: unit = "minutes"
            case .hours: unit = "hours"
            case .days: unit = "days"
            case .weeks, .calendarWeeks: unit = "weeks"
            case .months, .calendarMonths: unit = "months"
            case .years, .calendarYears: unit = "years"
            }
            let today = filter.kind == .relativeDate && filter.relative.includeToday ? " including today" : ""
            switch filter.relative.direction {
            case .this: return "is in this \(String(unit.dropLast()))"
            case .last: return "is in the last \(filter.relative.count) \(unit)\(today)"
            case .next: return "is in the next \(filter.relative.count) \(unit)\(today)"
            }
        }
    }
}

/// With the report's Apply button on: the filters the visuals last ran with, for each filter list
/// edited since. Edits are saved (and undoable) straight away; the visuals keep these until Apply.
struct HeldFilters: Equatable {
    enum Target: Hashable { case report, page(UUID), visual(UUID) }
    private(set) var lists: [Target: [FilterSpec]] = [:]

    var isEmpty: Bool { lists.isEmpty }
    /// Records a list as it was before its first edit; later edits keep that first record.
    mutating func hold(_ target: Target, _ filters: [FilterSpec]) {
        if lists[target] == nil { lists[target] = filters }
    }
    /// The filters a visual runs with: the held list where there is one, otherwise the live one.
    func effective(_ target: Target, live: [FilterSpec]) -> [FilterSpec] { lists[target] ?? live }

    /// True when Apply would change what a visual shows: some held list restricts differently from
    /// the live one. Renaming, locking or hiding a filter changes nothing a visual shows.
    func isPending(in report: Report) -> Bool {
        lists.contains { target, held in
            let live: [FilterSpec]
            switch target {
            case .report: live = report.filters
            case .page(let id): live = report.page(id)?.filters ?? []
            case .visual(let id): live = report.pages.lazy.compactMap { $0.visual(id) }.first?.filters ?? []
            }
            return Self.effect(held) != Self.effect(live)
        }
    }
    private static func effect(_ list: [FilterSpec]) -> [FilterSpec] {
        list.filter { !$0.isEmpty }.map { f in
            var e = f
            e.displayName = nil; e.isLocked = false; e.isHidden = false
            return e
        }
    }
}

extension DocumentStore {
    /// What a filter edit invalidates: the visuals at once or, when the report asks for an Apply
    /// button, nothing yet (the list is held as it was, and queries wait for Apply).
    func filterInvalidation(_ immediate: Invalidation, holding target: HeldFilters.Target) -> Invalidation {
        guard report.settings.filterPaneApplyButton else { return immediate }
        let live: [FilterSpec]
        switch target {
        case .report: live = report.filters
        case .page(let id): live = report.page(id)?.filters ?? []
        case .visual(let id): live = visual(id)?.filters ?? []
        }
        ReportRuntime.of(self).heldFilters.hold(target, live)
        return .layout
    }

    /// Run the visuals with the filter edits made since the last Apply.
    func applyPendingFilters() {
        ReportRuntime.existing(for: self)?.heldFilters = HeldFilters()
        refreshVisuals()
    }

    /// Clear every unlocked filter on this page, on its visuals and on the report.
    func clearAllFilters() {
        var probe = report
        guard FilterTools.clearAll(&probe, pageIndex: pageIndex) > 0 else {
            status = StatusMessage(kind: .info, text: "There are no filters to clear. Locked filters stay as they are.")
            return
        }
        let i = pageIndex, page = currentPage
        let targets: [HeldFilters.Target] = [.report, .page(page.id)] + page.visuals.map { .visual($0.id) }
        let invalidation = targets.map { filterInvalidation(.visuals(nil), holding: $0) }.last ?? .visuals(nil)
        mutate("Clear All Filters", invalidates: invalidation) { d in
            FilterTools.clearAll(&d.report, pageIndex: i)
        }
    }

    /// Edit one scope's list of filters as a whole (order, names). Nothing a visual shows changes.
    func editFilterList(_ scope: FilterSpec.Scope, name: String, _ body: (inout [FilterSpec]) -> Void) {
        switch scope {
        case .visual:
            guard let id = selectedVisual?.id else { return }
            updateVisual(id, name: name, invalidates: .layout) { body(&$0.filters) }
        case .page: updatePage(name: name) { body(&$0.filters) }
        case .report: mutate(name, invalidates: .layout) { body(&$0.report.filters) }
        case .drillthrough: updatePage(name: name) { body(&$0.drillthroughFilters) }
        }
    }

    func moveFilter(id: UUID, scope: FilterSpec.Scope, by delta: Int) {
        editFilterList(scope, name: "Reorder Filters") { $0 = FilterTools.moved($0, id: id, by: delta) }
    }

    /// Rename a filter card (an empty name shows the field's own name again).
    func renameFilter(id: UUID, scope: FilterSpec.Scope, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editFilterList(scope, name: "Rename Filter") { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].displayName = trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// Apply and clear controls at the foot of the Filters pane.
struct FilterPaneFooter: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportRuntime

    var body: some View {
        let pending = runtime.filtersPending
        HStack(spacing: Design.Space.s) {
            Button("Clear all") { store.clearAllFilters() }
                .help("Clear every filter that is not locked")
            Spacer(minLength: 0)
            if store.report.settings.filterPaneApplyButton {
                if pending {
                    Text("Changes waiting").font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Apply") { store.applyPendingFilters() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!pending)
                    .help(pending ? "Run the visuals with your filter changes" : "No filter changes are waiting")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }
}

/// The reader's Filters list in the reading view: page and report filters the author left visible.
/// Locked filters are shown but cannot be changed; list filters can be changed value by value.
struct ReaderFiltersPanel: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportRuntime

    var body: some View {
        let page = FilterTools.readerVisible(store.currentPage.filters)
        let all = FilterTools.readerVisible(store.report.filters)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    if page.isEmpty && all.isEmpty {
                        PaneNote("This page has no filters you can see.")
                    }
                    if !page.isEmpty {
                        SectionLabel("Filters on this page")
                        ForEach(page) { ReaderFilterRow(filter: $0, scope: .page) }
                    }
                    if !all.isEmpty {
                        SectionLabel("Filters on all pages")
                        ForEach(all) { ReaderFilterRow(filter: $0, scope: .report) }
                    }
                }
                .padding(Design.Space.m)
            }
            Hairline()
            FilterPaneFooter(runtime: runtime)
        }
        .frame(width: 280, height: 360)
    }
}

private struct ReaderFilterRow: View {
    @EnvironmentObject var store: DocumentStore
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @State private var options: [Value] = []

    var body: some View {
        let editable = FilterTools.readerCanEdit(filter)
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                Text(filter.displayName ?? filter.field.caption).font(Design.Typeface.bodyStrong).lineLimit(1)
                if !editable {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary).help("Locked by the report author")
                }
                Spacer(minLength: 0)
            }
            Text(FilterTools.summary(filter)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if editable, filter.kind == .basic, filter.field.kind == .column {
                ForEach(options.prefix(100), id: \.asString) { value in
                    Toggle(value.asString.isEmpty ? "(Blank)" : value.asString, isOn: Binding(
                        get: { filter.values.contains(value) },
                        set: { _ in store.updateFilter(id: filter.id, scope: scope) { $0 = FilterTools.toggling($0, value) } }))
                        .toggleStyle(.checkbox).font(Design.Typeface.caption)
                }
            }
        }
        .task(id: filter.id) {
            guard filter.kind == .basic, filter.field.kind == .column else { return }
            let field = filter.field
            options = await store.withEngine { $0.distinctValues(field: field, filters: [], limit: 100) }
        }
    }
}
