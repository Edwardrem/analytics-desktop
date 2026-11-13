import XCTest
import FacetCore
@testable import FacetDAX

/// Fixture for time intelligence, window functions and calculation groups: a contiguous,
/// marked date table over three full years and a small sales fact.
///
/// Tables:
/// - `Date`: one row per day from 2023-01-01 to 2025-12-31 (1096 rows; 2024 is a leap year), with
///   `Year`, `Quarter` (1–4), `MonthNo` (1–12) and `Month` ("2024-03"). Marked as the date table.
/// - `Sales` (18 rows): `OrderDate`, `Region`, `Amount`; related to `Date` on the date itself.
///
/// Sales rows (date, region, amount):
/// ```
/// 2023-01-15 East   10    2024-01-01 East  100    2024-06-30 East   700
/// 2023-02-28 West   20    2024-01-15 West  200    2024-07-01 West   800
/// 2023-03-31 East   30    2024-02-29 East  300    2024-12-31 East   900
/// 2023-06-30 West   40    2024-03-15 West  400    2025-01-10 West  1000
/// 2023-07-01 East   50    2024-03-31 East  500    2025-02-28 East  2000
/// 2023-12-31 West   60    2024-04-01 West  600    2025-03-01 West  3000
/// ```
/// Hand-computed totals:
/// - 2023: Jan 10, Feb 20, Mar 30, Jun 40, Jul 50, Dec 60 → 210 (Q1 60, Q2 40, Q3 50, Q4 60).
/// - 2024: Jan 300, Feb 300, Mar 900, Apr 600, Jun 700, Jul 800, Dec 900 → 4500
///   (Q1 1500, Q2 1300, Q3 800, Q4 900).
/// - 2025: Jan 1000, Feb 2000, Mar 3000 → 6000 (all in Q1). Grand total 10710.
/// - East: 2023 90, 2024 2500, 2025 2000 → 4590. West: 2023 120, 2024 2000, 2025 4000 → 6120.
enum TimeSchema {
    static let sales: [(date: String, region: String, amount: Int)] = [
        ("2023-01-15", "East", 10), ("2023-02-28", "West", 20), ("2023-03-31", "East", 30),
        ("2023-06-30", "West", 40), ("2023-07-01", "East", 50), ("2023-12-31", "West", 60),
        ("2024-01-01", "East", 100), ("2024-01-15", "West", 200), ("2024-02-29", "East", 300),
        ("2024-03-15", "West", 400), ("2024-03-31", "East", 500), ("2024-04-01", "West", 600),
        ("2024-06-30", "East", 700), ("2024-07-01", "West", 800), ("2024-12-31", "East", 900),
        ("2025-01-10", "West", 1000), ("2025-02-28", "East", 2000), ("2025-03-01", "West", 3000),
    ]

    static func model() -> SemanticModel {
        var date = ModelTable(name: "Date", columns: [
            ModelColumn(name: "Date", dataType: .date),
            ModelColumn(name: "Year", dataType: .integer),
            ModelColumn(name: "Quarter", dataType: .integer),
            ModelColumn(name: "MonthNo", dataType: .integer),
            ModelColumn(name: "Month", dataType: .text),
        ])
        date.dateColumn = "Date"
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "OrderDate", dataType: .date),
            ModelColumn(name: "Region", dataType: .text),
            ModelColumn(name: "Amount", dataType: .integer),
        ])
        sales.measures = [
            Measure(name: "Amt", expression: "SUM(Sales[Amount])", formatString: "#,0"),
            Measure(name: "Orders", expression: "COUNTROWS(Sales)", formatString: "0"),
        ]
        var model = SemanticModel()
        model.tables = [date, sales]
        model.relationships = [
            Relationship(fromTable: "Sales", fromColumn: "OrderDate", toTable: "Date", toColumn: "Date"),
        ]
        return model
    }

    static func data() -> DataStore {
        let calendar = Calendar.utc
        var rows: [[Value]] = []
        var day = StarSchema.day("2023-01-01")
        let end = StarSchema.day("2025-12-31")
        while case .date(let d) = day, case .date(let last) = end, d <= last {
            let c = calendar.dateComponents([.year, .month], from: d)
            let year = c.year ?? 0, month = c.month ?? 0
            rows.append([.date(d), .int(Int64(year)), .int(Int64((month - 1) / 3 + 1)), .int(Int64(month)),
                         .string(String(format: "%04d-%02d", year, month))])
            day = .date(d.addingTimeInterval(86400))
        }
        let date = DataTable(name: "Date", columnNames: ["Date", "Year", "Quarter", "MonthNo", "Month"], rows: rows,
                             types: [.date, .integer, .integer, .integer, .text])
        let fact = DataTable(name: "Sales", columnNames: ["OrderDate", "Region", "Amount"],
                             rows: sales.map { [StarSchema.day($0.date), .string($0.region), .int(Int64($0.amount))] },
                             types: [.date, .text, .integer])
        return DataStore(tables: [date.name: date, fact.name: fact])
    }

    /// Adds two calculation groups:
    /// - `Time Calc`[Calc] (precedence 20): Current, YTD, PY, YoY % (formatted "0.0%"), Name.
    /// - `Averages`[Average] (precedence 10): Total, Per Day (formatted "0.00"), Orders Only,
    ///   In K (format: the measure's own format string followed by "K").
    static func addCalculationGroups(_ model: inout SemanticModel, _ data: inout DataStore,
                                     timePrecedence: Int = 20, averagePrecedence: Int = 10) {
        func group(_ table: String, _ column: String, _ precedence: Int,
                   _ items: [(name: String, expression: String, format: String?)]) {
            var g = CalculationGroup(name: table)
            g.columnName = column
            g.precedence = precedence
            g.items = items.enumerated().map { i, item in
                var ci = CalculationItem(name: item.name, expression: item.expression)
                ci.formatExpression = item.format
                ci.ordinal = i
                return ci
            }
            // The engine creates the group's one-column table itself.
            model.calculationGroups.append(g)
        }
        let py = "CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR('Date'[Date]))"
        group("Time Calc", "Calc", timePrecedence, [
            ("Current", "SELECTEDMEASURE()", nil),
            ("YTD", "CALCULATE(SELECTEDMEASURE(), DATESYTD('Date'[Date]))", nil),
            ("PY", py, nil),
            ("YoY %", "DIVIDE(SELECTEDMEASURE() - \(py), \(py))", "\"0.0%\""),
            ("Name", "SELECTEDMEASURENAME()", nil),
        ])
        group("Averages", "Average", averagePrecedence, [
            ("Total", "SELECTEDMEASURE()", nil),
            ("Per Day", "DIVIDE(SELECTEDMEASURE(), COUNTROWS('Date'))", "\"0.00\""),
            ("Orders Only", "IF(ISSELECTEDMEASURE([Orders]), SELECTEDMEASURE(), -1)", nil),
            ("In K", "SELECTEDMEASURE() / 1000", "SELECTEDMEASUREFORMATSTRING() & \"K\""),
        ])
    }

    /// A fresh engine with the time schema loaded; `configure` may extend the model first.
    static func makeEngine(roles: [String] = [], userName: String = "",
                           configure: (inout SemanticModel, inout DataStore) -> Void = { _, _ in }) -> DAXEngine {
        var m = model(), d = data()
        configure(&m, &d)
        let engine = DAXEngine()
        let errors = engine.load(model: m, data: d, roles: roles, userName: userName)
        if !errors.isEmpty { XCTFail("fixture failed to load: \(errors)") }
        return engine
    }
}

/// Base class of the suites over the time schema.
class TimeSchemaTestCase: StarSchemaTestCase {
    override func setUpWithError() throws {
        engine = TimeSchema.makeEngine()
    }

    /// The dates of a date-table expression as "yyyy-MM-dd" strings, ascending.
    func dates(_ expression: String, filters: [FilterSpec] = []) throws -> [String] {
        let result = try table("EVALUATE \(expression)", filters: filters)
        let column = try XCTUnwrap(result.columns.first, "no column")
        return column.values.compactMap(\.asDate).sorted().map(TimeSchemaTestCase.iso)
    }

    static func iso(_ d: Date) -> String {
        let c = Calendar.utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Every day from `first` to `last` inclusive as "yyyy-MM-dd".
    static func days(_ first: String, _ last: String) -> [String] {
        guard case .date(var d) = StarSchema.day(first), case .date(let end) = StarSchema.day(last) else { return [] }
        var out: [String] = []
        while d <= end { out.append(iso(d)); d = d.addingTimeInterval(86400) }
        return out
    }
}
