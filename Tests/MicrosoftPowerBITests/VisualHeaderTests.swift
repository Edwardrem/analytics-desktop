import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Visual header options authors set: whether readers see the header, and its help (information) tooltip.
@MainActor
final class VisualHeaderTests: XCTestCase {
    func testHelpTextIsTheAuthorsTrimmedText() {
        var chart = ReportFixture.chart()
        XCTAssertNil(VisualHeaderOptions.helpText(chart))
        chart.setFmt("visualHeader", "helpText", .string("   "))
        XCTAssertNil(VisualHeaderOptions.helpText(chart), "blank text shows no icon")
        chart.setFmt("visualHeader", "helpText", .string("  Sales by region, before returns. "))
        XCTAssertEqual(VisualHeaderOptions.helpText(chart), "Sales by region, before returns.")
    }

    func testReadersSeeTheHeaderUnlessTheReportOrTheVisualHidesIt() {
        var chart = ReportFixture.chart()
        var settings = ReportSettings()
        XCTAssertTrue(VisualHeaderOptions.showsToReaders(chart, settings: settings))
        chart.setFmt("visualHeader", "show", .bool(false))
        XCTAssertFalse(VisualHeaderOptions.showsToReaders(chart, settings: settings))
        chart.setFmt("visualHeader", "show", nil)
        settings.hideVisualHeaders = true
        XCTAssertFalse(VisualHeaderOptions.showsToReaders(chart, settings: settings))
        let shape = VisualSpec(type: .shape, frame: chart.frame)
        XCTAssertFalse(VisualHeaderOptions.showsToReaders(shape, settings: ReportSettings()), "page elements have no header")
    }

    func testTheFormatPaneOffersHeaderIconsForDataVisualsOnly() throws {
        let card = try XCTUnwrap(FormatCatalog.generalCards(for: .clusteredColumn).first { $0.card == "visualHeader" })
        XCTAssertEqual(card.properties.map(\.key), ["show", "helpText"])
        XCTAssertEqual(card.properties.first?.defaultValue, .bool(true))
        XCTAssertNil(FormatCatalog.generalCards(for: .textBox).first { $0.card == "visualHeader" })
    }
}
