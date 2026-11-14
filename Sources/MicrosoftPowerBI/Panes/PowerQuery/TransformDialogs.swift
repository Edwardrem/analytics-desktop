import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// Routes column-transform dialogs (new, or the gear of an existing step) to their views, after loading the table
/// the dialog works on.
struct TransformDialogRouter: View {
    @ObservedObject var session: QueryEditorSession
    let dialog: EditorDialog
    @State private var input: QueryPreview?
    @State private var loaded = false

    private var edit: StepEdit? { if case .editStep(let e) = dialog { return e }; return nil }

    var body: some View {
        Group {
            if let input { route(input) } else if loaded {
                DialogChrome(title: "Edit Step", canCommit: false, problem: "The input of this step could not be evaluated.", commit: {}) { EmptyView() }
            } else {
                ProgressView().padding(Design.Space.xl).frame(width: 240)
            }
        }
        .task {
            input = await session.inputPreview(for: edit)
            loaded = true
        }
    }

    @ViewBuilder
    private func route(_ p: QueryPreview) -> some View {
        let columns = p.table.columnNames
        switch dialog {
        case .filter(let c): FilterRowsDialog(session: session, table: p.table, column: c, edit: nil)
        case .changeTypeWithLocale(let cs): ChangeTypeLocaleDialog(session: session, columns: cs, edit: nil)
        case .replaceValues(let cs): ReplaceValuesDialog(session: session, table: p.table, columns: cs, edit: nil)
        case .replaceErrors(let cs): ReplaceErrorsDialog(session: session, table: p.table, columns: cs)
        case .split(let c, let k): SplitColumnDialog(session: session, table: p.table, column: c, kind: k, edit: nil)
        case .mergeColumns(let cs, let new): MergeColumnsDialog(session: session, columns: cs, asNewColumn: new, all: columns, edit: nil)
        case .affix(let cs, let suffix): AffixDialog(session: session, columns: cs, suffix: suffix, edit: nil)
        case .extract(let cs, let k, let new): ExtractDialog(session: session, columns: cs, kind: k, asNewColumn: new, all: columns, edit: nil)
        case .numberValue(let cs, let k, let new): NumberValueDialog(session: session, columns: cs, kind: k, asNewColumn: new, all: columns, edit: nil)
        case .extractValues(let c): ExtractValuesDialog(session: session, column: c, edit: nil)
        case .pivot(let c): PivotDialog(session: session, column: c, columns: columns, edit: nil)
        case .indexColumn: IndexColumnDialog(session: session, columns: columns, edit: nil)
        case .expand(let c): ExpandDialog(session: session, column: c, columns: columns, edit: nil)
        case .aggregate(let c): AggregateDialog(session: session, column: c, columns: columns, edit: nil)
        case .groupBy: GroupByDialog(session: session, table: p.table, edit: nil)
        case .merge(let asNew): MergeQueriesDialog(session: session, asNew: asNew, edit: nil)
        case .append(let asNew): AppendQueriesDialog(session: session, asNew: asNew, edit: nil)
        case .customColumn: CustomColumnDialog(session: session, columns: columns, edit: nil)
        case .conditionalColumn: ConditionalColumnDialog(session: session, table: p.table, edit: nil)
        case .invokeFunction: InvokeFunctionDialog(session: session, columns: columns, edit: nil)
        case .columnFromExamples(let cs): ColumnFromExamplesDialog(session: session, table: p.table, sourceColumns: cs)
        case .editStep(let e): editRoute(e, p)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func editRoute(_ e: StepEdit, _ p: QueryPreview) -> some View {
        let columns = p.table.columnNames
        switch e.transform {
        case .filterRows: FilterRowsDialog(session: session, table: p.table, column: nil, edit: e)
        case .changeType(let changes, _): ChangeTypeLocaleDialog(session: session, columns: changes.map(\.column), edit: e)
        case .replaceValues(let cs, _, _, _): ReplaceValuesDialog(session: session, table: p.table, columns: cs, edit: e)
        case .replaceErrors(let cs, _): ReplaceErrorsDialog(session: session, table: p.table, columns: cs, edit: e)
        case .splitByDelimiter(let c, _, _, _): SplitColumnDialog(session: session, table: p.table, column: c, kind: .delimiter, edit: e)
        case .splitByLength(let c, _, _, _): SplitColumnDialog(session: session, table: p.table, column: c, kind: .length, edit: e)
        case .splitByPositions(let c, _, _): SplitColumnDialog(session: session, table: p.table, column: c, kind: .positions, edit: e)
        case .mergeColumns(let cs, _, _): MergeColumnsDialog(session: session, columns: cs, asNewColumn: false, all: columns, edit: e)
        case .addPrefix(let cs, _): AffixDialog(session: session, columns: cs, suffix: false, edit: e)
        case .addSuffix(let cs, _): AffixDialog(session: session, columns: cs, suffix: true, edit: e)
        case .extractText(let c, let kind, let new):
            ExtractDialog(session: session, columns: [c], kind: ExtractDialog.kind(of: kind), asNewColumn: new != nil, all: columns, edit: e)
        case .number(let cs, let op, let new):
            NumberValueDialog(session: session, columns: cs, kind: NumberValueDialog.kind(of: op), asNewColumn: new != nil, all: columns, edit: e)
        case .extractListValues(let c, _): ExtractValuesDialog(session: session, column: c, edit: e)
        case .pivotColumn(let c, _, _): PivotDialog(session: session, column: c, columns: columns, edit: e)
        case .addIndexColumn: IndexColumnDialog(session: session, columns: columns, edit: e)
        case .expandRecordColumn(let c, _, _), .expandTableColumn(let c, _, _): ExpandDialog(session: session, column: c, columns: columns, edit: e)
        case .aggregateTableColumn(let c, _): AggregateDialog(session: session, column: c, columns: columns, edit: e)
        case .groupBy: GroupByDialog(session: session, table: p.table, edit: e)
        case .mergeQueries: MergeQueriesDialog(session: session, asNew: false, edit: e)
        case .appendQueries: AppendQueriesDialog(session: session, asNew: false, edit: e)
        case .addCustomColumn: CustomColumnDialog(session: session, columns: columns, edit: e)
        case .addConditionalColumn: ConditionalColumnDialog(session: session, table: p.table, edit: e)
        case .invokeCustomFunction: InvokeFunctionDialog(session: session, columns: columns, edit: e)
        case .renameColumns(let pairs): RenameColumnsDialog(session: session, pairs: pairs, edit: e)
        default: EmptyView()
        }
    }
}

// MARK: - Values typed into dialogs

enum EditorValues {
    /// A value typed for a column of `type`: numbers, dates and logicals are parsed; `null` (any case) is null;
    /// anything else is text. Empty input is empty text for text columns and null otherwise.
    static func parse(_ text: String, as type: DataType) -> Value {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased() == "null" { return .null }
        switch type {
        case .text, .binary: return .string(text)
        case .integer:
            if let i = Int64(t) { return .int(i) }
            return Double(t).map(Value.double) ?? (t.isEmpty ? .null : .string(text))
        case .decimal, .currency, .duration:
            return Double(t).map(Value.double) ?? (t.isEmpty ? .null : .string(text))
        case .boolean:
            switch t.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return t.isEmpty ? .null : .string(text)
            }
        case .date, .dateTime, .time:
            return DateParsing.parse(t).map(Value.date) ?? (t.isEmpty ? .null : .string(text))
        case .any:
            if t.isEmpty { return .string(text) }
            if let i = Int64(t) { return .int(i) }
            if let d = Double(t) { return .double(d) }
            return .string(text)
        }
    }

    /// The text a value is shown as in a dialog field.
    static func text(_ v: Value, type: DataType) -> String { v.isNull ? "null" : QueryCellText.text(v, type: type) }
}

/// Common delimiters of the split, merge and extract dialogs.
let editorDelimiters: [(name: String, value: String)] = [
    ("Comma", ","), ("Colon", ":"), ("Equals Sign", "="), ("Semicolon", ";"), ("Space", " "), ("Tab", "\t"), ("Line Feed", "\n"),
]

struct DelimiterPicker: View {
    let label: String
    @Binding var value: String
    var allowNone = false
    @State private var custom = false

    var body: some View {
        PropertyRow(label) {
            HStack {
                Picker(label, selection: Binding(get: { custom ? "\u{1}" : value }, set: { v in
                    if v == "\u{1}" { custom = true } else { custom = false; value = v }
                })) {
                    if allowNone { Text("None").tag("") }
                    ForEach(editorDelimiters, id: \.value) { Text($0.name).tag($0.value) }
                    Text("Custom").tag("\u{1}")
                }
                .labelsHidden().frame(width: 140)
                if custom { TextField("Delimiter", text: $value).textFieldStyle(.roundedBorder).frame(width: 90) }
            }
        }
        .onAppear { custom = !editorDelimiters.contains { $0.value == value } && !(allowNone && value.isEmpty) }
    }
}

/// Column picker used by the dialogs.
struct ColumnPicker: View {
    let label: String
    let columns: [String]
    @Binding var selection: String
    var body: some View {
        PropertyRow(label) {
            Picker(label, selection: $selection) { ForEach(columns, id: \.self) { Text($0).tag($0) } }.labelsHidden()
        }
    }
}

// MARK: - Type with locale

struct ChangeTypeLocaleDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let edit: StepEdit?
    @State private var type: DataType = .date
    @State private var locale = "en-US"
    @Environment(\.dismiss) private var dismiss

    static let locales = ["en-US", "en-GB", "en-AU", "en-CA", "en-IN", "en-ZA", "de-DE", "de-CH", "fr-FR", "fr-CA", "es-ES", "es-MX", "it-IT",
                          "nl-NL", "pt-BR", "pt-PT", "sv-SE", "da-DK", "nb-NO", "fi-FI", "pl-PL", "cs-CZ", "ru-RU", "tr-TR", "ja-JP", "zh-CN", "ko-KR"]

    var body: some View {
        DialogChrome(title: "Change Type with Locale", subtitle: "Change the type of \(columns.joined(separator: ", ")), reading the values with the conventions of a locale.", commit: done) {
            PropertyRow("Data Type") {
                Picker("Data Type", selection: $type) { ForEach(DataTypeCommands.types, id: \.type) { Text($0.title).tag($0.type) } }.labelsHidden()
            }
            PropertyRow("Locale") {
                Picker("Locale", selection: $locale) {
                    ForEach(Self.locales, id: \.self) { Text(Locale(identifier: $0).localizedString(forIdentifier: $0) ?? $0).tag($0) }
                }.labelsHidden()
            }
        }
        .onAppear {
            if case .changeType(let changes, let culture)? = edit?.transform {
                type = changes.first?.type ?? type
                locale = culture ?? locale
            }
        }
    }
    private func done() {
        session.commit(.changeType(columns.map { ($0, type) }, culture: locale), editing: edit)
        dismiss()
    }
}

// MARK: - Replace

struct ReplaceValuesDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    let columns: [String]
    let edit: StepEdit?
    @State private var find = ""
    @State private var replace = ""
    @State private var entireCell = false
    @Environment(\.dismiss) private var dismiss

    private var type: DataType { columns.first.flatMap { table.column($0)?.type } ?? .text }

    var body: some View {
        DialogChrome(title: "Replace Values", subtitle: "Replace one value with another in \(columns.joined(separator: ", ")).", commit: done) {
            PropertyRow("Value To Find") { TextField("Value", text: $find).textFieldStyle(.roundedBorder) }
            PropertyRow("Replace With") { TextField("Value", text: $replace).textFieldStyle(.roundedBorder) }
            if type == .text || type == .any { Toggle("Match entire cell contents", isOn: $entireCell) }
        }
        .onAppear {
            if case .replaceValues(_, let f, let r, let e)? = edit?.transform {
                find = EditorValues.text(f, type: type); replace = EditorValues.text(r, type: type); entireCell = e
            }
        }
    }
    private func done() {
        let textual = type == .text || type == .any
        let f = textual && !entireCell ? Value.string(find) : EditorValues.parse(find, as: type)
        let r = textual ? Value.string(replace) : EditorValues.parse(replace, as: type)
        session.commit(.replaceValues(columns: columns, find: f, replaceWith: r, matchEntireCell: entireCell || !textual), editing: edit)
        dismiss()
    }
}

struct ReplaceErrorsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    let columns: [String]
    var edit: StepEdit?
    @State private var value = "null"
    @Environment(\.dismiss) private var dismiss

    private var type: DataType { columns.first.flatMap { table.column($0)?.type } ?? .any }

    var body: some View {
        DialogChrome(title: "Replace Errors", subtitle: "Enter the value that replaces errors in \(columns.joined(separator: ", ")).", commit: done) {
            PropertyRow("Value") { TextField("Value", text: $value).textFieldStyle(.roundedBorder) }
        }
        .onAppear { if case .replaceErrors(_, let v)? = edit?.transform { value = EditorValues.text(v, type: type) } }
    }
    private func done() {
        session.commit(.replaceErrors(columns: columns, with: EditorValues.parse(value, as: type)), editing: edit)
        dismiss()
    }
}

// MARK: - Rename (gear of Renamed Columns)

struct RenameColumnsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let pairs: [(from: String, to: String)]
    let edit: StepEdit
    @State private var names: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Rename Columns", canCommit: !names.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, commit: done) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                PropertyRow(pair.from) {
                    TextField("New name", text: Binding(get: { names[safe: i] ?? pair.to }, set: { if names.indices.contains(i) { names[i] = $0 } }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .onAppear { names = pairs.map(\.to) }
    }
    private func done() {
        session.commit(.renameColumns(zip(pairs, names).map { ($0.0.from, $0.1) }), editing: edit)
        dismiss()
    }
}
