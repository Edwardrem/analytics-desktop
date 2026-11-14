import SwiftUI
import FacetCore
import FacetCloud
import FacetDesign

/// Settings ▸ Assistant: the Anthropic API key, model, reasoning effort and conversation options.
struct AssistantSettingsView: View {
    @State private var config = AssistantConfiguration.load()
    @State private var apiKeyDraft = ""
    @State private var hasKey = false
    @State private var keyStatus: String?
    private let client = AssistantClient()

    var body: some View {
        Form {
            Section("Anthropic API key") {
                if hasKey {
                    Label("A key is saved in your Keychain.", systemImage: "checkmark.seal")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                SecureField("sk-ant-…", text: $apiKeyDraft)
                HStack {
                    Button("Save Key") {
                        do {
                            try client.setAPIKey(apiKeyDraft)
                            apiKeyDraft = ""
                            keyStatus = nil
                        } catch {
                            keyStatus = "The key could not be saved to the Keychain: \(error.localizedDescription)"
                        }
                        keyChanged()
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey {
                        Button("Remove Key", role: .destructive) {
                            do { try client.removeAPIKey(); keyStatus = nil }
                            catch { keyStatus = "The key could not be removed from the Keychain: \(error.localizedDescription)" }
                            keyChanged()
                        }
                    }
                }
                if let keyStatus {
                    Text(keyStatus).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("Create a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com")!)
                    .font(Design.Typeface.caption)
            }
            Section("Model") {
                Picker("Model", selection: modelBinding) {
                    ForEach(AssistantModel.allCases, id: \.id) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                Picker("Reasoning effort", selection: effortBinding) {
                    Text("Default").tag(AssistantConfiguration.Effort?.none)
                    ForEach(AssistantConfiguration.Effort.allCases, id: \.self) { e in
                        Text(e.rawValue.capitalized).tag(AssistantConfiguration.Effort?.some(e))
                    }
                }
                LabeledContent("Max output tokens") {
                    TextField("64000", value: $config.maxOutputTokens, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                Toggle("Summarize the model's reasoning", isOn: $config.showThinkingSummaries)
                Toggle("Retry declined requests on a fallback model", isOn: $config.refusalFallback)
            }
            Section("Conversation and tools") {
                LabeledContent("History token budget") {
                    TextField("400000", value: $config.historyTokenBudget, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                LabeledContent("Max tool rounds") {
                    TextField("30", value: $config.maxToolRounds, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                Toggle("Run tools in parallel", isOn: $config.parallelToolExecution)
            }
        }
        .formStyle(.grouped)
        .onAppear { config = AssistantConfiguration.load(); hasKey = client.isConfigured }
        .onChange(of: config) { _, new in
            new.save(to: .standard)
            client.configuration = new
            NotificationCenter.default.post(name: .assistantConfigurationChanged, object: nil)
        }
    }

    /// Every open Assistant pane and assistant feature re-reads whether a key is saved.
    private func keyChanged() {
        hasKey = client.isConfigured
        NotificationCenter.default.post(name: .assistantConfigurationChanged, object: nil)
    }

    private var modelBinding: Binding<String> {
        Binding(get: { config.modelID }, set: { config.modelID = $0 })
    }

    private var effortBinding: Binding<AssistantConfiguration.Effort?> {
        Binding(get: { config.effort }, set: { config.effort = $0 })
    }
}
