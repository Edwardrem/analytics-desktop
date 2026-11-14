import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Text boxes with `{{Measure}}` and `{{=DAX}}` placeholders: evaluated in the page's filter context,
/// one column per placeholder named as the text box renderer looks it up.
///
/// Over `ReportFixture`: all regions Amount 150; North 30; Web channel 10 + 30 + 40 = 80.
@MainActor
final class TextBoxValuesTests: XCTestCase {
    private func textBox(_ content: String) -> VisualSpec {
        var v = VisualSpec(type: .textBox, frame: Frame(x: 0, y: 0, width: 300, height: 80))
        v.content = content
        return v
    }

    private func value(_ data: VisualData, _ column: String) -> Double? {
        data.table.columnIndex(column).flatMap { data.table.rowCount == 1 ? data.table[0, $0].asDouble : nil }
    }

    func testMeasuresAndExpressionsResolveWithoutFilters() {
        let data = ReportFixture.engine().visualData(spec: textBox("Sales {{Total}}, doubled {{=SUM(Sales[Amount]) * 2}}"),
                                                    request: VisualRequest())
        XCTAssertEqual(data.table.columnNames, ["Total", "=SUM(Sales[Amount]) * 2"])
        XCTAssertEqual(value(data, "Total"), 150)
        XCTAssertEqual(value(data, "=SUM(Sales[Amount]) * 2"), 300)
    }

    func testPlaceholdersFollowThePageFilters() {
        var request = VisualRequest()
        var north = FilterSpec(field: ReportFixture.region)
        north.values = [.string("North")]
        request.filters = [north]
        let data = ReportFixture.engine().visualData(spec: textBox("{{total}} / {{=COUNTROWS(Sales)}}"), request: request)
        // Measure names match case-insensitively; the column keeps the name as written.
        XCTAssertEqual(value(data, "total"), 30)
        XCTAssertEqual(value(data, "=COUNTROWS(Sales)"), 2)
    }

    func testSlicersAndSelectionsFilterTheTextBox() {
        var request = VisualRequest()
        var state = SlicerState()
        state.selected = [.string("Web")]
        request.slicers = [.init(fields: [ReportFixture.channel], state: state, type: .slicer)]
        XCTAssertEqual(value(ReportFixture.engine().visualData(spec: textBox("{{Total}}"), request: request), "Total"), 80)

        // A cross-highlight from a chart filters a text box (it has no points to highlight).
        var selected = VisualRequest()
        selected.highlights = [[ReportFixture.point(ReportFixture.region, "South")]]
        XCTAssertEqual(value(ReportFixture.engine().visualData(spec: textBox("{{Total}}"), request: selected), "Total"), 70)
    }

    func testUnknownNamesAndBrokenExpressionsStayUnresolved() {
        let data = ReportFixture.engine().visualData(spec: textBox("{{Nope}} {{=SUM(Sales[Missing])}} {{Total}}"),
                                                    request: VisualRequest())
        XCTAssertEqual(data.table.columnNames, ["Total"])
        XCTAssertEqual(value(data, "Total"), 150)
        XCTAssertTrue(ReportFixture.engine().visualData(spec: textBox("Plain text"), request: VisualRequest()).table.columns.isEmpty)
    }

    func testTheDocumentQueriesTextBoxesOnThePage() async throws {
        let store = ReportFixture.store()
        var box = textBox("{{Total}}")
        box.name = "Headline"
        store.mutate("Add", invalidates: .model) { $0.report.pages[0].visuals = [box] }
        for _ in 0..<200 where store.visualData[box.id] == nil || store.calculation.data["Sales"] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let data = try XCTUnwrap(store.visualData[box.id])
        XCTAssertEqual(value(data, "Total"), 150)
    }
}
