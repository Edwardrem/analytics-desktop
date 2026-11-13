import SwiftUI
import Combine
import FacetDesign

/// Sizes the shell agrees on, in one place.
enum ShellMetrics {
    static let railWidth: CGFloat = 48
    static let tabStripHeight: CGFloat = 30
    /// Height of a ribbon group's controls: one large button, or three small rows.
    static let ribbonControlsHeight: CGFloat = 66
    static let ribbonSmallRowHeight: CGFloat = 20
    static let ribbonLargeWidth: CGFloat = 68
    static let ribbonLargeIcon: CGFloat = 20
    static let ribbonSmallIcon: CGFloat = 12
    static let pageTabsHeight: CGFloat = 32
    static let statusBarHeight: CGFloat = 24
    static let paneHeaderHeight: CGFloat = 30
    static let minimumWindow = CGSize(width: 1000, height: 640)
}

/// Window-chrome state for one document: the ribbon tab, whether the ribbon is collapsed, and the
/// pane dock. None of it is document content, so it never goes through `DocumentStore.mutate`;
/// the collapsed ribbon and the dock arrangement are remembered across launches as preferences.
@MainActor
final class ShellState: ObservableObject {
    @Published var dock: PaneDock { didSet { if dock != oldValue { dockChanged() } } }
    @Published var ribbonCollapsed: Bool { didSet { if ribbonCollapsed != oldValue { ribbonChanged() } } }
    @Published var ribbonTab: RibbonTabID = .home
    /// While the ribbon is collapsed: a tab was clicked and its commands are showing over the window.
    @Published var ribbonPeeking = false

    private weak var store: DocumentStore?
    private let defaults: UserDefaults
    private var observation: AnyCancellable?

    private static let dockKey = "shell.paneDock"
    private static let ribbonKey = "shell.ribbonCollapsed"
    private static var all: [ObjectIdentifier: ShellState] = [:]
    /// Where the ribbon and dock preferences are kept.
    static var preferences: UserDefaults = .standard

    /// The shell state of a document, created on first use.
    static func of(_ store: DocumentStore) -> ShellState {
        let key = ObjectIdentifier(store)
        if let existing = all[key], existing.store === store { return existing }
        all = all.filter { $0.value.store != nil }
        let state = ShellState(store: store, defaults: preferences)
        all[key] = state
        return state
    }

    init(store: DocumentStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        dock = defaults.data(forKey: Self.dockKey).flatMap { try? JSONDecoder().decode(PaneDock.self, from: $0) } ?? PaneDock()
        ribbonCollapsed = defaults.bool(forKey: Self.ribbonKey)
        // Features open a pane by setting `store.inspector` (and `inspectorVisible`). Every assignment
        // — also of the value it already had — is a request to bring that pane forward.
        observation = store.$inspector.dropFirst().sink { [weak self] pane in
            self?.dock.reveal(pane.rawValue)
        }
    }

    private func dockChanged() {
        if let data = try? JSONEncoder().encode(dock) { defaults.set(data, forKey: Self.dockKey) }
        // Menu-bar check marks are computed from the store's commands; tell them the answer changed.
        store?.objectWillChange.send()
    }
    private func ribbonChanged() {
        defaults.set(ribbonCollapsed, forKey: Self.ribbonKey)
        if !ribbonCollapsed { ribbonPeeking = false }
        store?.objectWillChange.send()
    }

    // MARK: Ribbon

    func toggleRibbon() { ribbonCollapsed.toggle() }

    /// A tab was clicked. Collapsed, the ribbon drops that tab's commands over the window until one runs.
    func choose(_ tab: RibbonTabID) {
        if ribbonCollapsed {
            ribbonPeeking = !(ribbonPeeking && ribbonTab == tab)
        }
        ribbonTab = tab
    }

    /// Runs a command from the ribbon and puts a peeking ribbon away.
    func run(_ id: String) {
        ribbonPeeking = false
        if let store { AppCommands.run(id, store) }
    }

    // MARK: Panes

    func isShowing(_ pane: InspectorPane) -> Bool {
        (store?.inspectorVisible ?? false) && dock.isShowing(pane.rawValue)
    }
    func show(_ pane: InspectorPane) {
        dock.reveal(pane.rawValue)
        store?.inspectorVisible = true
    }
    func toggle(_ pane: InspectorPane) {
        if isShowing(pane) { dock.close(pane.rawValue) } else { show(pane) }
    }
}

/// Human-readable keyboard shortcuts, for tooltips and the shortcuts sheet.
enum ShortcutText {
    static func describe(_ shortcut: KeyboardShortcut) -> String {
        var s = ""
        if shortcut.modifiers.contains(.control) { s += "⌃" }
        if shortcut.modifiers.contains(.option) { s += "⌥" }
        if shortcut.modifiers.contains(.shift) { s += "⇧" }
        if shortcut.modifiers.contains(.command) { s += "⌘" }
        return s + key(shortcut.key)
    }
    static func key(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: return "↩"
        case .delete: return "⌫"
        case .deleteForward: return "⌦"
        case .escape: return "⎋"
        case .tab: return "⇥"
        case .space: return "Space"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        default: return String(key.character).uppercased()
        }
    }
}

/// Help ▸ Keyboard Shortcuts: every command that has one, by menu, straight from the registry.
struct KeyboardShortcutsSheet: View {
    @EnvironmentObject var store: DocumentStore
    @State private var search = ""

    private var sections: [(menu: AppCommand.Menu, commands: [AppCommand])] {
        AppCommand.Menu.allCases.compactMap { menu in
            let list = AppCommands.all.filter {
                $0.menu == menu && $0.shortcut != nil && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
            }
            return list.isEmpty ? nil : (menu, list)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.m) {
                Text("Keyboard shortcuts").font(Design.Typeface.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(Design.Space.l)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    ForEach(sections, id: \.menu) { section in
                        VStack(alignment: .leading, spacing: Design.Space.xs) {
                            SectionLabel(section.menu.rawValue)
                            ForEach(section.commands) { command in
                                HStack {
                                    Text(command.title).font(Design.Typeface.body)
                                    Spacer()
                                    Text(command.shortcut.map(ShortcutText.describe) ?? "")
                                        .font(Design.Typeface.mono).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, Design.Space.xxs)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("No shortcuts match “\(search)”.").font(Design.Typeface.body).foregroundStyle(.secondary)
                    }
                }
                .padding(Design.Space.l)
            }
            Hairline()
            HStack {
                Text("Every command is also in the command palette (⌘K).").font(Design.Typeface.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { store.dismissSheet() }.keyboardShortcut(.defaultAction)
            }
            .padding(Design.Space.l)
        }
        .frame(width: 520, height: 560)
    }
}
