import SwiftUI
import FacetCore
import FacetDesign

/// The Filters pane: visual-level, page-level, report-level and drillthrough filters, with the
/// filter types Power BI offers. Filters are added from the Data pane's field menu.
struct FiltersPane: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let visual = store.selectedVisual {
                    FiltersSection(visual: visual, scope: .visual, title: "Filters on this visual", filters: visual.filters)
                }
                FiltersSection(scope: .page, title: "Filters on this page", filters: store.currentPage.filters)
                FiltersSection(scope: .report, title: "Filters on all pages", filters: store.doc.report.filters)
                FiltersSection(scope: .drillthrough, title: "Drillthrough", filters: store.drillthroughFilters[store.currentPageID] ?? [])
            }
        }
    }

    /// Every filter that would apply, except the one being edited (so the value list shows the
    /// options that remain under the other conditions).
    func otherFilters(excluding id: UUID) -> [FilterSpec] {
        var all = store.doc.report.filters + store.currentPage.filters
        if let visual = store.selectedVisual { all += visual.filters }
        all += store.drillthroughFilters[store.currentPageID] ?? []
        return all.filter { $0.id != id && !$0.isEmpty }
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
                ForEach(filters) { f in
                    FilterRow(filter: f, scope: scope)
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
        case .drillthrough: return "Drillthrough filters arrive when a visual is drilled into."
        }
    }
}

// MARK: Row

private struct FilterRow: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    @EnvironmentObject var store: DocumentStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary).frame(width: 10)
                        Text(filter.field.caption).font(Design.Typeface.bodyStrong).lineLimit(1)
                        Text(typeName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if filter.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if filter.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Menu {
                    Button(filter.isLocked ? "Unlock" : "Lock") { toggle { $0.isLocked.toggle() } }
                    Button(filter.isHidden ? "Show" : "Hide") { toggle { $0.isHidden.toggle() } }
                    if filter.kind == .basic {
                        Button(filter.isInverted ? "Keep selected values" : "Exclude selected values") { toggle { $0.isInverted.toggle() } }
                    }
                    if filter.kind == .advanced {
                        Button(filter.conditionsUseOr ? "Match all conditions" : "Match any condition") { toggle { $0.conditionsUseOr.toggle() } }
                    }
                    Button("Clear filter") { toggle { f in clear(&f) } }
                    Button("Remove", role: .destructive) { store.removeFilter(id: filter.id, scope: scope) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(summary).font(Design.Typeface.caption).foregroundStyle(.secondary)
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

    private var summary: String {
        if filter.isEmpty && filter.kind != .relativeDate && filter.kind != .relativeTime { return "No condition." }
        switch filter.kind {
        case .basic:
            let values = filter.values.prefix(6).map(\.asString).joined(separator: ", ")
            let more = filter.values.count > 6 ? ", …" : ""
            return filter.isInverted ? "is not \(values)\(more)" : "is \(values)\(more)"
        case .advanced:
            return filter.conditions.map { "\($0.op.displayName) \($0.value.asString)" }
                .joined(separator: filter.conditionsUseOr ? " or " : " and ")
        case .topN:
            let direction = filter.topN.isBottom ? "Bottom" : "Top"
            let by = filter.topN.by.map { " by \($0.caption)" } ?? ""
            return "\(direction) \(filter.topN.count)\(by)"
        case .relativeDate, .relativeTime:
            let unit = relativeUnitName
            switch filter.relative.direction {
            case .this: return "This \(unit)"
            case .last: return "Last \(filter.relative.count) \(unit)\(filter.relative.includeToday ? " including today" : "")"
            case .next: return "Next \(filter.relative.count) \(unit)\(filter.relative.includeToday ? " including today" : "")"
            }
        }
    }

    private var relativeUnitName: String {
        switch filter.relative.unit {
        case .minutes: return "minutes"
        case .hours: return "hours"
        case .days: return "days"
        case .weeks, .calendarWeeks: return "weeks"
        case .months, .calendarMonths: return "months"
        case .years, .calendarYears: return "years"
        }
    }

    private func toggle(_ body: (inout FilterSpec) -> Void) {
        store.updateFilter(id: filter.id, scope: scope, body)
    }

    private func clear(_ f: inout FilterSpec) {
        switch f.kind {
        case .basic: f.values = []
        case .advanced: f.conditions = []
        case .topN: f.topN = TopNFilter()
        case .relativeDate, .relativeTime: break
        }
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
        store.updateFilter(id: filter.id, scope: scope, name: "Change Filter") { f in
            if let i = f.values.firstIndex(where: { $0 == value }) { f.values.remove(at: i) }
            else { f.values.append(value) }
        }
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
