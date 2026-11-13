import SwiftUI
import FacetCore
import FacetDesign

/// Hierarchies of one table: create, rename, and add, remove and reorder levels.
struct HierarchiesSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    @State private var draft: [Hierarchy]
    @State private var selection: UUID?
    @State private var level: String?

    /// - Parameter startingFrom: a column to start a new hierarchy with (the "New hierarchy" command on a column).
    init(table: ModelTable, startingFrom column: String? = nil) {
        self.table = table.name
        var hierarchies = table.hierarchies
        var selected = hierarchies.first?.id
        if let column, table.column(column) != nil {
            let h = HierarchyLogic.make(from: [column], in: table)
            hierarchies.append(h)
            selected = h.id
        }
        _draft = State(initialValue: hierarchies)
        _selection = State(initialValue: selected)
    }

    private var modelTable: ModelTable { store.model.table(table) ?? ModelTable(name: table) }
    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var problems: [String] { HierarchyLogic.problems(draft, table: modelTable) }

    var body: some View {
        ModelingSheet(title: "Hierarchies in \(table)", subtitle: "A hierarchy is a drill path: the top level first, such as Year, Quarter, Month.",
                      width: 700, height: 460) {
            HStack(spacing: 0) {
                NamedListColumn(items: draft.map { .init(id: $0.id, name: $0.name, symbol: ModelGlyph.hierarchy, detail: "\($0.levels.count)") },
                                selection: $selection, addHelp: "New hierarchy", width: 220,
                                onAdd: {
                                    let h = HierarchyLogic.make(from: [], in: modelTable, alongside: draft)
                                    draft.append(h); selection = h.id
                                },
                                onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id },
                                onRename: { id, name in if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].name = name } },
                                emptyTitle: "No hierarchies")
                Hairline(vertical: true)
                if let i = index { detail(i) } else {
                    EmptyState(systemImage: ModelGlyph.hierarchy, title: "Create a hierarchy", message: "Add one, then choose its levels from the columns of \(table).")
                }
            }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty, confirm: save)
        }
    }

    private func detail(_ i: Int) -> some View {
        let available = modelTable.columns.filter { c in !draft[i].levels.contains { ModelDAX.same($0, c.name) } }
        return VStack(alignment: .leading, spacing: Design.Space.m) {
            ModelField("Name") {
                TextField("Hierarchy", text: $draft[i].name).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            Toggle("Hidden in report view", isOn: $draft[i].isHidden).toggleStyle(.checkbox)
            ModelField("Levels, top first") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(draft[i].levels.enumerated()), id: \.element) { k, name in
                        HStack(spacing: Design.Space.xs) {
                            Text("\(k + 1)").font(Design.Typeface.caption).foregroundStyle(.tertiary).frame(width: 16)
                            Text(name).font(Design.Typeface.body).lineLimit(1)
                            Spacer(minLength: 0)
                            FieldWellGlyphButton("chevron.up", help: "Move \(name) up", disabled: k == 0) {
                                draft[i].levels = HierarchyLogic.move(draft[i].levels, from: k, to: k - 1)
                            }
                            FieldWellGlyphButton("chevron.down", help: "Move \(name) down", disabled: k == draft[i].levels.count - 1) {
                                draft[i].levels = HierarchyLogic.move(draft[i].levels, from: k, to: k + 1)
                            }
                            FieldWellGlyphButton("xmark", help: "Remove \(name)") { draft[i].levels.removeAll { $0 == name } }
                        }
                        .padding(.horizontal, Design.Space.s).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
                    }
                    Menu {
                        if available.isEmpty { Text("Every column is already a level") }
                        ForEach(available) { c in
                            Button(c.name) { draft[i].levels = HierarchyLogic.adding(c.name, to: draft[i].levels) }
                        }
                    } label: { Label("Add level", systemImage: "plus").font(Design.Typeface.caption) }
                    .menuStyle(.borderlessButton).fixedSize().padding(.top, Design.Space.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func save() {
        guard problems.isEmpty else { return }
        let hierarchies = HierarchyLogic.cleaned(draft)
        ModelOps.updateTable(store, table, name: "Edit Hierarchies") { $0.hierarchies = hierarchies }
        store.dismissSheet()
    }
}
