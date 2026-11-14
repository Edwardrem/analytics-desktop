import SwiftUI
import FacetCore
import FacetDesign

extension RelationshipLogic {
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
}

extension RelationshipOps {
    /// Saves an edited relationship when it passes the relationship editor's checks
    /// (`RelationshipEditLogic.check`). Returns the problem when it does not.
    @discardableResult
    static func update(_ store: DocumentStore, _ edited: Relationship) -> String? {
        let updated = RelationshipEditLogic.normalized(edited)
        guard let current = store.model.relationships.first(where: { $0.id == updated.id }) else { return "This relationship no longer exists." }
        if current == updated { return nil }
        let data = store.computedData.tables.isEmpty ? store.doc.data : store.computedData
        let unique = RelationshipEditLogic.uniqueness(updated, data: data, skipping: RelationshipEditLogic.unvalidatedTables(store.model))
        let check = RelationshipEditLogic.check(updated, model: store.model, uniqueness: unique)
        if let problem = check.problem { return problem }
        ModelOps.updateRelationships(store, [updated.id], name: "Edit Relationship") { $0 = updated }
        return nil
    }

    static func delete(_ store: DocumentStore, _ id: UUID) {
        ModelOps.delete(store, [.relationship(id)])
    }
}

/// The fields of one relationship, laid out for the narrow Properties panel, where every change
/// is applied at once. (The dialog form is `RelationshipEditor`.)
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
        .onChange(of: relationship.cardinality) { _, _ in relationship = RelationshipEditLogic.normalized(relationship) }
        .onChange(of: relationship.crossFilter) { _, _ in relationship = RelationshipEditLogic.normalized(relationship) }
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

/// Opens the relationship editor of the Manage relationships dialog on one relationship; shown
/// when its line is double-clicked in Model view.
struct RelationshipEditSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let relationship: Relationship

    var body: some View {
        ModelingSheet(title: "Edit relationship", subtitle: RelationshipOps.caption(relationship), width: 760, height: 420) {
            RelationshipEditor(original: relationship, isNew: false, onDone: { store.dismissSheet() })
        } footer: {
            Button("Delete relationship", role: .destructive) {
                RelationshipOps.delete(store, relationship.id)
                store.dismissSheet()
            }
            .help("Remove this relationship from the model")
            Spacer()
        }
    }
}
