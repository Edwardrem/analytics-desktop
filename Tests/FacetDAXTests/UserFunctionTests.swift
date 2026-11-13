import XCTest
import FacetCore
@testable import FacetDAX

/// User-defined functions (model functions and DEFINE FUNCTION) over the time schema.
/// Expected values are hand-computed: total 10710, East 4590, West 6120; years 210 / 4500 / 6000.
final class UserFunctionTests: TimeSchemaTestCase {
    override func setUpWithError() throws {
        engine = TimeSchema.makeEngine { model, _ in
            model.functions = [
                UserFunction(name: "AddTax", expression: "(amount : scalar, rate : scalar = 0.1) => amount * (1 + rate)"),
                UserFunction(name: "EastOnly", expression: "(m : expr) => CALCULATE(m, Sales[Region] = \"East\")"),
                UserFunction(name: "EastOnlyVal", expression: "(m : scalar val) => CALCULATE(m, Sales[Region] = \"East\")"),
                UserFunction(name: "RowCount", expression: "(t : table) => COUNTROWS(t)"),
                UserFunction(name: "TopYears", expression: "(n : scalar) => TOPN(n, VALUES('Date'[Year]), [Amt], DESC)"),
                UserFunction(name: "TaxedEast", expression: "(m : expr, rate : scalar) => AddTax(EastOnly(m), rate)"),
                UserFunction(name: "Leak", expression: "() => x + 1"),
                UserFunction(name: "Documented", expression: "/// Doubles a number.\n(v : scalar) => v * 2"),
            ]
            model.tables[1].measures.append(Measure(name: "Amt With Tax", expression: "AddTax([Amt], 0.2)"))
            var gross = ModelColumn(name: "Gross", dataType: .decimal)
            gross.expression = "AddTax(Sales[Amount])"
            model.tables[1].columns.append(gross)
        }
    }

    func testScalarParametersAndDefaults() throws {
        XCTAssertEqual(try num("AddTax(100, 0.25)"), 125, accuracy: 1e-9)
        // The second parameter falls back to its default expression (0.1).
        XCTAssertEqual(try num("AddTax(100)"), 110, accuracy: 1e-9)
        XCTAssertEqual(try num("AddTax(100, )"), 110, accuracy: 1e-9)
        // Function names are case-insensitive.
        XCTAssertEqual(try num("addtax(10, 1)"), 20, accuracy: 1e-9)
        XCTAssertEqual(try num("ADDTAX(10, 1)"), 20, accuracy: 1e-9)
        XCTAssertEqual(try num("Documented(21)"), 42)
        // Arguments are expressions evaluated in the caller's context.
        XCTAssertEqual(try num("AddTax([Amt], 0)", filters: [filter("Date", "Year", 2023)]), 210, accuracy: 1e-9)
    }

    func testArgumentCountIsChecked() throws {
        XCTAssertThrowsError(try scalar("AddTax(100, 0.1, 3)"))
        XCTAssertThrowsError(try scalar("AddTax()"))
        XCTAssertThrowsError(try scalar("NoSuchFunction(1)"))
    }

    func testCalledFromMeasuresAndCalculatedColumns() throws {
        // 10710 × 1.2; by year 2024: 4500 × 1.2.
        XCTAssertEqual(try num("[Amt With Tax]"), 12852, accuracy: 1e-6)
        XCTAssertEqual(try num("[Amt With Tax]", filters: [filter("Date", "Year", 2024)]), 5400, accuracy: 1e-6)
        // The calculated column uses the default rate on every row: 10710 × 1.1.
        XCTAssertEqual(try num("SUM(Sales[Gross])"), 11781, accuracy: 1e-6)
        XCTAssertEqual(try num("MAX(Sales[Gross])"), 3300, accuracy: 1e-6)
    }

    func testExpressionParametersAreEvaluatedInTheFunctionsContext() throws {
        // `expr`: the argument is evaluated inside the function's CALCULATE → East only.
        XCTAssertEqual(try num("EastOnly([Amt])"), 4590)
        XCTAssertEqual(try num("EastOnly(SUM(Sales[Amount]))"), 4590)
        XCTAssertEqual(try num("EastOnly([Amt])", filters: [filter("Date", "Year", 2024)]), 2500)
        // `val`: the argument is evaluated once, before the call, so the filter has no effect.
        XCTAssertEqual(try num("EastOnlyVal([Amt])"), 10710)
        XCTAssertEqual(try num("EastOnlyVal(SUM(Sales[Amount]))"), 10710)
    }

    func testTableParametersAndTableResults() throws {
        XCTAssertEqual(try num("RowCount(VALUES('Date'[Year]))"), 3)
        // Amounts above 500: 600, 700, 800, 900, 1000, 2000, 3000.
        XCTAssertEqual(try num("RowCount(FILTER(Sales, Sales[Amount] > 500))"), 7)
        // A function can return a table: the two best years are 2025 and 2024.
        XCTAssertEqual(try num("COUNTROWS(TopYears(2))"), 2)
        XCTAssertEqual(try num("SUMX(TopYears(2), [Amt])"), 10500)
        XCTAssertEqual(Set(try column("EVALUATE TopYears(2)", name: "Date[Year]")), [.int(2024), .int(2025)])
        XCTAssertEqual(try num("CALCULATE([Amt], TopYears(1))"), 6000)
    }

    func testFunctionsCallFunctions() throws {
        // AddTax(EastOnly([Amt]), 0.5) = 4590 × 1.5.
        XCTAssertEqual(try num("TaxedEast([Amt], 0.5)"), 6885, accuracy: 1e-6)
    }

    func testFunctionsDoNotSeeTheCallersVariables() throws {
        XCTAssertThrowsError(try scalar("VAR x = 5 RETURN Leak()"))
        // Parameters shadow nothing outside the function: the caller's variable is intact.
        XCTAssertEqual(try num("VAR amount = 7 RETURN AddTax(1, 0) + amount"), 8, accuracy: 1e-9)
    }

    func testDefineFunctionInAQuery() throws {
        let dax = """
        DEFINE
            FUNCTION Twice = (v : scalar) => v * 2
            FUNCTION Share = (m : expr, col : anyref) => DIVIDE(m, CALCULATE(m, REMOVEFILTERS(col)))
        EVALUATE
            SUMMARIZECOLUMNS(Sales[Region], "Double", Twice([Amt]), "Share", Share([Amt], Sales[Region]), "Taxed", AddTax(Twice(5)))
            ORDER BY Sales[Region]
        """
        XCTAssertEqual(try numbers(dax, name: "Double"), [9180, 12240])
        let shares = try numbers(dax, name: "Share")
        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(shares[0], 4590.0 / 10710.0, accuracy: 1e-12)
        XCTAssertEqual(shares[1], 6120.0 / 10710.0, accuracy: 1e-12)
        // Query functions can call model functions: (5 × 2) × 1.1.
        XCTAssertEqual(try numbers(dax, name: "Taxed")[0], 11, accuracy: 1e-9)
        // A query definition does not outlive its query.
        XCTAssertThrowsError(try scalar("Twice(1)"))
        // A query function shadows a model function of the same name.
        let shadow = "DEFINE FUNCTION AddTax = (a : scalar) => a + 1000 EVALUATE ROW(\"r\", AddTax(1))"
        XCTAssertEqual(try numbers(shadow, name: "r"), [1001])
        XCTAssertEqual(try num("AddTax(1, 0)"), 1, accuracy: 1e-9)
    }

    func testInvalidFunctionIsReportedAtLoad() throws {
        var model = TimeSchema.model()
        model.functions = [UserFunction(name: "Bad", expression: "(x : scalar) => x +")]
        let errors = DAXEngine().load(model: model, data: TimeSchema.data())
        XCTAssertNotNil(errors["Bad"], "\(errors)")
    }

    func testCheckKnowsUserFunctions() throws {
        XCTAssertTrue(engine.check("AddTax([Amt], 0.1)", kind: .measure, homeTable: "Sales").isEmpty)
        XCTAssertFalse(engine.check("AddTaxes([Amt], 0.1)", kind: .measure, homeTable: "Sales").isEmpty)
    }
}
