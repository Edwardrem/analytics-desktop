import SwiftUI
import FacetCore
import FacetAnalytics
import FacetCloud

/// Wires the AI features into the shell: the four AI visuals (Key influencers, Decomposition tree,
/// Narrative, Q&A), the Assistant pane and its settings tab.
@MainActor
enum AIFeature {
    static func register() {
        VisualExtensions.provider = { spec, data, context, store in
            AIVisuals.provider(spec: spec, data: data, context: context, store: store)
        }
        Features.paneBuilders[.assistant] = { store in
            AnyView(AssistantPane(store: store))
        }
        DAXAssistant.install()
        AppCommands.register(commands)
        if !SettingsSections.extra.contains(where: { $0.title == "Assistant" }) {
            SettingsSections.extra.append(SettingsSections.Section(
                title: "Assistant", symbol: "sparkles",
                view: { AnyView(AssistantSettingsView()) }))
        }
    }

    /// Assistant commands: measure descriptions (Data pane menu; the Model view properties panel links to the same sheet).
    static func commands() -> [AppCommand] {
        [MeasureDescriptions.command]
    }
}

extension Notification.Name {
    static let assistantConfigurationChanged = Notification.Name("assistantConfigurationChanged")
}
