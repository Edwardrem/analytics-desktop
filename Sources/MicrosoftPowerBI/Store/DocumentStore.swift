import SwiftUI
import FacetCore

enum WorkspaceView: String, CaseIterable, Identifiable {
    case report, table, model, dax, tmdl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .report: return "Report"
        case .table: return "Table"
        case .model: return "Model"
        case .dax: return "DAX Query"
        case .tmdl: return "TMDL"
        }
    }
    var symbol: String {
        switch self {
        case .report: return "chart.bar.xaxis"
        case .table: return "tablecells"
        case .model: return "point.3.connected.trianglepath.dotted"
        case .dax: return "function"
        case .tmdl: return "curlybraces"
        }
    }
}

enum InspectorPane: String, CaseIterable, Identifiable {
    case build, format, data, filters, bookmarks, selection, syncSlicers, performance, theme, assistant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .build: return "Build"
        case .format: return "Format"
        case .data: return "Data"
        case .filters: return "Filters"
        case .bookmarks: return "Bookmarks"
        case .selection: return "Selection"
        case .syncSlicers: return "Sync Slicers"
        case .performance: return "Performance"
        case .theme: return "Theme"
        case .assistant: return "Assistant"
        }
    }
    var symbol: String {
        switch self {
        case .build: return "square.grid.2x2"
        case .format: return "paintbrush"
        case .data: return "cylinder.split.1x2"
        case .filters: return "line.3.horizontal.decrease"
        case .bookmarks: return "bookmark"
        case .selection: return "square.3.layers.3d"
        case .syncSlicers: return "arrow.triangle.2.circlepath"
        case .performance: return "gauge.with.needle"
        case .theme: return "swatchpalette"
        case .assistant: return "sparkles"
        }
    }
}

/// What a mutation invalidates, so the store recomputes as little as possible.
enum Invalidation {
    /// Geometry/appearance only — no queries.
    case layout
    /// Requery the given visuals (nil = every visual on the current page).
    case visuals([UUID]?)
    /// The model or data changed: reload the engine, then requery.
    case model
}

struct PerformanceEvent: Identifiable {
    var id = UUID()
    var visualID: UUID
    var visualName: String
    var queryMilliseconds: Double
    /// Query and processing time, plus the display time once the visual has been drawn.
    var totalMilliseconds: Double
    var dax: String
    var timestamp = Date()
    /// From the results reaching the canvas to the visual being drawn with them; nil until then
    /// (or when the visual isn't on screen to draw).
    var displayMilliseconds: Double?
    /// When the results reached the canvas.
    var delivered: CFAbsoluteTime?
}

struct StatusMessage: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    var id = UUID()
    var kind: Kind
    var text: String
}

/// One open document: its content, its transient UI state, and every operation on it.
/// Views never mutate the document directly — they call `mutate` (or a named operation) so
/// undo, dirty tracking and query invalidation stay correct in one place.
@MainActor
final class DocumentStore: ObservableObject {
    // MARK: Content
    @Published private(set) var doc: FacetDocument
    @Published var fileURL: URL?
    @Published private(set) var isDirty = false

    // MARK: Workspace state
    @Published var view: WorkspaceView = .report
    @Published var inspector: InspectorPane = .build
    @Published var inspectorVisible = true
    @Published var currentPageID: UUID
    @Published var selection: Set<UUID> = []
    @Published var zoom: Double = 1
    @Published var fitToWindow = true
    /// With `fitToWindow`: scale the page to the canvas width (scrolling vertically) instead of fitting all of it.
    @Published var fitToWidth = false
    @Published var showGridlines = false
    @Published var snapToGrid = true
    @Published var lockObjects = false
    @Published var mobileLayout = false
    @Published var editInteractionsFor: UUID?
    @Published var formatPainterSource: UUID?
    @Published var focusVisualID: UUID?
    @Published var showAsTableID: UUID?
    @Published var presenting = false
    /// The modal sheet currently shown over this document's window, if any.
    @Published var sheet: SheetRequest?

    // MARK: Query state
    @Published private(set) var visualData: [UUID: VisualData] = [:]
    @Published private(set) var overlays: [UUID: AnalyticsOverlays] = [:]
    @Published private(set) var loadingVisuals: Set<UUID> = []
    /// Cross-filter/highlight selections: source visual → selected data points.
    @Published private(set) var pointSelections: [UUID: [DataPointSelection]] = [:]
    @Published var visualsPaused = false { didSet { if !visualsPaused { refreshVisuals() } } }
    @Published private(set) var pendingWhilePaused: Set<UUID> = []
    @Published private(set) var modelErrors: [String: String] = [:]
    @Published var performanceRecording = false
    @Published private(set) var performanceLog: [PerformanceEvent] = []
    @Published var status: StatusMessage?
    @Published var refreshProgress: RefreshProgress?
    @Published var activeBookmarkID: UUID?
    /// "View as" security context.
    @Published var viewAsRoles: [String] = [] { didSet { reloadEngine() } }
    @Published var viewAsUser: String = "" { didSet { reloadEngine() } }
    /// Drillthrough filters currently applied to a destination page.
    @Published private(set) var drillthroughFilters: [UUID: [FilterSpec]] = [:]
    private(set) var pageHistory: [UUID] = []

    // MARK: Engines
    let services: Services
    private(set) var calculation: CalculationService
    /// Serial queue confining all engine access.
    let calcQueue = DispatchQueue(label: "facet.calculation", qos: .userInitiated)
    private var generation = 0
    private var engineGeneration = 0

    // MARK: Undo
    private struct UndoEntry { var name: String; var doc: FacetDocument; var key: String?; var time: Date; var group: UUID? = nil }
    private var undoStack: [UndoEntry] = []
    /// The group `undoGroup(_:_:)` has open: its writes share one step under its name.
    private var openUndoGroup: (id: UUID, name: String)?
    private var redoStack: [UndoEntry] = []
    @Published private(set) var undoName: String?
    @Published private(set) var redoName: String?

    init(document: FacetDocument = FacetDocument(), url: URL? = nil, services: Services) {
        self.doc = document
        self.fileURL = url
        self.services = services
        self.calculation = services.makeCalculation()
        self.currentPageID = document.report.landingPageID ?? document.report.pages.first?.id ?? UUID()
        reloadEngine()
    }

    // MARK: - Accessors

    var model: SemanticModel { doc.model }
    var report: Report { doc.report }
    var theme: ThemeSpec { doc.report.theme }
    var pageIndex: Int { doc.report.pages.firstIndex { $0.id == currentPageID } ?? 0 }
    var currentPage: Page { doc.report.pages[safe: pageIndex] ?? Page(name: "Page 1") }
    var selectedVisuals: [VisualSpec] { currentPage.visuals.filter { selection.contains($0.id) } }
    var selectedVisual: VisualSpec? { selection.count == 1 ? selectedVisuals.first : nil }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    /// Source data plus calculated objects, as last computed by the engine.
    @Published private(set) var computedData = DataStore()

    func visual(_ id: UUID) -> VisualSpec? {
        for p in doc.report.pages { if let v = p.visual(id) { return v } }
        return nil
    }

    // MARK: - Mutation

    /// The single write path for document content.
    /// - Parameters:
    ///   - name: Undo menu title ("Move Visual").
    ///   - coalesce: Consecutive mutations with the same key within a second share one undo step (dragging, typing).
    ///   - group: An undo group (from `undoGroup(_:_:)`) this write belongs to. While the group's step is still the
    ///     latest one, the write joins it; after another change it becomes a step of its own.
    func mutate(_ name: String, coalesce: String? = nil, joining group: UUID? = nil, invalidates: Invalidation = .visuals(nil),
                _ body: (inout FacetDocument) -> Void) {
        let before = doc
        var after = doc
        body(&after)
        let now = Date()
        let group = group ?? openUndoGroup?.id
        if let group, let last = undoStack.last, last.group == group {
            undoStack[undoStack.count - 1].time = now
        } else if let key = coalesce, let last = undoStack.last, last.key == key, now.timeIntervalSince(last.time) < 1.2 {
            undoStack[undoStack.count - 1].time = now
        } else {
            undoStack.append(UndoEntry(name: openUndoGroup?.name ?? name, doc: before, key: coalesce, time: now, group: group))
            if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        }
        redoStack.removeAll()
        doc = after
        isDirty = true
        syncUndoNames()
        validateWorkspace()
        apply(invalidates)
    }

    private func apply(_ invalidation: Invalidation) {
        switch invalidation {
        case .layout: break
        case .visuals(let ids): refreshVisuals(ids)
        case .model: reloadEngine()
        }
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(name: entry.name, doc: doc, key: nil, time: Date()))
        restore(entry.doc)
    }
    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(name: entry.name, doc: doc, key: nil, time: Date()))
        restore(entry.doc)
    }
    private func restore(_ d: FacetDocument) {
        doc = d
        isDirty = true
        syncUndoNames()
        validateWorkspace()
        reloadEngine()
    }
    private func syncUndoNames() { undoName = undoStack.last?.name; redoName = redoStack.last?.name }

    /// Runs `body` so that every write it makes is one undo step named `name`, and returns the group, which a later
    /// write (a load that finishes afterwards) can join with `mutate(_:joining:)`. Groups don't nest: an inner call
    /// joins the outer group.
    @discardableResult
    func undoGroup(_ name: String, _ body: () -> Void) -> UUID {
        if let open = openUndoGroup { body(); return open.id }
        let id = UUID()
        openUndoGroup = (id, name)
        defer { openUndoGroup = nil }
        body()
        return id
    }

    /// Keep transient state pointing at things that still exist.
    private func validateWorkspace() {
        if doc.report.pages.isEmpty { doc.report.pages = [Page(name: "Page 1")] }
        if !doc.report.pages.contains(where: { $0.id == currentPageID }) { currentPageID = doc.report.pages[0].id }
        let ids = Set(currentPage.visuals.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        pointSelections = pointSelections.filter { ids.contains($0.key) }
    }

    /// Replace the whole document (open, import, revert). Clears undo history.
    func replaceDocument(_ d: FacetDocument, url: URL?) {
        doc = d; fileURL = url; isDirty = false
        undoStack.removeAll(); redoStack.removeAll(); syncUndoNames()
        currentPageID = d.report.landingPageID ?? d.report.pages.first?.id ?? UUID()
        selection = []; pointSelections = [:]; visualData = [:]; drillthroughFilters = [:]; pageHistory = []
        if let runtime = ReportRuntime.existing(for: self) { runtime.heldFilters = HeldFilters(); runtime.pendingSlicers = [:] }
        validateWorkspace()
        reloadEngine()
    }
    func markSaved(at url: URL) { fileURL = url; isDirty = false }

    // MARK: - Visual helpers

    func updateVisual(_ id: UUID, name: String = "Change Visual", coalesce: String? = nil,
                      invalidates: Invalidation? = nil, _ body: (inout VisualSpec) -> Void) {
        mutate(name, coalesce: coalesce, invalidates: invalidates ?? .visuals([id])) { d in
            for p in d.report.pages.indices {
                if let i = d.report.pages[p].visuals.firstIndex(where: { $0.id == id }) {
                    body(&d.report.pages[p].visuals[i]); return
                }
            }
        }
    }
    func updatePage(name: String = "Change Page", invalidates: Invalidation = .layout, _ body: (inout Page) -> Void) {
        let i = pageIndex
        mutate(name, invalidates: invalidates) { d in body(&d.report.pages[i]) }
    }
    func updateModel(_ name: String, _ body: (inout SemanticModel) -> Void) {
        mutate(name, invalidates: .model) { d in body(&d.model) }
    }

    // MARK: - Engine

    /// Reload the calculation engine with the current model and data, then requery the page.
    /// DirectQuery tables' rows come from their sources (see `DirectQuerySession`).
    func reloadEngine() {
        engineGeneration += 1
        let gen = engineGeneration
        let model = doc.model
        let roles = viewAsRoles, user = viewAsUser
        let engine = services.makeCalculation()
        DirectQuerySession.of(self).data(for: doc, baseDirectory: fileURL?.deletingLastPathComponent()) { [weak self] data, problems in
            guard let self, gen == self.engineGeneration else { return }
            if !problems.isEmpty { self.status = StatusMessage(kind: .error, text: problems.joined(separator: "\n")) }
            self.calcQueue.async { [weak self] in
                let start = DispatchTime.now()
                let errors = engine.load(model: model, data: data, roles: roles, userName: user)
                let computed = engine.data
                TraceLog.shared.record("engine.load", ["ms": .milliseconds(TraceLog.milliseconds(since: start)),
                                                       "tables": .count(model.tables.count), "errors": .count(errors.count),
                                                       "rows": .count(computed.tables.values.reduce(0) { $0 + $1.rowCount })])
                DispatchQueue.main.async {
                    guard let self, gen == self.engineGeneration else { return }
                    self.calculation = engine
                    self.modelErrors = errors
                    self.computedData = computed
                    self.engineDidLoad()
                    self.refreshVisuals()
                }
            }
        }
    }

    /// Visual types that can show a cross-highlight (others are always cross-filtered).
    static let highlightable: Set<VisualType> = [
        .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
        .lineStackedColumn, .lineClusteredColumn, .pie, .donut, .treemap, .funnel, .area, .stackedArea, .ribbon, .waterfall,
    ]

    func interaction(from source: UUID, to target: VisualSpec, on page: Page) -> InteractionMode {
        if let m = page.interactions[source]?[target.id] { return m }
        var mode = doc.report.settings.disableCrossHighlightByDefault ? .filter : doc.report.settings.defaultInteraction
        // Slicers only ever filter, and only some visuals can show a highlight.
        if mode == .highlight, !Self.highlightable.contains(target.type) || page.visual(source)?.type.isSlicer == true { mode = .filter }
        return mode
    }

    /// All filters that apply to a visual: report, page, drillthrough, and its own (as last applied,
    /// when the report has an Apply button and edits are waiting).
    func filters(for spec: VisualSpec, on page: Page) -> [FilterSpec] {
        let held = doc.report.settings.filterPaneApplyButton ? ReportRuntime.existing(for: self)?.heldFilters : nil
        return FilterTools.effective(report: doc.report, page: page, visual: spec,
                                     drillthrough: drillthroughFilters[page.id] ?? [], held: held)
    }

    /// Adds a filter on a field at the given scope, announced in the undo history.
    func addFilter(_ field: FieldRef, scope: FilterSpec.Scope, announce: Bool = false) {
        let filter = FilterSpec(field: field)
        switch scope {
        case .visual:
            guard let id = selectedVisual?.id else { return }
            updateVisual(id, name: announce ? "Add Visual Filter" : "Change Visual Filters", invalidates: filterInvalidation(.visuals([id]), holding: .visual(id))) {
                guard !$0.filters.contains(where: { $0.field.key == field.key }) else { return }
                $0.filters.append(filter)
            }
        case .page:
            updatePage(name: announce ? "Add Page Filter" : "Change Page Filters", invalidates: filterInvalidation(.visuals(nil), holding: .page(currentPageID))) {
                guard !$0.filters.contains(where: { $0.field.key == field.key }) else { return }
                $0.filters.append(filter)
            }
        case .report:
            mutate(announce ? "Add Report Filter" : "Change Report Filters", invalidates: filterInvalidation(.visuals(nil), holding: .report)) {
                guard !$0.report.filters.contains(where: { $0.field.key == field.key }) else { return }
                $0.report.filters.append(filter)
            }
        case .drillthrough:
            addDrillthroughField(field)
        }
    }

    /// Removes one filter (by id) at the given scope.
    func removeFilter(id: UUID, scope: FilterSpec.Scope) {
        switch scope {
        case .visual:
            guard let target = selectedVisual?.id else { return }
            updateVisual(target, name: "Remove Visual Filter", invalidates: filterInvalidation(.visuals([target]), holding: .visual(target))) { $0.filters.removeAll { $0.id == id } }
        case .page:
            updatePage(name: "Remove Page Filter", invalidates: filterInvalidation(.visuals(nil), holding: .page(currentPageID))) { $0.filters.removeAll { $0.id == id } }
        case .report:
            mutate("Remove Report Filter", invalidates: filterInvalidation(.visuals(nil), holding: .report)) { $0.report.filters.removeAll { $0.id == id } }
        case .drillthrough:
            // A drillthrough field belongs to the page; a kept filter only to this visit.
            if currentPage.drillthroughFilters.contains(where: { $0.id == id }) {
                updatePage(name: "Remove Drillthrough Field", invalidates: .visuals(nil)) { $0.drillthroughFilters.removeAll { $0.id == id } }
            }
            if var list = drillthroughFilters[currentPageID] {
                list.removeAll { $0.id == id }
                drillthroughFilters[currentPageID] = list.isEmpty ? nil : list
                refreshVisuals()
            }
        }
    }

    /// Updates one filter (by id) at the given scope.
    func updateFilter(id: UUID, scope: FilterSpec.Scope, name: String = "Change Filter", _ body: (inout FilterSpec) -> Void) {
        switch scope {
        case .visual:
            guard let target = selectedVisual?.id else { return }
            updateVisual(target, name: name, invalidates: filterInvalidation(.visuals([target]), holding: .visual(target))) {
                if let i = $0.filters.firstIndex(where: { $0.id == id }) { body(&$0.filters[i]) }
            }
        case .page:
            updatePage(name: name, invalidates: filterInvalidation(.visuals(nil), holding: .page(currentPageID))) {
                if let i = $0.filters.firstIndex(where: { $0.id == id }) { body(&$0.filters[i]) }
            }
        case .report:
            mutate(name, invalidates: filterInvalidation(.visuals(nil), holding: .report)) {
                if let i = $0.report.filters.firstIndex(where: { $0.id == id }) { body(&$0.report.filters[i]) }
            }
        case .drillthrough:
            // Author controls (lock, hide, name) are saved with the page's drillthrough field; the value
            // that arrived, and any kept filter, change only for this visit.
            if currentPage.drillthroughFilters.contains(where: { $0.id == id }) {
                updatePage(name: name) { p in
                    guard let i = p.drillthroughFilters.firstIndex(where: { $0.id == id }) else { return }
                    var edited = p.drillthroughFilters[i]
                    body(&edited)
                    p.drillthroughFilters[i].isLocked = edited.isLocked
                    p.drillthroughFilters[i].isHidden = edited.isHidden
                    p.drillthroughFilters[i].displayName = edited.displayName
                }
            }
            if var list = drillthroughFilters[currentPageID], let i = list.firstIndex(where: { $0.id == id }) {
                body(&list[i])
                drillthroughFilters[currentPageID] = list
                refreshVisuals()
            }
        }
    }

    /// Replaces the filters a drillthrough carried to a page (nil clears them).
    func setAppliedDrillthrough(_ filters: [FilterSpec]?, for pageID: UUID) {
        drillthroughFilters[pageID] = filters
    }

    func request(for spec: VisualSpec, on page: Page) -> VisualRequest {
        var r = VisualRequest()
        r.filters = filters(for: spec, on: page)
        for other in page.visuals where other.id != spec.id && other.type.isSlicer {
            guard let state = other.slicerState, state.isActive else { continue }
            if page.interactions[other.id]?[spec.id] == InteractionMode.none { continue }
            r.slicers.append(.init(fields: other.fields(.field), state: state, type: other.type,
                                   matchOperator: other.fmtString("slicer", "operator", "contains")))
        }
        for (source, points) in pointSelections where source != spec.id && !points.isEmpty {
            switch interaction(from: source, to: spec, on: page) {
            case .filter: r.crossFilters.append(points)
            case .highlight: r.highlights.append(points)
            case .none: break
            }
        }
        return r
    }

    /// Requery visuals on the current page. Results arrive progressively; stale results are dropped.
    func refreshVisuals(_ ids: [UUID]? = nil) {
        let page = currentPage
        var targets = page.visuals.filter(FormatBindings.queriesData)
        if let ids { let set = Set(ids); targets = targets.filter { set.contains($0.id) } }
        guard !targets.isEmpty else { return }
        if visualsPaused {
            pendingWhilePaused.formUnion(targets.map(\.id))
            return
        }
        pendingWhilePaused.subtract(targets.map(\.id))
        generation += 1
        let gen = generation
        let jobs = targets.map { ($0, request(for: $0, on: page)) }
        loadingVisuals.formUnion(targets.map(\.id))
        let engine = calculation, analytics = services.analytics
        let recording = performanceRecording
        calcQueue.async { [weak self] in
            for (spec, request) in jobs {
                let start = CFAbsoluteTimeGetCurrent()
                let data = engine.visualData(spec: spec, request: request)
                let overlay = spec.analytics.isEmpty ? AnalyticsOverlays() : analytics.overlays(spec: spec, data: data)
                let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
                TraceLog.shared.record("visual.query", ["visualType": .name(spec.type.rawValue), "ms": .milliseconds(total),
                                                        "queryMs": .milliseconds(data.queryMilliseconds),
                                                        "rows": .count(data.table.rowCount), "failed": .flag(data.error != nil)])
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loadingVisuals.remove(spec.id)
                    // A newer refresh for this visual supersedes this result only if it targeted the same visual;
                    // accepting slightly stale data briefly is better than flashing empty.
                    if gen < self.generation, self.loadingVisuals.contains(spec.id) { return }
                    self.visualData[spec.id] = data
                    self.overlays[spec.id] = overlay
                    if recording {
                        self.performanceLog.append(PerformanceEvent(
                            visualID: spec.id, visualName: spec.name, queryMilliseconds: data.queryMilliseconds,
                            totalMilliseconds: total, dax: data.daxQuery, delivered: CFAbsoluteTimeGetCurrent()))
                    }
                }
            }
        }
    }
    func clearPerformanceLog() { performanceLog.removeAll() }

    /// The visual was drawn with an event's results at `time`: that is its display time, added to the total once.
    func visualDisplayed(_ eventID: UUID, at time: CFAbsoluteTime) {
        guard let i = performanceLog.lastIndex(where: { $0.id == eventID }), performanceLog[i].displayMilliseconds == nil,
              let delivered = performanceLog[i].delivered else { return }
        let ms = max(0, (time - delivered) * 1000)
        performanceLog[i].displayMilliseconds = ms
        performanceLog[i].totalMilliseconds += ms
    }

    /// Run work against the engine off the main thread.
    func withEngine<T>(_ work: @escaping (CalculationService) -> T) async -> T {
        let engine = calculation
        return await withCheckedContinuation { cont in
            calcQueue.async { cont.resume(returning: work(engine)) }
        }
    }

    // MARK: - Pages

    func goToPage(_ id: UUID, recordHistory: Bool = true) {
        guard id != currentPageID, doc.report.pages.contains(where: { $0.id == id }) else { return }
        if recordHistory { pageHistory.append(currentPageID) }
        currentPageID = id
        selection = []; pointSelections = [:]; editInteractionsFor = nil
        refreshVisuals()
    }
    func goBack() {
        guard let last = pageHistory.popLast() else { return }
        drillthroughFilters[currentPageID] = nil
        goToPage(last, recordHistory: false)
    }
    func addPage(named name: String? = nil, size: PageSize? = nil, tooltip: Bool = false) {
        var p = Page(name: name ?? uniquePageName("Page"))
        p.size = size ?? doc.report.theme.defaultPageSize ?? .widescreen
        p.isTooltipPage = tooltip
        if tooltip { p.size = .tooltip; p.isHidden = true }
        let at = pageIndex + 1
        mutate("Add Page", invalidates: .layout) { $0.report.pages.insert(p, at: min(at, $0.report.pages.count)) }
        goToPage(p.id)
    }
    func duplicatePage(_ id: UUID) {
        guard var p = doc.report.page(id), let i = doc.report.pages.firstIndex(where: { $0.id == id }) else { return }
        var map: [UUID: UUID] = [:]
        p.id = UUID(); p.name = uniquePageName("\(p.name) copy", exact: true)
        for v in p.visuals.indices { let n = UUID(); map[p.visuals[v].id] = n; p.visuals[v].id = n }
        p.interactions = Dictionary(uniqueKeysWithValues: p.interactions.compactMap { src, targets in
            guard let s = map[src] else { return nil }
            return (s, Dictionary(uniqueKeysWithValues: targets.compactMap { t, m in map[t].map { ($0, m) } }))
        })
        mutate("Duplicate Page", invalidates: .layout) { $0.report.pages.insert(p, at: i + 1) }
        goToPage(p.id)
    }
    func deletePage(_ id: UUID) {
        guard doc.report.pages.count > 1 else { return }
        mutate("Delete Page", invalidates: .layout) { d in
            d.report.pages.removeAll { $0.id == id }
            d.report.bookmarks.removeAll { $0.pageID == id }
            if d.report.landingPageID == id { d.report.landingPageID = nil }
        }
        refreshVisuals()
    }
    func movePage(from: Int, to: Int) {
        mutate("Reorder Pages", invalidates: .layout) { d in
            guard d.report.pages.indices.contains(from) else { return }
            let p = d.report.pages.remove(at: from)
            d.report.pages.insert(p, at: max(0, min(to, d.report.pages.count)))
        }
    }
    private func uniquePageName(_ base: String, exact: Bool = false) -> String {
        let names = Set(doc.report.pages.map(\.name))
        if exact, !names.contains(base) { return base }
        var n = exact ? 2 : doc.report.pages.count + 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Visual creation and arrangement

    static func defaultSize(for type: VisualType) -> (w: Double, h: Double) {
        switch type {
        case .card, .cardLegacy, .kpi: return (220, 130)
        case .slicer, .listSlicer: return (200, 240)
        case .buttonSlicer, .inputSlicer: return (300, 90)
        case .textBox: return (320, 80)
        case .button: return (140, 44)
        case .shape, .image: return (160, 160)
        case .pageNavigator, .bookmarkNavigator: return (420, 48)
        case .table, .matrix: return (460, 300)
        case .gauge: return (260, 200)
        default: return (420, 280)
        }
    }

    @discardableResult
    func addVisual(_ type: VisualType, at point: CGPoint? = nil, configure: ((inout VisualSpec) -> Void)? = nil) -> UUID {
        let page = currentPage
        let size = Self.defaultSize(for: type)
        var origin = point ?? freeSpot(for: size, on: page)
        origin.x = max(0, min(origin.x, page.size.width - size.w))
        origin.y = max(0, min(origin.y, page.size.height - size.h))
        var spec = VisualSpec(type: type, frame: Frame(x: origin.x, y: origin.y, width: size.w, height: size.h))
        spec.zIndex = (page.visuals.map(\.zIndex).max() ?? 0) + 1
        spec.tabOrder = page.visuals.count
        spec.name = uniqueVisualName(type.displayName, on: page)
        configure?(&spec)
        let i = pageIndex
        mutate("Add \(type.displayName)", invalidates: .visuals([spec.id])) { $0.report.pages[i].visuals.append(spec) }
        selection = [spec.id]
        if type.isPageElement { inspector = .format } else { inspector = .build }
        return spec.id
    }

    /// First position on a coarse grid where a new visual doesn't overlap existing ones.
    private func freeSpot(for size: (w: Double, h: Double), on page: Page) -> CGPoint {
        let margin = 24.0, step = 24.0
        let taken = page.visuals.map(\.frame.cgRect)
        var y = margin
        while y + size.h <= page.size.height - margin {
            var x = margin
            while x + size.w <= page.size.width - margin {
                let r = CGRect(x: x, y: y, width: size.w, height: size.h).insetBy(dx: -8, dy: -8)
                if !taken.contains(where: { $0.intersects(r) }) { return CGPoint(x: x, y: y) }
                x += step
            }
            y += step
        }
        let n = Double(page.visuals.count % 8)
        return CGPoint(x: margin + n * 24, y: margin + n * 24)
    }
    private func uniqueVisualName(_ base: String, on page: Page) -> String {
        let names = Set(page.visuals.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection, i = pageIndex
        mutate(ids.count == 1 ? "Delete Visual" : "Delete Visuals", invalidates: .visuals(nil)) { d in
            d.report.pages[i].visuals.removeAll { ids.contains($0.id) }
            for id in ids { d.report.pages[i].interactions[id] = nil }
        }
        for id in ids { visualData[id] = nil; pointSelections[id] = nil }
        selection = []
    }

    func duplicateSelection(offset: Double = 16) {
        let copies = selectedVisuals.map { v -> VisualSpec in
            var c = v; c.id = UUID(); c.frame.x += offset; c.frame.y += offset; c.zIndex += 100
            c.name = v.name + " copy"
            return c
        }
        insert(copies, name: "Duplicate")
    }
    func insert(_ visuals: [VisualSpec], name: String) {
        guard !visuals.isEmpty else { return }
        let i = pageIndex
        mutate(name, invalidates: .visuals(visuals.map(\.id))) { $0.report.pages[i].visuals.append(contentsOf: visuals) }
        selection = Set(visuals.map(\.id))
    }

    static let pasteboardType = NSPasteboard.PasteboardType("com.facet.visuals")
    func copySelection() {
        guard !selection.isEmpty, let data = try? JSONEncoder().encode(selectedVisuals) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
    }
    func cutSelection() { copySelection(); deleteSelection() }
    func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              var visuals = try? JSONDecoder().decode([VisualSpec].self, from: data) else { return }
        let existing = currentPage.visuals.map(\.frame)
        for i in visuals.indices {
            visuals[i].id = UUID()
            if existing.contains(where: { $0.x == visuals[i].frame.x && $0.y == visuals[i].frame.y }) {
                visuals[i].frame.x += 16; visuals[i].frame.y += 16
            }
        }
        insert(visuals, name: "Paste")
    }

    enum Arrangement { case left, centerH, right, top, centerV, bottom, distributeH, distributeV, sameWidth, sameHeight, sameSize }
    func arrange(_ a: Arrangement) {
        let sel = selectedVisuals
        guard !sel.isEmpty else { return }
        // With one visual selected, align to the page. In the phone layout, arrange the phone frames.
        let size = canvasSize
        let rects = sel.map { frame(of: $0).cgRect }
        let bounds = sel.count == 1 ? CGRect(x: 0, y: 0, width: size.width, height: size.height)
            : rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        var frames = Dictionary(uniqueKeysWithValues: sel.map { ($0.id, frame(of: $0)) })
        func each(_ body: (inout Frame) -> Void) {
            for k in Array(frames.keys) { if var f = frames[k] { body(&f); frames[k] = f } }
        }
        let first = frame(of: sel[0])
        switch a {
        case .left: each { $0.x = bounds.minX }
        case .right: each { $0.x = bounds.maxX - $0.width }
        case .centerH: each { $0.x = bounds.midX - $0.width / 2 }
        case .top: each { $0.y = bounds.minY }
        case .bottom: each { $0.y = bounds.maxY - $0.height }
        case .centerV: each { $0.y = bounds.midY - $0.height / 2 }
        case .distributeH:
            let sorted = sel.map { frame(of: $0) }.enumerated().sorted { $0.element.x < $1.element.x }
            guard sorted.count > 2 else { return }
            let gap = (bounds.width - sorted.reduce(0) { $0 + $1.element.width }) / Double(sorted.count - 1)
            var x = bounds.minX
            for (i, f) in sorted { frames[sel[i].id]?.x = x; x += f.width + gap }
        case .distributeV:
            let sorted = sel.map { frame(of: $0) }.enumerated().sorted { $0.element.y < $1.element.y }
            guard sorted.count > 2 else { return }
            let gap = (bounds.height - sorted.reduce(0) { $0 + $1.element.height }) / Double(sorted.count - 1)
            var y = bounds.minY
            for (i, f) in sorted { frames[sel[i].id]?.y = y; y += f.height + gap }
        case .sameWidth: each { $0.width = first.width }
        case .sameHeight: each { $0.height = first.height }
        case .sameSize: each { $0.width = first.width; $0.height = first.height }
        }
        setFrames(frames, name: "Arrange")
    }
    func setFrames(_ frames: [UUID: Frame], name: String = "Move", coalesce: String? = nil) {
        let i = pageIndex
        mutate(name, coalesce: coalesce, invalidates: .layout) { d in
            for v in d.report.pages[i].visuals.indices {
                if let f = frames[d.report.pages[i].visuals[v].id] {
                    if self.mobileLayout { d.report.pages[i].visuals[v].mobileFrame = f; d.report.pages[i].hasMobileLayout = true }
                    else { d.report.pages[i].visuals[v].frame = f }
                }
            }
        }
    }

    enum LayerMove { case front, forward, backward, back }
    func reorder(_ move: LayerMove) {
        let ids = selection, i = pageIndex
        guard !ids.isEmpty else { return }
        mutate("Change Layer Order", invalidates: .layout) { d in
            var ordered = d.report.pages[i].visuals.sorted { $0.zIndex < $1.zIndex }
            let moving = ordered.filter { ids.contains($0.id) }
            switch move {
            case .front: ordered.removeAll { ids.contains($0.id) }; ordered.append(contentsOf: moving)
            case .back: ordered.removeAll { ids.contains($0.id) }; ordered.insert(contentsOf: moving, at: 0)
            case .forward:
                for k in stride(from: ordered.count - 2, through: 0, by: -1)
                where ids.contains(ordered[k].id) && !ids.contains(ordered[k + 1].id) { ordered.swapAt(k, k + 1) }
            case .backward:
                for k in 1..<max(1, ordered.count)
                where ids.contains(ordered[k].id) && !ids.contains(ordered[k - 1].id) { ordered.swapAt(k, k - 1) }
            }
            let z = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
            for v in d.report.pages[i].visuals.indices {
                d.report.pages[i].visuals[v].zIndex = z[d.report.pages[i].visuals[v].id] ?? 0
            }
        }
    }

    func groupSelection() {
        guard selection.count > 1 else { return }
        let ids = selection, i = pageIndex, gid = UUID()
        mutate("Group", invalidates: .layout) { d in
            let n = d.report.pages[i].groups.count + 1
            d.report.pages[i].groups[gid] = "Group \(n)"
            for v in d.report.pages[i].visuals.indices where ids.contains(d.report.pages[i].visuals[v].id) {
                d.report.pages[i].visuals[v].groupID = gid
            }
        }
    }
    func ungroupSelection() {
        let gids = Set(selectedVisuals.compactMap(\.groupID)), i = pageIndex
        guard !gids.isEmpty else { return }
        mutate("Ungroup", invalidates: .layout) { d in
            for v in d.report.pages[i].visuals.indices {
                if let g = d.report.pages[i].visuals[v].groupID, gids.contains(g) { d.report.pages[i].visuals[v].groupID = nil }
            }
            for g in gids { d.report.pages[i].groups[g] = nil }
        }
    }
    /// Expand a selection to whole groups.
    func withGroupMembers(_ ids: Set<UUID>) -> Set<UUID> {
        let gids = Set(currentPage.visuals.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !gids.isEmpty else { return ids }
        return ids.union(currentPage.visuals.filter { $0.groupID.map(gids.contains) ?? false }.map(\.id))
    }

    /// Change a visual's type, carrying fields over to the closest wells of the new type.
    func changeType(of id: UUID, to type: VisualType) {
        updateVisual(id, name: "Change Visual Type") { v in
            VisualRetype.apply(&v, to: type) { self.defaultAggregation(for: $0) }
        }
    }

    func defaultAggregation(for field: FieldRef) -> Aggregation {
        guard field.kind == .column, let col = doc.model.table(field.table)?.column(field.name) else { return .none }
        if col.summarizeBy != .none { return col.summarizeBy }
        // A position is averaged, never added up, and a date summarizes to its earliest value.
        if col.dataCategory == .latitude || col.dataCategory == .longitude { return .average }
        if col.dataType.isTemporal { return .min }
        return col.dataType.isNumeric ? .sum : .count
    }

    /// Add a field to the selected visual (or create a suitable new visual), choosing the natural well.
    func addField(_ field: FieldRef, to visualID: UUID? = nil, well: Well? = nil) {
        let target = visualID ?? selectedVisual?.id
        let isNumeric: Bool = {
            if field.kind == .measure { return true }
            guard let c = doc.model.table(field.table)?.column(field.name) else { return false }
            return c.dataType.isNumeric && c.summarizeBy != .none
        }()
        guard let id = target, let spec = visual(id), !spec.type.wells.isEmpty else {
            // No target: numeric → column chart; date → line; text → table.
            let col = doc.model.table(field.table)?.column(field.name)
            let type: VisualType = isNumeric ? .clusteredColumn : (col?.dataType.isTemporal == true ? .line : .table)
            addVisual(type) { v in
                var f = field
                if isNumeric, f.kind == .column { f.aggregation = self.defaultAggregation(for: f) }
                let w: Well = type == .table ? .values : (isNumeric ? .values : .category)
                v.setFields(w, [f])
            }
            return
        }
        let wells = spec.type.wells
        let chosen: Well = well ?? {
            if isNumeric {
                return wells.first { !$0.isGrouping && $0 != .tooltips && spec.fields($0).isEmpty }
                    ?? wells.first { !$0.isGrouping && $0 != .tooltips } ?? wells[0]
            }
            return wells.first { $0.isGrouping && spec.fields($0).isEmpty } ?? wells.first { $0.isGrouping } ?? wells[0]
        }()
        var f = field
        f.id = UUID()
        if !chosen.isGrouping, f.kind == .column, !(spec.type == .table) { f.aggregation = defaultAggregation(for: f) }
        if spec.type == .table, f.kind == .column, isNumeric { f.aggregation = defaultAggregation(for: f) }
        // An End well takes the latest date where a Start well takes the earliest.
        if chosen == .end, f.kind == .column, f.aggregation == .min { f.aggregation = .max }
        updateVisual(id, name: "Add Field") { v in v.setFields(chosen, v.fields(chosen) + [f]) }
    }

    // MARK: - Interaction: selection, slicers, drill, actions

    func selectPoints(_ points: [DataPointSelection], in visualID: UUID, additive: Bool) {
        var current = pointSelections[visualID] ?? []
        if points.isEmpty { current = [] }
        else if additive {
            for p in points {
                if let i = current.firstIndex(where: { $0.key == p.key }) { current.remove(at: i) } else { current.append(p) }
            }
        } else if current.count == 1, points.count == 1, current[0].key == points[0].key { current = [] }
        else { current = points }
        if current.isEmpty { pointSelections[visualID] = nil } else { pointSelections[visualID] = current }
        refreshVisuals(currentPage.visuals.filter { $0.id != visualID }.map(\.id))
    }
    /// Drops one visual's data point selection; the visuals it cross-filtered requery without it.
    private func clearSelection(of visualID: UUID) {
        guard pointSelections[visualID] != nil else { return }
        pointSelections[visualID] = nil
        refreshVisuals(currentPage.visuals.filter { $0.id != visualID }.map(\.id))
    }
    func clearPointSelections() {
        guard !pointSelections.isEmpty else { return }
        pointSelections = [:]
        refreshVisuals()
    }

    func setSlicerState(_ state: SlicerState, for id: UUID) {
        guard let spec = visual(id) else { return }
        let group = spec.syncGroup
        mutate("Change Slicer", coalesce: "slicer-\(id)", invalidates: .visuals(nil)) { d in
            for p in d.report.pages.indices {
                for v in d.report.pages[p].visuals.indices {
                    let s = d.report.pages[p].visuals[v]
                    if s.id == id || (group != nil && s.syncGroup == group) {
                        d.report.pages[p].visuals[v].slicerState = state.isActive ? state : nil
                    }
                }
            }
        }
    }
    /// Clear every slicer on this page — and the slicers synced with them on other pages — including
    /// selections still waiting for "Apply all slicers".
    func clearAllSlicers() {
        let page = currentPage
        ReportRuntime.existing(for: self)?.dropPendingSlicers(on: page)
        let ids = Set(page.visuals.filter(\.type.isSlicer).map(\.id))
        let groups = Set(page.visuals.filter(\.type.isSlicer).compactMap(\.syncGroup))
        mutate("Clear All Slicers") { d in
            for p in d.report.pages.indices {
                for v in d.report.pages[p].visuals.indices where d.report.pages[p].visuals[v].type.isSlicer {
                    let s = d.report.pages[p].visuals[v]
                    if ids.contains(s.id) || s.syncGroup.map(groups.contains) == true { d.report.pages[p].visuals[v].slicerState = nil }
                }
            }
        }
    }

    func drill(_ action: DrillAction, in id: UUID) {
        switch action {
        case .down(let point):
            updateVisual(id, name: "Drill Down") { v in
                let levels = v.fields(.category).count + (v.type == .matrix ? v.fields(.rows).count : 0)
                guard v.drillLevel < max(0, levels - 1) else { return }
                if let point, let value = point.values[safe: min(v.drillLevel, point.values.count - 1)] {
                    v.drillPath.append(value)
                } else { v.drillPath = [] }
                v.drillLevel += 1
                v.expandedAllLevels = false
            }
            clearSelection(of: id)
        case .up:
            updateVisual(id, name: "Drill Up") { v in
                guard v.drillLevel > 0 else { return }
                v.drillLevel -= 1
                if !v.drillPath.isEmpty { v.drillPath.removeLast() }
                if v.drillLevel == 0 { v.expandedAllLevels = false }
            }
            clearSelection(of: id)
        case .expandAll:
            updateVisual(id, name: "Expand to Next Level") { v in
                guard v.drillLevel < max(0, v.fields(.category).count - 1) else { return }
                v.drillLevel += 1; v.expandedAllLevels = true; v.drillPath = []
            }
        case .drillthrough(let point, let pageID):
            drillthrough(point, to: pageID, from: id)
        case .showAsTable:
            showAsTableID = id
        }
    }

    func perform(_ action: ActionSpec, from visualID: UUID? = nil) {
        if let measure = action.conditionalMeasure, [.bookmark, .pageNavigation, .drillthrough, .webURL].contains(action.kind) {
            performConditional(action, measure: measure, from: visualID)
            return
        }
        switch action.kind {
        case .none: break
        case .back: goBack()
        case .bookmark: if let id = action.bookmarkID { applyBookmark(id) }
        case .pageNavigation: if let id = action.pageID { goToPage(id) }
        case .webURL:
            if let url = URL(string: action.url), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        case .clearAllSlicers: clearAllSlicers()
        case .applyAllSlicers: applyAllSlicers()
        case .qna: inspector = .assistant; inspectorVisible = true
        case .drillthrough: performDrillthroughButton(action)
        case .dataFunction:
            NotificationCenter.default.post(name: .facetRunDataFunction, object: self, userInfo: ["action": action])
        }
    }

    // MARK: - Bookmarks

    func captureState() -> BookmarkState {
        let page = currentPage
        var s = BookmarkState()
        s.pageFilters = page.filters
        s.reportFilters = doc.report.filters
        for v in page.visuals {
            if let st = v.slicerState { s.slicerStates[v.id] = st }
            if !v.filters.isEmpty { s.visualFilters[v.id] = v.filters }
            if v.isHidden { s.hiddenVisuals.append(v.id) }
            if !v.sort.isEmpty { s.sorts[v.id] = v.sort }
            if v.drillLevel > 0 { s.drillLevels[v.id] = v.drillLevel; s.drillPaths[v.id] = v.drillPath }
        }
        for (id, points) in pointSelections { s.selections[id] = points.map(\.values) }
        return s
    }
    @discardableResult
    func addBookmark(named name: String? = nil) -> UUID {
        var b = Bookmark(name: name ?? "Bookmark \(doc.report.bookmarks.count + 1)", pageID: currentPageID)
        b.state = captureState()
        mutate("Add Bookmark", invalidates: .layout) { $0.report.bookmarks.append(b) }
        return b.id
    }
    func updateBookmark(_ id: UUID) {
        let state = captureState(), page = currentPageID
        mutate("Update Bookmark", invalidates: .layout) { d in
            guard let i = d.report.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            d.report.bookmarks[i].state = state
            d.report.bookmarks[i].pageID = page
        }
    }
    func applyBookmark(_ id: UUID) {
        guard let b = doc.report.bookmarks.first(where: { $0.id == id }) else { return }
        if b.appliesCurrentPage, b.pageID != currentPageID { goToPage(b.pageID) }
        guard let pi = doc.report.pages.firstIndex(where: { $0.id == b.pageID }) else { return }
        let scope = b.selectedVisualIDs.map(Set.init)
        func inScope(_ v: UUID) -> Bool { scope?.contains(v) ?? true }
        // Applying a bookmark is a view change, not an edit: it doesn't dirty the undo stack.
        var d = doc
        if b.appliesData {
            if scope == nil { d.report.pages[pi].filters = b.state.pageFilters; d.report.filters = b.state.reportFilters }
            for v in d.report.pages[pi].visuals.indices {
                let vid = d.report.pages[pi].visuals[v].id
                guard inScope(vid) else { continue }
                if d.report.pages[pi].visuals[v].type.isSlicer { d.report.pages[pi].visuals[v].slicerState = b.state.slicerStates[vid] }
                d.report.pages[pi].visuals[v].filters = b.state.visualFilters[vid] ?? []
                d.report.pages[pi].visuals[v].sort = b.state.sorts[vid] ?? d.report.pages[pi].visuals[v].sort
                d.report.pages[pi].visuals[v].drillLevel = b.state.drillLevels[vid] ?? 0
                d.report.pages[pi].visuals[v].drillPath = b.state.drillPaths[vid] ?? []
            }
        }
        if b.appliesDisplay {
            let hidden = Set(b.state.hiddenVisuals)
            for v in d.report.pages[pi].visuals.indices where inScope(d.report.pages[pi].visuals[v].id) {
                d.report.pages[pi].visuals[v].isHidden = hidden.contains(d.report.pages[pi].visuals[v].id)
            }
        }
        doc = d
        if b.appliesData {
            var sel: [UUID: [DataPointSelection]] = [:]
            for (vid, rows) in b.state.selections where inScope(vid) {
                guard let spec = d.report.pages[pi].visual(vid) else { continue }
                let fields = spec.type.wells.filter(\.isGrouping).flatMap { spec.fields($0) }
                sel[vid] = rows.map { DataPointSelection(fields: Array(fields.prefix($0.count)), values: $0) }
            }
            pointSelections = sel
        }
        activeBookmarkID = id
        refreshVisuals()
    }

    // MARK: - Data

    /// Install freshly loaded tables and make sure the model has matching table metadata. Tables new to the
    /// model get the relationships autodetect finds, in the same undo step, when the option is on.
    func installTables(_ tables: [DataTable], sourceQueries: [String: String] = [:], actionName: String = "Load Data",
                       joiningUndo group: UUID? = nil) {
        mutate(actionName, joining: group, invalidates: .model) { d in
            var added = Set<String>()
            for t in tables {
                d.data[t.name] = t
                if let i = d.model.tableIndex(t.name) {
                    // Reconcile columns: keep metadata for surviving columns, add new ones, drop missing source columns.
                    var cols: [ModelColumn] = []
                    for c in t.columns {
                        if var existing = d.model.tables[i].column(c.name) {
                            if existing.dataType == .any || !existing.isCalculated { existing.dataType = c.type }
                            cols.append(existing)
                        } else { cols.append(Self.modelColumn(for: c)) }
                    }
                    cols += d.model.tables[i].columns.filter { $0.isCalculated && t.columnIndex($0.name) == nil }
                    d.model.tables[i].columns = cols
                } else {
                    var mt = ModelTable(name: t.name, columns: t.columns.map(Self.modelColumn))
                    mt.sourceQuery = sourceQueries[t.name]
                    d.model.tables.append(mt)
                    added.insert(t.name)
                }
            }
            if DataLoadOptions.autodetectRelationships(for: d) {
                d.model.relationships += DataLoadOptions.relationships(afterLoading: added, in: d)
            }
        }
    }
    static func modelColumn(for c: DataColumn) -> ModelColumn {
        var m = ModelColumn(name: c.name, dataType: c.type == .any ? .text : c.type)
        let lower = c.name.lowercased()
        // Identifiers and years are numbers you don't add up.
        if m.dataType.isNumeric, lower.hasSuffix("id") || lower.hasSuffix("key") || lower.contains("year") || lower == "zip"
            || lower.contains("postal") || lower.hasSuffix("code") || lower.hasSuffix("number") {
            m.summarizeBy = .none
        }
        switch m.dataType {
        case .currency: m.formatString = "#,0.00"
        case .date: m.formatString = "d MMM yyyy"
        default: break
        }
        if lower == "country" || lower == "country/region" { m.dataCategory = .country }
        else if lower == "city" { m.dataCategory = .city }
        else if lower == "state" || lower == "province" || lower == "state or province" { m.dataCategory = .stateOrProvince }
        else if lower == "latitude" || lower == "lat" { m.dataCategory = .latitude; m.summarizeBy = .none }
        else if lower == "longitude" || lower == "lon" || lower == "lng" { m.dataCategory = .longitude; m.summarizeBy = .none }
        else if lower.hasSuffix("url") { m.dataCategory = .webURL }
        return m
    }

    /// Refresh data by re-running Power Query queries (all, or only the named ones). With `group`, the loaded tables
    /// join that undo step (Close & Apply, a storage mode switch) instead of adding a "Refresh Data" step.
    func refreshData(only names: [String]? = nil, joiningUndo group: UUID? = nil) {
        let queries = doc.queries
        guard !queries.isEmpty else {
            status = StatusMessage(kind: .info, text: "This document has no queries to refresh.")
            return
        }
        let base = fileURL?.deletingLastPathComponent()
        // DirectQuery tables aren't imported: Refresh makes their next query read the source again.
        let direct = Set(DirectQuerySession.tables(doc.model, queries: queries).map(\.query))
        let only = direct.isEmpty ? names : (names ?? queries.filter { $0.kind == .table && $0.loadEnabled && $0.includeInRefresh }.map(\.name))
            .filter { !direct.contains($0) }
        if !direct.isEmpty { DirectQuerySession.of(self).invalidate() }
        refreshProgress = RefreshProgress(query: "", message: "Starting refresh…", fraction: 0)
        let start = DispatchTime.now()
        Task {
            let results = await services.query.refresh(queries: queries, only: only, baseDirectory: base) { p in
                DispatchQueue.main.async { self.refreshProgress = p }
            }
            Self.trace(refresh: results, since: start)
            var tables: [DataTable] = [], failures: [String] = []
            for (name, result) in results {
                switch result {
                case .success(var t): t.name = name; tables.append(t)
                case .failure(let e): failures.append("\(name): \(e.localizedDescription)")
                }
            }
            self.refreshProgress = nil
            if !tables.isEmpty {
                self.installTables(tables, sourceQueries: Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.name) }),
                                   actionName: "Refresh Data", joiningUndo: group)
            } else if !direct.isEmpty {
                self.reloadEngine()
            }
            self.status = failures.isEmpty
                ? StatusMessage(kind: .success, text: "Refreshed \(tables.count) table\(tables.count == 1 ? "" : "s")."
                                + (direct.isEmpty ? "" : " DirectQuery tables read their sources again."))
                : StatusMessage(kind: .error, text: failures.joined(separator: "\n"))
        }
    }
}

extension DocumentStore {
    /// Settings ▸ Diagnostics ▸ tracing: each query's row count or failure, and the refresh's duration.
    nonisolated static func trace(refresh results: [String: Result<DataTable, Error>], since start: DispatchTime) {
        var failures = 0
        for (name, result) in results.sorted(by: { $0.key < $1.key }) {
            switch result {
            case .success(let t): TraceLog.shared.record("refresh.query", ["query": .name(name), "rows": .count(t.rowCount)])
            case .failure: failures += 1; TraceLog.shared.record("refresh.query", ["query": .name(name), "failed": .flag(true)])
            }
        }
        TraceLog.shared.record("refresh", ["ms": .milliseconds(TraceLog.milliseconds(since: start)),
                                           "queries": .count(results.count), "failures": .count(failures)])
    }
}

/// A modal sheet. Features present arbitrary content without the store knowing their types.
struct SheetRequest: Identifiable {
    let id = UUID()
    var view: AnyView
}

extension DocumentStore {
    /// Present a sheet over this document's window.
    func present<V: View>(@ViewBuilder _ content: () -> V) {
        sheet = SheetRequest(view: AnyView(content().environmentObject(self)))
    }
    func dismissSheet() { sheet = nil }
}

extension Notification.Name {
    static let facetRunDataFunction = Notification.Name("facet.runDataFunction")
}
