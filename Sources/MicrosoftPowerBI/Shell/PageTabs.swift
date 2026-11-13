import SwiftUI
import FacetCore
import FacetDesign

/// The rules of the page tabs that do not need a view.
enum PageTabsModel {
    static let dragPrefix = "facet-page:"

    static func dragPayload(for id: UUID) -> String { dragPrefix + id.uuidString }
    /// The page a dropped string names, or nil when the drop is something else.
    static func draggedPage(_ payload: String) -> UUID? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(dragPrefix.count)))
    }
    /// Where a page dragged from `from` and dropped on the tab at `onto` should go, or nil for no move.
    static func destination(from: Int, onto: Int, count: Int) -> Int? {
        guard from >= 0, from < count, onto >= 0, onto < count, from != onto else { return nil }
        return onto
    }
    /// A trimmed page name worth committing, or nil when the rename should be dropped.
    static func committedName(_ draft: String, current: String) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == current ? nil : name
    }
    static func canDelete(pageCount: Int) -> Bool { pageCount > 1 }
}

/// Page tabs along the bottom of Report view: add, rename, duplicate, hide, delete, and drag to reorder.
struct PageTabs: View {
    @EnvironmentObject var store: DocumentStore
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var dropTarget: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Design.Space.xxs) {
                    ForEach(Array(store.report.pages.enumerated()), id: \.element.id) { index, page in
                        tab(page, index: index).id(page.id)
                    }
                    IconButton("plus", help: "New page (⌥⌘N)") { AppCommands.run("insert.page", store) }
                }
                .padding(.horizontal, Design.Space.s)
            }
            .onChange(of: store.currentPageID) { _, id in
                withAnimation(Design.Motion.quick) { proxy.scrollTo(id) }
            }
        }
        .frame(height: ShellMetrics.pageTabsHeight)
        .background(Design.Palette.surface)
    }

    @ViewBuilder private func tab(_ page: Page, index: Int) -> some View {
        let selected = page.id == store.currentPageID
        if renaming == page.id {
            TextField("Page name", text: $draftName)
                .textFieldStyle(.plain).font(Design.Typeface.caption).frame(width: 120)
                .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.xs)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).strokeBorder(Color.accentColor))
                .focused($renameFocused)
                .onSubmit { commitRename(page) }
                .onExitCommand { renaming = nil }
                .onChange(of: renameFocused) { _, focused in if !focused, renaming == page.id { commitRename(page) } }
                .onAppear { renameFocused = true }
        } else {
            HStack(spacing: Design.Space.xs) {
                ForEach(badges(page), id: \.self) { Image(systemName: $0).font(.system(size: 9)) }
                Text(page.name).font(selected ? Design.Typeface.captionStrong : Design.Typeface.caption).lineLimit(1)
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .opacity(page.isHidden ? 0.6 : 1)
            .padding(.horizontal, Design.Space.s + Design.Space.xxs).padding(.vertical, Design.Space.xs + 1)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .fill(selected ? Design.Palette.fillStrong : Color.clear))
            .overlay(alignment: .leading) {
                // Where a dragged page will land.
                if dropTarget == page.id { Capsule().fill(Color.accentColor).frame(width: 2).padding(.vertical, Design.Space.xxs) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginRename(page) }
            .onTapGesture { store.goToPage(page.id) }
            .draggable(PageTabsModel.dragPayload(for: page.id))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(PageTabsModel.draggedPage),
                      let from = store.report.pages.firstIndex(where: { $0.id == id }),
                      let to = PageTabsModel.destination(from: from, onto: index, count: store.report.pages.count) else { return false }
                store.movePage(from: from, to: to)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = page.id } else if dropTarget == page.id { dropTarget = nil }
            }
            .contextMenu { menu(page, index: index) }
            .help(help(page))
            .accessibilityLabel("Page \(page.name)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    @ViewBuilder private func menu(_ page: Page, index: Int) -> some View {
        let count = store.report.pages.count
        Button("Rename") { beginRename(page) }
        Button("Duplicate") { store.duplicatePage(page.id) }
        Button(page.isHidden ? "Show Page" : "Hide Page") { change(page, "Hide Page") { $0.isHidden.toggle() } }
        Divider()
        Button(store.report.landingPageID == page.id ? "Clear Landing Page" : "Set as Landing Page") {
            store.mutate("Set Landing Page", invalidates: .layout) { d in
                d.report.landingPageID = d.report.landingPageID == page.id ? nil : page.id
            }
        }
        Button(page.isTooltipPage ? "Use as Normal Page" : "Use as Tooltip Page") {
            change(page, "Change Page Type") { $0.isTooltipPage.toggle(); if $0.isTooltipPage { $0.size = .tooltip } }
        }
        if let settings = AppCommands.command("page.settings") {
            Button(settings.title) { store.goToPage(page.id); AppCommands.run(settings.id, store) }
        }
        Divider()
        Button("Move Left") { store.movePage(from: index, to: index - 1) }.disabled(index <= 0)
        Button("Move Right") { store.movePage(from: index, to: index + 1) }.disabled(index >= count - 1)
        Button("Move to Start") { store.movePage(from: index, to: 0) }.disabled(index <= 0)
        Button("Move to End") { store.movePage(from: index, to: count - 1) }.disabled(index >= count - 1)
        Divider()
        Button("New Page") { store.goToPage(page.id); AppCommands.run("insert.page", store) }
        Button("Delete", role: .destructive) { store.deletePage(page.id) }
            .disabled(!PageTabsModel.canDelete(pageCount: count))
    }

    private func badges(_ page: Page) -> [String] {
        var symbols: [String] = []
        if page.isHidden { symbols.append("eye.slash") }
        if page.isTooltipPage { symbols.append("text.bubble") }
        if page.isDrillthroughPage { symbols.append("arrow.down.right.circle") }
        if page.hasMobileLayout { symbols.append("iphone") }
        if store.report.landingPageID == page.id { symbols.append("house") }
        return symbols
    }
    private func help(_ page: Page) -> String {
        var notes: [String] = []
        if page.isHidden { notes.append("hidden from readers") }
        if page.isTooltipPage { notes.append("tooltip page") }
        if page.isDrillthroughPage { notes.append("drillthrough page") }
        if page.hasMobileLayout { notes.append("has a mobile layout") }
        if store.report.landingPageID == page.id { notes.append("landing page") }
        let detail = notes.isEmpty ? "" : " — " + notes.joined(separator: ", ")
        return "\(page.name)\(detail). Double-click to rename, drag to reorder."
    }

    private func beginRename(_ page: Page) { draftName = page.name; renaming = page.id }
    private func change(_ page: Page, _ name: String, _ body: @escaping (inout Page) -> Void) {
        store.mutate(name, invalidates: .layout) { d in
            if let i = d.report.pages.firstIndex(where: { $0.id == page.id }) { body(&d.report.pages[i]) }
        }
    }
    private func commitRename(_ page: Page) {
        guard renaming == page.id else { return }
        renaming = nil
        guard let name = PageTabsModel.committedName(draftName, current: page.name) else { return }
        change(page, "Rename Page") { $0.name = name }
    }
}
