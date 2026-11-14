import XCTest
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Fields in a visual's Tooltips well: queried with their summarization at the grain of the
/// visual, and listed in the default tooltip of each data point.
///
/// Over `ReportFixture` (Region / Product / Channel / Amount):
/// - North: Amount 10 + 20 = 30, channels Web and Store → First of Channel "Store" (first in sort order)
/// - South: 30 + 40 = 70, channels Web, Web → "Web"
/// - East: 50, Store → "Store"
@MainActor
final class TooltipFieldsTests: XCTestCase {
    private func chart() -> VisualSpec {
        var v = ReportFixture.chart()
        v.setFields(.tooltips, [ReportFixture.channel, ReportFixture.total])
        return v
    }

    private func row(_ data: VisualData, _ region: String) throws -> Int {
        try XCTUnwrap((0..<data.table.rowCount).first { data.table[$0, 0] == .string(region) }, "no row for \(region)")
    }

    func testTooltipFieldsAreQueriedAsValuesOfEachPoint() throws {
        let data = ReportFixture.engine().visualData(spec: chart(), request: VisualRequest())
        XCTAssertNil(data.error)
        // The text field summarizes; it does not split the regions into region × channel rows.
        XCTAssertEqual(data.table.rowCount, 3)
        XCTAssertEqual(data.indices(.category), [0])
        XCTAssertEqual(data.indices(.values), [1])
        XCTAssertEqual(data.indices(.tooltips), [2, 3])
        XCTAssertEqual(data.fields[2]?.aggregation, .first)
        XCTAssertEqual(data.fields[2]?.caption, "First of Channel")

        let expected: [(String, Double, String)] = [("North", 30, "Store"), ("South", 70, "Web"), ("East", 50, "Store")]
        for (region, amount, channel) in expected {
            let r = try row(data, region)
            XCTAssertEqual(data.table[r, 1].asDouble, amount, region)
            XCTAssertEqual(data.table[r, 2], .string(channel), region)
            XCTAssertEqual(data.table[r, 3].asDouble, amount, region)
        }
    }

    func testDefaultTooltipListsTheTooltipFields() throws {
        let data = ReportFixture.engine().visualData(spec: chart(), request: VisualRequest())
        let r = try row(data, "North")
        let rows = SeriesModel.tooltipFields(data: data, row: r)
        XCTAssertEqual(rows.map(\.label), ["First of Channel", "Total"])
        XCTAssertEqual(rows.map(\.value), ["Store", "30"])
    }

    func testTooltipsFollowTheFilters() throws {
        var request = VisualRequest()
        var web = FilterSpec(field: ReportFixture.channel)
        web.values = [.string("Web")]
        request.filters = [web]
        let data = ReportFixture.engine().visualData(spec: chart(), request: request)
        // Only Web rows remain: North 10 (Web), South 70 (Web); East has no Web sales.
        XCTAssertEqual(data.table.rowCount, 2)
        let north = try row(data, "North")
        XCTAssertEqual(data.table[north, 2], .string("Web"))
        XCTAssertEqual(data.table[north, 3].asDouble, 10)
    }

    func testUnsummarizedTooltipColumnsTakeTheWellDefault() {
        var model = ReportFixture.model()
        model.tables[0].columns.append(ModelColumn(name: "Day", dataType: .date))
        XCTAssertEqual(LiveCalculation.tooltipValue(.column("Sales", "Channel"), model: model).aggregation, .first)
        XCTAssertEqual(LiveCalculation.tooltipValue(.column("Sales", "Day"), model: model).aggregation, .min)
        // Numbers keep "none": the query sums them, as it does for any implicit measure.
        XCTAssertEqual(LiveCalculation.tooltipValue(.column("Sales", "Amount"), model: model).aggregation, .none)
        XCTAssertEqual(LiveCalculation.tooltipValue(.column("Sales", "Channel", .count), model: model).aggregation, .count)
        XCTAssertEqual(LiveCalculation.tooltipValue(ReportFixture.total, model: model), ReportFixture.total)
    }
}
