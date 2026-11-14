import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Serves fixed documents to `URLSession.shared` for hosts ending in `.getdata.test`.
final class GetDataStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var documents: [String: String] = [:]
    static func serve(_ docs: [String: String]) { lock.lock(); documents = docs; lock.unlock() }
    static func document(_ url: String) -> String? { lock.lock(); defer { lock.unlock() }; return documents[url] }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("getdata.test") ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.document(url.absoluteString)
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data((body ?? "not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Get Data end to end for workbooks, XML, web addresses (CSV, HTML tables) and OData feeds.
@MainActor
final class GetDataConnectorTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("GetDataConnectorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "GetDataConnectorTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        URLProtocol.registerClass(GetDataStubProtocol.self)
    }
    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(GetDataStubProtocol.self)
        GetDataStubProtocol.serve([:])
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func session(_ id: String, _ location: String) throws -> GetDataSession {
        let s = GetDataSession(store: DocumentStore(services: .live()), security: QuerySecurity(defaults: defaults))
        s.choose(try XCTUnwrap(DataConnector.connector(id)), location: location)
        return s
    }
    private func steps(_ s: GetDataSession, _ i: Int = 0) -> [String] { MScript.steps(of: s.store.doc.queries[i].mScript).map(\.name) }

    // MARK: Files

    func testExcelSheetLoadsWithPromotedHeadersAndTypes() async throws {
        let ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        let rels = "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\""
        func cell(_ ref: String, _ text: String) -> String { "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>" }
        let sheet = """
        <worksheet \(ns)><sheetData>
          <row r="1">\(cell("A1", "Region"))\(cell("B1", "Amount"))</row>
          <row r="2">\(cell("A2", "North"))<c r="B2"><v>10</v></c></row>
          <row r="3">\(cell("A3", "South"))<c r="B3"><v>20</v></c></row>
        </sheetData></worksheet>
        """
        let parts = [
            ("[Content_Types].xml", "<Types/>"),
            ("xl/workbook.xml", "<workbook \(ns)><sheets><sheet name=\"Sales\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships \(rels)><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        let path = dir.appendingPathComponent("book.xlsx")
        try StoredZip.archive(parts).write(to: path)
        let s = try session("excel", path.path)
        await s.connect()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.items.map(\.name), ["Sales"])
        XCTAssertEqual(s.preview?.table.columnNames, ["Region", "Amount"])
        _ = await s.finish(.load)
        XCTAssertEqual(s.store.doc.queries.map(\.name), ["Sales"])
        XCTAssertEqual(steps(s), ["Source", "Sales_Sheet", "Promoted Headers", "Changed Type"])
        XCTAssertEqual(s.store.doc.data["Sales"]?.column("Amount")?.values, [.int(10), .int(20)])
        XCTAssertEqual(s.store.doc.data["Sales"]?.column("Amount")?.type, .integer)
    }

    func testXmlElementsBecomeNavigatorTables() async throws {
        let path = dir.appendingPathComponent("orders.xml").path
        try Data("<orders><order><id>1</id><item>Pen</item></order><order><id>2</id><item>Ink</item></order></orders>".utf8).write(to: URL(fileURLWithPath: path))
        let s = try session("xml", path)
        await s.connect()
        XCTAssertNil(s.error)
        let order = try XCTUnwrap(s.items.first { $0.name == "order" })
        s.checked = [order.id]
        _ = await s.finish(.load)
        let table = try XCTUnwrap(s.store.doc.data["order"])
        XCTAssertEqual(table.columnNames, ["id", "item"])
        XCTAssertEqual(table.column("id")?.values, [.int(1), .int(2)])
        XCTAssertEqual(table.column("item")?.values, [.string("Pen"), .string("Ink")])
    }

    // MARK: Web

    func testWebAddressServingCSV() async throws {
        GetDataStubProtocol.serve(["https://files.getdata.test/prices.csv": "Item;Price\nPen;1.5\nInk;2\n"])
        let s = try session("web", "https://files.getdata.test/prices.csv")
        await s.connect()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.request.webContent, .csv)
        XCTAssertEqual(s.request.delimiter, ";")
        _ = await s.finish(.load)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.store.doc.queries.map(\.name), ["prices"])
        XCTAssertEqual(s.store.doc.data["prices"]?.column("Price")?.values, [.double(1.5), .double(2)])
        XCTAssertEqual(s.store.doc.dataSources.map(\.location), ["https://files.getdata.test"])
        XCTAssertEqual(s.store.doc.dataSources.map(\.kind), ["Web"])
    }

    func testHtmlPageOffersItsTables() async throws {
        let page = """
        <!DOCTYPE html><html><body>
        <table><caption>Prices</caption><tr><th>Item</th><th>Price</th></tr><tr><td>Pen</td><td>1</td></tr></table>
        <table><tr><th>City</th></tr><tr><td>Oslo</td></tr><tr><td>Rome</td></tr></table>
        </body></html>
        """
        GetDataStubProtocol.serve(["https://www.getdata.test/report": page])
        let s = try session("web", "https://www.getdata.test/report")
        await s.connect()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.request.webContent, .html)
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.items.first?.name, "Prices")
        s.checked = Set(s.items.map(\.id))
        _ = await s.finish(.load)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.store.doc.data["Prices"]?.column("Item")?.values, [.string("Pen")])
        let second = try XCTUnwrap(s.store.doc.queries.last?.name)
        XCTAssertEqual(s.store.doc.data[second]?.column("City")?.values, [.string("Oslo"), .string("Rome")])
    }

    func testODataFeedEntitySetsLoad() async throws {
        GetDataStubProtocol.serve([
            "https://svc.getdata.test/odata": #"{"@odata.context":"https://svc.getdata.test/odata/$metadata","value":[{"name":"People","kind":"EntitySet","url":"People"}]}"#,
            "https://svc.getdata.test/odata/People": #"{"value":[{"Id":1,"Name":"Ann"},{"Id":2,"Name":"Bob"}]}"#,
        ])
        let s = try session("odata", "https://svc.getdata.test/odata")
        await s.connect()
        XCTAssertNil(s.error)
        XCTAssertEqual(s.items.map(\.name), ["People"])
        _ = await s.finish(.load)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.store.doc.data["People"]?.column("Name")?.values, [.string("Ann"), .string("Bob")])
        XCTAssertEqual(s.store.doc.dataSources.map(\.kind), ["OData"])
    }

    func testAnAddressThatFailsStaysOnTheForm() async throws {
        let s = try session("web", "https://files.getdata.test/missing.csv")
        await s.connect()
        XCTAssertEqual(s.stage, .form)
        XCTAssertNotNil(s.error)
    }

    // MARK: Inside the editor

    func testNewSourceInsideTheEditorAddsQueriesWithoutLoading() async throws {
        let path = dir.appendingPathComponent("t.csv").path
        try Data("a,b\n1,2\n".utf8).write(to: URL(fileURLWithPath: path))
        let store = DocumentStore(services: .live())
        let editor = QueryEditorSession(store: store, security: QuerySecurity(defaults: defaults))
        let s = GetDataSession(store: store, security: editor.security)
        s.insideEditor = true
        s.choose(try XCTUnwrap(DataConnector.connector("csv")), location: path)
        await s.connect()
        _ = await s.finish(.transform)
        XCTAssertTrue(store.doc.data.tables.isEmpty)
        XCTAssertEqual(editor.queries.map(\.name), ["t"])
        XCTAssertEqual(editor.selectedQuery?.name, "t", "the editor selects the new query")
        XCTAssertEqual(editor.refreshPlan().refresh, ["t"], "Apply loads it")
    }
}

/// ZIP archives with stored entries (enough for a hand-written .xlsx).
enum StoredZip {
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    static func archive(_ entries: [(String, String)]) -> Data {
        var out = Data(), directory = Data()
        func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func put32(_ d: inout Data, _ v: Int) { put16(&d, v & 0xFFFF); put16(&d, (v >> 16) & 0xFFFF) }
        for (name, text) in entries {
            let body = Data(text.utf8), nameBytes = Data(name.utf8), offset = out.count, crc = Int(crc32(body))
            func sizes(_ d: inout Data) { put32(&d, crc); put32(&d, body.count); put32(&d, body.count); put16(&d, nameBytes.count); put16(&d, 0) }
            put32(&out, 0x04034b50)
            for _ in 0..<5 { put16(&out, 0) }
            sizes(&out)
            out.append(nameBytes); out.append(body)
            put32(&directory, 0x02014b50)
            for _ in 0..<6 { put16(&directory, 0) }
            sizes(&directory)
            for _ in 0..<3 { put16(&directory, 0) }
            put32(&directory, 0); put32(&directory, offset)
            directory.append(nameBytes)
        }
        let start = out.count
        out.append(directory)
        put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0); put16(&out, entries.count); put16(&out, entries.count)
        put32(&out, directory.count); put32(&out, start); put16(&out, 0)
        return out
    }
}
