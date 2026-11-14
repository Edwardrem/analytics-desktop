import XCTest
import SQLite3
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// DirectQuery over SQLite: rows come from the source when the model is queried, are reused until Refresh,
/// aren't saved, are fetched with at most the configured connections per source, and stop at the row limit.
/// Tables whose source can't run their query can only be imported.
@MainActor
final class DirectQueryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DirectQueryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func exec(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("could not open the test database") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw XCTSkip("could not change the test database") }
    }

    /// orders: (1, Pen, 10), (2, Ink, 20), (3, Cap, 30).
    private func database() throws -> String {
        let path = dir.appendingPathComponent("shop.sqlite").path
        try exec(path, "create table orders (id integer, item text, amount integer); insert into orders values (1, 'Pen', 10), (2, 'Ink', 20), (3, 'Cap', 30);")
        return path
    }

    private func script(_ path: String, _ extra: String = "") -> String {
        "let Source = Sqlite.Database(\(MSyntax.text(path))), T = Source{[Name = \"orders\"]}[Data]\(extra) in T"
    }

    private func document(_ path: String, mode: StorageMode = .directQuery) -> FacetDocument {
        var doc = FacetDocument()
        doc.queries = [QueryDefinition(name: "Orders", mScript: script(path))]
        var t = ModelTable(name: "Orders", columns: [ModelColumn(name: "id", dataType: .integer), ModelColumn(name: "item", dataType: .text),
                                                    ModelColumn(name: "amount", dataType: .integer)])
        t.sourceQuery = "Orders"
        t.storageMode = mode
        t.measures = [Measure(name: "Total", expression: "SUM(Orders[amount])")]
        doc.model.tables = [t]
        return doc
    }

    /// Waits until the engine shows `table`'s rows, up to a few seconds.
    private func waitForRows(_ store: DocumentStore, _ table: String, count: Int) async throws {
        for _ in 0..<200 {
            if store.computedData[table]?.rowCount == count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("\(table) never had \(count) rows; it has \(store.computedData[table]?.rowCount ?? 0). Status: \(store.status?.text ?? "none")")
    }

    private func total(_ store: DocumentStore) async -> Double? {
        await store.withEngine { (try? $0.scalar("[Total]", filters: []))?.asDouble }
    }

    func testRowsComeFromTheSourceUntilRefresh() async throws {
        let path = try database()
        let store = DocumentStore(services: .live())
        store.replaceDocument(document(path), url: nil)
        try await waitForRows(store, "Orders", count: 3)
        let first = await total(store)
        XCTAssertEqual(first, 60)
        XCTAssertNil(store.doc.data["Orders"], "nothing is imported")
        XCTAssertNil(store.doc.withoutDirectQueryRows.data["Orders"], "nor saved")

        try exec(path, "insert into orders values (4, 'Nib', 40);")
        store.updateModel("Hide") { $0.tables[0].isHidden = true }   // a model change reuses this session's rows
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.computedData["Orders"]?.rowCount, 3)

        store.refreshData()
        try await waitForRows(store, "Orders", count: 4)
        let second = await total(store)
        XCTAssertEqual(second, 100)
        XCTAssertNil(store.doc.data["Orders"], "Refresh reads the source again rather than importing")
    }

    func testAnUnreadableSourceShowsNoStaleRows() async throws {
        var doc = document(dir.appendingPathComponent("missing.sqlite").path)
        doc.data["Orders"] = DataTable(name: "Orders", columnNames: ["id", "item", "amount"], rows: [[1, "Old", 5]], types: [.integer, .text, .integer])
        let store = DocumentStore(services: .live())
        store.replaceDocument(doc, url: nil)
        for _ in 0..<200 where store.status == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.status?.kind, .error)
        XCTAssertTrue(store.status?.text.contains("couldn't read “Orders”") == true, store.status?.text ?? "")
        for _ in 0..<200 where store.computedData["Orders"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(store.computedData["Orders"], "the engine loaded the model")
        XCTAssertEqual(store.computedData["Orders"]?.rowCount, 0, "the old snapshot isn't shown as if it were the source")
    }

    func testTheRowLimitStopsAQuery() async throws {
        let path = try database()
        let engine = QueryEngine(queries: [QueryDefinition(name: "Orders", mScript: script(path))], environment: QueryEnvironment(baseDirectory: nil))
        let job = DirectQuerySession.Job(table: "Orders", query: "Orders", source: "s")
        let three = try await DirectQuerySession.read(job, engine: engine, limit: 3)
        XCTAssertEqual(three.rowCount, 3)
        do {
            _ = try await DirectQuerySession.read(job, engine: engine, limit: 2)
            XCTFail("three rows are over a limit of two")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The result of a query to the data source has exceeded the maximum allowed size of 2 rows.")
        }
    }

    /// Five tables on one source with two connections, and two on another: never more than two at once on a source.
    func testFetchesRespectTheConnectionsPerSource() async throws {
        actor Gauge {
            var now: [String: Int] = [:], peak: [String: Int] = [:]
            func enter(_ s: String) { now[s, default: 0] += 1; peak[s] = max(peak[s] ?? 0, now[s] ?? 0) }
            func leave(_ s: String) { now[s, default: 0] -= 1 }
        }
        let gauge = Gauge()
        let jobs = (1...5).map { DirectQuerySession.Job(table: "A\($0)", query: "A\($0)", source: "a") }
            + (1...2).map { DirectQuerySession.Job(table: "B\($0)", query: "B\($0)", source: "b") }
        let results = await DirectQuerySession.fetch(jobs, maxConnections: 2) { job in
            await gauge.enter(job.source)
            try await Task.sleep(nanoseconds: 20_000_000)
            await gauge.leave(job.source)
            return DataTable(name: job.table, columnNames: ["x"], rows: [[1]], types: [.integer])
        }
        XCTAssertEqual(Set(results.keys), Set(jobs.map(\.table)))
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak["a"] ?? 0, 2)
        XCTAssertLessThanOrEqual(peak["b"] ?? 0, 2)
    }

    func testTheSourceIsTheDatabaseFile() {
        XCTAssertEqual(DirectQuerySession.sourceKey("let S = Sqlite.Database(\"/data/shop.db\") in S", query: "Q"), "sqlite:/data/shop.db")
        XCTAssertEqual(DirectQuerySession.sourceKey("Sqlite.Database( \"a \"\"b\"\".db\" )", query: "Q"), "sqlite:a \"b\".db")
        XCTAssertEqual(DirectQuerySession.sourceKey("Csv.Document(File.Contents(\"x.csv\"))", query: "Q"), "query:Q")
    }

    // MARK: Storage mode choice

    func testOnlyAFoldedSQLiteQueryCanBeDirectQuery() async throws {
        let path = try database()
        let doc = document(path, mode: .import)
        let t = try XCTUnwrap(doc.model.table("Orders"))
        let folded = await StorageModeLogic.support(t, queries: doc.queries, baseDirectory: nil)
        XCTAssertEqual(folded, .directQuery)

        // Division isn't folded, so from that step on the query runs on this Mac.
        let local = [QueryDefinition(name: "Orders", mScript: "let Source = Sqlite.Database(\(MSyntax.text(path))), T = Source{[Name = \"orders\"]}[Data], Half = Table.AddColumn(T, \"half\", each [amount] / 2) in Half")]
        guard case .importOnly(let why) = await StorageModeLogic.support(t, queries: local, baseDirectory: nil) else { return XCTFail("a local step allows DirectQuery") }
        XCTAssertTrue(why.contains("Half"), why)

        let csvPath = dir.appendingPathComponent("orders.csv").path
        try Data("id,amount\n1,10\n".utf8).write(to: URL(fileURLWithPath: csvPath))
        let csv = [QueryDefinition(name: "Orders", mScript: "Csv.Document(File.Contents(\(MSyntax.text(csvPath))))")]
        guard case .importOnly = await StorageModeLogic.support(t, queries: csv, baseDirectory: nil) else { return XCTFail("a CSV file can't run queries") }

        var calculated = t
        calculated.expression = "ROW(\"x\", 1)"
        guard case .importOnly(let reason) = await StorageModeLogic.support(calculated, queries: doc.queries, baseDirectory: nil) else { return XCTFail() }
        XCTAssertTrue(reason.contains("always imported"))
    }

    func testSwitchingToDirectQueryDropsTheImportedRows() throws {
        let path = try database()
        var doc = document(path, mode: .import)
        doc.data["Orders"] = DataTable(name: "Orders", columnNames: ["id", "item", "amount"], rows: [[1, "Pen", 10]], types: [.integer, .text, .integer])
        let store = DocumentStore(services: .live())
        store.replaceDocument(doc, url: nil)
        StorageModeLogic.set(.directQuery, table: "Orders", store: store)
        XCTAssertEqual(store.model.table("Orders")?.storageMode, .directQuery)
        XCTAssertNil(store.doc.data["Orders"])
        store.undo()
        XCTAssertEqual(store.model.table("Orders")?.storageMode, .import)
        XCTAssertEqual(store.doc.data["Orders"]?.rowCount, 1)
    }

    func testRelationshipChecksCanSkipDirectQueryTables() {
        let suite = "DirectQueryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let doc = document("/nowhere.sqlite")
        XCTAssertEqual(RelationshipEditLogic.unvalidatedTables(doc.model, defaults: defaults), [])
        defaults.set(true, forKey: AppSettings.Key.dqSkipRelationshipValidation.rawValue)
        XCTAssertEqual(RelationshipEditLogic.unvalidatedTables(doc.model, defaults: defaults), ["orders"])
        let data = DataStore(tables: ["Orders": DataTable(name: "Orders", columnNames: ["id"], rows: [[1], [1]], types: [.integer])])
        let r = Relationship(fromTable: "Other", fromColumn: "id", toTable: "Orders", toColumn: "id")
        XCTAssertEqual(RelationshipEditLogic.uniqueness(r, data: data).to, false)
        XCTAssertNil(RelationshipEditLogic.uniqueness(r, data: data, skipping: ["orders"]).to)
    }
}
