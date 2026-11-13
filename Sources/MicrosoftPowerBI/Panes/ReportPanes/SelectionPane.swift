import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Model helpers

/// One row group in the layer list: a loose visual, or a named group with its members (top layer first).
enum LayerEntry: Identifiable {
    case visual(VisualSpec)
    case group(id: UUID, name: String, members: [VisualSpec])

    var id: UUID {
        switch self {
        case .visual(let v): return v.id
        case .group(let id, _, _): return id
        }
    }
    var visuals: [VisualSpec] {
        switch self {
        case .visual(let v): return [v]
        case .group(_, _, let members): return members
        }
    }

    /// The page's visuals, top layer first; a group sits where its topmost member is.
    static func entries(_ page: Page) -> [LayerEntry] {
        let ordered = page.visuals.enumerated()
            .sorted { $0.element.zIndex != $1.element.zIndex ? $0.element.zIndex > $1.element.zIndex : $0.offset > $1.offset }
            .map(\.element)
        var out: [LayerEntry] = []
        var seen: Set<UUID> = []
        for v in ordered {
            guard let g = v.groupID else { out.append(.visual(v)); continue }
            guard seen.insert(g).inserted else { continue }
            out.append(.group(id: g, name: page.groups[g] ?? "Group", members: ordered.filter { $0.groupID == g }))
        }
        return out
    }
    static func displayOrder(_ page: Page) -> [VisualSpec] { entries(page).flatMap(\.visuals) }
}

extension DocumentStore {
    /// Edit visuals on the current page in one undo step.
    func editVisuals(_ ids: Set<UUID>, name: String, _ body: (inout VisualSpec) -> Void) {
        guard !ids.isEmpty else { return }
        updatePage(name: name) { p in
            for i in p.visuals.indices where ids.contains(p.visuals[i].id) { body(&p.visuals[i]) }
        }
    }
    /// Move layers before `target` in the layer list (nil = to the bottom), into `group` (nil = no group).
    func moveLayers(_ ids: Set<UUID>, before target: UUID?, group: UUID?) {
        guard !ids.isEmpty, target.map({ !ids.contains($0) }) ?? true else { return }
        updatePage(name: "Change Layer Order") { p in
            var order = LayerEntry.displayOrder(p).map(\.id)
            let moving = order.filter(ids.contains)
            order.removeAll(where: ids.contains)
            let at = target.flatMap { order.firstIndex(of: $0) } ?? order.count
            order.insert(contentsOf: moving, at: at)
            let z = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, order.count - 1 - $0) })
            for i in p.visuals.indices {
                p.visuals[i].zIndex = z[p.visuals[i].id] ?? 0
                if ids.contains(p.visuals[i].id) { p.visuals[i].groupID = group }
            }
            let used = Set(p.visuals.compactMap(\.groupID))
            p.groups = p.groups.filter { used.contains($0.key) }
        }
    }
    /// Take visuals out of their group without changing their layer.
    func removeFromGroup(_ ids: Set<UUID>) {
        updatePage(name: "Remove from Group") { p in
            for i in p.visuals.indices where ids.contains(p.visuals[i].id) { p.visuals[i].groupID = nil }
            let used = Set(p.visuals.compactMap(\.groupID))
            p.groups = p.groups.filter { used.contains($0.key) }
        }
    }
    func ungroup(_ group: UUID) {
        updatePage(name: "Ungroup") { p in
            for i in p.visuals.indices where p.visuals[i].groupID == group { p.visuals[i].groupID = nil }
            p.groups[group] = nil
        }
    }
    /// Visuals in keyboard order; skipped ones (tab order −1) come last.
    var tabOrderedVisuals: [VisualSpec] {
        currentPage.visuals.enumerated().sorted { a, b in
            let sa = a.element.tabOrder < 0, sb = b.element.tabOrder < 0
            if sa != sb { return sb }
            if a.element.tabOrder != b.element.tabOrder { return a.element.tabOrder < b.element.tabOrder }
            return a.offset < b.offset
        }.map(\.element)
    }
    /// Renumber the tab order from a list of visual ids; skipped visuals keep −1.
    func setTabOrder(_ ordered: [UUID], name: String = "Change Tab Order") {
        updatePage(name: name) { p in
            let skipped = Set(p.visuals.filter { $0.tabOrder < 0 }.map(\.id))
            var n = 0
            var rank: [UUID: Int] = [:]
            for id in ordered where !skipped.contains(id) { rank[id] = n; n += 1 }
            for i in p.visuals.indices {
                let id = p.visuals[i].id
                if skipped.contains(id) { continue }
                if let r = rank[id] { p.visuals[i].tabOrder = r } else { p.visuals[i].tabOrder = n; n += 1 }
            }
        }
    }
    func setTabSkipped(_ id: UUID, _ skipped: Bool) {
        let order = tabOrderedVisuals.map(\.id)
        updatePage(name: skipped ? "Skip in Tab Order" : "Include in Tab Order") { p in
            var n = 0
            for vid in order {
                guard let i = p.visuals.firstIndex(where: { $0.id == vid }) else { continue }
                let skip = vid == id ? skipped : p.visuals[i].tabOrder < 0
                if skip { p.visuals[i].tabOrder = -1 } else { p.visuals[i].tabOrder = n; n += 1 }
            }
        }
    }

    /// Place a visual on the phone canvas, stacked under what is already there.
    func addToMobileLayout(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let phone = PageSize.phone
        updatePage(name: ids.count == 1 ? "Add to Mobile Layout" : "Add All to Mobile Layout") { p in
            let margin = 12.0
            var y = (p.visuals.compactMap { $0.mobileFrame.map { $0.y + $0.height } }.max() ?? 0) + margin
            for id in ids {
                guard let i = p.visuals.firstIndex(where: { $0.id == id }), p.visuals[i].mobileFrame == nil else { continue }
                let f = p.visuals[i].frame
                let width = phone.width - margin * 2
                var height = min(300, max(60, f.height * width / max(1, f.width)))
                let room = phone.height - margin - y
                if room >= 60 { height = min(height, room) } else { y = phone.height - margin - height }
                p.visuals[i].mobileFrame = Frame(x: margin, y: max(margin, y), width: width, height: height)
                y += height + margin
            }
            p.hasMobileLayout = true
        }
    }
    func removeFromMobileLayout(_ ids: [UUID]) {
        let set = Set(ids)
        updatePage(name: "Remove from Mobile Layout") { p in
            for i in p.visuals.indices where set.contains(p.visuals[i].id) { p.visuals[i].mobileFrame = nil }
            p.hasMobileLayout = p.visuals.contains { $0.mobileFrame != nil }
        }
        selection.subtract(set)
    }
}

// MARK: - Pane

struct SelectionPane: View {
    enum Tab: String { case layers, tabOrder, mobile }

    @EnvironmentObject var store: DocumentStore
    @State private var tab: Tab = .layers
    @State private var collapsed: Set<UUID> = []
    @State private var renaming: UUID?
    @State private var anchor: UUID?
    @State private var dragging: String?
    @State private var hovered: UUID?

    private var page: Page { store.currentPage }
    private var activeTab: Tab { tab == .mobile && !store.mobileLayout ? .layers : tab }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Selection", detail: page.visuals.isEmpty ? "" : "\(page.visuals.count)") {
                if activeTab == .layers {
                    IconButton("square.2.layers.3d.top.filled", help: "Bring forward") { store.reorder(.forward) }
                        .disabled(store.selection.isEmpty)
                    IconButton("square.2.layers.3d.bottom.filled", help: "Send backward") { store.reorder(.backward) }
                        .disabled(store.selection.isEmpty)
                }
            }
            Picker("View", selection: Binding(get: { activeTab }, set: { tab = $0 })) {
                Text("Layers").tag(Tab.layers)
                Text("Tab order").tag(Tab.tabOrder)
                if store.mobileLayout { Text("Mobile").tag(Tab.mobile) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.s)
            Hairline()
            if page.visuals.isEmpty {
                EmptyState(systemImage: "square.3.layers.3d", title: "Nothing on this page",
                           message: "Visuals, shapes, text boxes and buttons appear here, front to back, so you can name, hide, lock and reorder them.")
            } else {
                switch activeTab {
                case .layers: layers
                case .tabOrder: tabOrder
                case .mobile: mobile
                }
            }
        }
    }

    // MARK: Layers

    private var layers: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.m) {
                Button("Show all") { store.editVisuals(Set(page.visuals.map(\.id)), name: "Show All") { $0.isHidden = false } }
                    .disabled(!page.visuals.contains { $0.isHidden })
                Button("Hide all") { store.editVisuals(Set(page.visuals.map(\.id)), name: "Hide All") { $0.isHidden = true } }
                    .disabled(page.visuals.allSatisfy(\.isHidden))
                Spacer()
            }
            .buttonStyle(.link).font(Design.Typeface.caption)
            .padding(.horizontal, Design.Space.m).frame(height: 30)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(LayerEntry.entries(page)) { entry in
                        switch entry {
                        case .visual(let v):
                            layerRow(v, indent: 0)
                        case .group(let id, let name, let members):
                            groupRow(id, name, members)
                            if !collapsed.contains(id) {
                                ForEach(members) { layerRow($0, indent: 16) }
                            }
                        }
                    }
                    Color.clear.frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                        .reorderEnd("end", dragging: $dragging) { drop($0, before: nil, group: nil) }
                        .onTapGesture { store.selection = [] }
                }
                .padding(.horizontal, Design.Space.s).padding(.bottom, Design.Space.s)
            }
        }
    }

    private func layerRow(_ v: VisualSpec, indent: CGFloat) -> some View {
        let selected = store.selection.contains(v.id)
        return HStack(spacing: Design.Space.xs) {
            Image(systemName: VisualCatalog.symbol(for: v.type))
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18)
            InlineRename(text: v.name, isEditing: renameBinding(v.id)) { name in
                store.updateVisual(v.id, name: "Rename Visual", invalidates: .layout) { $0.name = name }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(v.isHidden ? 0.45 : 1)
            if v.isLocked || hovered == v.id {
                rowToggle(v.isLocked ? "lock.fill" : "lock.open", on: v.isLocked,
                          help: v.isLocked ? "Unlock \(v.name)" : "Lock \(v.name)") {
                    store.updateVisual(v.id, name: v.isLocked ? "Unlock Visual" : "Lock Visual", invalidates: .layout) { $0.isLocked.toggle() }
                }
            }
            rowToggle(v.isHidden ? "eye.slash" : "eye", on: v.isHidden,
                      help: v.isHidden ? "Show \(v.name)" : "Hide \(v.name)") {
                store.updateVisual(v.id, name: v.isHidden ? "Show Visual" : "Hide Visual", invalidates: .layout) { $0.isHidden.toggle() }
            }
        }
        .padding(.leading, Design.Space.s + indent).padding(.trailing, Design.Space.xs)
        .frame(height: 28)
        .contentShape(Rectangle())
        .rowHighlight(selected ? .active : (hovered == v.id ? .hover : .none))
        .onHover { hovered = $0 ? v.id : (hovered == v.id ? nil : hovered) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = v.id })
        .onTapGesture { click(v.id, order: visibleOrder) }
        .contextMenu {
            Button("Rename") { renaming = v.id }
            Divider()
            Button("Bring to Front") { select(v.id); store.reorder(.front) }
            Button("Send to Back") { select(v.id); store.reorder(.back) }
            if store.selection.count > 1, selected { Button("Group") { store.groupSelection() } }
            if v.groupID != nil {
                Button("Remove from Group") { store.removeFromGroup([v.id]) }
            }
            Divider()
            Button("Delete", role: .destructive) { select(v.id); store.deleteSelection() }
        }
        .reorderRow("v:\(v.id.uuidString)", dragging: $dragging) { drop($0, before: v.id, group: v.groupID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(v.name), \(v.type.displayName)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func groupRow(_ id: UUID, _ name: String, _ members: [VisualSpec]) -> some View {
        let ids = Set(members.map(\.id))
        let allSelected = !ids.isEmpty && ids.isSubset(of: store.selection)
        let allHidden = members.allSatisfy(\.isHidden), allLocked = members.allSatisfy(\.isLocked)
        return HStack(spacing: Design.Space.xs) {
            DisclosureChevron(expanded: !collapsed.contains(id), label: name) {
                withAnimation(Design.Motion.quick) {
                    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                }
            }
            Image(systemName: "square.on.square.dashed").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18)
            InlineRename(text: name, isEditing: renameBinding(id), font: Design.Typeface.bodyStrong) { new in
                store.updatePage(name: "Rename Group") { $0.groups[id] = new }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(allHidden ? 0.45 : 1)
            if allLocked || hovered == id {
                rowToggle(allLocked ? "lock.fill" : "lock.open", on: allLocked, help: allLocked ? "Unlock group" : "Lock group") {
                    store.editVisuals(ids, name: allLocked ? "Unlock Group" : "Lock Group") { $0.isLocked = !allLocked }
                }
            }
            rowToggle(allHidden ? "eye.slash" : "eye", on: allHidden, help: allHidden ? "Show group" : "Hide group") {
                store.editVisuals(ids, name: allHidden ? "Show Group" : "Hide Group") { $0.isHidden = !allHidden }
            }
        }
        .padding(.leading, Design.Space.xxs).padding(.trailing, Design.Space.xs)
        .frame(height: 28)
        .contentShape(Rectangle())
        .rowHighlight(allSelected ? .selected : (hovered == id ? .hover : .none))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = id })
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { store.selection.formUnion(ids) }
            else { store.selection = ids }
            anchor = members.first?.id
        }
        .contextMenu {
            Button("Rename") { renaming = id }
            Button("Ungroup") { store.ungroup(id) }
        }
        // Dropping on a group's header adds the visual to the top of that group.
        .reorderRow("g:\(id.uuidString)", dragging: $dragging, canDrag: false) { drop($0, before: members.first?.id, group: id) }
    }

    private func rowToggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    // MARK: Tab order

    private var tabOrder: some View {
        let ordered = store.tabOrderedVisuals
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                PaneNote("The order keyboard and screen-reader users move through this page. Skip decorative elements.")
                    .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.s)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, v in
                    tabRow(v, position: index, ordered: ordered)
                }
                Color.clear.frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                    .reorderEnd("end", dragging: $dragging) { dropTab($0, before: nil) }
            }
            .padding(.horizontal, Design.Space.s).padding(.bottom, Design.Space.s)
        }
    }

    private func tabRow(_ v: VisualSpec, position: Int, ordered: [VisualSpec]) -> some View {
        let skipped = v.tabOrder < 0
        let selected = store.selection.contains(v.id)
        let included = ordered.filter { $0.tabOrder >= 0 }.map(\.id)
        return HStack(spacing: Design.Space.xs) {
            Text(skipped ? "–" : "\(position + 1)")
                .font(Design.Typeface.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Image(systemName: VisualCatalog.symbol(for: v.type))
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18)
            Text(v.name).font(Design.Typeface.body).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !skipped, hovered == v.id || selected, let i = included.firstIndex(of: v.id) {
                rowToggle("chevron.up", on: false, help: "Move \(v.name) earlier") { moveTab(v.id, in: included, from: i, by: -1) }
                    .disabled(i == 0)
                rowToggle("chevron.down", on: false, help: "Move \(v.name) later") { moveTab(v.id, in: included, from: i, by: 1) }
                    .disabled(i == included.count - 1)
            }
            Toggle("Skip", isOn: Binding(get: { skipped }, set: { store.setTabSkipped(v.id, $0) }))
                .toggleStyle(.checkbox).controlSize(.small).font(Design.Typeface.caption)
                .help("Leave \(v.name) out of the tab order")
        }
        .opacity(skipped ? 0.55 : 1)
        .padding(.horizontal, Design.Space.xs)
        .frame(height: 28)
        .contentShape(Rectangle())
        .rowHighlight(selected ? .active : (hovered == v.id ? .hover : .none))
        .onHover { hovered = $0 ? v.id : (hovered == v.id ? nil : hovered) }
        .onTapGesture { click(v.id, order: ordered.map(\.id)) }
        .reorderRow("t:\(v.id.uuidString)", dragging: $dragging, canDrag: !skipped) { dropTab($0, before: skipped ? nil : v.id) }
    }

    // MARK: Mobile layout

    private var mobile: some View {
        let ordered = LayerEntry.displayOrder(page)
        let placed = ordered.filter { $0.mobileFrame != nil }
        let unplaced = ordered.filter { $0.mobileFrame == nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                HStack {
                    SectionLabel("Not on the phone layout")
                    if unplaced.count > 1 {
                        Button("Add all") { store.addToMobileLayout(unplaced.reversed().map(\.id)) }
                            .buttonStyle(.link).font(Design.Typeface.caption)
                    }
                }
                if unplaced.isEmpty {
                    PaneNote("Every visual on this page is on the phone layout.")
                }
                ForEach(unplaced) { v in
                    mobileRow(v, action: "Add", help: "Add \(v.name) to the phone layout") {
                        store.addToMobileLayout([v.id])
                        store.selection = [v.id]
                    }
                }
                if !placed.isEmpty {
                    SectionLabel("On the phone layout").padding(.top, Design.Space.s)
                    ForEach(placed) { v in
                        mobileRow(v, action: "Remove", help: "Remove \(v.name) from the phone layout") {
                            store.removeFromMobileLayout([v.id])
                        }
                    }
                }
            }
            .padding(Design.Space.m)
        }
    }

    private func mobileRow(_ v: VisualSpec, action: String, help: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: VisualCatalog.symbol(for: v.type))
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18)
            Text(v.name).font(Design.Typeface.body).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
                .controlSize(.small).help(help).accessibilityLabel(help)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { if v.mobileFrame != nil { store.selection = [v.id] } }
    }

    // MARK: Actions

    /// Visual ids in the order the layer list currently shows them (collapsed groups left out).
    private var visibleOrder: [UUID] {
        LayerEntry.entries(page).flatMap { entry -> [UUID] in
            if case .group(let id, _, _) = entry, collapsed.contains(id) { return [] }
            return entry.visuals.map(\.id)
        }
    }
    private func renameBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { renaming == id }, set: { if !$0, renaming == id { renaming = nil } })
    }
    private func select(_ id: UUID) {
        if !store.selection.contains(id) { store.selection = [id] }
    }
    private func click(_ id: UUID, order: [UUID]) {
        let flags = NSEvent.modifierFlags
        store.view = .report
        if flags.contains(.command) {
            if store.selection.contains(id) { store.selection.remove(id) } else { store.selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let a = order.firstIndex(of: anchor), let z = order.firstIndex(of: id) {
            store.selection = Set(order[min(a, z)...max(a, z)])
        } else {
            store.selection = [id]
            anchor = id
        }
    }
    private func drop(_ source: String, before target: UUID?, group: UUID?) {
        guard source.hasPrefix("v:"), let id = UUID(uuidString: String(source.dropFirst(2))) else { return }
        let moving: Set<UUID> = store.selection.contains(id) ? store.selection : [id]
        store.moveLayers(moving, before: target, group: group)
        if let group { collapsed.remove(group) }
    }
    private func dropTab(_ source: String, before target: UUID?) {
        guard source.hasPrefix("t:"), let id = UUID(uuidString: String(source.dropFirst(2))), id != target else { return }
        var order = store.tabOrderedVisuals.filter { $0.tabOrder >= 0 }.map(\.id)
        order.removeAll { $0 == id }
        let at = target.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(id, at: at)
        store.setTabOrder(order)
    }
    private func moveTab(_ id: UUID, in included: [UUID], from index: Int, by delta: Int) {
        var order = included
        let to = index + delta
        guard order.indices.contains(to) else { return }
        order.swapAt(index, to)
        store.setTabOrder(order)
    }
}
