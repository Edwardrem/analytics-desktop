import XCTest
import FacetCore
@testable import FacetDAX

/// Auto date/time over the time schema (see `TimeSchemaFixture`): hidden Year › Quarter › Month › Day
/// levels exist only when the model's option is on, only for imported, unmarked tables, and never for
/// the many side of a relationship (Power BI's documented conditions).
final class AutoDateTimeTests: TimeSchemaTestCase {
    /// The time schema with auto date/time on and Sales no longer related to Date, so Sales[OrderDate] qualifies.
    private func useAutoDateTime(culture: String = "en-US", keepRelationship: Bool = false) {
        engine = TimeSchema.makeEngine { m, _ in
            m.autoDateTime = true
            m.culture = culture
            if !keepRelationship { m.relationships = [] }
        }
    }

    /// Group → value from a two-column result (group first).
    private func totals(_ dax: String, filters: [FilterSpec] = []) throws -> [String: Double] {
        let t = try table(dax, filters: filters)
        XCTAssertEqual(t.columnCount, 2)
        var out: [String: Double] = [:]
        for r in 0..<t.rowCount { out[t[r, 0].asString] = t[r, 1].asDouble }
        return out
    }

    func testLevelsDoNotExistWhenTheOptionIsOff() {
        engine = TimeSchema.makeEngine { m, _ in m.relationships = [] }
        XCTAssertThrowsError(try scalar("MIN('Sales'[OrderDate].[Year])"))
    }

    func testYearLevelGroupsTheColumnsRows() throws {
        useAutoDateTime()
        let byYear = try totals("EVALUATE SUMMARIZECOLUMNS('Sales'[OrderDate].[Year], \"Amt\", [Amt])")
        XCTAssertEqual(byYear, ["2023": 210, "2024": 4500, "2025": 6000])
    }

    func testQuarterAndMonthAreNamedAndNumbered() throws {
        useAutoDateTime()
        let y2024 = [filterLevel("Year", .int(2024))]
        let byQuarter = try totals("EVALUATE SUMMARIZECOLUMNS('Sales'[OrderDate].[Quarter], \"Amt\", [Amt])", filters: y2024)
        XCTAssertEqual(byQuarter, ["Qtr 1": 1500, "Qtr 2": 1300, "Qtr 3": 800, "Qtr 4": 900])
        XCTAssertEqual(try num("CALCULATE([Amt], 'Sales'[OrderDate].[Month] = \"March\")", filters: y2024), 900)
        XCTAssertEqual(try num("CALCULATE([Amt], 'Sales'[OrderDate].[MonthNo] = 3)", filters: y2024), 900)
        XCTAssertEqual(try num("CALCULATE([Amt], 'Sales'[OrderDate].[QuarterNo] = 2)", filters: y2024), 1300)
        XCTAssertEqual(try num("CALCULATE([Amt], 'Sales'[OrderDate].[Day] = 31)", filters: y2024), 500 + 900)
    }

    func testMonthNamesFollowTheModelLanguage() throws {
        useAutoDateTime(culture: "fr-FR")
        XCTAssertEqual(try num("CALCULATE([Amt], 'Sales'[OrderDate].[Month] = \"mars\")", filters: [filterLevel("Year", .int(2024))]), 900)
    }

    func testManySideAndMarkedDateTablesGetNoHierarchy() {
        useAutoDateTime(keepRelationship: true)
        XCTAssertThrowsError(try scalar("MIN('Sales'[OrderDate].[Year])"), "Sales[OrderDate] is the many side of Sales → Date")
        XCTAssertThrowsError(try scalar("MIN('Date'[Date].[Year])"), "Date is marked as the date table")
    }

    func testDirectQueryTablesGetNoHierarchy() {
        engine = TimeSchema.makeEngine { m, _ in
            m.autoDateTime = true
            m.relationships = []
            if let i = m.tableIndex("Sales") { m.tables[i].storageMode = .directQuery }
        }
        XCTAssertThrowsError(try scalar("MIN('Sales'[OrderDate].[Year])"))
    }

    func testTableExpressionsAndTheDataStoreLeaveTheLevelsOut() throws {
        useAutoDateTime()
        XCTAssertEqual(try table("EVALUATE 'Sales'").columns.count, 3)
        XCTAssertEqual(engine.data["Sales"]?.columns.map(\.name), ["OrderDate", "Region", "Amount"])
        let columns = try column("EVALUATE INFO.COLUMNS()", name: "Name").map(\.asString)
        XCTAssertFalse(columns.contains { $0.contains(".") }, "INFO.COLUMNS lists hierarchy levels: \(columns)")
    }

    func testCalendarAutoStillSeesDateColumns() throws {
        useAutoDateTime()
        // Sales and Date span 2023-01-01 … 2025-12-31: three whole calendar years.
        XCTAssertEqual(try table("EVALUATE CALENDARAUTO()").rowCount, 365 + 366 + 365)
    }

    func testReportFieldsReachTheLevel() throws {
        useAutoDateTime()
        let year = FieldRef.dateLevel("Sales", "OrderDate", "Year")
        XCTAssertEqual(Set(engine.distinctValues(field: year, filters: []).compactMap(\.asInt)), [2023, 2024, 2025])
        XCTAssertEqual(try num("[Amt]", filters: [filterLevel("Year", .int(2025))]), 6000)
        let selection = DataPointSelection(fields: [year], values: [.int(2023)])
        XCTAssertEqual(try column("EVALUATE ROW(\"Amt\", [Amt])", name: "Amt", crossFilters: [[selection]]).first?.asDouble, 210)
    }

    func testCalculatedColumnsCanUseTheLevels() throws {
        engine = TimeSchema.makeEngine { m, _ in
            m.autoDateTime = true
            m.relationships = []
            if let i = m.tableIndex("Sales") {
                m.tables[i].columns.append(ModelColumn(name: "OrderYear", dataType: .integer, expression: "'Sales'[OrderDate].[Year]"))
            }
        }
        // 6 orders each in 2023, 2024 (9 orders) and 2025 (3 orders): 6×2023 + 9×2024 + 3×2025.
        XCTAssertEqual(try num("SUM('Sales'[OrderYear])"), Double(6 * 2023 + 9 * 2024 + 3 * 2025))
    }

    func testEligibleColumns() {
        var m = TimeSchema.model()
        XCTAssertTrue(AutoDateTime.eligibleColumns(in: m).isEmpty, "off by default")
        m.autoDateTime = true
        XCTAssertTrue(AutoDateTime.eligibleColumns(in: m).isEmpty, "many side and marked date table only")
        m.relationships = []
        XCTAssertEqual(AutoDateTime.eligibleColumns(in: m).map { "\($0.table)[\($0.column)]" }, ["Sales[OrderDate]"])
    }

    private func filterLevel(_ level: String, _ value: Value) -> FilterSpec {
        var spec = FilterSpec(field: .dateLevel("Sales", "OrderDate", level))
        spec.values = [value]
        return spec
    }
}
