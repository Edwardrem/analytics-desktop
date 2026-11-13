import SwiftUI
import FacetCore
import FacetDesign

/// One row of the Data pane's tree.
struct DataNode: Identifiable {
    enum Kind {
        case table(ModelTable)
        case folder(String)
        case column(ModelColumn)
        case measure(Measure)
        case hierarchy(Hierarchy)
        case level(column: ModelColumn, hierarchy: String)
    }
    var id: String
    var depth: Int
    var kind: Kind
    var table: String
    var isExpandable = false
    var isDimmed = false

    /// The field a row adds to a visual (first level for hierarchies).
    var fieldRef: FieldRef? {
        switch kind {
        case .column(let c): return .column(table, c.name)
        case .level(let c, _): return .column(table, c.name)
        case .measure(let m): return .measure(table, m.name)
        case .hierarchy(let h): return h.levels.first.map { .column(table, $0) }
        case .table, .folder: return nil
        }
    }
    var name: String {
        switch kind {
        case .table(let t): return t.name
        case .folder(let f): return f
        case .column(let c): return c.name
        case .measure(let m): return m.name
        case .hierarchy(let h): return h.name
        case .level(let c, _): return c.name
        }
    }
}

/// The model's fields, ready to drag onto the canvas.
struct DataPane: View {
    @EnvironmentObject var store: DocumentStore
    @State var search = ""
    @AppStorage("facet.dataPane.showHidden") var showHidden = false
    @AppStorage("facet.dataPane.measuresFirst") var measuresFirst = true
    @SceneStorage("facet.dataPane.expanded") var expandedRaw = ""
    @SceneStorage("facet.dataPane.explorer") var explorer = "tables"
    @State var renaming: String?
    @State var draftName = ""
    @State var pendingDelete: DeleteRequest?
    @FocusState var renameFocused: Bool

    struct DeleteRequest: Identifiable {
        enum Target { case table(String), column(String, String), measure(String, String), hierarchy(String, String) }
        var id = UUID()
        var target: Target
        var title: String
        var message: String
    }

    // MARK: Expansion

    var expanded: Set<String> { Set(expandedRaw.split(separator: "\u{1F}").map(String.init)) }
    func setExpanded(_ id: String, _ on: Bool) {
        var s = expanded
        if on { s.insert(id) } else { s.remove(id) }
        expandedRaw = s.sorted().joined(separator: "\u{1F}")
    }

    // MARK: Tree

    private func matches(_ name: String, _ synonyms: [String] = []) -> Bool {
        name.localizedCaseInsensitiveContains(search) || synonyms.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private enum Item {
        case column(ModelColumn), measure(Measure), hierarchy(Hierarchy)
        var name: String {
            switch self { case .column(let c): return c.name; case .measure(let m): return m.name; case .hierarchy(let h): return h.name }
        }
        var rank: Int { switch self { case .measure: return 0; case .hierarchy: return 1; case .column: return 2 } }
        var folder: String {
            switch self {
            case .column(let c): return c.displayFolder
            case .measure(let m): return m.displayFolder
            case .hierarchy: return ""
            }
        }
    }

    var nodes: [DataNode] {
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let open = expanded
        var out: [DataNode] = []
        let tables = store.model.tables.filter { showHidden || !$0.isHidden }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for t in tables {
            let tableMatches = searching && matches(t.name, t.synonyms)
            func keep(_ name: String, _ synonyms: [String] = []) -> Bool { !searching || tableMatches || matches(name, synonyms) }
            var items: [Item] = []
            items += t.measures.filter { (showHidden || !$0.isHidden) && keep($0.name) }.map(Item.measure)
            items += t.hierarchies.filter { (showHidden || !$0.isHidden) && keep($0.name) }.map(Item.hierarchy)
            items += t.columns.filter { (showHidden || !$0.isHidden) && keep($0.name, $0.synonyms) }.map(Item.column)
            if searching && items.isEmpty && !tableMatches { continue }
            let tid = "t|\(t.name)"
            out.append(DataNode(id: tid, depth: 0, kind: .table(t), table: t.name, isExpandable: true, isDimmed: t.isHidden))
            guard searching || open.contains(tid) else { continue }

            func sorted(_ list: [Item]) -> [Item] {
                list.sorted { a, b in
                    if measuresFirst, a.rank != b.rank { return a.rank < b.rank }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            func emit(_ item: Item, depth: Int) {
                switch item {
                case .measure(let m):
                    out.append(DataNode(id: "m|\(t.name)|\(m.name)", depth: depth, kind: .measure(m), table: t.name, isDimmed: m.isHidden || t.isHidden))
                case .column(let c):
                    out.append(DataNode(id: "c|\(t.name)|\(c.name)", depth: depth, kind: .column(c), table: t.name, isDimmed: c.isHidden || t.isHidden))
                case .hierarchy(let h):
                    let hid = "h|\(t.name)|\(h.name)"
                    out.append(DataNode(id: hid, depth: depth, kind: .hierarchy(h), table: t.name, isExpandable: true, isDimmed: h.isHidden || t.isHidden))
                    if open.contains(hid) {
                        for level in h.levels {
                            guard let c = t.column(level) else { continue }
                            out.append(DataNode(id: "\(hid)|\(level)", depth: depth + 1, kind: .level(column: c, hierarchy: h.name), table: t.name, isDimmed: h.isHidden || t.isHidden))
                        }
                    }
                }
            }
            // Display folders: "A\B" nests; a field with several folders ("A;B") appears under the first.
            func path(_ item: Item) -> [String] {
                let first = item.folder.split(separator: ";").first.map(String.init) ?? ""
                return first.split(separator: "\\").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            func walk(_ list: [Item], prefix: [String], depth: Int) {
                let here = list.filter { path($0).count == prefix.count }
                let deeper = list.filter { path($0).count > prefix.count }
                let folders = Set(deeper.map { path($0)[prefix.count] }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                for f in folders {
                    let p = prefix + [f]
                    let fid = "f|\(t.name)|\(p.joined(separator: "\\"))"
                    out.append(DataNode(id: fid, depth: depth, kind: .folder(f), table: t.name, isExpandable: true, isDimmed: t.isHidden))
                    if searching || open.contains(fid) {
                        walk(deeper.filter { Array(path($0).prefix(p.count)) == p }, prefix: p, depth: depth + 1)
                    }
                }
                for item in sorted(here) { emit(item, depth: depth) }
            }
            walk(items, prefix: [], depth: 1)
        }
        return out
    }

    /// Fields used by the selected visual, as "kind|table|name".
    private var usedFields: Set<String> {
        guard let v = store.selectedVisual else { return [] }
        return Set(v.allFields.map { "\($0.kind.rawValue)|\($0.table)|\($0.name)" })
    }
    func isUsed(_ node: DataNode, _ used: Set<String>) -> Bool {
        switch node.kind {
        case .hierarchy(let h): return !h.levels.isEmpty && h.levels.allSatisfy { used.contains("column|\(node.table)|\($0)") }
        default:
            guard let r = node.fieldRef else { return false }
            return used.contains("\(r.kind.rawValue)|\(r.table)|\(r.name)")
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            FieldPaneHeader("Data") {
                Toggle("Show hidden", isOn: $showHidden)
                Toggle("Measures first", isOn: $measuresFirst)
                Divider()
                Button("Expand all") { expandAll(true) }
                Button("Collapse all") { expandAll(false) }
            }
            if store.model.tables.isEmpty {
                VStack(spacing: Design.Space.s) {
                    EmptyState(systemImage: "cylinder.split.1x2", title: "No data yet",
                               message: "Connect to data, or load the sample to explore. Tables and fields appear here.")
                        .frame(maxHeight: 180)
                    Button("Load sample data") { AppCommands.run("data.sample", store) }.controlSize(.small)
                    Spacer()
                }
            } else {
                SearchField(text: $search, prompt: explorer == "model" ? "Search model objects" : "Search tables and fields")
                    .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.s)
                Hairline()
                if explorer == "model" { ModelExplorer(search: search) } else { tree }
                Hairline()
                footer
            }
        }
        .confirmationDialog(pendingDelete?.title ?? "", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { req in
            Button("Delete", role: .destructive) { performDelete(req) }
            Button("Cancel", role: .cancel) {}
        } message: { req in Text(req.message) }
    }

    private var tree: some View {
        let rows = nodes
        let used = usedFields
        return Group {
            if rows.isEmpty {
                EmptyState(systemImage: "magnifyingglass", title: "No matching fields", message: "Nothing in the model matches “\(search)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { node in row(node, used: used) }
                    }
                    .padding(.vertical, Design.Space.xs)
                }
            }
        }
    }

    private var footer: some View {
        let tables = store.model.tables
        let fields = tables.reduce(0) { $0 + $1.columns.count + $1.measures.count }
        return HStack(spacing: Design.Space.s) {
            Text("\(tables.count) table\(tables.count == 1 ? "" : "s") · \(fields) field\(fields == 1 ? "" : "s")")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Picker("Model explorer", selection: $explorer) {
                Text("Tables").tag("tables")
                Text("Model").tag("model")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            .help("Browse by table, or by kind of model object")
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }

    private func expandAll(_ on: Bool) {
        guard on else { expandedRaw = ""; return }
        var s = Set<String>()
        for t in store.model.tables {
            s.insert("t|\(t.name)")
            for h in t.hierarchies { s.insert("h|\(t.name)|\(h.name)") }
            let folders = t.columns.map(\.displayFolder) + t.measures.map(\.displayFolder)
            for f in folders {
                let parts = (f.split(separator: ";").first.map(String.init) ?? "").split(separator: "\\").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for n in parts.indices { s.insert("f|\(t.name)|\(parts[0...n].joined(separator: "\\"))") }
            }
        }
        expandedRaw = s.sorted().joined(separator: "\u{1F}")
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ node: DataNode, used: Set<String>) -> some View {
        let content = DataRow(node: node, isOpen: isOpen(node), isChecked: isUsed(node, used), search: search,
                              isRenaming: renaming == node.id, draftName: $draftName, renameFocused: $renameFocused,
                              toggleExpand: { setExpanded(node.id, !expanded.contains(node.id)) },
                              toggleCheck: { toggleUse(node) },
                              commitRename: { commitRename(node) },
                              cancelRename: { renaming = nil },
                              menu: { AnyView(contextMenu(for: node)) })
            .contextMenu { contextMenu(for: node) }
        if let ref = node.fieldRef, renaming != node.id {
            content
                .onTapGesture(count: 2) { addToVisual(node) }
                .draggable(FieldDrag.encode(ref)) {
                    Chip(node.name, systemImage: glyph(node)).padding(2)
                }
        } else {
            content
        }
    }

    private func isOpen(_ node: DataNode) -> Bool {
        if expanded.contains(node.id) { return true }
        if case .hierarchy = node.kind { return false }
        return !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func glyph(_ node: DataNode) -> String {
        switch node.kind {
        case .table(let t): return FieldGlyph.symbol(table: t)
        case .folder: return FieldGlyph.folder
        case .column(let c), .level(let c, _): return FieldGlyph.symbol(column: c)
        case .measure: return FieldGlyph.measure
        case .hierarchy: return FieldGlyph.hierarchy
        }
    }

    // MARK: Using fields

    private func addToVisual(_ node: DataNode) {
        if case .hierarchy(let h) = node.kind { addHierarchy(h, table: node.table); return }
        if let ref = node.fieldRef { store.addField(ref) }
    }

    private func toggleUse(_ node: DataNode) {
        guard let v = store.selectedVisual, isUsed(node, usedFields) else { addToVisual(node); return }
        let names: Set<String>
        if case .hierarchy(let h) = node.kind { names = Set(h.levels) } else { names = [node.name] }
        let kind: FieldRef.Kind = { if case .measure = node.kind { return .measure }; return .column }()
        let table = node.table
        func hit(_ f: FieldRef) -> Bool { f.kind == kind && f.table == table && names.contains(f.name) }
        store.updateVisual(v.id, name: "Remove Field") { s in
            for w in s.type.wells { s.setFields(w, s.fields(w).filter { !hit($0) }) }
            s.sort.removeAll { hit($0.field) }
            BuildLogic.clampDrill(&s)
        }
    }

    private func addHierarchy(_ h: Hierarchy, table: String) {
        let refs = h.levels.map { FieldRef.column(table, $0) }
        guard let first = refs.first else { return }
        if let v = store.selectedVisual, let well = v.type.wells.first(where: \.isGrouping) {
            store.updateVisual(v.id, name: "Add Hierarchy") { s in
                let have = Set(s.fields(well).map(\.key))
                s.setFields(well, s.fields(well) + refs.filter { !have.contains($0.key) })
            }
        } else {
            store.addField(first)
            guard refs.count > 1, let id = store.selection.first, let v = store.visual(id),
                  let well = v.type.wells.first(where: { w in w.isGrouping && v.fields(w).contains { $0.key == first.key } }) else { return }
            store.updateVisual(id, name: "Add Hierarchy") { s in s.setFields(well, s.fields(well) + refs.dropFirst()) }
        }
    }
}

/// A single 26-pt row: disclosure, checkbox, glyph, name, badges.
private struct DataRow: View {
    let node: DataNode
    let isOpen: Bool
    let isChecked: Bool
    let search: String
    let isRenaming: Bool
    @Binding var draftName: String
    var renameFocused: FocusState<Bool>.Binding
    let toggleExpand: () -> Void
    let toggleCheck: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let menu: () -> AnyView
    @State private var hovering = false

    private var isField: Bool {
        switch node.kind { case .table, .folder: return false; default: return true }
    }
    private var symbol: String {
        switch node.kind {
        case .table(let t): return FieldGlyph.symbol(table: t)
        case .folder: return FieldGlyph.folder
        case .column(let c), .level(let c, _): return FieldGlyph.symbol(column: c)
        case .measure: return FieldGlyph.measure
        case .hierarchy: return FieldGlyph.hierarchy
        }
    }
    private var badge: (String, String)? {
        switch node.kind {
        case .column(let c) where c.isCalculated: return ("fx", "Calculated column")
        case .column(let c) where c.grouping != nil: return ("grp", "Group")
        case .table(let t) where t.isCalculated: return ("fx", "Calculated table")
        case .table(let t) where t.storageMode != .import: return (t.storageMode == .directQuery ? "DQ" : t.storageMode.rawValue, "Storage mode: \(t.storageMode.rawValue)")
        default: return nil
        }
    }
    private var title: AttributedString {
        var a = AttributedString(node.name)
        if !search.isEmpty, let r = a.range(of: search, options: .caseInsensitive) {
            a[r].foregroundColor = .accentColor
            a[r].font = .system(size: 13, weight: .semibold)
        }
        return a
    }
    private var tooltip: String {
        switch node.kind {
        case .column(let c): return c.description.isEmpty ? "\(c.name) · \(c.dataType.displayName)" : c.description
        case .level(let c, _): return "\(c.name) · \(c.dataType.displayName)"
        case .measure(let m): return m.description.isEmpty ? m.expression : m.description
        case .table(let t): return t.description.isEmpty ? t.name : t.description
        case .hierarchy(let h): return h.levels.joined(separator: " › ")
        case .folder(let f): return f
        }
    }

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Color.clear.frame(width: CGFloat(node.depth) * 14, height: 1)
            if node.isExpandable {
                Button(action: toggleExpand) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(.tertiary)
                        .frame(width: 12, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse \(node.name)" : "Expand \(node.name)")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            if isField {
                Button(action: toggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(isChecked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .frame(width: 16, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isChecked ? "Remove from the selected visual" : "Add to the selected visual")
                .accessibilityLabel(isChecked ? "Remove \(node.name) from visual" : "Add \(node.name) to visual")
            }
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .focused(renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onAppear { renameFocused.wrappedValue = true }
            } else {
                Text(title)
                    .font({ if case .table = node.kind { return Design.Typeface.bodyStrong }; return Design.Typeface.body }())
                    .lineLimit(1).truncationMode(.middle)
                if let badge {
                    Text(badge.0).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).help(badge.1)
                }
                if node.isDimmed {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary).help("Hidden in report view")
                }
                Spacer(minLength: 0)
                if hovering {
                    Menu { menu() } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More options").accessibilityLabel("More options for \(node.name)")
                }
            }
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: 26)
        .opacity(node.isDimmed ? 0.5 : 1)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Design.Palette.fill : .clear).padding(.horizontal, Design.Space.xs))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isField && !isRenaming { toggleExpand() } }
        .help(tooltip)
        .accessibilityElement(children: .contain)
    }
}
