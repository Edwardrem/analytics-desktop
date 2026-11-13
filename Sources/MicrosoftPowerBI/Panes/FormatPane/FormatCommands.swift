import SwiftUI
import FacetCore

/// Format menu commands for copying, pasting and resetting visual formatting.
@MainActor
enum FormatCommands {
    static func commands() -> [AppCommand] {
        [
            AppCommand(id: "format.copyFormatting", title: "Copy Formatting", menu: .format, symbol: "paintbrush",
                       shortcut: .init("c", modifiers: [.command, .shift]), separatorBefore: true,
                       isEnabled: { $0.view == .report && $0.selectedVisual != nil }) { store in
                guard let spec = store.selectedVisual else { return }
                FormatClipboard.source = spec
                store.status = StatusMessage(kind: .info, text: "Copied the formatting of \(spec.name). Select visuals and choose Paste Formatting.")
            },
            AppCommand(id: "format.pasteFormatting", title: "Paste Formatting", menu: .format, symbol: "paintbrush.fill",
                       shortcut: .init("v", modifiers: [.command, .shift]),
                       isEnabled: { $0.view == .report && FormatClipboard.source != nil && !$0.selection.isEmpty }) { store in
                guard let source = FormatClipboard.source else { return }
                store.updateVisuals(store.selectedVisuals.map(\.id), name: "Paste Formatting") { $0.format = FormatPainter.painted($0, from: source) }
            },
            AppCommand(id: "format.resetFormatting", title: "Reset Formatting to Default", menu: .format, symbol: "arrow.counterclockwise",
                       isEnabled: { $0.view == .report && $0.selectedVisuals.contains(where: FormatPainter.hasOverrides) }) { store in
                store.updateVisuals(store.selectedVisuals.map(\.id), name: "Reset Formatting") { $0.format = FormatPainter.reset($0) }
            },
        ]
    }
}
