import SwiftUI
import FacetCore

/// The page auto-refresh timer for one document. Observable so the Performance pane can show when it last ran.
@MainActor
final class AutoRefreshState: ObservableObject {
    @Published fileprivate(set) var isRunning = false
    @Published fileprivate(set) var lastRefresh: Date?
    /// When a change-detection measure is set: the last time it was checked and found unchanged.
    @Published fileprivate(set) var lastCheck: Date?

    fileprivate weak var store: DocumentStore?
    fileprivate var timer: Timer?
    fileprivate var pageID: UUID?
    fileprivate var interval: Double = 0
    fileprivate var measureKey: String?
    fileprivate var baseline: Value?
    fileprivate var hasBaseline = false
    fileprivate var checking = false

    fileprivate init(store: DocumentStore) { self.store = store }

    func stop() {
        timer?.invalidate(); timer = nil
        pageID = nil; measureKey = nil; hasBaseline = false; baseline = nil
        if isRunning { isRunning = false }
    }

    fileprivate func start(page: UUID, spec: PageRefreshSpec) {
        timer?.invalidate()
        pageID = page
        interval = AutoRefreshController.clamped(spec.intervalSeconds)
        measureKey = spec.changeDetectionMeasure?.key
        hasBaseline = false; baseline = nil
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = min(1, interval * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if !isRunning { isRunning = true }
    }

    private func tick() {
        guard let store else { stop(); return }
        let spec = store.currentPage.autoRefresh
        guard spec.isEnabled, store.currentPageID == pageID else { stop(); return }
        // Never stack refreshes: skip this beat while one is still running.
        guard store.refreshProgress == nil, !checking else { return }
        guard let measure = spec.changeDetectionMeasure else { refresh(store); return }
        checking = true
        let expression = measure.daxReference
        Task { [weak self] in
            let value = await store.withEngine { engine in try? engine.scalar(expression, filters: []) }
            guard let self else { return }
            self.checking = false
            guard self.timer != nil, self.measureKey == measure.key else { return }
            let current = value ?? .null
            if !self.hasBaseline {
                self.hasBaseline = true; self.baseline = current
                self.lastCheck = Date()
            } else if current != self.baseline {
                self.baseline = current
                self.refresh(store)
            } else {
                self.lastCheck = Date()
            }
        }
    }

    private func refresh(_ store: DocumentStore) {
        if store.doc.queries.isEmpty { store.refreshVisuals() } else { store.refreshData() }
        lastRefresh = Date()
    }
}

/// Owns the page auto-refresh timers, one per open document, independent of whether any pane is showing.
@MainActor
final class AutoRefreshController {
    static let shared = AutoRefreshController()
    static let minimumInterval: Double = 1
    static func clamped(_ seconds: Double) -> Double { max(minimumInterval, seconds.isFinite ? seconds : 30) }

    private var states: [ObjectIdentifier: AutoRefreshState] = [:]

    func state(for store: DocumentStore) -> AutoRefreshState {
        let key = ObjectIdentifier(store)
        if let s = states[key], s.store === store { return s }
        for (k, s) in states where s.store == nil { s.stop(); states[k] = nil }
        let s = AutoRefreshState(store: store)
        states[key] = s
        return s
    }

    /// Start, restart or stop the timer so it matches the current page's auto-refresh settings.
    func sync(_ store: DocumentStore) {
        let state = state(for: store)
        let spec = store.currentPage.autoRefresh
        guard spec.isEnabled else { if state.timer != nil { state.stop() }; return }
        let unchanged = state.timer != nil && state.pageID == store.currentPageID
            && state.interval == Self.clamped(spec.intervalSeconds)
            && state.measureKey == spec.changeDetectionMeasure?.key
        if !unchanged { state.start(page: store.currentPageID, spec: spec) }
    }
}

extension DocumentStore {
    /// Make sure page auto refresh is running (or stopped) to match the current page's settings, and keep
    /// it matched as the document and the current page change. Safe to call repeatedly.
    func startAutoRefreshIfNeeded() {
        _ = ReportPaneRuntime.of(self)
        AutoRefreshController.shared.sync(self)
    }
}
