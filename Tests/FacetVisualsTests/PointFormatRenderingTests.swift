import XCTest
import FacetCore
@testable import FacetVisuals

/// Charts label a data point in its own format when its measure's dynamic format string gives
/// points different formats: East 400 is "0", West 800 is "#,0.00"; the visual's own is "#,0.00".
@MainActor
final class PointFormatRenderingTests: XCTestCase {
    private func sample() -> (VisualSpec, VisualData) {
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        let region = FieldRef.column("Sales", "Region"), total = FieldRef.measure("Sales", "Total")
        spec.setFields(.category, [region]); spec.setFields(.values, [total])
        let table = DataTable(name: "q", columns: [
            DataColumn(name: "Region", values: ["East", "West"].map(Value.string)),
            DataColumn(name: "Total", type: .decimal, values: [400, 800].map(Value.double)),
        ])
        var data = VisualData(table: table, roles: ["category": [0], "values": [1]], fields: [region, total], formats: ["", "#,0.00"])
        data.pointFormats = [1: ["0", "#,0.00"]]
        return (spec, data)
    }

    func testAPointIsFormattedWithItsOwnFormat() {
        let (spec, data) = sample()
        let model = SeriesModel(spec: spec, data: data)
        XCTAssertEqual(model.formatted(400, series: 0, category: 0), "400")
        XCTAssertEqual(model.formatted(800, series: 0, category: 1), "800.00")
        XCTAssertEqual(model.formatted(400, series: 0), "400.00", "without a point, the visual's format (axis, totals)")
        XCTAssertEqual(data.formatted(row: 0, col: 1), "400")
        XCTAssertEqual(data.format(row: 0, col: 0), "", "columns without point formats use their own")
        // A row past the point formats falls back to the visual's format.
        XCTAssertEqual(data.format(row: 5, col: 1), "#,0.00")
    }
}
