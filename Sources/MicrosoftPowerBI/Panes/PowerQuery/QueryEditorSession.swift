import SwiftUI
import Combine
import FacetCore
import FacetQuery

/// The state of one Power Query Editor window: the pending queries (edited here and written to the document only
/// on Apply), the selected query, step and columns, the data preview with its profiles and folding indicators,
/// and the editor's own undo history.
@MainActor
final class QueryEditorSession: ObservableObject {
    let store: DocumentStore
    let security: QuerySecurity

    /// The queries as edited in this window.
    @Published private(set) var queries: [QueryDefinition]
    /// The document's queries when this window last synchronised with it.
    @Published private(set) var baseline: [QueryDefinition]
    @Published var selectedQueryID: UUID? { didSet { if oldValue != selectedQueryID { selectionChanged() } } }
    /// Index into the selected query's applied steps; nil = the last step.
    @Published private(set) var selectedStep: Int?
    /// Selected columns of the preview, in selection order.
    @Published var selectedColumns: [String] = []

    // Preview
    @Published private(set) var preview: QueryPreview?
    @Published private(set) var previewError: String?
    @Published private(set) var isEvaluating = false
    @Published private(set) var profiles: [ColumnProfile] = []
    @Published private(set) var folding: [String: StepFoldingInfo] = [:]
    @Published private(set) var previewTime: Date?
    @Published private(set) var lastEvents: [QueryDiagnosticEvent] = []
    /// The error of each query whose last evaluation failed (warning icons in the Queries pane).
    @Published private(set) var queryErrors: [UUID: String] = [:]
    /// A native database query the last preview needed but the user has not approved yet (Edit Permission).
    @Published private(set) var permissionRequest: NativeQueryRequest?

    // View options (View tab)
    @Published var showQuerySettings = true
    @Published var showFormulaBar = true
    @Published var showQuality = false { didSet { if showQuality != oldValue { scheduleProfiles() } } }
    @Published var showDistribution = false { didSet { if showDistribution != oldValue { scheduleProfiles() } } }
    @Published var showProfile = false { didSet { if showProfile != oldValue { scheduleProfiles() } } }
    /// "Column profiling based on entire data set" instead of the top 1,000 rows.
    @Published var profileWholeDataset = false { didSet { if profileWholeDataset != oldValue { refreshPreview() } } }
    @Published var monospaced = false
    @Published var showWhitespace = false
    /// The new Power Query editor (Settings ▸ Preview features): the centre shows the data, the schema or the
    /// query's script, and the diagram view can sit above it.
    enum CentreView: Equatable { case data, schema, script }
    @Published var centreView = CentreView.data
    @Published var showDiagram = false
    let newEditorViews: Bool

    // Diagnostics (Tools tab)
    @Published private(set) var isRecordingDiagnostics = false
    @Published private(set) var recordedDiagnostics: [QueryDiagnosticEvent] = []

    /// The dialog shown over the editor.
    @Published var dialog: EditorDialog?
    /// A message shown in the editor's status line.
    @Published var message: StatusMessage?
    /// Groups created in this window that have no queries yet.
    @Published var extraGroups: [String] = []
    /// A query the user asked to delete, awaiting confirmation in the Queries pane.
    @Published var deleteRequest: UUID?
    /// Set by Close & Apply / Close: the window closes itself (after applying or discarding).
    @Published var closeRequest: CloseRequest?
    enum CloseRequest { case apply, discard, ask }

    static let previewRows = 1000

    private struct UndoEntry { var name: String; var queries: [QueryDefinition]; var selection: UUID? }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    @Published private(set) var undoName: String?
    @Published private(set) var redoName: String?
    private var generation = 0
    private var applying = false
    /// The evaluation started by the latest `refreshPreview`.
    private var previewTask: Task<Void, Never>?
    private var observation: AnyCancellable?

    init(store: DocumentStore, security: QuerySecurity = .shared, options: UserDefaults = AppSettings.defaults) {
        self.store = store
        self.security = security
        // The View tab starts as Settings ▸ Data ▸ Power Query Editor sets it.
        func option(_ key: AppSettings.Key) -> Bool { options.object(forKey: key.rawValue) as? Bool ?? AppSettings.initial[key.rawValue] as? Bool ?? false }
        showFormulaBar = option(.pqFormulaBar)
        showQuality = option(.pqColumnQuality)
        showDistribution = option(.pqColumnDistribution)
        showProfile = option(.pqColumnProfile)
        profileWholeDataset = option(.pqProfilingWholeDataset)
        monospaced = option(.pqMonospaced)
        newEditorViews = option(.previewNewQueryEditor)
        queries = store.doc.queries
        baseline = store.doc.queries
        selectedQueryID = Self.initialSelection(store: store, queries: store.doc.queries)
        observation = store.$doc.map(\.queries).removeDuplicates().dropFirst()
            .sink { [weak self] remote in MainActor.assumeIsolated { self?.documentChanged(remote) } }
    }

    private static func initialSelection(store: DocumentStore, queries: [QueryDefinition]) -> UUID? {
        if let routed = QueryEditorRouting.takeSelection(for: store), let q = queries.first(where: { $0.name == routed }) { return q.id }
        return (queries.first { $0.kind == .table && $0.loadEnabled } ?? queries.first)?.id
    }

    // MARK: Accessors

    var selectedQuery: QueryDefinition? { queries.first { $0.id == selectedQueryID } }
    var steps: [MStep] { selectedQuery.map { MScript.steps(of: $0.mScript) } ?? [] }
    /// The selected step's index, resolving "last".
    var currentStepIndex: Int? {
        let count = steps.count
        guard count > 0 else { return nil }
        return min(selectedStep ?? count - 1, count - 1)
    }
    var currentStep: MStep? { currentStepIndex.flatMap { steps[safe: $0] } }
    var isLastStepSelected: Bool { selectedStep == nil || selectedStep == steps.count - 1 }
    var hasPendingChanges: Bool { queries != baseline }
    var columnNames: [String] { preview?.table.columnNames ?? [] }
    var queryNames: Set<String> { Set(queries.map(\.name)) }
    var groups: [String] {
        var out: [String] = []
        for g in queries.map(\.group) + extraGroups where !g.isEmpty && !out.contains(g) { out.append(g) }
        return out
    }
    func query(_ id: UUID?) -> QueryDefinition? { queries.first { $0.id == id } }
    func query(named name: String) -> QueryDefinition? { queries.first { $0.name == name } }
    /// Types of the selected columns in the preview.
    var selectedColumnTypes: [DataType] { selectedColumns.compactMap { preview?.table.column($0)?.type } }

    var environment: QueryEnvironment { security.environment(baseDirectory: store.fileURL?.deletingLastPathComponent()) }
    func makeEngine(_ queries: [QueryDefinition]? = nil) -> QueryEngine {
        QueryEngine(queries: queries ?? self.queries, environment: environment)
    }
    /// An engine that also reports the native query it was refused (for Edit Permission).
    private func previewEngine() -> (QueryEngine, NativeQueryRefusals) {
        var env = environment
        let refusals = NativeQueryRefusals(), approve = env.approveNativeQuery
        env.approveNativeQuery = { request in
            let ok = approve?(request) ?? false
            if !ok { refusals.note(request) }
            return ok
        }
        return (QueryEngine(queries: queries, environment: env), refusals)
    }

    // MARK: Changes

    /// The one write path for the pending queries: records an undo entry, then re-evaluates the preview.
    func change(_ name: String, refresh: Bool = true, _ body: (inout [QueryDefinition]) -> Void) {
        var copy = queries
        body(&copy)
        guard copy != queries else { return }
        undoStack.append(UndoEntry(name: name, queries: queries, selection: selectedQueryID))
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
        redoStack.removeAll()
        queries = copy
        syncUndoNames()
        if selectedQuery == nil { selectedQueryID = queries.first?.id }
        if refresh { refreshPreview() }
    }

    /// Edit the selected query's script. Callers that select a step afterwards pass `refresh: false`
    /// (selecting re-evaluates the preview).
    func changeScript(_ name: String, refresh: Bool = true, _ edit: (String) -> String) {
        guard let id = selectedQueryID else { return }
        change(name, refresh: refresh) { qs in
            if let i = qs.firstIndex(where: { $0.id == id }) { qs[i].mScript = edit(qs[i].mScript) }
        }
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(name: entry.name, queries: queries, selection: selectedQueryID))
        restore(entry)
    }
    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(name: entry.name, queries: queries, selection: selectedQueryID))
        restore(entry)
    }
    private func restore(_ entry: UndoEntry) {
        queries = entry.queries
        selectedStep = nil
        if query(entry.selection) != nil { selectedQueryID = entry.selection } else { selectedQueryID = queries.first?.id }
        syncUndoNames()
        refreshPreview()
    }
    private func syncUndoNames() { undoName = undoStack.last?.name; redoName = redoStack.last?.name }

    // MARK: Selection

    func selectStep(_ index: Int?) {
        let resolved = index.map { min(max(0, $0), max(0, steps.count - 1)) }
        selectedStep = resolved == steps.count - 1 ? nil : resolved
        refreshPreview()
    }

    private func selectionChanged() {
        selectedStep = nil
        selectedColumns = []
        preview = nil
        profiles = []
        folding = [:]
        refreshPreview()
    }

    func clickColumn(_ name: String, toggle: Bool, range: Bool) {
        selectedColumns = QueryEditorPlans.select(name, in: columnNames, current: selectedColumns, toggle: toggle, range: range)
    }

    // MARK: Preview

    /// Evaluate the selected step (cell errors, structured cells, profiles, folding) on the query engine.
    func refreshPreview() {
        generation += 1
        let mine = generation
        guard let q = selectedQuery else {
            preview = nil; previewError = nil; profiles = []; folding = [:]; isEvaluating = false
            return
        }
        if q.kind == .parameter {
            preview = nil; previewError = nil; profiles = []; folding = [:]; isEvaluating = false
            return
        }
        let (engine, refusals) = previewEngine(), name = q.name, step = selectedStep, whole = profileWholeDataset
        let wantsFolding = Self.mayFold(q, in: queries)
        isEvaluating = true
        previewTask = Task {
            do {
                let shown = try await engine.evaluatePreview(name, upToStep: step, rowLimit: Self.previewRows)
                let events = engine.diagnostics
                let profiled = whole ? try await engine.profile(name, upToStep: step, rowLimit: nil) : ColumnProfiler.profile(shown)
                var foldingInfo: [String: StepFoldingInfo] = [:]
                if wantsFolding, let info = try? await engine.stepFolding(for: name) {
                    for i in info { foldingInfo[i.step] = i }
                }
                guard mine == generation else { return }
                preview = shown
                previewError = nil
                permissionRequest = nil
                if step == nil { queryErrors[q.id] = nil }
                profiles = profiled
                folding = foldingInfo
                previewTime = Date()
                lastEvents = events
                if isRecordingDiagnostics { recordedDiagnostics += events }
                selectedColumns = selectedColumns.filter(shown.table.columnNames.contains)
                noteValueKind(shown.valueKind, of: q.id)
            } catch {
                guard mine == generation else { return }
                preview = nil
                profiles = []
                previewError = MError.wrap(error).description
                permissionRequest = refusals.last
                if step == nil { queryErrors[q.id] = previewError }
                lastEvents = engine.diagnostics
                if isRecordingDiagnostics { recordedDiagnostics += engine.diagnostics }
            }
            if mine == generation { isEvaluating = false }
        }
    }

    /// Wait until the latest preview evaluation has finished (and any it started in turn).
    func waitForPreview() async {
        var seen: Task<Void, Never>?
        while let task = previewTask, task != seen {
            seen = task
            await task.value
        }
    }

    /// Profiles are computed with every preview; toggling a profile view only needs a whole-dataset rerun.
    private func scheduleProfiles() {
        if profileWholeDataset { refreshPreview() }
    }

    /// Folding indicators are worth computing only for queries that read a database (directly or through others).
    static func mayFold(_ q: QueryDefinition, in queries: [QueryDefinition]) -> Bool {
        let graph = QueryDependencyGraph(queries: queries)
        let names = graph.transitiveDependencies(of: q.name).union([q.name])
        let databases = ["Sqlite.Database", "PostgreSQL.Database", "MySQL.Database", "MariaDB.Contents", "AmazonRedshift.Database"]
        return queries.contains { q in names.contains(q.name) && databases.contains { q.mScript.contains($0) } }
    }

    /// Power Query shows a query that evaluates to a function as a function (fx), and loads only tables.
    private func noteValueKind(_ kind: String, of id: UUID) {
        guard selectedStep == nil, let i = queries.firstIndex(where: { $0.id == id }) else { return }
        let current = queries[i].kind
        let wanted: QueryDefinition.Kind? = kind == "function" ? .function : (current == .function ? .table : nil)
        guard let wanted, wanted != current else { return }
        queries[i].kind = wanted
    }

    /// Refresh the previews of every query (Home ▸ Refresh All): reports which queries fail.
    func refreshAllPreviews() {
        let engine = makeEngine(), names = queries.filter { $0.kind == .table }.map(\.name)
        isEvaluating = true
        Task {
            let results = await engine.refreshAll(only: names) { _ in }
            var errors: [UUID: String] = [:]
            let failures = names.compactMap { n -> String? in
                guard case .failure(let e)? = results[n] else { return nil }
                let text = MError.wrap(e).description
                if let id = queries.first(where: { $0.name == n })?.id { errors[id] = text }
                return "\(n): \(text)"
            }
            queryErrors = errors
            message = failures.isEmpty
                ? StatusMessage(kind: .success, text: "Refreshed the previews of \(names.count) quer\(names.count == 1 ? "y" : "ies").")
                : StatusMessage(kind: .error, text: failures.joined(separator: "\n"))
            refreshPreview()
        }
    }

    /// Edit Permission ▸ Run: approve the native query the preview asked for, then evaluate again.
    func approvePermissionRequest() {
        guard let r = permissionRequest else { return }
        security.approve(query: r.query, kind: r.sourceKind, location: r.sourceLocation)
        permissionRequest = nil
        refreshPreview()
    }

    // MARK: Diagnostics

    func startDiagnostics() { recordedDiagnostics = []; isRecordingDiagnostics = true; message = StatusMessage(kind: .info, text: "Recording query diagnostics…") }
    func stopDiagnostics() {
        isRecordingDiagnostics = false
        dialog = .diagnostics(recordedDiagnostics, title: "Query Diagnostics")
    }
    /// Evaluate the selected step once and show what the engine did.
    func diagnoseStep() {
        guard let q = selectedQuery, let stepName = currentStep?.name else { return }
        let engine = makeEngine(), step = selectedStep
        Task {
            _ = try? await engine.evaluatePreview(q.name, upToStep: step, rowLimit: Self.previewRows)
            dialog = .diagnostics(engine.diagnostics, title: "Diagnostics for \(q.name) ▸ \(stepName)")
        }
    }

    // MARK: Apply and discard

    /// Close & Apply / Apply: write the pending queries to the document, rename or remove the model tables they
    /// feed, and load the changed queries into the model, all as one undo step ("Apply Query Changes"): the load,
    /// which finishes later, joins the step unless something else changed the document first.
    func applyChanges() {
        guard hasPendingChanges || !refreshPlan().refresh.isEmpty else { return }
        let after = queries
        let plan = refreshPlan()
        applying = true
        defer { applying = false }
        let group = store.undoGroup("Apply Query Changes") {
            for r in plan.renames { ModelOps.renameTable(store, r.from, to: r.to) }
            store.mutate("Apply Query Changes", invalidates: .model) { d in
                d.queries = after
                for t in plan.removedTables { ModelRefactor.deleteTable(&d, name: t) }
            }
        }
        baseline = store.doc.queries
        queries = store.doc.queries
        if !plan.refresh.isEmpty { store.refreshData(only: plan.refresh, joiningUndo: group) }
        message = StatusMessage(kind: .success, text: plan.refresh.isEmpty ? "Applied the query changes." : "Applied the query changes; loading \(plan.refresh.count) quer\(plan.refresh.count == 1 ? "y" : "ies").")
    }

    /// The plan Apply would carry out now.
    func refreshPlan() -> QueryEditorPlans.ApplyPlan {
        var loaded: [String: String] = [:]
        for t in store.doc.model.tables { if let q = t.sourceQuery { loaded[t.name] = q } }
        return QueryEditorPlans.applyPlan(before: baseline, after: queries, loadedTables: loaded)
    }

    /// Close without applying: forget every pending change.
    func discardChanges() {
        queries = baseline
        undoStack.removeAll(); redoStack.removeAll(); syncUndoNames()
        if selectedQuery == nil { selectedQueryID = queries.first?.id }
        refreshPreview()
    }

    // MARK: Document synchronisation

    private func documentChanged(_ remote: [QueryDefinition]) {
        guard !applying else { return }
        let merged = QueryEditorPlans.merge(base: baseline, local: queries, remote: remote)
        baseline = remote
        let selectionBefore = selectedQuery
        if merged != queries { queries = merged }
        if let routed = QueryEditorRouting.takeSelection(for: store), let q = queries.first(where: { $0.name == routed }) {
            selectedQueryID = q.id
        } else if selectedQuery == nil {
            selectedQueryID = queries.first?.id
        } else if selectedQuery != selectionBefore {
            refreshPreview()
        }
    }

    /// Called when the window comes to the front again (Get Data ▸ Transform Data may have routed a query here).
    func takeRoutedSelection() {
        if let routed = QueryEditorRouting.takeSelection(for: store), let q = queries.first(where: { $0.name == routed }) {
            selectedQueryID = q.id
        }
    }
}

/// Native queries an evaluation was refused, collected from the engine's threads.
private final class NativeQueryRefusals: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [NativeQueryRequest] = []
    func note(_ r: NativeQueryRequest) { lock.lock(); requests.append(r); lock.unlock() }
    var last: NativeQueryRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
}
