import SwiftUI
import Combine
import FacetCore

/// Transient, per-document state of the report canvas and reading view: tooltip page results.
/// Never persisted with the document.
@MainActor
final class ReportRuntime: ObservableObject {
    /// Tooltip page results: tooltip key → visual id → data.
    @Published private(set) var tooltipData: [String: [UUID: VisualData]] = [:]
    /// Bumped whenever cached tooltip results are dropped, so visible tooltips reload.
    @Published private(set) var tooltipVersion = 0
    private var tooltipLoading: Set<String> = []
    private(set) weak var store: DocumentStore?
    private var cancellables: Set<AnyCancellable> = []

    private static var all: [ObjectIdentifier: ReportRuntime] = [:]

    static func of(_ store: DocumentStore) -> ReportRuntime {
        let key = ObjectIdentifier(store)
        if let existing = all[key], existing.store === store { return existing }
        for (k, r) in all where r.store == nil { all[k] = nil }
        let runtime = ReportRuntime(store)
        all[key] = runtime
        return runtime
    }

    private init(_ store: DocumentStore) {
        self.store = store
        // Any change to the document, its filters or selections can change what a tooltip page shows.
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.dropTooltips() } }
            .store(in: &cancellables)
    }

    private func dropTooltips() {
        guard !tooltipData.isEmpty || !tooltipLoading.isEmpty else { return }
        tooltipData = [:]
        tooltipLoading = []
        tooltipVersion += 1
    }

    /// Query every visual on a tooltip page for one hovered data point (once per page, point and source visual).
    func loadTooltip(page: Page, point: DataPointSelection, sourceID: UUID) {
        guard let store else { return }
        let key = TooltipPages.key(page: page.id, point: point, source: sourceID)
        guard tooltipData[key] == nil, !tooltipLoading.contains(key) else { return }
        let sourcePage = store.currentPage
        let source = sourcePage.visual(sourceID).map { store.request(for: $0, on: sourcePage) } ?? VisualRequest()
        let jobs = page.visuals.filter { !$0.isHidden && (!$0.type.isPageElement || $0.type == .textBox) }.map { spec in
            (spec, TooltipPages.request(base: store.request(for: spec, on: page), source: source, point: point))
        }
        tooltipLoading.insert(key)
        let version = tooltipVersion
        Task {
            let results = await store.withEngine { engine in
                jobs.map { spec, request in (spec.id, engine.visualData(spec: spec, request: request)) }
            }
            guard version == self.tooltipVersion else { return }
            self.tooltipLoading.remove(key)
            self.tooltipData[key] = Dictionary(results, uniquingKeysWith: { first, _ in first })
        }
    }
}
