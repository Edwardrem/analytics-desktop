import SwiftUI
import FacetCore
import FacetDesign

/// New parameter: a numeric range (what-if) parameter or a field parameter, plus the parameters already in the model.
struct ParametersSheet: View {
    enum Page: String, CaseIterable, Identifiable { case numeric = "Numeric range", fields = "Fields", existing = "In this model"
        var id: String { rawValue } }
    @EnvironmentObject private var store: DocumentStore
    @State var page: Page = .numeric

    // Numeric range
    @State private var name = "Parameter"
    @State private var minimum = "0"
    @State private var maximum = "20"
    @State private var increment = "1"
    @State private var defaultValue = ""
    // Fields
    @State private var fieldName = "Parameter"
    @State private var fields: [FieldRef] = []
    /// The parameter being edited, when one was opened from the list.
    @State private var editingID: UUID?
    @State private var addSlicer = true

    private var parsed: ParameterLogic.Parsed {
        ParameterLogic.parse(name: name, minimum: minimum, maximum: maximum, increment: increment, defaultValue: defaultValue)
    }
    private var problem: String? {
        switch page {
        case .numeric:
            switch parsed {
            case .problem(let p): return p
            case .parameter(let p): return ParameterLogic.problem(p, replacing: editingID, model: store.model)
            }
        case .fields: return ParameterLogic.fieldParameterProblem(name: fieldName, fields: fields, replacing: editingID, model: store.model)
        case .existing: return nil
        }
    }

    var body: some View {
        ModelingSheet(title: editingID == nil ? "Parameters" : "Edit parameter",
                      subtitle: "A numeric range feeds a value into measures from a slicer. A field parameter lets readers choose which fields a visual shows.",
                      width: 620, height: 470) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Kind", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 380)
                .padding(Design.Space.m)
                .disabled(editingID != nil)
                Hairline()
                ScrollView {
                    Group {
                        switch page {
                        case .numeric: numericForm
                        case .fields: fieldsForm
                        case .existing: existingList
                        }
                    }
                    .padding(Design.Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } footer: {
            if page == .existing {
                ModelingSheetButtons(cancelTitle: nil, confirmTitle: "Close")
            } else {
                DialogProblemLine(problem: problem)
                ModelingSheetButtons(confirmTitle: editingID == nil ? "Create" : "Save", confirmDisabled: problem != nil, confirm: create)
            }
        }
        .onAppear {
            if editingID == nil {
                let taken = store.model.tables.map(\.name)
                name = ModelOps.uniqueName("Parameter", among: taken)
                fieldName = name
            }
        }
    }

    private var numericForm: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ModelField("Name") { TextField("Discount", text: $name).textFieldStyle(.roundedBorder).frame(width: 240) }
            HStack(spacing: Design.Space.l) {
                ModelField("Minimum") { TextField("0", text: $minimum).textFieldStyle(.roundedBorder).frame(width: 100) }
                ModelField("Maximum") { TextField("20", text: $maximum).textFieldStyle(.roundedBorder).frame(width: 100) }
            }
            HStack(spacing: Design.Space.l) {
                ModelField("Increment") { TextField("1", text: $increment).textFieldStyle(.roundedBorder).frame(width: 100) }
                ModelField("Default") { TextField("Minimum", text: $defaultValue).textFieldStyle(.roundedBorder).frame(width: 100) }
            }
            if editingID == nil { Toggle("Add a slicer to this page", isOn: $addSlicer).toggleStyle(.checkbox) }
            if case .parameter(let p) = parsed {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("\(ParameterLogic.valueCount(minimum: p.minimum, maximum: p.maximum, increment: p.increment).formatted()) values. Use the measure [\(ParameterLogic.valueMeasureName(p.name))] in your calculations.")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Text("\(p.name) = \(ParameterLogic.seriesExpression(p))\n\(ParameterLogic.valueMeasureName(p.name)) = \(ParameterLogic.valueMeasureExpression(p))")
                        .font(Design.Typeface.mono).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var fieldsForm: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ModelField("Name") { TextField("Parameter", text: $fieldName).textFieldStyle(.roundedBorder).frame(width: 240) }
            FieldWell(title: "Fields readers can choose between", fields: $fields, allowsMultiple: true)
            if editingID == nil { Toggle("Add a slicer to this page", isOn: $addSlicer).toggleStyle(.checkbox) }
            Text("The parameter becomes a table. Put its column in a slicer so readers can pick fields.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var existingList: some View {
        let model = store.model
        if model.whatIfParameters.isEmpty, model.fieldParameters.isEmpty {
            Text("This model has no parameters yet.").font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.whatIfParameters) { p in
                existingRow(name: p.name, symbol: "slider.horizontal.3",
                            detail: "\(ModelDAX.number(p.minimum)) to \(ModelDAX.number(p.maximum)), step \(ModelDAX.number(p.increment))",
                            id: p.id) {
                    name = p.name; minimum = ModelDAX.number(p.minimum); maximum = ModelDAX.number(p.maximum)
                    increment = ModelDAX.number(p.increment); defaultValue = ModelDAX.number(p.defaultValue)
                    editingID = p.id; page = .numeric
                }
            }
            ForEach(model.fieldParameters) { p in
                existingRow(name: p.name, symbol: "list.bullet.rectangle", detail: p.fields.map(\.caption).joined(separator: ", "), id: p.id) {
                    fieldName = p.name; fields = p.fields; editingID = p.id; page = .fields
                }
            }
        }
    }

    private func existingRow(name: String, symbol: String, detail: String, id: UUID, edit: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(name).font(Design.Typeface.body)
                Text(detail).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                IconButton("pencil", help: "Edit \(name)", action: edit)
                IconButton("trash", help: "Delete \(name) and its table") {
                    store.mutate("Delete Parameter", invalidates: .model) { ParameterLogic.remove(parameter: id, from: &$0.model) }
                }
            }
            .padding(.vertical, 3)
            Hairline()
        }
    }

    private func create() {
        guard problem == nil else { return }
        let replacing = editingID
        var slicerField: FieldRef?
        switch page {
        case .numeric:
            guard case .parameter(let p) = parsed else { return }
            store.mutate(replacing == nil ? "New Parameter" : "Edit Parameter", invalidates: .model) {
                ParameterLogic.install(p, replacing: replacing, into: &$0.model)
            }
            slicerField = .column(p.name, p.name)
            store.status = StatusMessage(kind: .success, text: "\(replacing == nil ? "Created" : "Updated") \(p.name). Use [\(ParameterLogic.valueMeasureName(p.name))] in measures.")
        case .fields:
            let n = fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = fields
            store.mutate(replacing == nil ? "New Field Parameter" : "Edit Field Parameter", invalidates: .model) {
                ParameterLogic.install(fieldParameter: n, fields: chosen, replacing: replacing, into: &$0.model)
            }
            slicerField = .column(n, n)
            store.status = StatusMessage(kind: .success, text: "\(replacing == nil ? "Created" : "Updated") field parameter \(n).")
        case .existing: return
        }
        if replacing == nil, addSlicer, let slicerField, store.view == .report {
            let id = store.addVisual(.slicer) { $0.name = "\(slicerField.table) slicer" }
            store.updateVisual(id, name: "New Parameter") { $0.setFields(.field, [slicerField]) }
        }
        store.dismissSheet()
    }
}
