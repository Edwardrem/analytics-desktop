import Foundation
import AppKit
import FacetCore
import FacetCloud

/// The assistant in DAX query view: explains the selected query and writes a query from a request, with the
/// model's schema as context. A written query is checked against the model before it reaches a tab.
@MainActor
enum DAXAssistant {
    /// Model answers that fail the check are sent back with the problems this many times before giving up.
    static let repairAttempts = 2

    static func install() {
        DAXAssistantHook.explain = { query, store in try await explain(query, store: store) }
        DAXAssistantHook.write = { request, store in try await write(request, store: store) }
        DAXAssistantHook.fix = { query, error, store in try await fix(query, error: error, store: store) }
    }

    static let explainInstructions = """
    Explain DAX queries to report authors in plain language. Start with one sentence saying what the query \
    returns, then explain the important parts (variables, filters, measures, functions) in a few short \
    bullet points that start with "• ". Refer to the model's tables, columns and measures by name. \
    Do not use Markdown headings or code blocks, and do not rewrite the query.
    """

    static let writeInstructions = """
    Write DAX queries for the semantic model described in the context. Reply with exactly one DAX query in a \
    ```dax code block and nothing else. The query must contain EVALUATE (optionally after DEFINE) and must use \
    only tables, columns and measures that exist in the model, written as 'Table'[Column] and [Measure].
    """

    static let fixInstructions = """
    Fix DAX queries that fail against the semantic model described in the context. Keep the author's intent \
    and change as little as possible. Reply with exactly one corrected DAX query in a ```dax code block and \
    nothing else. The query must contain EVALUATE (optionally after DEFINE) and must use only tables, columns \
    and measures that exist in the model, written as 'Table'[Column] and [Measure].
    """

    static func explain(_ query: String, store: DocumentStore) async throws -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DAXAssistantError.emptyQuery }
        return try await AssistantTasks.ask(explainInstructions, prompt: "Explain this DAX query:\n\n\(text)", store: store)
    }

    /// Writes a query for `request`; repairs it with the model's help until it parses and every name exists.
    static func write(_ request: String, store: DocumentStore) async throws -> String {
        try await checkedQuery(instructions: writeInstructions, request: request, store: store)
    }

    /// Proposes a corrected version of a failing query from the query, its error and the model's schema. The
    /// proposal passes the same checks as a written query; one that matches the original is not a fix.
    static func fix(_ query: String, error: String, store: DocumentStore) async throws -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DAXAssistantError.emptyQuery }
        let request = "This DAX query fails:\n```dax\n\(text)\n```\nThe error is: \(error)"
        let fixed = try await checkedQuery(instructions: fixInstructions, request: request, store: store)
        guard fixed != text else { throw DAXAssistantError.invalidQuery(["The answer repeated the failing query."]) }
        return fixed
    }

    /// Sends `request` with the schema as cached context and repairs the answer until it checks out.
    private static func checkedQuery(instructions: String, request: String, store: DocumentStore) async throws -> String {
        let client = AssistantTasks.makeClient()
        let system = [AssistantSystemBlock(AssistantTasks.role + instructions),
                      AssistantSystemBlock(AssistantContext.model(store), cache: true)]
        var messages: [AssistantMessage] = [.user(request)]
        var problems: [String] = []
        for attempt in 0...repairAttempts {
            let answer = try await client.complete(system: system, messages: messages).text
            let query = extractQuery(answer)
            problems = await validate(query, store: store)
            if problems.isEmpty { return query }
            guard attempt < repairAttempts else { break }
            messages.append(AssistantMessage(role: .assistant, content: [["type": "text", "text": .string(answer)]]))
            messages.append(.user("That query does not check out against the model:\n"
                                  + problems.map { "- \($0)" }.joined(separator: "\n")
                                  + "\nReply with the corrected query only, in a ```dax code block."))
        }
        throw DAXAssistantError.invalidQuery(problems)
    }

    /// A short tab name from the request: its first words, at most 32 characters.
    nonisolated static func tabName(for request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        var name = ""
        for w in words {
            let next = name.isEmpty ? String(w) : name + " " + w
            if next.count > 32 { break }
            name = next
        }
        if name.isEmpty { name = String(trimmed.prefix(32)) }
        return name.isEmpty ? "Assistant query" : name
    }

    /// The query inside the first fenced code block, or the whole answer when it has none.
    nonisolated static func extractQuery(_ answer: String) -> String {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.range(of: "```") else { return text }
        var body = text[open.upperBound...]
        // Skip the language tag on the opening fence line.
        if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] } else { return text }
        let inner = body.range(of: "```").map { body[..<$0.lowerBound] } ?? body
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Problems that stop a query from running against this model: no EVALUATE, a parse error, a name the
    /// model does not have, or an error from a trial run. Empty when the query is good to place in a tab.
    static func validate(_ query: String, store: DocumentStore) async -> [String] {
        guard !query.isEmpty else { return ["The answer contained no query."] }
        guard DAXLexer.tokens(query).contains(where: { $0.isWord("EVALUATE") }) else {
            return ["The query has no EVALUATE statement."]
        }
        return await store.withEngine { engine -> [String] in
            let issues = engine.check(query, kind: .query, homeTable: nil).filter { !$0.isWarning }.map(\.message)
            if !issues.isEmpty { return issues }
            // The static check does not resolve every reference (an unqualified [Name] may be a measure or a
            // row-context column), so the query also has to run.
            do { _ = try engine.query(query); return [] }
            catch { return [(error as? LocalizedError)?.errorDescription ?? error.localizedDescription] }
        }
    }
}

enum DAXAssistantError: LocalizedError, Equatable {
    case emptyQuery
    case invalidQuery([String])

    var errorDescription: String? {
        switch self {
        case .emptyQuery: return "There is no query to work with. Type or select a query first."
        case .invalidQuery(let problems):
            return "The assistant could not find a query that works with this model. "
                + (problems.first.map { "Its last attempt failed the check: \($0)" } ?? "Try describing the result differently.")
        }
    }
}

extension DAXQuerySession {
    /// The text the assistant explains: the selection in the editor when there is one, otherwise the whole query.
    var assistantQueryText: String {
        guard let tab = activeTab else { return "" }
        if let tv = editorTextView, tv.string == tab.text {
            let r = tv.selectedRange()
            if r.length > 0 {
                let selected = (tv.string as NSString).substring(with: r)
                if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return selected }
            }
        }
        return tab.text
    }
}
