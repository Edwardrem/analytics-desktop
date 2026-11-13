import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// One document window, laid out like Power BI Desktop on Windows:
/// ribbon · view rail | workspace over page tabs | Filters, Visualizations, Data panes · status bar.
struct DocumentWindow: View {
    let handle: DocumentHandle
    @StateObject private var store: DocumentStore
    @ObservedObject private var shell: ShellState
    @Environment(\.openWindow) private var openWindow
    @State private var paletteVisible = false

    init(handle: DocumentHandle) {
        self.handle = handle
        let store = StoreRegistry.shared.store(for: handle)
        _store = StateObject(wrappedValue: store)
        _shell = ObservedObject(wrappedValue: ShellState.of(store))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.presenting {
                RibbonBar(shell: shell, modeling: store.modeling)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if !store.presenting {
                        ViewRail()
                        Hairline(vertical: true)
                    }
                    VStack(spacing: 0) {
                        workspace
                        if store.view == .report && !store.presenting {
                            Hairline()
                            PageTabs()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.inspectorVisible && !store.presenting {
                        PaneDockView(shell: shell, available: geo.size.width - ShellMetrics.railWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .overlay(alignment: .top) { RibbonPeek(shell: shell, modeling: store.modeling) }
            if !store.presenting {
                Hairline()
                StatusBar()
            }
        }
        .animation(Design.Motion.quick, value: store.inspectorVisible)
        .animation(Design.Motion.quick, value: shell.ribbonCollapsed)
        .animation(Design.Motion.quick, value: shell.ribbonPeeking)
        .animation(Design.Motion.quick, value: shell.dock.collapsed)
        .frame(minWidth: ShellMetrics.minimumWindow.width, minHeight: ShellMetrics.minimumWindow.height)
        .background(Design.Palette.surface)
        .toolbar { TitleBarToolbar(store: store, showPalette: { paletteVisible = true }) }
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

    private var subtitle: String { store.isDirty ? "Edited" : "" }

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

/// The title bar keeps only what Windows keeps there: save, undo, redo, search and the account.
/// Everything else is on the ribbon, in the menu bar and in the palette.
struct TitleBarToolbar: ToolbarContent {
    @ObservedObject var store: DocumentStore
    let showPalette: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            commandButton("file.save", "Save", "square.and.arrow.down")
            commandButton("edit.undo", "Undo", "arrow.uturn.backward")
            commandButton("edit.redo", "Redo", "arrow.uturn.forward")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: showPalette) { Label("Commands", systemImage: "magnifyingglass") }
                .help("Search every command (⌘K)")
            Features.toolbarAccessory(store)
            commandButton("view.inspector", "Panes", "sidebar.right")
        }
    }

    /// A toolbar button for one registry command; disabled when the command is, or is not registered.
    private func commandButton(_ id: String, _ label: String, _ symbol: String) -> some View {
        let command = AppCommands.command(id)
        let ref = RibbonCommand(id: id, label: label, symbol: symbol)
        return Button { AppCommands.run(id, store) } label: { Label(label, systemImage: symbol) }
            .disabled(!(command?.isEnabled(store) ?? false))
            .help(help(for: ref, command: command))
    }
    private func help(for ref: RibbonCommand, command: AppCommand?) -> String {
        switch ref.id {
        case "edit.undo": return store.undoName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo"
        case "edit.redo": return store.redoName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo"
        case "view.inspector": return store.inspectorVisible ? "Hide the panes (⌥⌘I)" : "Show the panes (⌥⌘I)"
        default: return RibbonHelp.text(for: ref, command: command)
        }
    }
}
