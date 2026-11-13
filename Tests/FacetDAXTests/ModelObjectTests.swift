import XCTest
import FacetCore
@testable import FacetDAX

/// Model objects the engine evaluates beyond plain measures: user functions, calculation groups, calendars and bins.
///
/// Fixture: T has four rows — 29 Jun, 30 Jun, 1 Jul, 2 Jul 2024 with Amount 10, 20, 30, 40.
final class ModelObjectTests: XCTestCase {
    private func day(_ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = 2024; c.month = m; c.day = d
        return Calendar.utc.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }
    private func model() -> SemanticModel {
        var m = SemanticModel()
        var t = ModelTable(name: "T", columns: [ModelColumn(name: "Date", dataType: .date), ModelColumn(name: "Amount", dataType: .decimal)])
        t.measures = [Measure(name: "Total", expression: "SUM(T[Amount])")]
        m.tables = [t]
        return m
    }
    private func data() -> DataStore {
        var s = DataStore()
        s["T"] = DataTable(name: "T", columns: [
            DataColumn(name: "Date", type: .date, values: [.date(day(6, 29)), .date(day(6, 30)), .date(day(7, 1)), .date(day(7, 2))]),
            DataColumn(name: "Amount", type: .decimal, values: [.double(10), .double(20), .double(30), .double(40)]),
        ])
        return s
    }
    private func value(_ engine: DAXEngine, _ expression: String) throws -> Double? {
        try engine.query("EVALUATE ROW(\"v\", \(expression))").first?.columns.first?.values.first?.asDouble
    }

    func testUserFunctionsAreCallableWithDefaults() throws {
        var m = model()
        var rate = FunctionParameter(name: "rate")
        rate.defaultExpression = "0.1"
        m.functions = [UserFunction(name: "AddTax", parameters: [FunctionParameter(name: "amount"), rate], expression: "amount * (1 + rate)")]
        let engine = DAXEngine()
        XCTAssertEqual(engine.load(model: m, data: data()), [:])
        XCTAssertEqual(try XCTUnwrap(value(engine, "AddTax(100)")), 110, accuracy: 1e-9)       // the default rate
        XCTAssertEqual(try XCTUnwrap(value(engine, "addtax(100, 0.5)")), 150, accuracy: 1e-9)  // names are case-insensitive
        // A function defined in the query is found the same way.
        let defined = try engine.query("DEFINE FUNCTION Twice = (x) => x * 2\nEVALUATE ROW(\"v\", Twice([Total]))")
        XCTAssertEqual(defined.first?.columns.first?.values.first?.asDouble, 200)
    }

    func testACalculationGroupIsATableOfItsItems() throws {
        var m = model()
        var g = CalculationGroup(name: "Scale")
        var half = CalculationItem(name: "Half", expression: "SELECTEDMEASURE() / 2"); half.ordinal = 1
        var double = CalculationItem(name: "Double", expression: "SELECTEDMEASURE() * 2"); double.ordinal = 0
        g.items = [half, double]
        m.calculationGroups = [g]
        let engine = DAXEngine()
        XCTAssertEqual(engine.load(model: m, data: data()), [:])
        XCTAssertEqual(engine.data["Scale"]?.column("Name")?.values, [.string("Double"), .string("Half")], "items are listed by ordinal")
        XCTAssertEqual(try value(engine, "CALCULATE([Total], Scale[Name] = \"Double\")"), 200)
        XCTAssertEqual(try value(engine, "CALCULATE([Total], Scale[Name] = \"Half\")"), 50)
        XCTAssertEqual(try value(engine, "[Total]"), 100)
    }

    func testACalendarsFiscalYearStartsInItsFirstMonth() throws {
        var m = model()
        var fiscal = CalendarDefinition(name: "Fiscal", columnsByUnit: ["date": "Date"])
        fiscal.fiscalYearStartMonth = 7
        m.tables[0].calendars = [fiscal, CalendarDefinition(name: "Plain", columnsByUnit: ["date": "Date"])]
        let engine = DAXEngine()
        XCTAssertEqual(engine.load(model: m, data: data()), [:])
        // A July start: 2 July is the second day of the year, 30 June the last day of the year before.
        XCTAssertEqual(try value(engine, "CALCULATE(TOTALYTD([Total], Fiscal), T[Date] = DATE(2024, 7, 2))"), 70)
        XCTAssertEqual(try value(engine, "CALCULATE(TOTALYTD([Total], Fiscal), T[Date] = DATE(2024, 6, 30))"), 30)
        // A January start is the calendar year.
        XCTAssertEqual(try value(engine, "CALCULATE(TOTALYTD([Total], Plain), T[Date] = DATE(2024, 7, 2))"), 100)
    }

    func testBinsAreComputedFromTheGroupingDefinition() {
        var m = model()
        var bySize = ModelColumn(name: "Amount (bins)", dataType: .decimal)
        var size = ColumnGrouping(kind: .binSize, sourceColumn: "Amount"); size.binValue = 25
        bySize.grouping = size
        var byMonth = ModelColumn(name: "Month", dataType: .date)
        var month = ColumnGrouping(kind: .binSize, sourceColumn: "Date"); month.binValue = 1; month.binUnit = .month
        byMonth.grouping = month
        var byCount = ModelColumn(name: "Halves", dataType: .decimal)
        var count = ColumnGrouping(kind: .binCount, sourceColumn: "Amount"); count.binValue = 2   // 10–25 and 25–40
        byCount.grouping = count
        m.tables[0].columns += [bySize, byMonth, byCount]
        let engine = DAXEngine()
        XCTAssertEqual(engine.load(model: m, data: data()), [:])
        XCTAssertEqual(engine.data["T"]?.column("Amount (bins)")?.values.map(\.asDouble), [0, 0, 25, 25])
        XCTAssertEqual(engine.data["T"]?.column("Month")?.values, [.date(day(6, 1)), .date(day(6, 1)), .date(day(7, 1)), .date(day(7, 1))])
        XCTAssertEqual(engine.data["T"]?.column("Halves")?.values.map(\.asDouble), [10, 10, 25, 25])
    }
}
