import SwiftUI
import FacetCore
import FacetQuery
import FacetAnalytics
import FacetDesign

/// Model view, Table view and the formula commands: new measure/column/table and quick measures.
/// The modeling dialogs register their own commands in `Dialogs/ModelingDialogsFeature.swift`.
@MainActor
enum ModelingFeature {
    static func register() {
        AppCommands.register { commands }
        ModelingDialogsFeature.register()   // every modeling dialog: see Dialogs/ModelingDialogsFeature.swift
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
            AppCommand(id: "view.model", title: "Model View", menu: .view, symbol: "rectangle.split.3x1",
                       isEnabled: { $0.model.tables.isEmpty == false }) { $0.view = .model },
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
