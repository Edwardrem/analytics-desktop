import SwiftUI
import FacetCore
import FacetAnalytics
import FacetCloud
import FacetQuery
import FacetDesign

/// Wires the AI features into the shell: the four AI visuals (Key influencers, Decomposition tree,
/// Narrative, Q&A), the Assistant pane and its settings tab, the assistant in DAX query view, and the
/// on-device AI Insights functions of Power Query.
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
        AIInsights.provider = OnDeviceAIInsights()
        AppCommands.register(commands)
        installVisualHeaderButton()
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

    private static var headerInstalled = false

    /// Adds Summarize to the header of every visual with data, after the controls already there.
    private static func installVisualHeaderButton() {
        guard !headerInstalled else { return }
        headerInstalled = true
        let existing = Features.visualHeaderAccessory
        Features.visualHeaderAccessory = { spec, store in
            let summarizable = !spec.type.isPageElement && !spec.type.isSlicer && spec.type != .narrative && spec.type != .qna
            return AnyView(HStack(spacing: 2) {
                if let existing { existing(spec, store) }
                if summarizable { SummarizeVisualButton(visual: spec.id, store: store) }
            })
        }
    }

    /// Brings the Assistant pane forward; without a key it shows how to set one up.
    static func showPane(_ store: DocumentStore) {
        ShellState.of(store).show(.assistant)
    }
}

extension Notification.Name {
    static let assistantConfigurationChanged = Notification.Name("assistantConfigurationChanged")
}

/// The visual header's Summarize button: opens the Assistant pane with a summary of this visual.
struct SummarizeVisualButton: View {
    let visual: UUID
    let store: DocumentStore

    var body: some View {
        IconButton("sparkles", help: "Summarize this visual with the assistant") {
            AIFeature.showPane(store)
            AssistantPaneModel.of(store).summarizeVisual(visual)
        }
    }
}
