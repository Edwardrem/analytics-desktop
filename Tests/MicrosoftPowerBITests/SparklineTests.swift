import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Sparklines in table cells: their definition, the series the query computes, and the command.
@MainActor
final class SparklineTests: XCTestCase {
    private typealias F = ReportFixture

    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func table() -> VisualSpec {
        var v = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 300, height: 200), name: "Table")
        v.setFields(.values, [F.region, F.total])
        return v
    }

    func testDefinitionSurvivesTheFormatCard() throws {
        var v = table()
        let s = Sparkline(name: "Total by Product", value: F.amount, axis: F.product, kind: .column)
        Sparklines.set(s, on: &v)
        XCTAssertEqual(Sparklines.list(v), [s])
        // The renderer's own contract is kept: the type, and the axis column's name.
        let card = try XCTUnwrap(v.format["sparklines"]?["Total by Product"])
        XCTAssertEqual(card["type"]?.stringValue, "column")
        XCTAssertEqual(card["by"]?.stringValue, "Product")
        // Re-saving under a new name replaces the old entry.
        var renamed = s; renamed.name = "Trend"
        Sparklines.set(renamed, replacing: s.name, on: &v)
        XCTAssertEqual(Sparklines.list(v).map(\.name), ["Trend"])
        Sparklines.remove("Trend", from: &v)
        XCTAssertNil(v.format["sparklines"])
    }

    func testSeriesFollowTheAxisOrderAndSkipBlanks() {
        // Row key, axis (month name), sort column (month number), value.
        let t = DataTable(name: "q", columnNames: ["Region", "Month", "MonthNo", "v"], rows: [
            [.string("North"), .string("Mar"), .int(3), .int(7)],
            [.string("North"), .string("Jan"), .int(1), .int(5)],
            [.string("North"), .string("Feb"), .int(2), .null],
            [.string("South"), .string("Feb"), .int(2), .int(9)],
        ], types: [.text, .text, .integer, .integer])
        let byMonthNumber = Sparklines.series(t, keys: 1, axis: 1, sort: 2, value: 3)
        XCTAssertEqual(byMonthNumber[[.string("North")]], [5, 7], "January before March; February is blank")
        XCTAssertEqual(byMonthNumber[[.string("South")]], [9])
        let byName = Sparklines.series(t, keys: 1, axis: 1, sort: nil, value: 3)
        XCTAssertEqual(byName[[.string("North")]], [5, 7], "Jan < Mar alphabetically too")
        XCTAssertEqual(Sparklines.cell([5, 7.5]), .string("5.0|7.5"))
    }

    func testTheQueryAddsOneSeriesPerRow() throws {
        var v = table()
        Sparklines.set(Sparkline(name: "Total by Product", value: F.total, axis: F.product), on: &v)
        let data = F.engine().visualData(spec: v, request: VisualRequest())
        XCTAssertNil(data.error)
        let column = try XCTUnwrap(data.table.columnIndex("Total by Product"))
        XCTAssertTrue(data.indices(.values).contains(column))
        XCTAssertNil(data.fields[column], "a sparkline is not a model field")
        var cells: [String: String] = [:]
        for r in 0..<data.table.rowCount { cells[data.table[r, 0].asString] = data.table[r, column].asString }
        // North: Apple 10, Pear 20. South: Apple 30, Pear 40. East: Apple 50.
        XCTAssertEqual(cells, ["North": "10.0|20.0", "South": "30.0|40.0", "East": "50.0"])
    }

    func testTheSeriesHonourTheVisualsFilters() throws {
        var v = table()
        Sparklines.set(Sparkline(name: "Total by Product", value: F.total, axis: F.product), on: &v)
        var web = FilterSpec(field: F.channel); web.values = [.string("Web")]
        var request = VisualRequest(); request.filters = [web]
        let data = F.engine().visualData(spec: v, request: request)
        let column = try XCTUnwrap(data.table.columnIndex("Total by Product"))
        var cells: [String: String] = [:]
        for r in 0..<data.table.rowCount { cells[data.table[r, 0].asString] = data.table[r, column].asString }
        // Web rows only: North Apple 10; South Apple 30, Pear 40; East sells only in store.
        XCTAssertEqual(cells, ["North": "10.0", "South": "30.0|40.0"])
    }

    func testCommandNeedsATableWithValues() {
        let store = F.store()
        var empty = table(); empty.wells = [:]
        let chart = F.chart(), full = table()
        store.mutate("Set Up", invalidates: .layout) { $0.report.pages[0].visuals = [empty, chart, full] }
        let command = AppCommands.command("insert.sparkline")
        XCTAssertNotNil(command)
        store.selection = [empty.id]
        XCTAssertEqual(command?.isEnabled(store), false)
        store.selection = [chart.id]
        XCTAssertEqual(command?.isEnabled(store), false, "only tables draw sparklines")
        store.selection = [full.id]
        XCTAssertEqual(command?.isEnabled(store), true)
        AppCommands.run("insert.sparkline", store)
        XCTAssertNotNil(store.sheet)
    }

    func testNewNamesDoNotCollide() {
        var v = table()
        XCTAssertEqual(Sparklines.uniqueName("Total", in: v), "Total 2", "a column of the table already has that name")
        Sparklines.set(Sparkline(name: "Total by Region", value: F.total, axis: F.region), on: &v)
        XCTAssertEqual(Sparklines.uniqueName("Total by Region", in: v), "Total by Region 2")
        XCTAssertEqual(Sparklines.uniqueName("Total by Product", in: v), "Total by Product")
    }
}
