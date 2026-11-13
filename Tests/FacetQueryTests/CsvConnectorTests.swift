import XCTest
import FacetCore
@testable import FacetQuery

/// Text/CSV connector: `File.Contents` + `Csv.Document`. Expected values follow RFC 4180 and the documented
/// behaviour of Csv.Document (text columns named Column1…, QuoteStyle, Encoding, Columns).
final class CsvConnectorTests: FixtureTestCase {
    func testBasicDocumentHasTextColumnsNamedByPosition() throws {
        try write("a.csv", "id,name\n1,Ann\n2,Bob\n")
        let v = try eval("Csv.Document(File.Contents(\"a.csv\"))")
        XCTAssertEqual(columnNames(v), ["Column1", "Column2"])
        XCTAssertEqual(v.tableValue?.columnTypes, [.text, .text])
        XCTAssertEqual(try tableRows(v), [["id", "name"], ["1", "Ann"], ["2", "Bob"]])
    }
    func testPromoteHeaders() throws {
        try write("a.csv", "id,name,id,\n1,Ann,x,y\n")
        let v = try eval("Table.PromoteHeaders(Csv.Document(File.Contents(\"a.csv\")), [PromoteAllScalars = true])")
        // duplicate header gets a suffix, blank header gets its position
        XCTAssertEqual(columnNames(v), ["id", "name", "id_1", "Column4"])
        XCTAssertEqual(try tableRows(v), [["1", "Ann", "x", "y"]])
    }
    func testQuotedFields() throws {
        try write("q.csv", "a,\"b,c\",\"say \"\"hi\"\"\"\n\"line1\nline2\",x,\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"q.csv\"))"), [["a", "b,c", "say \"hi\""], ["line1\nline2", "x", ""]])
        // QuoteStyle.None: a line break always ends the row, even inside quotes
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"q.csv\"), [QuoteStyle = QuoteStyle.None])").count, 3)
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"q.csv\"), [QuoteStyle = QuoteStyle.Csv])").count, 2)
    }
    func testDelimiters() throws {
        try write("semi.csv", "a;b\n1,5;2\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"semi.csv\"), [Delimiter = \";\"])"), [["a", "b"], ["1,5", "2"]])
        try write("tab.tsv", "a\tb\n1\t2\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"tab.tsv\"), [Delimiter = \"#(tab)\"])"), [["a", "b"], ["1", "2"]])
        try write("pipe.txt", "a|b|c\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"pipe.txt\"), null, \"|\")"), [["a", "b", "c"]])
        try write("multi.txt", "a||b|c\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"multi.txt\"), [Delimiter = \"||\"])"), [["a", "b|c"]])
        // without the right delimiter the whole line is one field
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"semi.csv\"))"), [["a;b", "null"], ["1", "5;2"]])
    }
    func testLineEndings() throws {
        try write("crlf.csv", "a,b\r\n1,2\r\n")
        try write("cr.csv", "a,b\r1,2")
        try write("blank.csv", "a,b\n\n1,2\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"crlf.csv\"))"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"cr.csv\"))"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"blank.csv\"))"), [["a", "b"], ["", "null"], ["1", "2"]])
        try write("empty.csv", "")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"empty.csv\"))"), [])
    }
    func testEncodings() throws {
        try write("bom.csv", Data([0xEF, 0xBB, 0xBF]) + Data("naïve,b\n".utf8))
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"bom.csv\"), [Encoding = 65001])"), [["naïve", "b"]])
        try write("utf16.csv", Data([0xFF, 0xFE]) + (try XCTUnwrap("é,ü\n".data(using: .utf16LittleEndian))))
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"utf16.csv\"))"), [["é", "ü"]])
        try write("utf16nobom.csv", try XCTUnwrap("é,ü\n".data(using: .utf16LittleEndian)))
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"utf16nobom.csv\"), [Encoding = TextEncoding.Unicode])"), [["é", "ü"]])
        try write("win.csv", Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x80, 0x0A])) // "café,€" in Windows-1252
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"win.csv\"), [Encoding = 1252])"), [["café", "€"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"win.csv\"), [Encoding = TextEncoding.Windows])"), [["café", "€"]])
        // read as UTF-8 the invalid bytes become the replacement character rather than failing
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"win.csv\"))"), [["caf\u{FFFD}", "\u{FFFD}"]])
        XCTAssertNotNil(failure("Csv.Document(File.Contents(\"win.csv\"), [Encoding = 99999])"))
    }
    func testRaggedRowsAndColumnsOption() throws {
        try write("r.csv", "a,b,c\n1\n1,2,3,4\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"r.csv\"))"),
                       [["a", "b", "c", "null"], ["1", "null", "null", "null"], ["1", "2", "3", "4"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"r.csv\"), [Columns = 2])"), [["a", "b"], ["1", "null"], ["1", "2"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"r.csv\"), 2)"), [["a", "b"], ["1", "null"], ["1", "2"]])
        XCTAssertEqual(columnNames(try eval("Csv.Document(File.Contents(\"r.csv\"), {\"x\", \"y\"})")), ["x", "y"])
    }
    func testTextSourceAndBlankCellsBecomeNullWhenTyped() throws {
        let m = "Table.TransformColumnTypes(Table.PromoteHeaders(Csv.Document(\"n,d#(lf)1,2024-03-05#(lf),#(lf)x,\")), {{\"n\", Int64.Type}, {\"d\", type date}})"
        let v = try eval(m)
        XCTAssertEqual(v.tableValue?.columnTypes, [.int64, .date])
        XCTAssertEqual(try tableRows(v), [["1", "#date(2024, 3, 5)"], ["null", "null"], ["<error>", "null"]])
    }
    func testChangeTypeWithLocale() throws {
        let m = "Table.TransformColumnTypes(Table.PromoteHeaders(Csv.Document(\"amount;day#(lf)1.234,5;03/04/2024\", [Delimiter = \";\"])), "
            + "{{\"amount\", type number}, {\"day\", type date}}, \"de-DE\")"
        XCTAssertEqual(try rows(m), [["1234.5", "#date(2024, 4, 3)"]])
    }
    func testDetectDataTypes() async throws {
        try write("t.csv", "id,price,day,flag,name,mixed\n1,1.5,2024-01-05,true,Ann,1\n2,2,2024-02-06,FALSE,Bob,x\n")
        let script = "let Source = Csv.Document(File.Contents(\"t.csv\")), Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]) in Promoted"
        let e = engine([("T", script)])
        let preview = try await e.evaluate("T")
        guard case .changeType(let changes, let culture)? = Transform.detectTypes(in: preview) else { return XCTFail("no types detected") }
        XCTAssertNil(culture)
        XCTAssertEqual(changes.map(\.column), ["id", "price", "day", "flag"])
        XCTAssertEqual(changes.map(\.type), [.integer, .decimal, .date, .boolean])
        // applying the detected step yields typed columns
        let typed = MScript.appending(.changeType(changes, culture: nil), to: script)
        let table = try await engine([("T", typed)]).evaluate("T")
        XCTAssertEqual(table.columns.map(\.type), [.integer, .decimal, .date, .boolean, .text, .text])
        XCTAssertEqual(table.column("id")?.values, [.int(1), .int(2)])
        XCTAssertEqual(table.column("price")?.values, [.double(1.5), .double(2)])
        XCTAssertEqual(table.column("flag")?.values, [.bool(true), .bool(false)])
        XCTAssertEqual(table.column("day")?.values.first, .date(try MLibrary.makeDate(2024, 1, 5)))
        // nothing to detect on an already typed table
        XCTAssertNil(Transform.detectTypes(in: table))
    }
    func testErrorsAreClearAndBounded() throws {
        let missing = try XCTUnwrap(failure("Csv.Document(File.Contents(\"nope.csv\"))"))
        XCTAssertEqual(missing.reason, "DataSource.Error")
        XCTAssertTrue(missing.message.contains("nope.csv"), missing.message)
        let folder = try XCTUnwrap(failure("File.Contents(\".\")"))
        XCTAssertEqual(folder.reason, "DataSource.Error")
        XCTAssertNotNil(failure("Csv.Document(\"a,b\", [Delimiter = \"\"])"))
        XCTAssertNotNil(failure("Csv.Document(42)"))
        try write("big.csv", String(repeating: "abcdefghij\n", count: 100))
        env.maxSourceBytes = 500
        let big = try XCTUnwrap(failure("Csv.Document(File.Contents(\"big.csv\"))"))
        XCTAssertEqual(big.reason, "DataSource.Error")
        XCTAssertTrue(big.message.contains("too large") && big.message.contains("1100") && big.message.contains("500"), big.message)
    }
    func testLargeFileParsesEveryRow() throws {
        var text = "n,sq\n"
        for i in 1...20_000 { text += "\(i),\(i * i)\n" }
        try write("large.csv", text)
        let v = try eval("let t = Table.PromoteHeaders(Csv.Document(File.Contents(\"large.csv\"))) in {Table.RowCount(t), t{19999}[sq], List.Sum(List.Transform(t[n], Number.From))}")
        XCTAssertEqual(v.listValue?.map(show), ["20000", "400000000", "200010000"])
    }
    func testAbsoluteAndRelativePaths() throws {
        let path = try write("sub/x.csv", "a\n")
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\"sub/x.csv\"))"), [["a"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\(MSyntax.text(path))))"), [["a"]])
        XCTAssertEqual(try rows("Csv.Document(File.Contents(\(MSyntax.text("file://" + path))))"), [["a"]])
    }
}
