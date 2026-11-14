import XCTest
import SwiftUI
import FacetCore
@testable import FacetVisuals

/// An anomaly marker knows the data point it marks and the overlay entry it came from, so a click
/// on it can open that anomaly's explanations.
@MainActor
final class AnomalyMarkerTests: XCTestCase {
    func testTheMarkerSitsOnItsPointAndCarriesItsAnomaly() throws {
        var spec = VisualSpec(type: .line, frame: Frame(x: 0, y: 0, width: 480, height: 320))
        let letter = FieldRef.column("Sales", "Letter"), units = FieldRef.measure("Sales", "Units")
        spec.setFields(.category, [letter]); spec.setFields(.values, [units])
        spec.analytics = [AnalyticsItem(kind: .anomalies)]
        // The result comes back C, A, B; the axis keeps that order, so row 0 (C) is category 0.
        let table = DataTable(name: "q", columns: [
            DataColumn(name: "Letter", values: ["C", "A", "B"].map(Value.string)),
            DataColumn(name: "Units", type: .decimal, values: [9, 1, 2].map(Value.double)),
        ])
        let data = VisualData(table: table, roles: ["category": [0], "values": [1]], fields: [letter, units], formats: ["", ""])
        var overlays = AnalyticsOverlays()
        overlays.anomalies = [AnalyticsOverlays.Anomaly(seriesColumn: 1, row: 0, expected: 1.5, lower: 1, upper: 2, explanation: "")]
        let kind = try XCTUnwrap(CartesianKind(.line))
        let style = ChartStyle(spec: spec, theme: .facet)
        let model = SeriesModel(spec: spec, data: data)
        let layout = CartesianLayout(model: model, options: CartesianOptions(spec: spec, style: style, kind: kind), forecasts: [])
        let marker = try XCTUnwrap(CartesianAnalytics(spec: spec, model: model, overlays: overlays, kind: kind)
            .resolve(layout: layout, model: model, colors: ColorResolver(spec: spec, data: data, theme: .facet), style: style, kind: kind)
            .anomalies.first)
        XCTAssertEqual(marker.cat, 0)
        XCTAssertEqual(marker.series, 0)
        XCTAssertEqual(marker.value, 9)
        XCTAssertEqual(marker.x, 0)
        XCTAssertEqual(marker.source.row, 0)
        XCTAssertEqual(marker.source.expected, 1.5)
    }

    func testAMarkerWithAnActivationRunsItInsteadOfSelecting() {
        var ran = 0
        var hit = ChartHit(id: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10), selection: nil, tooltip: TooltipContent())
        XCTAssertNil(hit.activate)
        hit.activate = { ran += 1 }
        hit.activate?()
        XCTAssertEqual(ran, 1)
    }
}
