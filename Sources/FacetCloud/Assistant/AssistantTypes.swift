import Foundation
import FacetCore

/// Claude models offered for Facet's assistant. IDs are the exact Claude API model strings.
public enum AssistantModel: Hashable, Sendable, CaseIterable {
    /// Claude Sonnet 5.5 — the default: fast and capable for everyday report authoring.
    case sonnet
    /// Claude Opus 5.5 — strongest reasoning.
    case opus
    /// Claude Haiku 5.5 — fastest and cheapest.
    case haiku

    public var id: String {
        switch self {
        case .sonnet: return "claude-sonnet-5-5"
        case .opus: return "claude-opus-5-5"
        case .haiku: return "claude-haiku-5-5"
        }
    }
    public var displayName: String {
        switch self {
        case .sonnet: return "Claude Sonnet 5.5"
        case .opus: return "Claude Opus 5.5"
        case .haiku: return "Claude Haiku 5.5"
        }
    }
    public static let `default` = AssistantModel.sonnet

    /// Models on which the API accepts the server-side refusal `fallbacks` parameter.
    static func supportsServerFallback(_ modelID: String) -> Bool {
        ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-fable-5-2"].contains(modelID)
    }
    /// Models that accept `{"role": "system"}` messages inside `messages`.
    static func supportsMidConversationSystem(_ modelID: String) -> Bool {
        modelID.hasPrefix("claude-sonnet-5-5") || modelID.hasPrefix("claude-opus-5") || modelID.hasPrefix("claude-opus-4-8")
            || modelID.hasPrefix("claude-haiku-5-5") || modelID.hasPrefix("claude-fable-5") || modelID.hasPrefix("claude-mythos-5")
    }
}

/// Assistant settings. Persisted in `UserDefaults`; the API key is stored separately in the Keychain.
public struct AssistantConfiguration: Codable, Equatable, Sendable {
    public enum Effort: String, Codable, CaseIterable, Sendable { case low, medium, high, xhigh, max }

    /// Claude model ID. Defaults to Claude Sonnet 5.5; any Claude API model ID is accepted.
    public var modelID: String = AssistantModel.default.id
    /// Upper bound on tokens generated per response.
    public var maxOutputTokens: Int = 64_000
    /// Thinking depth / token spend. `nil` uses the model's default.
    public var effort: Effort?
    /// Ask the API to re-run a request that a safety classifier declined on Anthropic's recommended fallback
    /// model (server-side `fallbacks: "default"`, a beta feature). Applies only to models that support it.
    public var refusalFallback = true
    /// Stream readable summaries of the model's reasoning (`thinking.display = "summarized"`).
    public var showThinkingSummaries = false
    /// Approximate token budget for conversation history before old turns are trimmed.
    public var historyTokenBudget = 400_000
    /// Maximum tool-use rounds in one user turn.
    public var maxToolRounds = 30
    /// Run a response's tool calls concurrently. Off by default so authoring tools apply in the order requested.
    public var parallelToolExecution = false

    public init() {}

    public var model: AssistantModel? { AssistantModel.allCases.first { $0.id == modelID } }

    public static let defaultsKey = "com.facet.assistant.configuration"
    public static func load(from defaults: UserDefaults = .standard) -> AssistantConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let c = try? JSONDecoder().decode(AssistantConfiguration.self, from: data) else { return AssistantConfiguration() }
        return c
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Errors from the assistant client.
public enum AssistantError: LocalizedError, Equatable {
    /// No API key has been saved.
    case notConfigured
    /// The API key was rejected (HTTP 401).
    case authentication(message: String, requestID: String?)
    /// The key lacks permission for the model or feature (HTTP 403).
    case permissionDenied(message: String, requestID: String?)
    /// Rate limited (HTTP 429). `retryAfter` is the server's suggested wait in seconds.
    case rateLimited(retryAfter: TimeInterval?, message: String, requestID: String?)
    /// The API is temporarily overloaded (HTTP 529 or an `overloaded_error` event).
    case overloaded(retryAfter: TimeInterval?, requestID: String?)
    /// The request was malformed or unsupported (HTTP 400/404/413/422).
    case invalidRequest(message: String, requestID: String?)
    case server(status: Int, message: String, requestID: String?)
    case network(String)
    case invalidResponse(String)
    /// The model kept calling tools past `maxToolRounds`.
    case toolRoundLimit(Int)

    public var errorDescription: String? {
        func rid(_ id: String?) -> String { id.map { " Request ID: \($0)." } ?? "" }
        switch self {
        case .notConfigured:
            return "The assistant is not set up. Add your Anthropic API key in \(AppIdentity.name)'s Assistant settings (create one at console.anthropic.com)."
        case .authentication(let m, let id):
            return "The Anthropic API key was not accepted. Check the key in Assistant settings. \(m)" + rid(id)
        case .permissionDenied(let m, let id):
            return "This API key is not allowed to do that. \(m)" + rid(id)
        case .rateLimited(let retry, let m, let id):
            let wait = retry.map { " Try again in about \(Int($0.rounded(.up))) seconds." } ?? " Try again shortly."
            return "The assistant is being rate limited.\(wait) \(m)" + rid(id)
        case .overloaded(let retry, let id):
            let wait = retry.map { " Try again in about \(Int($0.rounded(.up))) seconds." } ?? " Try again in a moment."
            return "Claude is temporarily overloaded.\(wait)" + rid(id)
        case .invalidRequest(let m, let id):
            return "The assistant request was not accepted: \(m)" + rid(id)
        case .server(let status, let m, let id):
            return "The assistant service had a problem (HTTP \(status)). \(m)" + rid(id)
        case .network(let m):
            return "Could not reach the assistant service: \(m)"
        case .invalidResponse(let m):
            return "The assistant service sent a response \(AppIdentity.name) could not read (\(m))."
        case .toolRoundLimit(let n):
            return "The assistant stopped after \(n) rounds of tool use without finishing. Ask it to continue if needed."
        }
    }

    /// Whether retrying the same request later can succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: return true
        case .server(let status, _, _): return status >= 500
        default: return false
        }
    }

    /// Maps an HTTP error response (`{"type":"error","error":{"type","message"},"request_id"}`) to a typed error.
    static func from(status: Int, body: Data, headers: (String) -> String?) -> AssistantError {
        let json = (try? JSONValue.parse(body)) ?? .null
        let type = json["error"]?["type"]?.stringValue ?? ""
        let message = json["error"]?["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let requestID = json["request_id"]?.stringValue ?? headers("request-id")
        let retryAfter = headers("retry-after").flatMap(Double.init)
        return classify(status: status, type: type, message: message, requestID: requestID, retryAfter: retryAfter)
    }

    static func classify(status: Int, type: String, message: String, requestID: String?, retryAfter: TimeInterval?) -> AssistantError {
        if type == "overloaded_error" || status == 529 { return .overloaded(retryAfter: retryAfter, requestID: requestID) }
        if type == "rate_limit_error" || status == 429 { return .rateLimited(retryAfter: retryAfter, message: message, requestID: requestID) }
        if type == "authentication_error" || status == 401 { return .authentication(message: message, requestID: requestID) }
        if type == "permission_error" || type == "billing_error" || status == 403 || status == 402 {
            return .permissionDenied(message: message, requestID: requestID)
        }
        if type == "invalid_request_error" || type == "not_found_error" || type == "request_too_large" || (400..<500).contains(status) {
            return .invalidRequest(message: message, requestID: requestID)
        }
        return .server(status: status, message: message, requestID: requestID)
    }
}

/// Token accounting for one response (or summed over a turn).
public struct AssistantUsage: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    /// Tokens written to the prompt cache.
    public var cacheCreationInputTokens = 0
    /// Tokens served from the prompt cache. Zero across repeated requests means caching is not taking effect.
    public var cacheReadInputTokens = 0
    public init() {}

    static func + (a: AssistantUsage, b: AssistantUsage) -> AssistantUsage {
        var u = AssistantUsage()
        u.inputTokens = a.inputTokens + b.inputTokens
        u.outputTokens = a.outputTokens + b.outputTokens
        u.cacheCreationInputTokens = a.cacheCreationInputTokens + b.cacheCreationInputTokens
        u.cacheReadInputTokens = a.cacheReadInputTokens + b.cacheReadInputTokens
        return u
    }

    mutating func merge(_ json: JSONValue?) {
        guard let json else { return }
        if let v = json["input_tokens"]?.intValue { inputTokens = Int(v) }
        if let v = json["output_tokens"]?.intValue { outputTokens = Int(v) }
        if let v = json["cache_creation_input_tokens"]?.intValue { cacheCreationInputTokens = Int(v) }
        if let v = json["cache_read_input_tokens"]?.intValue { cacheReadInputTokens = Int(v) }
    }
}

public enum AssistantStopReason: Equatable, Sendable {
    case endTurn, toolUse, maxTokens, stopSequence
    /// A server-side loop paused; the request is re-sent to continue.
    case pauseTurn
    /// The model or a safety classifier declined the request.
    case refusal
    case other(String)

    init(_ raw: String?) {
        switch raw {
        case "end_turn": self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "pause_turn": self = .pauseTurn
        case "refusal": self = .refusal
        default: self = .other(raw ?? "unknown")
        }
    }
}

/// One conversation message. `content` holds the raw API content blocks so that everything the model
/// produced (including thinking blocks and their signatures) is sent back unchanged on later requests.
public struct AssistantMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant, system }
    public var role: Role
    public var content: [JSONValue]

    public init(role: Role, content: [JSONValue]) { self.role = role; self.content = content }
    public static func user(_ text: String) -> AssistantMessage {
        AssistantMessage(role: .user, content: [["type": "text", "text": .string(text)]])
    }

    /// The concatenated visible text of the message.
    public var text: String {
        content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
    }
    /// Tool calls requested in this message.
    public var toolCalls: [AssistantToolCall] {
        content.compactMap { b in
            guard b["type"]?.stringValue == "tool_use", let id = b["id"]?.stringValue, let name = b["name"]?.stringValue else { return nil }
            return AssistantToolCall(id: id, name: name, input: b["input"] ?? [:])
        }
    }
    /// True for user messages that only carry tool results.
    public var isToolResult: Bool {
        role == .user && !content.isEmpty && content.allSatisfy { $0["type"]?.stringValue == "tool_result" }
    }

    var json: JSONValue {
        if role == .system { return ["role": "system", "content": .string(text)] }
        return ["role": .string(role.rawValue), "content": .array(content)]
    }
}

/// A tool call requested by the model.
public struct AssistantToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The parsed JSON input (always an object).
    public let input: JSONValue
}

/// What a tool handler returns to the model.
public struct AssistantToolOutput: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    public init(_ content: String, isError: Bool = false) { self.content = content; self.isError = isError }
    public static func error(_ message: String) -> AssistantToolOutput { AssistantToolOutput(message, isError: true) }
    /// Returns a JSON-serialisable value as the tool result.
    public static func json(_ value: JSONValue) -> AssistantToolOutput { AssistantToolOutput(value.serialized()) }
}

/// A tool the app exposes to the assistant: a name, a description, a JSON Schema for the input, and a handler.
public struct AssistantTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema (`{"type":"object","properties":{…},"required":[…]}`).
    public let inputSchema: JSONValue
    /// Executes the tool. Thrown errors are reported to the model as error results, so it can recover.
    public let handler: @Sendable (JSONValue) async throws -> AssistantToolOutput

    public init(name: String, description: String, inputSchema: JSONValue,
                handler: @escaping @Sendable (JSONValue) async throws -> AssistantToolOutput) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.handler = handler
    }

    var definition: JSONValue {
        // eager_input_streaming: tool inputs stream as generated instead of being buffered server-side;
        // the client therefore parses strictly and validates against the schema before running the tool.
        ["name": .string(name), "description": .string(description), "eager_input_streaming": true, "input_schema": inputSchema]
    }
}

/// A complete model response.
public struct AssistantResponse: Sendable, Equatable {
    public var id: String?
    public var model: String?
    public var message: AssistantMessage
    public var stopReason: AssistantStopReason
    /// For refusals: the policy category (e.g. `cyber`), when given.
    public var refusalCategory: String?
    public var refusalExplanation: String?
    public var usage: AssistantUsage
    /// Tool-use ids whose streamed input was not valid JSON, mapped to the raw text received.
    public var invalidToolInputs: [String: String]
}

/// Events surfaced while the assistant responds.
public enum AssistantEvent: Sendable, Equatable {
    /// Incremental visible text.
    case textDelta(String)
    /// Incremental reasoning summary (only when `showThinkingSummaries` is on).
    case thinkingDelta(String)
    /// The model began composing a tool call.
    case toolCallStarted(id: String, name: String)
    /// A tool call is fully received and about to run.
    case toolCall(AssistantToolCall)
    /// A tool finished; its output is being sent back to the model.
    case toolResult(callID: String, name: String, output: AssistantToolOutput)
    /// One API response finished (a turn with tool use has several).
    case responseFinished(AssistantResponse)
    /// Older conversation turns were dropped to stay within the history budget.
    case historyTrimmed(removedMessages: Int)
    /// The whole user turn is done.
    case turnFinished(stopReason: AssistantStopReason, usage: AssistantUsage)
}
