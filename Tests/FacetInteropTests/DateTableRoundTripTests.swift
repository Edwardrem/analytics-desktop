import XCTest
import FacetCore
@testable import FacetInterop

/// "Mark as date table" travels with the table: dataCategory "Time" plus the chosen column (a Facet annotation, as in
/// TMDL). Only a marked table reads back as a date table, and with the column the author chose.
final class DateTableRoundTripTests: XCTestCase {
    private func model() -> SemanticModel {
        var m = SemanticModel()
        var calendar = ModelTable(name: "Calendar")
        // The marked column is the second temporal column, so a reader that guesses the first one gets it wrong.
        calendar.columns = [ModelColumn(name: "Week Start", dataType: .date), ModelColumn(name: "Date", dataType: .date),
                            ModelColumn(name: "Year", dataType: .integer)]
        calendar.dateColumn = "Date"
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Order Date", dataType: .date), ModelColumn(name: "Amount", dataType: .decimal)]
        m.tables = [calendar, sales]
        return m
    }

    func testModelBimKeepsTheMarkedDateTableAndNoOther() {
        let bim = TMSLWriter.document(model: model(), queries: [])
        let tables = bim["model"]?["tables"]?.arrayValue ?? []
        let calendar = tables.first { $0["name"]?.stringValue == "Calendar" }
        XCTAssertEqual(calendar?["dataCategory"]?.stringValue, "Time")
        XCTAssertEqual(calendar.flatMap { TMSLConverter.facet($0, "dateColumn")?.stringValue }, "Date")
        let sales = tables.first { $0["name"]?.stringValue == "Sales" }
        XCTAssertNil(sales?["dataCategory"])

        let (read, _, _) = TMSLConverter.convert(bim)
        XCTAssertEqual(read.table("Calendar")?.dateColumn, "Date")
        XCTAssertNil(read.table("Sales")?.dateColumn, "a table with a date column is not a date table unless it is marked")
    }

    func testTMDLKeepsTheMarkedDateColumn() throws {
        let back = try TMDL.parseDetailed(files: TMDL.serialize(model: model()))
        XCTAssertEqual(back.model.table("Calendar")?.dateColumn, "Date")
        XCTAssertNil(back.model.table("Sales")?.dateColumn)
    }
}
