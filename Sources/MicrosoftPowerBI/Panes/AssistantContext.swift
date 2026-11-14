import Foundation
import FacetCore
import FacetAnalytics

/// What the assistant is told about the open document: the semantic model (`ModelDescriber`) and the
/// report's pages with the numbers their visuals show right now (`ReportDescriber`).
@MainActor
enum AssistantContext {
    /// The model as the assistant sees it: hidden and AI-excluded fields left out; the author's AI
    /// instructions and verified answers (with the visuals that answer them) included.
    static func model(_ store: DocumentStore) -> String {
        let referenced = Set(store.model.verifiedAnswers.compactMap(\.visualID))
        var visuals: [UUID: String] = [:]
        for page in store.report.pages {
            for v in page.visuals where referenced.contains(v.id) {
                visuals[v.id] = "\"\(title(v))\" on page \"\(page.name)\""
            }
        }
        return ModelDescriber.schemaSummary(model: store.model, answerVisuals: visuals)
    }

    static func title(_ v: VisualSpec) -> String { v.fmtString("title", "text", v.name) }

    /// Visuals whose data describes a page; images, shapes, buttons, slicers and the AI text visuals have none.
    static func dataVisuals(_ page: Page) -> [VisualSpec] {
        page.visuals.filter { !$0.isHidden && !$0.type.isPageElement && !$0.type.isSlicer && $0.type != .narrative && $0.type != .qna }
    }

    /// Query results for a page's visuals under its current filters and slicers. The current page reuses what
    /// the canvas already shows; anything missing is queried now.
    static func visualData(for page: Page, store: DocumentStore) async -> [UUID: VisualData] {
        var out: [UUID: VisualData] = [:]
        var jobs: [(VisualSpec, VisualRequest)] = []
        for v in dataVisuals(page) {
            if page.id == store.currentPageID, let d = store.visualData[v.id] { out[v.id] = d }
            else { jobs.append((v, store.request(for: v, on: page))) }
        }
        guard !jobs.isEmpty else { return out }
        let computed: [(UUID, VisualData)] = await store.withEngine { engine in
            jobs.map { spec, request in (spec.id, engine.visualData(spec: spec, request: request)) }
        }
        for (id, d) in computed { out[id] = d }
        return out
    }

    /// One page: its filters, then each visual with its fields and top values.
    static func page(_ page: Page, store: DocumentStore) async -> String {
        ReportDescriber.describe(page: page, visualData: await visualData(for: page, store: store))
    }

    /// Every page a reader can open, with fewer rows per visual than a single-page description.
    static func report(_ store: DocumentStore) async -> String {
        var data: [UUID: VisualData] = [:]
        for page in store.report.pages where !page.isHidden && !page.isTooltipPage {
            data.merge(await visualData(for: page, store: store)) { a, _ in a }
        }
        return ReportDescriber.describe(report: store.report, visualData: data)
    }

    /// One visual, where it sits, and its data; nil when the visual no longer exists.
    static func visual(_ id: UUID, store: DocumentStore) async -> String? {
        guard let page = store.report.pages.first(where: { $0.visual(id) != nil }), let v = page.visual(id) else { return nil }
        let data = await visualData(for: page, store: store)[id]
        let lines = ReportDescriber.describe(visual: v, data: data)
        guard !lines.isEmpty else { return nil }
        return (["On page \"\(page.name)\":"] + lines).joined(separator: "\n")
    }
}
