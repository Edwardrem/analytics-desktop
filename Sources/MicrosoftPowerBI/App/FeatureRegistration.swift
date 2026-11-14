import SwiftUI
import FacetQuery

/// The one place that wires feature areas into the shell.
/// Each area exposes a `register()` that fills `Features` builders, `AppCommands`, `FileOperations.importers`, etc.
@MainActor
enum FeatureRegistration {
    static func register() {
        IdentityMigration.runAtLaunch()
        SettingsFeature.register()
        FieldPanesFeature.register()
        ReportPanesFeature.register()
        ReportFeature.register()
        FormatPaneFeature.register()
        ModelingFeature.register()
        DAXQueryFeature.register()
        TMDLViewFeature.register()
        PowerQueryFeature.register()
        GetDataFeature.register()
        AccountFeature.register()
        AIFeature.register()
        AnalyzeFeature.register()
        FileFormatsFeature.register()
        DataExporters.register()
        AgentBridgeFeature.register()
        UpdatesFeature.register()
    }
}
