import AppKit
import SwiftUI

/// A declarative description of an AppKit menu, so SwiftUI-side code can supply menus for
/// AppKit-backed views (grid headers and cells).
indirect enum ModelMenuEntry {
    case item(title: String, symbol: String = "", enabled: Bool = true, checked: Bool = false, action: () -> Void)
    case submenu(title: String, symbol: String = "", entries: [ModelMenuEntry])
    case separator

    static func build(_ entries: [ModelMenuEntry], into menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for e in entries { menu.addItem(e.menuItem()) }
    }

    private func menuItem() -> NSMenuItem {
        switch self {
        case .separator: return .separator()
        case .item(let title, let symbol, let enabled, let checked, let action):
            let item = ModelClosureMenuItem(title: title, handler: action)
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            if !symbol.isEmpty { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return item
        case .submenu(let title, let symbol, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if !symbol.isEmpty { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            let sub = NSMenu(title: title)
            ModelMenuEntry.build(entries, into: sub)
            item.submenu = sub
            return item
        }
    }
}

final class ModelClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func fire() { handler() }
}

/// Small modal prompts for renames and confirmations.
@MainActor
enum ModelPrompt {
    /// Asks for a line of text. Returns nil when cancelled or left empty.
    static func text(title: String, message: String = "", value: String, confirm: String = "Rename") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func confirm(title: String, message: String, confirm: String = "Delete") -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
