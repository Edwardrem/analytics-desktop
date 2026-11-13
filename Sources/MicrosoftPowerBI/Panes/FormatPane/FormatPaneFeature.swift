import SwiftUI
import FacetCore

/// Registers the Format pane (`InspectorPane.format`), its commands and on-object formatting.
@MainActor
enum FormatPaneFeature {
    static func register() {
        Features.paneBuilders[.format] = { _ in AnyView(FormatPane()) }
        Features.visualHeaderAccessory = { spec, _ in AnyView(FormatOnObjectButton(spec: spec)) }
        AppCommands.register(FormatCommands.commands)
    }
}
