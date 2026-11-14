import SwiftUI
import Combine
import FacetCore

/// Per-document state of the report canvas and reading view that is not part of the document:
/// tooltip page results, the spotlighted visual, filter and slicer changes waiting for Apply, and
/// each reader's personalised visuals (kept per user in the app's preferences, keyed by the document's location).
@MainActor
final class ReportRuntime: ObservableObject {
    /// Tooltip page results: tooltip key → visual id → data.
    @Published private(set) var tooltipData: [String: [UUID: VisualData]] = [:]
    /// Bumped whenever cached tooltip results are dropped, so visible tooltips reload.
    @Published private(set) var tooltipVersion = 0
    private var tooltipLoading: Set<String> = []
    /// The visual shown at full strength while the rest of the page is dimmed.
    @Published var spotlightID: UUID? { didSet { if spotlightID != oldValue { store?.objectWillChange.send() } } }
    /// With the report's Apply button on: the filter lists as the visuals last ran with them.
    @Published var heldFilters = HeldFilters()
    /// Slicer selections made on a page with an "Apply all slicers" button, waiting for it: slicer id → state.
    @Published var pendingSlicers: [UUID: SlicerState] = [:] { didSet { if pendingSlicers != oldValue { store?.objectWillChange.send() } } }
    /// Reader changes per visual id.
    @Published private(set) var personalizations: [UUID: Personalization] = [:]
    /// Query results for personalised visuals (the store only queries the saved ones).
    @Published private(set) var personalData: [UUID: VisualData] = [:]
    private var personalSignatures: [UUID: String] = [:]
    private var storageKey: String?
    /// Where personalisations are kept. Tests point this at a scratch suite.
    static var preferences: UserDefaults = .standard
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

    /// The store's runtime if one was made; never makes one (safe to call while one is being made).
    static func existing(for store: DocumentStore) -> ReportRuntime? {
        guard let r = all[ObjectIdentifier(store)], r.store === store else { return nil }
        return r
    }

    /// True when Apply would change what the visuals show.
    var filtersPending: Bool {
        guard let store, store.report.settings.filterPaneApplyButton else { return false }
        return heldFilters.isPending(in: store.report)
    }

    /// The slicer as it is drawn: with a selection waiting for "Apply all slicers" in place of the saved one.
    func withPendingSlicer(_ spec: VisualSpec) -> VisualSpec {
        guard spec.type.isSlicer, let pending = pendingSlicers[spec.id], let store, SlicerApply.defers(store.currentPage) else { return spec }
        var s = spec
        s.slicerState = pending.isActive ? pending : nil
        return s
    }

    private init(_ store: DocumentStore) {
        self.store = store
        // Any change to the document, its filters or selections can change what a tooltip page shows.
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.dropTooltips(); self?.syncPersonalized() } }
            .store(in: &cancellables)
        storageKey = Personalize.storageKey(for: store.fileURL)
        personalizations = Personalize.decode(storageKey.flatMap { Self.preferences.data(forKey: $0) })
        syncPersonalized()
    }

    // MARK: Personalised visuals

    func personalization(for id: UUID) -> Personalization? { personalizations[id] }

    /// The visual as this reader sees it.
    func effectiveSpec(_ spec: VisualSpec) -> VisualSpec {
        let shown = withPendingSlicer(spec)
        guard let p = personalizations[spec.id], let store else { return shown }
        return Personalize.apply(p, to: shown) { store.defaultAggregation(for: $0) }
    }

    /// The data to draw for a visual: the personalised query's result when there is one.
    func data(for spec: VisualSpec) -> VisualData {
        if personalizations[spec.id] != nil, let data = personalData[spec.id] { return data }
        return store?.visualData[spec.id] ?? VisualData()
    }

    func setPersonalization(_ p: Personalization?, for id: UUID) {
        if let p, !p.isEmpty { personalizations[id] = p } else { personalizations[id] = nil; personalData[id] = nil }
        personalSignatures[id] = nil
        save()
        syncPersonalized()
    }

    /// Back to the report as its author saved it: one page's visuals, or every visual.
    func resetPersonalizations(on page: Page? = nil) {
        let ids = page.map { Set($0.visuals.map(\.id)) }
        personalizations = personalizations.filter { id, _ in ids.map { !$0.contains(id) } ?? false }
        personalData = personalData.filter { personalizations[$0.key] != nil }
        personalSignatures = personalSignatures.filter { personalizations[$0.key] != nil }
        save()
    }

    func hasPersonalizations(on page: Page) -> Bool { page.visuals.contains { personalizations[$0.id] != nil } }

    private func save() {
        guard let key = storageKey else { return }
        if personalizations.isEmpty { Self.preferences.removeObject(forKey: key) }
        else if let data = Personalize.encode(personalizations) { Self.preferences.set(data, forKey: key) }
    }

    /// Requery personalised visuals on the current page whenever their saved counterpart was requeried
    /// (filters, slicers, selections or data changed) or the personalisation itself changed.
    private func syncPersonalized() {
        guard let store else { return }
        let key = Personalize.storageKey(for: store.fileURL)
        if key != storageKey {
            // Saved for the first time, or saved under a new name: the reader's changes follow the document.
            storageKey = key
            save()
        }
        guard !personalizations.isEmpty else { return }
        let page = store.currentPage
        for saved in page.visuals {
            guard let p = personalizations[saved.id] else { continue }
            let base = store.visualData[saved.id]
            let signature = "\(base?.daxQuery ?? "")|\(base?.queryMilliseconds ?? 0)|\(p.hashValueString)"
            guard personalSignatures[saved.id] != signature else { continue }
            personalSignatures[saved.id] = signature
            let spec = effectiveSpec(saved)
            let request = store.request(for: spec, on: page)
            Task {
                let result = await store.withEngine { engine -> VisualData in
                    engine.visualData(spec: spec, request: request)
                }
                guard self.personalSignatures[saved.id] == signature else { return }
                self.personalData[saved.id] = result
            }
        }
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

private extension Personalization {
    /// A stable text form, for change detection.
    var hashValueString: String {
        (try? JSONEncoder().encode(self)).map { $0.base64EncodedString() } ?? ""
    }
}
