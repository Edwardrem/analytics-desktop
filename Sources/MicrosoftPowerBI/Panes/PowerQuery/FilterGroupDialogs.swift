import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// Power Query's row filter (FacetCore has a report-filter type of the same name).
typealias RowFilter = FacetQuery.FilterCondition

// MARK: - Filter rows

/// One condition of the Filter Rows dialog.
struct FilterClause: Equatable {
    enum Op: String, CaseIterable {
        case equals, notEquals, greater, greaterOrEqual, less, lessOrEqual
        case beginsWith, notBeginsWith, endsWith, notEndsWith, contains, notContains
        case isNull, isNotNull, isEarliest, isLatest
        case inPrevious, inNext, inCurrent, yearToDate

        func title(for type: DataType) -> String {
            let temporal = type.isTemporal
            switch self {
            case .equals: return temporal ? "is" : "equals"
            case .notEquals: return temporal ? "is not" : "does not equal"
            case .greater: return temporal ? "is after" : "is greater than"
            case .greaterOrEqual: return temporal ? "is after or equal to" : "is greater than or equal to"
            case .less: return temporal ? "is before" : "is less than"
            case .lessOrEqual: return temporal ? "is before or equal to" : "is less than or equal to"
            case .beginsWith: return "begins with"
            case .notBeginsWith: return "does not begin with"
            case .endsWith: return "ends with"
            case .notEndsWith: return "does not end with"
            case .contains: return "contains"
            case .notContains: return "does not contain"
            case .isNull: return "is null"
            case .isNotNull: return "is not null"
            case .isEarliest: return "is earliest"
            case .isLatest: return "is latest"
            case .inPrevious: return "is in the previous"
            case .inNext: return "is in the next"
            case .inCurrent: return "is in the current"
            case .yearToDate: return "is year to date"
            }
        }
        var needsValue: Bool { ![.isNull, .isNotNull, .isEarliest, .isLatest, .inCurrent, .yearToDate].contains(self) }
        /// Relative date conditions take a unit (days, weeks, months, quarters, years).
        var needsUnit: Bool { [.inPrevious, .inNext, .inCurrent].contains(self) }

        /// The operators offered for a column type.
        static func offered(for type: DataType) -> [Op] {
            let compare: [Op] = [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual]
            switch type {
            case .text: return [.equals, .notEquals, .beginsWith, .notBeginsWith, .endsWith, .notEndsWith, .contains, .notContains, .isNull, .isNotNull]
            case .date, .dateTime: return compare + [.inPrevious, .inNext, .inCurrent, .yearToDate, .isEarliest, .isLatest, .isNull, .isNotNull]
            case .time: return compare + [.isEarliest, .isLatest, .isNull, .isNotNull]
            case .any: return compare + [.beginsWith, .endsWith, .contains, .notContains, .isNull, .isNotNull]
            default: return compare + [.isNull, .isNotNull]
            }
        }
    }
    var column: String
    var op: Op = .equals
    var value = ""
    /// Joins this clause to the ones before it (ignored for the first).
    var and = true
    var unit: RowFilter.DateUnit = .day

    func condition(type: DataType) -> RowFilter {
        let v = EditorValues.parse(value, as: type)
        switch op {
        case .equals: return .compare(column: column, .equals, v, type: type)
        case .notEquals: return .compare(column: column, .notEquals, v, type: type)
        case .greater: return .compare(column: column, .greaterThan, v, type: type)
        case .greaterOrEqual: return .compare(column: column, .greaterOrEqual, v, type: type)
        case .less: return .compare(column: column, .lessThan, v, type: type)
        case .lessOrEqual: return .compare(column: column, .lessOrEqual, v, type: type)
        case .beginsWith: return .text(column: column, .beginsWith, value)
        case .notBeginsWith: return .text(column: column, .doesNotBeginWith, value)
        case .endsWith: return .text(column: column, .endsWith, value)
        case .notEndsWith: return .text(column: column, .doesNotEndWith, value)
        case .contains: return .text(column: column, .contains, value)
        case .notContains: return .text(column: column, .doesNotContain, value)
        case .isNull: return .isNull(column: column)
        case .isNotNull: return .isNotNull(column: column)
        case .isEarliest: return .date(column: column, .isEarliest)
        case .isLatest: return .date(column: column, .isLatest)
        case .inPrevious:
            let n = max(1, Int(value.trimmingCharacters(in: .whitespaces)) ?? 1)
            return .date(column: column, n == 1 ? .inPrevious(unit) : .inPreviousN(n, unit))
        case .inNext:
            let n = max(1, Int(value.trimmingCharacters(in: .whitespaces)) ?? 1)
            return .date(column: column, n == 1 ? .inNext(unit) : .inNextN(n, unit))
        case .inCurrent: return .date(column: column, .inCurrent(unit))
        case .yearToDate: return .date(column: column, .yearToDate)
        }
    }

    /// Clauses joined left to right with their And / Or (consecutive joins of one kind share a group).
    static func combine(_ clauses: [FilterClause], types: [String: DataType]) -> RowFilter? {
        guard let first = clauses.first else { return nil }
        var acc = first.condition(type: types[first.column] ?? .any)
        for c in clauses.dropFirst() {
            let next = c.condition(type: types[c.column] ?? .any)
            switch (acc, c.and) {
            case (.and(let parts), true): acc = .and(parts + [next])
            case (.or(let parts), false): acc = .or(parts + [next])
            default: acc = c.and ? .and([acc, next]) : .or([acc, next])
            }
        }
        return acc
    }

    /// The clauses of a condition the dialog can show (nil when the condition needs the custom formula).
    static func clauses(of condition: RowFilter, types: [String: DataType]) -> [FilterClause]? {
        func one(_ c: RowFilter) -> FilterClause? {
            switch c {
            case .compare(let col, let cmp, let v, _):
                let op: Op
                switch cmp {
                case .equals: op = .equals
                case .notEquals: op = .notEquals
                case .greaterThan: op = .greater
                case .greaterOrEqual: op = .greaterOrEqual
                case .lessThan: op = .less
                case .lessOrEqual: op = .lessOrEqual
                }
                return FilterClause(column: col, op: op, value: EditorValues.text(v, type: types[col] ?? .any))
            case .text(let col, let m, let s, false):
                let op: Op
                switch m {
                case .beginsWith: op = .beginsWith
                case .doesNotBeginWith: op = .notBeginsWith
                case .endsWith: op = .endsWith
                case .doesNotEndWith: op = .notEndsWith
                case .contains: op = .contains
                case .doesNotContain: op = .notContains
                }
                return FilterClause(column: col, op: op, value: s)
            case .isNull(let col): return FilterClause(column: col, op: .isNull)
            case .isNotNull(let col): return FilterClause(column: col, op: .isNotNull)
            case .date(let col, .isEarliest): return FilterClause(column: col, op: .isEarliest)
            case .date(let col, .isLatest): return FilterClause(column: col, op: .isLatest)
            case .date(let col, .inPrevious(let u)): return FilterClause(column: col, op: .inPrevious, value: "1", unit: u)
            case .date(let col, .inPreviousN(let n, let u)): return FilterClause(column: col, op: .inPrevious, value: "\(n)", unit: u)
            case .date(let col, .inNext(let u)): return FilterClause(column: col, op: .inNext, value: "1", unit: u)
            case .date(let col, .inNextN(let n, let u)): return FilterClause(column: col, op: .inNext, value: "\(n)", unit: u)
            case .date(let col, .inCurrent(let u)): return FilterClause(column: col, op: .inCurrent, unit: u)
            case .date(let col, .yearToDate): return FilterClause(column: col, op: .yearToDate)
            default: return nil
            }
        }
        switch condition {
        case .and(let parts), .or(let parts):
            var isAnd = false
            if case .and = condition { isAnd = true }
            var out: [FilterClause] = []
            for p in parts {
                guard var c = one(p) else { return nil }
                c.and = isAnd
                out.append(c)
            }
            return out.isEmpty ? nil : out
        default:
            return one(condition).map { [$0] }
        }
    }
}

struct FilterRowsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    /// The column the dialog opened on (nil when editing a step).
    let column: String?
    let edit: StepEdit?
    enum Mode: String, CaseIterable { case values = "Values", basic = "Basic", advanced = "Advanced", formula = "Formula" }
    @State private var mode = Mode.basic
    @State private var clauses: [FilterClause] = []
    @State private var formula = ""
    @State private var search = ""
    @State private var keep: Set<Value> = []
    @Environment(\.dismiss) private var dismiss

    private var types: [String: DataType] { Dictionary(table.columns.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a }) }
    private var focus: String { column ?? clauses.first?.column ?? table.columnNames.first ?? "" }
    private var distinct: [Value] {
        var seen = Set<Value>(), out: [Value] = []
        for v in table.column(focus)?.values ?? [] where seen.insert(v).inserted { out.append(v) }
        return out.sorted()
    }

    var body: some View {
        DialogChrome(title: "Filter Rows", subtitle: "Keep the rows that match these conditions.", canCommit: canCommit, width: 600, commit: done) {
            Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            switch mode {
            case .values: valueList
            case .basic, .advanced: clauseList
            case .formula:
                Text("A condition over each row, for example [Amount] > 100 and [Region] <> \"North\".").font(Design.Typeface.caption).foregroundStyle(.secondary)
                TextEditor(text: $formula).font(Design.Typeface.mono).frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            }
        }
        .onAppear(perform: load)
        .onChange(of: mode) { _, m in if m == .basic { clauses = clauses.map { var c = $0; c.column = focus; return c } } }
    }

    private var valueList: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            Toggle("(Select All)", isOn: Binding(get: { keep.count == distinct.count }, set: { keep = $0 ? Set(distinct) : [] }))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let type = types[focus] ?? .any
                    ForEach(distinct.filter { search.isEmpty || EditorValues.text($0, type: type).localizedCaseInsensitiveContains(search) }, id: \.self) { v in
                        Toggle(EditorValues.text(v, type: type), isOn: Binding(get: { keep.contains(v) }, set: { if $0 { keep.insert(v) } else { keep.remove(v) } }))
                    }
                }
            }
            .frame(height: 220)
            if table.rowCount >= QueryEditorSession.previewRows {
                Text("The list shows values of the first \(QueryEditorSession.previewRows) rows.").font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var clauseList: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            ForEach(clauses.indices, id: \.self) { i in
                HStack(spacing: Design.Space.xs) {
                    if i > 0 {
                        Picker("Join", selection: $clauses[i].and) { Text("And").tag(true); Text("Or").tag(false) }.labelsHidden().frame(width: 70)
                    } else {
                        Text(mode == .basic ? "“\(focus)”" : "Keep rows where").font(Design.Typeface.caption).frame(width: 70, alignment: .leading).lineLimit(1)
                    }
                    if mode == .advanced {
                        Picker("Column", selection: $clauses[i].column) { ForEach(table.columnNames, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 140)
                    }
                    let type = types[clauses[i].column] ?? .any
                    Picker("Operator", selection: $clauses[i].op) {
                        ForEach(FilterClause.Op.offered(for: type), id: \.self) { Text($0.title(for: type)).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                    if clauses[i].op.needsValue {
                        TextField(clauses[i].op.needsUnit ? "1" : type.isTemporal ? "yyyy-mm-dd" : "Value", text: $clauses[i].value)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: clauses[i].op.needsUnit ? 60 : .infinity)
                    }
                    if clauses[i].op.needsUnit {
                        Picker("Unit", selection: $clauses[i].unit) {
                            ForEach(RowFilter.DateUnit.allCases, id: \.self) { Text($0.rawValue.lowercased() + "s").tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    if !clauses[i].op.needsValue || clauses[i].op.needsUnit { Spacer() }
                    IconButton("minus.circle", help: "Remove this condition") { clauses.remove(at: i) }.disabled(clauses.count == 1)
                }
            }
            Button("Add Clause") { clauses.append(FilterClause(column: focus)) }.controlSize(.small)
        }
    }

    private var canCommit: Bool {
        switch mode {
        case .values: return !keep.isEmpty
        case .basic, .advanced: return !clauses.isEmpty && clauses.allSatisfy { !$0.op.needsValue || !$0.value.isEmpty || types[$0.column] == .text }
        case .formula: return !formula.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func load() {
        if let edit, case .filterRows(let condition) = edit.transform {
            if let found = FilterClause.clauses(of: condition, types: types) {
                clauses = found
                mode = Set(found.map(\.column)).count > 1 ? .advanced : .basic
            } else {
                formula = condition.mExpression(previous: edit.previous)
                mode = .formula
            }
        } else {
            clauses = [FilterClause(column: focus)]
            keep = Set(distinct)
            mode = .values
        }
    }

    private func done() {
        let condition: RowFilter?
        switch mode {
        case .values:
            let type = types[focus] ?? .any
            let all = distinct
            let removed = all.filter { !keep.contains($0) }
            if removed.isEmpty { dismiss(); return }
            if keep.count <= removed.count {
                condition = keep.count == 1 ? .compare(column: focus, .equals, keep.first ?? .null, type: type)
                    : .inList(column: focus, all.filter(keep.contains), type: type)
            } else {
                condition = removed.count == 1 ? .compare(column: focus, .notEquals, removed[0], type: type)
                    : .and(removed.map { .compare(column: focus, .notEquals, $0, type: type) })
            }
        case .basic, .advanced: condition = FilterClause.combine(clauses, types: types)
        case .formula: condition = .custom(formula.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let condition { session.commit(.filterRows(condition), editing: edit) }
        dismiss()
    }
}

// MARK: - Group by

struct GroupByDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    let edit: StepEdit?

    enum Operation: String, CaseIterable, Identifiable {
        case sum = "Sum", average = "Average", median = "Median", min = "Min", max = "Max", countRows = "Count Rows"
        case countDistinctRows = "Count Distinct Rows", allRows = "All Rows", standardDeviation = "Standard Deviation", countDistinct = "Count Distinct"
        var id: String { rawValue }
        var needsColumn: Bool { ![.countRows, .countDistinctRows, .allRows].contains(self) }
        func aggregation(_ column: String) -> GroupAggregation {
            switch self {
            case .sum: return .sum(column: column)
            case .average: return .average(column: column)
            case .median: return .median(column: column)
            case .min: return .min(column: column)
            case .max: return .max(column: column)
            case .standardDeviation: return .standardDeviation(column: column)
            case .countDistinct: return .countDistinct(column: column)
            case .countRows: return .countRows
            case .countDistinctRows: return .countDistinctRows
            case .allRows: return .allRows
            }
        }
        static func of(_ a: GroupAggregation) -> (Operation, String) {
            switch a {
            case .sum(let c): return (.sum, c)
            case .average(let c): return (.average, c)
            case .median(let c): return (.median, c)
            case .min(let c): return (.min, c)
            case .max(let c): return (.max, c)
            case .standardDeviation(let c): return (.standardDeviation, c)
            case .countDistinct(let c): return (.countDistinct, c)
            case .countRows: return (.countRows, "")
            case .countDistinctRows: return (.countDistinctRows, "")
            case .allRows: return (.allRows, "")
            }
        }
    }
    struct Row: Equatable { var name = "Count"; var operation = Operation.countRows; var column = "" }

    @State private var advanced = false
    @State private var keys: [String] = []
    @State private var rows: [Row] = [Row()]
    @Environment(\.dismiss) private var dismiss

    private var columns: [String] { table.columnNames }

    var body: some View {
        DialogChrome(title: "Group By", subtitle: "Specify the columns to group by and one or more outputs.", canCommit: canCommit, width: 600, commit: done) {
            Picker("Mode", selection: $advanced) { Text("Basic").tag(false); Text("Advanced").tag(true) }.pickerStyle(.segmented).labelsHidden()
            ForEach(keys.indices, id: \.self) { i in
                HStack {
                    Picker("Group by", selection: $keys[i]) { ForEach(columns, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    if advanced { IconButton("minus.circle", help: "Remove this grouping") { keys.remove(at: i) }.disabled(keys.count == 1) }
                }
            }
            if advanced { Button("Add Grouping") { keys.append(columns.first { !keys.contains($0) } ?? columns.first ?? "") }.controlSize(.small) }
            Hairline()
            HStack {
                Text("New column name").frame(width: 150, alignment: .leading)
                Text("Operation").frame(width: 170, alignment: .leading)
                Text("Column")
            }
            .font(Design.Typeface.caption).foregroundStyle(.secondary)
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    TextField("Name", text: $rows[i].name).textFieldStyle(.roundedBorder).frame(width: 150)
                    Picker("Operation", selection: $rows[i].operation) { ForEach(Operation.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170)
                    if rows[i].operation.needsColumn {
                        Picker("Column", selection: $rows[i].column) { ForEach(columns, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    } else { Spacer() }
                    if advanced { IconButton("minus.circle", help: "Remove this aggregation") { rows.remove(at: i) }.disabled(rows.count == 1) }
                }
            }
            if advanced { Button("Add Aggregation") { rows.append(Row(name: "Count\(rows.count)", column: columns.first ?? "")) }.controlSize(.small) }
        }
        .onAppear(perform: load)
        .onChange(of: advanced) { _, on in
            if !on { keys = Array(keys.prefix(1)); rows = Array(rows.prefix(1)) }
        }
    }

    private var canCommit: Bool {
        !keys.isEmpty && !rows.isEmpty && rows.allSatisfy { !$0.name.isEmpty && (!$0.operation.needsColumn || columns.contains($0.column)) }
            && Set(rows.map(\.name)).count == rows.count
    }

    private func load() {
        if case .groupBy(let k, let aggs)? = edit?.transform {
            keys = k
            rows = aggs.map { a in let (op, c) = Operation.of(a.aggregation); return Row(name: a.name, operation: op, column: c) }
            advanced = keys.count > 1 || rows.count > 1
        } else {
            keys = [session.selectedColumns.first ?? columns.first ?? ""]
            rows = [Row(column: columns.first { !keys.contains($0) } ?? "")]
        }
    }

    private func done() {
        session.commit(.groupBy(keys: keys, aggregations: rows.map { ($0.name, $0.operation.aggregation($0.column)) }), editing: edit)
        dismiss()
    }
}
