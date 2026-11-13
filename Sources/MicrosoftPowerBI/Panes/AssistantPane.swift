import SwiftUI
import FacetCore
import FacetQuery
import FacetCloud
import FacetDesign

/// The Assistant pane: chat alongside the report with tools that run DAX, inspect the model,
/// and create visuals or measures. Backed by the Claude assistant in FacetCloud.
struct AssistantPane: View {
    let store: DocumentStore
    @StateObject private var model: AssistantPaneModel

    init(store: DocumentStore) {
        self.store = store
        _model = StateObject(wrappedValue: AssistantPaneModel(store: store))
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
                            Text("Ask about your data, ask for DAX, or describe a visual to create.")
                                .font(Design.Typeface.body).foregroundStyle(.secondary)
                        }
                        ForEach(model.transcript) { entry in
                            ChatRow(entry: entry)
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
                Text(error).font(Design.Typeface.caption).foregroundStyle(.red)
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
                ForEach(AssistantModel.allCases, id: \.id) { m in
                    Button(m.displayName) { model.setAssistantModel(m) }
                }
            } label: {
                Label(model.client.configuration.modelID, systemImage: "cpu")
                    .font(Design.Typeface.caption)
            }
            .menuStyle(.borderlessButton).fixedSize()
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

// MARK: - First-run setup

private struct SetupCard: View {
    let model: AssistantPaneModel
    @State private var key = ""
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Label("Assistant", systemImage: "sparkles").font(Design.Typeface.headline)
            Text("The assistant runs on the Claude API. Create a key at console.anthropic.com and paste it here — it is stored in your Keychain and sent only to the Anthropic API.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Key") {
                    do { try model.saveAPIKey(key); status = "Key saved."; key = "" }
                    catch { status = "Couldn't save the key: \(error.localizedDescription)" }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if let status { Text(status).font(Design.Typeface.caption).foregroundStyle(.secondary) }
            }
            Link("Create a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com")!)
                .font(Design.Typeface.caption)
            Spacer()
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Transcript rows

private struct ChatRow: View {
    let entry: AssistantPaneModel.ChatEntry

    var body: some View {
        switch entry.role {
        case .user:
            HStack(alignment: .top, spacing: Design.Space.xs) {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(Design.Space.s)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.16)))
            }
        case .assistant:
            HStack(alignment: .top, spacing: Design.Space.xs) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Color.accentColor).padding(.top, 2)
                Text(entry.text.isEmpty && entry.isStreaming ? "…" : entry.text)
                    .textSelection(.enabled)
                    .font(Design.Typeface.body)
                Spacer(minLength: 20)
            }
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: entry.toolDone ? (entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill") : "gear")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.isError ? Color.red : (entry.toolDone ? Color.green : Color.secondary))
                    Text(entry.toolName ?? "Tool").font(Design.Typeface.captionStrong)
                    if !entry.toolDone { ProgressView().controlSize(.mini) }
                }
                if let output = entry.toolOutput, !output.isEmpty {
                    Text(output).font(Design.Typeface.mono)
                        .foregroundStyle(.secondary).lineLimit(8)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Design.Palette.fill))
                }
                if let input = entry.toolInput, !input.isEmpty {
                    Text(input).font(Design.Typeface.mono).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            .padding(.leading, 20)
        }
    }
}

// MARK: - Model

@MainActor
final class AssistantPaneModel: ObservableObject {
    struct ChatEntry: Identifiable {
        enum Role { case user, assistant, tool }
        let id = UUID()
        var role: Role
        var text: String = ""
        var toolName: String?
        var toolCallID: String?
        var toolInput: String?
        var toolOutput: String?
        var toolDone = false
        var isError = false
        var isStreaming = false
    }

    @Published var transcript: [ChatEntry] = []
    @Published var input = ""
    @Published var isStreaming = false
    @Published var hasKey: Bool
    @Published var error: String?
    @Published var usage = AssistantUsage()

    let client: AssistantClient
    let session: AssistantSession
    private var turnTask: Task<Void, Never>?

    static let instructions = """
    You are the assistant built into \(AppIdentity.name) for Mac. You help analyse data, write DAX, and build reports.
    Prefer running a DAX query with run_dax to answer questions about the data, then describe the result.
    Use get_model_schema when unsure what tables, columns or measures exist.
    Use add_visual to create a visual on the report page when the user asks for one, and add_measure to add a measure.
    Be concise.
    """

    init(store: DocumentStore) {
        client = AssistantClient()
        hasKey = client.isConfigured
        session = AssistantSession(client: client, instructions: Self.instructions,
                                   modelSchema: AssistantPrompt.describe(store.model), tools: Self.tools(for: store))
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        error = nil
        transcript.append(ChatEntry(role: .user, text: text))
        transcript.append(ChatEntry(role: .assistant, text: "", isStreaming: true))
        isStreaming = true
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in session.send(text) { apply(event) }
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if let last = transcript.last, last.role == .assistant, last.text.isEmpty { transcript.removeLast() }
            }
            isStreaming = false
        }
    }

    func cancel() {
        turnTask?.cancel()
        session.cancel()
        isStreaming = false
    }

    func clear() {
        cancel()
        session.reset()
        transcript = []
        usage = AssistantUsage()
        error = nil
    }

    func saveAPIKey(_ key: String) throws {
        try client.setAPIKey(key)
        hasKey = client.isConfigured
    }

    func setAssistantModel(_ m: AssistantModel) {
        client.configuration.modelID = m.id
        client.configuration.save(to: .standard)
    }

    /// Re-reads the configuration after the user changed it in settings.
    func applyConfigurationChange() {
        client.configuration = AssistantConfiguration.load()
        hasKey = client.isConfigured
    }

    private func apply(_ event: AssistantEvent) {
        switch event {
        case .textDelta(let t):
            if let i = transcript.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                transcript[i].text += t
            }
        case .toolCallStarted(let id, let name):
            transcript.append(ChatEntry(role: .tool, toolName: name, toolCallID: id))
        case .toolCall(let call):
            if let i = transcript.lastIndex(where: { $0.toolCallID == call.id }) {
                transcript[i].toolInput = call.input.serialized()
            }
        case .toolResult(let callID, _, let output):
            if let i = transcript.lastIndex(where: { $0.toolCallID == callID }) {
                transcript[i].toolOutput = output.content
                transcript[i].isError = output.isError
                transcript[i].toolDone = true
            }
        case .turnFinished(_, let u):
            usage = u
        case .thinkingDelta, .responseFinished, .historyTrimmed:
            break
        }
    }

    // MARK: Tools

    private static func tools(for store: DocumentStore) -> [AssistantTool] {
        weak var weakStore = store
        return [
            AssistantTool(name: "run_dax",
                          description: "Runs a DAX query against the model and returns up to 20 result rows per table.",
                          inputSchema: ["type": "object",
                                        "properties": ["dax": ["type": "string"]],
                                        "required": ["dax"]],
                          handler: { input in
                              guard let store = weakStore else { return .error("The document is closed.") }
                              let dax = input["dax"]?.stringValue ?? ""
                              guard !dax.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                  return .error("Provide a DAX query in the \"dax\" property.")
                              }
                              let result: Result<[DataTable], Error> = await store.withEngine { engine in
                                  Result { try engine.query(dax) }
                              }
                              switch result {
                              case .success(let tables): return AssistantToolOutput(Self.describe(tables))
                              case .failure(let e): return .error(MError.wrap(e).description)
                              }
                          }),
            AssistantTool(name: "get_model_schema",
                          description: "Returns a description of the semantic model: tables, columns, measures and relationships.",
                          inputSchema: ["type": "object", "properties": [:]],
                          handler: { _ in
                              guard let store = weakStore else { return .error("The document is closed.") }
                              return await MainActor.run { AssistantToolOutput(AssistantPrompt.describe(store.model)) }
                          }),
            AssistantTool(name: "add_visual",
                          description: "Creates a visual on the current report page. Types: column, bar, line, area, pie, donut, card, table, matrix, scatter.",
                          inputSchema: ["type": "object",
                                        "properties": ["type": ["type": "string"],
                                                       "title": ["type": "string"]],
                                        "required": ["type"]],
                          handler: { input in
                              guard let store = weakStore else { return .error("The document is closed.") }
                              let name = (input["type"]?.stringValue ?? "").lowercased()
                              let title = input["title"]?.stringValue
                              return await MainActor.run {
                                  guard let type = Self.visualType(name) else {
                                      return AssistantToolOutput.error("Unknown visual type \"\(name)\". Use column, bar, line, area, pie, donut, card, table, matrix or scatter.")
                                  }
                                  let id = store.addVisual(type) { v in
                                      if let title, !title.isEmpty { v.name = title }
                                  }
                                  return AssistantToolOutput("Created a \(type.displayName) visual (\(id.uuidString)). The user can now drag fields into it.")
                              }
                          }),
            AssistantTool(name: "add_measure",
                          description: "Adds a DAX measure to a table of the model and recalculates.",
                          inputSchema: ["type": "object",
                                        "properties": ["table": ["type": "string"],
                                                       "name": ["type": "string"],
                                                       "expression": ["type": "string"]],
                                        "required": ["table", "name", "expression"]],
                          handler: { input in
                              guard let store = weakStore else { return .error("The document is closed.") }
                              guard let table = input["table"]?.stringValue, let name = input["name"]?.stringValue,
                                    let expression = input["expression"]?.stringValue else {
                                  return .error("Provide \"table\", \"name\" and \"expression\".")
                              }
                              return await MainActor.run {
                                  guard store.model.table(table) != nil else {
                                      return AssistantToolOutput.error("The table \"\(table)\" was not found.")
                                  }
                                  store.mutate("Add Measure (Assistant)", invalidates: .model) { d in
                                      if let i = d.model.tableIndex(table) {
                                          d.model.tables[i].measures.append(Measure(name: name, expression: expression))
                                      }
                                  }
                                  store.reloadEngine()
                                  return AssistantToolOutput("Added measure [\(name)] to \(table).")
                              }
                          }),
        ]
    }

    nonisolated static func visualType(_ name: String) -> VisualType? {
        switch name {
        case "column", "clusteredcolumn": return .clusteredColumn
        case "bar", "clusteredbar": return .clusteredBar
        case "stackedcolumn": return .stackedColumn
        case "stackedbar": return .stackedBar
        case "line": return .line
        case "area": return .area
        case "pie": return .pie
        case "donut": return .donut
        case "card": return .card
        case "table": return .table
        case "matrix": return .matrix
        case "scatter": return .scatter
        case "treemap": return .treemap
        default: return VisualType(rawValue: name)
        }
    }

    nonisolated private static func describe(_ tables: [DataTable]) -> String {
        var out: [String] = []
        for t in tables {
            out.append(t.columnNames.joined(separator: " | "))
            for row in t.rows.prefix(20) { out.append(row.map { $0.asString }.joined(separator: " | ")) }
            if t.rowCount > 20 { out.append("… \(t.rowCount - 20) more rows") }
        }
        return out.isEmpty ? "(no results)" : out.joined(separator: "\n")
    }
}
