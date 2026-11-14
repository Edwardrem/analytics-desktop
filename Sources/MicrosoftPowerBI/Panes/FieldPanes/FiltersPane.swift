import SwiftUI
import FacetCore
import FacetDesign

/// The Filters pane, laid out as Power BI's: a search over every card, then Filters on this
/// visual, on this page and on all pages (and Drillthrough), each a stack of filter cards. Filters
/// are added from the Data pane's field menu.
struct FiltersPane: View {
    @EnvironmentObject var store: DocumentStore
    @State private var query = ""

    var body: some View {
        let visual = store.selectedVisual
        let lists: [(scope: FilterSpec.Scope, filters: [FilterSpec])] = (visual.map { [(.visual, $0.filters)] } ?? [])
            + [(.page, store.currentPage.filters), (.report, store.doc.report.filters), (.drillthrough, store.drillthroughDisplay)]
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let found = lists.reduce(0) { $0 + FilterCardLogic.listed($1.filters, query: query).count }
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search filters")
                .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    ForEach(lists, id: \.scope) { list in
                        if !searching || !FilterCardLogic.listed(list.filters, query: query).isEmpty {
                            FiltersSection(scope: list.scope, filters: list.filters, query: query)
                        }
                    }
                    if searching && found == 0 {
                        PaneNote("No filter matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                    }
                }
                .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.xs).padding(.bottom, Design.Space.m)
            }
            Hairline()
            FilterPaneFooter(runtime: ReportRuntime.of(store))
        }
    }
}

// MARK: Section

private struct FiltersSection: View {
    let scope: FilterSpec.Scope
    let filters: [FilterSpec]
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(title).font(Design.Typeface.captionStrong).foregroundStyle(.secondary).lineLimit(1)
                if !filters.isEmpty {
                    Text("\(filters.count)").font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            if filters.isEmpty {
                Text(hint).font(Design.Typeface.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(FilterCardLogic.listed(filters, query: query), id: \.filter.id) { item in
                    FilterCard(filter: item.filter, scope: scope, position: item.position, count: filters.count)
                }
            }
        }
    }

    private var title: String {
        switch scope {
        case .visual: return "Filters on this visual"
        case .page: return "Filters on this page"
        case .report: return "Filters on all pages"
        case .drillthrough: return "Drillthrough"
        }
    }

    private var hint: String {
        switch scope {
        case .visual: return "Add a filter for this visual from the Data pane's field menu."
        case .page: return "Add a page filter from the Data pane's field menu."
        case .report: return "Add a filter that applies to every page from the Data pane."
        case .drillthrough: return "Add a column from the Data pane’s field menu to make this page a drillthrough destination."
        }
    }
}

// MARK: Editor

/// A filter card's editor: the filter type, then what that type asks for.
struct FilterEditor: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Picker("Filter type", selection: kind) {
                Text("List").tag(FilterSpec.Kind.basic)
                Text("Advanced").tag(FilterSpec.Kind.advanced)
                Text("Top N").tag(FilterSpec.Kind.topN)
                Text("Relative date").tag(FilterSpec.Kind.relativeDate)
                Text("Relative time").tag(FilterSpec.Kind.relativeTime)
            }
            .pickerStyle(.segmented).labelsHidden()
            switch filter.kind {
            case .basic: BasicValuesEditor(filter: filter, scope: scope)
            case .advanced: AdvancedConditionsEditor(filter: filter, scope: scope)
            case .topN: TopNEditor(filter: filter, scope: scope)
            case .relativeDate, .relativeTime: RelativeEditor(filter: filter, scope: scope)
            }
        }
    }

    private var kind: Binding<FilterSpec.Kind> {
        Binding(get: { filter.kind }, set: { newKind in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter Type") { FilterEditing.setKind(newKind, of: &$0) }
        })
    }
}

/// The edits the Filters pane makes to a filter, kept apart from the views so they can be tested.
enum FilterEditing {
    /// Switches a filter to another type, carrying over what makes sense.
    static func setKind(_ kind: FilterSpec.Kind, of f: inout FilterSpec) {
        guard f.kind != kind else { return }
        f.kind = kind
        switch kind {
        case .basic: f.values = f.conditions.map(\.value)
        case .advanced: f.conditions = [FilterCondition(op: .equals, value: f.values.first ?? .null)]
        case .topN: f.topN = TopNFilter()
        case .relativeDate, .relativeTime: f.relative = RelativeDateFilter()
        }
    }

    /// What a Top N filter can rank by (its By value well): every visible measure, then every
    /// visible numeric column with the summarization it gets in a visual.
    static func topNCandidates(_ model: SemanticModel) -> [FieldRef] {
        var out: [FieldRef] = []
        for (table, measure) in model.allMeasures where !measure.isHidden {
            out.append(.measure(table, measure.name))
        }
        for table in model.tables where !table.isHidden {
            for column in table.columns where !column.isHidden && column.dataType.isNumeric {
                let aggregation: Aggregation = column.summarizeBy == .none ? .sum : column.summarizeBy
                out.append(.column(table.name, column.name, aggregation))
            }
        }
        return out
    }

    /// Sets (or, with nil, clears) the field a Top N filter ranks by.
    static func setTopNBy(_ field: FieldRef?, of f: inout FilterSpec) {
        f.topN.by = field
    }
}

// MARK: Basic values

private struct BasicValuesEditor: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore
    @State private var options: [Value] = []
    @State private var loadedFor: UUID?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if options.count > 10 {
                SearchField(text: $search, prompt: "Search values").padding(.bottom, Design.Space.xs)
            }
            if filter.values.isEmpty {
                Text("Nothing is selected, so the filter is inactive.").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            }
            ForEach(displayed, id: \.asString) { value in
                Button { toggleValue(value) } label: {
                    HStack {
                        Image(systemName: selected.contains(value) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected.contains(value) ? Color.accentColor : Color.secondary)
                        Text(value.asString.isEmpty ? "(blank)" : value.asString).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 1)
            }
        }
        .task(id: filter.id) { await load() }
    }

    private var selected: Set<Value> { Set(filter.values) }
    private var displayed: [Value] {
        let base = options.isEmpty ? filter.values : options
        let term = search.trimmingCharacters(in: .whitespaces)
        let shown = term.isEmpty ? base : base.filter { $0.asString.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return Array(shown.prefix(200))
    }

    private func toggleValue(_ value: Value) {
        store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { $0 = FilterTools.toggling($0, value) }
    }

    private func load() async {
        guard loadedFor != filter.id else { return }
        loadedFor = filter.id
        guard filter.field.kind == .column else { return }
        let field = filter.field
        let others = store.otherFilters(excluding: filter.id)
        let values = await store.withEngine { $0.distinctValues(field: field, filters: others, limit: 200) }
        if !values.isEmpty { options = values }
    }
}

private extension DocumentStore {
    /// Every filter that would apply, except the one being edited (so the value list shows the
    /// options that remain under the other conditions).
    func otherFilters(excluding id: UUID) -> [FilterSpec] {
        var all = doc.report.filters + currentPage.filters
        if let visual = selectedVisual { all += visual.filters }
        all += drillthroughFilters[currentPageID] ?? []
        return all.filter { $0.id != id && !$0.isEmpty }
    }
}

/// A small literal parser for filter value text.
private enum PBIExprLite {
    static func parseLiteral(_ text: String) -> Value {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .null }
        if s.lowercased() == "true" { return .bool(true) }
        if s.lowercased() == "false" { return .bool(false) }
        if let n = DataTable.parseNumber(s) { return .double(n) }
        if let d = DateParsing.parse(s) { return .date(d) }
        return .string(text)
    }
}

// MARK: Advanced conditions

private struct AdvancedConditionsEditor: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            ForEach(filter.conditions.indices, id: \.self) { i in
                HStack(spacing: Design.Space.xs) {
                    Picker("", selection: opBinding(i)) {
                        ForEach(FilterOperator.allCases, id: \.self) { op in
                            Text(op.displayName).tag(op)
                        }
                    }
                    .labelsHidden()
                    if filter.conditions[safe: i]?.op.needsValue == true {
                        CommitTextField("Value", text: filter.conditions[safe: i]?.value.asString ?? "") { text in
                            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
                                if f.conditions.indices.contains(i) { f.conditions[i].value = PBIExprLite.parseLiteral(text) }
                            }
                        }
                        .multilineTextAlignment(.trailing)
                    }
                    Button {
                        store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
                            if f.conditions.indices.contains(i) { f.conditions.remove(at: i) }
                        }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add condition") {
                store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
                    f.conditions.append(FilterCondition(op: .equals, value: .string("")))
                }
            }
            .buttonStyle(.link).font(Design.Typeface.caption)
        }
    }

    private func opBinding(_ i: Int) -> Binding<FilterOperator> {
        Binding(get: { filter.conditions[safe: i]?.op ?? .equals }, set: { op in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
                if f.conditions.indices.contains(i) { f.conditions[i].op = op }
            }
        })
    }
}

// MARK: Top N

private struct TopNEditor: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Picker("Direction", selection: direction) {
                Text("Top").tag(false)
                Text("Bottom").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Show").font(Design.Typeface.caption).foregroundStyle(.secondary)
                CommitNumberField(value: Double(filter.topN.count), width: 56) { v in
                    store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
                        f.topN.count = max(1, Int(v))
                    }
                }
            }
            // The By value well: what the items are ranked by. Without it the filter does nothing.
            Picker("By value", selection: by) {
                Text("Choose a value").tag(String?.none)
                ForEach(candidates, id: \.key) { field in
                    Text(field.caption).tag(String?.some(field.key))
                }
            }
            .font(Design.Typeface.caption)
            if filter.topN.by == nil {
                Text("Choose the value that ranks the items.").font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var candidates: [FieldRef] { FilterEditing.topNCandidates(store.model) }

    private var by: Binding<String?> {
        Binding(get: { filter.topN.by?.key }, set: { key in
            let field = key.flatMap { k in candidates.first { $0.key == k } }
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { FilterEditing.setTopNBy(field, of: &$0) }
        })
    }

    private var direction: Binding<Bool> {
        Binding(get: { filter.topN.isBottom }, set: { isBottom in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { $0.topN.isBottom = isBottom }
        })
    }
}

// MARK: Relative date

private struct RelativeEditor: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Picker("Direction", selection: direction) {
                Text("Last").tag(RelativeDateFilter.Direction.last)
                Text("This").tag(RelativeDateFilter.Direction.this)
                Text("Next").tag(RelativeDateFilter.Direction.next)
            }
            .pickerStyle(.segmented).labelsHidden()
            if filter.relative.direction != .this {
                HStack {
                    Text("of the previous").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    CommitNumberField(value: Double(filter.relative.count), width: 56) { v in
                        store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
                            f.relative.count = max(1, Int(v))
                        }
                    }
                    Picker("Unit", selection: unit) {
                        ForEach(units, id: \.0) { unit in Text(unit.1).tag(unit.0) }
                    }
                    .labelsHidden()
                }
                Toggle("Include today", isOn: includeToday)
            }
        }
    }

    private var units: [(RelativeDateFilter.Unit, String)] {
        filter.kind == .relativeTime
            ? [(.minutes, "minutes"), (.hours, "hours"), (.days, "days")]
            : [(.days, "days"), (.weeks, "weeks"), (.calendarWeeks, "calendar weeks"), (.months, "months"),
               (.calendarMonths, "calendar months"), (.years, "years"), (.calendarYears, "calendar years")]
    }

    private var direction: Binding<RelativeDateFilter.Direction> {
        Binding(get: { filter.relative.direction }, set: { d in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { $0.relative.direction = d }
        })
    }
    private var unit: Binding<RelativeDateFilter.Unit> {
        Binding(get: { filter.relative.unit }, set: { u in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { $0.relative.unit = u }
        })
    }
    private var includeToday: Binding<Bool> {
        Binding(get: { filter.relative.includeToday }, set: { b in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { $0.relative.includeToday = b }
        })
    }
}
