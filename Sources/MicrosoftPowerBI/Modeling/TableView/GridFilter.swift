import SwiftUI
import FacetCore
import FacetDesign

/// A view-only filter on one grid column: a set of allowed values and/or up to two conditions.
struct GridColumnFilter: Equatable {
    /// Allowed values; nil means every value passes.
    var selected: Set<Value>?
    var conditions: [FilterCondition] = []
    var useOr = false
    var isActive: Bool { selected != nil || !conditions.isEmpty }
}

/// View-only sort and filters for one table in Table view. Never written to the document.
struct GridViewState: Equatable {
    var sortColumn: String?
    var ascending = true
    var filters: [String: GridColumnFilter] = [:]
    var isIdentity: Bool { sortColumn == nil && !filters.values.contains { $0.isActive } }
}

/// Computes the visible row order for a table. Pure; run it off the main thread.
enum GridIndexer {
    /// Row indices to show, in order — nil when the table is shown as stored.
    static func rows(_ table: DataTable, state: GridViewState) -> [Int]? {
        if state.isIdentity { return nil }
        var rows = Array(0..<table.rowCount)
        for (name, filter) in state.filters where filter.isActive {
            guard let ci = table.columnIndex(name) else { continue }
            let values = table.columns[ci].values
            rows = rows.filter { passes(values[$0], filter) }
        }
        if let sort = state.sortColumn, let ci = table.columnIndex(sort) {
            let values = table.columns[ci].values
            if state.ascending {
                rows.sort { a, b in values[a] == values[b] ? a < b : values[a] < values[b] }
            } else {
                rows.sort { a, b in values[a] == values[b] ? a < b : values[b] < values[a] }
            }
        }
        return rows
    }

    static func passes(_ v: Value, _ f: GridColumnFilter) -> Bool {
        if let selected = f.selected, !selected.contains(v) { return false }
        if f.conditions.isEmpty { return true }
        return f.useOr ? f.conditions.contains { matches(v, $0) } : f.conditions.allSatisfy { matches(v, $0) }
    }

    static func matches(_ v: Value, _ c: FilterCondition) -> Bool {
        func text(_ x: Value) -> String { x.asString.lowercased() }
        func comparable(_ a: Value, _ b: Value) -> Bool {
            if a.isNull || b.isNull { return false }
            if a.isNumber && b.isNumber { return true }
            switch (a, b) { case (.date, .date), (.string, .string), (.bool, .bool): return true; default: return false }
        }
        switch c.op {
        case .equals:
            if case .string = v, case .string = c.value { return text(v) == text(c.value) }
            return v == c.value
        case .notEquals:
            if case .string = v, case .string = c.value { return text(v) != text(c.value) }
            return v != c.value
        case .greaterThan: return comparable(v, c.value) && v > c.value
        case .greaterOrEqual: return comparable(v, c.value) && v >= c.value
        case .lessThan: return comparable(v, c.value) && v < c.value
        case .lessOrEqual: return comparable(v, c.value) && v <= c.value
        case .contains: return text(v).contains(text(c.value))
        case .notContains: return !text(v).contains(text(c.value))
        case .startsWith: return text(v).hasPrefix(text(c.value))
        case .notStartsWith: return !text(v).hasPrefix(text(c.value))
        case .endsWith: return text(v).hasSuffix(text(c.value))
        case .isBlank: return v.isNull
        case .isNotBlank: return !v.isNull
        case .isEmpty: return v.isNull || v.asString.isEmpty
        case .isNotEmpty: return !(v.isNull || v.asString.isEmpty)
        }
    }

    /// Operators that make sense for a column type.
    static func operators(for type: DataType) -> [FilterOperator] {
        if type.isNumeric || type.isTemporal {
            return [.equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .isBlank, .isNotBlank]
        }
        if type == .boolean { return [.equals, .notEquals, .isBlank, .isNotBlank] }
        return [.contains, .notContains, .startsWith, .notStartsWith, .endsWith, .equals, .notEquals, .isBlank, .isNotBlank, .isEmpty, .isNotEmpty]
    }

    /// Parses what the user typed into a value of the column's type.
    static func parse(_ text: String, as type: DataType) -> Value {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .null }
        if type.isNumeric { return DataTable.parseNumber(t).map(Value.double) ?? .string(t) }
        if type.isTemporal { return DateParsing.parse(t).map(Value.date) ?? .string(t) }
        if type == .boolean { return Value.string(t).asBool.map(Value.bool) ?? .string(t) }
        return .string(t)
    }
}

/// Popover that edits one column's filter: searchable distinct-values checklist plus conditions.
struct GridFilterEditor: View {
    let columnName: String
    let type: DataType
    let format: String
    let values: [Value]
    let current: GridColumnFilter?
    let apply: (GridColumnFilter?) -> Void
    let close: () -> Void

    @State private var distinct: [Value]?
    @State private var truncated = false
    @State private var checked: Set<Value> = []
    @State private var allChecked = true
    @State private var search = ""
    @State private var op1: FilterOperator = .equals
    @State private var text1 = ""
    @State private var useSecond = false
    @State private var op2: FilterOperator = .equals
    @State private var text2 = ""
    @State private var useOr = false
    @State private var useCondition = false

    private static let limit = 2000
    private var operators: [FilterOperator] { GridIndexer.operators(for: type) }
    private var shown: [Value] {
        guard let distinct else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return distinct }
        return distinct.filter { label($0).lowercased().contains(q) }
    }
    private func label(_ v: Value) -> String { v.isNull ? "(Blank)" : ValueFormatter.format(v, format) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Text("Filter \(columnName)").font(Design.Typeface.bodyStrong)
                TextField("Search values", text: $search).textFieldStyle(.roundedBorder)
            }
            .padding(Design.Space.m)
            Hairline()
            Group {
                if distinct == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    EmptyState(systemImage: "magnifyingglass", title: "No matching values")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            Toggle("Select all", isOn: Binding(get: { allChecked }, set: { on in
                                allChecked = on
                                checked = on ? [] : []
                            }))
                            .font(Design.Typeface.bodyStrong)
                            ForEach(Array(shown.enumerated()), id: \.offset) { _, v in
                                Toggle(label(v), isOn: Binding(get: { allChecked || checked.contains(v) }, set: { on in
                                    if allChecked { allChecked = false; checked = Set(distinct ?? []) }
                                    if on { checked.insert(v) } else { checked.remove(v) }
                                    if let d = distinct, !truncated, checked.count == d.count { allChecked = true; checked = [] }
                                }))
                                .lineLimit(1)
                            }
                            if truncated {
                                Text("Showing the first \(Self.limit.formatted()) values. Use a condition to filter the rest.")
                                    .font(Design.Typeface.caption).foregroundStyle(.tertiary).padding(.top, Design.Space.xs)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 200)
            Hairline()
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Toggle("Show rows where the value", isOn: $useCondition).toggleStyle(.checkbox)
                if useCondition {
                    conditionRow(op: $op1, text: $text1)
                    if useSecond {
                        Picker("", selection: $useOr) { Text("And").tag(false); Text("Or").tag(true) }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        conditionRow(op: $op2, text: $text2)
                    }
                    Button(useSecond ? "Remove second condition" : "Add condition") { useSecond.toggle() }
                        .buttonStyle(.link)
                }
            }
            .padding(Design.Space.m)
            Hairline()
            HStack {
                Button("Clear filter") { apply(nil); close() }.disabled(current?.isActive != true)
                Spacer()
                Button("Apply") { apply(result()); close() }.keyboardShortcut(.defaultAction)
            }
            .padding(Design.Space.m)
        }
        .controlSize(.small)
        .font(Design.Typeface.body)
        .frame(width: 280)
        .task { await load() }
    }

    private func conditionRow(op: Binding<FilterOperator>, text: Binding<String>) -> some View {
        HStack(spacing: Design.Space.s) {
            Picker("Operator", selection: op) {
                ForEach(operators, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: 130)
            if op.wrappedValue.needsValue {
                TextField(type.isTemporal ? "2026-01-31" : "Value", text: text).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func load() async {
        if let c = current {
            if let s = c.selected { allChecked = false; checked = s }
            if let first = c.conditions.first {
                useCondition = true; op1 = first.op; text1 = first.value.asString
                if c.conditions.count > 1 { useSecond = true; op2 = c.conditions[1].op; text2 = c.conditions[1].value.asString; useOr = c.useOr }
            }
        }
        if !operators.contains(op1) { op1 = operators[0] }
        if !operators.contains(op2) { op2 = operators[0] }
        let values = values, limit = Self.limit
        let (list, more) = await Task.detached(priority: .userInitiated) { () -> ([Value], Bool) in
            let sorted = Set(values).sorted()
            return (Array(sorted.prefix(limit)), sorted.count > limit)
        }.value
        distinct = list
        truncated = more
    }

    private func result() -> GridColumnFilter? {
        var f = GridColumnFilter()
        if !allChecked { f.selected = checked }
        if useCondition {
            f.conditions.append(FilterCondition(op: op1, value: GridIndexer.parse(text1, as: type)))
            if useSecond { f.conditions.append(FilterCondition(op: op2, value: GridIndexer.parse(text2, as: type))) }
            f.useOr = useOr
        }
        return f.isActive ? f : nil
    }
}
