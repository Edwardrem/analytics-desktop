import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// Transform data ▸ Edit Parameters, from the report: change the current values of the file's parameters,
/// then reload the queries that use them.
struct EditParametersSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var values: [UUID: String] = [:]

    private var parameters: [QueryDefinition] { store.doc.queries.filter { $0.kind == .parameter } }

    /// The document's queries with the typed values applied (nil when a value does not fit its parameter's type).
    static func applying(_ values: [UUID: String], to queries: [QueryDefinition]) -> [QueryDefinition]? {
        var out = queries
        for i in out.indices where out[i].kind == .parameter {
            guard let text = values[out[i].id] else { continue }
            var draft = ParameterDraft(out[i])
            draft.current = text
            if draft.problem != nil { return nil }
            let p = draft.parameter
            out[i].parameter = p
            out[i].mScript = MScript.parameterScript(p)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Edit Parameters").font(Design.Typeface.headline)
            if parameters.isEmpty {
                EmptyState(systemImage: "slider.horizontal.3", title: "This file has no parameters",
                           message: "Create parameters in the Power Query Editor (Home ▸ Manage Parameters).")
                    .frame(height: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.s) {
                        ForEach(parameters) { q in row(q) }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: apply).keyboardShortcut(.defaultAction)
                    .disabled(Self.applying(values, to: store.doc.queries) == nil)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 460)
        .onAppear {
            for q in parameters { values[q.id] = ParameterDraft(q).current }
        }
    }

    @ViewBuilder
    private func row(_ q: QueryDefinition) -> some View {
        let draft = ParameterDraft(q)
        let binding = Binding(get: { values[q.id] ?? draft.current }, set: { values[q.id] = $0 })
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            Text(q.name + (draft.required ? "" : " (optional)")).font(Design.Typeface.bodyStrong)
            if !q.description.isEmpty { Text(q.description).font(Design.Typeface.caption).foregroundStyle(.secondary) }
            if draft.listMode {
                Picker(q.name, selection: binding) {
                    ForEach(draft.suggestions.map { EditorValues.text($0, type: draft.type) }, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField(draft.type.displayName, text: binding).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func apply() {
        guard let after = Self.applying(values, to: store.doc.queries), after != store.doc.queries else { dismiss(); return }
        var loaded: [String: String] = [:]
        for t in store.doc.model.tables { if let q = t.sourceQuery { loaded[t.name] = q } }
        let plan = QueryEditorPlans.applyPlan(before: store.doc.queries, after: after, loadedTables: loaded)
        store.mutate("Edit Parameters", invalidates: .model) { $0.queries = after }
        if !plan.refresh.isEmpty { store.refreshData(only: plan.refresh) }
        dismiss()
    }
}
