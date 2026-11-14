import SwiftUI
import FacetCore
import FacetDesign

/// Manage relationships: every relationship in the model, with new, edit, delete, activate and autodetect.
struct RelationshipsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var selection: UUID?
    @State private var editing: Relationship?
    @State private var message: String?

    var body: some View {
        ModelingSheet(title: "Manage relationships",
                      subtitle: "Relationships let filters on one table reach another. One active path connects any two tables.",
                      width: 760, height: 480) {
            if let editing {
                RelationshipEditor(original: editing, isNew: !store.model.relationships.contains { $0.id == editing.id },
                                   onDone: { self.editing = nil })
            } else {
                list
            }
        } footer: {
            if editing == nil {
                Button("New…") { beginNew() }
                Button("Autodetect") { autodetect() }.help("Find relationships between columns with matching names")
                Button("Edit…") { editing = selected }.disabled(selected == nil)
                Button("Delete") { delete() }.disabled(selected == nil)
                DialogProblemLine(problem: message)
                ModelingSheetButtons(cancelTitle: nil, confirmTitle: "Close")
            }
        }
    }

    private var selected: Relationship? { store.model.relationships.first { $0.id == selection } }

    @ViewBuilder
    private var list: some View {
        if store.model.relationships.isEmpty {
            EmptyState(systemImage: ModelGlyph.relationship, title: "No relationships yet",
                       message: "Choose New to relate two columns, or Autodetect to match columns by name.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack(spacing: Design.Space.s) {
                        Text("Active").frame(width: 44, alignment: .leading)
                        Text("From: table (column)").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Cardinality").frame(width: 130, alignment: .leading)
                        Text("To: table (column)").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Filter").frame(width: 50, alignment: .leading)
                    }
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Design.Space.l).padding(.vertical, Design.Space.xs)
                    Hairline()
                    ForEach(store.model.relationships) { r in row(r) }
                }
            }
        }
    }

    private func row(_ r: Relationship) -> some View {
        let isSelected = selection == r.id
        return HStack(spacing: Design.Space.s) {
            Toggle("Active", isOn: Binding(get: { r.isActive }, set: { setActive(r, $0) }))
                .labelsHidden().toggleStyle(.checkbox).frame(width: 44, alignment: .leading)
                .help(r.isActive ? "Deactivate this relationship" : "Make this relationship active")
            Text("\(r.fromTable) (\(r.fromColumn))").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(r.cardinality.displayName).foregroundStyle(.secondary).lineLimit(1).frame(width: 130, alignment: .leading)
            Text("\(r.toTable) (\(r.toColumn))").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(r.crossFilter == .both ? "Both" : "Single").foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
        }
        .font(Design.Typeface.body)
        .padding(.horizontal, Design.Space.l).padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selection = r.id; editing = r }
        .onTapGesture { selection = r.id; message = nil }
        .contextMenu {
            Button("Edit…") { editing = r }
            Button("Delete", role: .destructive) { selection = r.id; delete() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func beginNew() {
        message = nil
        let tables = store.model.tables
        let from = DialogTarget.table(store) ?? tables.first?.name ?? ""
        var r = Relationship(fromTable: from, fromColumn: "", toTable: tables.first { !ModelDAX.same($0.name, from) }?.name ?? "", toColumn: "")
        if let c = DialogTarget.column(store), ModelDAX.same(c.table, from) { r.fromColumn = c.name }
        editing = r
    }

    private func setActive(_ r: Relationship, _ active: Bool) {
        if active, let problem = RelationshipEditLogic.activationProblem(r.id, model: store.model) {
            message = problem
            return
        }
        message = nil
        ModelOps.updateRelationships(store, [r.id], name: active ? "Activate Relationship" : "Deactivate Relationship") { $0.isActive = active }
    }

    private func delete() {
        guard let id = selection else { return }
        message = nil
        store.mutate("Delete Relationship", invalidates: .model) { d in d.model.relationships.removeAll { $0.id == id } }
        selection = nil
    }

    private func autodetect() {
        let model = store.model
        let data = DialogTarget.data(store)
        Task {
            let found = await Task.detached(priority: .userInitiated) { RelationshipLogic.autodetect(model, data: data) }.value
            if found.isEmpty {
                message = nil
                store.status = StatusMessage(kind: .info, text: "No new relationships found.")
            } else {
                store.mutate("Autodetect Relationships", invalidates: .model) { $0.model.relationships.append(contentsOf: found) }
                store.status = StatusMessage(kind: .success, text: "Found \(found.count) new relationship\(found.count == 1 ? "" : "s").")
                selection = found.first?.id
            }
        }
    }
}

/// The new / edit relationship form.
struct RelationshipEditor: View {
    @EnvironmentObject private var store: DocumentStore
    let original: Relationship
    let isNew: Bool
    let onDone: () -> Void
    @State private var draft: Relationship
    @State private var uniqueness = RelationshipEditLogic.Uniqueness()

    init(original: Relationship, isNew: Bool, onDone: @escaping () -> Void) {
        self.original = original; self.isNew = isNew; self.onDone = onDone
        _draft = State(initialValue: original)
    }

    private var check: RelationshipEditLogic.Check {
        RelationshipEditLogic.check(draft, model: store.model, uniqueness: uniqueness)
    }
    private var columnsKey: String { "\(draft.fromTable)|\(draft.fromColumn)|\(draft.toTable)|\(draft.toColumn)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text(isNew ? "New relationship" : "Edit relationship").font(Design.Typeface.bodyStrong)
            HStack(alignment: .top, spacing: Design.Space.l) {
                end(title: "From table", table: $draft.fromTable, column: $draft.fromColumn, mark: RelationshipEditLogic.endMarks(draft.cardinality).from)
                end(title: "To table", table: $draft.toTable, column: $draft.toColumn, mark: RelationshipEditLogic.endMarks(draft.cardinality).to)
            }
            HStack(alignment: .top, spacing: Design.Space.l) {
                ModelField("Cardinality") {
                    Picker("Cardinality", selection: $draft.cardinality) {
                        ForEach(Cardinality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width: 220)
                }
                ModelField("Cross-filter direction") {
                    Picker("Cross-filter direction", selection: $draft.crossFilter) {
                        Text("Single").tag(CrossFilterDirection.single)
                        Text("Both").tag(CrossFilterDirection.both)
                    }.labelsHidden().frame(width: 140).disabled(draft.cardinality == .oneToOne)
                }
            }
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Toggle("Make this relationship active", isOn: $draft.isActive)
                Toggle("Assume referential integrity", isOn: $draft.assumeReferentialIntegrity)
                    .help("Lets DirectQuery sources use inner joins")
                Toggle("Apply security filter in both directions", isOn: $draft.securityFilterBothDirections)
                    .disabled(RelationshipEditLogic.normalized(draft).crossFilter == .single)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
            HStack(spacing: Design.Space.s) {
                DialogProblemLine(problem: check.problem, warning: check.warnings.first)
                Spacer()
                Button("Back") { onDone() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(check.problem != nil)
            }
        }
        .padding(Design.Space.l)
        .onChange(of: draft.cardinality) { _, _ in draft = RelationshipEditLogic.normalized(draft) }
        .task(id: columnsKey) { await detect() }
    }

    private func end(title: String, table: Binding<String>, column: Binding<String>, mark: String) -> some View {
        ModelField(title) {
            HStack(spacing: Design.Space.s) {
                ModelTablePicker(label: title, selection: Binding(get: { table.wrappedValue }, set: { new in
                    if new != table.wrappedValue { table.wrappedValue = new; column.wrappedValue = "" }
                })).frame(width: 150)
                ModelColumnPicker(label: "\(title) column", table: table.wrappedValue, selection: column,
                                  filter: { $0.dataType != .binary }).frame(width: 150)
                Text(mark).font(Design.Typeface.bodyStrong).foregroundStyle(.secondary).frame(width: 14)
                    .help(mark == "1" ? "One: values are unique" : "Many: values can repeat")
            }
        }
    }

    /// Reads whether each column is unique and, for a new relationship, sets the cardinality the data implies.
    private func detect() async {
        let probe = draft
        guard !probe.fromColumn.isEmpty, !probe.toColumn.isEmpty else { uniqueness = .init(); return }
        let data = DialogTarget.data(store), skipping = RelationshipEditLogic.unvalidatedTables(store.model)
        let found = await Task.detached(priority: .userInitiated) { RelationshipEditLogic.uniqueness(probe, data: data, skipping: skipping) }.value
        if Task.isCancelled { return }
        uniqueness = found
        let columnsChanged = probe.fromColumn != original.fromColumn || probe.toColumn != original.toColumn
            || probe.fromTable != original.fromTable || probe.toTable != original.toTable
        if isNew || columnsChanged, let c = RelationshipEditLogic.detectedCardinality(found) {
            draft.cardinality = c
            draft = RelationshipEditLogic.normalized(draft)
            if isNew, RelationshipLogic.hasActivePath(store.model, from: draft.fromTable, to: draft.toTable, excluding: draft.id) { draft.isActive = false }
        }
    }

    private func save() {
        guard check.problem == nil else { return }
        let r = RelationshipEditLogic.normalized(draft)
        store.mutate(isNew ? "New Relationship" : "Edit Relationship", invalidates: .model) { d in
            RelationshipEditLogic.upsert(r, into: &d.model)
        }
        onDone()
    }
}
