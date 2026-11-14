import XCTest
import SwiftUI
import FacetCore
@testable import FacetVisuals

/// Ribbon charts: one ribbon per Small multiples value on a shared scale, each band ranked per
/// category, and hover targets where the bands are drawn.
@MainActor
final class RibbonSmallMultiplesTests: XCTestCase {
    private let month = FieldRef.column("Sales", "Month")
    private let product = FieldRef.column("Sales", "Product")
    private let region = FieldRef.column("Sales", "Region")
    private let amount = FieldRef.column("Sales", "Amount", .sum)

    /// | Region | Month | A  | B  | C  |
    /// | North  | Jan   | 30 | 20 | 10 |
    /// | North  | Feb   | 10 | 40 | 20 |
    /// | South  | Jan   |  5 | 15 | 25 |
    /// | South  | Feb   | 50 |  5 |  5 |
    private func sample() -> (VisualSpec, VisualData) {
        var spec = VisualSpec(type: .ribbon, frame: Frame(x: 0, y: 0, width: 480, height: 320))
        spec.setFields(.category, [month]); spec.setFields(.legend, [product])
        spec.setFields(.smallMultiples, [region]); spec.setFields(.values, [amount])
        var regions: [String] = [], months: [String] = [], products: [String] = [], values: [Double] = []
        let cells: [(String, String, [Double])] = [("North", "Jan", [30, 20, 10]), ("North", "Feb", [10, 40, 20]),
                                                   ("South", "Jan", [5, 15, 25]), ("South", "Feb", [50, 5, 5])]
        for (r, m, vs) in cells {
            for (p, v) in zip(["A", "B", "C"], vs) { regions.append(r); months.append(m); products.append(p); values.append(v) }
        }
        let columns = [DataColumn(name: "Month", values: months.map(Value.string)),
                       DataColumn(name: "Product", values: products.map(Value.string)),
                       DataColumn(name: "Region", values: regions.map(Value.string)),
                       DataColumn(name: "Amount", type: .decimal, values: values.map(Value.double))]
        let data = VisualData(table: DataTable(name: "q", columns: columns),
                              roles: ["category": [0], "legend": [1], "smallMultiples": [2], "values": [3]],
                              fields: [month, product, region, amount], formats: ["", "", "", ""])
        return (spec, data)
    }

    private func models(_ data: VisualData, _ spec: VisualSpec) -> [SeriesModel] {
        SeriesModel.partitions(data: data).map {
            SeriesModel(spec: spec, data: data, categoryWell: .category, valueWells: [.values], legendWell: .legend, partition: $0)
        }
    }

    func testEachRegionGetsItsOwnRibbonOnTheTallestStacksScale() {
        let (spec, data) = sample()
        XCTAssertEqual(SeriesModel.partitions(data: data).map(\.title), ["North", "South"])
        let chart = RibbonChart(env: FlowEnv(spec: spec, data: data, context: VisualContext()))
        let parts = models(data, spec)
        // North's stacks are 60 and 70, South's 45 and 60: the shared top is 70.
        XCTAssertEqual(chart.sharedMax(parts), 70)

        let north = chart.layout(parts[0], size: CGSize(width: 200, height: 100), sharedMax: 70)
        // Jan: A 30, B 20, C 10 stack in rank order; Feb: B 40, C 20, A 10.
        XCTAssertEqual(north.bands.map { $0.lo }, [[0, 60], [30, 0], [50, 40]])
        XCTAssertEqual(north.bands.map { $0.hi }, [[30, 70], [50, 40], [60, 60]])
        XCTAssertEqual(north.bands.map { $0.rank }, [[1, 3], [2, 1], [3, 2]])

        let south = chart.layout(parts[1], size: CGSize(width: 200, height: 100), sharedMax: 70)
        // Jan: C 25, B 15, A 5; Feb: A 50, then B and C tie at 5 and keep series order.
        XCTAssertEqual(south.bands.map { $0.rank }, [[3, 1], [2, 2], [1, 3]])
        XCTAssertEqual(south.maxTotal, 70)
        XCTAssertEqual(south.totals, [45, 60])
        // Without the shared axis each panel is scaled to its own tallest stack.
        XCTAssertEqual(chart.layout(parts[1], size: CGSize(width: 200, height: 100)).maxTotal, 60)
    }

    func testTooltipsGiveTheRankInTheirCategoryAndHitWhereTheBandIsDrawn() throws {
        let (spec, data) = sample()
        let chart = RibbonChart(env: FlowEnv(spec: spec, data: data, context: VisualContext()))
        let north = models(data, spec)[0]
        let size = CGSize(width: 200, height: 100)
        let layout = chart.layout(north, size: size, sharedMax: 70)
        let hits = chart.bandHits(layout, north, size: size)
        XCTAssertEqual(hits.count, 6)
        func rank(_ i: Int) -> String? { hits[i].tooltip.rows.first { $0.label == "Rank" }?.value }
        // Hits run category by category, A, B, C within each.
        XCTAssertEqual((0..<6).map(rank), ["1 of 3", "2 of 3", "3 of 3", "3 of 3", "1 of 3", "2 of 3"])

        // The plot is 100 points tall less 6 at the top and bottom: 0 sits at y 94 and 70 at y 6.
        // Jan's A band, 0…30, runs from y 94 up to 94 − 30/70 × 88 ≈ 56.29, across the first slice (x 6…100).
        let janA = hits[0].path.boundingRect
        XCTAssertEqual(janA.minX, 6, accuracy: 1e-9)
        XCTAssertEqual(janA.maxX, 100, accuracy: 1e-9)
        XCTAssertEqual(janA.minY, 94 - 30.0 / 70 * 88, accuracy: 1e-9)
        XCTAssertEqual(janA.maxY, 94, accuracy: 1e-9)
        XCTAssertTrue(hits[0].path.contains(CGPoint(x: 50, y: 80)))
        // Feb's B band, 0…40, is the bottom of the second slice.
        XCTAssertTrue(hits[4].path.contains(CGPoint(x: 150, y: 80)))
        XCTAssertFalse(hits[3].path.contains(CGPoint(x: 150, y: 80)))
        XCTAssertEqual(hits[0].selection?.values, [.string("Jan"), .string("A"), .string("North")])
    }

    func testTheFormatPaneOffersTheSmallMultiplesCard() {
        let keys = FlowCharts.formatProperties(for: .ribbon).filter { $0.card == "smallMultiples" }.map(\.key)
        XCTAssertEqual(keys, ["sharedYAxis", "columns", "rows", "padding"])
        XCTAssertTrue(VisualType.ribbon.wells.contains(.smallMultiples))
    }
}
