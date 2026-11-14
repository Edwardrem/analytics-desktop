import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

// MARK: - Split

struct SplitColumnDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    let column: String
    let kind: EditorDialog.SplitKind
    let edit: StepEdit?
    @State private var delimiter = ","
    @State private var at = 2          // 0 left-most, 1 right-most, 2 each
    @State private var intoRows = false
    @State private var count = 2
    @State private var length = 1
    @State private var repeated = true
    @State private var positions = "0, 1"
    @Environment(\.dismiss) private var dismiss

    private var values: [String] { table.column(column)?.values.map(\.asString) ?? [] }
    private var parsedPositions: [Int]? {
        let parts = positions.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.compactMap { $0 }
        return p == p.sorted() && (p.first ?? -1) >= 0 ? p : nil
    }

    var body: some View {
        DialogChrome(title: title, subtitle: "Split “\(column)”.", canCommit: canCommit, commit: done) {
            switch kind {
            case .delimiter:
                DelimiterPicker(label: "Delimiter", value: $delimiter)
                PropertyRow("Split at") {
                    Picker("Split at", selection: $at) {
                        Text("Left-most delimiter").tag(0); Text("Right-most delimiter").tag(1); Text("Each occurrence of the delimiter").tag(2)
                    }.labelsHidden().pickerStyle(.radioGroup)
                }
            case .length:
                CountField(label: "Characters", value: $length)
                PropertyRow("Split") {
                    Picker("Split", selection: $repeated) { Text("Once, as far left as possible").tag(false); Text("Repeatedly").tag(true) }
                        .labelsHidden().pickerStyle(.radioGroup)
                }
            case .positions:
                PropertyRow("Positions") { TextField("0, 7, 13", text: $positions).textFieldStyle(.roundedBorder) }
            }
            DisclosureGroup("Advanced options") {
                Picker("Split into", selection: $intoRows) { Text("Columns").tag(false); Text("Rows").tag(true) }.pickerStyle(.segmented)
                if !intoRows, !(kind == .delimiter && at != 2) { CountField(label: "Columns to split into", value: $count) }
            }
        }
        .onAppear(perform: load)
        .onChange(of: delimiter) { _, _ in suggestCount() }
        .onChange(of: length) { _, _ in suggestCount() }
        .onChange(of: repeated) { _, _ in suggestCount() }
        .onChange(of: positions) { _, _ in suggestCount() }
    }

    private var title: String {
        switch kind {
        case .delimiter: return "Split Column by Delimiter"
        case .length: return "Split Column by Number of Characters"
        case .positions: return "Split Column by Positions"
        }
    }
    private var canCommit: Bool {
        switch kind {
        case .delimiter: return !delimiter.isEmpty && count >= 1
        case .length: return length >= 1 && count >= 1
        case .positions: return parsedPositions != nil
        }
    }

    /// Power Query proposes as many columns as the previewed values split into.
    private func suggestCount() {
        guard edit == nil else { return }
        switch kind {
        case .delimiter: count = max(1, values.map { SplitCount.parts(of: $0, delimiter: delimiter) }.max() ?? 2)
        case .length: count = repeated ? max(1, values.map { Int((Double($0.count) / Double(max(length, 1))).rounded(.up)) }.max() ?? 2) : 2
        case .positions: count = parsedPositions?.count ?? 2
        }
    }

    private func load() {
        switch edit?.transform {
        case .splitByDelimiter(_, let d, let a, let into)?:
            delimiter = d
            at = a == .leftmost ? 0 : a == .rightmost ? 1 : 2
            apply(into)
        case .splitByLength(_, let n, let r, let into)?: length = n; repeated = r; apply(into)
        case .splitByPositions(_, let p, let into)?: positions = p.map(String.init).joined(separator: ", "); apply(into)
        default: suggestCount()
        }
    }
    private func apply(_ into: SplitTarget) {
        switch into {
        case .columns(let n): count = n; intoRows = false
        case .rows: intoRows = true
        }
    }

    private func done() {
        let target: SplitTarget = intoRows ? .rows : .columns(kind == .delimiter && at != 2 ? 2 : count)
        let t: Transform
        switch kind {
        case .delimiter: t = .splitByDelimiter(column: column, delimiter: delimiter, at: at == 0 ? .leftmost : at == 1 ? .rightmost : .each, into: target)
        case .length: t = .splitByLength(column: column, length: length, repeated: repeated, into: target)
        case .positions: t = .splitByPositions(column: column, positions: parsedPositions ?? [0], into: intoRows ? .rows : .columns(parsedPositions?.count ?? count))
        }
        session.commit(t, editing: edit)
        dismiss()
    }
}

// MARK: - Merge columns, prefix / suffix

struct MergeColumnsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let asNewColumn: Bool
    let all: [String]
    let edit: StepEdit?
    @State private var separator = ""
    @State private var name = "Merged"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Merge Columns", subtitle: "Combine \(columns.joined(separator: ", ")) into one text column.", canCommit: !name.isEmpty, commit: done) {
            DelimiterPicker(label: "Separator", value: $separator, allowNone: true)
            PropertyRow("New column name") { TextField("Merged", text: $name).textFieldStyle(.roundedBorder) }
        }
        .onAppear {
            if case .mergeColumns(_, let s, let n)? = edit?.transform { separator = s; name = n }
            else { name = QueryEditorPlans.uniqueColumnName("Merged", taken: asNewColumn ? all : all.filter { !columns.contains($0) }) }
        }
    }
    private func done() {
        if asNewColumn {
            let parts = columns.map { "Text.From(\(MSyntax.field($0)), \"en-US\")" }.joined(separator: ", ")
            session.commit(.addCustomColumn(name: name, expression: "Text.Combine({\(parts)}, \(MSyntax.text(separator)))", type: .text), editing: edit)
        } else {
            session.commit(.mergeColumns(columns, separator: separator, newName: name), editing: edit)
        }
        dismiss()
    }
}

struct AffixDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let suffix: Bool
    let edit: StepEdit?
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: suffix ? "Suffix" : "Prefix", subtitle: "Enter the text to add \(suffix ? "after" : "before") each value of \(columns.joined(separator: ", ")).", commit: done) {
            PropertyRow("Value") { TextField("Text", text: $text).textFieldStyle(.roundedBorder) }
        }
        .onAppear {
            switch edit?.transform {
            case .addPrefix(_, let t)?, .addSuffix(_, let t)?: text = t
            default: break
            }
        }
    }
    private func done() {
        session.commit(suffix ? .addSuffix(columns: columns, text) : .addPrefix(columns: columns, text), editing: edit)
        dismiss()
    }
}

// MARK: - Extract

struct ExtractDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let kind: EditorDialog.ExtractKind
    let asNewColumn: Bool
    let all: [String]
    let edit: StepEdit?
    @State private var count = 1
    @State private var start = 0
    @State private var a = ""
    @State private var b = ""
    @Environment(\.dismiss) private var dismiss

    static func kind(of e: TextExtract) -> EditorDialog.ExtractKind {
        switch e {
        case .firstCharacters: return .first
        case .lastCharacters: return .last
        case .range: return .range
        case .beforeDelimiter: return .before
        case .afterDelimiter: return .after
        case .betweenDelimiters: return .between
        case .length: return .first
        }
    }

    private var title: String {
        switch kind {
        case .first: return "Extract First Characters"
        case .last: return "Extract Last Characters"
        case .range: return "Extract Text Range"
        case .before: return "Text Before Delimiter"
        case .after: return "Text After Delimiter"
        case .between: return "Text Between Delimiters"
        }
    }

    var body: some View {
        DialogChrome(title: title, canCommit: valid, commit: done) {
            switch kind {
            case .first, .last: CountField(label: "Count", value: $count)
            case .range:
                CountField(label: "Starting index", value: $start)
                CountField(label: "Characters", value: $count)
            case .before, .after: PropertyRow("Delimiter") { TextField("Delimiter", text: $a).textFieldStyle(.roundedBorder) }
            case .between:
                PropertyRow("Start delimiter") { TextField("Delimiter", text: $a).textFieldStyle(.roundedBorder) }
                PropertyRow("End delimiter") { TextField("Delimiter", text: $b).textFieldStyle(.roundedBorder) }
            }
            if kind == .range { Text("The first character is at index 0.").font(Design.Typeface.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            guard case .extractText(_, let e, _)? = edit?.transform else { return }
            switch e {
            case .firstCharacters(let n), .lastCharacters(let n): count = n
            case .range(let s, let n): start = s; count = n
            case .beforeDelimiter(let d), .afterDelimiter(let d): a = d
            case .betweenDelimiters(let x, let y): a = x; b = y
            case .length: break
            }
        }
    }

    private var valid: Bool {
        switch kind {
        case .first, .last, .range: return count >= 0 && start >= 0
        case .before, .after: return !a.isEmpty
        case .between: return !a.isEmpty && !b.isEmpty
        }
    }
    private var extract: TextExtract {
        switch kind {
        case .first: return .firstCharacters(count)
        case .last: return .lastCharacters(count)
        case .range: return .range(start: start, count: count)
        case .before: return .beforeDelimiter(a)
        case .after: return .afterDelimiter(a)
        case .between: return .betweenDelimiters(a, b)
        }
    }
    private var newName: String {
        switch kind {
        case .first: return "First Characters"
        case .last: return "Last Characters"
        case .range: return "Text Range"
        case .before: return "Text Before Delimiter"
        case .after: return "Text After Delimiter"
        case .between: return "Text Between Delimiters"
        }
    }
    private func done() {
        if let edit, case .extractText(let c, _, let existing) = edit.transform {
            session.commit(.extractText(column: c, extract, newColumn: existing), editing: edit)
        } else if asNewColumn, let c = columns.first {
            session.apply(.extractText(column: c, extract, newColumn: QueryEditorPlans.uniqueColumnName(newName, taken: all)))
        } else {
            // One step per column (Power Query transforms each selected column in place).
            for c in columns { session.apply(.extractText(column: c, extract, newColumn: nil)) }
        }
        dismiss()
    }
}

// MARK: - Number with a value

struct NumberValueDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let kind: EditorDialog.NumberValueKind
    let asNewColumn: Bool
    let all: [String]
    let edit: StepEdit?
    @State private var value = ""
    @Environment(\.dismiss) private var dismiss

    static func kind(of op: NumberOperation) -> EditorDialog.NumberValueKind {
        switch op {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .integerDivide: return .integerDivide
        case .modulo: return .modulo
        case .percentage: return .percentage
        case .percentOf: return .percentOf
        case .power: return .power
        default: return .round
        }
    }
    private var number: Double? { Double(value.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        DialogChrome(title: kind.title, subtitle: kind == .round ? "Enter the number of decimal places to round to." : "Enter the value to use with \(columns.joined(separator: ", ")).",
                     canCommit: number != nil, commit: done) {
            PropertyRow(kind == .round ? "Decimal places" : kind == .power ? "Power" : "Value") { TextField("Value", text: $value).textFieldStyle(.roundedBorder) }
        }
        .onAppear {
            guard case .number(_, let op, _)? = edit?.transform else { value = kind == .round ? "2" : ""; return }
            switch op {
            case .add(let v), .subtract(let v), .multiply(let v), .divide(let v), .integerDivide(let v), .modulo(let v),
                 .percentage(let v), .percentOf(let v), .power(let v): value = MSyntax.number(v)
            case .round(let d): value = String(d)
            default: break
            }
        }
    }
    private func done() {
        guard let number else { return }
        let op = kind.operation(number)
        if let edit, case .number(let cs, _, let new) = edit.transform {
            session.commit(.number(columns: cs, op, newColumn: new), editing: edit)
        } else if asNewColumn {
            session.apply(.number(columns: Array(columns.prefix(1)), op, newColumn: QueryEditorPlans.uniqueColumnName(ColumnOperationCommands.newColumnName(kind), taken: all)))
        } else {
            session.apply(.number(columns: columns, op, newColumn: nil))
        }
        dismiss()
    }
}

// MARK: - Structured columns

struct ExtractValuesDialog: View {
    @ObservedObject var session: QueryEditorSession
    let column: String
    let edit: StepEdit?
    @State private var delimiter = ","
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DialogChrome(title: "Extract Values from List", subtitle: "Join the values of each list in “\(column)” into text.", commit: done) {
            DelimiterPicker(label: "Delimiter", value: $delimiter)
        }
        .onAppear { if case .extractListValues(_, let d)? = edit?.transform { delimiter = d } }
    }
    private func done() { session.commit(.extractListValues(column: column, delimiter: delimiter), editing: edit); dismiss() }
}

struct ExpandDialog: View {
    @ObservedObject var session: QueryEditorSession
    let column: String
    let columns: [String]
    let edit: StepEdit?
    @State private var info: StructuredColumnInfo?
    @State private var problem: String?
    @State private var checked: Set<String> = []
    @State private var prefix = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Expand “\(column)”", subtitle: info.map { "Choose the \($0.kind == "Record" ? "fields" : "columns") to expand." } ?? "Reading the column…",
                     canCommit: !checked.isEmpty, width: 380, problem: problem, commit: done) {
            if let info {
                Toggle("(Select All Columns)", isOn: Binding(get: { checked.count == info.fields.count }, set: { checked = $0 ? Set(info.fields) : [] }))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(info.fields, id: \.self) { f in
                            Toggle(f, isOn: Binding(get: { checked.contains(f) }, set: { if $0 { checked.insert(f) } else { checked.remove(f) } }))
                        }
                    }
                }
                .frame(height: 220)
                Toggle("Use original column name as prefix", isOn: $prefix)
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let q = session.selectedQuery else { return }
        let input = edit.map { e in session.steps.firstIndex { MSyntax.identifier($0.name) == e.previous } ?? (e.index - 1) } ?? session.currentStepIndex
        do {
            info = try await session.makeEngine().structuredColumn(column, of: q.name, upToStep: input)
            if info == nil { problem = "“\(column)” holds no tables or records." }
        } catch { problem = MError.wrap(error).description }
        switch edit?.transform {
        case .expandTableColumn(_, let cs, let names)?: checked = Set(cs); prefix = names == nil || names != cs
        case .expandRecordColumn(_, let fs, let names)?: checked = Set(fs); prefix = names == nil || names != fs
        default: checked = Set(info?.fields ?? [])
        }
    }

    private func done() {
        guard let info else { return }
        let fields = info.fields.filter(checked.contains)
        let names = prefix ? fields.map { "\(column).\($0)" } : fields
        let unique = names.map { n in columns.contains(n) && n != column ? QueryEditorPlans.uniqueColumnName(n, taken: columns) : n }
        let t: Transform = info.kind == "Record"
            ? .expandRecordColumn(column: column, fields: fields, newNames: unique)
            : .expandTableColumn(column: column, columns: fields, newNames: unique)
        session.commit(t, editing: edit)
        dismiss()
    }
}

struct AggregateDialog: View {
    @ObservedObject var session: QueryEditorSession
    let column: String
    let columns: [String]
    let edit: StepEdit?
    @State private var fields: [String] = []
    @State private var choice: [String: ColumnStatistic] = [:]
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Aggregate “\(column)”", subtitle: "Choose an aggregation for each column of the nested tables.", canCommit: !choice.isEmpty, width: 420, problem: problem, commit: done) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.xs) {
                    ForEach(fields, id: \.self) { f in
                        HStack {
                            Toggle(f, isOn: Binding(get: { choice[f] != nil }, set: { choice[f] = $0 ? .sum : nil }))
                            Spacer()
                            Picker(f, selection: Binding(get: { choice[f] ?? .sum }, set: { choice[f] = $0 })) {
                                ForEach(ColumnOperationCommands.statistics, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .labelsHidden().frame(width: 170).disabled(choice[f] == nil)
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .task {
            guard let q = session.selectedQuery else { return }
            let input = edit.map { e in session.steps.firstIndex { MSyntax.identifier($0.name) == e.previous } ?? (e.index - 1) } ?? session.currentStepIndex
            do {
                fields = try await session.makeEngine().structuredColumn(column, of: q.name, upToStep: input)?.fields ?? []
                if fields.isEmpty { problem = "“\(column)” holds no tables." }
            } catch { problem = MError.wrap(error).description }
            if case .aggregateTableColumn(_, let aggs)? = edit?.transform { for a in aggs { choice[a.column] = a.statistic } }
        }
    }

    private func done() {
        let titles = Dictionary(ColumnOperationCommands.statistics.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        var taken = columns
        let aggs = fields.compactMap { f -> (column: String, statistic: ColumnStatistic, newName: String)? in
            guard let s = choice[f] else { return nil }
            let name = QueryEditorPlans.uniqueColumnName("\(titles[s] ?? "Sum") of \(f)", taken: taken)
            taken.append(name)
            return (f, s, name)
        }
        session.commit(.aggregateTableColumn(column: column, aggregations: aggs), editing: edit)
        dismiss()
    }
}

// MARK: - Pivot and index

struct PivotDialog: View {
    @ObservedObject var session: QueryEditorSession
    let column: String
    let columns: [String]
    let edit: StepEdit?
    @State private var values = ""
    @State private var aggregation: ColumnStatistic? = .sum
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Pivot Column", subtitle: "Use the names in “\(column)” to create new columns.", canCommit: !values.isEmpty, commit: done) {
            ColumnPicker(label: "Values Column", columns: columns.filter { $0 != column }, selection: $values)
            PropertyRow("Aggregate") {
                Picker("Aggregate", selection: $aggregation) {
                    ForEach(ColumnOperationCommands.statistics, id: \.0) { Text($0.1).tag(Optional($0.0)) }
                    Text("Don't Aggregate").tag(ColumnStatistic?.none)
                }.labelsHidden()
            }
        }
        .onAppear {
            if case .pivotColumn(_, let v, let a)? = edit?.transform { values = v; aggregation = a }
            else { values = columns.first { $0 != column } ?? "" }
        }
    }
    private func done() { session.commit(.pivotColumn(column: column, valueColumn: values, aggregation: aggregation), editing: edit); dismiss() }
}

struct IndexColumnDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let edit: StepEdit?
    @State private var name = "Index"
    @State private var start = 0
    @State private var increment = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Add Index Column", canCommit: !name.isEmpty, commit: done) {
            PropertyRow("Column name") { TextField("Index", text: $name).textFieldStyle(.roundedBorder) }
            CountField(label: "Starting index", value: $start)
            CountField(label: "Increment", value: $increment)
        }
        .onAppear {
            if case .addIndexColumn(let n, let s, let i)? = edit?.transform { name = n; start = s; increment = i }
            else { name = QueryEditorPlans.uniqueColumnName("Index", taken: columns) }
        }
    }
    private func done() { session.commit(.addIndexColumn(name: name, start: start, increment: increment), editing: edit); dismiss() }
}
