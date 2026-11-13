import SwiftUI
import FacetCore
import FacetDesign

/// Calculation groups: calculation items, their order, precedence and format string expressions.
struct CalculationGroupsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var draft: [CalculationGroup]
    @State private var selection: UUID?
    @State private var item: UUID?

    init(model: SemanticModel) {
        let groups = model.calculationGroups.map { g -> CalculationGroup in
            var g = g
            g.items.sort { $0.ordinal < $1.ordinal }
            return g
        }
        _draft = State(initialValue: groups)
        _selection = State(initialValue: groups.first?.id)
        _item = State(initialValue: groups.first?.items.first?.id)
    }

    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var problems: [String] { CalculationGroupLogic.problems(draft, model: store.model) }
    private var dateTables: [ModelTable] { store.model.tables.filter(\.isDateTable) }

    var body: some View {
        ModelingSheet(title: "Calculation groups",
                      subtitle: "Calculation items rewrite whichever measure is in play through SELECTEDMEASURE(). Put the group's column in a slicer or on an axis.",
                      width: 900, height: 580) {
            HStack(spacing: 0) {
                NamedListColumn(items: draft.map { .init(id: $0.id, name: $0.name, symbol: "square.stack.3d.up", detail: "\($0.precedence)") },
                                selection: $selection, addHelp: "New calculation group", width: 190,
                                onAdd: {
                                    let g = CalculationGroupLogic.make(model: store.model, alongside: draft)
                                    draft.append(g); selection = g.id; item = g.items.first?.id
                                },
                                onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id; item = draft.first?.items.first?.id },
                                onRename: { id, name in if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].name = name } },
                                emptyTitle: "No calculation groups")
                Hairline(vertical: true)
                if let i = index { detail(i) } else {
                    EmptyState(systemImage: "square.stack.3d.up", title: "Create a calculation group",
                               message: "One group can give every measure a year-to-date, prior-year and variance version.")
                }
            }
            .onChange(of: selection) { _, _ in item = index.flatMap { draft[$0].items.first?.id } }
        } footer: {
            DialogProblemLine(problem: problems.first, warning: CalculationGroupLogic.precedenceWarning(draft))
            Button("Save and Add Slicer") { save(addSlicer: true) }
                .disabled(!problems.isEmpty || index == nil || store.view != .report)
                .help("Save, then add a slicer of the selected group's items to this page")
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty) { save(addSlicer: false) }
        }
    }

    private func detail(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: Design.Space.l) {
                ModelField("Name") { TextField("Time intelligence", text: $draft[i].name).textFieldStyle(.roundedBorder).frame(width: 190) }
                ModelField("Column") { TextField("Calculation item", text: $draft[i].columnName).textFieldStyle(.roundedBorder).frame(width: 170) }
                ModelField("Precedence") {
                    TextField("0", value: $draft[i].precedence, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                        .help("When several groups apply, the higher precedence is applied first")
                }
            }
            .padding(Design.Space.m)
            Hairline()
            HStack(spacing: 0) {
                NamedListColumn(items: draft[i].items.map { .init(id: $0.id, name: $0.name, symbol: "function", detail: $0.formatExpression == nil ? "" : "fmt") },
                                selection: $item, addHelp: "New calculation item", width: 190,
                                onAdd: {
                                    let new = CalculationGroupLogic.makeItem(in: draft[i])
                                    draft[i].items.append(new); item = new.id
                                },
                                onDelete: { id in draft[i].items.removeAll { $0.id == id }; item = draft[i].items.first?.id },
                                onRename: { id, name in if let k = draft[i].items.firstIndex(where: { $0.id == id }) { draft[i].items[k].name = name } },
                                onMove: { from, to in
                                    guard draft[i].items.indices.contains(from), draft[i].items.indices.contains(to) else { return }
                                    draft[i].items.swapAt(from, to)
                                },
                                emptyTitle: "No items")
                Hairline(vertical: true)
                if let k = draft[i].items.firstIndex(where: { $0.id == item }) { itemEditor(i, k) } else {
                    VStack(alignment: .leading, spacing: Design.Space.s) {
                        Text("Add an item, or start from the usual time-intelligence set.").font(Design.Typeface.caption).foregroundStyle(.secondary)
                        timeIntelligenceMenu(i)
                    }
                    .padding(Design.Space.m).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func itemEditor(_ i: Int, _ k: Int) -> some View {
        let itemID = draft[i].items[k].id
        func write(_ body: (inout CalculationItem) -> Void) {
            guard let gi = draft.firstIndex(where: { $0.id == selection }),
                  let ki = draft[gi].items.firstIndex(where: { $0.id == itemID }) else { return }
            body(&draft[gi].items[ki])
        }
        return VStack(alignment: .leading, spacing: Design.Space.m) {
            ModelField("Item name") { TextField("YTD", text: $draft[i].items[k].name).textFieldStyle(.roundedBorder).frame(width: 220) }
            ModelField("Expression") {
                ModelingDAXEditor(text: draft[i].items[k].expression, kind: .measure, height: 130) { new in write { $0.expression = new } }
                    .id(itemID)
            }
            Toggle("Dynamic format string", isOn: Binding(get: { draft[i].items[k].formatExpression != nil },
                                                          set: { on in write { $0.formatExpression = on ? "SELECTEDMEASUREFORMATSTRING()" : nil } }))
                .toggleStyle(.checkbox)
            if let format = draft[i].items[k].formatExpression {
                ModelField("Format string expression") {
                    ModelingDAXEditor(text: format, kind: .measure, height: 54) { new in write { $0.formatExpression = new } }
                        .id("fmt-\(itemID)")
                }
            }
            timeIntelligenceMenu(i)
            Spacer(minLength: 0)
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func timeIntelligenceMenu(_ i: Int) -> some View {
        Menu {
            if dateTables.isEmpty { Text("Mark a table as a date table first") }
            ForEach(dateTables) { t in
                Button("Using \(t.name)[\(t.dateColumn ?? "")]") {
                    let items = CalculationGroupLogic.timeIntelligenceItems(dateTable: t.name, dateColumn: t.dateColumn ?? "", existing: draft[i].items)
                    draft[i].items.append(contentsOf: items)
                    if item == nil { item = draft[i].items.first?.id }
                }
            }
        } label: { Label("Add time intelligence items", systemImage: "calendar.badge.plus").font(Design.Typeface.caption) }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Adds Current, YTD, PY, YoY and YoY % items that this group doesn't have yet")
    }

    private func save(addSlicer: Bool) {
        guard problems.isEmpty else { return }
        let groups = CalculationGroupLogic.normalized(draft)
        let chosen = groups.first { $0.id == selection }
        store.mutate("Edit Calculation Groups", invalidates: .model) { $0.model.calculationGroups = groups }
        if addSlicer, let g = chosen {
            let id = store.addVisual(.slicer) { $0.name = "\(g.name) slicer" }
            store.updateVisual(id, name: "Add Slicer") { $0.setFields(.field, [.column(g.name, g.columnName)]) }
        }
        store.dismissSheet()
    }
}
