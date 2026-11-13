import Foundation
import FacetCore

/// A date-like value split into its wall-clock instant and a way to rebuild the same kind of value.
struct MTemporal {
    enum Kind { case date, datetime, zone(Int) }
    var wall: Date
    var kind: Kind

    init?(_ v: MValue) {
        switch v {
        case .date(let d): wall = d; kind = .date
        case .datetime(let d): wall = d; kind = .datetime
        case .datetimezone(let d, let off): wall = d.addingTimeInterval(Double(off) * 60); kind = .zone(off)
        default: return nil
        }
    }
    /// A value of the same kind at another wall-clock instant.
    func make(_ w: Date) -> MValue {
        switch kind {
        case .date: return .date(MOps.dayFloor(w))
        case .datetime: return .datetime(w)
        case .zone(let off): return .datetimezone(w.addingTimeInterval(-Double(off) * 60), offsetMinutes: off)
        }
    }
    /// The last representable instant before `w` (for `EndOf…`); for dates, the day before.
    func makeEnd(before w: Date) -> MValue {
        if case .date = kind { return .date(MOps.dayFloor(w.addingTimeInterval(-86400))) }
        return make(Date(timeIntervalSince1970: w.timeIntervalSince1970.nextDown))
    }
}

/// Calendar arithmetic on wall-clock dates (stored as UTC).
enum MDate {
    enum Unit: String, CaseIterable { case second = "Second", minute = "Minute", hour = "Hour", day = "Day", week = "Week", month = "Month", quarter = "Quarter", year = "Year" }

    static func parts(_ d: Date) -> (year: Int, month: Int, day: Int) {
        let c = Calendar.utc.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? 1, c.month ?? 1, c.day ?? 1)
    }
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar.utc.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }
    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        Calendar.utc.range(of: .day, in: .month, for: date(y, m, 1))?.count ?? 30
    }
    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
    /// 0 = Sunday … 6 = Saturday.
    static func weekday(_ d: Date) -> Int { Calendar.utc.component(.weekday, from: d) - 1 }
    /// The culture's first day of the week (0 = Sunday).
    static func firstDay(culture: String) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = MConvert.locale(culture)
        return cal.firstWeekday - 1
    }
    static func addMonths(_ d: Date, _ n: Int) -> Date {
        let p = parts(d), time = d.timeIntervalSince(MOps.dayFloor(d))
        let total = p.year * 12 + (p.month - 1) + n
        let y = Int((Double(total) / 12).rounded(.down)), m = total - y * 12 + 1
        return date(y, m, min(p.day, daysInMonth(y, m))).addingTimeInterval(time)
    }
    static func start(_ unit: Unit, _ d: Date, firstDay: Int = 0) -> Date {
        let p = parts(d), t = d.timeIntervalSince1970
        switch unit {
        case .second: return Date(timeIntervalSince1970: t.rounded(.down))
        case .minute: return Date(timeIntervalSince1970: (t / 60).rounded(.down) * 60)
        case .hour: return Date(timeIntervalSince1970: (t / 3600).rounded(.down) * 3600)
        case .day: return MOps.dayFloor(d)
        case .week: return MOps.dayFloor(d).addingTimeInterval(-Double((weekday(d) - firstDay + 7) % 7) * 86400)
        case .month: return date(p.year, p.month, 1)
        case .quarter: return date(p.year, (p.month - 1) / 3 * 3 + 1, 1)
        case .year: return date(p.year, 1, 1)
        }
    }
    static func add(_ unit: Unit, _ n: Int, to d: Date) -> Date {
        switch unit {
        case .second: return d.addingTimeInterval(Double(n))
        case .minute: return d.addingTimeInterval(Double(n) * 60)
        case .hour: return d.addingTimeInterval(Double(n) * 3600)
        case .day: return d.addingTimeInterval(Double(n) * 86400)
        case .week: return d.addingTimeInterval(Double(n) * 7 * 86400)
        case .month: return addMonths(d, n)
        case .quarter: return addMonths(d, 3 * n)
        case .year: return addMonths(d, 12 * n)
        }
    }
    static func dayOfYear(_ d: Date) -> Int { Calendar.utc.ordinality(of: .day, in: .year, for: d) ?? 1 }
    /// Week number where week 1 contains the first day of the period and weeks start on `firstDay`.
    static func weekNumber(_ d: Date, periodStart: Date, firstDay: Int) -> Int {
        let dayIndex = Int((MOps.dayFloor(d).timeIntervalSince(periodStart) / 86400).rounded())
        return (dayIndex + (weekday(periodStart) - firstDay + 7) % 7) / 7 + 1
    }
}

extension MLibrary {
    /// Options of `X.FromText` / `X.ToText`: a culture or format text, or a record `[Format = …, Culture = …]`.
    static func formatOptions(_ a: MArgs, _ i: Int, textIsFormat: Bool, _ ctx: MInterpreter) throws -> (format: String?, culture: String) {
        var format: String?, culture = ctx.culture
        switch a[i] {
        case .text(let s): if textIsFormat { format = s } else { culture = s }
        case .record(let r):
            format = try r.text("Format")
            culture = try r.text("Culture") ?? culture
        case .null: break
        default: throw MError.typeMismatch(expected: "record", got: a[i])
        }
        if textIsFormat, let c = try a.optText(i + 1) { culture = c }
        return (format, culture)
    }
    /// A date-like argument, or nil when it is null.
    static func temporal(_ a: MArgs, _ i: Int) throws -> MTemporal? {
        if a[i].isNull { return nil }
        guard let t = MTemporal(a[i]) else { throw MError.typeMismatch(expected: "date", got: a[i]) }
        return t
    }
    /// Seconds since midnight of a time, datetime or datetimezone argument.
    static func timeOfDay(_ a: MArgs, _ i: Int) throws -> Double? {
        if a[i].isNull { return nil }
        if case .time(let t) = a[i] { return t }
        guard let t = MTemporal(a[i]) else { throw MError.typeMismatch(expected: "time", got: a[i]) }
        return t.wall.timeIntervalSince(MOps.dayFloor(t.wall))
    }
}
