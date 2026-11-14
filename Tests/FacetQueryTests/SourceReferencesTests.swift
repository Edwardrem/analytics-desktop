import XCTest
import FacetCore
@testable import FacetQuery

/// `MScript.sourceReferences` (sources named by a script) and `QueryEngine.structuredColumn` (fields of nested values).
final class SourceReferencesTests: FixtureTestCase {
    func testConnectorCallsWithLiteralLocations() {
        let script = """
        let
            Source = Csv.Document(File.Contents("/data/sales.csv"), [Delimiter = ","]),
            // File.Contents("/in/a/comment.csv") is not a source
            Rates = Json.Document(Web.Contents("https://api.example.com/v1/rates?x=1")),
            Page = Web.Page(Web.Contents("https://api.example.com/other")),
            Db = Sqlite.Database("/db/shop.sqlite"),
            Files = Folder.Files("~/in"),
            Feed = OData.Feed("http://services.odata.org/V4/TripPin", null, [Implementation = "2.0"]),
            Sql = Sql.Database("srv01", "Sales"),
            Pg = PostgreSQL.Database("pg.local"),
            List = SharePoint.Tables("https://contoso.sharepoint.com/sites/x", [ApiVersion = 15]),
            Again = File.Contents("/data/sales.csv"),
            Dynamic = File.Contents(Folder & "x.csv"),
            Text = "File.Contents(""/not/a/call"")"
        in
            Source
        """
        XCTAssertEqual(MScript.sourceReferences(in: script), [
            QueryDataSource(kind: "File", location: "/data/sales.csv"),
            QueryDataSource(kind: "Web", location: "https://api.example.com"),
            QueryDataSource(kind: "SQLite", location: "/db/shop.sqlite"),
            QueryDataSource(kind: "Folder", location: "~/in"),
            QueryDataSource(kind: "OData", location: "http://services.odata.org"),
            QueryDataSource(kind: "SQL Server", location: "srv01;Sales"),
            QueryDataSource(kind: "PostgreSQL", location: "pg.local"),
            QueryDataSource(kind: "SharePoint list", location: "https://contoso.sharepoint.com/sites/x"),
        ])
        XCTAssertEqual(MScript.sourceReferences(in: "let Source = Excel.Workbook(Web.Contents(\"HTTPS://files.example.org/b.xlsx\")) in Source"),
                       [QueryDataSource(kind: "Web", location: "https://files.example.org")])
        XCTAssertTrue(MScript.sourceReferences(in: "let Source = #table({\"A\"}, {{1}}) in Source").isEmpty)
        XCTAssertTrue(MScript.sourceReferences(in: "Web.Contents(\"ftp://example.com/x\")").isEmpty, "the engine refuses non-http addresses")
        XCTAssertTrue(MScript.sourceReferences(in: "let Source = \"unterminated in Source").isEmpty)
    }

    func testStaticSourcesMatchWhatTheEngineRecords() async throws {
        let csv = try write("sales.csv", "a,b\n1,2\n")
        try write("in/x.csv", "a\n1\n")
        let folder = dir.appendingPathComponent("in").path
        let script = "let Source = Csv.Document(File.Contents(\(MSyntax.text(csv)))), Files = Folder.Files(\(MSyntax.text(folder))), "
            + "Both = Table.RowCount(Source) + Table.RowCount(Files) in Both"
        let e = engine([("Q", script)])
        _ = try await e.evaluateValue("Q")
        XCTAssertEqual(e.dataSourcesAccessed, MScript.sourceReferences(in: script))
        XCTAssertEqual(MScript.sourceReferences(in: script).map(\.kind), ["File", "Folder"])
    }

    private let nested = """
    #table({"Id", "Nested", "Rec", "Items", "Mixed"}, {
        {1, #table({"A", "B"}, {{1, 2}}), [x = 1, y = 2], {1, 2}, null},
        {2, #table({"B", "C"}, {{3, 4}}), [y = 3, z = 4], {3}, [k = 1]},
        {3, null, null, null, {1}},
        {4, #table({"D"}, {}), [w = error "bad"], {}, {2}}
    })
    """

    func testStructuredColumnsReportKindAndFieldsInFirstSeenOrder() async throws {
        let e = engine([("Q", "let Source = \(nested), Kept = Table.FirstN(Source, 2) in Kept")])
        // Kept (the result) has the first two rows; step 0 (Source) has all four.
        let kept2 = try await e.structuredColumn("Nested", of: "Q")
        XCTAssertEqual(kept2, StructuredColumnInfo(kind: "Table", fields: ["A", "B", "C"]))
        let tables = try await e.structuredColumn("Nested", of: "Q", upToStep: 0)
        XCTAssertEqual(tables, StructuredColumnInfo(kind: "Table", fields: ["A", "B", "C", "D"]))
        let records = try await e.structuredColumn("Rec", of: "Q", upToStep: 0)
        XCTAssertEqual(records, StructuredColumnInfo(kind: "Record", fields: ["x", "y", "z", "w"]))
        let lists = try await e.structuredColumn("Items", of: "Q", upToStep: 0)
        XCTAssertEqual(lists, StructuredColumnInfo(kind: "List", fields: []))
        // Mixed: one record, two lists (nulls are not sampled).
        let mixed = try await e.structuredColumn("Mixed", of: "Q", upToStep: 0)
        XCTAssertEqual(mixed, StructuredColumnInfo(kind: "List", fields: []))
        // The step Kept has two rows: the record in Mixed is the only structured value there.
        let kept = try await e.structuredColumn("Mixed", of: "Q")
        XCTAssertEqual(kept, StructuredColumnInfo(kind: "Record", fields: ["k"]))
    }

    func testStructuredColumnSampleScalarsAndMissingColumns() async throws {
        let e = engine([("Q", nested)])
        let first = try await e.structuredColumn("Nested", of: "Q", sampleRows: 1)
        XCTAssertEqual(first, StructuredColumnInfo(kind: "Table", fields: ["A", "B"]))
        let scalars = try await e.structuredColumn("Id", of: "Q")
        XCTAssertNil(scalars)
        do {
            _ = try await e.structuredColumn("Nope", of: "Q")
            XCTFail("a missing column throws")
        } catch {
            XCTAssertTrue(MError.wrap(error).description.contains("Nope"))
        }
        let scalar = engine([("S", "1 + 1")])
        do {
            _ = try await scalar.structuredColumn("A", of: "S")
            XCTFail("a number is not a table")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a table"), error.localizedDescription)
        }
    }
}
