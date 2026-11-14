import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Dynamic format strings evaluated per data point.
///
/// Sales by Region: East 400, West 800, North 1500 — 2700 in all. Total's format string is
/// `IF(SELECTEDMEASURE() >= 500, "#,0.00", "0")`: under the visual's filters (all regions, 2700)
/// that is "#,0.00", but East's own value is 400, so East is "0" while West and North keep "#,0.00".
@MainActor
final class PointFormatsTests: XCTestCase {
    private let region = FieldRef.column("Sales", "Region")
    private let total = FieldRef.measure("Sales", "Total")

    private func model(formatExpression: String?) -> SemanticModel {
        var t = ModelTable(name: "Sales", columns: [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .integer)])
        var m = Measure(name: "Total", expression: "SUM(Sales[Amount])")
        m.formatString = "#,0"
        m.formatExpression = formatExpression
        t.measures = [m]
        var model = SemanticModel()
        model.tables = [t]
        return model
    }

    private func engine(_ model: SemanticModel) -> CalculationService {
        let engine = Services.live().makeCalculation()
        var data = DataStore()
        data["Sales"] = DataTable(name: "Sales", columnNames: ["Region", "Amount"],
                                  rows: [[.string("East"), .int(400)], [.string("West"), .int(800)], [.string("North"), .int(1500)]],
                                  types: [.text, .integer])
        _ = engine.load(model: model, data: data, roles: [], userName: "")
        return engine
    }

    private func table(_ fields: [FieldRef]) -> VisualSpec {
        var v = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        v.setFields(.values, fields)
        return v
    }

    /// The result's rows by the text in `column`, so the checks don't depend on the row order.
    private func rows(_ data: VisualData, by column: Int = 0) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (0..<data.table.rowCount).map { (data.table[$0, column].asString, $0) })
    }

    func testEachDataPointTakesTheFormatItsOwnValueGives() throws {
        let data = engine(model(formatExpression: ##"IF(SELECTEDMEASURE() >= 500, "#,0.00", "0")"##))
            .visualData(spec: table([region, total]), request: VisualRequest())
        XCTAssertNil(data.error)
        XCTAssertEqual(data.formats[safe: 1], "#,0.00", "the visual's format, at 2700")
        let at = rows(data)
        let east = try XCTUnwrap(at["East"]), west = try XCTUnwrap(at["West"]), north = try XCTUnwrap(at["North"])
        XCTAssertEqual(data.format(row: east, col: 1), "0")
        XCTAssertEqual(data.format(row: west, col: 1), "#,0.00")
        XCTAssertEqual(data.formatted(row: east, col: 1), "400")
        XCTAssertEqual(data.formatted(row: west, col: 1), "800.00")
        XCTAssertEqual(data.formatted(row: north, col: 1), "1,500.00")
        XCTAssertEqual(data.format(row: east, col: 0), "", "a grouping column keeps its own format")
    }

    func testAConstantFormatStringIsNotEvaluatedPerPoint() {
        for expression in [##""#,0.0""##, nil] {
            let data = engine(model(formatExpression: expression)).visualData(spec: table([region, total]), request: VisualRequest())
            XCTAssertTrue(data.pointFormats.isEmpty, "\(expression ?? "no expression")")
        }
        // Where every point agrees with the visual, nothing is stored either: all three are ≥ 100.
        let same = engine(model(formatExpression: ##"IF(SELECTEDMEASURE() >= 100, "#,0.00", "0")"##))
            .visualData(spec: table([region, total]), request: VisualRequest())
        XCTAssertTrue(same.pointFormats.isEmpty)
    }

    func testACalculationItemsFormatAppliesToItsRows() throws {
        // Scale[Show]: Value (the measure as it is) and Share (its share of all regions, "0.0%").
        var m = model(formatExpression: nil)
        var group = CalculationGroup(name: "Scale")
        group.columnName = "Show"
        var value = CalculationItem(name: "Value", expression: "SELECTEDMEASURE()")
        value.ordinal = 0
        var share = CalculationItem(name: "Share", expression: "DIVIDE(SELECTEDMEASURE(), CALCULATE(SELECTEDMEASURE(), ALL(Sales)))")
        share.formatExpression = #""0.0%""#
        share.ordinal = 1
        group.items = [value, share]
        m.calculationGroups = [group]
        let data = engine(m).visualData(spec: table([.column("Scale", "Show"), total]), request: VisualRequest())
        XCTAssertNil(data.error)
        let at = rows(data)
        // Value is 2700 in "#,0"; Share is 2700 / 2700 = 1 in "0.0%".
        XCTAssertEqual(data.formatted(row: try XCTUnwrap(at["Value"]), col: 1), "2,700")
        XCTAssertEqual(data.formatted(row: try XCTUnwrap(at["Share"]), col: 1), "100.0%")
    }

    func testPointsWithTheSameCalculationItemShareOneEvaluation() {
        var m = model(formatExpression: ##""#,0""##)
        var group = CalculationGroup(name: "Scale")
        group.columnName = "Show"
        var share = CalculationItem(name: "Share", expression: "SELECTEDMEASURE()")
        share.formatExpression = #""0.0%""#
        group.items = [CalculationItem(name: "Value", expression: "SELECTEDMEASURE()"), share]
        m.calculationGroups = [group]
        // Three regions × two items: six rows, but the format only depends on the item, so two evaluations.
        let show = FieldRef.column("Scale", "Show")
        var rows: [[Value]] = []
        for r in ["East", "West", "North"] { for s in ["Value", "Share"] { rows.append([.string(r), .string(s), .int(1)]) } }
        let result = DataTable(name: "q", columnNames: ["Region", "Show", "Total"], rows: rows, types: [.text, .text, .integer])
        var calls: [[String]] = []
        let formats = PointFormats.formats(result: result, groups: [region, show], values: [(2, total)], visual: ["", "", "#,0"],
                                           filters: [], model: m) { _, filters in
            calls.append(filters)
            return filters.contains { $0.contains("\"Share\"") } ? "0.0%" : "#,0"
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first, ["FILTER(ALL('Scale'[Show]), 'Scale'[Show] IN { \"Value\" })"], "filtered by the item alone")
        XCTAssertEqual(formats[2], ["#,0", "0.0%", "#,0", "0.0%", "#,0", "0.0%"])
    }

    func testOnlyTextLiteralsMakeAConstantFormatString() {
        for constant in [##""#,0.00""##, #""0" & "%""#, #"( "0.0" )"#, #""say ""hi""""#, "\"0\" // fixed", "-- fixed\n\"0\"", "/* fixed */ \"0\""] {
            XCTAssertTrue(PointFormats.isConstant(constant), constant)
        }
        for dynamic in [#"IF(SELECTEDMEASURE() > 1, "0", "0.0")"#, "SELECTEDMEASUREFORMATSTRING()", #""0" & [Suffix]"#] {
            XCTAssertFalse(PointFormats.isConstant(dynamic), dynamic)
        }
    }

    func testABlankGroupValueIsFilteredAsBlank() {
        XCTAssertEqual(PointFormats.filter(region, .null), "FILTER(ALL('Sales'[Region]), ISBLANK('Sales'[Region]))")
        XCTAssertEqual(PointFormats.filter(region, .string("East")), "FILTER(ALL('Sales'[Region]), 'Sales'[Region] IN { \"East\" })")
    }
}
