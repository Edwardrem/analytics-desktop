import Foundation
import FacetCore

/// The date window of a relative date or relative time filter ("in the last 7 days",
/// "in this month", "in the next 2 calendar weeks"), as Power BI defines them.
public enum RelativeDates {
    /// The half-open window `[lower, upper)` in UTC for a filter evaluated at `now`.
    ///
    /// - Days, weeks, months and years count back or forward from today. "Include today" decides
    ///   whether a *last* window ends with today or yesterday, and whether a *next* window starts
    ///   today or tomorrow: last 7 days including today is today and the six days before it.
    /// - Calendar weeks (starting Sunday), months and years are whole periods and never include
    ///   the current one: the last calendar month is the month before this one.
    /// - *This* is the current day, week, month or year (or the current minute or hour).
    /// - Minutes and hours are measured from the current instant.
    /// Without `now`, the engine's clock (the one TODAY and NOW use) is read.
    public static func window(_ filter: RelativeDateFilter, now: Date? = nil) -> Range<Date> {
        let now = now ?? PureDate.now()
        var cal = Calendar.utc
        cal.firstWeekday = 1   // calendar weeks start on Sunday whatever the locale
        let count = max(0, filter.count)
        func add(_ component: Calendar.Component, _ n: Int, to d: Date) -> Date { cal.date(byAdding: component, value: n, to: d) ?? d }
        func start(of component: Calendar.Component, _ d: Date) -> Date { cal.dateInterval(of: component, for: d)?.start ?? d }

        // Relative time: measured from the current instant.
        if filter.unit == .minutes || filter.unit == .hours {
            let component: Calendar.Component = filter.unit == .minutes ? .minute : .hour
            switch filter.direction {
            case .this:
                let lower = start(of: component, now)
                return lower..<add(component, 1, to: lower)
            case .last: return add(component, -count, to: now)..<now.addingTimeInterval(0.001)
            case .next: return now..<add(component, count, to: now).addingTimeInterval(0.001)
            }
        }

        let today = cal.startOfDay(for: now)
        let period: Calendar.Component
        switch filter.unit {
        case .weeks, .calendarWeeks: period = .weekOfYear
        case .months, .calendarMonths: period = .month
        case .years, .calendarYears: period = .year
        default: period = .day
        }
        let wholePeriods = filter.unit == .calendarWeeks || filter.unit == .calendarMonths || filter.unit == .calendarYears
        /// Shifts a day by `n` units of the filter (weeks as seven days).
        func shift(_ d: Date, _ n: Int) -> Date {
            period == .weekOfYear ? add(.day, 7 * n, to: d) : add(period, n, to: d)
        }
        switch filter.direction {
        case .this:
            let lower = start(of: period, today)
            return lower..<shift(lower, 1)
        case .last:
            let upper = wholePeriods ? start(of: period, today) : (filter.includeToday ? add(.day, 1, to: today) : today)
            return shift(upper, -count)..<upper
        case .next:
            let lower = wholePeriods ? shift(start(of: period, today), 1) : (filter.includeToday ? today : add(.day, 1, to: today))
            return lower..<shift(lower, count)
        }
    }
}
