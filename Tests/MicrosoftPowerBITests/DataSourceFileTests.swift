import XCTest
import FacetCore
import FacetInterop
@testable import MicrosoftPowerBI

/// `.pbids` data source files open as Power BI Desktop opens them: an empty document with Get Data's navigator for the
/// file's connection, where the preview has its headers promoted and types detected, and Load or Transform Data
/// finishes the job.
@MainActor
final class DataSourceFileTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        Features.registerAll()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DataSourceFileTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "DataSourceFileTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func pbids(_ connections: String, name: String = "regions.pbids") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(#"{"version": "0.1", "connections": [\#(connections)]}"#.utf8).write(to: url)
        return url
    }
    private func file(_ path: String, mode: String = "Import") -> String {
        #"{"details": {"protocol": "file", "address": {"path": "\#(path)"}}, "mode": "\#(mode)"}"#
    }
    private func connections(_ json: String) throws -> [PBIDS.Connection] { try PBIDS.read(from: try pbids(json)) }
    private func regionsCSV() throws -> String {
        let csv = dir.appendingPathComponent("regions.csv")
        try Data("Region,Amount\nNorth,10\nSouth,20\nEast,5\n".utf8).write(to: csv)
        return csv.path
    }

    // MARK: Opening

    func testOpeningStartsAnEmptyDocument() throws {
        let url = try pbids(file("/data/sales.csv"))
        let result = try FileOperations.read(url)
        XCTAssertTrue(result.document.queries.isEmpty, "the navigator, not the file, decides what is loaded")
        XCTAssertTrue(result.document.model.tables.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(FileOperations.documentURL(for: url), "a new, unsaved document")
        // A broken file is refused before a window opens.
        let broken = dir.appendingPathComponent("broken.pbids")
        try Data(#"{"version": "0.1"}"#.utf8).write(to: broken)
        XCTAssertThrowsError(try FileOperations.read(broken))
    }

    func testEachProtocolOpensItsGetDataConnector() throws {
        func plan(_ json: String) throws -> DataSourceFiles.Plan { DataSourceFiles.plan(for: try connections(json), file: "x.pbids") }
        func connector(_ json: String) throws -> (String, String)? {
            guard case .navigator(let c, let location, _) = try plan(json) else { return nil }
            return (c.id, location)
        }
        XCTAssertEqual(try connector(file("/data/sales.csv"))?.0, "csv")
        XCTAssertEqual(try connector(file("/data/sales.csv"))?.1, "/data/sales.csv")
        XCTAssertEqual(try connector(file("/data/notes.txt"))?.0, "csv")
        XCTAssertEqual(try connector(file("/data/book.xlsx"))?.0, "excel")
        XCTAssertEqual(try connector(file("/data/feed.json"))?.0, "json")
        XCTAssertEqual(try connector(file("/data/feed.xml"))?.0, "xml")
        XCTAssertEqual(try connector(#"{"details": {"protocol": "folder", "address": {"path": "/data/in"}}}"#)?.0, "folder")
        XCTAssertEqual(try connector(#"{"details": {"protocol": "http", "address": {"url": "https://example.com/a.csv"}}}"#)?.0, "web")
        XCTAssertEqual(try connector(#"{"details": {"protocol": "http", "address": {"url": "https://example.com/a.csv"}}}"#)?.1,
                       "https://example.com/a.csv")
        XCTAssertEqual(try connector(#"{"details": {"protocol": "odata", "address": {"url": "https://example.com/odata"}}}"#)?.0, "odata")

        // SQL Server opens its form with the server and the database.
        let sql = try connector(#"{"details": {"protocol": "tds", "address": {"server": "srv", "database": "Sales"}}}"#)
        XCTAssertEqual(sql?.0, "sqlserver")
        XCTAssertEqual(sql?.1, "srv;Sales")
        // Sources the catalog lists but can't connect to say why, in the catalog's own words.
        guard case .unavailable(let ssas) = try plan(#"{"details": {"protocol": "analysis-services", "address": {"server": "srv", "database": "Model"}}}"#) else {
            return XCTFail("Analysis Services has no working connector here")
        }
        XCTAssertTrue(ssas.contains("Analysis Services srv / Model"), ssas)
        XCTAssertTrue(ssas.contains("SQL Server Analysis Services database"), ssas)
        XCTAssertTrue(ssas.contains(DataConnector.Missing.driver), ssas)
        guard case .navigator(let parquet, _, _) = try plan(file("/data/t.parquet")) else { return XCTFail("parquet opens Get Data") }
        XCTAssertEqual(parquet.id, "parquet")
        guard case .unavailable(let unknown) = try plan(file("/data/archive.bin")) else { return XCTFail("unknown file type") }
        XCTAssertTrue(unknown.contains("can't read"), unknown)
    }

    func testOneConnectionOpensAndTheRestAreNamed() throws {
        let plan = DataSourceFiles.plan(for: try connections(file("/data/a.csv") + ", " + file("/data/b.csv", mode: "DirectQuery")), file: "two.pbids")
        guard case .navigator(let c, let location, let notes) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(c.id, "csv")
        XCTAssertEqual(location, "/data/a.csv")
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("2 connections"), notes[0])
        XCTAssertTrue(notes[0].contains("File /data/b.csv"), notes[0])

        let direct = DataSourceFiles.plan(for: try connections(file("/data/a.csv", mode: "DirectQuery")), file: "dq.pbids")
        guard case .navigator(_, _, let dqNotes) = direct else { return XCTFail("\(direct)") }
        XCTAssertEqual(dqNotes.count, 1)
        XCTAssertTrue(dqNotes[0].contains("DirectQuery"), dqNotes[0])
        XCTAssertTrue(dqNotes[0].contains("imported"), dqNotes[0])
    }

    func testOpeningPresentsGetDataOrSaysWhyNot() async throws {
        let store = DocumentStore(services: .live())
        DataSourceFiles.startGetData(from: try pbids(file(try regionsCSV())), in: store)
        XCTAssertNotNil(store.sheet, "Get Data opens over the new document")
        XCTAssertNil(store.status)

        let sql = DocumentStore(services: .live())
        DataSourceFiles.startGetData(from: try pbids(#"{"details": {"protocol": "analysis-services", "address": {"server": "srv"}}}"#, name: "sql.pbids"), in: sql)
        XCTAssertNil(sql.sheet)
        XCTAssertEqual(sql.status?.kind, .error)

        // Adopting the opened file does the same once the window is up.
        let adopted = DocumentStore(services: .live())
        FileOperations.adopt(try pbids(file(try regionsCSV()), name: "adopted.pbids"), store: adopted)
        let presented = await Smoke.wait { adopted.sheet != nil }
        XCTAssertTrue(presented)
    }

    // MARK: The navigator

    private func navigator(_ store: DocumentStore) async throws -> GetDataSession {
        let url = try pbids(file(try regionsCSV()))
        guard case .navigator(let connector, let location, _) = DataSourceFiles.plan(for: try PBIDS.read(from: url), file: url.lastPathComponent) else {
            throw XCTSkip("no navigator plan")
        }
        let s = GetDataSession(store: store, security: QuerySecurity(defaults: defaults), options: defaults)
        s.choose(connector, location: location)
        await s.connect()
        return s
    }

    func testTheNavigatorPromotesHeadersAndDetectsTypes() async throws {
        let store = DocumentStore(services: .live())
        let s = try await navigator(store)
        XCTAssertEqual(s.stage, .navigator)
        XCTAssertNil(s.previewError)
        XCTAssertTrue(s.promoteHeaders, "the first row holds names, so it becomes the headers")
        XCTAssertEqual(s.preview?.table.columnNames, ["Region", "Amount"])
        XCTAssertEqual(s.preview?.table.rowCount, 3)
        XCTAssertEqual(s.preview?.table.column("Amount")?.type, .integer)

        let loaded = await s.finish(.load)
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.doc.queries.map(\.name), ["regions"])
        XCTAssertEqual(store.doc.data["regions"]?.rowCount, 3)
        XCTAssertEqual(store.doc.data["regions"]?.column("Amount")?.values, [.int(10), .int(20), .int(5)])
        XCTAssertEqual(store.doc.model.table("regions")?.column("Amount")?.dataType, .integer)
        XCTAssertEqual(store.undoName, "Get Data", "one step, as any Get Data load")
    }

    func testTransformDataAddsTheShapedQueryForTheEditor() async throws {
        let store = DocumentStore(services: .live())
        let s = try await navigator(store)
        let added = await s.finish(.transform)
        XCTAssertTrue(added)
        let script = try XCTUnwrap(store.doc.queries.first?.mScript)
        XCTAssertTrue(script.contains("Table.PromoteHeaders"), script)
        XCTAssertTrue(script.contains("Table.TransformColumnTypes"), script)
        XCTAssertTrue(store.doc.data.tables.isEmpty, "Transform Data loads nothing until Close & Apply")
        XCTAssertEqual(QueryEditorRouting.takeSelection(for: store), "regions")
    }
}
