import XCTest
import FacetCore
@testable import FacetDAX

/// Iterator functions, RANKX and TOPN over the star-schema fixture.
/// All expected values are hand-computed from the fixture (see StarSchemaFixture).
final class StarSchemaIteratorTests: StarSchemaTestCase {
    // MARK: Iterators over the fact table

    func testIteratorsOverSales() throws {
        // Σ qty·amount: 40+20+270+10+160+1250+10+320+120+50+30 = 2280.
        XCTAssertEqual(try num("SUMX(Sales, Sales[Qty] * Sales[Amount])"), 2280)
        XCTAssertEqual(try num("AVERAGEX(Sales, Sales[Amount])"), 700.0 / 11.0, accuracy: 1e-12)
        XCTAssertEqual(try num("MINX(Sales, Sales[Amount])"), 10)
        XCTAssertEqual(try num("MAXX(Sales, Sales[Amount])"), 250)
        XCTAssertEqual(try num("COUNTX(Sales, Sales[Qty])"), 11)
        // Sorted amounts: 10,10,20,20,30,50,60,80,80,90,250 → median 50.
        XCTAssertEqual(try num("MEDIANX(Sales, Sales[Amount])"), 50)
    }

    func testIteratorsRespectFilterContext() throws {
        let y2024 = filter("Date", "Year", 2024)
        // 2024 qty: 2+1+3+1+1+1 = 9.
        XCTAssertEqual(try num("SUMX(Sales, Sales[Qty])", filters: [y2024]), 9)
        // 2024 rows × qty·amount: 40+20+270+10+50+30 = 420.
        XCTAssertEqual(try num("SUMX(FILTER(Sales, RELATED(Date[Year])=2024), Sales[Qty] * Sales[Amount])"), 420)
    }

    func testIteratorsOverDimensionTables() throws {
        // Per-customer totals: Ann 410, Dee 170, Cal 90, Ben 30.
        XCTAssertEqual(try scalar("CONCATENATEX(VALUES(Customer[Customer]), Customer[Customer], \", \", [Total Amount], DESC)"), .string("Ann, Dee, Cal, Ben"))
        XCTAssertEqual(try num("MAXX(VALUES(Customer[Country]), CALCULATE([Total Amount]))"), 440)
        XCTAssertEqual(try num("COUNTX(VALUES(Product[Product]), [Total Amount])"), 6)
    }

    // MARK: RANKX

    func testRANKXRanksByDescendingDefault() throws {
        let widget = filter("Product", "Product", "Widget")
        let thing = filter("Product", "Product", "Thing")
        // By total amount descending: Thing 300, Gizmo 150, Gadget 100, Doohickey 80, Widget 40, blank 30.
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Total Amount]), Product[Product]=\"Widget\")"), 5)
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Total Amount]), Product[Product]=\"Thing\")"), 1)
        // Explicit ASC: only the blank member (30) is below Widget's 40 → 2.
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Total Amount], , ASC), Product[Product]=\"Widget\")", filters: [widget]), 2)
        // A value argument replaces the current value: 200 ranks 2 descending, 6 ascending.
        XCTAssertEqual(try num("RANKX(ALL(Product[Product]), [Total Amount], 200)"), 2)
        XCTAssertEqual(try num("RANKX(ALL(Product[Product]), [Total Amount], 200, ASC)"), 6)
        XCTAssertEqual(try num("RANKX(ALL(Product[Product]), [Total Amount], 200, DESC)", filters: [thing]), 2)
    }

    func testRANKXTiesAndDense() throws {
        // Row counts: Widget 3, Gadget/Gizmo/Thing 2, Doohickey/blank 1.
        // Widget ranks 1; Doohickey has 4 products above it → 5.
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Sales Rows]), Product[Product]=\"Widget\")"), 1)
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Sales Rows]), Product[Product]=\"Gadget\")"), 2)
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Sales Rows]), Product[Product]=\"Doohickey\")"), 5)
        // With DENSE the ties collapse: Widget 1, Doohickey 3.
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Sales Rows], , , DENSE), Product[Product]=\"Widget\")"), 1)
        XCTAssertEqual(try num("CALCULATE(RANKX(ALL(Product[Product]), [Sales Rows], , , DENSE), Product[Product]=\"Doohickey\")"), 3)
    }

    // MARK: TOPN

    func testTOPNSelectsOrderedRows() throws {
        // By total amount descending: Thing 300, Gizmo 150 → 2 rows.
        XCTAssertEqual(try num("COUNTROWS(TOPN(2, VALUES(Product[Product]), [Total Amount]))"), 2)
        XCTAssertEqual(try num("CALCULATE(SUMX(TOPN(2, ALL(Product[Product]), [Total Amount]), [Total Amount]))"), 450)
        // ASC picks the bottom: the blank product member has the smallest total, 30.
        XCTAssertEqual(try num("CALCULATE([Total Amount], TOPN(1, VALUES(Product[Product]), [Total Amount], ASC))"), 30)
        // More rows requested than exist → all 6 members.
        XCTAssertEqual(try num("COUNTROWS(TOPN(10, VALUES(Product[Product]), [Total Amount]))"), 6)
        // Zero rows → an empty table, and COUNTROWS of an empty table is BLANK.
        XCTAssertTrue(try scalar("COUNTROWS(TOPN(0, VALUES(Product[Product]), [Total Amount]))").isNull)
    }

    func testTOPNIncludesTiesAtTheBoundary() throws {
        // Row counts: Widget 3, Gadget 2, Gizmo 2, Thing 2, Doohickey 1, blank 1.
        // TOPN 2 keeps Widget plus every row tied with the second row → 4.
        XCTAssertEqual(try num("COUNTROWS(TOPN(2, VALUES(Product[Product]), [Sales Rows]))"), 4)
        XCTAssertEqual(try num("COUNTROWS(TOPN(3, VALUES(Product[Product]), [Sales Rows]))"), 4)
        // TOPN as a CALCULATE filter: the top product by rows is Widget → 40.
        XCTAssertEqual(try num("CALCULATE([Total Amount], TOPN(1, ALL(Product[Product]), [Sales Rows]))"), 40)
    }

    // MARK: Iterators with context transition

    func testIteratorWithContextTransitionPerRow() throws {
        // Transitioning to each Sales row identifies the row itself: Σ qty = 23.
        XCTAssertEqual(try num("SUMX(Sales, CALCULATE(SUM(Sales[Qty])))"), 23)
        // Per-row amount, aggregated by category inside the iterator: Tools 140.
        XCTAssertEqual(try num("SUMX(FILTER(VALUES(Product[Category]), Product[Category]=\"Tools\"), CALCULATE(SUM(Sales[Amount])))"), 140)
    }
}
