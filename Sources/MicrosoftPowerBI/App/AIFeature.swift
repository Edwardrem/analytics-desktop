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

    static let summarizePageID = "assistant.summarizePage"
    static let summarizeReportID = "assistant.summarizeReport"

    /// Assistant commands: measure descriptions (Data pane menu; the Model view properties panel links to the same
    /// sheet) and the page and report summaries (Home ▸ Assistant), which open the Assistant pane with the answer.
    static func commands() -> [AppCommand] {
        [
            MeasureDescriptions.command,
            AppCommand(id: summarizePageID, title: "Summarize Page", menu: .view, symbol: "doc.text.magnifyingglass",
                       help: "The assistant summarizes what the current page shows, in the Assistant pane",
                       isEnabled: { ShellState.of($0).isAvailable(.assistant) }) { store in
                showPane(store)
                AssistantPaneModel.of(store).summarizePage()
            },
            AppCommand(id: summarizeReportID, title: "Summarize Report", menu: .view, symbol: "doc.richtext",
                       help: "The assistant summarizes every visible page, in the Assistant pane",
                       isEnabled: { ShellState.of($0).isAvailable(.assistant) }) { store in
                showPane(store)
                AssistantPaneModel.of(store).summarizeReport()
            },
        ]
    }

    /// Brings the Assistant pane forward; without a key it shows how to set one up.
    static func showPane(_ store: DocumentStore) {
        ShellState.of(store).show(.assistant)
    }
}

extension Notification.Name {
    static let assistantConfigurationChanged = Notification.Name("assistantConfigurationChanged")
}
