import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

// MARK: - Smart narrative

/// The narrative visual's assistant mode (Copilot's narrative): the author writes a prompt, and the assistant
/// answers it from the page or the whole report. The prompt and the text the author kept are stored on the
/// visual; when the page's numbers change (a slicer, a filter, a cross-highlight) the text is rewritten for
/// display without changing the document.
@MainActor
enum NarrativeAssistant {
    enum Scope: String, CaseIterable {
        case page, report
        var title: String { self == .page ? "This page" : "Whole report" }
    }

    static let instructions = """
    Write the text of a narrative visual on a report page, answering the author's prompt from the report data in \
    the request. Write two to five short sentences of plain prose: no Markdown, no headings, and no bullet points \
    unless the prompt asks for a list. Quote figures as they appear in the data, and say nothing the data does not show.
    """

    static let suggestedPrompts = ["Summarize the key insights", "Explain what drives the totals", "Point out anything unusual"]

    static func prompt(_ spec: VisualSpec) -> String { spec.fmtString("narrative", "prompt", "") }
    static func text(_ spec: VisualSpec) -> String { spec.fmtString("narrative", "text", "") }
    static func scope(_ spec: VisualSpec) -> Scope { Scope(rawValue: spec.fmtString("narrative", "scope", "")) ?? .page }
    static func basis(_ spec: VisualSpec) -> String { spec.fmtString("narrative", "basis", "") }

    /// The page without the narrative and other text-writing visuals, so the narrative never describes itself.
    private static func source(_ page: Page, excluding id: UUID) -> Page {
        var p = page
        p.visuals.removeAll { $0.id == id || $0.type == .narrative || $0.type == .qna }
        return p
    }

    /// What the narrative is written from, with the values the visuals show now.
    static func context(_ scope: Scope, excluding id: UUID, store: DocumentStore) async -> String {
        switch scope {
        case .page:
            return await AssistantContext.page(source(store.currentPage, excluding: id), store: store)
        case .report:
            var report = store.report
            report.pages = report.pages.map { source($0, excluding: id) }
            var data: [UUID: VisualData] = [:]
            for page in report.pages where !page.isHidden && !page.isTooltipPage {
                data.merge(await AssistantContext.visualData(for: page, store: store)) { a, _ in a }
            }
            return ReportDescriber.describe(report: report, visualData: data)
        }
    }

    /// The assistant's text for a prompt, cleaned to plain prose.
    static func generate(prompt: String, scope: Scope, excluding id: UUID, store: DocumentStore) async throws -> String {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { throw NarrativeError.emptyPrompt }
        let data = await context(scope, excluding: id, store: store)
        let tag = scope.rawValue
        let answer = try await AssistantTasks.ask(instructions, prompt: "\(request)\n\n<\(tag)>\n\(data)\n</\(tag)>", store: store)
        let text = clean(answer)
        guard !text.isEmpty else { throw NarrativeError.unusable }
        return text
    }

    /// Prose without Markdown emphasis or heading marks, paragraphs kept.
    nonisolated static func clean(_ answer: String) -> String {
        let paragraphs = answer.components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for p in paragraphs where !(p.isEmpty && (out.last?.isEmpty ?? true)) { out.append(p) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Stores the prompt and text on the visual as one undoable change. False when the visual is gone.
    @discardableResult
    static func keep(_ text: String, prompt: String, scope: Scope, visual id: UUID, store: DocumentStore) -> Bool {
        guard let spec = store.visual(id) else { return false }
        let basis = currentBasis(for: spec, store: store)
        store.updateVisual(id, name: "Write Narrative", invalidates: .layout) { v in
            v.setFmt("narrative", "prompt", .string(prompt))
            v.setFmt("narrative", "text", .string(text))
            v.setFmt("narrative", "scope", .string(scope.rawValue))
            v.setFmt("narrative", "basis", .string(basis))
        }
        return true
    }

    /// Goes back to the on-device summary.
    static func clear(visual id: UUID, store: DocumentStore) {
        store.updateVisual(id, name: "Clear Narrative", invalidates: .layout) { v in
            for key in ["prompt", "text", "scope", "basis"] { v.setFmt("narrative", key, nil) }
        }
    }

    /// A fingerprint of the numbers on the page now (the narrative left out), to notice when they change.
    static func currentBasis(for spec: VisualSpec, store: DocumentStore) -> String {
        let page = source(store.currentPage, excluding: spec.id)
        return fingerprint(ReportDescriber.describe(page: page, visualData: store.visualData))
    }

    /// FNV-1a, so the fingerprint is the same from one launch to the next.
    nonisolated static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

enum NarrativeError: LocalizedError, Equatable {
    case emptyPrompt, unusable
    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "Write what the narrative should say, or pick a suggestion."
        case .unusable: return "The assistant's answer had no usable text. Try again."
        }
    }
}

struct NarrativeView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let store: DocumentStore

    @State private var editing = false
    /// Text rewritten after the page's numbers changed; shown instead of the stored text, never saved.
    @State private var refreshed: (basis: String, text: String)?
    @State private var refreshing = false
    @State private var refreshError: String?

    private var assistantText: String { NarrativeAssistant.text(spec) }
    private var basis: String { NarrativeAssistant.currentBasis(for: spec, store: store) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    if assistantText.isEmpty { onDevice } else { written }
                }
                .padding(Design.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if context.isInteractive {
                IconButton(assistantText.isEmpty ? "sparkles" : "pencil", help: assistantText.isEmpty ? "Write this narrative with the assistant from a prompt" : "Change the narrative's prompt") {
                    editing = true
                }
                .padding(Design.Space.xs)
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    NarrativePromptEditor(spec: spec, store: store) { editing = false }
                }
            }
        }
        .task(id: assistantText.isEmpty ? "" : basis) { await refreshIfNeeded() }
    }

    @ViewBuilder
    private var onDevice: some View {
        let narrative = build()
        if narrative.isEmpty {
            Text("Add visuals with data to this page and the summary is written here.")
                .font(Design.Typeface.body).foregroundStyle(.secondary)
        } else {
            // One flowing paragraph, with the figures picked out.
            narrative.segments.reduce(Text("")) { $0 + segment($1) }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var written: some View {
        let current = refreshed?.basis == basis ? refreshed?.text : nil
        Text(current ?? assistantText)
            .font(Design.Typeface.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Design.Space.xs) {
            if refreshing { ProgressView().controlSize(.mini) }
            Text(refreshing ? "Updating for the current filters…" : (refreshError ?? "Written by the assistant: \(NarrativeAssistant.prompt(spec))"))
                .font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(2)
        }
    }

    /// Rewrites the text when the page's numbers no longer match what it was written from.
    private func refreshIfNeeded() async {
        let prompt = NarrativeAssistant.prompt(spec)
        let now = basis
        guard !assistantText.isEmpty, !prompt.isEmpty, now != NarrativeAssistant.basis(spec), refreshed?.basis != now,
              store.loadingVisuals.isEmpty, AssistantTasks.isConfigured else { return }
        // Let a run of slicer clicks settle before asking.
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        refreshing = true
        refreshError = nil
        do {
            let text = try await NarrativeAssistant.generate(prompt: prompt, scope: NarrativeAssistant.scope(spec), excluding: spec.id, store: store)
            if !Task.isCancelled { refreshed = (now, text) }
        } catch {
            if !(error is CancellationError) { refreshError = "Not updated: " + AssistantTasks.message(error) }
        }
        refreshing = false
    }

    private func segment(_ s: Narrative.Segment) -> Text {
        switch s {
        case .text(let t): return Text(t).font(Design.Typeface.body)
        case .value(let v, _): return Text(v).font(Design.Typeface.bodyStrong).foregroundColor(Color.accentColor)
        }
    }

    private func build() -> Narrative {
        // A narrative with fields summarises its own data; otherwise it summarises the page.
        if !spec.fields(.values).isEmpty, data.table.rowCount > 0, data.error == nil {
            return SmartNarrative.summarize(data: data, spec: spec)
        }
        let page = store.currentPage.visuals.compactMap { v -> (VisualSpec, VisualData)? in
            guard v.id != spec.id, !v.type.isPageElement, !v.type.isSlicer,
                  let d = store.visualData[v.id], !d.isEmpty, d.error == nil else { return nil }
            return (v, d)
        }
        return SmartNarrative.summarize(page: page)
    }
}

/// Prompt → Generate → review → Keep, for the narrative visual.
struct NarrativePromptEditor: View {
    let spec: VisualSpec
    let store: DocumentStore
    let dismiss: () -> Void

    @State private var prompt = ""
    @State private var scope = NarrativeAssistant.Scope.page
    @State private var draft = ""
    @State private var working = false
    @State private var failure: Error?
    @State private var configured = true

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Narrative").font(Design.Typeface.headline)
            Text("Tell the assistant what to write. It reads the values on the page as they are filtered now, and rewrites the text when they change.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !configured {
                AssistantNotice(message: AssistantTasks.setupMessage, showsSettings: true)
            } else {
                TextField("Summarize the key insights", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(NarrativeAssistant.suggestedPrompts, id: \.self) { s in
                        Button(s) { prompt = s }.buttonStyle(.bordered).controlSize(.small).help("Use this prompt")
                    }
                }
                Picker("Write from", selection: $scope) {
                    ForEach(NarrativeAssistant.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let failure { AssistantNotice(error: failure) }
                if working {
                    HStack(spacing: Design.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Writing…").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                } else if !draft.isEmpty {
                    Text(draft).font(Design.Typeface.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Design.Space.s)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Design.Palette.fill))
                }
            }
            Hairline()
            HStack {
                if !NarrativeAssistant.text(spec).isEmpty {
                    Button("Use On-Device Summary") {
                        NarrativeAssistant.clear(visual: spec.id, store: store)
                        dismiss()
                    }
                    .help("Remove the assistant's text and go back to the built-in summary (you can undo it)")
                }
                Spacer()
                Button(draft.isEmpty ? "Generate" : "Try Again") { generate() }
                    .disabled(working || !configured || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Ask the assistant to write the narrative from this prompt")
                Button("Keep") {
                    NarrativeAssistant.keep(draft, prompt: prompt, scope: scope, visual: spec.id, store: store)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || draft.isEmpty)
                .help("Show this text in the visual (you can undo it)")
            }
        }
        .padding(Design.Space.m)
        .frame(width: 300)
        .onAppear {
            configured = AssistantTasks.isConfigured
            prompt = NarrativeAssistant.prompt(spec)
            scope = NarrativeAssistant.scope(spec)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantConfigurationChanged)) { _ in configured = AssistantTasks.isConfigured }
    }

    private func generate() {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            do { draft = try await NarrativeAssistant.generate(prompt: prompt, scope: scope, excluding: spec.id, store: store) }
            catch { failure = error }
            working = false
        }
    }
}
