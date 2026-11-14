import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// What a parameter form holds while it is edited.
struct ParameterDraft: Equatable {
    var name = "Parameter1"
    var description = ""
    var required = true
    var type: DataType = .text
    var listMode = false
    /// One suggested value per line.
    var list = ""
    var defaultValue = ""
    var current = ""

    /// Parameter types Power Query offers.
    static let types: [(DataType, String)] = [
        (.text, "Text"), (.decimal, "Decimal Number"), (.integer, "Whole Number"), (.currency, "Fixed Decimal Number"),
        (.date, "Date"), (.dateTime, "Date/Time"), (.time, "Time"), (.duration, "Duration"), (.boolean, "True/False"), (.any, "Any"),
    ]

    init() {}
    init(_ q: QueryDefinition) {
        name = q.name
        description = q.description
        let p = q.parameter ?? QueryParameter()
        required = p.isRequired
        type = p.type
        listMode = !p.suggestedValues.isEmpty
        list = p.suggestedValues.map { EditorValues.text($0, type: p.type) }.joined(separator: "\n")
        defaultValue = p.defaultValue.isNull ? "" : EditorValues.text(p.defaultValue, type: p.type)
        current = p.currentValue.isNull ? "" : EditorValues.text(p.currentValue, type: p.type)
    }

    var suggestions: [Value] {
        list.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { EditorValues.parse($0, as: type) }
    }

    /// Why the form cannot be saved yet.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A parameter needs a name." }
        if required, current.trimmingCharacters(in: .whitespaces).isEmpty { return "A required parameter needs a current value." }
        let value = EditorValues.parse(current, as: type)
        if !current.isEmpty, type != .text, type != .any, case .string = value { return "“\(current)” is not a valid \(type.displayName.lowercased())." }
        if listMode, suggestions.isEmpty { return "Add at least one suggested value, one per line." }
        return nil
    }

    var parameter: QueryParameter {
        var p = QueryParameter()
        p.type = type
        p.isRequired = required
        p.currentValue = current.isEmpty ? .null : EditorValues.parse(current, as: type)
        p.suggestedValues = listMode ? suggestions : []
        p.defaultValue = listMode && !defaultValue.isEmpty ? EditorValues.parse(defaultValue, as: type) : .null
        return p
    }
}

/// Manage Parameters: the file's parameters on the left, the selected one's definition on the right.
struct ManageParametersDialog: View {
    @ObservedObject var session: QueryEditorSession
    @State var selected: UUID?
    @State private var draft = ParameterDraft()
    @State private var isNew = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var parameters: [QueryDefinition] { session.queries.filter { $0.kind == .parameter } }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Manage Parameters").font(Design.Typeface.headline)
            HStack(alignment: .top, spacing: Design.Space.m) {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Button { newParameter() } label: { Label("New", systemImage: "plus") }.controlSize(.small)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(parameters) { p in
                                Text(p.name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).padding(.horizontal, Design.Space.xs)
                                    .background(!isNew && selected == p.id ? Design.Palette.accent.opacity(0.16) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(p) }
                            }
                            if isNew {
                                Text(draft.name).italic().padding(.vertical, 3).padding(.horizontal, Design.Space.xs)
                                    .frame(maxWidth: .infinity, alignment: .leading).background(Design.Palette.accent.opacity(0.16))
                            }
                        }
                    }
                }
                .frame(width: 180, height: 360)
                Hairline(vertical: true)
                if isNew || selected != nil { form } else {
                    EmptyState(systemImage: "slider.horizontal.3", title: "No parameter selected", message: "Add a parameter to use typed values in sources and filters.")
                }
            }
            if let problem { Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative) }
            HStack {
                if let id = selected, !isNew {
                    Button("Delete") { if let p = session.deleteQueries([id]) { problem = p } else { selected = nil } }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { save(close: true) }.keyboardShortcut(.defaultAction).disabled((isNew || selected != nil) && draft.problem != nil)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 640)
        .onAppear {
            if let id = selected, let q = session.query(id) { select(q) } else if parameters.isEmpty || selected == nil { newParameter() }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            PropertyRow("Name") { TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder) }
            PropertyRow("Description") { TextField("Description", text: $draft.description).textFieldStyle(.roundedBorder) }
            Toggle("Required", isOn: $draft.required)
            PropertyRow("Type") {
                Picker("Type", selection: $draft.type) { ForEach(ParameterDraft.types, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden()
            }
            PropertyRow("Suggested Values") {
                Picker("Suggested Values", selection: $draft.listMode) { Text("Any value").tag(false); Text("List of values").tag(true) }.labelsHidden()
            }
            if draft.listMode {
                TextEditor(text: $draft.list).font(Design.Typeface.mono).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
                PropertyRow("Default Value") {
                    Picker("Default", selection: $draft.defaultValue) {
                        Text("None").tag("")
                        ForEach(draft.suggestions.map { EditorValues.text($0, type: draft.type) }, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                PropertyRow("Current Value") {
                    Picker("Current", selection: $draft.current) {
                        ForEach(draft.suggestions.map { EditorValues.text($0, type: draft.type) }, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            } else {
                PropertyRow("Current Value") { TextField(draft.type.isTemporal ? "yyyy-mm-dd" : "Value", text: $draft.current).textFieldStyle(.roundedBorder) }
            }
            if let p = draft.problem { Text(p).font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func select(_ q: QueryDefinition) {
        if isNew || selected != nil, draft.problem == nil, !save(close: false) { return }
        isNew = false; selected = q.id; draft = ParameterDraft(q); problem = nil
    }

    private func newParameter() {
        if isNew || selected != nil, draft.problem == nil, !save(close: false) { return }
        isNew = true; selected = nil
        draft = ParameterDraft()
        draft.name = QueryEditorPlans.newQueryName("Parameter", taken: session.queryNames)
    }

    /// Save the form; true when saved (or nothing to save).
    @discardableResult
    private func save(close: Bool) -> Bool {
        guard isNew || selected != nil else { if close { dismiss() }; return true }
        if let p = draft.problem { problem = p; return false }
        let original = selected.flatMap { session.query($0) }
        let changed = isNew || original.map { ParameterDraft($0) != draft } ?? true
        if changed, let p = session.saveParameter(id: isNew ? nil : selected, name: draft.name, description: draft.description, parameter: draft.parameter) {
            problem = p
            return false
        }
        if isNew { selected = session.query(named: draft.name.trimmingCharacters(in: .whitespaces))?.id; isNew = false }
        if close { dismiss() }
        return true
    }
}
