import XCTest
import SQLite3
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Get Data end to end against real files: connect → navigator → Load / Transform Data → queries and tables in the document.
@MainActor
final class GetDataSessionTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("GetDataSessionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "GetDataSessionTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }
    private func session(_ id: String, _ location: String) throws -> GetDataSession {
        let s = GetDataSession(store: DocumentStore(services: .live()), security: QuerySecurity(defaults: defaults))
        s.choose(try XCTUnwrap(DataConnector.connector(id)), location: location)
        return s
    }
    private func database() throws -> String {
        let path = dir.appendingPathComponent("shop.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("could not create the test database") }
        defer { sqlite3_close(db) }
        let sql = """
        create table orders (id integer, item text);
        insert into orders values (1, 'Pen'), (2, 'Ink'), (3, 'Cap');
        create view big_orders as select * from orders where id > 1;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw XCTSkip("could not fill the test database") }
        return path
    }

    func testTextFileDetectsDelimiterHeadersAndTypesThenLoads() async throws {
        let path = try write("sales.csv", "Region;Amount\nNorth;10\nSouth;20.5\n")
        let s = try session("csv", path)
        XCTAssertEqual(s.stage, .form)
        await s.connect()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.stage, .navigator)
        XCTAssertTrue(s.items.isEmpty, "a text file is one table")
        XCTAssertEqual(s.request.delimiter, ";")
        XCTAssertTrue(s.promoteHeaders)
        XCTAssertEqual(s.preview?.table.columnNames, ["Region", "Amount"])
        XCTAssertEqual(s.preview?.table.column("Amount")?.type, .decimal)

        let closed = await s.finish(.load)
        XCTAssertTrue(closed)
        XCTAssertTrue(s.isDone)
        let doc = s.store.doc
        XCTAssertEqual(doc.queries.map(\.name), ["sales"])
        XCTAssertEqual(MScript.steps(of: doc.queries[0].mScript).map(\.name), ["Source", "Promoted Headers", "Changed Type"])
        XCTAssertEqual(doc.data["sales"]?.rowCount, 2)
        XCTAssertEqual(doc.data["sales"]?.column("Amount")?.values, [.double(10), .double(20.5)])
        XCTAssertEqual(doc.model.tables.map(\.name), ["sales"])
        XCTAssertEqual(doc.model.tables.first?.sourceQuery, "sales")
        XCTAssertEqual(doc.dataSources.map(\.kind), ["File"])
        XCTAssertEqual(doc.dataSources.first?.location, path)
        XCTAssertEqual(s.security.recentSources.map(\.location), [path])
    }

    func testTurningHeadersOffKeepsTheFirstRowAsData() async throws {
        let s = try session("csv", try write("names.csv", "Region,Amount\nNorth,10\n"))
        await s.connect()
        s.promoteHeaders = false
        await s.focus(nil)
        XCTAssertEqual(s.preview?.table.columnNames, ["Column1", "Column2"])
        XCTAssertEqual(s.preview?.table.rowCount, 2)
    }

    func testJsonListOfRecordsBecomesATable() async throws {
        let s = try session("json", try write("people.json", #"[{"id":1,"name":"Ann"},{"id":2,"name":"Bob","city":"Oslo"}]"#))
        await s.connect()
        XCTAssertNil(s.previewError)
        XCTAssertEqual(s.preview?.table.columnNames, ["id", "name", "city"])
        _ = await s.finish(.load)
        let table = try XCTUnwrap(s.store.doc.data["people"])
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertEqual(table.column("city")?.values, [.null, .string("Oslo")])
        XCTAssertEqual(MScript.steps(of: s.store.doc.queries[0].mScript).first { $0.name == "Converted to Table" }?.expression,
                       "Table.FromRecords(Source, {\"id\", \"name\", \"city\"}, MissingField.UseNull)")
    }

    func testDatabaseNavigatorLoadsCheckedObjectsInDirectQueryMode() async throws {
        let s = try session("sqlite", try database())
        s.request.directQuery = true
        await s.connect()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.items.map(\.name), ["big_orders", "orders"])
        XCTAssertEqual(s.items.map(\.kind), ["View", "Table"])
        XCTAssertEqual(s.checked, [s.items[0].id], "the first object starts checked")
        s.checked = Set(s.items.map(\.id))
        _ = await s.finish(.load)
        let doc = s.store.doc
        XCTAssertEqual(doc.queries.map(\.name), ["big_orders", "orders"])
        XCTAssertEqual(doc.data["orders"]?.rowCount, 3)
        XCTAssertEqual(doc.data["big_orders"]?.rowCount, 2)
        XCTAssertEqual(doc.data["orders"]?.column("id")?.type, .integer)
        XCTAssertEqual(doc.model.tables.map(\.storageMode), [.directQuery, .directQuery])
        XCTAssertEqual(doc.dataSources.map(\.kind), ["SQLite"])
    }

    func testNativeQueryNeedsApprovalOnceThenOpensTheEditor() async throws {
        let path = try database()
        let s = try session("sqlite", path)
        s.request.nativeQuery = "select item from orders where id > 1 order by id"
        await s.connect()
        XCTAssertEqual(s.stage, .approval, "nothing runs before the user approves")
        XCTAssertNil(s.preview)
        await s.approveNativeQuery()
        XCTAssertEqual(s.stage, .navigator)
        XCTAssertTrue(s.items.isEmpty)
        XCTAssertEqual(s.preview?.table.column("item")?.values, [.string("Ink"), .string("Cap")])

        _ = await s.finish(.transform)
        let doc = s.store.doc
        XCTAssertEqual(doc.queries.map(\.name), ["shop"])
        XCTAssertTrue(doc.data.tables.isEmpty, "Transform Data adds the query without loading it")
        XCTAssertEqual(QueryEditorRouting.takeSelection(for: s.store), "shop")

        // The approval is remembered for this database and statement.
        let again = GetDataSession(store: DocumentStore(services: .live()), security: s.security)
        again.choose(try XCTUnwrap(DataConnector.connector("sqlite")), location: path)
        again.request.nativeQuery = "select item from orders where id > 1 order by id"
        await again.connect()
        XCTAssertEqual(again.stage, .navigator)
    }

    func testFolderCombinesFilesOfTheMostCommonFormat() async throws {
        _ = try write("in/a.csv", "k,v\n1,x\n")
        _ = try write("in/b.csv", "k,v\n2,y\n")
        _ = try write("in/readme.txt", "not data")
        let s = try session("folder", dir.appendingPathComponent("in").path)
        await s.connect()
        XCTAssertEqual(s.preview?.table.rowCount, 3, "the navigator previews the file list")
        XCTAssertEqual(s.combine?.extension, ".csv")
        _ = await s.finish(.load, combined: true)
        XCTAssertNil(s.error)
        let table = try XCTUnwrap(s.store.doc.data["in"])
        XCTAssertEqual(table.columnNames, ["k", "v", "Source.Name"])
        XCTAssertEqual(Set(table.rows.map { $0.map(\.asString).joined(separator: "|") }), ["1|x|a.csv", "2|y|b.csv"])
        XCTAssertEqual(table.column("k")?.type, .integer)
    }

    func testMissingFileReportsTheErrorAndStaysOnTheForm() async throws {
        let s = try session("csv", dir.appendingPathComponent("nope.csv").path)
        await s.connect()
        XCTAssertEqual(s.stage, .form)
        XCTAssertTrue(try XCTUnwrap(s.error).contains("nope.csv"))
        XCTAssertTrue(s.store.doc.queries.isEmpty)
    }

    func testSecondLoadOfTheSameFileGetsAUniqueName() async throws {
        let path = try write("t.csv", "a,b\n1,2\n")
        let first = try session("csv", path)
        await first.connect()
        _ = await first.finish(.load)
        let second = GetDataSession(store: first.store, security: first.security)
        second.choose(try XCTUnwrap(DataConnector.connector("csv")), location: path)
        await second.connect()
        _ = await second.finish(.load)
        XCTAssertEqual(first.store.doc.queries.map(\.name), ["t", "t (2)"])
        XCTAssertEqual(first.store.doc.dataSources.count, 1, "one record per source")
    }

    func testBlankQueryOpensTheEditorOnANewQuery() async throws {
        let s = GetDataSession(store: DocumentStore(services: .live()), security: QuerySecurity(defaults: defaults))
        s.request = SourceRequest(kind: .blank)
        _ = await s.finish(.transform)
        XCTAssertEqual(s.store.doc.queries.map(\.name), ["Query1"])
        XCTAssertEqual(QueryEditorRouting.takeSelection(for: s.store), "Query1")
    }

    func testUnavailableConnectorCannotBeStarted() throws {
        let s = GetDataSession(store: DocumentStore(services: .live()), security: QuerySecurity(defaults: defaults))
        s.choose(try XCTUnwrap(DataConnector.connector("sqlserver")))
        XCTAssertEqual(s.stage, .catalog)
        XCTAssertNil(s.connector)
    }
}
