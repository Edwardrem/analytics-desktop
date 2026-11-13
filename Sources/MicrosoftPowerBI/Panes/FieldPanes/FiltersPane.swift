import SwiftUI
import FacetCore
import FacetDesign

/// The Filters pane: visual-level, page-level, report-level and drillthrough filters, with the
/// filter types Power BI offers. Filters are added from the Data pane's field menu.
struct FiltersPane: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let visual = store.selectedVisual {
                        FiltersSection(visual: visual, scope: .visual, title: "Filters on this visual", filters: visual.filters)
                    }
                    FiltersSection(scope: .page, title: "Filters on this page", filters: store.currentPage.filters)
                    FiltersSection(scope: .report, title: "Filters on all pages", filters: store.doc.report.filters)
                    FiltersSection(scope: .drillthrough, title: "Drillthrough", filters: store.drillthroughDisplay)
                }
            }
            Hairline()
            FilterPaneFooter(runtime: ReportRuntime.of(store))
        }
    }
}

// MARK: Section

private struct FiltersSection: View {
    var visual: VisualSpec?
    let scope: FilterSpec.Scope
    let title: String
    let filters: [FilterSpec]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Text(title).font(Design.Typeface.bodyStrong).lineLimit(1)
                if !filters.isEmpty {
                    Text("\(filters.count)").font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            if filters.isEmpty {
                Text(hint).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    .padding(.bottom, Design.Space.m)
            } else {
                ForEach(Array(filters.enumerated()), id: \.element.id) { i, f in
                    FilterRow(filter: f, scope: scope, position: i, count: filters.count)
                }
                .padding(.bottom, Design.Space.s)
            }
            Hairline()
        }
        .padding(.horizontal, Design.Space.m)
    }

    private var hint: String {
        switch scope {
        case .visual: return "Select a visual, then add a filter from the Data pane's field menu."
        case .page: return "Add a page filter from the Data pane's field menu."
        case .report: return "Add a filter that applies to every page from the Data pane."
        case .drillthrough: return "Add a column from the Data pane’s field menu to make this page a drillthrough destination."
        }
    }
}

// MARK: Row

private struct FilterRow: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    let position: Int
    let count: Int
    @EnvironmentObject var store: DocumentStore
    @State private var expanded = false
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary).frame(width: 10)
                        if !renaming {
                            Text(filter.displayName ?? filter.field.caption).font(Design.Typeface.bodyStrong).lineLimit(1)
                            Text(typeName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) {
                    if renaming {
                        CommitTextField(filter.field.caption, text: filter.displayName ?? filter.field.caption) { name in
                            store.renameFilter(id: filter.id, scope: scope, to: name)
                            renaming = false
                        }
                        .padding(.leading, 14)
                        .onExitCommand { renaming = false }
                    }
                }
                if filter.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if filter.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Menu {
                    Button("Rename…") { renaming = true }
                    Button("Move Up") { store.moveFilter(id: filter.id, scope: scope, by: -1) }.disabled(position == 0)
                    Button("Move Down") { store.moveFilter(id: filter.id, scope: scope, by: 1) }.disabled(position >= count - 1)
                    Divider()
                    Button(filter.isLocked ? "Unlock" : "Lock") { toggle { $0.isLocked.toggle() } }
                    Button(filter.isHidden ? "Show" : "Hide") { toggle { $0.isHidden.toggle() } }
                    if filter.kind == .basic {
                        Button(filter.requireSingleSelection ? "Allow multiple selections" : "Require single selection") {
                            toggle { $0 = FilterTools.requiringSingleSelection($0, !$0.requireSingleSelection) }
                        }
                        Button(filter.isInverted ? "Keep selected values" : "Exclude selected values") { toggle { $0.isInverted.toggle() } }
                    }
                    if filter.kind == .advanced {
                        Button(filter.conditionsUseOr ? "Match all conditions" : "Match any condition") { toggle { $0.conditionsUseOr.toggle() } }
                    }
                    Button("Clear filter") { toggle { $0 = FilterTools.cleared($0) } }
                    Button("Remove", role: .destructive) { store.removeFilter(id: filter.id, scope: scope) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Filter options")
            }
            Text(FilterTools.summary(filter)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14)
            if expanded {
                FilterEditor(filter: filter, scope: scope)
                    .padding(.leading, 14)
            }
            Hairline()
        }
        .padding(.vertical, Design.Space.xs)
    }

    private var typeName: String {
        switch filter.kind {
        case .basic: return filter.isInverted ? "Exclude" : "List"
        case .advanced: return "Advanced"
        case .topN: return "Top N"
        case .relativeDate: return "Relative date"
        case .relativeTime: return "Relative time"
        }
    }

    private func toggle(_ body: (inout FilterSpec) -> Void) {
        store.updateFilter(id: filter.id, scope: scope, body)
    }
}

// MARK: Editor

private struct FilterEditor: View {
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
        .padding(Design.Space.s)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Design.Palette.fill))
    }

    private var kind: Binding<FilterSpec.Kind> {
        Binding(get: { filter.kind }, set: { newKind in
            store.updateFilter(id: filter.id, scope: scope, name: "Change Filter Type") { f in
                guard f.kind != newKind else { return }
                f.kind = newKind
                switch newKind {
                case .basic: f.values = f.conditions.map(\.value)
                case .advanced: f.conditions = [FilterCondition(op: .equals, value: f.values.first ?? .null)]
                case .topN: f.topN = TopNFilter()
                case .relativeDate, .relativeTime: f.relative = RelativeDateFilter()
                }
            }
        })
    }
}

// MARK: Basic values

private struct BasicValuesEditor: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore
    @State private var options: [Value] = []
    @State private var loadedFor: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        return Array(base.prefix(200))
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
        }
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
