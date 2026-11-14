import XCTest
import FacetCore
@testable import FacetVisuals

/// High-density sampling on scatter charts: one point per occupied grid cell (per series), the
/// extremes and the selected points, instead of the first 4,000 rows.
final class ScatterSamplingTests: XCTestCase {
    /// A 100 × 100 lattice, x = 0...99 and y = 0...99, in x-major order (x = 0 first).
    private func lattice(series: (Int, Int) -> Int = { _, _ in 0 }) -> [ScatterModel.Point] {
        var out: [ScatterModel.Point] = []
        for x in 0..<100 {
            for y in 0..<100 {
                out.append(ScatterModel.Point(id: out.count, x: Double(x), y: Double(y), size: nil, series: series(x, y),
                                              label: "\(x),\(y)",
                                              selection: DataPointSelection(fields: [.column("T", "P")], values: [.string("\(x),\(y)")]),
                                              row: out.count, frame: nil))
            }
        }
        return out
    }

    private func has(_ points: [ScatterModel.Point], _ x: Double, _ y: Double) -> Bool {
        points.contains { $0.x == x && $0.y == y }
    }

    func testUpToTheLimitEveryPointIsDrawn() {
        let points = Array(lattice().prefix(4_000))
        XCTAssertEqual(ScatterSampling.sample(points).map(\.id), points.map(\.id))
    }

    func testTheGridCoarsensUntilTheCellsFitAndKeepsTheExtremes() {
        // 126 cells a side gives 100 × 100 occupied cells; 94 gives 94² = 8,836; 70 gives 4,900;
        // 52 gives 52² = 2,704, under 4,000. Each cell keeps its first point in row order.
        // The first point at the largest x, (99, 0), shares a cell with (98, 0), which comes first,
        // and the first at the largest y, (0, 99), shares one with (0, 98): both are added.
        let sampled = ScatterSampling.sample(lattice())
        XCTAssertEqual(sampled.count, 2_706)
        XCTAssertTrue(has(sampled, 0, 0))
        XCTAssertTrue(has(sampled, 99, 0))
        XCTAssertTrue(has(sampled, 0, 99))
        XCTAssertTrue(has(sampled, 98, 98))
        XCTAssertFalse(has(sampled, 99, 99))
        // The points keep their order, so the drawing order is the data's.
        XCTAssertEqual(sampled.map(\.id), sampled.map(\.id).sorted())
    }

    func testSelectedPointsAreAlwaysDrawn() {
        // (51, 51) shares its cell with (50, 50), which comes first; keeping it adds one point.
        let sampled = ScatterSampling.sample(lattice()) { $0.x == 51 && $0.y == 51 }
        XCTAssertEqual(sampled.count, 2_707)
        XCTAssertTrue(has(sampled, 51, 51))
        XCTAssertTrue(has(sampled, 50, 50))
    }

    func testEachSeriesKeepsItsOwnPointInACell() {
        // Alternating series: at 52 a side 2,704 cells hold both series except the 16 cells of a
        // single point, 5,392 in all, too many; at 39 a side every cell holds 2 × 2 points or more,
        // so both series: 39² × 2 = 3,042. (99, 0) and (0, 99) are series 1 and come after (97, 0)
        // and (0, 97) in their cells: 3,044.
        let sampled = ScatterSampling.sample(lattice { x, y in (x + y) % 2 })
        XCTAssertEqual(sampled.count, 3_044)
        XCTAssertEqual(sampled.filter { $0.series == 0 }.count, 1_521)
        XCTAssertTrue(has(sampled, 97, 0))
        XCTAssertTrue(has(sampled, 97, 1))
    }

    func testIdenticalPointsCollapseToOne() {
        let same = (0..<5_000).map { i in
            ScatterModel.Point(id: i, x: 3, y: 4, size: nil, series: 0, label: "", selection: DataPointSelection(fields: [], values: []),
                               row: i, frame: nil)
        }
        XCTAssertEqual(ScatterSampling.sample(same).map(\.id), [0])
        XCTAssertEqual(ScatterSampling.slot(99, 0, 99, 52), 51)
        XCTAssertEqual(ScatterSampling.slot(98, 0, 99, 52), 51)
        XCTAssertEqual(ScatterSampling.slot(97, 0, 99, 52), 50)
    }

    func testTheNoteSaysHowManyAreShown() {
        XCTAssertEqual(ScatterSampling.note(shown: 2_706, of: 10_000),
                       "Showing \(2_706.formatted()) of \(10_000.formatted()) points")
    }
}
