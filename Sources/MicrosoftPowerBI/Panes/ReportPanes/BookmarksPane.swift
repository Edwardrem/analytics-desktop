import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Model helpers

/// One row group in the Bookmarks pane: a loose bookmark, or a named group with its members.
enum BookmarkEntry: Identifiable {
    case bookmark(Bookmark)
    case group(name: String, members: [Bookmark])

    var id: String {
        switch self {
        case .bookmark(let b): return "b:\(b.id.uuidString)"
        case .group(let name, _): return "g:\(name)"
        }
    }
    var bookmarks: [Bookmark] {
        switch self {
        case .bookmark(let b): return [b]
        case .group(_, let members): return members
        }
    }

    /// Bookmarks in display order: a group sits where its first member is.
    static func entries(_ bookmarks: [Bookmark]) -> [BookmarkEntry] {
        var out: [BookmarkEntry] = []
        var seen: Set<String> = []
        for b in bookmarks {
            if b.group.isEmpty { out.append(.bookmark(b)); continue }
            guard seen.insert(b.group).inserted else { continue }
            out.append(.group(name: b.group, members: bookmarks.filter { $0.group == b.group }))
        }
        return out
    }
    /// Every bookmark in the order the pane shows (and the slideshow plays) them.
    static func displayOrder(_ bookmarks: [Bookmark]) -> [Bookmark] { entries(bookmarks).flatMap(\.bookmarks) }
}

extension DocumentStore {
    func editBookmark(_ id: UUID, name: String = "Change Bookmark", _ body: (inout Bookmark) -> Void) {
        mutate(name, invalidates: .layout) { d in
            guard let i = d.report.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            body(&d.report.bookmarks[i])
        }
    }
    func deleteBookmarks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutate(ids.count == 1 ? "Delete Bookmark" : "Delete Bookmarks", invalidates: .layout) { d in
            d.report.bookmarks.removeAll { ids.contains($0.id) }
        }
        if let active = activeBookmarkID, ids.contains(active) { activeBookmarkID = nil }
    }
    /// Move bookmarks before `target` (nil = to the end), placing them in `group` ("" = no group).
    func moveBookmarks(_ ids: Set<UUID>, before target: UUID?, group: String) {
        guard !ids.isEmpty, target.map({ !ids.contains($0) }) ?? true else { return }
        mutate("Reorder Bookmarks", invalidates: .layout) { d in
            var moving = d.report.bookmarks.filter { ids.contains($0.id) }
            for i in moving.indices { moving[i].group = group }
            var rest = d.report.bookmarks.filter { !ids.contains($0.id) }
            let at = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
            rest.insert(contentsOf: moving, at: at)
            // Keep storage order equal to display order so navigators and the slideshow agree with the pane.
            d.report.bookmarks = BookmarkEntry.displayOrder(rest)
        }
    }
    @discardableResult
    func groupBookmarks(_ ids: Set<UUID>) -> String {
        let name = Set(report.bookmarks.map(\.group)).uniqueName("Group 1")
        mutate("Group Bookmarks", invalidates: .layout) { d in
            for i in d.report.bookmarks.indices where ids.contains(d.report.bookmarks[i].id) { d.report.bookmarks[i].group = name }
            d.report.bookmarks = BookmarkEntry.displayOrder(d.report.bookmarks)
        }
        return name
    }
    func renameBookmarkGroup(_ old: String, to new: String) {
        guard !new.isEmpty, new != old else { return }
        mutate("Rename Bookmark Group", invalidates: .layout) { d in
            for i in d.report.bookmarks.indices where d.report.bookmarks[i].group == old { d.report.bookmarks[i].group = new }
            d.report.bookmarks = BookmarkEntry.displayOrder(d.report.bookmarks)
        }
    }
    func ungroupBookmarks(_ group: String) {
        mutate("Ungroup Bookmarks", invalidates: .layout) { d in
            for i in d.report.bookmarks.indices where d.report.bookmarks[i].group == group { d.report.bookmarks[i].group = "" }
        }
    }
}

// MARK: - Slideshow

/// Plays bookmarks in order. Lives outside the pane so a slideshow keeps going while presenting full screen.
@MainActor
final class BookmarkPlayer: ObservableObject {
    static let intervals: [Double] = [3, 5, 10, 30, 60]

    @Published private(set) var queue: [UUID] = []
    @Published private(set) var index = 0
    @Published var isAutoPlaying = false { didSet { reschedule() } }
    @Published var interval: Double = 5 { didSet { reschedule() } }
    private weak var store: DocumentStore?
    private var timer: Timer?

    init(store: DocumentStore) { self.store = store }

    var isActive: Bool { !queue.isEmpty }
    var currentID: UUID? { queue[safe: index] }
    var canStepBack: Bool { index > 0 }
    var canStepForward: Bool { index < queue.count - 1 }

    /// Start a slideshow over the given bookmarks (in that order), beginning at `startingAt` when it is one of them.
    func start(_ ids: [UUID], startingAt: UUID? = nil) {
        guard !ids.isEmpty else { return }
        queue = ids
        index = startingAt.flatMap { ids.firstIndex(of: $0) } ?? 0
        applyCurrent()
        reschedule()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        queue = []; index = 0
        if isAutoPlaying { isAutoPlaying = false }
    }
    func step(_ delta: Int, wrap: Bool = false) {
        prune()
        guard !queue.isEmpty else { return }
        var next = index + delta
        if wrap { next = ((next % queue.count) + queue.count) % queue.count }
        guard queue.indices.contains(next) else { return }
        index = next
        applyCurrent()
        reschedule()
    }

    /// Drop bookmarks that were deleted while playing.
    private func prune() {
        guard let store else { stop(); return }
        let alive = Set(store.report.bookmarks.map(\.id))
        guard !queue.allSatisfy(alive.contains) else { return }
        let current = currentID
        queue = queue.filter(alive.contains)
        index = current.flatMap { queue.firstIndex(of: $0) } ?? min(index, max(0, queue.count - 1))
        if queue.isEmpty { stop() }
    }
    private func applyCurrent() {
        guard let store, let id = currentID else { return }
        store.view = .report
        store.applyBookmark(id)
    }
    private func reschedule() {
        timer?.invalidate(); timer = nil
        guard isAutoPlaying, isActive else { return }
        let t = Timer(timeInterval: max(1, interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(1, wrap: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Pane

struct BookmarksPane: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var player: BookmarkPlayer
    /// Rows picked in the pane (⌘/⇧-click) for grouping, deleting and dragging together.
    @State private var picked: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var collapsed: Set<String> = []
    @State private var renamingBookmark: UUID?
    @State private var renamingGroup: String?
    @State private var dragging: String?
    @State private var hovered: UUID?

    private var bookmarks: [Bookmark] { store.report.bookmarks }
    private var entries: [BookmarkEntry] { BookmarkEntry.entries(bookmarks) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Bookmarks", detail: bookmarks.isEmpty ? "" : "\(bookmarks.count)") {
                if picked.count > 1 {
                    IconButton("folder.badge.plus", help: "Group selected bookmarks") { groupPicked() }
                }
                IconButton("play", help: "View bookmarks as a slideshow", isOn: player.isActive) {
                    if player.isActive { player.stop() } else { play(BookmarkEntry.displayOrder(bookmarks).map(\.id)) }
                }
                .disabled(bookmarks.isEmpty)
                IconButton("plus", help: "Add a bookmark of the current view") { add() }
            }
            Hairline()
            if player.isActive {
                BookmarkTransport(player: player)
                Hairline()
            }
            if bookmarks.isEmpty {
                EmptyState(systemImage: "bookmark", title: "No bookmarks yet",
                           message: "A bookmark captures the current page with its filters, slicers, sort order, drill state and which visuals are hidden. Add one, then click it any time to return to this view.")
            } else {
                list
            }
        }
        .onChange(of: bookmarks.map(\.id)) { _, ids in picked.formIntersection(ids) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(entries) { entry in
                    switch entry {
                    case .bookmark(let b):
                        row(b, indent: 0)
                    case .group(let name, let members):
                        groupHeader(name, members)
                        if !collapsed.contains(name) {
                            ForEach(members) { row($0, indent: 16) }
                        }
                    }
                }
                // Space below the last row: drop here to move to the end, out of any group.
                Color.clear.frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                    .reorderEnd("end", dragging: $dragging) { source in drop(source, before: nil, group: "") }
                    .onTapGesture { picked = [] }
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.s)
        }
    }

    // MARK: Rows

    private func row(_ b: Bookmark, indent: CGFloat) -> some View {
        let isActive = store.activeBookmarkID == b.id
        let isPicked = picked.contains(b.id)
        return HStack(spacing: Design.Space.s) {
            Image(systemName: isActive ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 16)
            InlineRename(text: b.name, isEditing: renameBinding(b.id)) { name in
                store.editBookmark(b.id, name: "Rename Bookmark") { $0.name = name }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if b.selectedVisualIDs != nil {
                Image(systemName: "square.dashed").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("Applies to selected visuals only")
                    .accessibilityLabel("Applies to selected visuals only")
            }
            if hovered == b.id || isPicked || isActive {
                bookmarkMenu(b)
            }
        }
        .padding(.leading, Design.Space.s + indent).padding(.trailing, Design.Space.xs)
        .frame(height: 28)
        .contentShape(Rectangle())
        .rowHighlight(isActive ? .active : (isPicked ? .selected : (hovered == b.id ? .hover : .none)))
        .onHover { hovered = $0 ? b.id : (hovered == b.id ? nil : hovered) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { renamingBookmark = b.id })
        .onTapGesture { click(b) }
        .contextMenu { bookmarkActions(b) }
        .reorderRow("b:\(b.id.uuidString)", dragging: $dragging) { source in drop(source, before: b.id, group: b.group) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(b.name)
        .accessibilityValue(isActive ? "Active" : "")
        .accessibilityAddTraits(.isButton)
    }

    private func groupHeader(_ name: String, _ members: [Bookmark]) -> some View {
        let expanded = !collapsed.contains(name)
        return HStack(spacing: Design.Space.xs) {
            DisclosureChevron(expanded: expanded, label: name) { toggleCollapsed(name) }
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            InlineRename(text: name, isEditing: Binding(
                get: { renamingGroup == name }, set: { if !$0, renamingGroup == name { renamingGroup = nil } }
            ), font: Design.Typeface.bodyStrong) { new in
                let unique = Set(bookmarks.map(\.group)).subtracting([name]).uniqueName(new)
                if collapsed.remove(name) != nil { collapsed.insert(unique) }
                store.renameBookmarkGroup(name, to: unique)
            }
            Text("\(members.count)").font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit()
            Spacer(minLength: 0)
            Menu {
                groupActions(name, members)
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Group options").accessibilityLabel("Options for group \(name)")
        }
        .padding(.leading, Design.Space.xxs).padding(.trailing, Design.Space.xs)
        .frame(height: 28)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { renamingGroup = name })
        .onTapGesture { picked = Set(members.map(\.id)); anchor = members.first?.id }
        .contextMenu { groupActions(name, members) }
        // Dropping on a group's header adds the bookmark to the top of that group.
        .reorderRow("g:\(name)", dragging: $dragging, canDrag: false) { source in
            drop(source, before: members.first?.id, group: name)
        }
    }

    // MARK: Menus

    private func bookmarkMenu(_ b: Bookmark) -> some View {
        Menu {
            bookmarkActions(b)
        } label: {
            Image(systemName: "ellipsis").frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Bookmark options").accessibilityLabel("Options for \(b.name)")
    }

    @ViewBuilder
    private func bookmarkActions(_ b: Bookmark) -> some View {
        Button("Update") {
            store.updateBookmark(b.id)
            store.status = StatusMessage(kind: .success, text: "“\(b.name)” now captures the current view.")
        }
        Button("Rename") { renamingBookmark = b.id }
        Button("Play from Here") { play(BookmarkEntry.displayOrder(bookmarks).map(\.id), from: b.id) }
        Divider()
        Toggle("Data", isOn: flag(b, \.appliesData))
        Toggle("Display", isOn: flag(b, \.appliesDisplay))
        Toggle("Current page", isOn: flag(b, \.appliesCurrentPage))
        Divider()
        Toggle("All visuals", isOn: Binding(get: { b.selectedVisualIDs == nil }, set: { on in
            if on { store.editBookmark(b.id) { $0.selectedVisualIDs = nil } }
        }))
        Toggle("Selected visuals", isOn: Binding(get: { b.selectedVisualIDs != nil }, set: { on in
            if !on { store.editBookmark(b.id) { $0.selectedVisualIDs = nil }; return }
            let ids = store.currentPage.visuals.map(\.id).filter(store.selection.contains)
            guard !ids.isEmpty else {
                store.status = StatusMessage(kind: .info, text: "Select the visuals this bookmark should affect on the canvas first.")
                return
            }
            store.editBookmark(b.id) { $0.selectedVisualIDs = ids }
        }))
        Divider()
        if picked.count > 1, picked.contains(b.id) {
            Button("Group Selected") { groupPicked() }
        }
        if !b.group.isEmpty {
            Button("Remove from Group") { store.moveBookmarks([b.id], before: nil, group: "") }
        }
        Button(picked.count > 1 && picked.contains(b.id) ? "Delete \(picked.count) Bookmarks" : "Delete", role: .destructive) {
            store.deleteBookmarks(picked.contains(b.id) ? picked : [b.id])
        }
    }

    @ViewBuilder
    private func groupActions(_ name: String, _ members: [Bookmark]) -> some View {
        Button("Play Group") { play(members.map(\.id)) }
        Button("Rename") { renamingGroup = name }
        Divider()
        Button("Ungroup") { collapsed.remove(name); store.ungroupBookmarks(name) }
        Button("Delete Group and Bookmarks", role: .destructive) { store.deleteBookmarks(Set(members.map(\.id))) }
    }

    // MARK: Actions

    private func flag(_ b: Bookmark, _ keyPath: WritableKeyPath<Bookmark, Bool>) -> Binding<Bool> {
        Binding(get: { b[keyPath: keyPath] }, set: { value in store.editBookmark(b.id) { $0[keyPath: keyPath] = value } })
    }
    private func renameBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { renamingBookmark == id }, set: { if !$0, renamingBookmark == id { renamingBookmark = nil } })
    }
    private func toggleCollapsed(_ name: String) {
        withAnimation(Design.Motion.quick) {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        }
    }
    private func add() {
        let id = store.addBookmark()
        store.activeBookmarkID = id
        picked = [id]; anchor = id
        renamingBookmark = id
    }
    private func click(_ b: Bookmark) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if picked.contains(b.id) { picked.remove(b.id) } else { picked.insert(b.id) }
            anchor = b.id
        } else if flags.contains(.shift), let anchor {
            let order = BookmarkEntry.displayOrder(bookmarks).map(\.id)
            if let a = order.firstIndex(of: anchor), let z = order.firstIndex(of: b.id) {
                picked = Set(order[min(a, z)...max(a, z)])
            }
        } else {
            picked = [b.id]; anchor = b.id
            store.view = .report
            store.applyBookmark(b.id)
        }
    }
    private func groupPicked() {
        let name = store.groupBookmarks(picked)
        collapsed.remove(name)
        renamingGroup = name
    }
    private func play(_ ids: [UUID], from start: UUID? = nil) {
        player.start(ids, startingAt: start ?? store.activeBookmarkID)
    }
    private func drop(_ source: String, before target: UUID?, group: String) {
        guard source.hasPrefix("b:"), let id = UUID(uuidString: String(source.dropFirst(2))) else { return }
        let moving: Set<UUID> = picked.contains(id) ? picked : [id]
        store.moveBookmarks(moving, before: target, group: group)
        collapsed.remove(group)
    }
}

/// Previous / next / auto-play controls shown while a bookmark slideshow is running.
struct BookmarkTransport: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var player: BookmarkPlayer

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            IconButton("chevron.left", help: "Previous bookmark") { player.step(-1) }
                .disabled(!player.canStepBack)
            IconButton("chevron.right", help: "Next bookmark") { player.step(1) }
                .disabled(!player.canStepForward)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Design.Typeface.bodyStrong).lineLimit(1).truncationMode(.middle)
                Text("\(player.index + 1) of \(player.queue.count)")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.leading, Design.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Toggle("Advance automatically", isOn: $player.isAutoPlaying)
                Divider()
                Picker("Every", selection: $player.interval) {
                    ForEach(BookmarkPlayer.intervals, id: \.self) { s in
                        Text(s >= 60 ? "\(Int(s / 60)) minute" : "\(Int(s)) seconds").tag(s)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: player.isAutoPlaying ? "pause.fill" : "timer")
                    .foregroundStyle(player.isAutoPlaying ? Color.accentColor : .primary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Auto-play").accessibilityLabel("Auto-play options")
            IconButton("play.rectangle", help: "Present full screen") {
                store.selection = []
                store.presenting = true
            }
            Button("Done") { player.stop() }
                .buttonStyle(.borderless).controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
                .help("End the slideshow (Esc)")
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: 44)
        .background(Design.Palette.fill)
    }

    private var title: String {
        player.currentID.flatMap { id in store.report.bookmarks.first { $0.id == id }?.name } ?? "Bookmark"
    }
}
