import XCTest
import FacetCore
@testable import FacetDAX

/// Visual calculations over a visual's result grid.
///
/// The main grid is the time schema's amount by year and quarter (rows axis: Year, Quarter):
/// 2023 → 60, 40, 50, 60 (210) and 2024 → 1500, 1300, 800, 900 (4500); grand total 4710.
/// Expected values are worked out by hand from these numbers.
final class VisualCalculationTests: XCTestCase {
    private let engine = TimeSchema.makeEngine()
    private let grid = DataTable(name: "", columnNames: ["Year", "Quarter", "Sales"], rows: [
        [2023, 1, 60], [2023, 2, 40], [2023, 3, 50], [2023, 4, 60],
        [2024, 1, 1500], [2024, 2, 1300], [2024, 3, 800], [2024, 4, 900],
    ])

    /// One value per row; blanks are nil.
    private func calc(_ expression: String, file: StaticString = #filePath, line: UInt = #line) throws -> [Double?] {
        try engine.visualCalculation(expression, on: grid, rowAxis: ["Year", "Quarter"]).map { $0.isNull ? nil : $0.asDouble }
    }
    private func assertClose(_ got: [Double?], _ want: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, file: file, line: line)
        for (g, w) in zip(got, want) { XCTAssertEqual(g ?? .nan, w, accuracy: 1e-9, file: file, line: line) }
    }

    // MARK: Column references

    func testVisualColumnsAreReferencedByName() throws {
        XCTAssertEqual(try calc("[Sales]"), [60, 40, 50, 60, 1500, 1300, 800, 900])
        XCTAssertEqual(try calc("[Sales] * 2 + [Quarter]"), [121, 82, 103, 124, 3001, 2602, 1603, 1804])
        XCTAssertEqual(try engine.visualCalculation("IF([Sales] > 100, \"big\", \"small\")", on: grid, rowAxis: ["Year", "Quarter"]),
                       ["small", "small", "small", "small", "big", "big", "big", "big"])
        // A visual column hides a model measure of the same name.
        let named = DataTable(name: "", columnNames: ["Year", "Amt"], rows: [[2023, 1], [2024, 2]])
        XCTAssertEqual(try engine.visualCalculation("[Amt] + 1", on: named, rowAxis: ["Year"]), [.int(2), .int(3)])
        XCTAssertThrowsError(try calc("[No Such Column]"))
        // The dedicated functions are errors outside a visual calculation.
        XCTAssertThrowsError(try engine.scalar("RUNNINGSUM([Amt])"))
        XCTAssertThrowsError(try engine.scalar("COLLAPSE([Amt], ROWS)"))
    }

    // MARK: RUNNINGSUM

    func testRunningSum() throws {
        XCTAssertEqual(try calc("RUNNINGSUM([Sales])"), [60, 100, 150, 210, 1710, 3010, 3810, 4710])
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS)"), [60, 100, 150, 210, 1710, 3010, 3810, 4710])
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, NONE)"), [60, 100, 150, 210, 1710, 3010, 3810, 4710])
    }

    func testRunningSumResets() throws {
        let perYear: [Double?] = [60, 100, 150, 210, 1500, 2800, 3600, 4500]
        // With two levels the highest and the lowest parent are both the year.
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, HIGHESTPARENT)"), perYear)
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, LOWESTPARENT)"), perYear)
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, 1)"), perYear)
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, -1)"), perYear)
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, [Year])"), perYear)
        // On a single-level axis there is no parent to reset on.
        let years = DataTable(name: "", columnNames: ["Year", "Sales"], rows: [[2023, 210], [2024, 4500], [2025, 6000]])
        XCTAssertEqual(try engine.visualCalculation("RUNNINGSUM([Sales], ROWS, HIGHESTPARENT)", on: years, rowAxis: ["Year"]),
                       [.int(210), .int(4710), .int(10710)])
        XCTAssertThrowsError(try calc("RUNNINGSUM([Sales], ROWS, SOMETIMES)"))
        XCTAssertThrowsError(try calc("RUNNINGSUM([Sales], ROWS, [Sales])"))
    }

    func testRunningSumWithOrderBy() throws {
        // Largest first: 1500, 1300, 900, 800, 60 (Q1 2023), 60 (Q4 2023), 50, 40.
        XCTAssertEqual(try calc("RUNNINGSUM([Sales], ROWS, ORDERBY([Sales], DESC))"), [4560, 4710, 4670, 4620, 1500, 2800, 4500, 3700])
    }

    func testRunningSumSkipsBlanks() throws {
        let gaps = DataTable(name: "", columnNames: ["Year", "Sales"], rows: [[2021, .null], [2022, 5], [2023, .null], [2024, 7]])
        let result = try engine.visualCalculation("RUNNINGSUM([Sales])", on: gaps, rowAxis: ["Year"])
        XCTAssertTrue(result[0].isNull)
        XCTAssertEqual(result.dropFirst().map { $0.asDouble ?? .nan }, [5, 5, 12])
    }

    // MARK: MOVINGAVERAGE

    func testMovingAverage() throws {
        assertClose(try calc("MOVINGAVERAGE([Sales], 2)"), [60, 50, 45, 55, 780, 1400, 1050, 850])
        assertClose(try calc("MOVINGAVERAGE([Sales], 3)"), [60, 50, 50, 50, 1610.0 / 3, 2860.0 / 3, 1200, 1000])
        assertClose(try calc("MOVINGAVERAGE([Sales], 1)"), [60, 40, 50, 60, 1500, 1300, 800, 900])
        // Excluding the current row: the first row has nothing before it.
        let excluding = try calc("MOVINGAVERAGE([Sales], 3, FALSE)")
        XCTAssertNil(excluding[0])
        assertClose(Array(excluding.dropFirst()), [60, 50, 50, 50, 1610.0 / 3, 2860.0 / 3, 1200])
        // Restarting each year: Q1 2024 no longer averages with Q4 2023.
        assertClose(try calc("MOVINGAVERAGE([Sales], 2, TRUE, ROWS, HIGHESTPARENT)"), [60, 50, 45, 55, 1500, 1400, 1050, 850])
        XCTAssertThrowsError(try calc("MOVINGAVERAGE([Sales], 0)"))
    }

    // MARK: PREVIOUS / NEXT / FIRST / LAST

    func testPreviousAndNext() throws {
        XCTAssertEqual(try calc("PREVIOUS([Sales])"), [nil, 60, 40, 50, 60, 1500, 1300, 800])
        XCTAssertEqual(try calc("PREVIOUS([Sales], 2)"), [nil, nil, 60, 40, 50, 60, 1500, 1300])
        XCTAssertEqual(try calc("NEXT([Sales])"), [40, 50, 60, 1500, 1300, 800, 900, nil])
        XCTAssertEqual(try calc("NEXT([Sales], 3)"), [60, 1500, 1300, 800, 900, nil, nil, nil])
        // A blank is zero in arithmetic.
        XCTAssertEqual(try calc("[Sales] - PREVIOUS([Sales])"), [60, -20, 10, 10, 1440, -200, -500, 100])
        // Within each year only.
        XCTAssertEqual(try calc("PREVIOUS([Sales], 1, ROWS, HIGHESTPARENT)"), [nil, 60, 40, 50, nil, 1500, 1300, 800])
        XCTAssertEqual(try calc("NEXT([Sales], 1, ROWS, HIGHESTPARENT)"), [40, 50, 60, nil, 1300, 800, 900, nil])
        // The step count can be left out before the axis.
        XCTAssertEqual(try calc("PREVIOUS([Sales], ROWS)"), [nil, 60, 40, 50, 60, 1500, 1300, 800])
    }

    func testFirstAndLast() throws {
        XCTAssertEqual(try calc("FIRST([Sales])"), [Double?](repeating: 60, count: 8))
        XCTAssertEqual(try calc("LAST([Sales])"), [Double?](repeating: 900, count: 8))
        XCTAssertEqual(try calc("FIRST([Sales], ROWS, HIGHESTPARENT)"), [60, 60, 60, 60, 1500, 1500, 1500, 1500])
        XCTAssertEqual(try calc("LAST([Sales], ROWS, HIGHESTPARENT)"), [60, 60, 60, 60, 900, 900, 900, 900])
        XCTAssertEqual(try calc("[Sales] - FIRST([Sales])"), [0, -20, -10, 0, 1440, 1240, 740, 840])
    }

    // MARK: RANGE and window functions over the visual

    func testRange() throws {
        // The previous row and the current one.
        XCTAssertEqual(try calc("SUMX(RANGE(-1), [Sales])"), [60, 100, 90, 110, 1560, 2800, 2100, 1700])
        XCTAssertEqual(try calc("COUNTROWS(RANGE(-2))"), [1, 2, 3, 3, 3, 3, 3, 3])
        // The next row only.
        XCTAssertEqual(try calc("SUMX(RANGE(1, FALSE), [Sales])"), [40, 50, 60, 1500, 1300, 800, 900, nil])
        XCTAssertEqual(try calc("SUMX(RANGE(-1, TRUE, ROWS, HIGHESTPARENT), [Sales])"), [60, 100, 90, 110, 1500, 2800, 2100, 1700])
    }

    func testWindowFunctionsDefaultToTheVisualGrid() throws {
        XCTAssertEqual(try calc("ROWNUMBER()"), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(try calc("ROWNUMBER(ORDERBY([Quarter]), PARTITIONBY([Year]))"), [1, 2, 3, 4, 1, 2, 3, 4])
        // 1500, 1300, 900, 800, 60 = 60, 50, 40.
        XCTAssertEqual(try calc("RANK(DENSE, ORDERBY([Sales], DESC))"), [5, 7, 6, 5, 1, 2, 4, 3])
        XCTAssertEqual(try calc("RANK(SKIP, ORDERBY([Sales], DESC))"), [5, 8, 7, 5, 1, 2, 4, 3])
        XCTAssertEqual(try calc("SUMX(WINDOW(1, ABS, 0, REL), [Sales])"), [60, 100, 150, 210, 1710, 3010, 3810, 4710])
        XCTAssertEqual(try calc("SUMX(WINDOW(1, ABS, 0, REL, ORDERBY([Quarter]), PARTITIONBY([Year])), [Sales])"),
                       [60, 100, 150, 210, 1500, 2800, 3600, 4500])
        XCTAssertEqual(try calc("MAXX(OFFSET(-1), [Sales])"), [nil, 60, 40, 50, 60, 1500, 1300, 800])
        XCTAssertEqual(try calc("MAXX(INDEX(1, ORDERBY([Sales], DESC)), [Sales])"), [Double?](repeating: 1500, count: 8))
    }

    // MARK: COLLAPSE / EXPAND

    func testCollapse() throws {
        XCTAssertEqual(try calc("COLLAPSE([Sales], ROWS)"), [210, 210, 210, 210, 4500, 4500, 4500, 4500])
        XCTAssertEqual(try calc("COLLAPSE([Sales], ROWS, 2)"), [Double?](repeating: 4710, count: 8))
        XCTAssertEqual(try calc("COLLAPSE([Sales], [Quarter])"), [210, 210, 210, 210, 4500, 4500, 4500, 4500])
        XCTAssertEqual(try calc("COLLAPSEALL([Sales], ROWS)"), [Double?](repeating: 4710, count: 8))
        // Percent of parent and of grand total.
        assertClose(try calc("DIVIDE([Sales], COLLAPSE([Sales], ROWS))"),
                    [60.0 / 210, 40.0 / 210, 50.0 / 210, 60.0 / 210, 1500.0 / 4500, 1300.0 / 4500, 800.0 / 4500, 900.0 / 4500])
        assertClose(try calc("DIVIDE([Sales], COLLAPSEALL([Sales], ROWS))"),
                    [60.0 / 4710, 40.0 / 4710, 50.0 / 4710, 60.0 / 4710, 1500.0 / 4710, 1300.0 / 4710, 800.0 / 4710, 900.0 / 4710])
        // The collapsed level has one row per year, and the quarter is no longer a level.
        XCTAssertEqual(try calc("COLLAPSE(COUNTROWS(), ROWS)"), [Double?](repeating: 1, count: 8))
        XCTAssertEqual(try engine.visualCalculation("COLLAPSE(ISATLEVEL([Quarter]), ROWS)", on: grid, rowAxis: ["Year", "Quarter"]),
                       [Value](repeating: .bool(false), count: 8))
        XCTAssertEqual(try engine.visualCalculation("ISATLEVEL([Quarter])", on: grid, rowAxis: ["Year", "Quarter"]),
                       [Value](repeating: .bool(true), count: 8))
        XCTAssertEqual(try engine.visualCalculation("COLLAPSE(ISATLEVEL([Year]), ROWS)", on: grid, rowAxis: ["Year", "Quarter"]),
                       [Value](repeating: .bool(true), count: 8))
        // Other functions work at the collapsed level: the previous year's total.
        XCTAssertEqual(try calc("COLLAPSE(PREVIOUS([Sales]), ROWS)"), [nil, nil, nil, nil, 210, 210, 210, 210])
    }

    func testExpand() throws {
        // From the year level back down to its quarters: the average and the best quarter of the year.
        assertClose(try calc("COLLAPSE(EXPAND(AVERAGE([Sales]), ROWS), ROWS)"), [52.5, 52.5, 52.5, 52.5, 1125, 1125, 1125, 1125])
        XCTAssertEqual(try calc("COLLAPSE(EXPAND(MAX([Sales]), ROWS), ROWS)"), [60, 60, 60, 60, 1500, 1500, 1500, 1500])
        XCTAssertEqual(try calc("COLLAPSE(EXPAND(COUNTROWS(), ROWS), ROWS)"), [Double?](repeating: 4, count: 8))
        // From the grand total all the way down: every row of the visual.
        XCTAssertEqual(try calc("COLLAPSEALL(EXPANDALL(MAX([Sales]), ROWS), ROWS)"), [Double?](repeating: 1500, count: 8))
        XCTAssertEqual(try calc("COLLAPSEALL(EXPAND(COUNTROWS(), ROWS), ROWS)"), [Double?](repeating: 2, count: 8))
    }

    func testSuppliedLevelsAreUsedInsteadOfSums() throws {
        // An average is not additive: the visual supplies its real subtotals.
        let averages = DataTable(name: "", columnNames: ["Year", "Quarter", "Avg"], rows: [
            [2023, 1, 10], [2023, 2, 20], [2024, 1, 30], [2024, 2, 50],
        ])
        let byYear = DataTable(name: "", columnNames: ["Year", "Avg"], rows: [[2023, 14], [2024, 44]])
        let total = DataTable(name: "", columnNames: ["Avg"], rows: [[33]])
        func run(_ expression: String, levels: [DataTable]) throws -> [Double] {
            try engine.visualCalculation(expression, on: averages, rowAxis: ["Year", "Quarter"], levels: levels).map { $0.asDouble ?? .nan }
        }
        XCTAssertEqual(try run("COLLAPSE([Avg], ROWS)", levels: [byYear, total]), [14, 14, 44, 44])
        XCTAssertEqual(try run("COLLAPSEALL([Avg], ROWS)", levels: [byYear, total]), [33, 33, 33, 33])
        XCTAssertEqual(try run("LOOKUPWITHTOTALS([Avg], [Year], 2024)", levels: [byYear, total]), [44, 44, 44, 44])
        // Without supplied levels the values are summed.
        XCTAssertEqual(try run("COLLAPSE([Avg], ROWS)", levels: []), [30, 30, 80, 80])
        XCTAssertEqual(try run("COLLAPSEALL([Avg], ROWS)", levels: []), [110, 110, 110, 110])
    }

    // MARK: LOOKUP

    func testLookup() throws {
        XCTAssertEqual(try calc("LOOKUP([Sales], [Year], 2024, [Quarter], 1)"), [Double?](repeating: 1500, count: 8))
        // Columns that are not given keep the current row's value: the first quarter of the same year.
        XCTAssertEqual(try calc("LOOKUP([Sales], [Quarter], 1)"), [60, 60, 60, 60, 1500, 1500, 1500, 1500])
        XCTAssertEqual(try calc("LOOKUP([Sales], [Year], 2023)"), [60, 40, 50, 60, 60, 40, 50, 60])
        XCTAssertEqual(try calc("[Sales] - LOOKUP([Sales], [Year], 2023)"), [0, 0, 0, 0, 1440, 1260, 750, 840])
        XCTAssertEqual(try calc("LOOKUP([Sales], [Year], 2030)"), [Double?](repeating: nil, count: 8))
        // With totals, columns that are not given are totalled.
        XCTAssertEqual(try calc("LOOKUPWITHTOTALS([Sales], [Year], 2024)"), [Double?](repeating: 4500, count: 8))
        XCTAssertEqual(try calc("LOOKUPWITHTOTALS([Sales], [Quarter], 2)"), [Double?](repeating: 1340, count: 8))
        XCTAssertEqual(try calc("LOOKUPWITHTOTALS([Sales], [Year], 2024, [Quarter], 3)"), [Double?](repeating: 800, count: 8))
        XCTAssertEqual(try calc("LOOKUPWITHTOTALS([Sales], [Year], 2030)"), [Double?](repeating: nil, count: 8))
        XCTAssertThrowsError(try calc("LOOKUP([Sales])"))
        XCTAssertThrowsError(try calc("LOOKUP([Sales], [Year])"))
    }

    // MARK: Column axis

    func testAxisArgument() throws {
        // A matrix with regions on rows and years on columns, one grid row per cell.
        let matrix = DataTable(name: "", columnNames: ["Region", "Year", "Sales"], rows: [
            ["East", 2023, 90], ["East", 2024, 2500], ["East", 2025, 2000],
            ["West", 2023, 120], ["West", 2024, 2000], ["West", 2025, 4000],
        ])
        func run(_ expression: String) throws -> [Double?] {
            try engine.visualCalculation(expression, on: matrix, rowAxis: ["Region"], colAxis: ["Year"]).map { $0.isNull ? nil : $0.asDouble }
        }
        // Across the years of each region.
        XCTAssertEqual(try run("RUNNINGSUM([Sales], COLUMNS)"), [90, 2590, 4590, 120, 2120, 6120])
        XCTAssertEqual(try run("PREVIOUS([Sales], 1, COLUMNS)"), [nil, 90, 2500, nil, 120, 2000])
        // Down the regions of each year.
        XCTAssertEqual(try run("RUNNINGSUM([Sales], ROWS)"), [90, 2500, 2000, 210, 4500, 6000])
        XCTAssertEqual(try run("RUNNINGSUM([Sales])"), [90, 2500, 2000, 210, 4500, 6000])
        XCTAssertEqual(try run("FIRST([Sales], COLUMNS)"), [90, 90, 90, 120, 120, 120])
        // Collapsing the columns gives the region total; collapsing the rows the year total.
        XCTAssertEqual(try run("COLLAPSE([Sales], COLUMNS)"), [4590, 4590, 4590, 6120, 6120, 6120])
        XCTAssertEqual(try run("COLLAPSE([Sales], ROWS)"), [210, 4500, 6000, 210, 4500, 6000])
        XCTAssertEqual(try run("COLLAPSEALL(COLLAPSEALL([Sales], ROWS), COLUMNS)"), [Double?](repeating: 10710, count: 6))
        XCTAssertThrowsError(try run("COLLAPSE([Sales], DIAGONAL)"))
    }

    // MARK: Templates

    func testTemplatesProduceWorkingExpressions() throws {
        func template(_ id: String, window: Int = 3) throws -> [Double?] {
            let t = try XCTUnwrap(VisualCalcTemplates.template(id: id), id)
            return try calc(t.expression(field: "Sales", window: window))
        }
        XCTAssertEqual(VisualCalcTemplates.all.count, 9)
        XCTAssertEqual(try template("runningSum"), [60, 100, 150, 210, 1710, 3010, 3810, 4710])
        assertClose(try template("movingAverage", window: 2), [60, 50, 45, 55, 780, 1400, 1050, 850])
        assertClose(try template("percentOfParent"),
                    [60.0 / 210, 40.0 / 210, 50.0 / 210, 60.0 / 210, 1500.0 / 4500, 1300.0 / 4500, 800.0 / 4500, 900.0 / 4500])
        assertClose(try template("percentOfGrandTotal"),
                    [60.0 / 4710, 40.0 / 4710, 50.0 / 4710, 60.0 / 4710, 1500.0 / 4710, 1300.0 / 4710, 800.0 / 4710, 900.0 / 4710])
        XCTAssertEqual(try template("versusPrevious"), [60, -20, 10, 10, 1440, -200, -500, 100])
        XCTAssertEqual(try template("versusNext"), [20, -10, -10, -1440, 200, 500, -100, 900])
        XCTAssertEqual(try template("versusFirst"), [0, -20, -10, 0, 1440, 1240, 740, 840])
        XCTAssertEqual(try template("versusLast"), [-840, -860, -850, -840, 600, 400, -100, 0])
        // At the deepest level a row has no children: the average is the row's own value.
        assertClose(try template("averageOfChildren"), [60, 40, 50, 60, 1500, 1300, 800, 900])
        // A bracket in the field name is escaped.
        let t = try XCTUnwrap(VisualCalcTemplates.template(id: "runningSum"))
        XCTAssertEqual(t.expression(field: "Sales [net]"), "RUNNINGSUM([Sales [net]]])")
    }

    func testEmptyGrid() throws {
        let empty = DataTable(name: "", columnNames: ["Year", "Sales"], rows: [])
        XCTAssertEqual(try engine.visualCalculation("RUNNINGSUM([Sales])", on: empty, rowAxis: ["Year"]), [])
    }
}
