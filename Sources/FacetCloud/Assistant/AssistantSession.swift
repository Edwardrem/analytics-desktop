import Foundation
import Combine
import FacetCore

/// A conversation with the assistant: owns the system prompt, the history, the registered tools, and runs
/// the tool-use loop (stream a response → execute requested tools → send results back → repeat).
///
/// The system prompt and the tool set are fixed for the lifetime of a session. That keeps the prompt cache
/// warm and keeps the model's earlier reasoning blocks valid (the API ties them to an unchanged prefix).
/// To tell the model about something that changed mid-conversation (for example, the user edited the data
/// model), call `addNote(_:)`; to change instructions or tools, start a new session.
@MainActor
public final class AssistantSession: ObservableObject {
    /// The conversation so far, including tool calls and results.
    @Published public private(set) var history: [AssistantMessage] = []
    @Published public private(set) var isResponding = false
    /// Usage summed over the session.
    @Published public private(set) var totalUsage = AssistantUsage()

    public let client: AssistantClient
    public let instructions: String
    /// The large, stable description of the semantic model; sent as a prompt-cached system block.
    public let modelSchema: String
    public let tools: [AssistantTool]

    private var pendingNotes: [String] = []
    private var currentTask: Task<Void, Never>?

    /// - Parameters:
    ///   - instructions: behavioural instructions for the assistant (stable for the session).
    ///   - modelSchema: description of the user's semantic model (see `AssistantPrompt.describe(_:)`). Cached.
    ///   - tools: tools the model may call (`run_dax`, `create_visual`, …).
    public init(client: AssistantClient, instructions: String, modelSchema: String = "", tools: [AssistantTool] = []) {
        self.client = client
        self.instructions = instructions
        self.modelSchema = modelSchema
        self.tools = tools
    }

    private var system: [AssistantSystemBlock] {
        // Stable content first; the cache breakpoint sits on the last system block.
        if modelSchema.isEmpty { return [AssistantSystemBlock(instructions, cache: true)] }
        return [AssistantSystemBlock(instructions), AssistantSystemBlock(modelSchema, cache: true)]
    }

    /// Queues an operator note (e.g. "The user added a measure 'Margin %' to Sales") that is delivered with the
    /// next user message, without rewriting the system prompt or earlier history.
    public func addNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { pendingNotes.append(t) }
    }

    /// Clears the conversation (keeps instructions, schema and tools).
    public func reset() {
        cancel()
        history = []
        pendingNotes = []
        totalUsage = AssistantUsage()
    }

    /// Cancels the response in progress, if any. The stream returned by `send` finishes by throwing `CancellationError`.
    public func cancel() {
        currentTask?.cancel()
    }

    /// Sends a user message and streams the assistant's turn, running tools as the model requests them.
    ///
    /// The stream yields text deltas, tool calls and results, one `.responseFinished` per API response, and ends with
    /// `.turnFinished`. Errors are thrown as `AssistantError` (`.notConfigured` when no API key is stored).
    public func send(_ text: String) -> AsyncThrowingStream<AssistantEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !isResponding else {
                continuation.finish(throwing: AssistantError.invalidRequest(message: "The assistant is still responding to the previous message.", requestID: nil))
                return
            }
            guard client.isConfigured else {
                continuation.finish(throwing: AssistantError.notConfigured)
                return
            }
            isResponding = true
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                defer { self.isResponding = false; self.currentTask = nil }
                do {
                    try await self.runTurn(userText: text) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            currentTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Turn loop

    private func runTurn(userText: String, emit: @escaping (AssistantEvent) -> Void) async throws {
        let configuration = client.configuration
        var userContent: [JSONValue] = [["type": "text", "text": .string(userText)]]
        var noteMessage: AssistantMessage?
        if !pendingNotes.isEmpty {
            let note = pendingNotes.joined(separator: "\n")
            pendingNotes = []
            if AssistantModel.supportsMidConversationSystem(configuration.modelID) {
                noteMessage = AssistantMessage(role: .system, content: [["type": "text", "text": .string(note)]])
            } else {
                userContent.append(["type": "text", "text": .string("<app_note>\n\(note)\n</app_note>")])
            }
        }
        let historyCountBeforeTurn = history.count
        history.append(AssistantMessage(role: .user, content: userContent))
        if let noteMessage { history.append(noteMessage) }

        var turnUsage = AssistantUsage()
        var rounds = 0
        while true {
            try Task.checkCancellation()
            let trimmed = HistoryTrimmer.trim(history, budgetTokens: configuration.historyTokenBudget)
            if trimmed.removed > 0 {
                history = trimmed.messages
                emit(.historyTrimmed(removedMessages: trimmed.removed))
            }
            var response: AssistantResponse?
            for try await event in client.stream(AssistantRequest(system: system, messages: history, tools: tools)) {
                if case .responseFinished(let r) = event { response = r }
                emit(event)
            }
            guard let response else { throw AssistantError.invalidResponse("the response ended without a message") }
            turnUsage = turnUsage + response.usage
            totalUsage = totalUsage + response.usage

            switch response.stopReason {
            case .refusal:
                // Partial output from a declined request is discarded, never treated as complete.
                if rounds == 0, history.count > historyCountBeforeTurn { history.removeSubrange(historyCountBeforeTurn...) }
                emit(.turnFinished(stopReason: .refusal, usage: turnUsage))
                return
            case .pauseTurn:
                // A server-side loop paused: append the partial turn and re-send; the API resumes it.
                appendAssistant(response.message.content)
                continue
            case .toolUse:
                let calls = response.message.toolCalls
                guard !calls.isEmpty else {
                    appendAssistant(response.message.content)
                    emit(.turnFinished(stopReason: .toolUse, usage: turnUsage))
                    return
                }
                appendAssistant(response.message.content)
                let results = await execute(calls, invalid: response.invalidToolInputs, parallel: configuration.parallelToolExecution, emit: emit)
                // All results go back in ONE user message, in call order.
                history.append(AssistantMessage(role: .user, content: results))
                try Task.checkCancellation()
                rounds += 1
                if rounds >= configuration.maxToolRounds { throw AssistantError.toolRoundLimit(rounds) }
            case .maxTokens, .endTurn, .stopSequence, .other:
                // A tool call cut off by max_tokens is incomplete: never run it, and don't keep it in history
                // (an unanswered tool_use would make the next request invalid).
                let content = response.message.content.filter { $0["type"]?.stringValue != "tool_use" }
                appendAssistant(content)
                emit(.turnFinished(stopReason: response.stopReason, usage: turnUsage))
                return
            }
        }
    }

    private func appendAssistant(_ content: [JSONValue]) {
        // The API rejects empty assistant messages and empty text blocks.
        let cleaned = content.filter { !($0["type"]?.stringValue == "text" && ($0["text"]?.stringValue ?? "").isEmpty) }
        guard !cleaned.isEmpty else { return }
        history.append(AssistantMessage(role: .assistant, content: cleaned))
    }

    /// Runs tool calls and returns one `tool_result` block per call, in call order. Never throws: failures,
    /// invalid input and cancellation all become error results so the history stays well-formed.
    private func execute(_ calls: [AssistantToolCall], invalid: [String: String], parallel: Bool,
                         emit: @escaping (AssistantEvent) -> Void) async -> [JSONValue] {
        let toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        @Sendable func run(_ call: AssistantToolCall) async -> AssistantToolOutput {
            if let raw = invalid[call.id] {
                return .error(JSONValue.object([JSONMember(key: "INVALID_JSON", value: .string(raw))]).serialized())
            }
            guard let tool = toolsByName[call.name] else { return .error("Unknown tool '\(call.name)'.") }
            if let problem = ToolInputValidator.validate(call.input, against: tool.inputSchema) {
                return .error("Invalid input: \(problem).")
            }
            if Task.isCancelled { return .error("Cancelled by the user before this tool ran.") }
            do { return try await tool.handler(call.input) }
            catch is CancellationError { return .error("Cancelled by the user.") }
            catch { return .error(error.localizedDescription) }
        }

        var outputs = [AssistantToolOutput?](repeating: nil, count: calls.count)
        if parallel, calls.count > 1 {
            await withTaskGroup(of: (Int, AssistantToolOutput).self) { group in
                for (i, call) in calls.enumerated() { group.addTask { (i, await run(call)) } }
                for await (i, output) in group {
                    outputs[i] = output
                    emit(.toolResult(callID: calls[i].id, name: calls[i].name, output: output))
                }
            }
        } else {
            for (i, call) in calls.enumerated() {
                let output = await run(call)
                outputs[i] = output
                emit(.toolResult(callID: call.id, name: call.name, output: output))
            }
        }
        return zip(calls, outputs).map { call, output in
            let o = output ?? .error("The tool did not produce a result.")
            var block: JSONValue = ["type": "tool_result", "tool_use_id": .string(call.id), "content": .string(o.content.isEmpty ? "(no output)" : o.content)]
            if o.isError { block = block.setting("is_error", to: true) }
            return block
        }
    }
}

/// Keeps conversation history within a token budget.
///
/// Trimming is done rarely and in bulk (down to 60% of the budget) because every trim invalidates the prompt
/// cache. Only whole turns are removed, starting from the oldest, so tool calls and their results stay paired.
/// Since removing earlier messages changes the prefix that the model's reasoning blocks are bound to, reasoning
/// blocks are stripped from the retained messages (the API permits removing all of them).
public enum HistoryTrimmer {
    /// Rough token estimate (about 3.5 UTF-8 bytes per token). Use `AssistantClient.countTokens` for exact numbers.
    public static func estimateTokens(_ message: AssistantMessage) -> Int {
        Int((Double(message.json.serialized().utf8.count) / 3.5).rounded(.up))
    }
    public static func estimateTokens(_ messages: [AssistantMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    public static func trim(_ messages: [AssistantMessage], budgetTokens: Int, targetFraction: Double = 0.6) -> (messages: [AssistantMessage], removed: Int) {
        let sizes = messages.map(estimateTokens)
        var total = sizes.reduce(0, +)
        guard total > budgetTokens, budgetTokens > 0 else { return (messages, 0) }
        let target = Int(Double(budgetTokens) * targetFraction)
        // Candidate cut points: indices where a real user turn starts (not a tool-result message).
        let turnStarts = messages.indices.filter { messages[$0].role == .user && !messages[$0].isToolResult }
        guard let lastStart = turnStarts.last, lastStart > 0 else { return (messages, 0) }
        var cut = 0
        var dropped = 0
        for start in turnStarts.dropFirst(turnStarts.first == 0 ? 1 : 0) {
            // Drop everything before `start`.
            dropped = sizes[..<start].reduce(0, +)
            cut = start
            if total - dropped <= target || start == lastStart { break }
        }
        guard cut > 0 else { return (messages, 0) }
        total -= dropped
        let kept = messages[cut...].compactMap { m -> AssistantMessage? in
            guard m.role == .assistant else { return m }
            let content = m.content.filter { b in
                let t = b["type"]?.stringValue
                return t != "thinking" && t != "redacted_thinking"
            }
            return content.isEmpty ? nil : AssistantMessage(role: .assistant, content: content)
        }
        return (kept, messages.count - kept.count)
    }
}

/// Helpers for building the assistant's stable system-prompt blocks.
public enum AssistantPrompt {
    /// A deterministic, compact text description of a semantic model for the cached system block:
    /// tables, columns (type, format, description), measures with their DAX, and relationships.
    /// Fields listed in `aiExcludedFields` and hidden objects are left out; `aiInstructions` are appended.
    public static func describe(_ model: SemanticModel, includeHidden: Bool = false) -> String {
        let excluded = Set(model.aiExcludedFields.map { $0.lowercased() })
        func isExcluded(_ table: String, _ field: String? = nil) -> Bool {
            if excluded.contains(table.lowercased()) { return true }
            guard let field else { return false }
            return excluded.contains("\(table)[\(field)]".lowercased())
        }
        var out = "# Semantic model: \(model.name)\n"
        for t in model.tables where (includeHidden || !t.isHidden) && !isExcluded(t.name) {
            out += "\n## Table '\(t.name)'"
            if t.isDateTable { out += " (date table)" }
            out += "\n"
            if !t.description.isEmpty { out += "\(t.description)\n" }
            let columns = t.columns.filter { (includeHidden || !$0.isHidden) && !isExcluded(t.name, $0.name) }
            if !columns.isEmpty { out += "Columns:\n" }
            for c in columns {
                out += "- '\(t.name)'[\(c.name)]: \(c.dataType.rawValue)"
                if !c.formatString.isEmpty { out += ", format \(c.formatString)" }
                if c.dataCategory != .uncategorized { out += ", category \(c.dataCategory.rawValue)" }
                if let e = c.expression { out += ", calculated = \(e)" }
                if !c.description.isEmpty { out += " — \(c.description)" }
                out += "\n"
            }
            let measures = t.measures.filter { (includeHidden || !$0.isHidden) && !isExcluded(t.name, $0.name) }
            if !measures.isEmpty { out += "Measures:\n" }
            for m in measures {
                out += "- [\(m.name)] = \(m.expression.replacingOccurrences(of: "\n", with: " "))"
                if !m.formatString.isEmpty { out += " (format \(m.formatString))" }
                if !m.description.isEmpty { out += " — \(m.description)" }
                out += "\n"
            }
        }
        if !model.relationships.isEmpty {
            out += "\n## Relationships\n"
            for r in model.relationships where !isExcluded(r.fromTable) && !isExcluded(r.toTable) {
                out += "- '\(r.fromTable)'[\(r.fromColumn)] → '\(r.toTable)'[\(r.toColumn)] (\(r.cardinality.rawValue), \(r.crossFilter.rawValue) direction\(r.isActive ? "" : ", inactive"))\n"
            }
        }
        if !model.aiInstructions.isEmpty { out += "\n## Instructions from the model author\n\(model.aiInstructions)\n" }
        return out
    }
}
