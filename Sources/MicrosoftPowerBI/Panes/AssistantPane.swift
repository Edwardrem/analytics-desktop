import SwiftUI
import FacetCore
import FacetAnalytics
import FacetCloud
import FacetDesign
import FacetVisuals

/// The Assistant pane: chat alongside the report with tools that read the model and the report, run DAX,
/// and create visuals, pages or measures. Backed by the Claude assistant in FacetCloud.
struct AssistantPane: View {
    let store: DocumentStore
    @ObservedObject private var model: AssistantPaneModel

    init(store: DocumentStore) {
        self.store = store
        _model = ObservedObject(wrappedValue: AssistantPaneModel.of(store))
    }

    var body: some View {
        Group {
            if !model.hasKey {
                SetupCard(model: model)
            } else {
                chat
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantConfigurationChanged)) { _ in
            model.applyConfigurationChange()
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Design.Space.m) {
                        if model.transcript.isEmpty {
                            AssistantSuggestions(store: store, model: model)
                        }
                        ForEach(model.transcript) { entry in
                            ChatRow(entry: entry, show: { model.show($0) })
                        }
                    }
                    .padding(Design.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.transcript.count) { _, _ in
                    withAnimation { proxy.scrollTo(model.transcript.last?.id, anchor: .bottom) }
                }
                .onChange(of: model.transcript.last?.text) { _, _ in
                    proxy.scrollTo(model.transcript.last?.id, anchor: .bottom)
                }
            }
            if let error = model.error {
                AssistantNotice(message: error, showsSettings: error == AssistantTasks.setupMessage)
                    .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.xs)
            }
            Hairline()
            inputBar
            usageFooter
        }
    }

    private var header: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("Assistant").font(Design.Typeface.headline)
            Spacer(minLength: 0)
            Menu {
                Button("Summarize This Page") { model.summarizePage() }
                Button("Summarize the Report") { model.summarizeReport() }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.isStreaming)
            .help("Summarize the current page or the whole report")
            Menu {
                ForEach(AssistantModel.allCases, id: \.id) { m in
                    Button(m.displayName) { model.setAssistantModel(m) }
                }
            } label: {
                Label(model.client.configuration.modelID, systemImage: "cpu")
                    .font(Design.Typeface.caption)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("The Claude model the assistant uses")
            Button {
                model.clear()
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Clear the conversation")
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }

    private var inputBar: some View {
        HStack(spacing: Design.Space.xs) {
            TextField("Ask about your data…", text: $model.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { model.send() }
            if model.isStreaming {
                Button { model.cancel() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.plain).help("Stop")
            } else {
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
            }
        }
        .padding(Design.Space.m)
    }

    private var usageFooter: some View {
        HStack(spacing: Design.Space.s) {
            Spacer()
            Text("↑ \(model.usage.inputTokens)  ↓ \(model.usage.outputTokens) tokens")
                .font(Design.Typeface.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.xs)
    }
}

// MARK: - Suggestions

/// What to ask first: the summary shortcuts, the author's verified questions, and questions about the model.
private struct AssistantSuggestions: View {
    let store: DocumentStore
    @ObservedObject var model: AssistantPaneModel

    private var questions: [String] {
        let verified = store.model.verifiedAnswers.map(\.question).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let suggested = QuestionParser.suggestedQuestions(store.model, limit: 4)
        var out: [String] = []
        for q in verified + suggested where !out.contains(q) && out.count < 5 { out.append(q) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Ask about your data, ask for DAX, or describe a visual or a page to create.")
                .font(Design.Typeface.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SectionLabel("Try")
            FlowLayout(spacing: 6, lineSpacing: 4) {
                Button("Summarize this page") { model.summarizePage() }
                    .help("Summarize what the current page shows")
                Button("Summarize the report") { model.summarizeReport() }
                    .help("Summarize every visible page")
                ForEach(questions, id: \.self) { q in
                    Button(q) { model.send(q) }.help("Ask this question")
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

// MARK: - First-run setup

private struct SetupCard: View {
    let model: AssistantPaneModel
    @State private var key = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Label("Assistant", systemImage: "sparkles").font(Design.Typeface.headline)
            Text("The assistant runs on the Claude API. Create a key at console.anthropic.com and paste it here, or in Settings ▸ Assistant. It is stored in your Keychain and sent only to the Anthropic API.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Key") {
                    do { try model.saveAPIKey(key); status = "Key saved."; key = "" }
                    catch { status = "Couldn't save the key: \(error.localizedDescription)" }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Store the key in your Keychain")
                Button("Open Settings…") { AssistantTasks.openSettings() }
                    .help("Choose the model and effort in Settings ▸ Assistant")
            }
            if let status { Text(status).font(Design.Typeface.caption).foregroundStyle(.secondary) }
            if let console = URL(string: "https://console.anthropic.com") {
                Link("Create a key at console.anthropic.com", destination: console)
                    .font(Design.Typeface.caption)
                    .help("Opens the Anthropic console in your browser")
            }
            Spacer()
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Transcript rows

private struct ChatRow: View {
    let entry: AssistantPaneModel.ChatEntry
    let show: (AssistantPaneModel.VerifiedLink) -> Void

    var body: some View {
        switch entry.role {
        case .user:
            HStack(alignment: .top, spacing: Design.Space.xs) {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(Design.Space.s)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Color.accentColor.opacity(0.16)))
            }
        case .assistant:
            HStack(alignment: .top, spacing: Design.Space.xs) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Color.accentColor).padding(.top, 2)
                Text(entry.text.isEmpty && entry.isStreaming ? "…" : entry.text)
                    .textSelection(.enabled)
                    .font(Design.Typeface.body)
                Spacer(minLength: 20)
            }
        case .verified:
            if let link = entry.verified { verified(link) }
        case .tool:
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: entry.toolDone ? (entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill") : "gear")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.isError ? Design.Palette.negative : (entry.toolDone ? Design.Palette.positive : Color.secondary))
                    Text(entry.toolName ?? "Tool").font(Design.Typeface.captionStrong)
                    if !entry.toolDone { ProgressView().controlSize(.mini) }
                }
                if let output = entry.toolOutput, !output.isEmpty {
                    Text(output).font(Design.Typeface.mono)
                        .foregroundStyle(.secondary).lineLimit(8)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Design.Palette.fill))
                }
                if let input = entry.toolInput, !input.isEmpty {
                    Text(input).font(Design.Typeface.mono).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            .padding(.leading, 20)
        }
    }

    private func verified(_ link: AssistantPaneModel.VerifiedLink) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Label("Verified answer", systemImage: "checkmark.seal.fill")
                .font(Design.Typeface.captionStrong).foregroundStyle(Design.Palette.positive)
            Text(link.question).font(Design.Typeface.caption).foregroundStyle(.secondary)
            if let title = link.visualTitle, link.visualID != nil {
                Button("Show “\(title)”") { show(link) }
                    .buttonStyle(.link).font(Design.Typeface.caption)
                    .help("Open the page with the visual the model's author verified for this question")
            }
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
    }
}
