import XCTest
import FacetCore
@testable import FacetDAX

/// Time intelligence over the time schema (a contiguous, marked date table).
/// All expected values are hand-computed from the fixture (see TimeSchemaFixture).
final class TimeIntelligenceTests: TimeSchemaTestCase {
    private var y2023: FilterSpec { filter("Date", "Year", 2023) }
    private var y2024: FilterSpec { filter("Date", "Year", 2024) }
    private var y2025: FilterSpec { filter("Date", "Year", 2025) }
    private func month(_ n: Int) -> FilterSpec { filter("Date", "MonthNo", .int(Int64(n))) }
    private func quarter(_ n: Int) -> FilterSpec { filter("Date", "Quarter", .int(Int64(n))) }
    private func on(_ day: String) -> FilterSpec { filter("Date", "Date", StarSchema.day(day)) }

    // MARK: Fixture

    func testFixtureTotals() throws {
        XCTAssertEqual(try num("COUNTROWS('Date')"), 1096)
        XCTAssertEqual(try num("[Amt]"), 10710)
        XCTAssertEqual(try num("[Amt]", filters: [y2023]), 210)
        XCTAssertEqual(try num("[Amt]", filters: [y2024]), 4500)
        XCTAssertEqual(try num("[Amt]", filters: [y2025]), 6000)
        XCTAssertEqual(try num("[Amt]", filters: [y2024, quarter(1)]), 1500)
        XCTAssertEqual(try num("[Amt]", filters: [filter("Sales", "Region", "East")]), 4590)
    }

    // MARK: TOTALYTD / TOTALQTD / TOTALMTD

    func testTotalYTDAccumulatesFromTheStartOfTheYear() throws {
        // March 2024: Jan 300 + Feb 300 + Mar 900. The filters on Year and MonthNo are replaced
        // by the year-to-date dates because the filter is on the date table's date column.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [y2024, month(3)]), 1500)
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [y2024, month(1)]), 300)
        // May has no sales of its own but the running total carries on: 1500 + Apr 600.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [y2024, month(5)]), 2100)
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [y2024, month(12)]), 4500)
        // A whole year: its total. No year filter: up to the last date of the table, in 2025.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [y2023]), 210)
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])"), 6000)
        // A single day: everything from 1 January up to that day (Jan 1 100 + Jan 15 200).
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [on("2024-01-15")]), 300)
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [on("2024-01-14")]), 100)
        // The measure form is the same as CALCULATE over DATESYTD.
        XCTAssertEqual(try num("CALCULATE([Amt], DATESYTD('Date'[Date]))", filters: [y2024, month(3)]), 1500)
    }

    func testTotalYTDWithFiscalYearEnd() throws {
        // Year ending 30 June: March 2024 belongs to the year that began 1 July 2023 →
        // Jul 50 + Dec 60 + Jan 300 + Feb 300 + Mar 900 = 1610.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date], \"6/30\")", filters: [y2024, month(3)]), 1610)
        // June closes that year: + Apr 600 + Jun 700 = 2910. July starts a new one: 800.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date], \"6/30\")", filters: [y2024, month(6)]), 2910)
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date], \"6/30\")", filters: [y2024, month(7)]), 800)
        XCTAssertEqual(try dates("DATESYTD('Date'[Date], \"6/30\")", filters: [y2024, month(8)]),
                       TimeSchemaTestCase.days("2024-07-01", "2024-08-31"))
    }

    func testTotalYTDWithFilterArgument() throws {
        // East only: Jan 100 + Feb 300 + Mar 500.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date], Sales[Region] = \"East\")", filters: [y2024, month(3)]), 900)
        // The filter argument can also remove a filter: ALL(Sales[Region]) undoes the outer East.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date], ALL(Sales[Region]))",
                               filters: [y2024, month(3), filter("Sales", "Region", "East")]), 1500)
        // An outer filter on another table is kept.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [y2024, month(3), filter("Sales", "Region", "West")]), 600)
    }

    func testTotalQTDAndMTD() throws {
        // June 2024 is in Q2: Apr 600 + Jun 700. March closes Q1: 1500. April opens Q2: 600.
        XCTAssertEqual(try num("TOTALQTD([Amt], 'Date'[Date])", filters: [y2024, month(6)]), 1300)
        XCTAssertEqual(try num("TOTALQTD([Amt], 'Date'[Date])", filters: [y2024, month(3)]), 1500)
        XCTAssertEqual(try num("TOTALQTD([Amt], 'Date'[Date])", filters: [y2024, month(4)]), 600)
        // Month to date on 20 March 2024: only the 15th (400) has happened; on the 31st, 900.
        XCTAssertEqual(try num("TOTALMTD([Amt], 'Date'[Date])", filters: [on("2024-03-20")]), 400)
        XCTAssertEqual(try num("TOTALMTD([Amt], 'Date'[Date])", filters: [on("2024-03-31")]), 900)
        XCTAssertTrue(try scalar("TOTALMTD([Amt], 'Date'[Date])", filters: [on("2024-03-14")]).isNull)
        XCTAssertEqual(try dates("DATESQTD('Date'[Date])", filters: [y2024, month(5)]),
                       TimeSchemaTestCase.days("2024-04-01", "2024-05-31"))
        XCTAssertEqual(try dates("DATESMTD('Date'[Date])", filters: [on("2024-02-10")]),
                       TimeSchemaTestCase.days("2024-02-01", "2024-02-10"))
    }

    func testRunningTotalByMonth() throws {
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[Month], "YTD", TOTALYTD([Amt], 'Date'[Date]))
        ORDER BY 'Date'[Month]
        """
        // Every month of 2024 has a running total, including the months without sales.
        XCTAssertEqual(try numbers(dax, name: "YTD", filters: [y2024]),
                       [300, 600, 1500, 2100, 2100, 2800, 3600, 3600, 3600, 3600, 3600, 4500])
    }

    // MARK: SAMEPERIODLASTYEAR / DATEADD / PARALLELPERIOD

    func testSamePeriodLastYear() throws {
        XCTAssertEqual(try num("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))", filters: [y2024]), 210)
        XCTAssertEqual(try num("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))", filters: [y2025]), 4500)
        XCTAssertEqual(try num("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))", filters: [y2024, month(2)]), 20)
        XCTAssertEqual(try num("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))", filters: [y2025, quarter(1)]), 1500)
        // There is no 2022 in the date table.
        XCTAssertTrue(try scalar("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))", filters: [y2023]).isNull)
        // A filter on another table stays: East in 2023 = 10 + 30 + 50.
        XCTAssertEqual(try num("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))",
                               filters: [y2024, filter("Sales", "Region", "East")]), 90)
        // A whole month maps to the whole month a year earlier: leap February (29 days) → 28 days,
        // and February 2025 (28 days) → all 29 days of February 2024.
        XCTAssertEqual(try dates("SAMEPERIODLASTYEAR('Date'[Date])", filters: [y2024, month(2)]),
                       TimeSchemaTestCase.days("2023-02-01", "2023-02-28"))
        XCTAssertEqual(try dates("SAMEPERIODLASTYEAR('Date'[Date])", filters: [y2025, month(2)]),
                       TimeSchemaTestCase.days("2024-02-01", "2024-02-29"))
        // Year over year by month, 2024 against 2023 (April has no counterpart).
        let dax = """
        EVALUATE SUMMARIZECOLUMNS('Date'[MonthNo], "A", [Amt], "PY", CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date])))
        ORDER BY 'Date'[MonthNo]
        """
        XCTAssertEqual(try numbers(dax, name: "Date[MonthNo]", filters: [y2024]), [1, 2, 3, 4, 6, 7, 12])
        XCTAssertEqual(try numbers(dax, name: "A", filters: [y2024]), [300, 300, 900, 600, 700, 800, 900])
        let previous = try column(dax, name: "PY", filters: [y2024])
        XCTAssertEqual(previous.map { $0.asDouble ?? -1 }, [10, 20, 30, -1, 40, 50, 60])
        XCTAssertTrue(previous[3].isNull)
    }

    func testDateAdd() throws {
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -1, MONTH))", filters: [y2024, month(3)]), 300)
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], 1, MONTH))", filters: [y2024, month(3)]), 600)
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -1, QUARTER))", filters: [y2024, quarter(2)]), 1500)
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -1, YEAR))", filters: [y2025]), 4500)
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -2, YEAR))", filters: [y2025]), 210)
        // January 2024 back one month crosses the year boundary: December 2023.
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -1, MONTH))", filters: [y2024, month(1)]), 60)
        // Day shifts: 1 March 2024 back one day is the leap day (300).
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -1, DAY))", filters: [on("2024-03-01")]), 300)
        XCTAssertEqual(try dates("DATEADD('Date'[Date], 1, DAY)", filters: [on("2024-12-31")]), ["2025-01-01"])
        // Part of a month shifts day by day.
        var part = FilterSpec(field: .column("Date", "Date"))
        part.values = [StarSchema.day("2024-03-10"), StarSchema.day("2024-03-11"), StarSchema.day("2024-03-12")]
        XCTAssertEqual(try dates("DATEADD('Date'[Date], -1, MONTH)", filters: [part]), ["2024-02-10", "2024-02-11", "2024-02-12"])
        // Whole months stay whole: 2024 → the 365 days of 2023, and 2025 → the 366 days of 2024.
        XCTAssertEqual(try dates("DATEADD('Date'[Date], -1, YEAR)", filters: [y2024]),
                       TimeSchemaTestCase.days("2023-01-01", "2023-12-31"))
        XCTAssertEqual(try num("COUNTROWS(DATEADD('Date'[Date], -1, YEAR))", filters: [y2025]), 366)
        // Dates outside the date table are dropped.
        XCTAssertEqual(try dates("DATEADD('Date'[Date], -1, YEAR)", filters: [y2023]), [])
        XCTAssertThrowsError(try scalar("COUNTROWS(DATEADD('Date'[Date], -1, FORTNIGHT))"))
        XCTAssertThrowsError(try scalar("COUNTROWS(DATEADD(Sales[Region], -1, MONTH))"))
    }

    func testParallelPeriodReturnsWholePeriods() throws {
        // One month of 2024 → the whole previous year.
        XCTAssertEqual(try num("CALCULATE([Amt], PARALLELPERIOD('Date'[Date], -1, YEAR))", filters: [y2024, month(2)]), 210)
        XCTAssertEqual(try num("CALCULATE([Amt], PARALLELPERIOD('Date'[Date], 1, YEAR))", filters: [y2024, month(2)]), 6000)
        // One day in May 2024 → the whole previous quarter (Q1 2024), and the whole next month.
        XCTAssertEqual(try dates("PARALLELPERIOD('Date'[Date], -1, QUARTER)", filters: [on("2024-05-10")]),
                       TimeSchemaTestCase.days("2024-01-01", "2024-03-31"))
        XCTAssertEqual(try num("CALCULATE([Amt], PARALLELPERIOD('Date'[Date], -1, QUARTER))", filters: [on("2024-05-10")]), 1500)
        XCTAssertEqual(try num("CALCULATE([Amt], PARALLELPERIOD('Date'[Date], 1, MONTH))", filters: [on("2024-05-10")]), 700)
        // Unlike DATEADD, a partial selection still returns the full period.
        XCTAssertEqual(try num("CALCULATE([Amt], DATEADD('Date'[Date], -1, YEAR))", filters: [on("2024-01-15")]), 10)
        XCTAssertEqual(try num("CALCULATE([Amt], PARALLELPERIOD('Date'[Date], -1, YEAR))", filters: [on("2024-01-15")]), 210)
    }

    // MARK: DATESINPERIOD / DATESBETWEEN

    func testDatesInPeriod() throws {
        // Three months ending on the last visible date (31 March 2024): the first quarter.
        XCTAssertEqual(try num("CALCULATE([Amt], DATESINPERIOD('Date'[Date], MAX('Date'[Date]), -3, MONTH))",
                               filters: [y2024, month(3)]), 1500)
        // Rolling twelve months to March 2024: Apr 2023 … Mar 2024 = 40 + 50 + 60 + 300 + 300 + 900.
        XCTAssertEqual(try num("CALCULATE([Amt], DATESINPERIOD('Date'[Date], MAX('Date'[Date]), -12, MONTH))",
                               filters: [y2024, month(3)]), 1650)
        // A negative count ends on the start date; a positive count begins on it.
        XCTAssertEqual(try dates("DATESINPERIOD('Date'[Date], DATE(2024, 3, 1), -2, DAY)"), ["2024-02-29", "2024-03-01"])
        XCTAssertEqual(try dates("DATESINPERIOD('Date'[Date], DATE(2024, 1, 30), 3, DAY)"), ["2024-01-30", "2024-01-31", "2024-02-01"])
        XCTAssertEqual(try dates("DATESINPERIOD('Date'[Date], DATE(2024, 1, 15), 1, MONTH)"),
                       TimeSchemaTestCase.days("2024-01-15", "2024-02-14"))
        XCTAssertEqual(try dates("DATESINPERIOD('Date'[Date], DATE(2024, 3, 15), -1, MONTH)"),
                       TimeSchemaTestCase.days("2024-02-16", "2024-03-15"))
        // One year back from the leap day: 1 March 2023 … 29 February 2024 (366 days).
        XCTAssertEqual(try dates("DATESINPERIOD('Date'[Date], DATE(2024, 2, 29), -1, YEAR)"),
                       TimeSchemaTestCase.days("2023-03-01", "2024-02-29"))
        XCTAssertEqual(try num("COUNTROWS(DATESINPERIOD('Date'[Date], DATE(2024, 12, 31), -1, QUARTER))"), 92)
        // The period ignores the outer date filter (it is built from the whole date column).
        XCTAssertEqual(try num("CALCULATE([Amt], DATESINPERIOD('Date'[Date], DATE(2024, 1, 15), -15, DAY))", filters: [y2023]), 300)
    }

    func testDatesBetween() throws {
        XCTAssertEqual(try num("CALCULATE([Amt], DATESBETWEEN('Date'[Date], DATE(2024, 1, 1), DATE(2024, 1, 15)))", filters: [y2023]), 300)
        XCTAssertEqual(try num("CALCULATE([Amt], DATESBETWEEN('Date'[Date], DATE(2023, 12, 31), DATE(2024, 1, 1)))"), 160)
        // A blank boundary is open-ended.
        XCTAssertEqual(try num("CALCULATE([Amt], DATESBETWEEN('Date'[Date], BLANK(), DATE(2023, 6, 30)))"), 100)
        XCTAssertEqual(try num("CALCULATE([Amt], DATESBETWEEN('Date'[Date], DATE(2025, 2, 1), BLANK()))"), 5000)
        // Start after end: no dates.
        XCTAssertEqual(try dates("DATESBETWEEN('Date'[Date], DATE(2024, 2, 1), DATE(2024, 1, 1))"), [])
    }

    // MARK: PREVIOUS* / NEXT*

    func testPreviousPeriods() throws {
        XCTAssertEqual(try dates("PREVIOUSDAY('Date'[Date])", filters: [on("2024-03-01")]), ["2024-02-29"])
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSDAY('Date'[Date]))", filters: [on("2024-01-01")]), 60)
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSMONTH('Date'[Date]))", filters: [y2024, month(3)]), 300)
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSMONTH('Date'[Date]))", filters: [y2024, month(1)]), 60)
        // The previous period is relative to the first visible date: 20 March → all of February.
        XCTAssertEqual(try dates("PREVIOUSMONTH('Date'[Date])", filters: [on("2024-03-20")]),
                       TimeSchemaTestCase.days("2024-02-01", "2024-02-29"))
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSQUARTER('Date'[Date]))", filters: [y2024, quarter(2)]), 1500)
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSQUARTER('Date'[Date]))", filters: [y2024, quarter(1)]), 60)
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSYEAR('Date'[Date]))", filters: [y2024, month(3)]), 210)
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSYEAR('Date'[Date]))", filters: [y2025]), 4500)
        // Fiscal years ending 30 June: July 2024 is in FY 2025, so the previous year is
        // 1 July 2023 … 30 June 2024 = 50 + 60 + 300 + 300 + 900 + 600 + 700.
        XCTAssertEqual(try num("CALCULATE([Amt], PREVIOUSYEAR('Date'[Date], \"6/30\"))", filters: [y2024, month(7)]), 2910)
        // Before the first date of the table there is nothing.
        XCTAssertEqual(try dates("PREVIOUSDAY('Date'[Date])", filters: [on("2023-01-01")]), [])
        XCTAssertTrue(try scalar("CALCULATE([Amt], PREVIOUSYEAR('Date'[Date]))", filters: [y2023]).isNull)
    }

    func testNextPeriods() throws {
        XCTAssertEqual(try num("CALCULATE([Amt], NEXTDAY('Date'[Date]))", filters: [on("2024-02-28")]), 300)
        XCTAssertEqual(try dates("NEXTDAY('Date'[Date])", filters: [on("2025-12-31")]), [])
        XCTAssertEqual(try num("CALCULATE([Amt], NEXTMONTH('Date'[Date]))", filters: [y2024, month(3)]), 600)
        XCTAssertEqual(try num("CALCULATE([Amt], NEXTMONTH('Date'[Date]))", filters: [y2024, month(12)]), 1000)
        // Relative to the last visible date: 5 November 2024 → the first quarter of 2025 (90 days).
        XCTAssertEqual(try dates("NEXTQUARTER('Date'[Date])", filters: [on("2024-11-05")]),
                       TimeSchemaTestCase.days("2025-01-01", "2025-03-31"))
        XCTAssertEqual(try num("CALCULATE([Amt], NEXTQUARTER('Date'[Date]))", filters: [y2024, quarter(2)]), 800)
        XCTAssertEqual(try num("CALCULATE([Amt], NEXTYEAR('Date'[Date]))", filters: [y2024, month(3)]), 6000)
        XCTAssertEqual(try num("CALCULATE([Amt], NEXTYEAR('Date'[Date]))", filters: [y2023]), 4500)
    }

    // MARK: Period boundaries and balances

    func testStartAndEndOfPeriods() throws {
        XCTAssertEqual(try scalar("FIRSTDATE('Date'[Date])", filters: [y2024, month(3)]), StarSchema.day("2024-03-01"))
        XCTAssertEqual(try scalar("LASTDATE('Date'[Date])", filters: [y2024, month(2)]), StarSchema.day("2024-02-29"))
        // On the fact column: the last order of Q1 2024.
        XCTAssertEqual(try scalar("LASTDATE(Sales[OrderDate])", filters: [y2024, quarter(1)]), StarSchema.day("2024-03-31"))
        XCTAssertEqual(try scalar("FIRSTDATE(Sales[OrderDate])", filters: [y2024, quarter(2)]), StarSchema.day("2024-04-01"))
        XCTAssertEqual(try scalar("STARTOFMONTH('Date'[Date])", filters: [on("2024-05-17")]), StarSchema.day("2024-05-01"))
        XCTAssertEqual(try scalar("ENDOFMONTH('Date'[Date])", filters: [on("2024-02-10")]), StarSchema.day("2024-02-29"))
        XCTAssertEqual(try scalar("STARTOFQUARTER('Date'[Date])", filters: [y2024, month(5)]), StarSchema.day("2024-04-01"))
        XCTAssertEqual(try scalar("ENDOFQUARTER('Date'[Date])", filters: [y2024, month(5)]), StarSchema.day("2024-06-30"))
        XCTAssertEqual(try scalar("STARTOFYEAR('Date'[Date])", filters: [y2024, month(5)]), StarSchema.day("2024-01-01"))
        XCTAssertEqual(try scalar("ENDOFYEAR('Date'[Date])", filters: [y2024, month(5)]), StarSchema.day("2024-12-31"))
        XCTAssertEqual(try scalar("ENDOFYEAR('Date'[Date], \"6/30\")", filters: [y2024, month(5)]), StarSchema.day("2024-06-30"))
        XCTAssertEqual(try scalar("STARTOFYEAR('Date'[Date], \"6/30\")", filters: [y2024, month(5)]), StarSchema.day("2023-07-01"))
    }

    func testOpeningAndClosingBalances() throws {
        // The closing balance is the expression on the last date of the period; the opening
        // balance is the expression on the last date of the previous period.
        XCTAssertEqual(try num("CLOSINGBALANCEMONTH([Amt], 'Date'[Date])", filters: [y2024, month(3)]), 500)
        XCTAssertEqual(try num("OPENINGBALANCEMONTH([Amt], 'Date'[Date])", filters: [y2024, month(4)]), 500)
        // From any day of the month the balance is still read on the month's last day.
        XCTAssertEqual(try num("CLOSINGBALANCEMONTH([Amt], 'Date'[Date])", filters: [on("2024-03-05")]), 500)
        XCTAssertEqual(try num("CLOSINGBALANCEQUARTER([Amt], 'Date'[Date])", filters: [y2024, month(4)]), 700)
        XCTAssertEqual(try num("OPENINGBALANCEQUARTER([Amt], 'Date'[Date])", filters: [y2024, month(8)]), 700)
        XCTAssertEqual(try num("CLOSINGBALANCEYEAR([Amt], 'Date'[Date])", filters: [y2024, month(3)]), 900)
        XCTAssertEqual(try num("OPENINGBALANCEYEAR([Amt], 'Date'[Date])", filters: [y2025, month(2)]), 900)
        XCTAssertEqual(try num("OPENINGBALANCEYEAR([Amt], 'Date'[Date])", filters: [y2024]), 60)
        // 30 April 2024 has no sales.
        XCTAssertTrue(try scalar("CLOSINGBALANCEMONTH([Amt], 'Date'[Date])", filters: [y2024, month(4)]).isNull)
    }

    // MARK: Date-table semantics

    func testFilterOnTheDateColumnReplacesOtherDateFilters() throws {
        // A CALCULATE filter on the marked date column clears the filters on Year and MonthNo.
        XCTAssertEqual(try num("CALCULATE([Amt], 'Date'[Date] = DATE(2024, 1, 15))", filters: [y2023, month(6)]), 200)
        XCTAssertEqual(try num("CALCULATE([Amt], 'Date'[Date] >= DATE(2024, 1, 1) && 'Date'[Date] <= DATE(2024, 1, 15))", filters: [y2023]), 300)
        // KEEPFILTERS turns that off: the dates are intersected with 2023 → nothing.
        XCTAssertTrue(try scalar("CALCULATE([Amt], KEEPFILTERS('Date'[Date] = DATE(2024, 1, 15)))", filters: [y2023]).isNull)
        // A filter on another column of the date table does not clear its siblings: Q1 ∧ 2025.
        XCTAssertEqual(try num("CALCULATE([Amt], 'Date'[Year] = 2025)", filters: [y2024, quarter(1)]), 6000)
        XCTAssertTrue(try scalar("CALCULATE([Amt], 'Date'[Year] = 2025)", filters: [y2024, quarter(2)]).isNull)
    }

    func testNoVisibleDatesGivesBlank() throws {
        let none = filter("Date", "Year", 2030)
        XCTAssertTrue(try scalar("TOTALYTD([Amt], 'Date'[Date])", filters: [none]).isNull)
        XCTAssertTrue(try scalar("CALCULATE([Amt], SAMEPERIODLASTYEAR('Date'[Date]))", filters: [none]).isNull)
        XCTAssertTrue(try scalar("CALCULATE([Amt], PREVIOUSMONTH('Date'[Date]))", filters: [none]).isNull)
        XCTAssertTrue(try scalar("LASTDATE('Date'[Date])", filters: [none]).isNull)
    }
}
