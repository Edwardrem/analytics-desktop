import SwiftUI
import FacetCore
import FacetDesign

// Context menus and model edits for the Data pane.

extension DataPane {

    /// Menu item for a command owned by the modeling feature. Hidden until that command is registered.
    @ViewBuilder
    private func modelCommand(_ title: String, _ id: String, table: String, field: FieldRef? = nil) -> some View {
        if AppCommands.command(id) != nil {
            Button(title) { FieldPaneContext.run(id, table: table, field: field, store) }
        }
    }

    @ViewBuilder
    func contextMenu(for node: DataNode) -> some View {
        switch node.kind {
        case .table(let t): tableMenu(t)
        case .column(let c): columnMenu(c, table: node.table)
        case .level(let c, let h):
            Button("Remove from hierarchy") { removeLevel(c.name, hierarchy: h, table: node.table) }
            Divider()
            columnMenu(c, table: node.table)
        case .measure(let m): measureMenu(m, table: node.table)
        case .hierarchy(let h): hierarchyMenu(h, table: node.table)
        case .folder:
            Button("Expand") { setExpanded(node.id, true) }
            Button("Collapse") { setExpanded(node.id, false) }
        }
    }

    // MARK: Table

    @ViewBuilder
    private func tableMenu(_ t: ModelTable) -> some View {
        modelCommand("New measure", "model.newMeasure", table: t.name)
        modelCommand("New column", "model.newColumn", table: t.name)
        modelCommand("New quick measure…", "model.quickMeasure", table: t.name)
        modelCommand("New table", "model.newTable", table: t.name)
        Divider()
        Button("Rename") { beginRename("t|\(t.name)", t.name) }
        Button(t.isHidden ? "Unhide" : "Hide") {
            store.updateModel(t.isHidden ? "Unhide Table" : "Hide Table") { m in
                if let i = m.tableIndex(t.name) { m.tables[i].isHidden.toggle() }
            }
        }
        Button("Delete from model…", role: .destructive) {
            let uses = ModelRefactor.usageCount(in: store.report) { $0.table == t.name }
            pendingDelete = DeleteRequest(target: .table(t.name), title: "Delete “\(t.name)” from the model?",
                                          message: deleteMessage(uses, extra: "Its columns, measures and relationships are removed too."))
        }
        Divider()
        if t.sourceQuery != nil || store.doc.queries.contains(where: { $0.name == t.name }) {
            Button("Refresh data") { store.refreshData(only: [t.sourceQuery ?? t.name]) }
        }
        modelCommand(t.isDateTable ? "Date table settings…" : "Mark as date table…", "model.markDateTable", table: t.name)
        modelCommand("Incremental refresh…", "model.incrementalRefresh", table: t.name)
        Button("Copy table") { copyTable(t.name) }
    }

    // MARK: Column

    @ViewBuilder
    private func columnMenu(_ c: ModelColumn, table: String) -> some View {
        let ref = FieldRef.column(table, c.name)
        let t = store.model.table(table)
        modelCommand("New hierarchy", "model.newHierarchy", table: table, field: ref)
        if let hs = t?.hierarchies.filter({ h in !h.levels.contains { $0 == c.name } }), !hs.isEmpty {
            Menu("Add to hierarchy") {
                ForEach(hs) { h in Button(h.name) { addLevel(c.name, hierarchy: h.name, table: table) } }
            }
        }
        modelCommand("New group…", "model.newGroup", table: table, field: ref)
        Divider()
        Button("Rename") { beginRename("c|\(table)|\(c.name)", c.name) }
        Button(c.isHidden ? "Unhide" : "Hide") {
            store.updateModel(c.isHidden ? "Unhide Column" : "Hide Column") { m in
                editColumn(&m, table, c.name) { $0.isHidden.toggle() }
            }
        }
        Button("Delete…", role: .destructive) {
            let uses = ModelRefactor.usageCount(in: store.report) { $0.kind == .column && $0.table == table && $0.name == c.name }
            let rels = store.model.relationships.filter { ($0.fromTable == table && $0.fromColumn == c.name) || ($0.toTable == table && $0.toColumn == c.name) }.count
            pendingDelete = DeleteRequest(target: .column(table, c.name), title: "Delete “\(c.name)”?",
                                          message: deleteMessage(uses, extra: rels > 0 ? "\(rels) relationship\(rels == 1 ? "" : "s") on this column will be removed." : ""))
        }
        Divider()
        Picker("Sort by column", selection: Binding(get: { c.sortByColumn ?? "" }, set: { new in
            store.updateModel("Sort by Column") { m in editColumn(&m, table, c.name) { $0.sortByColumn = new.isEmpty ? nil : new } }
        })) {
            Text("Default").tag("")
            Divider()
            ForEach((t?.columns ?? []).filter { $0.name != c.name }) { other in Text(other.name).tag(other.name) }
        }
        Picker("Summarize by", selection: Binding(get: { c.summarizeBy }, set: { new in
            store.updateModel("Summarize By") { m in editColumn(&m, table, c.name) { $0.summarizeBy = new } }
        })) {
            Text(Aggregation.none.displayName).tag(Aggregation.none)
            Divider()
            ForEach(Aggregation.valid(for: c.dataType), id: \.self) { a in Text(a.label(for: c.dataType)).tag(a) }
        }
        Divider()
        filterMenu(ref)
        Button("Copy name") { copy("'\(table)'[\(c.name)]") }
    }

    // MARK: Measure

    @ViewBuilder
    private func measureMenu(_ m: Measure, table: String) -> some View {
        let ref = FieldRef.measure(table, m.name)
        modelCommand("Edit", "model.editMeasure", table: table, field: ref)
        Button("Rename") { beginRename("m|\(table)|\(m.name)", m.name) }
        Button(m.isHidden ? "Unhide" : "Hide") {
            store.updateModel(m.isHidden ? "Unhide Measure" : "Hide Measure") { model in
                if let ti = model.tableIndex(table), let mi = model.tables[ti].measures.firstIndex(where: { $0.name == m.name }) {
                    model.tables[ti].measures[mi].isHidden.toggle()
                }
            }
        }
        Button("Delete…", role: .destructive) {
            let uses = ModelRefactor.usageCount(in: store.report) { $0.kind == .measure && $0.name == m.name }
            pendingDelete = DeleteRequest(target: .measure(table, m.name), title: "Delete “\(m.name)”?",
                                          message: deleteMessage(uses, extra: "Measures that reference it will show an error."))
        }
        let others = store.model.tables.filter { $0.name != table }
        if !others.isEmpty {
            Menu("Move to table") {
                ForEach(others) { t in
                    Button(t.name) {
                        store.mutate("Move Measure", invalidates: .model) { ModelRefactor.moveMeasure(&$0, name: m.name, from: table, to: t.name) }
                    }
                }
            }
        }
        Divider()
        filterMenu(ref)
        Button("Copy name") { copy("[\(m.name)]") }
    }

    // MARK: Hierarchy

    @ViewBuilder
    private func hierarchyMenu(_ h: Hierarchy, table: String) -> some View {
        Button("Rename") { beginRename("h|\(table)|\(h.name)", h.name) }
        Button(h.isHidden ? "Unhide" : "Hide") {
            store.updateModel(h.isHidden ? "Unhide Hierarchy" : "Hide Hierarchy") { m in
                if let ti = m.tableIndex(table), let hi = m.tables[ti].hierarchies.firstIndex(where: { $0.id == h.id }) {
                    m.tables[ti].hierarchies[hi].isHidden.toggle()
                }
            }
        }
        Button("Delete…", role: .destructive) {
            pendingDelete = DeleteRequest(target: .hierarchy(table, h.name), title: "Delete the hierarchy “\(h.name)”?",
                                          message: "Its columns stay in the table. You can undo this.")
        }
    }

    @ViewBuilder
    private func filterMenu(_ ref: FieldRef) -> some View {
        Menu("Add to filters") {
            if store.selectedVisual != nil { Button("On this visual") { store.addFilter(ref, scope: .visual, announce: true) } }
            if ref.kind == .column {
                Button("On this page") { store.addFilter(ref, scope: .page, announce: true) }
                Button("On all pages") { store.addFilter(ref, scope: .report, announce: true) }
            }
        }
        .disabled(ref.kind == .measure && store.selectedVisual == nil)
        if ref.kind == .column {
            Button("Add as drillthrough") { store.addFilter(ref, scope: .drillthrough, announce: true) }
        }
    }

    // MARK: Actions

    private func deleteMessage(_ uses: Int, extra: String) -> String {
        var parts: [String] = []
        if uses > 0 { parts.append("It is used in \(uses) place\(uses == 1 ? "" : "s") in this report; those uses will be removed.") }
        if !extra.isEmpty { parts.append(extra) }
        parts.append("You can undo this.")
        return parts.joined(separator: " ")
    }

    private func editColumn(_ m: inout SemanticModel, _ table: String, _ column: String, _ change: (inout ModelColumn) -> Void) {
        guard let ti = m.tableIndex(table), let ci = m.tables[ti].columns.firstIndex(where: { $0.name == column }) else { return }
        change(&m.tables[ti].columns[ci])
    }

    private func addLevel(_ column: String, hierarchy: String, table: String) {
        store.updateModel("Add to Hierarchy") { m in
            if let ti = m.tableIndex(table), let hi = m.tables[ti].hierarchies.firstIndex(where: { $0.name == hierarchy }) {
                m.tables[ti].hierarchies[hi].levels.append(column)
            }
        }
        setExpanded("h|\(table)|\(hierarchy)", true)
    }
    private func removeLevel(_ column: String, hierarchy: String, table: String) {
        store.updateModel("Remove from Hierarchy") { m in
            if let ti = m.tableIndex(table), let hi = m.tables[ti].hierarchies.firstIndex(where: { $0.name == hierarchy }) {
                m.tables[ti].hierarchies[hi].levels.removeAll { $0 == column }
                if m.tables[ti].hierarchies[hi].levels.isEmpty { m.tables[ti].hierarchies.remove(at: hi) }
            }
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Copies the table's data (with calculated columns) as tab-separated text.
    private func copyTable(_ name: String) {
        guard let t = store.computedData[name] ?? store.doc.data[name] else {
            store.status = StatusMessage(kind: .info, text: "“\(name)” has no loaded data to copy.")
            return
        }
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = [t.columnNames.map(clean).joined(separator: "\t")]
        lines.reserveCapacity(t.rowCount + 1)
        for r in 0..<t.rowCount { lines.append(t.columns.map { clean($0.values[r].asString) }.joined(separator: "\t")) }
        copy(lines.joined(separator: "\n"))
        store.status = StatusMessage(kind: .success, text: "Copied \(t.rowCount.formatted()) rows from \(name).")
    }

    // MARK: Rename

    func beginRename(_ nodeID: String, _ current: String) {
        draftName = current
        renaming = nodeID
    }

    func commitRename(_ node: DataNode) {
        let new = draftName.trimmingCharacters(in: .whitespaces)
        let old = node.name
        defer { renaming = nil }
        guard new != old else { return }
        let table = node.table
        switch node.kind {
        case .table:
            if let p = ModelRefactor.tableNameProblem(new, renaming: old, in: store.model) { store.status = StatusMessage(kind: .warning, text: p); return }
            let wasOpen = expanded.contains(node.id)
            store.mutate("Rename Table", invalidates: .model) { ModelRefactor.renameTable(&$0, from: old, to: new) }
            if wasOpen { setExpanded(node.id, false); setExpanded("t|\(new)", true) }
        case .column, .level:
            if let p = ModelRefactor.fieldNameProblem(new, renaming: .column(table, old), in: store.model) { store.status = StatusMessage(kind: .warning, text: p); return }
            store.mutate("Rename Column", invalidates: .model) { ModelRefactor.renameColumn(&$0, table: table, from: old, to: new) }
        case .measure:
            if let p = ModelRefactor.fieldNameProblem(new, renaming: .measure(table, old), in: store.model) { store.status = StatusMessage(kind: .warning, text: p); return }
            store.mutate("Rename Measure", invalidates: .model) { ModelRefactor.renameMeasure(&$0, table: table, from: old, to: new) }
        case .hierarchy:
            guard !new.isEmpty else { return }
            if let t = store.model.table(table), t.column(new) != nil || t.hierarchies.contains(where: { $0.name.caseInsensitiveCompare(new) == .orderedSame && $0.name != old }) {
                store.status = StatusMessage(kind: .warning, text: "“\(new)” already exists in \(table)."); return
            }
            let wasOpen = expanded.contains(node.id)
            store.mutate("Rename Hierarchy", invalidates: .model) { ModelRefactor.renameHierarchy(&$0, table: table, from: old, to: new) }
            if wasOpen { setExpanded(node.id, false); setExpanded("h|\(table)|\(new)", true) }
        case .folder: break
        }
    }

    func performDelete(_ req: DeleteRequest) {
        switch req.target {
        case .table(let t): store.mutate("Delete Table", invalidates: .model) { ModelRefactor.deleteTable(&$0, name: t) }
        case .column(let t, let c): store.mutate("Delete Column", invalidates: .model) { ModelRefactor.deleteColumn(&$0, table: t, name: c) }
        case .measure(let t, let m): store.mutate("Delete Measure", invalidates: .model) { ModelRefactor.deleteMeasure(&$0, table: t, name: m) }
        case .hierarchy(let t, let h):
            store.updateModel("Delete Hierarchy") { m in
                if let ti = m.tableIndex(t) { m.tables[ti].hierarchies.removeAll { $0.name == h } }
            }
        }
        pendingDelete = nil
    }
}

// MARK: - Model explorer

/// The model listed by kind of object rather than by table.
struct ModelExplorer: View {
    @EnvironmentObject var store: DocumentStore
    let search: String

    private struct Group: Identifiable {
        var id: String { title }
        var title: String
        var symbol: String
        var names: [String]
    }

    private var groups: [Group] {
        let m = store.model
        func keep(_ names: [String]) -> [String] {
            search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
        }
        return [
            Group(title: "Measures", symbol: FieldGlyph.measure, names: keep(m.allMeasures.map(\.measure.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })),
            Group(title: "Calculation groups", symbol: "square.stack.3d.up", names: keep(m.calculationGroups.map(\.name))),
            Group(title: "Relationships", symbol: "arrow.left.arrow.right",
                  names: keep(m.relationships.map { "\($0.fromTable)[\($0.fromColumn)] → \($0.toTable)[\($0.toColumn)]\($0.isActive ? "" : " (inactive)")" })),
            Group(title: "Roles", symbol: "person.badge.key", names: keep(m.roles.map(\.name))),
            Group(title: "Perspectives", symbol: "eye", names: keep(m.perspectives.map(\.name))),
            Group(title: "Cultures", symbol: "character.bubble", names: keep(m.translations.map(\.culture))),
            Group(title: "Functions", symbol: "curlybraces", names: keep(m.functions.map(\.name))),
            Group(title: "Parameters", symbol: "slider.horizontal.3", names: keep(m.fieldParameters.map(\.name) + m.whatIfParameters.map(\.name))),
        ]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { g in
                    FieldPaneSection(g.title, count: g.names.count, expanded: !g.names.isEmpty) {
                        if g.names.isEmpty {
                            PaneHint(search.isEmpty ? "None in this model." : "No matches.")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(g.names.enumerated()), id: \.offset) { _, name in
                                    ExplorerRow(symbol: g.symbol, name: name) { AppCommands.run("view.model", store) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ExplorerRow: View {
    let symbol: String
    let name: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                Text(name).font(Design.Typeface.body).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.xs)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Design.Palette.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show in Model view")
    }
}
