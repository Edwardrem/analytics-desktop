import XCTest
import FacetCore
@testable import FacetDAX

/// Relationship semantics over the star-schema fixture: propagation, inactive relationships,
/// USERELATIONSHIP, CROSSFILTER, RELATED, RELATEDTABLE, LOOKUPVALUE and context transition.
/// All expected values are hand-computed from the fixture (see StarSchemaFixture).
final class StarSchemaRelationshipTests: StarSchemaTestCase {
    // MARK: Propagation directions

    func testSingleDirectionDoesNotFilterDimensions() throws {
        let us = filter("Customer", "Country", "US")
        // Customer → Sales is active, but Sales → Product is single-direction, so a customer
        // filter never reaches Product: all 6 members (5 products + the blank member) stay.
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(VALUES(Product[Product])), Customer[Country]=\"US\")", filters: [us]), 6)
        // The same with a product filter reaches Sales as usual → 490 for Red.
        let red = filter("Product", "Color", "Red")
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Product[Color]=\"Red\")", filters: [red]), 490)
    }

    func testBidirectionalModelRelationship() throws {
        // Sales → Store is bidirectional, so filters on Sales reach Store.
        // Office sales are rows 6 (East) and 10 (North) → 2 stores.
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(Store), Product[Category]=\"Office\")"), 2)
        // 2024 sales touch all three stores (rows 1,2,3,4,10,11 → stores 1,1,2,3,1,1) → 3.
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(Store), Date[Year]=2024)"), 3)
        // UK customers (Cal, Dee) buy in all three stores → 3.
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(Store), Customer[Country]=\"UK\")"), 3)
        // The dimension → fact direction still works: South sells 250.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Store[Store]=\"South\")"), 250)
    }

    func testCROSSFILTERModifier() throws {
        // NONE breaks the active relationship: the 2024 filter no longer reaches Sales → 700.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Date[Year]=2024, CROSSFILTER(Sales[DateKey], Date[DateKey], NONE))"), 700)
        // BOTH on the single-direction Product relationship lets a customer filter reach products.
        // US sales (rows 1,2,3,6,7,10) use products 1,2,3,5 → 4 members, no blank (no orphan row).
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(VALUES(Product[Product])), Customer[Country]=\"US\", CROSSFILTER(Sales[ProductKey], Product[ProductKey], BOTH))"), 4)
        // UK sales include the orphan row 11, so the blank member joins: 4 products + blank = 5.
        XCTAssertEqual(try num("CALCULATE(COUNTROWS(VALUES(Product[Product])), Customer[Country]=\"UK\", CROSSFILTER(Sales[ProductKey], Product[ProductKey], BOTH))"), 5)
        // Unknown direction and unrelated columns are rejected.
        XCTAssertThrowsError(try scalar("CALCULATE(SUM(Sales[Amount]), CROSSFILTER(Sales[DateKey], Date[DateKey], BOTHWAYS))"))
        XCTAssertThrowsError(try scalar("CALCULATE(SUM(Sales[Amount]), CROSSFILTER(Product[Product], Customer[Customer], BOTH))"))
        // Outside CALCULATE the modifier is rejected.
        XCTAssertThrowsError(try scalar("CROSSFILTER(Sales[DateKey], Date[DateKey], BOTH)"))
    }

    // MARK: Inactive relationship and USERELATIONSHIP

    func testInactiveRelationshipIsNotUsedByDefault() throws {
        // The order-date filter flows through the active relationship only: 2024 → 220.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), Date[Year]=2024)"), 220)
        // A ship-date analysis without USERELATIONSHIP is not possible from a date filter:
        // [Shipped Amount] activates the ship relationship, so it differs from [Total Amount].
        // Shipped "2024" = rows 1, 2, 11 (rows 3 and 4 ship on Jan 4/5, which are not in the
        // Date dimension, so they join the blank date row and are excluded by Year=2024).
        XCTAssertEqual(try num("CALCULATE([Shipped Amount], Date[Year]=2024)"), 70)
    }

    func testUSERELATIONSHIPActivatesInactiveRelationship() throws {
        // Ship keys are only matched where the Date dimension has the date. Shipped "2024":
        // rows 1, 2, 11 → 20+20+30 = 70; rows 3 and 4 (Jan 4/5) join the blank date row.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), USERELATIONSHIP(Sales[ShipDateKey], Date[DateKey]), Date[Year]=2024)"), 70)
        // Shipped "2025": rows 5, 6, 10 → 80+250+50 = 380; rows 7, 8, 9 (Jan 4–6) are unmatched.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), USERELATIONSHIP(Sales[ShipDateKey], Date[DateKey]), Date[Year]=2025)"), 380)
        // Without a date filter the relationship swap alone does not restrict anything → 700.
        XCTAssertEqual(try num("CALCULATE(SUM(Sales[Amount]), USERELATIONSHIP(Sales[ShipDateKey], Date[DateKey]))"), 700)
        // The measure form gives the same numbers.
        XCTAssertEqual(try num("[Shipped Amount]"), 700)
        XCTAssertEqual(try num("CALCULATE([Shipped Amount], Date[Year]=2025)"), 380)
        // No relationship between these columns → error.
        XCTAssertThrowsError(try scalar("CALCULATE(SUM(Sales[Amount]), USERELATIONSHIP(Product[Product], Customer[Customer]))"))
    }

    // MARK: RELATED / RELATEDTABLE

    func testRelatedFollowsRelationshipFromManySide() throws {
        // Store 2 sales: rows 3 (Ann, US), 5 (Dee, UK), 8 (Cal, UK) → 2 UK rows.
        XCTAssertEqual(try num("SUMX(FILTER(Sales, Sales[StoreKey]=2), IF(RELATED(Customer[Country])=\"UK\", 1, 0))"), 2)
        // Widget rows: 1, 4, 7 → 3.
        XCTAssertEqual(try num("COUNTROWS(FILTER(Sales, RELATED(Product[Product])=\"Widget\"))"), 3)
        // The orphan row has no product → RELATED is BLANK → 1 row.
        XCTAssertEqual(try num("COUNTROWS(FILTER(Sales, ISBLANK(RELATED(Product[Product]))))"), 1)
        // Ann buys Widget (10), Gizmo (30), Thing (50) → 2*10 + 3*30 + 5*50 + 1*50 = 410.
        XCTAssertEqual(try num("SUMX(FILTER(Sales, Sales[CustomerKey]=1), Sales[Qty] * RELATED(Product[Price]))"), 410)
    }

    func testRelatedTableUsesContextTransition() throws {
        // Rows per customer: Ann 4, Ben 2, Cal 2, Dee 3 → 11.
        XCTAssertEqual(try num("SUMX(VALUES(Customer[Customer]), COUNTROWS(RELATEDTABLE(Sales)))"), 11)
        XCTAssertEqual(try num("MAXX(FILTER(VALUES(Customer[Customer]), Customer[Customer]=\"Ann\"), COUNTROWS(RELATEDTABLE(Sales)))"), 4)
    }

    // MARK: LOOKUPVALUE

    func testLookupValueSearchesColumns() throws {
        XCTAssertEqual(try scalar("LOOKUPVALUE(Product[Product], Product[ProductKey], 3)"), .string("Gizmo"))
        XCTAssertEqual(try scalar("LOOKUPVALUE(Product[Product], Product[Color], \"Red\", Product[Category], \"Office\")"), .string("Thing"))
        // No match → BLANK, or the alternate result.
        XCTAssertTrue(try scalar("LOOKUPVALUE(Product[Product], Product[ProductKey], 99)").isNull)
        XCTAssertEqual(try scalar("LOOKUPVALUE(Product[Product], Product[ProductKey], 99, \"None\")"), .string("None"))
        // Several matches → error.
        XCTAssertThrowsError(try scalar("LOOKUPVALUE(Product[Product], Product[Color], \"Red\")"))
    }

    // MARK: Context transition

    func testContextTransitionWithMeasures() throws {
        // Per-product totals: Widget 40, Gadget 100, Gizmo 150, Doohickey 80, Thing 300, blank 30.
        XCTAssertEqual(try num("MAXX(VALUES(Product[Product]), [Total Amount])"), 300)
        XCTAssertEqual(try num("MINX(VALUES(Customer[Customer]), [Total Amount])"), 30)
        // Customers above 100: Ann 410, Dee 170 → 2.
        XCTAssertEqual(try num("COUNTROWS(FILTER(VALUES(Customer[Customer]), [Total Amount] > 100))"), 2)
        // A measure in an iterator over a dimension transitions to that dimension's row.
        XCTAssertEqual(try num("AVERAGEX(VALUES(Product[Product]), [Total Amount])"), 700.0 / 6.0, accuracy: 1e-12)
    }

    func testContextTransitionWithExplicitCalculate() throws {
        // US: 6 rows, UK: 5 rows → 11.
        XCTAssertEqual(try num("SUMX(VALUES(Customer[Country]), CALCULATE(COUNTROWS(Sales)))"), 11)
        // Red 490 + Blue 180 + blank 30 → 700.
        XCTAssertEqual(try num("SUMX(VALUES(Product[Color]), CALCULATE(SUM(Sales[Amount])))"), 700)
        // Among Ann (410) and Dee (170): Ann's qty 2+3+5+1 = 11, Dee's 2+2+1 = 5 → max 11.
        XCTAssertEqual(try num("MAXX(FILTER(VALUES(Customer[Customer]), [Total Amount] > 100), CALCULATE(SUM(Sales[Qty])))"), 11)
    }

    func testContextTransitionInNestedContextsWithEarlier() throws {
        // For each customer, count the customers with strictly more sales; keep customers that
        // have one. Ann 410 (none above), Ben 30, Cal 90, Dee 170 → 3.
        let dax = """
        COUNTROWS(FILTER(VALUES(Customer[Customer]),
            COUNTROWS(FILTER(VALUES(Customer[Customer]),
                [Total Amount] > CALCULATE([Total Amount], Customer[Customer] = EARLIER(Customer[Customer], 2)))) > 0))
        """
        XCTAssertEqual(try num(dax), 3)
    }

    func testContextTransitionThroughAddColumns() throws {
        // Extension column with per-customer totals: Ann 410, Ben 30, Cal 90, Dee 170 → 2 above 100.
        XCTAssertEqual(try num("COUNTROWS(FILTER(ADDCOLUMNS(VALUES(Customer[Customer]), \"Amt\", [Total Amount]), [Amt] > 100))"), 2)
    }

    func testCalculateTableFiltersAndTransitions() throws {
        // Red sales rows: 1,3,4,6,7,9,10 → 7.
        XCTAssertEqual(try num("COUNTROWS(CALCULATETABLE(Sales, Product[Color]=\"Red\"))"), 7)
        // Per product, sales rows above 50: Widget 0, Gadget 1, Gizmo 2, Doohickey 1, Thing 1, blank 0.
        XCTAssertEqual(try num("MAXX(VALUES(Product[Product]), COUNTROWS(CALCULATETABLE(Sales, Sales[Amount] > 50)))"), 2)
    }
}
