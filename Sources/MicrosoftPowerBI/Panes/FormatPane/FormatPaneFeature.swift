import SwiftUI
import FacetCore

/// Registers the Format pane (`InspectorPane.format`).
@MainActor
enum FormatPaneFeature {
    static func register() {
        Features.paneBuilders[.format] = { _ in AnyView(FormatPane()) }
    }
}
