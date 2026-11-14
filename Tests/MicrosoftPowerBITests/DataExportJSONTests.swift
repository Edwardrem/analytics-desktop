import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Export data ▸ JSON: an array of row objects with typed values.
@MainActor
final class DataExportJSONTests: XCTestCase {
    private func day(_ s: String) throws -> Value { .date(try XCTUnwrap(DateParsing.parse(s), s)) }

    private func table() throws -> DataTable {
        DataTable(name: "Export", columnNames: ["Region", "Amount", "Share", "Open", "Day", "Note"], rows: [
            [.string("North"), .int(30), .double(0.25), .bool(true), try day("2024-03-01"), .string("Says \"hi\"\n\\ok")],
            [.string("Søuth"), .null, .double(.nan), .bool(false), try day("2024-03-01 10:30:00"), .string("tab\there")],
        ], types: [.text, .integer, .decimal, .boolean, .dateTime, .text])
    }

    func testRowsBecomeObjectsInColumnOrder() throws {
        let text = String(decoding: DataExporters.json(try table()), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "[")
        XCTAssertEqual(lines[1], #"  {"Region": "North", "Amount": 30, "Share": 0.25, "Open": true, "Day": "2024-03-01", "Note": "Says \"hi\"\n\\ok"},"#)
        XCTAssertEqual(lines[2], #"  {"Region": "Søuth", "Amount": null, "Share": null, "Open": false, "Day": "2024-03-01T10:30:00", "Note": "tab\there"}"#)
        XCTAssertEqual(lines[3], "]")
    }

    func testOutputIsValidJSON() throws {
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: DataExporters.json(try table())) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0]["Note"] as? String, "Says \"hi\"\n\\ok")
        XCTAssertEqual(parsed[0]["Amount"] as? Int, 30)
        XCTAssertTrue(parsed[1]["Amount"] is NSNull)
        XCTAssertEqual(String(decoding: DataExporters.json(DataTable(name: "Empty", columns: [])), as: UTF8.self), "[]\n")
        XCTAssertEqual(DataExporters.jsonString("\u{01}"), #""\u0001""#)
    }

    func testRepeatedColumnNamesStayDistinct() throws {
        let t = DataTable(name: "T", columnNames: ["Total", "Total"], rows: [[.int(1), .int(2)]], types: [.integer, .integer])
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: DataExporters.json(t)) as? [[String: Int]])
        XCTAssertEqual(parsed, [["Total": 1, "Total 2": 2]])
    }

    func testJSONIsRegisteredAndWritesCaptions() throws {
        DataExporters.register()
        let exporter = try XCTUnwrap(VisualExport.dataExporters["json"])
        let data = ReportFixture.engine().visualData(spec: ReportFixture.chart(), request: VisualRequest())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try VisualExport.write(data, with: exporter, to: url), 3)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let north = try XCTUnwrap(rows.first { $0["Region"] as? String == "North" })
        XCTAssertEqual(north["Sum of Amount"] as? Int, 30)
    }
}
