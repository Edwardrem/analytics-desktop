import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// The ribbon, drawn from `RibbonLayout.tabs`. Every control runs a command from `AppCommands` by id
// and takes its enabled and on states from that command, so the ribbon, the menu bar and the palette
// cannot disagree. A command the registry does not have draws disabled.

/// The registry as the ribbon layout sees it, rebuilt only when the set of commands changes.
@MainActor
enum RibbonRegistry {
    private static var cached: (generation: Int, infos: [RibbonCommandInfo], resolved: [RibbonTab], file: [RibbonMenuEntry])?
    /// How many times the ribbon has been resolved against the registry (once per generation).
    private(set) static var resolutions = 0

    private static var current: (generation: Int, infos: [RibbonCommandInfo], resolved: [RibbonTab], file: [RibbonMenuEntry]) {
        let all = AppCommands.all
        if let cached, cached.generation == AppCommands.generation { return cached }
        let infos = all.map { RibbonCommandInfo(id: $0.id, title: $0.title, symbol: $0.symbol, menu: $0.menu, separatorBefore: $0.separatorBefore) }
        let fresh = (AppCommands.generation, infos, RibbonLayout.resolve(registry: infos), RibbonLayout.fileMenu(registry: infos))
        resolutions += 1
        cached = fresh
        return fresh
    }

    static var infos: [RibbonCommandInfo] { current.infos }
    /// Every tab with its registry-driven groups resolved. Drawing only filters this by window state.
    static var resolved: [RibbonTab] { current.resolved }
    static var fileMenu: [RibbonMenuEntry] { current.file }
    static func visibleTabs(_ store: DocumentStore) -> [RibbonTab] {
        RibbonLayout.visibleTabs(.current(store), resolved: resolved)
    }
}

extension RibbonContext {
    /// What the ribbon needs to know about a document window right now.
    @MainActor
    static func current(_ store: DocumentStore) -> RibbonContext {
        var c = RibbonContext()
        c.view = store.view
        let selected = store.view == .report ? store.selectedVisuals : []
        c.selectionCount = selected.count
        c.dataVisualSelected = selected.count == 1 && selected.first.map { !$0.type.isPageElement } ?? false
        c.modelHasTables = !store.model.tables.isEmpty
        if store.view == .table || store.view == .model {
            switch store.modeling.primary {
            case .column(let t, let n)? where store.model.table(t)?.column(n) != nil: c.modelObject = .column
            case .measure(let t, let n)? where store.model.table(t)?.measure(n) != nil: c.modelObject = .measure
            case .table(let t)? where store.model.table(t) != nil: c.modelObject = .table
            default: c.modelObject = nil
            }
        }
        return c
    }
}

/// The ribbon: a strip of tabs over the active tab's groups. Collapsed, only the strip shows.
struct RibbonBar: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var shell: ShellState
    /// Observed so the contextual tabs follow the selection in Table and Model view.
    @ObservedObject var modeling: ModelingState

    var body: some View {
        let tabs = RibbonRegistry.visibleTabs(store)
        let active = RibbonLayout.activeTab(selected: shell.ribbonTab, visible: tabs)
        VStack(spacing: 0) {
            RibbonTabStrip(tabs: tabs, active: active?.id, shell: shell)
            if !shell.ribbonCollapsed, let active {
                RibbonGroups(tab: active, shell: shell)
            }
            Hairline()
        }
        .background(Design.Palette.surface)
    }
}

/// The active tab's commands, dropped over the window while the collapsed ribbon is peeking.
struct RibbonPeek: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var shell: ShellState
    @ObservedObject var modeling: ModelingState

    var body: some View {
        // Nothing is resolved unless the peek is actually up.
        if shell.ribbonCollapsed, shell.ribbonPeeking,
           let active = RibbonLayout.activeTab(selected: shell.ribbonTab, visible: RibbonRegistry.visibleTabs(store)) {
            ZStack(alignment: .top) {
                // Clicking anywhere else puts the ribbon away again.
                Color.clear.contentShape(Rectangle()).onTapGesture { shell.ribbonPeeking = false }
                VStack(spacing: 0) {
                    RibbonGroups(tab: active, shell: shell)
                    Hairline()
                }
                .background(Design.Palette.surface)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Tab strip

private struct RibbonTabStrip: View {
    @EnvironmentObject var store: DocumentStore
    let tabs: [RibbonTab]
    let active: RibbonTabID?
    @ObservedObject var shell: ShellState
    @State private var fileAnchor = AnchorBox()

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Button {
                RibbonMenu.popUp(RibbonRegistry.fileMenu, store: store, anchor: fileAnchor.view) { shell.run($0) }
            } label: {
                tabLabel("File", selected: false, contextual: false)
            }
            .buttonStyle(.plain)
            .background(MenuAnchor(box: fileAnchor))
            .help("Open, save, export and report settings")
            ForEach(tabs, id: \.id) { tab in
                let selected = tab.id == active && (!shell.ribbonCollapsed || shell.ribbonPeeking)
                Button { shell.choose(tab.id) } label: {
                    tabLabel(tab.title, selected: selected, contextual: tab.contextual)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { shell.toggleRibbon() })
                .help(tab.contextual ? "\(tab.title) — tools for what is selected" : "\(tab.title) tab. Double-click to collapse or expand the ribbon.")
                .accessibilityLabel("\(tab.title) tab")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: Design.Space.s)
            IconButton(shell.ribbonCollapsed ? "chevron.down" : "chevron.up",
                       help: shell.ribbonCollapsed ? "Expand the ribbon (⌥⌘R)" : "Collapse the ribbon to a single line (⌥⌘R)") {
                shell.toggleRibbon()
            }
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: ShellMetrics.tabStripHeight)
    }

    private func tabLabel(_ title: String, selected: Bool, contextual: Bool) -> some View {
        Text(title)
            .font(selected ? Design.Typeface.bodyStrong : Design.Typeface.body)
            .foregroundStyle(contextual ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(selected ? .primary : .secondary))
            .lineLimit(1)
            .padding(.horizontal, Design.Space.s)
            .frame(height: ShellMetrics.tabStripHeight)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, Design.Space.s)
                }
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Groups

extension RibbonFit {
    /// The fit in the ribbon's real sizes: design tokens and the caption font.
    @MainActor static let standard = RibbonFit(
        metrics: RibbonMetrics(
            largeWidth: Double(ShellMetrics.ribbonLargeWidth), smallIcon: Double(Design.Space.l),
            smallPadding: Double(Design.Space.xs), smallSpacing: Double(Design.Space.xs),
            menuChevron: Double(Design.Space.m), columnSpacing: Double(Design.Space.xxs),
            groupPadding: Double(Design.Space.s), separator: 1, edgePadding: Double(Design.Space.xs), slack: 2),
        textWidth: RibbonText.width)
}

/// Caption widths in the ribbon's caption font (`Design.Typeface.caption`), measured once each.
@MainActor
enum RibbonText {
    private static var cache: [String: Double] = [:]
    private static let font = NSFont.systemFont(ofSize: 11)
    static func width(_ text: String) -> Double {
        if let hit = cache[text] { return hit }
        let w = Double((text as NSString).size(withAttributes: [.font: font]).width)
        cache[text] = w
        return w
    }
}

private struct RibbonGroups: View {
    let tab: RibbonTab
    @ObservedObject var shell: ShellState

    var body: some View {
        GeometryReader { geo in
            let fits = RibbonFit.standard.fit(tab.groups, available: Double(geo.size.width))
            // The fit keeps the row inside the window; scrolling is only the fallback below the minimum width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(tab.groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Hairline(vertical: true).padding(.vertical, Design.Space.s) }
                        if let fit = fits[safe: index] {
                            RibbonGroupView(group: group, fit: fit, shell: shell)
                        }
                    }
                }
                .padding(.horizontal, Design.Space.xs)
                .id(tab.id)
            }
        }
        .frame(height: ShellMetrics.ribbonControlsHeight + Design.Space.xl)
    }
}

private struct RibbonGroupView: View {
    @EnvironmentObject var store: DocumentStore
    let group: RibbonGroup
    let fit: RibbonGroupFit
    @ObservedObject var shell: ShellState
    @State private var anchor = AnchorBox()

    var body: some View {
        let inner = CGFloat(fit.width) - Design.Space.s * 2
        VStack(spacing: Design.Space.xxs) {
            controls
                .frame(width: inner, height: ShellMetrics.ribbonControlsHeight, alignment: .topLeading)
            Text(fit.mode == .collapsed ? "" : group.title)
                .font(Design.Typeface.section).foregroundStyle(.tertiary).lineLimit(1)
                .frame(width: inner)
        }
        .padding(.horizontal, Design.Space.s)
        .padding(.top, Design.Space.xs)
        .frame(width: CGFloat(fit.width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }

    @ViewBuilder private var controls: some View {
        if fit.mode == .collapsed {
            // The whole group behind one button, as on a narrow Windows ribbon.
            RibbonButton(label: group.title, symbol: RibbonFit.collapsedSymbol(group), size: .large, showsMenu: true,
                         help: "\(group.title) — show this group's commands") {
                RibbonMenu.popUp(RibbonFit.collapsedEntries(group), store: store, anchor: anchor.view) { shell.run($0) }
            }
            .background(MenuAnchor(box: anchor))
        } else {
            HStack(alignment: .top, spacing: Design.Space.xxs) {
                ForEach(Array(RibbonLayout.columns(group).enumerated()), id: \.offset) { index, column in
                    let width = CGFloat(fit.columnWidths[safe: index] ?? Double(ShellMetrics.ribbonLargeWidth))
                    switch column {
                    case .large(let item):
                        RibbonControlView(item: item, shell: shell)
                    case .stack(let items):
                        VStack(alignment: .leading, spacing: (ShellMetrics.ribbonControlsHeight - 3 * ShellMetrics.ribbonSmallRowHeight) / 2) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                RibbonControlView(item: item, shell: shell, smallWidth: width, iconOnly: fit.mode == .compact)
                            }
                        }
                        .frame(width: width, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// One control of a group: a command button, a menu, or the visual gallery.
private struct RibbonControlView: View {
    @EnvironmentObject var store: DocumentStore
    let item: RibbonItem
    @ObservedObject var shell: ShellState
    /// For a small control: the width of its column, and whether its caption is dropped to fit.
    var smallWidth: CGFloat?
    var iconOnly = false
    @State private var anchor = AnchorBox()
    @State private var galleryVisible = false

    var body: some View {
        switch item.control {
        case .button(let ref):
            let command = AppCommands.command(ref.id)
            RibbonButton(label: ref.label, symbol: ref.symbol, size: item.size, smallWidth: smallWidth, iconOnly: iconOnly,
                         isOn: command?.isOn?(store) ?? false,
                         enabled: command?.isEnabled(store) ?? false,
                         help: RibbonHelp.text(for: ref, command: command)) { shell.run(ref.id) }
        case .menu(let label, let symbol, let entries):
            RibbonButton(label: label, symbol: symbol, size: item.size, smallWidth: smallWidth, iconOnly: iconOnly,
                         showsMenu: true, help: label) {
                RibbonMenu.popUp(entries, store: store, anchor: anchor.view) { shell.run($0) }
            }
            .background(MenuAnchor(box: anchor))
        case .visualGallery(let label, let symbol):
            RibbonButton(label: label, symbol: symbol, size: item.size, smallWidth: smallWidth, iconOnly: iconOnly,
                         showsMenu: true, help: "Add a visual to the page") {
                galleryVisible.toggle()
            }
            .popover(isPresented: $galleryVisible, arrowEdge: .bottom) {
                VisualGallery { type in
                    galleryVisible = false
                    shell.run(RibbonLayout.visualPrefix + type.rawValue)
                }
            }
        case .registered, .overflow:
            // Resolved into buttons and menus by `RibbonLayout.expand` before drawing.
            EmptyView()
        }
    }
}

enum RibbonHelp {
    /// Tooltip for a ribbon command: its full title and shortcut, or why it is disabled.
    static func text(for ref: RibbonCommand, command: AppCommand?) -> String {
        guard let command else { return "\(ref.label) — not available yet" }
        var text = command.title
        if let shortcut = command.shortcut { text += " (\(ShortcutText.describe(shortcut)))" }
        if !command.help.isEmpty { text += " — \(command.help)" }
        return text
    }
}

/// A ribbon button face: icon over a caption (large) or icon beside it (small).
private struct RibbonButton: View {
    let label: String
    let symbol: String
    let size: RibbonItem.Size
    /// Small buttons are drawn at exactly the width `RibbonFit` gave their column.
    var smallWidth: CGFloat?
    var iconOnly = false
    var isOn = false
    var enabled = true
    var showsMenu = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(RibbonButtonStyle(isOn: isOn, hovering: hovering && enabled))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.38)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var symbolName: String { symbol.isEmpty ? RibbonLayout.fallbackSymbol : symbol }

    @ViewBuilder private var face: some View {
        switch size {
        case .large:
            VStack(spacing: Design.Space.xxs) {
                Image(systemName: symbolName)
                    .font(.system(size: ShellMetrics.ribbonLargeIcon, weight: .light))
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .frame(height: Design.Space.xl + Design.Space.xxs)
                caption.multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Design.Space.xs)
            .frame(width: ShellMetrics.ribbonLargeWidth, height: ShellMetrics.ribbonControlsHeight, alignment: .top)
            .contentShape(Rectangle())
        case .small:
            HStack(spacing: Design.Space.xs) {
                Image(systemName: symbolName)
                    .font(.system(size: ShellMetrics.ribbonSmallIcon))
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .frame(width: Design.Space.l)
                if !iconOnly { caption.lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, Design.Space.xs)
            .frame(width: smallWidth, height: ShellMetrics.ribbonSmallRowHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
        }
    }

    private var caption: Text {
        let text = Text(label).font(Design.Typeface.caption)
        guard showsMenu else { return text }
        return text + Text(" ") + Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .semibold))
    }
}

private struct RibbonButtonStyle: ButtonStyle {
    let isOn: Bool
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .fill(isOn ? Color.accentColor.opacity(0.14)
                      : configuration.isPressed ? Design.Palette.fillStrong
                      : hovering ? Design.Palette.fill : Color.clear))
    }
}

// MARK: - Menus

/// Holds the AppKit view a ribbon button sits on, so its menu can drop from the button.
final class AnchorBox {
    weak var view: NSView?
}

struct MenuAnchor: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Native drop-down menus for ribbon controls, built from registry commands.
@MainActor
enum RibbonMenu {
    static func popUp(_ entries: [RibbonMenuEntry], store: DocumentStore, anchor: NSView?, run: @escaping (String) -> Void) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case .command(let ref):
                let command = AppCommands.command(ref.id)
                let action = MenuAction { run(ref.id) }
                let item = NSMenuItem(title: ref.label, action: #selector(MenuAction.fire), keyEquivalent: "")
                item.target = action
                item.representedObject = action   // the item keeps its target alive
                item.isEnabled = command?.isEnabled(store) ?? false
                item.state = (command?.isOn?(store) ?? false) ? .on : .off
                item.toolTip = RibbonHelp.text(for: ref, command: command)
                if !ref.symbol.isEmpty { item.image = NSImage(systemSymbolName: ref.symbol, accessibilityDescription: nil) }
                menu.addItem(item)
            }
        }
        guard !menu.items.isEmpty else { return }
        if let anchor, anchor.window != nil {
            let below = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + Design.Space.xxs : -Design.Space.xxs)
            menu.popUp(positioning: nil, at: below, in: anchor)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}
