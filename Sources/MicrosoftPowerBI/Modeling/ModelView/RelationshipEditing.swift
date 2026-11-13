import SwiftUI
import FacetCore
import FacetDesign

extension RelationshipLogic {
    /// Why an edited relationship can't be saved, or nil: its columns must be valid, different
    /// tables, compatible types and not already related; and it can only be active when its two
    /// tables aren't already connected by other active relationships.
    static func updateProblem(_ updated: Relationship, model: SemanticModel) -> String? {
        if let problem = problem(updated, model: model) { return problem }
        if updated.isActive, hasActivePath(model, from: updated.fromTable, to: updated.toTable, excluding: updated.id) {
            return "\(updated.fromTable) and \(updated.toTable) are already connected by another active path. Make that relationship inactive first, or keep this one inactive."
        }
        return nil
    }

    /// Swaps the two ends, keeping the meaning of the cardinality (many-to-one becomes one-to-many).
    static func swapped(_ r: Relationship) -> Relationship {
        var s = r
        s.fromTable = r.toTable; s.fromColumn = r.toColumn
        s.toTable = r.fromTable; s.toColumn = r.fromColumn
        switch r.cardinality {
        case .manyToOne: s.cardinality = .oneToMany
        case .oneToMany: s.cardinality = .manyToOne
        case .oneToOne, .manyToMany: break
        }
        return s
    }

    /// After an end's table changes, its column may not exist there. Picks the column named like
    /// the other end's, else the first with a compatible type, else leaves it empty to be chosen.
    static func retargeted(_ r: Relationship, model: SemanticModel) -> Relationship {
        func column(in table: String, current: String, other otherTable: String, _ otherColumn: String) -> String {
            guard let t = model.table(table) else { return "" }
            if let c = t.column(current) { return c.name }
            if let c = t.column(otherColumn) { return c.name }
            if let type = model.table(otherTable)?.column(otherColumn)?.dataType,
               let c = t.columns.first(where: { compatible($0.dataType, type) && $0.dataType != .binary }) { return c.name }
            return ""
        }
        var out = r
        out.fromColumn = column(in: r.fromTable, current: r.fromColumn, other: r.toTable, r.toColumn)
        out.toColumn = column(in: r.toTable, current: r.toColumn, other: out.fromTable, out.fromColumn)
        return out
    }

    /// One-to-one relationships always filter both ways, as in Power BI.
    static func normalized(_ r: Relationship) -> Relationship {
        var n = r
        if n.cardinality == .oneToOne { n.crossFilter = .both }
        if n.crossFilter == .single { n.securityFilterBothDirections = false }
        return n
    }
}

extension RelationshipOps {
    /// Saves an edited relationship when it is valid. Returns the problem when it is not.
    @discardableResult
    static func update(_ store: DocumentStore, _ edited: Relationship) -> String? {
        let updated = RelationshipLogic.normalized(edited)
        guard let current = store.model.relationships.first(where: { $0.id == updated.id }) else { return "This relationship no longer exists." }
        if current == updated { return nil }
        if let problem = RelationshipLogic.updateProblem(updated, model: store.model) { return problem }
        ModelOps.updateRelationships(store, [updated.id], name: "Edit Relationship") { $0 = updated }
        return nil
    }

    static func delete(_ store: DocumentStore, _ id: UUID) {
        ModelOps.delete(store, [.relationship(id)])
    }
}

/// The fields of one relationship: its two columns, cardinality, cross-filter direction and
/// options. Used in the Properties panel and in the editor a double-click on a line opens.
struct RelationshipForm: View {
    @EnvironmentObject private var store: DocumentStore
    @Binding var relationship: Relationship
    /// Narrow (Properties panel) or two-column (sheet).
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            end("From", table: $relationship.fromTable, column: $relationship.fromColumn)
            end("To", table: $relationship.toTable, column: $relationship.toColumn)
            Button { relationship = RelationshipLogic.swapped(relationship) } label: {
                Label("Swap tables", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(.link)
            .help("Swap the from and to tables")
            Hairline()
            row("Cardinality") {
                Picker("Cardinality", selection: $relationship.cardinality) {
                    ForEach(Cardinality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            row("Cross-filter") {
                Picker("Cross-filter direction", selection: $relationship.crossFilter) {
                    Text("Single").tag(CrossFilterDirection.single)
                    Text("Both").tag(CrossFilterDirection.both)
                }
                .labelsHidden()
                .disabled(relationship.cardinality == .oneToOne)
                .help(relationship.cardinality == .oneToOne ? "One-to-one relationships always filter both ways" : "Which way filters flow")
            }
            Toggle("Make this relationship active", isOn: $relationship.isActive)
            Toggle("Assume referential integrity", isOn: $relationship.assumeReferentialIntegrity)
                .help("For DirectQuery: join with INNER JOIN because every row has a match")
            Toggle("Apply security filter in both directions", isOn: $relationship.securityFilterBothDirections)
                .disabled(relationship.crossFilter != .both)
        }
        .controlSize(.small)
        .onChange(of: relationship.cardinality) { _, _ in relationship = RelationshipLogic.normalized(relationship) }
        .onChange(of: relationship.crossFilter) { _, _ in relationship = RelationshipLogic.normalized(relationship) }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(label).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    content().frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LabeledContent(label) { content().frame(width: 260, alignment: .leading) }
            }
        }
    }

    private func end(_ label: String, table: Binding<String>, column: Binding<String>) -> some View {
        row(label) {
            HStack(spacing: Design.Space.xs) {
                Picker("\(label) table", selection: table) {
                    ForEach(store.model.tables) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                Picker("\(label) column", selection: column) {
                    if store.model.table(table.wrappedValue)?.column(column.wrappedValue) == nil { Text("—").tag(column.wrappedValue) }
                    ForEach(store.model.table(table.wrappedValue)?.columns ?? []) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
            }
        }
        .onChange(of: table.wrappedValue) { _, _ in
            // The column has to exist in the newly chosen table.
            let fixed = RelationshipLogic.retargeted(relationship, model: store.model)
            if fixed != relationship { relationship = fixed }
        }
    }
}

/// Edits one relationship; opened by double-clicking its line in Model view.
struct RelationshipEditSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var draft: Relationship
    @State private var problem: String?

    init(relationship: Relationship) { _draft = State(initialValue: relationship) }

    var body: some View {
        ModelingSheet(title: "Edit relationship", subtitle: RelationshipOps.caption(draft), width: 520, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                RelationshipForm(relationship: $draft, compact: false)
                if let problem {
                    Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Space.l)
        } footer: {
            Button("Delete", role: .destructive) {
                RelationshipOps.delete(store, draft.id)
                store.dismissSheet()
            }
            .help("Delete this relationship")
            ModelingSheetButtons(confirmTitle: "Save", confirm: save)
        }
        .onChange(of: draft) { _, _ in problem = nil }
    }

    private func save() {
        if let message = RelationshipOps.update(store, draft) { problem = message } else { store.dismissSheet() }
    }
}
