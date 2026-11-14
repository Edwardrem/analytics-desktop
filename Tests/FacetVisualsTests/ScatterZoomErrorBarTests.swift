import XCTest
import SwiftUI
import FacetCore
@testable import FacetVisuals

/// A scatter chart's error bars (Analytics pane) and its X and Y zoom sliders (format pane).
@MainActor
final class ScatterZoomErrorBarTests: XCTestCase {
    private func point(_ x: Double, _ y: Double, id: Int = 0) -> ScatterModel.Point {
        ScatterModel.Point(id: id, x: x, y: y, size: nil, series: 0, label: "", selection: DataPointSelection(fields: [], values: []),
                           row: id, frame: nil)
    }

    private func errorBars(_ percent: Double, axis: AnalyticsItem.ErrorAxis?) -> AnalyticsItem {
        var item = AnalyticsItem(kind: .errorBars)
        item.secondaryValue = percent
        item.errorAxis = axis
        return item
    }

    func testErrorBarsRunAlongTheChosenAxisByAPercentageOfTheValue() {
        let p = point(10, 20)
        // ± 10 %: X 10 ± 1, Y 20 ± 2. Unset is the Y axis, as Power BI starts them.
        let unset = ScatterAnalytics.errorBars(p, item: errorBars(10, axis: nil))
        XCTAssertNil(unset.x)
        XCTAssertEqual(unset.y, 18...22)
        let x = ScatterAnalytics.errorBars(p, item: errorBars(10, axis: .x))
        XCTAssertEqual(x.x, 9...11)
        XCTAssertNil(x.y)
        let both = ScatterAnalytics.errorBars(p, item: errorBars(10, axis: .both))
        XCTAssertEqual(both.x, 9...11)
        XCTAssertEqual(both.y, 18...22)
        // Negative values: the bar is ± 10 % of the size of the value, so −20 runs −22…−18.
        XCTAssertEqual(ScatterAnalytics.errorBars(point(-10, -20), item: errorBars(10, axis: nil)).y, -22 ... -18)
        // A document can hold any number: 5000 % is clamped to 1000 %, so 20 runs 20 ± 200.
        XCTAssertEqual(ScatterAnalytics.errorBars(p, item: errorBars(5000, axis: nil)).y, -180...220)
    }

    func testTheAxesReachTheEndsOfTheErrorBars() {
        let points = [point(10, 20, id: 0), point(0, -5, id: 1)]
        // ± 10 % on Y: 20 → 18…22, −5 → −5.5…−4.5; X keeps the points alone.
        let reach = ScatterAnalytics.extents(points, errorBars: errorBars(10, axis: nil))
        XCTAssertEqual(reach.x.min(), 0)
        XCTAssertEqual(reach.x.max(), 10)
        XCTAssertEqual(reach.y.min(), -5.5)
        XCTAssertEqual(reach.y.max(), 22)
        let none = ScatterAnalytics.extents(points, errorBars: nil)
        XCTAssertEqual(none.y.min(), -5)
        XCTAssertEqual(none.y.max(), 20)
    }

    func testAZoomSliderShowsItsFractionOfTheAxis() {
        XCTAssertEqual(StatZoom.window(0...100, 0.25...0.5), 25...50)
        XCTAssertEqual(StatZoom.window(-10...10, 0.5...1), 0...10)
        XCTAssertEqual(StatZoom.window(0...100, nil), 0...100, "no slider, the whole axis")
        XCTAssertEqual(StatZoom.window(0...100, 0...1), 0...100, "a slider at its full span")
        XCTAssertEqual(StatZoom.window(0...100, -0.5...0.5), 0...50, "fractions are kept to 0…1")
        // A zoomed axis keeps exactly the window and ticks it at round numbers: 25…50 in steps of 5.
        let scale = StatZoom.scale(25...50, targetTicks: 5)
        XCTAssertEqual(scale.lower, 25)
        XCTAssertEqual(scale.upper, 50)
        XCTAssertEqual(scale.ticks, [25, 30, 35, 40, 45, 50])
    }

    func testTheZoomSliderCardTurnsOnBothSlidersTogether() {
        var spec = VisualSpec(type: .scatter, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        func sliders() -> (x: Bool, y: Bool) { ScatterAnalytics.zoomSliders(ChartStyle(spec: spec, theme: .facet).format) }
        XCTAssertFalse(sliders().x || sliders().y, "off until the card turns them on")
        spec.format["zoomSlider"] = ["show": .bool(true)]
        XCTAssertTrue(sliders().x && sliders().y)
        spec.format["zoomSlider"]?["yAxis"] = .bool(false)
        XCTAssertTrue(sliders().x)
        XCTAssertFalse(sliders().y)
        let keys = ChartFormatCatalog.properties(for: .scatter).filter { $0.card == "zoomSlider" }.map(\.key)
        XCTAssertEqual(keys, ["show", "xAxis", "yAxis"])
    }

    func testAScatterChartWithErrorBarsAndZoomSlidersRenders() throws {
        var spec = VisualSpec(type: .scatter, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        let x = FieldRef.measure("S", "X"), y = FieldRef.measure("S", "Y"), name = FieldRef.column("S", "Name")
        spec.setFields(.details, [name]); spec.setFields(.x, [x]); spec.setFields(.y, [y])
        spec.analytics = [errorBars(10, axis: .both)]
        spec.format["zoomSlider"] = ["show": .bool(true)]
        let table = DataTable(name: "q", columns: [
            DataColumn(name: "Name", values: ["A", "B", "C"].map(Value.string)),
            DataColumn(name: "X", type: .decimal, values: [1, 2, 3].map(Value.double)),
            DataColumn(name: "Y", type: .decimal, values: [4, 5, 6].map(Value.double)),
        ])
        let data = VisualData(table: table, roles: ["details": [0], "x": [1], "y": [2]], fields: [name, x, y], formats: ["", "", ""])
        let png = ChartRendering.renderPNG(spec: spec, data: data, context: VisualContext(), size: CGSize(width: 400, height: 300))
        XCTAssertNotNil(png)
    }
}
