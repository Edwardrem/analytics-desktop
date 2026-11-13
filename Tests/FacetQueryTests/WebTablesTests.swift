import XCTest
import FacetCore
@testable import FacetQuery

final class WebTablesTests: FixtureTestCase {
    private let page = """
    <html><head><style>td { color: red }</style></head><body>
    <table id="t1" class="grid"><caption>Sales</caption>
    <thead><tr><th>Region</th><th>Q1</th><th>Q2</th></tr></thead>
    <tbody><tr><td rowspan="2">North</td><td>10</td><td>20</td></tr>
    <tr><td colspan="2">n/a</td></tr>
    <tr><td>South <b>East</b><br>x</td><td> 5 </td></tr></tbody></table>
    <p>Not a table</p>
    <table><tr><td>a</td><td>b</td></tr></table>
    </body></html>
    """

    func testWebPageListsTablesWithCaptionIdAndClass() throws {
        let path = try write("page.html", page)
        let v = try eval("Web.Page(File.Contents(\"\(path)\"))")
        XCTAssertEqual(columnNames(v), ["Caption", "Source", "ClassName", "Id", "Data"])
        XCTAssertEqual(try tableRows(v), [["Sales", "Table", "grid", "t1", "<table>"], ["null", "Table", "null", "null", "<table>"]])
    }

    func testHeaderRowSpansAndShortRows() throws {
        let path = try write("page.html", page)
        let first = try eval("Web.Page(File.Contents(\"\(path)\")){0}[Data]")
        XCTAssertEqual(columnNames(first), ["Region", "Q1", "Q2"])
        XCTAssertEqual(try tableRows(first), [["North", "10", "20"], ["North", "n/a", "n/a"], ["South East x", "5", "null"]])
    }

    func testTableWithoutHeaderGetsColumnNames() throws {
        let second = try eval("Web.Page(\"<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>\"){0}[Data]")
        XCTAssertEqual(columnNames(second), ["Column1", "Column2"])
        XCTAssertEqual(try tableRows(second), [["a", "b"], ["c", "d"]])
    }

    func testPageWithoutTablesIsEmpty() throws {
        XCTAssertEqual(try tableRows(try eval("Web.Page(\"<html><body><p>Hello</p></body></html>\")")), [])
    }

    // MARK: OData

    private func feed(_ documents: [String: String], at address: String, fetched: inout [String]) throws -> MValue {
        var log: [String] = []
        defer { fetched = log }
        return try ODataFeed.value(at: address) { url in
            log.append(url)
            guard let json = documents[url] else { throw MError.dataSource("no document at \(url)") }
            return try JsonParser.parse(Data(json.utf8))
        }
    }

    func testServiceDocumentBecomesNavigationTableOfEntitySets() throws {
        let documents = [
            "https://h/svc": #"{"@odata.context":"https://h/svc/$metadata","value":[{"name":"People","kind":"EntitySet","url":"People"},{"name":"Reset","kind":"FunctionImport","url":"Reset"}]}"#,
            "https://h/svc/People": #"{"value":[{"Id":1,"Name":"Ann"}]}"#,
        ]
        var fetched: [String] = []
        let nav = try XCTUnwrap(try feed(documents, at: "https://h/svc", fetched: &fetched).tableValue)
        XCTAssertEqual(nav.columnNames, ["Name", "Data", "Signature"])
        XCTAssertEqual(try nav.rows.map { show($0[0]) }, ["People"])
        XCTAssertEqual(fetched, ["https://h/svc"])                      // entity sets load only when opened
        let people = try nav.rows[0][1].forced()
        XCTAssertEqual(try tableRows(people), [["1", "Ann"]])
    }

    func testEntitySetFollowsNextLinksAndDropsAnnotations() throws {
        let documents = [
            "https://h/svc/People": #"{"@odata.context":"c","value":[{"@odata.etag":"W/1","Id":1,"Name":"Ann"},{"Id":2,"Name":"Bob","City":"Oslo"}],"@odata.nextLink":"People?$skip=2"}"#,
            "https://h/svc/People?$skip=2": #"{"value":[{"Id":3,"Name":"Cy"}]}"#,
        ]
        var fetched: [String] = []
        let v = try feed(documents, at: "https://h/svc/People", fetched: &fetched)
        XCTAssertEqual(columnNames(v), ["Id", "Name", "City"])
        XCTAssertEqual(try tableRows(v), [["1", "Ann", "null"], ["2", "Bob", "Oslo"], ["3", "Cy", "null"]])
        XCTAssertEqual(fetched, ["https://h/svc/People", "https://h/svc/People?$skip=2"])
    }

    func testVersion2VerboseJson() throws {
        let documents = [
            "https://h/v2": #"{"d":{"EntitySets":["Items"]}}"#,
            "https://h/v2/Items": #"{"d":{"results":[{"__metadata":{"uri":"u"},"A":"x"}],"__next":"https://h/v2/Items?$skiptoken=1"}}"#,
            "https://h/v2/Items?$skiptoken=1": #"{"d":{"results":[{"A":"y"}]}}"#,
        ]
        var fetched: [String] = []
        let nav = try XCTUnwrap(try feed(documents, at: "https://h/v2", fetched: &fetched).tableValue)
        XCTAssertEqual(try nav.rows.map { show($0[0]) }, ["Items"])
        let items = try nav.rows[0][1].forced()
        XCTAssertEqual(columnNames(items), ["A"])
        XCTAssertEqual(try tableRows(items), [["x"], ["y"]])
    }

    func testEntitySetAddressKeepsTheServiceQuery() {
        XCTAssertEqual(ODataFeed.entitySetAddress("People", root: "https://h/svc/"), "https://h/svc/People")
        XCTAssertEqual(ODataFeed.entitySetAddress("People", root: "https://h/svc?key=1"), "https://h/svc/People?key=1")
        XCTAssertEqual(ODataFeed.entitySetAddress("https://other/People", root: "https://h/svc"), "https://other/People")
    }

    func testFeedRejectsAddressesThatAreNotHttp() {
        let error = failure("OData.Feed(\"ftp://example.com/svc\")")
        XCTAssertEqual(error?.reason, "DataSource.Error")
    }
}
