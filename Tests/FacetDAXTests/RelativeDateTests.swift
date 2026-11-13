import XCTest
import FacetCore
@testable import FacetDAX

/// Relative date and relative time filters, with the engine clock pinned to
/// Friday 15 March 2024, 10:30 UTC. Amounts come from the time schema (see TimeSchemaFixture).
final class RelativeDateTests: TimeSchemaTestCase {
    private let now = DateParsing.parse("2024-03-15T10:30:00Z")
    private var savedClock: (() -> Date)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let pinned = try XCTUnwrap(now, "could not parse the pinned time")
        savedClock = PureDate.now
        PureDate.now = { pinned }
    }

    override func tearDown() {
        if let savedClock { PureDate.now = savedClock }
        super.tearDown()
    }

    private func relative(_ direction: RelativeDateFilter.Direction, _ count: Int, _ unit: RelativeDateFilter.Unit,
                          includeToday: Bool = true) -> RelativeDateFilter {
        var r = RelativeDateFilter()
        r.direction = direction; r.count = count; r.unit = unit; r.includeToday = includeToday
        return r
    }
    /// The window as "first day … last day" (inclusive), for whole-day windows.
    private func days(_ r: RelativeDateFilter) -> String {
        let w = RelativeDates.window(r)
        return "\(TimeSchemaTestCase.iso(w.lowerBound))…\(TimeSchemaTestCase.iso(w.upperBound.addingTimeInterval(-86400)))"
    }
    /// The amount under a relative date filter on the date table; nil when blank.
    private func amount(_ r: RelativeDateFilter) throws -> Double? {
        var spec = FilterSpec(field: .column("Date", "Date"), kind: .relativeDate)
        spec.relative = r
        let v = try scalar("[Amt]", filters: [spec])
        return v.isNull ? nil : v.asDouble
    }

    func testClockIsPinned() throws {
        XCTAssertEqual(try scalar("TODAY()"), StarSchema.day("2024-03-15"))
    }

    // MARK: Windows

    func testLastWindows() {
        XCTAssertEqual(days(relative(.last, 7, .days)), "2024-03-09…2024-03-15")
        XCTAssertEqual(days(relative(.last, 7, .days, includeToday: false)), "2024-03-08…2024-03-14")
        XCTAssertEqual(days(relative(.last, 1, .days)), "2024-03-15…2024-03-15")
        XCTAssertEqual(days(relative(.last, 1, .days, includeToday: false)), "2024-03-14…2024-03-14")
        XCTAssertEqual(days(relative(.last, 2, .weeks)), "2024-03-02…2024-03-15")
        XCTAssertEqual(days(relative(.last, 1, .months)), "2024-02-16…2024-03-15")
        XCTAssertEqual(days(relative(.last, 1, .months, includeToday: false)), "2024-02-15…2024-03-14")
        XCTAssertEqual(days(relative(.last, 1, .years)), "2023-03-16…2024-03-15")
    }

    func testCalendarWindowsAreWholePeriodsBeforeOrAfterTheCurrentOne() {
        // 15 March 2024 is a Friday; its week runs Sunday 10 to Saturday 16 March.
        XCTAssertEqual(days(relative(.last, 1, .calendarWeeks)), "2024-03-03…2024-03-09")
        XCTAssertEqual(days(relative(.last, 3, .calendarWeeks)), "2024-02-18…2024-03-09")
        XCTAssertEqual(days(relative(.last, 1, .calendarMonths)), "2024-02-01…2024-02-29")
        XCTAssertEqual(days(relative(.last, 2, .calendarMonths)), "2024-01-01…2024-02-29")
        XCTAssertEqual(days(relative(.last, 1, .calendarYears)), "2023-01-01…2023-12-31")
        XCTAssertEqual(days(relative(.next, 1, .calendarWeeks)), "2024-03-17…2024-03-23")
        XCTAssertEqual(days(relative(.next, 1, .calendarMonths)), "2024-04-01…2024-04-30")
        XCTAssertEqual(days(relative(.next, 2, .calendarYears)), "2025-01-01…2026-12-31")
        // "Include today" does not apply to whole periods.
        XCTAssertEqual(days(relative(.last, 1, .calendarMonths, includeToday: false)), "2024-02-01…2024-02-29")
    }

    func testThisWindows() {
        XCTAssertEqual(days(relative(.this, 1, .days)), "2024-03-15…2024-03-15")
        XCTAssertEqual(days(relative(.this, 1, .weeks)), "2024-03-10…2024-03-16")
        XCTAssertEqual(days(relative(.this, 1, .calendarWeeks)), "2024-03-10…2024-03-16")
        XCTAssertEqual(days(relative(.this, 1, .months)), "2024-03-01…2024-03-31")
        XCTAssertEqual(days(relative(.this, 1, .calendarMonths)), "2024-03-01…2024-03-31")
        XCTAssertEqual(days(relative(.this, 1, .years)), "2024-01-01…2024-12-31")
    }

    func testNextWindows() {
        XCTAssertEqual(days(relative(.next, 7, .days)), "2024-03-15…2024-03-21")
        XCTAssertEqual(days(relative(.next, 7, .days, includeToday: false)), "2024-03-16…2024-03-22")
        XCTAssertEqual(days(relative(.next, 3, .weeks)), "2024-03-15…2024-04-04")
        XCTAssertEqual(days(relative(.next, 1, .months, includeToday: false)), "2024-03-16…2024-04-15")
        XCTAssertEqual(days(relative(.next, 1, .years)), "2024-03-15…2025-03-14")
    }

    func testRelativeTimeWindows() throws {
        let pinned = try XCTUnwrap(now)
        let lastTwoHours = RelativeDates.window(relative(.last, 2, .hours))
        XCTAssertEqual(lastTwoHours.lowerBound, pinned.addingTimeInterval(-7200))
        XCTAssertTrue(lastTwoHours.contains(pinned))
        XCTAssertFalse(lastTwoHours.contains(pinned.addingTimeInterval(1)))
        let nextThirty = RelativeDates.window(relative(.next, 30, .minutes))
        XCTAssertEqual(nextThirty.lowerBound, pinned)
        XCTAssertTrue(nextThirty.contains(pinned.addingTimeInterval(1800)))
        XCTAssertFalse(nextThirty.contains(pinned.addingTimeInterval(1801)))
        // This hour: 10:00 up to, not including, 11:00.
        let thisHour = RelativeDates.window(relative(.this, 1, .hours))
        XCTAssertEqual(thisHour.lowerBound, pinned.addingTimeInterval(-1800))
        XCTAssertEqual(thisHour.upperBound, pinned.addingTimeInterval(1800))
        // The window can be evaluated at any instant.
        let other = try XCTUnwrap(DateParsing.parse("2025-01-01"))
        XCTAssertEqual(RelativeDates.window(relative(.last, 1, .calendarYears), now: other).lowerBound, DateParsing.parse("2024-01-01"))
    }

    // MARK: As a filter

    func testRelativeDateFilterOnTheDateTable() throws {
        // Sales near the pinned day: 29 Feb 300, 15 Mar 400, 31 Mar 500, 1 Apr 600.
        XCTAssertEqual(try amount(relative(.last, 7, .days)), 400)
        XCTAssertNil(try amount(relative(.last, 7, .days, includeToday: false)))
        XCTAssertEqual(try amount(relative(.last, 3, .weeks)), 700)
        XCTAssertEqual(try amount(relative(.last, 1, .months)), 700)
        // 16 Dec 2023 … 15 Mar 2024: 60 + 100 + 200 + 300 + 400.
        XCTAssertEqual(try amount(relative(.last, 3, .months)), 1060)
        XCTAssertEqual(try amount(relative(.last, 1, .calendarMonths)), 300)
        XCTAssertEqual(try amount(relative(.last, 2, .calendarMonths)), 600)
        XCTAssertNil(try amount(relative(.last, 1, .calendarWeeks)))
        XCTAssertEqual(try amount(relative(.last, 3, .calendarWeeks)), 300)
        // 16 Mar 2023 … 15 Mar 2024: 30 + 40 + 50 + 60 + 100 + 200 + 300 + 400.
        XCTAssertEqual(try amount(relative(.last, 1, .years)), 1180)
        XCTAssertEqual(try amount(relative(.last, 1, .calendarYears)), 210)
        XCTAssertEqual(try amount(relative(.this, 1, .days)), 400)
        XCTAssertEqual(try amount(relative(.this, 1, .weeks)), 400)
        XCTAssertEqual(try amount(relative(.this, 1, .months)), 900)
        XCTAssertEqual(try amount(relative(.this, 1, .years)), 4500)
        XCTAssertEqual(try amount(relative(.next, 7, .days)), 400)
        XCTAssertNil(try amount(relative(.next, 7, .days, includeToday: false)))
        XCTAssertEqual(try amount(relative(.next, 3, .weeks)), 1500)
        XCTAssertEqual(try amount(relative(.next, 1, .months, includeToday: false)), 1100)
        XCTAssertEqual(try amount(relative(.next, 1, .calendarMonths)), 600)
        XCTAssertEqual(try amount(relative(.next, 1, .calendarYears)), 6000)
    }

    func testRelativeDateFilterOnAFactColumnAndWithOtherFilters() throws {
        var spec = FilterSpec(field: .column("Sales", "OrderDate"), kind: .relativeDate)
        spec.relative = relative(.last, 3, .months)
        XCTAssertEqual(try num("[Amt]", filters: [spec]), 1060)
        XCTAssertEqual(try num("[Orders]", filters: [spec]), 5)
        // Combined with a region filter: East in the window is 100 + 300.
        XCTAssertEqual(try num("[Amt]", filters: [spec, filter("Sales", "Region", "East")]), 400)
    }
}
