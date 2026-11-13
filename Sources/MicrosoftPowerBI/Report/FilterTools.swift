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

    /// Filters a reader sees: hidden ones still apply but are not listed.
    static func readerVisible(_ filters: [FilterSpec]) -> [FilterSpec] { filters.filter { !$0.isHidden } }
    /// A reader may change a filter unless its author locked it.
    static func readerCanEdit(_ filter: FilterSpec) -> Bool { !filter.isLocked }

    /// One line describing what a filter keeps.
    static func summary(_ filter: FilterSpec) -> String {
        switch filter.kind {
        case .basic:
            guard !filter.values.isEmpty else { return "All" }
            let values = filter.values.prefix(6).map { $0.asString.isEmpty ? "(blank)" : $0.asString }.joined(separator: ", ")
            let more = filter.values.count > 6 ? ", …" : ""
            return filter.isInverted ? "is not \(values)\(more)" : "is \(values)\(more)"
        case .advanced:
            guard !filter.conditions.isEmpty else { return "All" }
            return filter.conditions.map { $0.op.needsValue ? "\($0.op.displayName) \($0.value.asString)" : $0.op.displayName }
                .joined(separator: filter.conditionsUseOr ? " or " : " and ")
        case .topN:
            guard let by = filter.topN.by else { return "All" }
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
            switch filter.relative.direction {
            case .this: return "This \(String(unit.dropLast()))"
            case .last: return "Last \(filter.relative.count) \(unit)"
            case .next: return "Next \(filter.relative.count) \(unit)"
            }
        }
    }
}

extension DocumentStore {
    /// What a filter edit invalidates: the visuals at once, or nothing yet when the report asks for
    /// an Apply button (the edit is saved, and queries wait for Apply).
    func filterInvalidation(_ immediate: Invalidation) -> Invalidation {
        guard report.settings.filterPaneApplyButton else { return immediate }
        ReportRuntime.of(self).filtersPending = true
        return .layout
    }

    /// Run the queries for filter edits made since the last Apply.
    func applyPendingFilters() {
        ReportRuntime.of(self).filtersPending = false
        refreshVisuals()
    }

    /// Clear every unlocked filter on this page, on its visuals and on the report.
    func clearAllFilters() {
        var probe = report
        guard FilterTools.clearAll(&probe, pageIndex: pageIndex) > 0 else {
            status = StatusMessage(kind: .info, text: "There are no filters to clear. Locked filters stay as they are.")
            return
        }
        let i = pageIndex
        mutate("Clear All Filters", invalidates: filterInvalidation(.visuals(nil))) { d in
            FilterTools.clearAll(&d.report, pageIndex: i)
        }
    }
}

/// Apply and clear controls at the foot of the Filters pane.
struct FilterPaneFooter: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportRuntime

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Button("Clear all") { store.clearAllFilters() }
                .help("Clear every filter that is not locked")
            Spacer(minLength: 0)
            if store.report.settings.filterPaneApplyButton {
                Button("Apply") { store.applyPendingFilters() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!runtime.filtersPending)
                    .help(runtime.filtersPending ? "Run the visuals with your filter changes" : "No filter changes are waiting")
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
                    Toggle(value.asString.isEmpty ? "(blank)" : value.asString, isOn: Binding(
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
