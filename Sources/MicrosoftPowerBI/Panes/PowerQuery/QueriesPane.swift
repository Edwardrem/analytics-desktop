import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// The Queries pane: every query, in its group folders, with the query and group context menus.
struct QueriesPane: View {
    @ObservedObject var session: QueryEditorSession
    @State private var collapsed: Set<String> = []
    @State private var disablingLoad: QueryDefinition?

    private static let otherGroup = "Other Queries"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queries [\(session.queries.count)]").font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Blank Query") { session.newBlankQuery() }
                    Button("New Source…") { session.dialog = .newSource }
                    Button("New Parameter…") { session.dialog = .manageParameters(select: nil) }
                    Divider()
                    Button("New Group…") { session.dialog = .newGroup(moving: []) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a query, parameter or group")
            }
            .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let grouped = !session.groups.isEmpty
                    ForEach(session.groups, id: \.self) { group in section(group, queries: session.queries.filter { $0.group == group }) }
                    let ungrouped = session.queries.filter { $0.group.isEmpty || !session.groups.contains($0.group) }
                    if grouped {
                        if !ungrouped.isEmpty { section("", queries: ungrouped) }
                    } else {
                        ForEach(ungrouped) { row($0, indent: 0) }
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
        }
        .confirmationDialog("Delete query?", isPresented: Binding(get: { session.deleteRequest != nil }, set: { if !$0 { session.deleteRequest = nil } }),
                            presenting: session.deleteRequest.flatMap(session.query)) { q in
            Button("Delete", role: .destructive) { session.deleteQueries([q.id]) }
            Button("Cancel", role: .cancel) {}
        } message: { q in
            Text(session.store.doc.model.tables.contains { $0.sourceQuery == q.name }
                 ? "When you apply, the table “\(q.name)” is removed from the model, and visuals that use its fields will stop working."
                 : "“\(q.name)” will be deleted when you apply.")
        }
        .confirmationDialog("Disable load?", isPresented: Binding(get: { disablingLoad != nil }, set: { if !$0 { disablingLoad = nil } }), presenting: disablingLoad) { q in
            Button("Disable Load", role: .destructive) { session.setLoadEnabled(q.id, false) }
            Button("Cancel", role: .cancel) {}
        } message: { q in
            Text("When you apply, the table “\(q.name)” is removed from the model, and visuals that use its fields will stop working.")
        }
    }

    // MARK: Groups

    private func section(_ group: String, queries: [QueryDefinition]) -> some View {
        let title = group.isEmpty ? Self.otherGroup : group
        let open = !collapsed.contains(title)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { collapsed.insert(title) } else { collapsed.remove(title) }
            } label: {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("\(title) [\(queries.count)]").font(Design.Typeface.bodyStrong).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { if !group.isEmpty { groupMenu(group) } }
            if open { ForEach(queries) { row($0, indent: 1) } }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: String) -> some View {
        Button("Rename…") { session.dialog = .renameGroup(group) }
        Button("Ungroup") { session.ungroup(group) }
        Divider()
        Button("New Query in Group") {
            session.newBlankQuery()
            if let id = session.selectedQueryID { session.moveQueries([id], toGroup: group) }
        }
    }

    // MARK: Rows

    private func row(_ q: QueryDefinition, indent: Int) -> some View {
        let selected = q.id == session.selectedQueryID
        return HStack(spacing: Design.Space.xs) {
            Image(systemName: Self.symbol(q)).foregroundStyle(.secondary).frame(width: 16)
            Text(q.name).lineLimit(1).italic(!q.loadEnabled && q.kind == .table)
            if q.kind == .parameter, let p = q.parameter {
                Text(QueryCellText.text(p.currentValue, type: p.type)).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let error = session.queryErrors[q.id] {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Design.Palette.caution)
                    .help("This query has an error: \(error)")
            }
            if q.kind == .table, !q.loadEnabled {
                Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.tertiary).help("Load is disabled: the query is connection only")
            } else if q.kind == .table, !q.includeInRefresh {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(.tertiary).help("Excluded from report refresh")
            }
        }
        .padding(.leading, Design.Space.s + CGFloat(indent) * Design.Space.l).padding(.trailing, Design.Space.s).padding(.vertical, 3)
        .background(selected ? Design.Palette.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { session.selectedQueryID = q.id }
        .help(q.description.isEmpty ? q.name : "\(q.name)\n\(q.description)")
        .contextMenu { menu(q) }
    }

    static func symbol(_ q: QueryDefinition) -> String {
        switch q.kind {
        case .table: return "tablecells"
        case .parameter: return "slider.horizontal.3"
        case .function: return "function"
        case .list: return "list.bullet"
        case .value: return "number"
        }
    }

    @ViewBuilder
    private func menu(_ q: QueryDefinition) -> some View {
        Button("Rename…") { session.dialog = .renameQuery(q.id) }
        Button("Delete") { session.deleteRequest = q.id }
        Button("Duplicate") { session.duplicateQuery(q.id) }
        Button("Reference") { session.referenceQuery(q.id) }
        Divider()
        Menu("Move to Group") {
            Button(Self.otherGroup) { session.moveQueries([q.id], toGroup: "") }.disabled(q.group.isEmpty)
            ForEach(session.groups, id: \.self) { g in Button(g) { session.moveQueries([q.id], toGroup: g) }.disabled(q.group == g) }
            Divider()
            Button("New Group…") { session.dialog = .newGroup(moving: [q.id]) }
        }
        Button("Move Up") { session.moveQuery(q.id, by: -1) }.disabled(session.queries.first?.id == q.id)
        Button("Move Down") { session.moveQuery(q.id, by: 1) }.disabled(session.queries.last?.id == q.id)
        Divider()
        if q.kind == .parameter {
            Button("Manage Parameter…") { session.dialog = .manageParameters(select: q.id) }
            Button("Convert to Query") { session.convertToQuery(q.id) }
        } else {
            Button("Create Function…") { session.dialog = .createFunction(q.id) }
            Button("Convert to Parameter") { Task { await session.convertToParameter(q.id) } }
            Button("Advanced Editor") { session.selectedQueryID = q.id; session.dialog = .advancedEditor }
        }
        Button("Properties…") { session.dialog = .queryProperties(q.id) }
        if q.kind == .table {
            Divider()
            Toggle("Enable Load", isOn: Binding(get: { q.loadEnabled }, set: { on in
                if on { session.setLoadEnabled(q.id, true) }
                else if session.store.doc.model.tables.contains(where: { $0.sourceQuery == q.name }) { disablingLoad = q }
                else { session.setLoadEnabled(q.id, false) }
            }))
            Toggle("Include in Report Refresh", isOn: Binding(get: { q.includeInRefresh }, set: { session.setIncludeInRefresh(q.id, $0) }))
                .disabled(!q.loadEnabled)
        }
    }
}

extension QueryEditorSession {
    /// Move a query up or down the list (within the whole list; its group does not change).
    func moveQuery(_ id: UUID, by offset: Int) {
        guard let i = queries.firstIndex(where: { $0.id == id }), queries.indices.contains(i + offset) else { return }
        change("Move Query", refresh: false) { qs in qs.swapAt(i, i + offset) }
    }
}
