import XCTest
import SwiftUI
import FacetCore
@testable import FacetVisuals

/// A forecast that ignores the last points of the series: its line starts at the last point it was
/// fitted to, runs over the ignored points where the actual ones are drawn, and only its future
/// points add categories to the axis.
@MainActor
final class ForecastOverlayTests: XCTestCase {
    /// Six categories A…F with 1…6; the forecast was fitted to A…D and re-forecasts E and F, then one more.
    private func sample() -> (VisualSpec, VisualData, AnalyticsOverlays) {
        var spec = VisualSpec(type: .line, frame: Frame(x: 0, y: 0, width: 480, height: 320))
        let letter = FieldRef.column("Sales", "Letter"), units = FieldRef.measure("Sales", "Units")
        spec.setFields(.category, [letter]); spec.setFields(.values, [units])
        spec.analytics = [AnalyticsItem(kind: .forecast)]
        let table = DataTable(name: "q", columns: [
            DataColumn(name: "Letter", values: ["A", "B", "C", "D", "E", "F"].map(Value.string)),
            DataColumn(name: "Units", type: .decimal, values: [1, 2, 3, 4, 5, 6].map(Value.double)),
        ])
        let data = VisualData(table: table, roles: ["category": [0], "values": [1]], fields: [letter, units], formats: ["", ""])
        var fc = AnalyticsOverlays.Forecast(seriesColumn: 1, labels: [.string("E"), .string("F"), .string("+1")],
                                            values: [4.5, 5.5, 6.5], lower: [4, 5, 6], upper: [5, 6, 7])
        fc.anchorRow = 3
        fc.ignoredRows = [4, 5]
        var overlays = AnalyticsOverlays()
        overlays.forecasts = [fc]
        return (spec, data, overlays)
    }

    func testTheLineStartsAtTheLastFittedPointAndOverlapsTheIgnoredOnes() throws {
        let (spec, data, overlays) = sample()
        let kind = try XCTUnwrap(CartesianKind(.line))
        let style = ChartStyle(spec: spec, theme: .facet)
        let options = CartesianOptions(spec: spec, style: style, kind: kind)
        let model = SeriesModel(spec: spec, data: data)
        let layout = CartesianLayout(model: model, options: options, forecasts: overlays.forecasts)
        // One future category, not three: E and F are already on the axis.
        XCTAssertEqual(layout.forecastLabels, ["+1"])
        XCTAssertEqual(layout.catPos, [0, 1, 2, 3, 4, 5])
        let resolved = CartesianAnalytics(spec: spec, model: model, overlays: overlays, kind: kind)
            .resolve(layout: layout, model: model, colors: ColorResolver(spec: spec, data: data, theme: .facet), style: style, kind: kind)
        let line = try XCTUnwrap(resolved.forecasts.first)
        // From D (4, the last fitted point) over E and F to the new category after F.
        XCTAssertEqual(line.points.map(\.x), [3, 4, 5, 6])
        XCTAssertEqual(line.points.map(\.y), [4, 4.5, 5.5, 6.5])
        XCTAssertEqual(line.points.map(\.lo), [4, 4, 5, 6])
        XCTAssertEqual(line.points.map(\.hi), [4, 5, 6, 7])
    }

    func testWithoutIgnoredPointsTheLineContinuesFromTheLastPoint() throws {
        var (spec, data, overlays) = sample()
        overlays.forecasts[0] = AnalyticsOverlays.Forecast(seriesColumn: 1, labels: [.string("+1"), .string("+2")],
                                                          values: [7, 8], lower: [6, 7], upper: [8, 9])
        spec.analytics = [AnalyticsItem(kind: .forecast)]
        let kind = try XCTUnwrap(CartesianKind(.line))
        let style = ChartStyle(spec: spec, theme: .facet)
        let model = SeriesModel(spec: spec, data: data)
        let layout = CartesianLayout(model: model, options: CartesianOptions(spec: spec, style: style, kind: kind), forecasts: overlays.forecasts)
        XCTAssertEqual(layout.forecastLabels, ["+1", "+2"])
        let line = try XCTUnwrap(CartesianAnalytics(spec: spec, model: model, overlays: overlays, kind: kind)
            .resolve(layout: layout, model: model, colors: ColorResolver(spec: spec, data: data, theme: .facet), style: style, kind: kind)
            .forecasts.first)
        XCTAssertEqual(line.points.map(\.x), [5, 6, 7])
        XCTAssertEqual(line.points.map(\.y), [6, 7, 8])
    }
}
