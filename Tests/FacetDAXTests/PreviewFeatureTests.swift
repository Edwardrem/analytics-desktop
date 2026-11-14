import XCTest
import FacetCore
@testable import FacetDAX

/// Preview features (Settings ▸ Preview) the engine honours, over the time schema.
final class PreviewFeatureTests: TimeSchemaTestCase {
    private func load(_ features: DAXFeatures, userName: String = "",
                      configure: (inout SemanticModel, inout DataStore) -> Void = { _, _ in }) -> [String: String] {
        var m = TimeSchema.model(), d = TimeSchema.data()
        configure(&m, &d)
        engine = DAXEngine()
        engine.features = features
        return engine.load(model: m, data: d, userName: userName)
    }

    private func calendar(_ m: inout SemanticModel, _ d: inout DataStore) {
        m.tables[0].calendars = [CalendarDefinition(name: "Gregorian", columnsByUnit: ["date": "Date", "year": "Year", "month": "Month"])]
    }

    func testCalendarTimeIntelligenceCanBeTurnedOff() throws {
        _ = load(DAXFeatures(), configure: calendar)
        // On: 15 March 2024 back one week by the calendar is 8 March.
        XCTAssertEqual(try dates("DATEADD(Gregorian, -1, WEEK)", filters: [filter("Date", "Date", StarSchema.day("2024-03-15"))]), ["2024-03-08"])

        _ = load(DAXFeatures(calendarTimeIntelligence: false), configure: calendar)
        XCTAssertThrowsError(try dates("DATEADD(Gregorian, -1, WEEK)")) { error in
            XCTAssertTrue("\(error)".contains("calendar-based time intelligence"), "\(error)")
        }
        // Date columns are unaffected: March 2024 year to date is Jan 300 + Feb 300 + Mar 900.
        XCTAssertEqual(try num("TOTALYTD([Amt], 'Date'[Date])", filters: [filter("Date", "Year", 2024), filter("Date", "MonthNo", 3)]), 1500)
    }

    func testTextSearchCanBeTurnedOff() throws {
        _ = load(DAXFeatures())
        // East rows: 9 of the 18 sales.
        XCTAssertEqual(try num("COUNTROWS(FILTER(Sales, TEXTSEARCH(Sales[Region], \"east\")))"), 9)
        _ = load(DAXFeatures(textSearch: false))
        XCTAssertThrowsError(try num("COUNTROWS(FILTER(Sales, TEXTSEARCH(Sales[Region], \"east\")))")) { error in
            XCTAssertTrue("\(error)".contains("preview feature"), "\(error)")
        }
    }

    /// A calculated column of USERNAME() sees the View-as user only with user-context-aware calculated columns.
    func testCalculatedColumnsSeeTheViewAsUserOnlyWhenTurnedOn() throws {
        func addWho(_ m: inout SemanticModel, _ d: inout DataStore) {
            guard let i = m.tableIndex("Sales") else { return }
            m.tables[i].columns.append(ModelColumn(name: "Who", dataType: .text, expression: "USERNAME()"))
        }
        XCTAssertEqual(load(DAXFeatures(), userName: "Ann", configure: addWho), [:])
        XCTAssertEqual(try scalar("MAX(Sales[Who])"), .string("Ann"))
        XCTAssertEqual(try scalar("USERNAME()"), .string("Ann"))

        XCTAssertEqual(load(DAXFeatures(userContextColumns: false), userName: "Ann", configure: addWho), [:])
        XCTAssertEqual(try scalar("MAX(Sales[Who])"), .string(""), "computed as at refresh, without the View-as user")
        XCTAssertEqual(try scalar("USERNAME()"), .string("Ann"), "queries still see the View-as user")
    }
}
