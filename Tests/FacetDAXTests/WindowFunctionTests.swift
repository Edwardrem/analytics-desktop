import XCTest
import FacetCore
@testable import FacetDAX

/// OFFSET, INDEX, WINDOW, RANK and ROWNUMBER with ORDERBY / PARTITIONBY over the time schema.
/// All expected values are hand-computed from the fixture (see TimeSchemaFixture):
/// years 2023 → 210, 2024 → 4500, 2025 → 6000; East/West by year 90/120, 2500/2000, 2000/4000.
final class WindowFunctionTests: TimeSchemaTestCase {
    private func blankAware(_ values: [Value]) -> [Double?] { values.map { $0.isNull ? nil : $0.asDouble } }

    // MARK: INDEX

    func testIndexPicksByPosition() throws {
        // Without ORDERBY the relation is ordered by its columns, ascending.
        XCTAssertEqual(try column("EVALUATE INDEX(1, ALL('Date'[Year]))", name: "Date[Year]"), [.int(2023)])
        XCTAssertEqual(try column("EVALUATE INDEX(2, ALL('Date'[Year]))", name: "Date[Year]"), [.int(2024)])
        // Negative positions count from the end.
        XCTAssertEqual(try column("EVALUATE INDEX(-1, ALL('Date'[Year]))", name: "Date[Year]"), [.int(2025)])
        XCTAssertEqual(try column("EVALUATE INDEX(-3, ALL('Date'[Year]))", name: "Date[Year]"), [.int(2023)])
        XCTAssertEqual(try column("EVALUATE INDEX(1, ALL('Date'[Year]), ORDERBY('Date'[Year], DESC))", name: "Date[Year]"), [.int(2025)])
        // Zero and positions outside the relation give an empty table.
        XCTAssertEqual(try table("EVALUATE INDEX(0, ALL('Date'[Year]))").rowCount, 0)
        XCTAssertEqual(try table("EVALUATE INDEX(4, ALL('Date'[Year]))").rowCount, 0)
        XCTAssertEqual(try table("EVALUATE INDEX(-4, ALL('Date'[Year]))").rowCount, 0)
        // Ordered by an expression: the year with the largest amount is 2025, in every row.
        let best = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year],
            "Best", CALCULATE([Amt], INDEX(1, ALLSELECTED('Date'[Year]), ORDERBY([Amt], DESC))),
            "Worst", CALCULATE([Amt], INDEX(-1, ALLSELECTED('Date'[Year]), ORDERBY([Amt], DESC))))
        ORDER BY 'Date'[Year]
        """
        XCTAssertEqual(try numbers(best, name: "Best"), [6000, 6000, 6000])
        XCTAssertEqual(try numbers(best, name: "Worst"), [210, 210, 210])
    }

    func testIndexWithPartitions() throws {
        // With no current row every partition contributes its row: the latest year of each region.
        let latest = try table("""
        EVALUATE INDEX(1, SUMMARIZE(Sales, Sales[Region], 'Date'[Year]), ORDERBY('Date'[Year], DESC), PARTITIONBY(Sales[Region]))
        """)
        XCTAssertEqual(Set(latest.rows), [["East", 2025], ["West", 2025]])
        // With a current row only its partition is used: each region's best year.
        let best = """
        EVALUATE
        VAR T = SUMMARIZECOLUMNS(Sales[Region], 'Date'[Year], "A", [Amt])
        RETURN ADDCOLUMNS(T, "BestYear",
            MAXX(INDEX(1, T, ORDERBY([A], DESC), PARTITIONBY(Sales[Region])), 'Date'[Year]))
        ORDER BY Sales[Region], 'Date'[Year]
        """
        // East's best year is 2024 (2500), West's is 2025 (4000).
        XCTAssertEqual(try numbers(best, name: "BestYear"), [2024, 2024, 2024, 2025, 2025, 2025])
    }

    // MARK: OFFSET

    func testOffsetFromTheFilterContext() throws {
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year], "A", [Amt],
            "Prev", CALCULATE([Amt], OFFSET(-1, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Next", CALCULATE([Amt], OFFSET(1, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Same", CALCULATE([Amt], OFFSET(0, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Far", CALCULATE([Amt], OFFSET(-3, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "PrevDesc", CALCULATE([Amt], OFFSET(-1, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year], DESC))))
        ORDER BY 'Date'[Year]
        """
        XCTAssertEqual(try numbers(dax, name: "A"), [210, 4500, 6000])
        XCTAssertEqual(blankAware(try column(dax, name: "Prev")), [nil, 210, 4500])
        XCTAssertEqual(blankAware(try column(dax, name: "Next")), [4500, 6000, nil])
        XCTAssertEqual(try numbers(dax, name: "Same"), [210, 4500, 6000])
        XCTAssertEqual(blankAware(try column(dax, name: "Far")), [nil, nil, nil])
        // In descending order the previous row is the following year.
        XCTAssertEqual(blankAware(try column(dax, name: "PrevDesc")), [4500, 6000, nil])
    }

    func testOffsetWithoutRelationUsesAllSelectedOfTheOrderColumns() throws {
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year], "A", [Amt],
            "Prev", CALCULATE([Amt], OFFSET(-1, , ORDERBY('Date'[Year]))))
        ORDER BY 'Date'[Year]
        """
        XCTAssertEqual(blankAware(try column(dax, name: "Prev")), [nil, 210, 4500])
        // ALLSELECTED respects the outer filter: with only 2024 and 2025 selected, 2024 has no previous year.
        var years = FilterSpec(field: .column("Date", "Year"))
        years.values = [2024, 2025]
        XCTAssertEqual(blankAware(try column(dax, name: "Prev", filters: [years])), [nil, 4500])
        // Without a relation the ORDERBY columns must be fully qualified columns of one table.
        XCTAssertThrowsError(try scalar("CALCULATE([Amt], OFFSET(-1, , ORDERBY([Amt])))"))
        XCTAssertThrowsError(try scalar("CALCULATE([Amt], OFFSET(-1, , ORDERBY('Date'[Year]), PARTITIONBY(Sales[Region])))"))
        XCTAssertThrowsError(try scalar("CALCULATE([Amt], OFFSET(-1))"))
    }

    func testOffsetWithPartitions() throws {
        // Quarters: 2023 → 60, 40, 50, 60; 2024 → 1500, 1300, 800, 900; 2025 → 6000 (Q1 only).
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year], 'Date'[Quarter], "A", [Amt],
            "PrevInYear", CALCULATE([Amt], OFFSET(-1, , ORDERBY('Date'[Quarter]), PARTITIONBY('Date'[Year]))),
            "PrevOverall", CALCULATE([Amt], OFFSET(-1, , ORDERBY('Date'[Year], ASC, 'Date'[Quarter], ASC))))
        ORDER BY 'Date'[Year], 'Date'[Quarter]
        """
        // 2025 Q2 has no amount of its own but a previous quarter, so its row is kept; Q3 and Q4 are blank throughout.
        XCTAssertEqual(blankAware(try column(dax, name: "A")), [60, 40, 50, 60, 1500, 1300, 800, 900, 6000, nil])
        // Partitioned by year: the first quarter of each year has no previous row.
        XCTAssertEqual(blankAware(try column(dax, name: "PrevInYear")), [nil, 60, 40, 50, nil, 1500, 1300, 800, nil, 6000])
        // One window over all quarters: Q1 follows the previous year's Q4.
        XCTAssertEqual(blankAware(try column(dax, name: "PrevOverall")), [nil, 60, 40, 50, 60, 1500, 1300, 800, 900, 6000])
    }

    func testOffsetFromTheRowContext() throws {
        let dax = """
        EVALUATE ADDCOLUMNS(VALUES('Date'[Year]),
            "PrevYear", MAXX(OFFSET(-1, ALL('Date'[Year]), ORDERBY('Date'[Year])), 'Date'[Year]),
            "NextYear", MAXX(OFFSET(1, ALL('Date'[Year]), ORDERBY('Date'[Year])), 'Date'[Year]))
        ORDER BY 'Date'[Year]
        """
        XCTAssertEqual(blankAware(try column(dax, name: "PrevYear")), [nil, 2023, 2024])
        XCTAssertEqual(blankAware(try column(dax, name: "NextYear")), [2024, 2025, nil])
        // No row or filter context identifies a year: there is no current row.
        XCTAssertThrowsError(try scalar("COUNTROWS(OFFSET(-1, ALL('Date'[Year]), ORDERBY('Date'[Year])))"))
    }

    // MARK: WINDOW

    func testWindowRunningAndMovingTotals() throws {
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year], "A", [Amt],
            "Running", CALCULATE([Amt], WINDOW(1, ABS, 0, REL, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Remaining", CALCULATE([Amt], WINDOW(0, REL, -1, ABS, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Moving2", CALCULATE([Amt], WINDOW(-1, REL, 0, REL, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Moving2Short", CALCULATE([Amt], WINDOW(-1, 0, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Centered", CALCULATE([Amt], WINDOW(-1, REL, 1, REL, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "All", CALCULATE([Amt], WINDOW(1, ABS, -1, ABS, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "FirstTwo", CALCULATE([Amt], WINDOW(1, ABS, 2, ABS, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "LastTwo", CALCULATE([Amt], WINDOW(-2, ABS, -1, ABS, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))),
            "Rows", COUNTROWS(WINDOW(1, ABS, 0, REL, ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year]))))
        ORDER BY 'Date'[Year]
        """
        XCTAssertEqual(try numbers(dax, name: "Running"), [210, 4710, 10710])
        XCTAssertEqual(try numbers(dax, name: "Remaining"), [10710, 10500, 6000])
        XCTAssertEqual(try numbers(dax, name: "Moving2"), [210, 4710, 10500])
        XCTAssertEqual(try numbers(dax, name: "Moving2Short"), [210, 4710, 10500])
        XCTAssertEqual(try numbers(dax, name: "Centered"), [4710, 10710, 10500])
        XCTAssertEqual(try numbers(dax, name: "All"), [10710, 10710, 10710])
        XCTAssertEqual(try numbers(dax, name: "FirstTwo"), [4710, 4710, 4710])
        XCTAssertEqual(try numbers(dax, name: "LastTwo"), [10500, 10500, 10500])
        XCTAssertEqual(try numbers(dax, name: "Rows"), [1, 2, 3])
    }

    func testWindowRestartsInEachPartition() throws {
        // Year-to-date by quarter with a window partitioned by year.
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year], 'Date'[Quarter],
            "YTD", CALCULATE([Amt], WINDOW(1, ABS, 0, REL, ORDERBY('Date'[Quarter]), PARTITIONBY('Date'[Year]))))
        ORDER BY 'Date'[Year], 'Date'[Quarter]
        """
        XCTAssertEqual(try numbers(dax, name: "YTD"),
                       [60, 100, 150, 210, 1500, 2800, 3600, 4500, 6000, 6000, 6000, 6000])
    }

    // MARK: RANK / ROWNUMBER

    func testRankAndRowNumberFromTheFilterContext() throws {
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Year], "A", [Amt],
            "Rank", RANK(DENSE, ALLSELECTED('Date'[Year]), ORDERBY([Amt], DESC)),
            "RankAsc", RANK(SKIP, ALLSELECTED('Date'[Year]), ORDERBY([Amt], ASC)),
            "Row", ROWNUMBER(ALLSELECTED('Date'[Year]), ORDERBY([Amt], DESC)),
            "YearRow", ROWNUMBER(ALLSELECTED('Date'[Year]), ORDERBY('Date'[Year], DESC)))
        ORDER BY 'Date'[Year]
        """
        XCTAssertEqual(try numbers(dax, name: "Rank"), [3, 2, 1])
        XCTAssertEqual(try numbers(dax, name: "RankAsc"), [1, 2, 3])
        XCTAssertEqual(try numbers(dax, name: "Row"), [3, 2, 1])
        XCTAssertEqual(try numbers(dax, name: "YearRow"), [3, 2, 1])
    }

    func testRankTiesSkipAndDense() throws {
        // Quantity by product in the star schema: Thing 6, Gadget 5, Gizmo 5, Widget 4, Doohickey 2, blank 1.
        engine = StarSchema.makeEngine()
        let dax = """
        EVALUATE
        VAR T = SUMMARIZECOLUMNS(Product[Product], "Q", [Total Qty])
        RETURN ADDCOLUMNS(T,
            "Skip", RANK(SKIP, T, ORDERBY([Q], DESC)),
            "Dense", RANK(DENSE, T, ORDERBY([Q], DESC)),
            "Row", ROWNUMBER(T, ORDERBY([Q], DESC, Product[Product], ASC)),
            "RowDefaultTie", ROWNUMBER(T, ORDERBY([Q], DESC)))
        ORDER BY [Q] DESC, Product[Product]
        """
        // Ordered: Thing, Gadget, Gizmo, Widget, Doohickey, blank.
        XCTAssertEqual(try column(dax, name: "Product[Product]"), ["Thing", "Gadget", "Gizmo", "Widget", "Doohickey", .null])
        XCTAssertEqual(try numbers(dax, name: "Skip"), [1, 2, 2, 4, 5, 6])
        XCTAssertEqual(try numbers(dax, name: "Dense"), [1, 2, 2, 3, 4, 5])
        XCTAssertEqual(try numbers(dax, name: "Row"), [1, 2, 3, 4, 5, 6])
        // ROWNUMBER breaks the tie with the relation's remaining column (the product name).
        XCTAssertEqual(try numbers(dax, name: "RowDefaultTie"), [1, 2, 3, 4, 5, 6])
    }

    func testRankAndRowNumberWithPartitions() throws {
        let dax = """
        EVALUATE
        VAR T = SUMMARIZECOLUMNS(Sales[Region], 'Date'[Year], "A", [Amt])
        RETURN ADDCOLUMNS(T,
            "RowInRegion", ROWNUMBER(T, ORDERBY([A], DESC), PARTITIONBY(Sales[Region])),
            "RankInYear", RANK(SKIP, T, ORDERBY([A], DESC), PARTITIONBY('Date'[Year])),
            "DenseOverall", RANK(DENSE, T, ORDERBY([A], DESC)),
            "SkipOverall", RANK(SKIP, T, ORDERBY([A], DESC)))
        ORDER BY Sales[Region], 'Date'[Year]
        """
        // East: 90, 2500, 2000. West: 120, 2000, 4000.
        XCTAssertEqual(try numbers(dax, name: "A"), [90, 2500, 2000, 120, 2000, 4000])
        XCTAssertEqual(try numbers(dax, name: "RowInRegion"), [3, 1, 2, 3, 2, 1])
        // Within a year: 2023 West leads, 2024 East leads, 2025 West leads.
        XCTAssertEqual(try numbers(dax, name: "RankInYear"), [2, 1, 2, 1, 2, 1])
        // Overall: 4000, 2500, 2000 = 2000, 120, 90.
        XCTAssertEqual(try numbers(dax, name: "DenseOverall"), [5, 2, 3, 4, 3, 1])
        XCTAssertEqual(try numbers(dax, name: "SkipOverall"), [6, 2, 3, 5, 3, 1])
    }

    func testRowNumberFromTheRowContextOfABaseTable() throws {
        // Every sale has a distinct amount, so numbering the amounts gives 1…18 → sum 171;
        // the largest amount (3000) is row 1 and the smallest (10) row 18.
        let number = "ROWNUMBER(ALL(Sales[Amount]), ORDERBY(Sales[Amount], DESC))"
        XCTAssertEqual(try num("SUMX(Sales, \(number))"), 171)
        XCTAssertEqual(try num("MAXX(FILTER(Sales, Sales[Amount] = 3000), \(number))"), 1)
        XCTAssertEqual(try num("MAXX(FILTER(Sales, Sales[Amount] = 10), \(number))"), 18)
        // Without any context there is no current row.
        XCTAssertThrowsError(try scalar(number))
        XCTAssertThrowsError(try scalar("RANK(DENSE, ALL('Date'[Year]), ORDERBY('Date'[Year]))"))
    }

    func testHelpersOutsideWindowFunctionsAreRejected() throws {
        XCTAssertThrowsError(try scalar("ORDERBY('Date'[Year])"))
        XCTAssertThrowsError(try scalar("COUNTROWS(PARTITIONBY('Date'[Year]))"))
    }
}
