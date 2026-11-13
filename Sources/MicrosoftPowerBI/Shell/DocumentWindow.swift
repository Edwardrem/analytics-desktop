import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// One document window: view rail · workspace · inspector, under a single quiet toolbar.
struct DocumentWindow: View {
    let handle: DocumentHandle
    @StateObject private var store: DocumentStore
    @Environment(\.openWindow) private var openWindow
    @State private var paletteVisible = false

    init(handle: DocumentHandle) {
        self.handle = handle
        _store = StateObject(wrappedValue: StoreRegistry.shared.store(for: handle))
    }

    var body: some View {
        HStack(spacing: 0) {
            ViewRail()
            Hairline(vertical: true)
            VStack(spacing: 0) {
                workspace
                if store.view == .report && !store.presenting {
                    Hairline()
                    PageTabs()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.inspectorVisible && showsInspector && !store.presenting {
                Hairline(vertical: true)
                Inspector().frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(Design.Motion.quick, value: store.inspectorVisible)
        .frame(minWidth: 980, minHeight: 620)
        .background(Design.Palette.surface)
        .toolbar { MainToolbar(store: store, showPalette: { paletteVisible = true }) }
        .navigationTitle(store.displayName)
        .navigationSubtitle(subtitle)
        .environmentObject(store)
        .focusedSceneObject(store)
        .overlay(alignment: .bottom) { StatusToast().environmentObject(store) }
        .overlay { if paletteVisible { CommandPalette(isPresented: $paletteVisible).environmentObject(store) } }
        .overlay { overlays }
        .sheet(item: $store.sheet) { $0.view }
        .background(WindowCloseGuard(store: store, handleID: handle.id))
        .onReceive(NotificationCenter.default.publisher(for: .facetShowPalette)) { _ in
            if NSApp.keyWindow != nil { paletteVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .facetOpenQueryEditor)) { note in
            if (note.object as? DocumentStore) === store { openWindow(id: "query-editor", value: handle.id) }
        }
        .onAppear {
            FileOperations.openInNewWindow = { url in openWindow(id: "document", value: DocumentHandle(url: url)) }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if store.isDirty { parts.append("Edited") }
        if !store.viewAsRoles.isEmpty { parts.append("Viewing as \(store.viewAsRoles.joined(separator: ", "))") }
        if store.visualsPaused { parts.append("Visuals paused") }
        return parts.joined(separator: " · ")
    }
    private var showsInspector: Bool { store.view == .report || store.view == .table || store.view == .model }

    @ViewBuilder private var workspace: some View {
        switch store.view {
        case .report:
            if store.presenting { PresentationView() } else { ReportCanvas() }
        default:
            Features.workspace(store.view, store).environmentObject(store)
        }
    }

    @ViewBuilder private var overlays: some View {
        if let id = store.focusVisualID, let spec = store.visual(id) {
            FocusOverlay(spec: spec).environmentObject(store)
        } else if let id = store.showAsTableID, let spec = store.visual(id) {
            ShowAsTableOverlay(spec: spec).environmentObject(store)
        }
        if let p = store.refreshProgress {
            VStack(spacing: Design.Space.m) {
                ProgressView(value: p.fraction).frame(width: 260)
                Text(p.query.isEmpty ? p.message : "\(p.query) — \(p.message)").font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(Design.Space.xl)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
        }
    }
}

extension Notification.Name {
    static let facetOpenQueryEditor = Notification.Name("facet.openQueryEditor")
}

/// Slim vertical switcher between the five views.
struct ViewRail: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        VStack(spacing: Design.Space.xs) {
            ForEach(WorkspaceView.allCases) { v in
                Button { store.view = v; store.presenting = false } label: {
                    VStack(spacing: 3) {
                        Image(systemName: v.symbol).font(.system(size: 15, weight: store.view == v ? .medium : .regular))
                        Text(v == .dax ? "DAX" : v.title).font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(store.view == v ? Color.accentColor : .secondary)
                    .frame(width: 48, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(store.view == v ? Color.accentColor.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(v.title) view")
                .accessibilityLabel("\(v.title) view")
                .accessibilityAddTraits(store.view == v ? .isSelected : [])
            }
            Spacer()
            if !store.modelErrors.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Palette.caution)
                    .help(store.modelErrors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                    .padding(.bottom, Design.Space.s)
            }
        }
        .padding(.vertical, Design.Space.s)
        .frame(width: 60)
        .background(Design.Palette.surface)
    }
}

/// The toolbar: a handful of verbs, grouped. Everything else lives in menus and ⌘K.
struct MainToolbar: ToolbarContent {
    @ObservedObject var store: DocumentStore
    let showPalette: () -> Void
    @State private var galleryVisible = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Button("Get Data…") { AppCommands.run("data.get", store) }
                Button("Enter Data…") { AppCommands.run("data.enter", store) }
                Button("Recent Sources…") { AppCommands.run("data.recent", store) }
                Divider()
                Button("OneLake Catalog…") { AppCommands.run("account.catalog", store) }
                Button("Load Sample Data") { AppCommands.run("data.sample", store) }
            } label: { Label("Get Data", systemImage: "cylinder.split.1x2") } primaryAction: { AppCommands.run("data.get", store) }
            .help("Get data")
            Button { AppCommands.run("data.transform", store) } label: { Label("Transform", systemImage: "wand.and.stars") }
                .help("Transform data in the Power Query Editor")
            Button { AppCommands.run("data.refresh", store) } label: { Label("Refresh", systemImage: "arrow.triangle.2.circlepath") }
                .help("Refresh data")
        }
        ToolbarItemGroup(placement: .principal) {
            if store.view == .report {
                Button { galleryVisible.toggle() } label: { Label("Visual", systemImage: "chart.bar.xaxis") }
                    .help("Add a visual")
                    .popover(isPresented: $galleryVisible, arrowEdge: .bottom) {
                        VisualGallery { type in
                            galleryVisible = false
                            AppCommands.run("insert.visual.\(type.rawValue)", store)
                        }
                    }
                Button { AppCommands.run("insert.textBox", store) } label: { Label("Text", systemImage: "textformat") }.help("Text box")
                Menu {
                    Button("Button") { AppCommands.run("insert.button", store) }
                    Button("Shape") { AppCommands.run("insert.shape", store) }
                    Button("Image…") { AppCommands.run("insert.image", store) }
                    Divider()
                    Button("Page Navigator") { AppCommands.run("insert.pageNavigator", store) }
                    Button("Bookmark Navigator") { AppCommands.run("insert.bookmarkNavigator", store) }
                } label: { Label("Elements", systemImage: "square.on.circle") }.help("Buttons, shapes and images")
            }
            Menu {
                Button("New Measure") { AppCommands.run("model.newMeasure", store) }
                Button("Quick Measure…") { AppCommands.run("model.quickMeasure", store) }
                Button("New Column") { AppCommands.run("model.newColumn", store) }
                Button("New Table") { AppCommands.run("model.newTable", store) }
                Divider()
                Button("New Parameter…") { AppCommands.run("model.newParameter", store) }
                Button("Manage Relationships…") { AppCommands.run("model.relationships", store) }
                Button("Manage Roles…") { AppCommands.run("model.roles", store) }
            } label: { Label("Calculate", systemImage: "function") } primaryAction: { AppCommands.run("model.newMeasure", store) }
            .help("New measure")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.view == .report {
                Button { AppCommands.run("optimize.pause", store) } label: {
                    Label("Pause", systemImage: store.visualsPaused ? "play.fill" : "pause")
                }.help(store.visualsPaused ? "Resume visuals" : "Pause visuals while you build")
                Button { AppCommands.run("view.present", store) } label: { Label("Present", systemImage: "play.rectangle") }
                    .help("Present this report")
            }
            Button { store.inspector = .assistant; store.inspectorVisible = true } label: { Label("Assistant", systemImage: "sparkles") }
                .help("Ask the assistant")
            Button(action: showPalette) { Label("Commands", systemImage: "command") }.help("Command palette (⌘K)")
            Features.toolbarAccessory(store)
            Button { AppCommands.run("view.inspector", store) } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector")
        }
    }
}

/// Searchable grid of every visual type.
struct VisualGallery: View {
    let choose: (VisualType) -> Void
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            TextField("Search visuals", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    ForEach(VisualCatalog.groups, id: \.name) { group in
                        let types = group.types.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
                        if !types.isEmpty {
                            VStack(alignment: .leading, spacing: Design.Space.s) {
                                SectionLabel(group.name)
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                                    ForEach(types, id: \.self) { t in GalleryTile(type: t) { choose(t) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Design.Space.l)
        .frame(width: 440, height: 520)
    }
}

private struct GalleryTile: View {
    let type: VisualType
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: VisualCatalog.symbol(for: type)).font(.system(size: 18, weight: .light)).frame(height: 22)
                Text(type.displayName.replacingOccurrences(of: " chart", with: "")).font(.system(size: 9.5)).lineLimit(2)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 62)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Design.Palette.fillStrong : Design.Palette.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(type.displayName)
    }
}

/// Page tabs along the bottom, with zoom controls at the trailing edge.
struct PageTabs: View {
    @EnvironmentObject var store: DocumentStore
    @State private var renaming: UUID?
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.report.pages.enumerated()), id: \.element.id) { index, page in
                        tab(page, index: index)
                    }
                    IconButton("plus", help: "New page") { store.addPage() }
                }
                .padding(.horizontal, Design.Space.s)
            }
            Spacer(minLength: Design.Space.m)
            if store.mobileLayout { Chip("Mobile layout", systemImage: "iphone", tint: .accentColor).padding(.trailing, Design.Space.s) }
            HStack(spacing: Design.Space.xs) {
                IconButton("minus", help: "Zoom out") { AppCommands.run("view.zoomOut", store) }
                Button { store.fitToWindow.toggle() } label: {
                    Text("\(Int((store.zoom * 100).rounded()))%").font(Design.Typeface.caption).monospacedDigit()
                        .foregroundStyle(store.fitToWindow ? Color.accentColor : .secondary).frame(width: 44)
                }.buttonStyle(.plain).help(store.fitToWindow ? "Fitting the page — click for a fixed zoom" : "Click to fit the page")
                IconButton("plus", help: "Zoom in") { AppCommands.run("view.zoomIn", store) }
            }
            .padding(.trailing, Design.Space.s)
        }
        .frame(height: 34)
        .background(Design.Palette.surface)
    }

    private func tab(_ page: Page, index: Int) -> some View {
        let selected = page.id == store.currentPageID
        return Group {
            if renaming == page.id {
                TextField("", text: $draftName, onCommit: { commitRename(page) })
                    .textFieldStyle(.plain).font(Design.Typeface.caption).frame(width: 110)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor))
                    .onExitCommand { renaming = nil }
            } else {
                HStack(spacing: 4) {
                    if page.isHidden { Image(systemName: "eye.slash").font(.system(size: 9)) }
                    if page.isTooltipPage { Image(systemName: "text.bubble").font(.system(size: 9)) }
                    if page.isDrillthroughPage { Image(systemName: "arrow.down.right.circle").font(.system(size: 9)) }
                    if page.hasMobileLayout { Image(systemName: "iphone").font(.system(size: 9)) }
                    if store.report.landingPageID == page.id { Image(systemName: "house").font(.system(size: 9)) }
                    Text(page.name).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                }
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Design.Palette.fillStrong : .clear))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { draftName = page.name; renaming = page.id }
                .onTapGesture { store.goToPage(page.id) }
                .draggable("facet-page:\(page.id.uuidString)")
                .dropDestination(for: String.self) { items, _ in
                    guard let s = items.first, s.hasPrefix("facet-page:"), let id = UUID(uuidString: String(s.dropFirst(11))),
                          let from = store.report.pages.firstIndex(where: { $0.id == id }) else { return false }
                    store.movePage(from: from, to: index)
                    return true
                }
                .contextMenu {
                    Button("Rename") { draftName = page.name; renaming = page.id }
                    Button("Duplicate") { store.duplicatePage(page.id) }
                    Button(page.isHidden ? "Show Page" : "Hide Page") { toggle(page) { $0.isHidden.toggle() } }
                    Button(store.report.landingPageID == page.id ? "Clear Landing Page" : "Set as Landing Page") {
                        store.mutate("Set Landing Page", invalidates: .layout) { d in
                            d.report.landingPageID = d.report.landingPageID == page.id ? nil : page.id
                        }
                    }
                    Button(page.isTooltipPage ? "Use as Normal Page" : "Use as Tooltip Page") {
                        toggle(page) { $0.isTooltipPage.toggle(); if $0.isTooltipPage { $0.size = .tooltip } }
                    }
                    Divider()
                    Button("Move Left") { store.movePage(from: index, to: index - 1) }.disabled(index == 0)
                    Button("Move Right") { store.movePage(from: index, to: index + 1) }.disabled(index == store.report.pages.count - 1)
                    Divider()
                    Button("Delete", role: .destructive) { store.deletePage(page.id) }.disabled(store.report.pages.count < 2)
                }
                .accessibilityLabel("Page \(page.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
    private func toggle(_ page: Page, _ change: @escaping (inout Page) -> Void) {
        store.mutate("Change Page", invalidates: .layout) { d in
            if let i = d.report.pages.firstIndex(where: { $0.id == page.id }) { change(&d.report.pages[i]) }
        }
    }
    private func commitRename(_ page: Page) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != page.name else { return }
        toggle(page) { $0.name = name }
    }
}

/// The right-hand inspector: a row of pane icons over the active pane.
struct Inspector: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(InspectorPane.allCases) { p in
                    IconButton(p.symbol, help: p.title, isOn: store.inspector == p) { store.inspector = p }
                }
            }
            .padding(.horizontal, Design.Space.s).padding(.vertical, 6)
            Hairline()
            Features.pane(store.inspector, store).environmentObject(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Design.Palette.surface)
    }
}

/// Transient feedback at the bottom of the window. Errors stay until dismissed.
struct StatusToast: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        Group {
            if let s = store.status {
                HStack(alignment: .top, spacing: Design.Space.s) {
                    Image(systemName: symbol(s.kind)).foregroundStyle(color(s.kind))
                    Text(s.text).font(Design.Typeface.body).textSelection(.enabled).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                    Button { store.status = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 3)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, Design.Space.l).padding(.vertical, Design.Space.m)
                .frame(maxWidth: 560)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.Palette.hairline))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: s.id) {
                    guard s.kind != .error else { return }
                    try? await Task.sleep(nanoseconds: UInt64(max(3.5, Double(s.text.count) / 18) * 1_000_000_000))
                    if store.status?.id == s.id { store.status = nil }
                }
            }
        }
        .animation(Design.Motion.standard, value: store.status)
    }
    private func symbol(_ k: StatusMessage.Kind) -> String {
        switch k { case .info: return "info.circle"; case .success: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.octagon.fill" }
    }
    private func color(_ k: StatusMessage.Kind) -> Color {
        switch k { case .info: return .secondary; case .success: return Design.Palette.positive; case .warning: return Design.Palette.caution; case .error: return Design.Palette.negative }
    }
}

/// ⌘K: every command, searchable.
struct CommandPalette: View {
    @EnvironmentObject var store: DocumentStore
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [AppCommand] {
        let all = AppCommands.all.filter { $0.isEnabled(store) }
        guard !query.isEmpty else { return Array(all.prefix(60)) }
        let q = query.lowercased()
        return all.compactMap { c -> (AppCommand, Int)? in
            let t = c.title.lowercased()
            if t.hasPrefix(q) { return (c, 0) }
            if t.contains(q) { return (c, 1) }
            if c.menu.rawValue.lowercased().contains(q) { return (c, 3) }
            // Subsequence match: "nm" finds "New Measure".
            var it = t.makeIterator()
            for ch in q { var found = false; while let n = it.next() { if n == ch { found = true; break } }; if !found { return nil } }
            return (c, 2)
        }.sorted { $0.1 < $1.1 }.prefix(60).map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: Design.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search commands", text: $query).textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                        .onSubmit { runSelected() }
                }
                .padding(Design.Space.l)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                                HStack(spacing: Design.Space.m) {
                                    Image(systemName: c.symbol.isEmpty ? "circle.fill" : c.symbol).font(.system(size: c.symbol.isEmpty ? 4 : 12))
                                        .foregroundStyle(.secondary).frame(width: 20)
                                    Text(c.title).font(Design.Typeface.body)
                                    Spacer()
                                    Text(c.menu.rawValue).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, Design.Space.l).padding(.vertical, 7)
                                .background(i == index ? Color.accentColor.opacity(0.14) : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; runSelected() }
                                .id(i)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous).strokeBorder(Design.Palette.hairlineStrong))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 16)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }
    private func runSelected() {
        guard let c = results[safe: index] else { return }
        isPresented = false
        c.run(store)
    }
}

/// A single visual, enlarged, over a dimmed window.
struct FocusOverlay: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().onTapGesture { store.focusVisualID = nil }
            VStack(alignment: .trailing, spacing: Design.Space.s) {
                Button { store.focusVisualID = nil } label: { Label("Back to report", systemImage: "chevron.left") }
                    .keyboardShortcut(.escape, modifiers: [])
                VisualView(spec: spec, data: store.visualData[spec.id] ?? VisualData(), context: store.context(for: spec))
                    .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            }
            .padding(48)
        }
    }
}

/// The data behind a visual, as an accessible table.
struct ShowAsTableOverlay: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    var body: some View {
        let data = store.visualData[spec.id] ?? VisualData()
        var table = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 800, height: 500), name: spec.name)
        let _ = { table.setFmt("title", "text", .string(spec.name)) }()
        var tableData = data
        let _ = { tableData.roles = [Well.values.rawValue: Array(0..<data.table.columnCount)] }()
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().onTapGesture { store.showAsTableID = nil }
            VStack(alignment: .trailing, spacing: Design.Space.s) {
                Button { store.showAsTableID = nil } label: { Label("Back to report", systemImage: "chevron.left") }
                    .keyboardShortcut(.escape, modifiers: [])
                VisualView(spec: table, data: tableData, context: store.context(for: table, interactive: false))
                    .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            }
            .padding(48)
        }
    }
}

/// Reading view: the page as readers see it, with page and bookmark navigation.
struct PresentationView: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        GeometryReader { geo in
            let page = store.currentPage
            let scale = max(0.1, min(geo.size.width / page.size.width, (geo.size.height - 44) / page.size.height))
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    store.theme.backgroundColor
                    if let c = page.background.color { Color(hex: c).opacity(1 - page.background.transparency / 100) }
                    ForEach(page.visuals.filter { !$0.isHidden }.sorted { $0.zIndex < $1.zIndex }) { spec in
                        VisualView(spec: spec, data: store.visualData[spec.id] ?? VisualData(), context: store.context(for: spec))
                            .frame(width: spec.frame.width, height: spec.frame.height)
                            .offset(x: spec.frame.x, y: spec.frame.y)
                    }
                }
                .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(width: page.size.width * scale, height: page.size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.92))
                HStack(spacing: Design.Space.m) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                    Text(page.name).font(Design.Typeface.bodyStrong)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                    if !store.report.bookmarks.isEmpty {
                        Menu("Bookmarks") {
                            ForEach(store.report.bookmarks) { b in Button(b.name) { store.applyBookmark(b.id) } }
                        }.fixedSize()
                    }
                    Spacer()
                    Button("Done") { store.presenting = false }.keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, Design.Space.l).frame(height: 44)
                .background(.bar)
            }
        }
    }
    private func step(_ d: Int) {
        let pages = store.report.pages.filter { !$0.isHidden }
        guard let i = pages.firstIndex(where: { $0.id == store.currentPageID }), let next = pages[safe: i + d] else { return }
        store.goToPage(next.id)
    }
}

/// Asks to save before a document window closes, and releases its store afterwards.
struct WindowCloseGuard: NSViewRepresentable {
    let store: DocumentStore
    let handleID: UUID

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = store.isDirty
        if context.coordinator.window == nil { DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(store: store, handleID: handleID) }

    final class Coordinator: NSObject, NSWindowDelegate {
        let store: DocumentStore
        let handleID: UUID
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        init(store: DocumentStore, handleID: UUID) { self.store = store; self.handleID = handleID }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        // Forward everything we don't handle to SwiftUI's own delegate.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard MainActor.assumeIsolated({ FileOperations.confirmClose(store) }) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            original?.windowWillClose?(notification)
            MainActor.assumeIsolated { StoreRegistry.shared.remove(handleID) }
        }
    }
}
