import XCTest
@testable import FacetCore

final class CoreTests: XCTestCase {
    func testValueEqualityAndOrder() {
        XCTAssertEqual(Value.int(1), Value.double(1.0))
        XCTAssertEqual(Set([Value.int(1), .double(1.0)]).count, 1)
        XCTAssertLessThan(Value.null, Value.int(0))
        XCTAssertLessThan(Value.int(2), Value.double(2.5))
        XCTAssertLessThan(Value.string("a10"), Value.string("a9").self == .string("a9") ? Value.string("b") : .null)
    }
    func testFormatting() {
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00"), "1,234.50")
        XCTAssertEqual(ValueFormatter.format(.double(0.256), "0.0%"), "25.6%")
        XCTAssertEqual(ValueFormatter.format(.double(-12), "$#,0;($#,0)"), "($12)")
        XCTAssertEqual(ValueFormatter.format(.int(7), "000"), "007")
        XCTAssertEqual(ValueFormatter.format(.double(2_500_000), "#,0.0,,\"M\""), "2.5M")
        XCTAssertEqual(ValueFormatter.format(.date(DateParsing.parse("2026-03-09")!), "yyyy-mm-dd"), "2026-03-09")
        XCTAssertEqual(ValueFormatter.format(.date(DateParsing.parse("2026-03-09")!), "mmm yyyy"), "Mar 2026")
        XCTAssertEqual(ValueFormatter.compact(1_260_000), "1.3M")
    }
    func testTypeDetection() {
        var t = DataTable(columnNames: ["a", "b", "c"], rows: [["1", "2.5", "2026-01-02"], ["3", "$1,000", "2026-02-03"]], types: [.text, .text, .text])
        t.detectAndConvertTextTypes()
        XCTAssertEqual(t.columns.map(\.type), [.integer, .decimal, .date])
        XCTAssertEqual(t[1, 1], .double(1000))
    }
    func testPackageRoundTrip() throws {
        var doc = FacetDocument()
        var table = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal)])
        table.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        doc.model.tables = [table]
        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Amount"], rows: [[1.5], [.null], [.date(Date(timeIntervalSince1970: 86400))]])
        doc.report.pages[0].visuals = [VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 100, height: 80))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).facet")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPackage.write(doc, to: url)
        try DocumentPackage.write(doc, to: url) // overwrite path
        let back = try DocumentPackage.read(from: url)
        XCTAssertEqual(back.model.tables.first?.measures.first?.name, "Total")
        XCTAssertEqual(back.data["Sales"]?.rowCount, 3)
        XCTAssertEqual(back.data["Sales"]?[2, 0], .date(Date(timeIntervalSince1970: 86400)))
        XCTAssertEqual(back.report.pages[0].visuals.first?.type, .card)
    }
}
