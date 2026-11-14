import Foundation
import FacetCore

/// Evaluates Power Query queries: previews, full refresh, dependencies, diagnostics, folding information,
/// DirectQuery handles and incremental refresh.
///
/// The engine is a snapshot of a set of `QueryDefinition`s; create a new engine (cheap) when queries change.
/// All evaluation runs on a dedicated worker thread with a large stack, never on the caller's thread.
public final class QueryEngine: @unchecked Sendable {
    public let queries: [QueryDefinition]
    public let environment: QueryEnvironment
    /// Dynamic M parameters: values that replace parameter queries (by name) for every evaluation by this engine.
    public var parameterOverrides: [String: Value] = [:]
    /// Maximum number of queries refreshed concurrently by `refreshAll`.
    public var maxConcurrentRefreshes = max(2, ProcessInfo.processInfo.activeProcessorCount)

    private let byName: [String: QueryDefinition]
    private let lock = NSLock()
    private var _diagnostics: [QueryDiagnosticEvent] = []
    private var _nativeQueries: [String] = []
    private var _trace: [String] = []
    private var _sources: [QueryDataSource] = []

    public init(queries: [QueryDefinition], environment: QueryEnvironment) {
        self.queries = queries; self.environment = environment
        var d: [String: QueryDefinition] = [:]
        for q in queries where d[q.name] == nil { d[q.name] = q }
        byName = d
    }

    /// Per-step timings / row counts / folding of the most recent `evaluate`/`evaluatePreview`/`refreshAll` call.
    public var diagnostics: [QueryDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return _diagnostics }
    /// Native queries sent to data sources during the most recent evaluation.
    public var nativeQueriesSent: [String] { lock.lock(); defer { lock.unlock() }; return _nativeQueries }
    /// Messages from `Diagnostics.Trace` during the most recent evaluation.
    public var traceMessages: [String] { lock.lock(); defer { lock.unlock() }; return _trace }

    /// Data sources read during the most recent evaluation (file paths, database files, web hosts), without duplicates.
    public var dataSourcesAccessed: [QueryDataSource] { lock.lock(); defer { lock.unlock() }; return _sources }

    // MARK: Dependencies

    /// query → queries it references.
    public func dependencies() -> [String: [String]] { QueryDependencyGraph(queries: queries).dependencies }
    public func dependencyGraph() -> QueryDependencyGraph { QueryDependencyGraph(queries: queries) }

    // MARK: Evaluation

    /// Evaluate a query by name. `upToStep` (index into `MScript.steps(of:)`) evaluates a prefix for previews;
    /// `rowLimit` caps the rows returned (pushed down to the source when the query folds).
    public func evaluate(_ name: String, upToStep: Int? = nil, rowLimit: Int? = nil) async throws -> DataTable {
        try await evaluate(name, upToStep: upToStep, rowLimit: rowLimit, parameterOverrides: [:])
    }

    /// Evaluate with per-call parameter overrides (dynamic M parameters); these win over `parameterOverrides`.
    public func evaluate(_ name: String, upToStep: Int? = nil, rowLimit: Int? = nil,
                         parameterOverrides overrides: [String: Value]) async throws -> DataTable {
        try await onWorker {
            let session = self.makeSession(overrides: overrides.mapValues { MValue($0) })
            defer { self.publish(session) }
            let v = try session.value(of: name, upToStep: upToStep)
            return try QueryEngine.dataTable(from: v, name: name, rowLimit: rowLimit)
        }
    }

    /// Evaluate a step for the editor preview, keeping cell errors and structured-cell markers.
    public func evaluatePreview(_ name: String, upToStep: Int? = nil, rowLimit: Int? = 1000) async throws -> QueryPreview {
        try await onWorker {
            let session = self.makeSession(overrides: [:])
            defer { self.publish(session) }
            let v = try session.value(of: name, upToStep: upToStep)
            return try QueryEngine.preview(from: v, name: name, rowLimit: rowLimit)
        }
    }

    /// The raw M value of a query or step (for drilling into nested tables/records/lists).
    public func evaluateValue(_ name: String, upToStep: Int? = nil) async throws -> MValue {
        try await onWorker {
            let session = self.makeSession(overrides: [:])
            defer { self.publish(session) }
            return try session.value(of: name, upToStep: upToStep)
        }
    }

    /// Evaluate free-standing M text; other queries and parameters are in scope by name.
    public func evaluateExpression(_ m: String) async throws -> MValue {
        try await onWorker {
            let session = self.makeSession(overrides: [:])
            defer { self.publish(session) }
            return try session.interpreter.evaluate(m)
        }
    }

    /// The native query of a query's result (or of step `upToStep`), when it is folded to the source.
    public func nativeQuery(for name: String, upToStep: Int? = nil) async throws -> String? {
        try await onWorker {
            let session = self.makeSession(overrides: [:])
            let v = try session.value(of: name, upToStep: upToStep)
            guard case .table(let t) = v, t.isLazy else { return nil }
            return t.source?.nativeQuery
        }
    }

    /// Folding indicator for each applied step of a query. Evaluates the query lazily (no rows are loaded for
    /// steps that fold all the way to the result).
    public func stepFolding(for name: String) async throws -> [StepFoldingInfo] {
        guard let q = byName[name] else { throw QueryEngineError.unknownQuery(name) }
        let steps = MScript.steps(of: q.mScript)
        return try await onWorker {
            let session = self.makeSession(overrides: [:])
            _ = try? session.value(of: name, upToStep: nil)
            let events = session.events.filter { $0.query == name }
            return steps.map { s in
                if let e = events.last(where: { $0.step == s.name }) {
                    return StepFoldingInfo(step: s.name, indicator: e.folding, nativeQuery: e.nativeQuery)
                }
                return StepFoldingInfo(step: s.name, indicator: .notEvaluated, nativeQuery: nil)
            }
        }
    }

    // MARK: Refresh

    /// Refresh every load-enabled table query that is included in refresh (or just `only`), in dependency order and in
    /// parallel where independent. Returns each query's table or error; `progress` is called from worker threads.
    public func refreshAll(only: [String]? = nil, progress: @escaping (QueryProgress) -> Void = { _ in }) async -> [String: Result<DataTable, Error>] {
        let graph = QueryDependencyGraph(queries: queries)
        let wanted: Set<String>
        if let only { wanted = Set(only) } else {
            wanted = Set(queries.filter { $0.kind == .table && $0.loadEnabled && $0.includeInRefresh }.map(\.name))
        }
        let total = wanted.count
        let state = RefreshState()
        let cache = SharedResultCache()
        var results: [String: Result<DataTable, Error>] = [:]
        for n in wanted where byName[n] == nil { results[n] = .failure(QueryEngineError.unknownQuery(n)) }
        for level in graph.levels() {
            let batch = level.filter(wanted.contains)
            if batch.isEmpty { continue }
            await withTaskGroup(of: (String, Result<DataTable, Error>).self) { group in
                var iterator = batch.makeIterator()
                var running = 0
                func launch(_ name: String) {
                    group.addTask {
                        progress(QueryProgress(query: name, phase: .started, completed: state.completed, total: total))
                        let start = Date()
                        do {
                            let table: DataTable = try await self.onWorker {
                                let session = self.makeSession(overrides: [:], shared: cache)
                                defer { self.publish(session, append: true) }
                                let v = try session.value(of: name, upToStep: nil)
                                let t = try QueryEngine.dataTable(from: v, name: name, rowLimit: nil)
                                if case .table(let mt) = v, !mt.isLazy { cache.store(name, v, sources: session.interpreter.accessedSources) }
                                return t
                            }
                            let secs = Date().timeIntervalSince(start)
                            progress(QueryProgress(query: name, phase: .finished(rows: table.rowCount, seconds: secs), completed: state.finishOne(), total: total))
                            return (name, .success(table))
                        } catch {
                            let secs = Date().timeIntervalSince(start)
                            progress(QueryProgress(query: name, phase: .failed(message: MError.wrap(error).description, seconds: secs), completed: state.finishOne(), total: total))
                            return (name, .failure(error))
                        }
                    }
                }
                while running < maxConcurrentRefreshes, let n = iterator.next() { launch(n); running += 1 }
                for await (name, result) in group {
                    results[name] = result
                    if let n = iterator.next() { launch(n) }
                }
            }
        }
        return results
    }

    // MARK: Sessions

    func makeSession(overrides: [String: MValue], shared: SharedResultCache? = nil) -> QuerySession {
        var merged = parameterOverrides.mapValues { MValue($0) }
        for (k, v) in overrides { merged[k] = v }
        return QuerySession(engine: self, queries: byName, overrides: merged, shared: shared)
    }

    private func publish(_ session: QuerySession, append: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let sources = session.interpreter.accessedSources.map { QueryDataSource(kind: $0.kind, location: $0.location) }
        _sources = (append ? _sources : []) + sources.filter { s in !(append && _sources.contains(s)) }
        if append {
            _diagnostics.append(contentsOf: session.events)
            _nativeQueries.append(contentsOf: session.interpreter.nativeQueries)
            _trace.append(contentsOf: session.interpreter.trace)
        } else {
            _diagnostics = session.events
            _nativeQueries = session.interpreter.nativeQueries
            _trace = session.interpreter.trace
        }
    }
    func resetDiagnostics() { lock.lock(); _diagnostics = []; _nativeQueries = []; _trace = []; _sources = []; lock.unlock() }

    /// Run blocking evaluation work on a dedicated thread with a 512 MB stack (deep M recursion).
    func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        let cancellation = QueryCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                let thread = Thread {
                    Thread.current.threadDictionary[QueryCancellation.threadKey] = cancellation
                    do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
                }
                thread.stackSize = 512 << 20
                thread.name = "Facet.QueryEngine"
                thread.start()
            }
        } onCancel: { cancellation.cancel() }
    }

    // MARK: Result conversion

    /// Convert any M value to a table for loading: tables as they are, lists as one column "Value",
    /// records as Name/Value rows, scalars as a 1×1 table.
    static func asTable(_ v: MValue, name: String) -> MTable {
        switch v {
        case .table(let t): return t
        case .list(let l): return MTable(names: ["Value"], columns: [l.map { $0.forcedCell() }])
        case .record(let r): return MTable(names: ["Name", "Value"], types: [.text, .any], columns: [r.names.map(MValue.text), r.cells])
        default: return MTable(names: [name.isEmpty ? "Value" : name], columns: [[v]])
        }
    }
    static func dataTable(from v: MValue, name: String, rowLimit: Int?) throws -> DataTable {
        try asTable(v, name: name).toDataTable(name: name, limit: rowLimit)
    }
    static func preview(from v: MValue, name: String, rowLimit: Int?) throws -> QueryPreview {
        let t = asTable(v, name: name)
        let fetch = rowLimit.map { $0 + 1 }
        var cols = try t.columns(limit: fetch)
        var truncated = false
        if let rowLimit, let first = cols.first, first.count > rowLimit {
            truncated = true
            cols = cols.map { Array($0.prefix(rowLimit)) }
        }
        var errors: [Int: [Int: String]] = [:], structured: [Int: [Int: String]] = [:]
        var outCols: [DataColumn] = []
        for (c, cells) in cols.enumerated() {
            let type = t.columnTypes[c]
            var values: [Value] = []
            values.reserveCapacity(cells.count)
            for (r, raw) in cells.enumerated() {
                let cell = raw.forcedCell()
                switch cell {
                case .error(let e): errors[c, default: [:]][r] = e.description
                case .table: structured[c, default: [:]][r] = "Table"
                case .list: structured[c, default: [:]][r] = "List"
                case .record: structured[c, default: [:]][r] = "Record"
                case .binary: structured[c, default: [:]][r] = "Binary"
                case .function: structured[c, default: [:]][r] = "Function"
                default: break
                }
                values.append(cell.toValue(type: type))
            }
            var dc = DataColumn(name: t.columnNames[c], type: type.dataType, values: values)
            if dc.type == .any { dc.type = DataTable.inferType(values) }
            outCols.append(dc)
        }
        return QueryPreview(table: DataTable(name: name, columns: outCols), columnTypes: t.columnTypes, cellErrors: errors,
                            structuredCells: structured, valueKind: v.typeName, isTruncated: truncated)
    }
}

/// Thread-safe counters for refresh progress.
private final class RefreshState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    var completed: Int { lock.lock(); defer { lock.unlock() }; return done }
    func finishOne() -> Int { lock.lock(); defer { lock.unlock() }; done += 1; return done }
}

/// Results of already-refreshed queries, shared between sessions of one `refreshAll` run so that a query
/// referenced by several others is evaluated once.
final class SharedResultCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (MValue, [(kind: String, location: String, privacy: PrivacyLevel)])] = [:]
    func store(_ name: String, _ v: MValue, sources: [(kind: String, location: String, privacy: PrivacyLevel)]) {
        lock.lock(); values[name] = (v, sources); lock.unlock()
    }
    func lookup(_ name: String) -> (MValue, [(kind: String, location: String, privacy: PrivacyLevel)])? {
        lock.lock(); defer { lock.unlock() }
        return values[name]
    }
}

/// One evaluation session: an interpreter plus memoised values of the queries it touches.
final class QuerySession {
    let interpreter: MInterpreter
    private let queries: [String: QueryDefinition]
    private let overrides: [String: MValue]
    private let shared: SharedResultCache?
    private var thunks: [String: MThunk] = [:]
    private(set) var events: [QueryDiagnosticEvent] = []
    private var timingStack: [Double] = [] // accumulated child time per active step

    init(engine: QueryEngine, queries: [String: QueryDefinition], overrides: [String: MValue], shared: SharedResultCache?) {
        self.queries = queries; self.overrides = overrides; self.shared = shared
        interpreter = MInterpreter(environment: engine.environment)
        interpreter.sharedNames = { [queries] in Array(queries.keys) }
        interpreter.sharedResolver = { [unowned self] name in try self.resolve(name) }
    }

    private func resolve(_ name: String) throws -> MValue? {
        if let o = overrides[name] { return o }
        guard queries[name] != nil else { return nil }
        if let t = thunks[name] { return try t.force() }
        if let (v, sources) = shared?.lookup(name) {
            for s in sources { try interpreter.noteDataSource(kind: s.kind, location: s.location) }
            return v
        }
        let t = MThunk { [unowned self] in try self.evaluateQuery(name, upToStep: nil) }
        thunks[name] = t
        do { return try t.force() } catch let e as MError where e.message.hasPrefix("A cyclic reference") {
            throw MError("A cyclic reference was encountered while evaluating the query '\(name)'.")
        }
    }

    /// Value of a query (optionally only up to a step).
    func value(of name: String, upToStep: Int?) throws -> MValue {
        if upToStep == nil, let v = try resolve(name) { return v }
        guard queries[name] != nil else { throw QueryEngineError.unknownQuery(name) }
        return try evaluateQuery(name, upToStep: upToStep)
    }

    private func evaluateQuery(_ name: String, upToStep: Int?) throws -> MValue {
        guard let q = queries[name] else { throw QueryEngineError.unknownQuery(name) }
        if q.kind == .parameter, let p = q.parameter, upToStep == nil {
            return MValue(p.currentValue.isNull ? p.defaultValue : p.currentValue, type: p.type)
        }
        let ast = try MParser.parse(q.mScript)
        guard case .letIn(let bindings, let body) = ast else {
            return try observeStep(query: name, step: "Source") { try self.interpreter.eval(ast, MEnv()).forced() }
        }
        let scope = interpreter.letScope(bindings, parent: MEnv()) { _, _, _ in }
        // Re-wrap bindings with our own observer (needs exclusive timing), by building the scope manually.
        let observed = MEnv()
        for b in bindings {
            let expr = b.expr, stepName = b.name
            observed.define(stepName, .lazy(MThunk { [unowned self] in
                try self.observeStep(query: name, step: stepName) { try self.interpreter.eval(expr, observed).forced() }
            }))
        }
        _ = scope
        if let i = upToStep, i >= 0, i < bindings.count {
            return try interpreter.eval(.identifier(bindings[i].name, inclusive: false), observed).forced()
        }
        if case .identifier(let n, _) = body, bindings.contains(where: { $0.name == n }) {
            return try interpreter.eval(body, observed).forced()
        }
        return try observeStep(query: name, step: "Result") { try self.interpreter.eval(body, observed).forced() }
    }

    private func observeStep(query: String, step: String, _ body: () throws -> MValue) throws -> MValue {
        let start = Date()
        timingStack.append(0)
        func finish(_ result: Result<MValue, Error>) {
            let total = Date().timeIntervalSince(start)
            let children = timingStack.popLast() ?? 0
            if !timingStack.isEmpty { timingStack[timingStack.count - 1] += total }
            var e = QueryDiagnosticEvent(query: query, step: step, seconds: total, exclusiveSeconds: max(0, total - children),
                                         rowCount: nil, folding: .notApplicable, nativeQuery: nil, error: nil, valueKind: "error")
            switch result {
            case .success(let v):
                e.valueKind = v.typeName
                if case .table(let t) = v {
                    if t.isLazy, let nq = t.source?.nativeQuery { e.folding = .folded; e.nativeQuery = nq }
                    else {
                        e.folding = t.source != nil || tableHasFoldableAncestry ? .notFolded : .notApplicable
                        e.rowCount = t.isLazy ? nil : (try? t.rowCount)
                    }
                    if e.folding == .folded { tableHasFoldableAncestry = true }
                }
            case .failure(let err): e.error = MError.wrap(err).description
            }
            events.append(e)
        }
        do {
            let v = try body()
            finish(.success(v))
            return v
        } catch {
            finish(.failure(error))
            throw error
        }
    }
    /// Set once any step of the session folded, so later local steps are reported as "not folded" rather than "n/a".
    private var tableHasFoldableAncestry = false
}
