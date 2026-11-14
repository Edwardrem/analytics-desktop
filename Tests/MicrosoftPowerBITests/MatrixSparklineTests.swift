import XCTest
import FacetCore
@testable import FacetVisuals
@testable import MicrosoftPowerBI

/// Sparklines in a matrix: every detail row carries its series at each point of the shared axis,
/// and subtotal and total cells combine the rows under them point by point.
@MainActor
final class MatrixSparklineTests: XCTestCase {
    private typealias F = ReportFixture

    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    /// Region on rows, Channel on columns, Total, and Total along Product as a sparkline.
    private func matrix(subtotal: String? = nil) -> VisualSpec {
        var v = VisualSpec(type: .matrix, frame: Frame(x: 0, y: 0, width: 400, height: 240), name: "Matrix")
        v.setFields(.rows, [F.region]); v.setFields(.columns, [F.channel]); v.setFields(.values, [F.total])
        Sparklines.set(Sparkline(name: "Total by Product", value: F.total, axis: F.product), on: &v)
        if let subtotal { v.setFmt("totals", "Total by Product", .string(subtotal)) }
        return v
    }

    func testSeriesSitAtEveryPointOfTheSharedAxis() {
        // Row key, axis (month name), sort column (month number), value.
        let t = DataTable(name: "q", columnNames: ["Region", "Month", "MonthNo", "v"], rows: [
            [.string("North"), .string("Mar"), .int(3), .int(7)],
            [.string("North"), .string("Jan"), .int(1), .int(5)],
            [.string("North"), .string("Feb"), .int(2), .null],
            [.string("South"), .string("Feb"), .int(2), .int(9)],
        ], types: [.text, .text, .integer, .integer])
        // January, February (only South has a value), March.
        let aligned = Sparklines.alignedSeries(t, keys: 1, axis: 1, sort: 2, value: 3)
        XCTAssertEqual(aligned[[.string("North")]], [5, nil, 7])
        XCTAssertEqual(aligned[[.string("South")]], [nil, 9, nil])

        XCTAssertEqual(MatrixSparkline.encode([5, nil, 7]), .string("5.0||7.0"))
        XCTAssertEqual(MatrixSparkline.decode(.string("5.0||7.0")), [5, nil, 7])
        XCTAssertNil(MatrixSparkline.decode(.string("5|x")))
        XCTAssertNil(MatrixSparkline.decode(.string("")))

        let rows: [[Double?]] = [[10, nil], [30, 40], [50, nil]]
        XCTAssertEqual(MatrixSparkline.combine(rows, .sum), [90, 40])
        XCTAssertEqual(MatrixSparkline.combine(rows, .average), [30, 40])
        XCTAssertEqual(MatrixSparkline.combine(rows, .max), [50, 40])
        XCTAssertEqual(MatrixSparkline.combine(rows, .count), [3, 1])
        XCTAssertEqual(MatrixSparkline.combine(rows, .none), [])
    }

    func testTheMatrixQueryCarriesEachCellsSeries() throws {
        let data = F.engine().visualData(spec: matrix(), request: VisualRequest())
        XCTAssertNil(data.error)
        let column = try XCTUnwrap(data.table.columnIndex("Total by Product"))
        XCTAssertTrue(data.indices(.values).contains(column))
        var cells: [String: String] = [:]
        for r in 0..<data.table.rowCount {
            cells["\(data.table[r, 0].asString) \(data.table[r, 1].asString)"] = data.table[r, column].asString
        }
        // Products are Apple, then Pear. North Web: Apple 10. North Store: Pear 20.
        // South Web: Apple 30, Pear 40. East Store: Apple 50.
        XCTAssertEqual(cells, ["North Web": "10.0|", "North Store": "|20.0", "South Web": "30.0|40.0", "East Store": "50.0|"])
    }

    func testSubtotalsAndTotalsCombineTheRowsUnderThem() throws {
        let spec = matrix()
        let data = F.engine().visualData(spec: spec, request: VisualRequest())
        let source = CmpMxSource(env: CmpEnv(spec: spec, data: data, context: VisualContext()), previous: nil)
        let pivot = source.pivot
        let column = try XCTUnwrap(data.table.columnIndex("Total by Product"))
        let spark = try XCTUnwrap(pivot.valueCols.firstIndex(of: column))
        let total = try XCTUnwrap(pivot.valueCols.firstIndex { $0 != column })
        func node(_ root: CmpMxNode, _ name: String) throws -> CmpMxNode {
            try XCTUnwrap(root.children.first { $0.path.last == .string(name) })
        }
        let north = try node(pivot.rowRoot, "North"), south = try node(pivot.rowRoot, "South")
        let web = try node(pivot.colRoot, "Web"), store = try node(pivot.colRoot, "Store")

        XCTAssertEqual(source.sparkPoints(row: north, col: web, v: spark), [10])          // Pear is blank there
        XCTAssertEqual(source.sparkPoints(row: north, col: pivot.colRoot, v: spark), [10, 20])
        XCTAssertEqual(source.sparkPoints(row: pivot.rowRoot, col: web, v: spark), [40, 40])   // Apple 10 + 30, Pear 40
        XCTAssertEqual(source.sparkPoints(row: pivot.rowRoot, col: store, v: spark), [50, 20]) // East's Apple, North's Pear
        XCTAssertEqual(source.sparkPoints(row: pivot.rowRoot, col: pivot.colRoot, v: spark), [90, 60])
        XCTAssertNil(source.sparkPoints(row: south, col: store, v: spark))                // no rows
        XCTAssertNil(source.sparkPoints(row: north, col: web, v: total))                  // Total is a number

        // With the average as its subtotal aggregate: Web's Apple is (10 + 30) / 2.
        let averaged = matrix(subtotal: "average")
        let avgData = F.engine().visualData(spec: averaged, request: VisualRequest())
        let avgSource = CmpMxSource(env: CmpEnv(spec: averaged, data: avgData, context: VisualContext()), previous: nil)
        let avgWeb = try node(avgSource.pivot.colRoot, "Web")
        let avgSpark = try XCTUnwrap(avgSource.pivot.valueCols.firstIndex(of: column))
        XCTAssertEqual(avgSource.sparkPoints(row: avgSource.pivot.rowRoot, col: avgWeb, v: avgSpark), [20, 40])
    }

    func testTheCommandAddsSparklinesToAMatrix() {
        let store = F.store()
        let m = matrix()
        store.mutate("Set Up", invalidates: .layout) { $0.report.pages[0].visuals = [m] }
        store.selection = [m.id]
        XCTAssertEqual(AppCommands.command("insert.sparkline")?.isEnabled(store), true)
    }
}
