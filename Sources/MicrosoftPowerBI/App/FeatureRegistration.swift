import SwiftUI
import FacetQuery

/// The one place that wires feature areas into the shell.
/// Each area exposes a `register()` that fills `Features` builders, `AppCommands`, `FileOperations.importers`, etc.
@MainActor
enum FeatureRegistration {
    static func register() {
        SettingsFeature.register()
        FieldPanesFeature.register()
        ReportPanesFeature.register()
        ModelingFeature.register()
        DAXQueryFeature.register()
        PowerQueryFeature.register()
        GetDataFeature.register()
        AccountFeature.register()
        AIFeature.register()
        AnalyzeFeature.register()
        #if !FACET_SHELL_ONLY
        LiveBridge.register()
        #endif
    }
}
