import Foundation
import FacetCore
import FacetQuery

/// DirectQuery tables keep no rows in the document. Their rows are read from the source when the model is
/// queried: when the engine loads the document or reloads after a model change, and again on Refresh. As in
/// Power BI Desktop, what the source returned is reused within the session until Refresh (or until the
/// queries change), and a source query may return at most 1,000,000 rows.
///
/// The source runs the table's query (folded into SQL); grouping, filters and measures then run in the model's
/// engine over those rows, rather than as one SQL query per visual.
@MainActor
final class DirectQuerySession {
    /// Power BI's limit on the rows one DirectQuery source query returns.
    nonisolated static let rowLimit = 1_000_000

    struct Job {
        var table: String
        var query: String
        /// The source the query reads; at most "Maximum connections per data source" fetches run against one source at once.
        var source: String
    }

    private struct Entry {
        var signature: Int
        var result: Result<DataTable, Error>
    }
    private var cache: [String: Entry] = [:]

    private static var key: UInt8 = 0
    static func of(_ store: DocumentStore) -> DirectQuerySession {
        if let s = objc_getAssociatedObject(store, &key) as? DirectQuerySession { return s }
        let s = DirectQuerySession()
        objc_setAssociatedObject(store, &key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    // MARK: Which tables

    /// DirectQuery tables loaded by a query of the document, with the query's name.
    nonisolated static func tables(_ model: SemanticModel, queries: [QueryDefinition]) -> [(table: String, query: String)] {
        model.tables.compactMap { t in
            guard t.storageMode == .directQuery, t.expression == nil, let q = t.sourceQuery,
                  queries.contains(where: { $0.name == q }) else { return nil }
            return (t.name, q)
        }
    }

    /// The SQLite file or SQL Server a query reads (its first `Sqlite.Database("…")` / `Sql.Database("…")`), so fetches
    /// can be counted per source; a query whose source can't be told counts as a source of its own.
    nonisolated static func sourceKey(_ script: String, query: String) -> String {
        if let r = script.range(of: #"Sql\.Database\s*\(\s*"((?:[^"]|"")*)""#, options: .regularExpression) {
            let literal = script[r].drop { $0 != "\"" }.dropFirst().dropLast()
            return "sql:" + literal.replacingOccurrences(of: "\"\"", with: "\"").lowercased()
        }
        guard let r = script.range(of: #"Sqlite\.Database\s*\(\s*"((?:[^"]|"")*)""#, options: .regularExpression) else { return "query:" + query }
        let literal = script[r].drop { $0 != "\"" }.dropFirst().dropLast()
        return "sqlite:" + literal.replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// The queries and their parameters, as one value: a change to any of them means fetching again.
    private static func signature(_ queries: [QueryDefinition]) -> Int {
        var h = Hasher()
        for q in queries { h.combine(q.name); h.combine(q.mScript) }
        return h.finalize()
    }

    /// The document's data with its DirectQuery tables' rows from their sources, and a message for each that
    /// couldn't be read (whose rows are then left out rather than shown stale). `completion` runs at once when
    /// nothing needs reading, otherwise after the sources answer.
    func data(for doc: FacetDocument, baseDirectory: URL?, maxConnections: Int = AppSettings.int(.dqMaxConnections),
              completion: @escaping (DataStore, [String]) -> Void) {
        let wanted = Self.tables(doc.model, queries: doc.queries)
        guard !wanted.isEmpty else { completion(doc.data, []); return }
        let signature = Self.signature(doc.queries)
        let missing = wanted.filter { cache[$0.table.lowercased()]?.signature != signature }
        if missing.isEmpty { completion(merged(doc.data, wanted), problems(wanted)); return }
        let scripts = Dictionary(doc.queries.map { ($0.name, $0.mScript) }, uniquingKeysWith: { a, _ in a })
        let jobs = missing.map { Job(table: $0.table, query: $0.query, source: Self.sourceKey(scripts[$0.query] ?? "", query: $0.query)) }
        let engine = QueryEngine(queries: doc.queries, environment: .app(baseDirectory: baseDirectory))
        let data = doc.data
        Task {
            let results = await Self.fetch(jobs, maxConnections: maxConnections) { job in
                let start = DispatchTime.now()
                do {
                    let rows = try await Self.read(job, engine: engine)
                    TraceLog.shared.record("directQuery.read", ["table": .name(job.table), "rows": .count(rows.rowCount),
                                                                "ms": .milliseconds(TraceLog.milliseconds(since: start))])
                    return rows
                } catch {
                    TraceLog.shared.record("directQuery.read", ["table": .name(job.table), "failed": .flag(true),
                                                                "ms": .milliseconds(TraceLog.milliseconds(since: start))])
                    throw error
                }
            }
            for (table, result) in results { cache[table.lowercased()] = Entry(signature: signature, result: result) }
            completion(merged(data, wanted), problems(wanted))
        }
    }

    /// Forgets what the sources returned, so the next query reads them again (Refresh).
    func invalidate() { cache.removeAll() }

    private func merged(_ data: DataStore, _ tables: [(table: String, query: String)]) -> DataStore {
        var out = data
        for t in tables {
            switch cache[t.table.lowercased()]?.result {
            case .success(let rows)?: out[t.table] = rows
            default: out[t.table] = nil
            }
        }
        return out
    }

    private func problems(_ tables: [(table: String, query: String)]) -> [String] {
        tables.compactMap { t in
            guard case .failure(let e)? = cache[t.table.lowercased()]?.result else { return nil }
            return "DirectQuery: couldn't read “\(t.table)” from its source. \(e.localizedDescription)"
        }
    }

    // MARK: Reading

    struct RowLimitExceeded: LocalizedError {
        var limit: Int
        var errorDescription: String? {
            "The result of a query to the data source has exceeded the maximum allowed size of \(limit.formatted()) rows."
        }
    }

    /// One table's rows from its source, with the row limit pushed to the source.
    nonisolated static func read(_ job: Job, engine: QueryEngine, limit: Int = rowLimit) async throws -> DataTable {
        var rows = try await engine.directQuery(job.query).fetch(rowLimit: limit + 1)
        guard rows.rowCount <= limit else { throw RowLimitExceeded(limit: limit) }
        rows.name = job.table
        return rows
    }

    /// Runs the fetches, at most `maxConnections` at a time against any one source; different sources run side by side.
    nonisolated static func fetch(_ jobs: [Job], maxConnections: Int,
                                  _ read: @escaping @Sendable (Job) async throws -> DataTable) async -> [String: Result<DataTable, Error>] {
        let limit = max(1, maxConnections)
        let bySource = Dictionary(grouping: jobs, by: \.source)
        return await withTaskGroup(of: [String: Result<DataTable, Error>].self) { sources in
            for (_, group) in bySource {
                sources.addTask {
                    await withTaskGroup(of: (String, Result<DataTable, Error>).self) { running in
                        var out: [String: Result<DataTable, Error>] = [:]
                        var next = 0
                        func launch() {
                            let job = group[next]
                            next += 1
                            running.addTask {
                                do { return (job.table, .success(try await read(job))) } catch { return (job.table, .failure(error)) }
                            }
                        }
                        while next < min(limit, group.count) { launch() }
                        while let (table, result) = await running.next() {
                            out[table] = result
                            if next < group.count { launch() }
                        }
                        return out
                    }
                }
            }
            var all: [String: Result<DataTable, Error>] = [:]
            for await part in sources { all.merge(part) { a, _ in a } }
            return all
        }
    }
}

extension FacetDocument {
    /// The document as it is saved: DirectQuery tables keep no rows in the file.
    var withoutDirectQueryRows: FacetDocument {
        var d = self
        for t in DirectQuerySession.tables(model, queries: queries) { d.data[t.table] = nil }
        return d
    }
}
