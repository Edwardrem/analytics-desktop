import SwiftUI
import FacetCore
import FacetQuery
import FacetAnalytics
import FacetDesign

/// Model view, Table view and modeling dialogs: new measure/column/table, quick measures,
/// what-if parameters, relationships and security roles.
@MainActor
enum ModelingFeature {
    static func register() {
        Features.workspaceBuilders[.table] = { store in AnyView(TableWorkspaceView(store: store)) }
        Features.workspaceBuilders[.model] = { store in AnyView(ModelWorkspaceView(store: store)) }
        // The Data pane sets FieldPaneContext while it runs a model.* command for its document;
        // the command acts on what the pane pointed at. (See ModelingTarget's contract.)
        ModelingTarget.externalTable = { FieldPaneContext.table(for: $0) }
        ModelingTarget.externalField = { FieldPaneContext.field(for: $0) }
        AppCommands.register { commands }
        AppCommands.register { ModelingToolCommands.commands }
    }

    static var commands: [AppCommand] {
        [
            AppCommand(id: "model.newMeasure", title: "New Measure", menu: .modeling, symbol: "function",
                       isEnabled: { $0.model.tables.isEmpty == false }) { ModelOps.beginFormula($0, kind: .measure) },
            AppCommand(id: "model.newColumn", title: "New Column", menu: .modeling, symbol: "tablecells",
                       isEnabled: { $0.model.tables.isEmpty == false }) { ModelOps.beginFormula($0, kind: .column) },
            AppCommand(id: "model.newTable", title: "New Table", menu: .modeling, symbol: "table",
                       isEnabled: { $0.model.tables.isEmpty == false }) { ModelOps.beginFormula($0, kind: .table) },
            AppCommand(id: "model.quickMeasure", title: "Quick Measure…", menu: .modeling, symbol: "wand.and.stars",
                       separatorBefore: true,
                       isEnabled: { $0.model.tables.isEmpty == false }) { store in
                store.present { QuickMeasureSheet() }
            },
            AppCommand(id: "model.newParameter", title: "New Parameter…", menu: .modeling, symbol: "slider.horizontal.3",
                       isEnabled: { $0.model.tables.isEmpty == false }) { store in
                store.present { WhatIfParameterSheet() }
            },
            AppCommand(id: "model.relationships", title: "Manage Relationships…", menu: .modeling, symbol: "arrow.left.arrow.right",
                       separatorBefore: true,
                       isEnabled: { $0.model.tables.count >= 2 }) { store in
                store.present { RelationshipsSheet() }
            },
            AppCommand(id: "model.roles", title: "Manage Roles…", menu: .modeling, symbol: "lock.shield",
                       isEnabled: { $0.model.tables.isEmpty == false }) { store in
                store.present { RolesSheet() }
            },
        ]
    }
}

// MARK: - Quick measures

struct QuickMeasureSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var calculation: QuickMeasureTemplates.Calculation = .averagePerCategory
    @State private var inputs = QuickMeasureTemplates.Inputs()
    @State private var filterValue: String = ""
    @State private var name = ""
    @State private var problem: String?

    private var allFields: [FieldRef] {
        store.model.tables.flatMap { t in
            t.columns.filter { !$0.isHidden }.map { FieldRef.column(t.name, $0.name) }
                + t.measures.filter { !$0.isHidden }.map { FieldRef.measure(t.name, $0.name) }
        }
    }

    var body: some View {
        ModelingSheet(title: "Quick measure", subtitle: "Pick a calculation and its fields; the DAX is generated for you.",
                      width: 620, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Picker("Calculation", selection: $calculation) {
                    ForEach(QuickMeasureTemplates.Calculation.allCases) { c in
                        Text(c.title).tag(c)
                    }
                }
                .onChange(of: calculation) { _, _ in inputs = QuickMeasureTemplates.Inputs(); problem = nil }
                slotsList
                nameField
                if let problem { Text(problem).font(Design.Typeface.caption).foregroundStyle(.red) }
            }
        } footer: {
            ModelingSheetButtons(confirmTitle: "Add Measure", confirm: { add() })
        }
    }

    @ViewBuilder
    private var slotsList: some View {
        let slots = QuickMeasureTemplates.slots(calculation)
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            ForEach(slots) { slot in
                LabeledContent(slot.title) {
                    Picker(slot.title, selection: slotBinding(slot)) {
                        Text("—").tag(FieldRef?.none)
                        ForEach(fields(for: slot.kind), id: \.key) { f in
                            Text(f.caption).tag(FieldRef?.some(f))
                        }
                    }
                    .frame(width: 260)
                }
            }
            ForEach(QuickMeasureTemplates.options(calculation)) { option in
                LabeledContent(option.title) {
                    TextField(option.defaultValue, text: Binding(
                        get: { inputs.options[option.key] ?? option.defaultValue },
                        set: { inputs.options[option.key] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
            if showsFilterValue {
                LabeledContent("Filter value") {
                    TextField("Value", text: $filterValue).textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
        }
    }

    @ViewBuilder
    private var nameField: some View {
        LabeledContent("Name") {
            TextField(suggestedName, text: $name).textFieldStyle(.roundedBorder)
        }
    }

    private var showsFilterValue: Bool {
        switch calculation {
        case .filteredValue, .differenceFromFiltered, .percentDifferenceFromFiltered: return true
        default: return false
        }
    }

    private var suggestedName: String {
        let measure = inputs.field("measure")?.caption
        switch calculation {
        case .averagePerCategory: return measure.map { "\($0) by category" } ?? "Measure"
        case .filteredValue: return measure.map { "\($0) filtered" } ?? "Measure"
        case .yearToDate: return measure.map { "\($0) YTD" } ?? "Measure"
        case .yearOverYear: return measure.map { "\($0) YoY %" } ?? "Measure"
        case .rollingAverage: return measure.map { "\($0) rolling average" } ?? "Measure"
        case .runningTotal: return measure.map { "\($0) running total" } ?? "Measure"
        default: return "Measure"
        }
    }

    private func slotBinding(_ slot: QuickMeasureTemplates.Slot) -> Binding<FieldRef?> {
        Binding(get: { inputs.field(slot.key) }, set: { v in
            if let v { inputs.fields[slot.key] = [v] } else { inputs.fields[slot.key] = nil }
        })
    }

    private func fields(for kind: QuickMeasureTemplates.SlotKind) -> [FieldRef] {
        switch kind {
        case .value, .measure: return allFields.filter { $0.kind == .measure || $0.aggregation != .none || isNumericColumn($0) }
        case .column: return allFields.filter { $0.kind == .column && !isNumericColumn($0) }
        case .dateColumn: return allFields.filter { $0.kind == .column && isTemporalColumn($0) }
        }
    }

    private func isNumericColumn(_ f: FieldRef) -> Bool {
        guard f.kind == .column, let col = store.model.table(f.table)?.column(f.name) else { return false }
        return col.dataType.isNumeric
    }
    private func isTemporalColumn(_ f: FieldRef) -> Bool {
        guard f.kind == .column, let col = store.model.table(f.table)?.column(f.name) else { return false }
        return col.dataType.isTemporal
    }

    private func add() {
        guard let measure = analyzeTarget else { problem = "Pick a base measure or column."; return }
        if showsFilterValue {
            inputs.filterValues = [Value.string(filterValue)]
        }
        guard let expression = QuickMeasureTemplates.dax(calculation, inputs, model: store.model) else {
            problem = "Pick the fields this calculation needs."
            return
        }
        let home = measure.table
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? suggestedName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = FormulaEdit(kind: .measure, table: home, original: nil, text: "\(finalName) = \(expression)")
        Task {
            if let message = await ModelOps.commitFormula(store, edit) {
                problem = message
            } else {
                store.dismissSheet()
            }
        }
    }

    /// The base measure or column the generated calculation is built on.
    private var analyzeTarget: FieldRef? {
        inputs.field("measure") ?? inputs.field("value") ?? inputs.field("x") ?? inputs.field("column")
    }
}

// MARK: - What-if parameter

struct WhatIfParameterSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var minimum = "0"
    @State private var maximum = "100"
    @State private var increment = "1"
    @State private var defaultValue = "10"
    @State private var problem: String?

    var body: some View {
        ModelingSheet(title: "New parameter", subtitle: "Creates a numeric series table with a slicer, used as an input to measures.",
                      width: 560, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                LabeledContent("Name") { TextField("Discount", text: $name).textFieldStyle(.roundedBorder).frame(width: 180) }
                HStack(spacing: Design.Space.m) {
                    LabeledContent("Minimum") { TextField("0", text: $minimum).textFieldStyle(.roundedBorder).frame(width: 80) }
                    LabeledContent("Maximum") { TextField("100", text: $maximum).textFieldStyle(.roundedBorder).frame(width: 80) }
                }
                HStack(spacing: Design.Space.m) {
                    LabeledContent("Increment") { TextField("1", text: $increment).textFieldStyle(.roundedBorder).frame(width: 80) }
                    LabeledContent("Default") { TextField("10", text: $defaultValue).textFieldStyle(.roundedBorder).frame(width: 80) }
                }
                if let problem { Text(problem).font(Design.Typeface.caption).foregroundStyle(.red) }
            }
        } footer: {
            ModelingSheetButtons(confirmTitle: "Create", confirm: { create() })
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { problem = "Name the parameter."; return }
        guard let lo = Double(minimum), let hi = Double(maximum), let inc = Double(increment),
              inc > 0, hi > lo else { problem = "Enter a valid numeric range and increment."; return }
        let def = Double(defaultValue) ?? lo

        var parameter = WhatIfParameter(name: trimmed, minimum: lo, maximum: hi, increment: inc, defaultValue: def)
        parameter.defaultValue = def

        Task {
            // The parameter's series table, as Power BI generates it.
            let shape: Result<DataTable?, Error> = await store.withEngine { engine in
                Result { try engine.query("EVALUATE GENERATESERIES(\(lo), \(hi), \(inc))").first }
            }
            var columns: [ModelColumn] = []
            switch shape {
            case .failure(let error):
                problem = error.localizedDescription
                return
            case .success(let series):
                if let series {
                    for c in series.columns { columns.append(ModelColumn(name: c.name, dataType: c.type)) }
                }
            }
            let tableName = "\(trimmed) Values"
            store.mutate("New Parameter", invalidates: .model) { d in
                if d.model.tableIndex(tableName) == nil {
                    d.model.tables.append(ModelTable(name: tableName, columns: columns))
                }
                if !d.model.whatIfParameters.contains(where: { ModelDAX.same($0.name, trimmed) }) {
                    d.model.whatIfParameters.append(parameter)
                }
            }
            // Add a slicer for the parameter on the current page.
            let id = store.addVisual(.slicer) { v in v.name = "\(trimmed) slicer" }
            store.updateVisual(id, name: "New Parameter") { v in
                v.setFields(.field, [.column(tableName, columns.first?.name ?? "Value")])
            }
            store.status = StatusMessage(kind: .success, text: "Created parameter \(trimmed) with a slicer.")
            store.dismissSheet()
        }
    }
}

// MARK: - Relationships

struct RelationshipsSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var problems: [String] = []

    var body: some View {
        ModelingSheet(title: "Manage relationships", subtitle: store.model.relationships.isEmpty
            ? "No relationships yet. Autodetect finds matches on identically named key columns."
            : "\(store.model.relationships.count) relationship\(store.model.relationships.count == 1 ? "" : "s").",
            width: 620, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                ForEach(store.model.relationships) { r in
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                        Text("\(r.fromTable)[\(r.fromColumn)] → \(r.toTable)[\(r.toColumn)]")
                            .font(Design.Typeface.caption).lineLimit(1)
                        Text(r.cardinality.displayName).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                        if !r.isActive { Text("inactive").font(Design.Typeface.caption).foregroundStyle(.orange) }
                        Spacer(minLength: 0)
                        Button {
                            store.mutate("Delete Relationship", invalidates: .model) { d in
                                d.model.relationships.removeAll { $0.id == r.id }
                            }
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                if store.model.relationships.isEmpty {
                    Text("No relationships.").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                }
            }
        } footer: {
            ModelingSheetButtons(confirmTitle: "Autodetect", confirm: { autodetect() })
        }
    }

    private func autodetect() {
        RelationshipOps.autodetect(store)
    }
}

// MARK: - Security roles

struct RolesSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newTable = ""
    @State private var newExpression = ""

    var body: some View {
        ModelingSheet(title: "Manage roles", subtitle: "Row-level security roles: table filters evaluated per user.",
            width: 620, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                ForEach(store.model.roles) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "lock.shield").foregroundStyle(.secondary)
                            Text(role.name).font(Design.Typeface.bodyStrong)
                            Spacer(minLength: 0)
                            Button {
                                store.mutate("Delete Role", invalidates: .model) { d in
                                    d.model.roles.removeAll { $0.id == role.id }
                                }
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        if role.tableFilters.isEmpty {
                            Text("No table filters.").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                        } else {
                            ForEach(role.tableFilters.sorted(by: { $0.key < $1.key }), id: \.key) { tableName, filter in
                                Text("\(tableName): \(filter)").font(Design.Typeface.mono)
                                    .foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Hairline()
                }
                if store.model.roles.isEmpty {
                    Text("No roles. Add one with a table filter below.").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                }
                // Add role.
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    LabeledContent("Role name") { TextField("Sales West", text: $newName).textFieldStyle(.roundedBorder).frame(width: 180) }
                    Picker("Table", selection: $newTable) {
                        Text("—").tag("")
                        ForEach(store.model.tables) { t in Text(t.name).tag(t.name) }
                    }
                    .frame(width: 220)
                    LabeledContent("DAX filter") { TextField("[Region] = \"West\"", text: $newExpression).textFieldStyle(.roundedBorder) }
                    Button("Add Role") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTable.isEmpty || newExpression.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, Design.Space.s)
            }
        } footer: {
            ModelingSheetButtons(confirm: { store.dismissSheet() })
        }
    }

    private func add() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !newTable.isEmpty, !newExpression.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.mutate("Add Role", invalidates: .model) { d in
            if let i = d.model.roles.firstIndex(where: { ModelDAX.same($0.name, trimmed) }) {
                d.model.roles[i].tableFilters[newTable] = newExpression
            } else {
                var role = SecurityRole(name: trimmed)
                role.tableFilters[newTable] = newExpression
                d.model.roles.append(role)
            }
        }
        newName = ""
        newExpression = ""
    }
}
