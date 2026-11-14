import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Titles from a measure (the Title target of conditional formatting, by field value).
@MainActor
final class DynamicTitleTests: XCTestCase {
    private typealias F = ReportFixture

    private func titled(by field: FieldRef) -> VisualSpec {
        var chart = F.chart()
        var rule = ConditionalFormat(target: .title)
        rule.mode = .fieldValue
        rule.basedOn = field
        chart.conditionalFormats = [rule]
        return chart
    }

    func testTheMeasureSuppliesTheTitleUnderTheVisualsFilters() {
        let chart = titled(by: F.destination)
        let engine = F.engine()
        // All sales: 150 > 100, so "Details".
        XCTAssertEqual(engine.visualData(spec: chart, request: VisualRequest()).dynamicTitle, "Details")
        // North only: 10 + 20 = 30, so "Nowhere".
        var north = FilterSpec(field: F.region); north.values = [.string("North")]
        var request = VisualRequest(); request.filters = [north]
        XCTAssertEqual(engine.visualData(spec: chart, request: request).dynamicTitle, "Nowhere")
    }

    func testANumberTitleAndNoRuleAtAll() {
        XCTAssertEqual(F.engine().visualData(spec: titled(by: F.amount), request: VisualRequest()).dynamicTitle, "150")
        XCTAssertNil(F.engine().visualData(spec: F.chart(), request: VisualRequest()).dynamicTitle)
        var gradient = titled(by: F.total)
        gradient.conditionalFormats[0].mode = .gradient
        XCTAssertNil(DynamicTitles.source(gradient), "only a field value supplies text")
    }

    func testABlankOrFailingValueFallsBackToTheStaticTitle() {
        let chart = titled(by: F.total)
        XCTAssertNil(DynamicTitles.text(for: chart, filters: [], model: F.model()) { _ in nil })
        XCTAssertNil(DynamicTitles.text(for: chart, filters: [], model: F.model()) { _ in
            DataTable(name: "q", columnNames: ["__title"], rows: [[.null]], types: [.text])
        })
        struct Failure: Error {}
        XCTAssertNil(DynamicTitles.text(for: chart, filters: [], model: F.model()) { _ in throw Failure() })
    }
}
