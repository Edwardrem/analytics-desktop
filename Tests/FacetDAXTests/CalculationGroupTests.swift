import XCTest
import FacetCore
@testable import FacetDAX

/// Calculation groups over the time schema: SELECTEDMEASURE, precedence and format strings.
/// Groups (see `TimeSchema.addCalculationGroups`): `Time Calc`[Calc] (precedence 20) and
/// `Averages`[Average] (precedence 10). Expected values are hand-computed from the fixture.
final class CalculationGroupTests: TimeSchemaTestCase {
    override func setUpWithError() throws {
        engine = TimeSchema.makeEngine { model, data in TimeSchema.addCalculationGroups(&model, &data) }
    }

    private var march2024: [FilterSpec] { [filter("Date", "Year", 2024), filter("Date", "MonthNo", 3)] }
    private func calc(_ item: String) -> FilterSpec { filter("Time Calc", "Calc", .string(item)) }
    private func average(_ item: String) -> FilterSpec { filter("Averages", "Average", .string(item)) }

    // MARK: SELECTEDMEASURE

    func testItemReplacesTheMeasure() throws {
        // March 2024: 900 on its own; year to date 1500; March 2023: 30.
        XCTAssertEqual(try num("[Amt]", filters: march2024), 900)
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [calc("Current")]), 900)
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [calc("YTD")]), 1500)
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [calc("PY")]), 30)
        // (900 − 30) / 30 = 29.
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [calc("YoY %")]), 29, accuracy: 1e-12)
        // The same item applies to every measure: orders in March 2024 = 2, year to date 5, March 2023 = 1.
        XCTAssertEqual(try num("[Orders]", filters: march2024 + [calc("YTD")]), 5)
        XCTAssertEqual(try num("[Orders]", filters: march2024 + [calc("PY")]), 1)
        // Selecting the item inside CALCULATE works as well.
        XCTAssertEqual(try num("CALCULATE([Amt], 'Time Calc'[Calc] = \"YTD\")", filters: march2024), 1500)
    }

    func testItemAppliesToEachMeasureReferenceButNotToPlainExpressions() throws {
        let y2024 = filter("Date", "Year", 2024)
        // Both references are replaced: 2023 amount 210 + 2023 orders 6.
        XCTAssertEqual(try num("[Amt] + [Orders]", filters: [y2024, calc("PY")]), 216)
        // An aggregation that is not a measure reference is left alone.
        XCTAssertEqual(try num("SUM(Sales[Amount])", filters: [y2024, calc("PY")]), 4500)
        XCTAssertEqual(try num("SUM(Sales[Amount]) + [Amt]", filters: [y2024, calc("PY")]), 4710)
    }

    func testNoSingleItemMeansNoItem() throws {
        // Two items selected: the group is not applied.
        var two = FilterSpec(field: .column("Time Calc", "Calc"))
        two.values = ["YTD", "PY"]
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [two]), 900)
        // Removing the filter on the group removes the item.
        XCTAssertEqual(try num("CALCULATE([Amt], REMOVEFILTERS('Time Calc'))", filters: march2024 + [calc("YTD")]), 900)
    }

    func testItemsByGroupColumn() throws {
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Time Calc'[Calc], "A", [Amt], "N", [Orders])
        """
        let result = try table(dax, filters: [filter("Date", "Year", 2024)])
        var amounts: [String: Value] = [:], orders: [String: Value] = [:]
        for row in result.rows { amounts[row[0].asString] = row[1]; orders[row[0].asString] = row[2] }
        XCTAssertEqual(amounts["Current"]?.asDouble, 4500)
        XCTAssertEqual(amounts["YTD"]?.asDouble, 4500)
        XCTAssertEqual(amounts["PY"]?.asDouble, 210)
        // (4500 − 210) / 210.
        XCTAssertEqual(amounts["YoY %"]?.asDouble ?? .nan, 4290.0 / 210.0, accuracy: 1e-12)
        XCTAssertEqual(amounts["Name"], .string("Amt"))
        XCTAssertEqual(orders["PY"]?.asDouble, 6)
        XCTAssertEqual(orders["Name"], .string("Orders"))
        XCTAssertEqual(result.rowCount, 5)
    }

    func testSelectedMeasureFunctions() throws {
        XCTAssertEqual(try scalar("[Amt]", filters: [calc("Name")]), .string("Amt"))
        XCTAssertEqual(try scalar("[Orders]", filters: [calc("Name")]), .string("Orders"))
        // ISSELECTEDMEASURE: the item passes [Orders] through and returns −1 for any other measure.
        XCTAssertEqual(try num("[Orders]", filters: [average("Orders Only")]), 18)
        XCTAssertEqual(try num("[Amt]", filters: [average("Orders Only")]), -1)
        // Outside a calculation item the functions are errors.
        XCTAssertThrowsError(try scalar("SELECTEDMEASURE()"))
        XCTAssertThrowsError(try scalar("SELECTEDMEASURENAME()"))
        XCTAssertThrowsError(try scalar("ISSELECTEDMEASURE([Amt])"))
    }

    // MARK: Precedence

    func testHigherPrecedenceGroupIsAppliedFirst() throws {
        // Time Calc (20) wraps Averages (10): CALCULATE(DIVIDE([Amt], COUNTROWS('Date')), DATESYTD(…))
        // → 1500 over the 91 days from 1 January to 31 March 2024.
        let both = march2024 + [calc("YTD"), average("Per Day")]
        XCTAssertEqual(try num("[Amt]", filters: both), 1500.0 / 91.0, accuracy: 1e-12)
        // The order in which the filters arrive does not matter.
        XCTAssertEqual(try num("[Amt]", filters: [average("Per Day"), calc("YTD")] + march2024), 1500.0 / 91.0, accuracy: 1e-12)
        // Each group alone.
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [average("Per Day")]), 900.0 / 31.0, accuracy: 1e-12)
        XCTAssertEqual(try num("[Amt]", filters: march2024 + [calc("YTD"), average("Total")]), 1500)
    }

    func testPrecedenceDecidesNotDeclarationOrder() throws {
        // Same groups, but Averages (10) now outranks Time Calc (5):
        // DIVIDE(CALCULATE([Amt], DATESYTD(…)), COUNTROWS('Date')) → 1500 over the 31 days of March.
        engine = TimeSchema.makeEngine { model, data in
            TimeSchema.addCalculationGroups(&model, &data, timePrecedence: 5, averagePrecedence: 10)
        }
        let both = march2024 + [calc("YTD"), average("Per Day")]
        XCTAssertEqual(try num("[Amt]", filters: both), 1500.0 / 31.0, accuracy: 1e-12)
    }

    // MARK: Format strings

    private func format(_ measure: String, _ filters: [FilterSpec]) throws -> String {
        let def = try XCTUnwrap(engine.lookupMeasure(measure.daxKey))
        return engine.formatString(for: def, try engine.rootContext(filters))
    }

    func testFormatStringsFollowTheSelectedItem() throws {
        XCTAssertEqual(try format("Amt", []), "#,0")
        XCTAssertEqual(try format("Orders", []), "0")
        // An item without a format expression keeps the measure's format.
        XCTAssertEqual(try format("Amt", [calc("PY")]), "#,0")
        // An item with a format expression replaces it, for every measure.
        XCTAssertEqual(try format("Amt", [calc("YoY %")]), "0.0%")
        XCTAssertEqual(try format("Orders", [calc("YoY %")]), "0.0%")
        XCTAssertEqual(try format("Amt", [average("Per Day")]), "0.00")
        // SELECTEDMEASUREFORMATSTRING() is the format of the measure the item is applied to.
        XCTAssertEqual(try format("Amt", [average("In K")]), "#,0K")
        XCTAssertEqual(try format("Orders", [average("In K")]), "0K")
        // Two items selected in one group: no item, so the measure's own format.
        var two = FilterSpec(field: .column("Time Calc", "Calc"))
        two.values = ["YoY %", "PY"]
        XCTAssertEqual(try format("Amt", [two]), "#,0")
    }

    func testFormatStringsFollowPrecedence() throws {
        // Time Calc (20) is outermost: its constant format wins over the inner group's.
        XCTAssertEqual(try format("Amt", [calc("YoY %"), average("In K")]), "0.0%")
        // An outer item without a format expression passes the inner format through.
        XCTAssertEqual(try format("Amt", [calc("PY"), average("In K")]), "#,0K")
        // With Averages outermost, its SELECTEDMEASUREFORMATSTRING() sees the inner item's format.
        engine = TimeSchema.makeEngine { model, data in
            TimeSchema.addCalculationGroups(&model, &data, timePrecedence: 5, averagePrecedence: 10)
        }
        XCTAssertEqual(try format("Amt", [calc("YoY %"), average("In K")]), "0.0%K")
    }

    func testDynamicMeasureFormatString() throws {
        engine = TimeSchema.makeEngine { model, _ in
            var m = Measure(name: "Amt Auto", expression: "SUM(Sales[Amount])", formatString: "0")
            m.formatExpression = "IF(SELECTEDVALUE(Sales[Region]) = \"East\", \"€#,0\", \"$#,0\")"
            model.tables[1].measures.append(m)
        }
        XCTAssertEqual(try format("Amt Auto", [filter("Sales", "Region", "East")]), "€#,0")
        XCTAssertEqual(try format("Amt Auto", [filter("Sales", "Region", "West")]), "$#,0")
        XCTAssertEqual(try format("Amt Auto", []), "$#,0")
    }

    func testPublicFormatStringAPI() throws {
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt"), "#,0")
        XCTAssertEqual(try engine.formatString(forMeasure: "amt", filters: [calc("YoY %")]), "0.0%")
        // Filters given as DAX table expressions, as the visual query layer passes them.
        let item = "FILTER(ALL('Time Calc'[Calc]), 'Time Calc'[Calc] IN { \"YoY %\" })"
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt", filterTables: [item]), "0.0%")
        let inK = "TREATAS({ \"In K\" }, 'Averages'[Average])"
        XCTAssertEqual(try engine.formatString(forMeasure: "Orders", filterTables: [inK]), "0K")
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt", filters: [calc("PY")], filterTables: [inK]), "#,0K")
        // Two items of one group: no item applies.
        let two = "FILTER(ALL('Time Calc'[Calc]), 'Time Calc'[Calc] IN { \"YoY %\", \"PY\" })"
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt", filterTables: [two]), "#,0")
        XCTAssertNil(try engine.formatString(forMeasure: "No Such Measure"))
        XCTAssertThrowsError(try engine.formatString(forMeasure: "Amt", filterTables: ["FILTER("]))
    }

    // MARK: Loading problems

    func testInvalidItemIsReportedAndItsGroupIsNotApplied() throws {
        var model = TimeSchema.model(), data = TimeSchema.data()
        TimeSchema.addCalculationGroups(&model, &data)
        model.calculationGroups[1].items[0].expression = "SELECTEDMEASURE( +"
        let engine = DAXEngine()
        let errors = engine.load(model: model, data: data)
        XCTAssertNotNil(errors["Averages[Total]"], "\(errors)")
        XCTAssertEqual(errors.count, 1, "\(errors)")
        // The healthy group still works; the broken one applies none of its items.
        XCTAssertEqual(try engine.scalar("[Amt]", filters: [filter("Date", "Year", 2024), calc("PY")]).asDouble, 210)
        XCTAssertEqual(try engine.scalar("[Amt]", filters: [filter("Date", "Year", 2024), average("Per Day")]).asDouble, 4500)
    }

    func testGroupTableListsItemsInOrdinalOrder() throws {
        XCTAssertEqual(try column("EVALUATE VALUES('Time Calc'[Calc])", name: "Time Calc[Calc]"),
                       ["Current", "YTD", "PY", "YoY %", "Name"])
        XCTAssertEqual(try num("COUNTROWS('Averages')"), 4)
    }
}
