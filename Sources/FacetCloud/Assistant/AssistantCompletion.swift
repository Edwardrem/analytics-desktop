import Foundation

/// A finished one-shot answer: the visible text and what it cost.
public struct AssistantCompletion: Sendable, Equatable {
    public var text: String
    public var stopReason: AssistantStopReason
    public var usage: AssistantUsage
}

extension AssistantClient {
    /// Sends one request without tools and waits for the whole answer.
    ///
    /// For features that need a single reply rather than a conversation (explaining a query, writing a
    /// description). The request still streams, so long answers do not hit HTTP timeouts.
    /// - Throws: `AssistantError.notConfigured` without an API key; `.declined` when the model or a safety
    ///   classifier declined; `.invalidResponse` when the answer is empty or was cut off by the token limit.
    public func complete(system: [AssistantSystemBlock], messages: [AssistantMessage]) async throws -> AssistantCompletion {
        guard isConfigured else { throw AssistantError.notConfigured }
        var response: AssistantResponse?
        for try await event in stream(AssistantRequest(system: system, messages: messages)) {
            if case .responseFinished(let r) = event { response = r }
        }
        guard let response else { throw AssistantError.invalidResponse("the response ended without a message") }
        let text = response.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch response.stopReason {
        case .refusal:
            throw AssistantError.declined(response.refusalExplanation ?? response.refusalCategory)
        case .maxTokens:
            throw AssistantError.invalidResponse("the answer was cut off at the output token limit; raise it in Assistant settings")
        default:
            guard !text.isEmpty else { throw AssistantError.invalidResponse("the answer was empty") }
            return AssistantCompletion(text: text, stopReason: response.stopReason, usage: response.usage)
        }
    }

    /// One user prompt with stable system instructions (prompt-cached) and optional reference context.
    public func complete(instructions: String, context: String = "", prompt: String) async throws -> AssistantCompletion {
        var system = [AssistantSystemBlock(instructions, cache: context.isEmpty)]
        if !context.isEmpty { system.append(AssistantSystemBlock(context, cache: true)) }
        return try await complete(system: system, messages: [.user(prompt)])
    }
}
