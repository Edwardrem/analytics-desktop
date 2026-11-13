import SwiftUI
import FacetCore
import FacetDesign

/// User-defined DAX functions: typed parameters, optional parameters with defaults, a body and a description.
struct FunctionsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var draft: [UserFunction]
    @State private var selection: UUID?

    init(model: SemanticModel) {
        _draft = State(initialValue: model.functions)
        _selection = State(initialValue: model.functions.first?.id)
    }

    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var builtIns: Set<String> { Set(LanguageSupport.dax.functions.map { $0.name.uppercased() }) }
    private var problems: [String] { FunctionLogic.problems(draft, builtIns: builtIns) }

    var body: some View {
        ModelingSheet(title: "Functions",
                      subtitle: "Reusable DAX you can call from measures, calculated columns, visual calculations and other functions.",
                      width: 900, height: 580) {
            HStack(spacing: 0) {
                NamedListColumn(items: draft.map { .init(id: $0.id, name: $0.name, symbol: "curlybraces", detail: "\($0.parameters.count)") },
                                selection: $selection, addHelp: "New function", width: 200,
                                onAdd: {
                                    let f = FunctionLogic.make(alongside: draft)
                                    draft.append(f); selection = f.id
                                },
                                onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id },
                                onRename: { id, name in if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].name = name } },
                                emptyTitle: "No functions")
                Hairline(vertical: true)
                if let i = index { detail(i) } else {
                    EmptyState(systemImage: "curlybraces", title: "Create a function", message: "Give it parameters and a body, then call it by name in any formula.")
                }
            }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty, confirm: save)
        }
    }

    private func detail(_ i: Int) -> some View {
        let id = draft[i].id
        return ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                HStack(alignment: .bottom, spacing: Design.Space.l) {
                    ModelField("Name") { TextField("Margin", text: $draft[i].name).textFieldStyle(.roundedBorder).frame(width: 220) }
                    ModelField("Description") { TextField("What it returns", text: $draft[i].description).textFieldStyle(.roundedBorder) }
                }
                ModelField("Parameters") {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        ForEach(Array(draft[i].parameters.enumerated()), id: \.offset) { k, _ in parameterRow(i, k) }
                        Button { draft[i].parameters.append(FunctionLogic.makeParameter(in: draft[i])) } label: {
                            Label("Add parameter", systemImage: "plus").font(Design.Typeface.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(draft[i].parameters.count >= FunctionLogic.maximumParameters)
                    }
                }
                ModelField("Body") {
                    ModelingDAXEditor(text: draft[i].expression, kind: nil, height: 150) { new in
                        if let k = draft.firstIndex(where: { $0.id == id }) { draft[k].expression = new }
                    }
                    .id(id)
                }
                Text("\(draft[i].name)\(FunctionLogic.signature(draft[i]))")
                    .font(Design.Typeface.mono).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func parameterRow(_ i: Int, _ k: Int) -> some View {
        HStack(spacing: Design.Space.s) {
            TextField("name", text: $draft[i].parameters[k].name).textFieldStyle(.roundedBorder).frame(width: 130)
            Picker("Type", selection: $draft[i].parameters[k].type) {
                ForEach(FunctionLogic.types, id: \.self) { Text(FunctionLogic.typeTitle($0)).tag($0) }
                if !FunctionLogic.types.contains(draft[i].parameters[k].type) { Text(draft[i].parameters[k].type).tag(draft[i].parameters[k].type) }
            }.labelsHidden().frame(width: 140)
            Picker("Evaluation", selection: $draft[i].parameters[k].mode) {
                Text("Value").tag("val")
                Text("Expression").tag("expr")
            }.labelsHidden().frame(width: 110)
            .help("Value: evaluated once before the call. Expression: evaluated inside the function, in its context.")
            TextField("default (optional)", text: Binding(get: { draft[i].parameters[k].defaultExpression ?? "" },
                                                         set: { draft[i].parameters[k].defaultExpression = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder).font(Design.Typeface.mono)
            FieldWellGlyphButton("chevron.up", help: "Move up", disabled: k == 0) { draft[i].parameters.swapAt(k, k - 1) }
            FieldWellGlyphButton("chevron.down", help: "Move down", disabled: k == draft[i].parameters.count - 1) { draft[i].parameters.swapAt(k, k + 1) }
            FieldWellGlyphButton("xmark", help: "Remove parameter") { draft[i].parameters.remove(at: k) }
        }
    }

    private func save() {
        guard problems.isEmpty else { return }
        let functions = FunctionLogic.normalized(draft)
        store.mutate("Edit Functions", invalidates: .model) { $0.model.functions = functions }
        store.dismissSheet()
    }
}
