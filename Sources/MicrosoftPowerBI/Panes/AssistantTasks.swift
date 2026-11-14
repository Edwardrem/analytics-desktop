import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetDesign

/// One-shot assistant requests outside the chat: explaining or writing DAX, describing a measure,
/// writing a narrative. Each reads the provider settings and the Keychain key through `makeClient`.
@MainActor
enum AssistantTasks {
    /// The client built from the saved assistant settings. Tests replace it with one on a stubbed session.
    static var makeClient: () -> AssistantClient = { AssistantClient() }

    static var isConfigured: Bool { makeClient().isConfigured }

    /// The message every assistant feature shows when no key is saved.
    static var setupMessage: String { AssistantError.notConfigured.errorDescription ?? "The assistant is not set up." }

    /// True for errors the user fixes in Settings ▸ Assistant (no key, or a rejected key).
    static func needsSetup(_ error: Error) -> Bool {
        switch error as? AssistantError {
        case .notConfigured?, .authentication?: return true
        default: return false
        }
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Opens the app's Settings window (the Assistant tab holds the key, model and effort).
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// The opening of every one-shot instruction block.
    static let role = "You are the assistant built into \(AppIdentity.name), a business-intelligence app for Mac. "

    /// One prompt with the model description as cached context; returns the answer text.
    static func ask(_ instructions: String, prompt: String, store: DocumentStore) async throws -> String {
        try await makeClient().complete(instructions: role + instructions, context: AssistantContext.model(store), prompt: prompt).text
    }
}

/// The notice an assistant feature shows instead of a result when it cannot run: the reason, and a way to
/// Settings when the fix is there.
struct AssistantNotice: View {
    let message: String
    var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(message).font(Design.Typeface.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if showsSettings {
                Button("Open Assistant Settings…") { AssistantTasks.openSettings() }
                    .help("Add or change the Anthropic API key in Settings ▸ Assistant")
            }
        }
    }

    init(message: String, showsSettings: Bool = false) {
        self.message = message
        self.showsSettings = showsSettings
    }

    init(error: Error) {
        self.message = AssistantTasks.message(error)
        self.showsSettings = AssistantTasks.needsSetup(error)
    }
}
