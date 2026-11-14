import SwiftUI
import AppKit
import FacetCore

/// AppKit menus for the preview's column headers. They are built when they open, after the clicked column has
/// been selected, so every item's enabled state reflects the column the user pointed at.
@MainActor
enum EditorMenus {
    final class Item: NSMenuItem {
        private var handler: (() -> Void)?
        convenience init(_ title: String, enabled: Bool, help: String?, handler: @escaping () -> Void) {
            self.init(title: title, action: #selector(fire), keyEquivalent: "")
            self.handler = handler
            target = self
            isEnabled = enabled
            toolTip = help
        }
        @objc private func fire() { handler?() }
    }

    static func menu(_ entries: [EditorRibbonLayout.Entry], session: QueryEditorSession, title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider: menu.addItem(.separator())
            case .submenu(let name, let inner):
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.submenu = Self.menu(inner, session: session, title: name)
                menu.addItem(item)
            case .command(let id):
                guard let command = EditorCommands.command(id) else { continue }
                let blocker = command.blocker(session)
                let item = Item(command.title, enabled: blocker == nil, help: blocker) { command.run(session) }
                if let on = command.isOn?(session) { item.state = on ? .on : .off }
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Show a menu at the mouse pointer.
    static func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Column header menus (Power Query's)

    /// The header's drop-down: sorting and filtering.
    static let headerEntries: [EditorRibbonLayout.Entry] = [
        .command("pq.sortAscending"), .command("pq.sortDescending"), .divider,
        .command("pq.filterColumn"), .command("pq.removeEmpty"),
    ]

    /// The header's context menu: column transformations.
    static var contextEntries: [EditorRibbonLayout.Entry] {
        [
            .command("pq.removeColumns"), .command("pq.removeOtherColumns"), .command("pq.add.duplicate"), .command("pq.add.examplesSelection"), .divider,
            .command("pq.removeDuplicates"), .command("pq.removeErrors"), .divider,
            .submenu("Change Type", DataTypeCommands.types.map { .command(DataTypeCommands.id($0.type)) } + [.divider, .command("pq.typeLocale")]),
            .submenu("Transform", ColumnOperationCommands.textFormats.map { .command("pq.text.\($0.0.rawValue)") } + [.divider, .command("pq.extract.length")]),
            .divider,
            .command("pq.replaceValues"), .command("pq.replaceErrors"), .divider,
            .submenu("Split Column", ["pq.splitDelimiter", "pq.splitLength", "pq.splitPositions", "pq.splitLowerUpper", "pq.splitUpperLower",
                                       "pq.splitDigitNonDigit", "pq.splitNonDigitDigit"].map { .command($0) }),
            .command("pq.groupBy"), .submenu("Fill", [.command("pq.fillDown"), .command("pq.fillUp")]), .divider,
            .command("pq.unpivot"), .command("pq.unpivotOther"), .command("pq.unpivotSelected"), .divider,
            .command("pq.renameColumn"),
            .submenu("Move", ["pq.moveLeft", "pq.moveRight", "pq.moveToBeginning", "pq.moveToEnd"].map { .command($0) }),
            .divider, .command("pq.drillDown"), .command("pq.addAsNewQuery"),
        ]
    }
}

/// Catches right-clicks (and control-clicks) on the view it overlays and shows the menu `make` builds;
/// every other click passes through to the SwiftUI view underneath.
struct ContextMenuCatcher: NSViewRepresentable {
    let make: () -> NSMenu?

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.make = make }

    final class CatcherView: NSView {
        var make: (() -> NSMenu?)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }
        override func menu(for event: NSEvent) -> NSMenu? { make?() }
        override func rightMouseDown(with event: NSEvent) {
            if let menu = make?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = make?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
    }
}
