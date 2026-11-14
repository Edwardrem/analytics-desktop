import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

// MARK: - Q&A

/// A Q&A question that matches a verified answer (Prep data for AI): the author's answer, and the visual they
/// chose for it with its page. Verified answers come before the question parser's own interpretation.
struct QnAVerifiedResult {
    var answer: VerifiedAnswer
    var visual: VisualSpec?
    var pageID: UUID?
    var pageName: String?

    @MainActor
    static func find(_ question: String, store: DocumentStore) -> QnAVerifiedResult? {
        guard let match = VerifiedAnswerMatcher.match(question, in: store.model.verifiedAnswers) else { return nil }
        var result = QnAVerifiedResult(answer: match.answer)
        if let id = match.answer.visualID, let page = store.report.pages.first(where: { $0.visual(id) != nil }) {
            result.visual = page.visual(id)
            result.pageID = page.id
            result.pageName = page.name
        }
        // A verified answer whose visual was deleted and that has no text has nothing to show.
        guard result.visual != nil || !match.answer.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }
}

struct QnAView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let store: DocumentStore

    @State private var question = ""
    @State private var answer: QuestionAnswer?
    @State private var verified: QnAVerifiedResult?
    @State private var answerData: VisualData?
    @State private var working = false
    @State private var valueCache: [String: [Value]] = [:]
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            questionBar
            Hairline()
            answerArea
        }
        .task(id: spec.content) {
            if question.isEmpty { question = spec.content }
            if !question.isEmpty, answer == nil { ask() }
            else if suggestions.isEmpty { suggestions = startingQuestions }
            if valueCache.isEmpty { await preload() }
        }
    }

    private var questionBar: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "questionmark.bubble").foregroundStyle(Color.accentColor)
            TextField("Ask a question about your data", text: $question)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { ask() }
            if working {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask") { ask() }.controlSize(.small).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if context.isInteractive {
                IconButton("gearshape", help: "Q&A setup: teach Q&A terms and review the questions asked") {
                    store.present { QnASetupSheet(tab: .teach, question: question) }
                }
            }
        }
        .padding(Design.Space.m)
    }

    @ViewBuilder
    private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                if let verified {
                    verifiedHeader(verified)
                    if let d = answerData, let v = verified.visual {
                        VisualView(spec: v, data: d, context: answerContext)
                            .frame(minHeight: 240)
                    }
                } else if let answer {
                    interpretation(answer)
                    if let d = answerData {
                        VisualView(spec: answer.spec, data: d, context: answerContext)
                            .frame(minHeight: 240)
                    }
                    if !answer.suggestions.isEmpty {
                        suggestionChips(answer.suggestions)
                    }
                } else {
                    suggestionChips(suggestions)
                }
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func interpretation(_ answer: QuestionAnswer) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text(answer.interpretation).font(Design.Typeface.body)
            if !answer.unrecognized.isEmpty {
                HStack(spacing: Design.Space.s) {
                    Text("Didn't understand: \(answer.unrecognized.joined(separator: ", "))")
                        .font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    if context.isInteractive {
                        Button("Teach Q&A") { store.present { QnASetupSheet(tab: .teach, question: spec.content) } }
                            .buttonStyle(.link).font(Design.Typeface.caption)
                            .help("Define the words Q&A didn't understand as a field or a filter")
                    }
                }
            }
        }
    }

    private func verifiedHeader(_ v: QnAVerifiedResult) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Label("Verified answer", systemImage: "checkmark.seal.fill")
                .font(Design.Typeface.captionStrong).foregroundStyle(Design.Palette.positive)
                .help("The model's author approved this answer for questions like yours")
            Text(v.answer.question).font(Design.Typeface.caption).foregroundStyle(.secondary)
            let text = v.answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { Text(text).font(Design.Typeface.body).fixedSize(horizontal: false, vertical: true) }
            if let visual = v.visual, let page = v.pageName {
                Text("From “\(AssistantContext.title(visual))” on page “\(page)”")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// The author's verified questions first, then questions the model's fields suggest.
    private var startingQuestions: [String] {
        let verified = store.model.verifiedAnswers.map(\.question).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [String] = []
        for q in verified + QuestionParser.suggestedQuestions(store.model, limit: 5) where !out.contains(q) && out.count < 5 { out.append(q) }
        return out
    }

    private func suggestionChips(_ list: [String]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(list, id: \.self) { s in
                Button(s) { question = s; ask() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var answerContext: VisualContext {
        var c = VisualContext()
        c.theme = store.theme
        c.isInteractive = false
        return c
    }

    // MARK: Asking

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !working else { return }
        working = true
        answerData = nil
        // A new question is also kept for Q&A setup ▸ Review questions.
        if q != spec.content { QnASetupLogic.ask(q, visual: spec.id, store: store) }
        if let match = QnAVerifiedResult.find(q, store: store) {
            verified = match
            answer = nil
            guard let visual = match.visual, let id = match.pageID, let page = store.report.page(id) else {
                working = false
                return
            }
            Task {
                let request = store.request(for: visual, on: page)
                answerData = await store.withEngine { $0.visualData(spec: visual, request: request) }
                working = false
            }
            return
        }
        verified = nil
        let parser = QuestionParser(model: store.model, synonyms: store.model.qnaSynonyms,
                                    distinctValues: { f in valueCache[QnASetupLogic.valueKey(f)] ?? [] })
        let parsed = parser.parse(q)
        answer = parsed
        guard parsed.isAnswerable else {
            working = false
            return
        }
        Task {
            let answerSpec = parsed.spec
            let request = store.request(for: answerSpec, on: store.currentPage)
            let result = await store.withEngine { $0.visualData(spec: answerSpec, request: request) }
            answerData = result
            working = false
        }
    }

    /// Preloads the distinct values of visible text columns so the parser recognises filter values.
    private func preload() async {
        valueCache = await QnASetupLogic.loadValues(store)
    }
}
