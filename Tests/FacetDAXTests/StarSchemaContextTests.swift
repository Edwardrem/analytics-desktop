import XCTest
import FacetCore
@testable import FacetDAX

/// Filter context, CALCULATE and its modifiers over the star-schema fixture.
/// All expected values are hand-computed from the fixture (see StarSchemaFixture).
final class StarSchemaContextTests: XCTestCase {
    private var engine: DAXEngine!

    override func setUpWithError() throws {
        engine = StarSchema.makeEngine()
    }

    /// A basic filter specification: `filter("Product", "Color", "Red")`.
    private func filter(_ table: String, _ column: String, _ values: Value...) -> FilterSpec {
        var spec = FilterSpec(field: .column(table, column))
        spec.values = values
        return spec
    }
    private func scalar(_ expression: String, filters: [FilterSpec] = []) throws -> Value {
        try engine.scalar(expression, filters: filters)
    }
    private func num(_ expression: String, filters: [FilterSpec] = []) throws -> Double {
        (try scalar(expression, filters: filters)).asDouble ?? .nan
    }
    private func column(_ dax: String, name: String, filters: [FilterSpec] = [], crossFilters: [[DataPointSelection]] = []) throws -> [Value] {
        let tables = try engine.query(dax, filters: filters, crossFilters: crossFilters)
        let table = try XCTUnwrap(tables.first, "query returned no result tables")
        return try XCTUnwrap(table.column(name)?.values, "missing column \(name)")
    }

    // MARK: Baseline totals

    func testTotalsWithoutFilters() throws {
        XCTAssertEqual(try num("[Total Amount]"), 700)
        XCTAssertEqual(try num("[Total Qty]"), 23)
        XCTAssertEqual(try num("[Sales Rows]"), 11)
        XCTAssertEqual(try num("[Amount Per Unit]"), 700.0 / 23.0, accuracy: 1e-12)
        // The orphan row references product key 99, which matches no product.
        XCTAssertEqual(try num("DISTINCTCOUNT(Sales[ProductKey])"), 6)
    }

    func testGroupingColumnsPropagateToSales() throws {
        // 2024: rows 1,2,3,4,10,11 → 20+20+90+10+50+30 = 220. 2025: 480.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Date[Year]=2024)"), 220)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Date[Year]=2025)"), 480)
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(Sales), Date[Year]=2024)"), 6)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Category]=\"Toys\")"), 230)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\")"), 490)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Blue\")"), 180)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Customer[Country]=\"UK\")"), 260)
    }

    // MARK: CALCULATE filter arguments

    func testCalculateReplacesExistingFilterOnSameColumn() throws {
        let red = filter("Product", "Color", "Red")
        let blue = filter("Product", "Color", "Blue")
        // The outer Blue filter is replaced by the CALCULATE Red filter → 490.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\")", filters: [blue]), 490)
        // Filters on different columns combine: Toys stays and Red is added → 150 (rows 3, 9).
        let toys = filter("Product", "Category", "Toys")
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\")", filters: [toys]), 150)
        // Both filters passed to CALCULATE combine: Year 2024 ∧ Red → rows 1,3,4,10 → 170.
        let y2024 = filter("Date", "Year", 2024)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Date[Year]=2024, Product[Color]=\"Red\")", filters: [y2024, red]), 170)
    }

    func testCalculateBooleanPredicateOverTwoColumns() throws {
        // One boolean filter over two columns of the same table: Toys ∧ Red → 150.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Category]=\"Toys\" && Product[Color]=\"Red\")"), 150)
        // A predicate over a column of another table is rejected.
        XCTAssertThrowsError(try scalar("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\" && Customer[Country]=\"UK\")"))
    }

    func testRootFilterContexts() throws {
        let red = filter("Product", "Color", "Red")
        let toys = filter("Product", "Category", "Toys")
        let y2024 = filter("Date", "Year", 2024)
        XCTAssertEqual(try num("SUM(Sales[Amount])", filters: [red]), 490)
        // Filters on different tables intersect: Toys ∧ 2024 → row 3 only → 90.
        XCTAssertEqual(try num("SUM(Sales[Amount])", filters: [toys, y2024]), 90)
        // Two values of one column union: Red ∪ Blue → 490 + 180 = 670 (the orphan row's blank
        // colour does not match either value).
        let redBlue = filter("Product", "Color", "Red", "Blue")
        XCTAssertEqual(try num("SUM(Sales[Amount])", filters: [redBlue]), 670)
    }

    func testRootAdvancedAndTopNFilters() throws {
        // Advanced: Sales[Amount] > 50 → rows 3,5,6,8,9 → 90+80+250+80+60 = 560.
        var advanced = FilterSpec(field: .column("Sales", "Amount"), kind: .advanced)
        advanced.conditions = [FilterCondition(op: .greaterThan, value: 50)]
        XCTAssertEqual(try num("SUM(Sales[Amount])", filters: [advanced]), 560)
        // Top N: the two largest sales rows by Amount → 250 + 90 = 340.
        var topN = FilterSpec(field: .column("Sales", "ProductKey"), kind: .topN)
        topN.topN.count = 2
        topN.topN.by = FieldRef.column("Sales", "Amount")
        XCTAssertEqual(try num("SUM(Sales[Amount])", filters: [topN]), 340)
    }

    func testCrossFilterSelections() throws {
        // A selected data point on Product[Color] filters Sales through the relationship.
        let total = "EVALUATE ROW(\"Total\", SUM(Sales[Amount]))"
        let color = FieldRef.column("Product", "Color")
        let red = [[DataPointSelection(fields: [color], values: ["Red"])]]
        XCTAssertEqual(try column(total, name: "Total", crossFilters: red).first?.asDouble, 490)
        // Multi-select of two data points unions: Red ∪ Blue → 670.
        let both = [[DataPointSelection(fields: [color], values: ["Red"]),
                     DataPointSelection(fields: [color], values: ["Blue"])]]
        XCTAssertEqual(try column(total, name: "Total", crossFilters: both).first?.asDouble, 670)
        // A tuple selection over two columns: Toys ∧ Red → 150.
        let category = FieldRef.column("Product", "Category")
        let tuple = [[DataPointSelection(fields: [category, color], values: ["Toys", "Red"])]]
        XCTAssertEqual(try column(total, name: "Total", crossFilters: tuple).first?.asDouble, 150)
    }

    // MARK: KEEPFILTERS

    func testKeepFiltersIntersectsInsteadOfReplacing() throws {
        let blue = filter("Product", "Color", "Blue")
        let redBlue = filter("Product", "Color", "Red", "Blue")
        // Blue ∩ Red = ∅ → BLANK.
        XCTAssertTrue(try scalar("CALCULATE(SUM(Sales[Amount]), KEEPFILTERS(Product[Color]=\"Red\"))", filters: [blue]).isNull)
        // {Red, Blue} ∩ Red = Red → 490.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), KEEPFILTERS(Product[Color]=\"Red\"))", filters: [redBlue]), 490)
        // Without KEEPFILTERS the same filter replaces the outer one → 490 even from Blue.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\")", filters: [blue]), 490)
    }

    // MARK: ALL / REMOVEFILTERS / ALLEXCEPT

    func testAllRemovesFilters() throws {
        let red = filter("Product", "Color", "Red")
        let toys = filter("Product", "Category", "Toys")
        let y2024 = filter("Date", "Year", 2024)
        // ALL(Product) clears the outer Product filters → 700.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ALL(Product))", filters: [red]), 700)
        // ALL(Product[Color]) clears only the colour; the category filter survives → 230.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ALL(Product[Color]))", filters: [red, toys]), 230)
        // ALL() clears everything → 700.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ALL())", filters: [red, y2024]), 700)
        // ALL(Sales) clears the expanded Sales table, so the dimension filters go too → 700.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ALL(Sales))", filters: [red, y2024]), 700)
        // A filter argument of the same CALCULATE is applied after ALL, so it survives → 490.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\", ALL(Product))"), 490)
        // ALLNOBLANKROW as a table function excludes the blank product row → 5 rows.
        XCTAssertEqual(try num("COUNTROWS(ALLNOBLANKROW(Product))"), 5)
    }

    func testRemoveFiltersMatchesAll() throws {
        let red = filter("Product", "Color", "Red")
        let toys = filter("Product", "Category", "Toys")
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), REMOVEFILTERS(Product[Color]))", filters: [red, toys]), 230)
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), REMOVEFILTERS())", filters: [red]), 700)
    }

    func testAllExceptKeepsNamedColumns() throws {
        let red = filter("Product", "Color", "Red")
        let toys = filter("Product", "Category", "Toys")
        // ALLEXCEPT(Product, Product[Color]) keeps only the colour filter → Red total 490.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ALLEXCEPT(Product, Product[Color]))", filters: [red, toys]), 490)
        // With no outer filters it clears every Product column except Color; the result is unfiltered.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ALLEXCEPT(Product, Product[Color]))"), 700)
    }

    func testAllSelectedRestoresOuterFilters() throws {
        // SUMMARIZECOLUMNS with a report-level Red filter. Inside each category group,
        // ALLSELECTED() restores the report context (Red), so the share is of 490, not 700.
        let red = filter("Product", "Color", "Red")
        let dax = """
        EVALUATE
        SUMMARIZECOLUMNS(Product[Category],
            "RedAmt", CALCULATE(SUM(Sales[Amount]), Product[Color]="Red"),
            "Share", DIVIDE(CALCULATE(SUM(Sales[Amount]), Product[Color]="Red"),
                            CALCULATE(SUM(Sales[Amount]), ALLSELECTED())))
        """
        let amounts = try column(dax, name: "RedAmt", filters: [red])
        let shares = try column(dax, name: "Share", filters: [red])
        let expectedShares: [Double] = [40.0 / 490.0, 150.0 / 490.0, 300.0 / 490.0]
        XCTAssertEqual(amounts.map { $0.asDouble ?? -1 }, [40, 150, 300])
        for (got, want) in zip(shares, expectedShares) {
            XCTAssertEqual(got.asDouble ?? -1, want, accuracy: 1e-12)
        }
    }

    // MARK: VALUES / DISTINCT / SELECTEDVALUE

    func testValuesIncludesBlankMemberButDistinctDoesNot() throws {
        // Sales has one orphan row, so Product carries a virtual blank row.
        XCTAssertEqual(try num("COUNTROWS(VALUES(Product[Product]))"), 6)
        XCTAssertEqual(try num("COUNTROWS(DISTINCT(Product[Product]))"), 5)
        XCTAssertEqual(try num("COUNTROWS(ALL(Product[Product]))"), 6)
        XCTAssertEqual(try num("COUNTROWS(Product)"), 6)
        // Tables without orphans have no blank member.
        XCTAssertEqual(try num("COUNTROWS(VALUES(Customer[Customer]))"), 4)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 4)
        // VALUES(Product[Color]) = Red, Blue, blank; VALUES(Product[Category]) adds a blank to 3 categories.
        XCTAssertEqual(try num("COUNTROWS(VALUES(Product[Color]))"), 3)
        XCTAssertEqual(try num("COUNTROWS(VALUES(Product[Category]))"), 4)
        // The blank member can be selected explicitly: the orphan row's 30.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), ISBLANK(Product[Product]))"), 30)
        XCTAssertEqual(try num("COUNTROWS(FILTER(VALUES(Product[Color]), ISBLANK(Product[Color])))"), 1)
    }

    func testSelectedValueAndHasOneValue() throws {
        let red = filter("Product", "Color", "Red")
        let redBlue = filter("Product", "Color", "Red", "Blue")
        XCTAssertEqual(try scalar("SELECTEDVALUE(Product[Color])", filters: [red]), .string("Red"))
        XCTAssertTrue(try scalar("SELECTEDVALUE(Product[Color])", filters: [redBlue]).isNull)
        XCTAssertEqual(try scalar("SELECTEDVALUE(Product[Color], \"Many\")", filters: [redBlue]), .string("Many"))
        XCTAssertEqual(try scalar("HASONEVALUE(Product[Color])", filters: [red]), .bool(true))
        XCTAssertEqual(try scalar("HASONEVALUE(Product[Color])", filters: [redBlue]), .bool(false))
        XCTAssertEqual(try scalar("HASONEVALUE(Product[Color])"), .bool(false))
    }

    // MARK: ISFILTERED / ISCROSSFILTERED

    func testIsFilteredAndIsCrossFiltered() throws {
        let red = filter("Product", "Color", "Red")
        let toys = filter("Product", "Category", "Toys")
        XCTAssertEqual(try scalar("ISFILTERED(Product[Color])", filters: [red]), .bool(true))
        XCTAssertEqual(try scalar("ISFILTERED(Product[Color])"), .bool(false))
        // A filter on another column of the same table is not a direct filter.
        XCTAssertEqual(try scalar("ISFILTERED(Product[Color])", filters: [toys]), .bool(false))
        // Direct filter on the column itself: not cross-filtered.
        XCTAssertEqual(try scalar("ISCROSSFILTERED(Product[Color])", filters: [red]), .bool(false))
        // A filter on another column of the same table is a cross filter.
        XCTAssertEqual(try scalar("ISCROSSFILTERED(Product[Color])", filters: [toys]), .bool(true))
        // A filter on Product reaches Sales through the relationship → cross-filtered.
        XCTAssertEqual(try scalar("ISCROSSFILTERED(Sales[Amount])", filters: [red]), .bool(true))
        XCTAssertEqual(try scalar("ISCROSSFILTERED(Sales[Amount])"), .bool(false))
        // Sales does not filter Product by default (single direction) → not cross-filtered.
        let uk = filter("Customer", "Country", "UK")
        XCTAssertEqual(try scalar("ISCROSSFILTERED(Product[Product])", filters: [uk]), .bool(false))
    }

    // MARK: ISINSCOPE

    func testIsInScopeFollowsGrouping() throws {
        // One grouping column: Category is in scope, Product is not. The orphan row's blank
        // product carries a blank category, so the group has four members.
        let one = """
        EVALUATE SUMMARIZECOLUMNS(Product[Category],
            "CatInScope", ISINSCOPE(Product[Category]),
            "ProdInScope", ISINSCOPE(Product[Product]),
            "Amt", [Total Amount])
        """
        XCTAssertEqual(try column(one, name: "CatInScope"), [.bool(true), .bool(true), .bool(true), .bool(true)])
        XCTAssertEqual(try column(one, name: "ProdInScope"), [.bool(false), .bool(false), .bool(false), .bool(false)])
        XCTAssertEqual(try column(one, name: "Amt"), [.int(140), .int(230), .int(300), .int(30)])
        // With both columns grouped, Product is in scope too.
        let two = """
        EVALUATE SUMMARIZECOLUMNS(Product[Category], Product[Product],
            "ProdInScope", ISINSCOPE(Product[Product]), "Amt", [Total Amount])
        """
        let inScope = try column(two, name: "ProdInScope")
        XCTAssertEqual(inScope.count, 6)
        XCTAssertEqual(Set(inScope), [.bool(true)])
    }
}
