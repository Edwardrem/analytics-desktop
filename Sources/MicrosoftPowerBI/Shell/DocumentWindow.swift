import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// One document window. Owns the document's store for the life of the window and hands it,
/// with its shell state, to the layout.
struct DocumentWindow: View {
    let handle: DocumentHandle
    @StateObject private var store: DocumentStore

    init(handle: DocumentHandle) {
        self.handle = handle
        // The autoclosure runs once, when SwiftUI first installs the state — not on every `init`.
        _store = StateObject(wrappedValue: StoreRegistry.shared.store(for: handle))
    }

    var body: some View {
        DocumentLayout(handle: handle, store: store, shell: ShellState.of(store))
    }
}

/// The window laid out like Power BI Desktop on Windows:
/// ribbon · view rail | workspace over page tabs | Filters, Visualizations, Data panes · status bar.
private struct DocumentLayout: View {
    let handle: DocumentHandle
    @ObservedObject var store: DocumentStore
    @ObservedObject var shell: ShellState
    @Environment(\.openWindow) private var openWindow
    @State private var paletteVisible = false

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
                        PaneDockView(shell: shell)
                            .transition(.move(edge: .trailing))
                    }
                }
                .onChange(of: geo.size.width, initial: true) { _, width in
                    shell.available = Double(width - ShellMetrics.railWidth)
                }
            }
            .overlay(alignment: .top) {
                if !store.presenting { RibbonPeek(shell: shell, modeling: store.modeling) }
            }
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
        .navigationSubtitle(store.isDirty ? "Edited" : "")
        .environmentObject(store)
        .focusedSceneObject(store)
        .overlay(alignment: .bottom) { StatusToast().environmentObject(store) }
        .overlay { if paletteVisible { CommandPalette(isPresented: $paletteVisible).environmentObject(store) } }
        .overlay { overlays }
        .sheet(item: $store.sheet) { $0.view }
        .background(WindowCloseGuard(store: store, handleID: handle.id))
        .onChange(of: store.presenting) { _, presenting in
            if presenting { shell.ribbonPeeking = false }
        }
        // Notifications reach every window; each acts only on the ones addressed to its own document.
        .onReceive(NotificationCenter.default.publisher(for: .facetShowPalette)) { note in
            if ShellNotifications.isAddressed(note, to: store) { paletteVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .facetOpenQueryEditor)) { note in
            if ShellNotifications.isAddressed(note, to: store) { openWindow(id: "query-editor", value: handle.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .facetRunDataFunction)) { note in
            guard ShellNotifications.isAddressed(note, to: store) else { return }
            store.status = StatusMessage(kind: .warning, text: ShellNotifications.dataFunctionMessage(note))
        }
        .onAppear {
            FileOperations.openInNewWindow = { url in openWindow(id: "document", value: DocumentHandle(url: url)) }
        }
    }

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

/// How windows decide whether a document-scoped notification is theirs.
enum ShellNotifications {
    /// A notification belongs to the window whose store posted it. One with no sender belongs to nobody.
    static func isAddressed(_ note: Notification, to store: DocumentStore) -> Bool {
        (note.object as? DocumentStore) === store
    }
    /// A button asked to run a user data function. Nothing in this build can call one, so say so
    /// instead of doing nothing.
    static func dataFunctionMessage(_ note: Notification) -> String {
        let name = (note.userInfo?["action"] as? ActionSpec)?.functionName ?? ""
        let subject = name.isEmpty ? "This button's data function" : "The data function “\(name)”"
        return "\(subject) can't run: \(AppIdentity.name) can't call Fabric user data functions yet. Choose another action for the button in the Build pane."
    }
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
