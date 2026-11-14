import Foundation
import ObjectiveC
import FacetCore
import FacetAnalytics
import FacetCloud

/// The Assistant pane's conversation for one document. The model description (`ModelDescriber`) is the
/// session's cached context; what the report shows comes from `ReportDescriber`, through the page and report
/// tools and the summary shortcuts. Questions that match a verified answer are answered from it.
@MainActor
final class AssistantPaneModel: ObservableObject {
    struct ChatEntry: Identifiable {
        enum Role { case user, assistant, tool, verified }
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
        var verified: VerifiedLink?
    }

    /// The verified answer a question matched, and where its visual is.
    struct VerifiedLink: Equatable {
        var question: String
        var answer: String
        var pageID: UUID?
        var visualID: UUID?
        var visualTitle: String?
    }

    @Published var transcript: [ChatEntry] = []
    @Published var input = ""
    @Published var isStreaming = false
    @Published var hasKey: Bool
    @Published var error: String?
    @Published var usage = AssistantUsage()

    let client: AssistantClient
    private(set) var session: AssistantSession
    private weak var store: DocumentStore?
    /// The model description the conversation was last told about.
    private var schema: String
    private var lastPageID: UUID?
    private var turnTask: Task<Void, Never>?

    static let instructions = """
    You are the assistant built into \(AppIdentity.name) for Mac. You help analyse data, write DAX, and build reports.
    The semantic model is described in the context. Call describe_page to see what the user's current page shows \
    (its filters and the values of each visual) and describe_report for the whole report; base answers about the \
    report on them. Run a DAX query with run_dax to answer questions the report does not already answer, then \
    describe the result. When a question matches a verified answer from the model's author, answer from it.
    To build the report, use add_visual (it binds the fields you name and finds free space) and create_page for a \
    new page with several visuals; name fields exactly as the model does, 'Table'[Column] or [Measure]. Use \
    add_measure to add a measure. If a tool reports a problem, fix the request and try again.
    Be concise. Write plain text; use short bullet points starting with "• " for lists.
    """

    private static var key: UInt8 = 0

    /// The conversation for a document, shared by the pane and the summary commands.
    static func of(_ store: DocumentStore) -> AssistantPaneModel {
        if let m = objc_getAssociatedObject(store, &key) as? AssistantPaneModel { return m }
        let m = AssistantPaneModel(store: store)
        objc_setAssociatedObject(store, &key, m, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return m
    }

    init(store: DocumentStore) {
        self.store = store
        client = AssistantTasks.makeClient()
        hasKey = client.isConfigured
        schema = AssistantContext.model(store)
        session = AssistantSession(client: client, instructions: Self.instructions, modelSchema: schema,
                                   tools: AssistantTools.tools(for: store))
    }

    // MARK: Sending

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        submit(display: text, matchVerified: true) { text }
    }

    /// Sends a suggested prompt as if typed.
    func send(_ text: String) {
        guard !isStreaming else { return }
        input = text
        send()
    }

    /// Asks for a summary of the page the user is on, with its visuals' current values attached.
    func summarizePage() {
        guard let store, !isStreaming else { return }
        let page = store.currentPage
        submit(display: "Summarize the page \"\(page.name)\"", matchVerified: false) {
            let description = await AssistantContext.page(page, store: store)
            return """
            Summarize this report page for a business reader: the main figures, notable highs and lows, and \
            anything that stands out. Use only what the page shows.

            <page>
            \(description)
            </page>
            """
        }
    }

    /// Asks for a summary of every visible page.
    func summarizeReport() {
        guard let store, !isStreaming else { return }
        submit(display: "Summarize the report", matchVerified: false) {
            let description = await AssistantContext.report(store)
            return """
            Summarize this report for a business reader: what each page covers and its key figures, then the \
            two or three most important takeaways overall. Use only what the report shows.

            <report>
            \(description)
            </report>
            """
        }
    }

    private func submit(display: String, matchVerified: Bool, prompt: @escaping @MainActor () async -> String) {
        guard let store else { return }
        hasKey = client.isConfigured
        guard hasKey else { error = AssistantTasks.setupMessage; return }
        error = nil
        transcript.append(ChatEntry(role: .user, text: display))
        isStreaming = true
        turnTask = Task { [weak self] in
            guard let self else { return }
            self.prepareNotes(store)
            let text = await prompt()
            if matchVerified, let (link, note) = await self.verifiedAnswer(for: text, store: store) {
                self.transcript.append(ChatEntry(role: .verified, text: link.question, verified: link))
                self.session.addNote(note)
            }
            guard !Task.isCancelled else { self.isStreaming = false; return }
            self.transcript.append(ChatEntry(role: .assistant, text: "", isStreaming: true))
            do {
                for try await event in self.session.send(text) { self.apply(event) }
            } catch is CancellationError {
            } catch {
                self.error = AssistantTasks.message(error)
                if AssistantTasks.needsSetup(error) { self.hasKey = self.client.isConfigured }
            }
            self.finishStreamingEntry()
            self.isStreaming = false
        }
    }

    /// Tells the conversation what changed since the last message: a changed model, or another page.
    private func prepareNotes(_ store: DocumentStore) {
        let current = AssistantContext.model(store)
        if current != schema {
            if session.history.isEmpty {
                // Nothing said yet: start over with the new description as the cached context.
                session = AssistantSession(client: client, instructions: Self.instructions, modelSchema: current,
                                           tools: AssistantTools.tools(for: store))
            } else {
                session.addNote("The data model changed since the conversation started. Its current description, which replaces the earlier one:\n\n\(current)")
            }
            schema = current
        }
        if lastPageID != store.currentPageID {
            let page = store.currentPage
            let count = AssistantContext.dataVisuals(page).count
            session.addNote("The user is looking at the report page \"\(page.name)\" (\(count) visual\(count == 1 ? "" : "s") with data). Call describe_page to see what it shows.")
            lastPageID = store.currentPageID
        }
    }

    /// The verified answer a question matches, with the note that tells the model about it.
    func verifiedAnswer(for question: String, store: DocumentStore) async -> (VerifiedLink, String)? {
        guard let match = VerifiedAnswerMatcher.match(question, in: store.model.verifiedAnswers) else { return nil }
        let a = match.answer
        var link = VerifiedLink(question: a.question, answer: a.answer)
        var note = "The user's question matches a verified answer that the model's author approved.\nVerified question: \(a.question)\n"
        if !a.answer.isEmpty { note += "Approved answer: \(a.answer)\n" }
        if let id = a.visualID, let page = store.report.pages.first(where: { $0.visual(id) != nil }), let v = page.visual(id) {
            link.pageID = page.id
            link.visualID = id
            link.visualTitle = AssistantContext.title(v)
            if let data = await AssistantContext.visual(id, store: store) {
                note += "The visual that answers it, with its current values:\n\(data)\n"
            }
        }
        note += "Answer from this verified answer and say that the model's author verified it."
        return (link, note)
    }

    /// Opens the page of a verified answer's visual and selects it.
    func show(_ link: VerifiedLink) {
        guard let store, let page = link.pageID, let visual = link.visualID,
              store.report.page(page)?.visual(visual) != nil else { return }
        if store.view != .report { store.view = .report }
        store.goToPage(page)
        store.selection = [visual]
    }

    func cancel() {
        turnTask?.cancel()
        session.cancel()
        finishStreamingEntry()
        isStreaming = false
    }

    func clear() {
        cancel()
        session.reset()
        transcript = []
        usage = AssistantUsage()
        error = nil
        lastPageID = nil
    }

    func saveAPIKey(_ key: String) throws {
        try client.setAPIKey(key)
        hasKey = client.isConfigured
        NotificationCenter.default.post(name: .assistantConfigurationChanged, object: nil)
    }

    func setAssistantModel(_ m: AssistantModel) {
        client.configuration.modelID = m.id
        client.configuration.save(to: .standard)
    }

    /// Re-reads the configuration after the user changed it in settings.
    func applyConfigurationChange() {
        client.configuration = AssistantConfiguration.load()
        hasKey = client.isConfigured
        if hasKey, error == AssistantTasks.setupMessage { error = nil }
    }

    private func finishStreamingEntry() {
        guard let i = transcript.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) else { return }
        transcript[i].isStreaming = false
        if transcript[i].text.isEmpty { transcript.remove(at: i) }
    }

    private func apply(_ event: AssistantEvent) {
        switch event {
        case .textDelta(let t):
            if let i = transcript.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                transcript[i].text += t
            }
        case .toolCallStarted(let id, let name):
            // Tool rows go above the text that follows them.
            transcript.append(ChatEntry(role: .tool, toolName: name, toolCallID: id))
            if let i = transcript.lastIndex(where: { $0.role == .assistant && $0.isStreaming }), transcript[i].text.isEmpty {
                let entry = transcript.remove(at: i)
                transcript.append(entry)
            } else {
                finishStreamingEntry()
                transcript.append(ChatEntry(role: .assistant, text: "", isStreaming: true))
            }
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
        case .turnFinished(let reason, let u):
            usage = u
            if reason == .refusal {
                finishStreamingEntry()
                transcript.append(ChatEntry(role: .assistant, text: AssistantError.declined(nil).errorDescription ?? "The assistant declined this request."))
            }
        case .thinkingDelta, .responseFinished, .historyTrimmed:
            break
        }
    }
}
