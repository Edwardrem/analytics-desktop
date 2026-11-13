import Foundation
import FacetCore

extension MLibrary {
    static func registerDateTime(_ lib: MLibrary) {
        lib.enumeration("Day", [("Sunday", 0), ("Monday", 1), ("Tuesday", 2), ("Wednesday", 3), ("Thursday", 4), ("Friday", 5), ("Saturday", 6)])

        /// Functions of one date-like value; null in, null out.
        func part(_ name: String, _ arity: ClosedRange<Int> = 1...1, _ f: @escaping (MTemporal, MArgs, MInterpreter) throws -> MValue) {
            lib.fn(name, arity) { a, ctx in try temporal(a, 0).map { try f($0, a, ctx) } ?? .null }
        }
        func firstDay(_ a: MArgs, _ i: Int, _ ctx: MInterpreter) throws -> Int {
            try a.optInt(i).map { (($0 % 7) + 7) % 7 } ?? MDate.firstDay(culture: ctx.culture)
        }

        // MARK: Date parts
        part("Date.Year") { t, _, _ in .int(MDate.parts(t.wall).year) }
        part("Date.Month") { t, _, _ in .int(MDate.parts(t.wall).month) }
        part("Date.Day") { t, _, _ in .int(MDate.parts(t.wall).day) }
        part("Date.QuarterOfYear") { t, _, _ in .int((MDate.parts(t.wall).month - 1) / 3 + 1) }
        part("Date.DayOfYear") { t, _, _ in .int(MDate.dayOfYear(t.wall)) }
        part("Date.DaysInMonth") { t, _, _ in let p = MDate.parts(t.wall); return .int(MDate.daysInMonth(p.year, p.month)) }
        part("Date.IsLeapYear") { t, _, _ in .logical(MDate.isLeap(MDate.parts(t.wall).year)) }
        part("Date.DayOfWeek", 1...2) { t, a, ctx in .int((MDate.weekday(t.wall) - (try firstDay(a, 1, ctx)) + 7) % 7) }
        part("Date.WeekOfYear", 1...2) { t, a, ctx in
            .int(MDate.weekNumber(t.wall, periodStart: MDate.start(.year, t.wall), firstDay: try firstDay(a, 1, ctx)))
        }
        part("Date.WeekOfMonth", 1...2) { t, a, ctx in
            .int(MDate.weekNumber(t.wall, periodStart: MDate.start(.month, t.wall), firstDay: try firstDay(a, 1, ctx)))
        }
        part("Date.MonthName", 1...2) { t, a, ctx in .text(MConvert.formatDate(t.wall, format: "MMMM", culture: try a.optText(1) ?? ctx.culture)) }
        part("Date.DayOfWeekName", 1...2) { t, a, ctx in .text(MConvert.formatDate(t.wall, format: "dddd", culture: try a.optText(1) ?? ctx.culture)) }
        part("Date.ToRecord") { t, _, _ in
            let p = MDate.parts(t.wall)
            return .record(MRecord(names: ["Year", "Month", "Day"], values: [.int(p.year), .int(p.month), .int(p.day)]))
        }

        // MARK: Start / end of period, shifting
        for unit in [MDate.Unit.day, .week, .month, .quarter, .year] {
            part("Date.StartOf\(unit.rawValue)", 1...2) { t, a, ctx in
                t.make(MDate.start(unit, t.wall, firstDay: unit == .week ? try firstDay(a, 1, ctx) : 0))
            }
            part("Date.EndOf\(unit.rawValue)", 1...2) { t, a, ctx in
                let start = MDate.start(unit, t.wall, firstDay: unit == .week ? try firstDay(a, 1, ctx) : 0)
                return t.makeEnd(before: MDate.add(unit, 1, to: start))
            }
            part("Date.Add\(unit.rawValue)s", 2...2) { t, a, _ in t.make(MDate.add(unit, try a.int(1), to: t.wall)) }
        }

        // MARK: Relative-date tests
        func relative(_ prefix: String, _ unit: MDate.Unit) {
            func window(_ ctx: MInterpreter, _ from: Int, _ to: Int, _ a: MArgs) throws -> (Date, Date) {
                let start = MDate.start(unit, ctx.environment.localNow(), firstDay: unit == .week ? try firstDay(a, 99, ctx) : 0)
                return (MDate.add(unit, from, to: start), MDate.add(unit, to, to: start))
            }
            func test(_ name: String, _ arity: ClosedRange<Int>, _ bounds: @escaping (MArgs) throws -> (Int, Int)) {
                part(name, arity) { t, a, ctx in
                    let (from, to) = try bounds(a)
                    let (lo, hi) = try window(ctx, from, to, a)
                    return .logical(t.wall >= lo && t.wall < hi)
                }
            }
            let u = unit.rawValue
            test("\(prefix).IsInCurrent\(u)", 1...1) { _ in (0, 1) }
            test("\(prefix).IsInPrevious\(u)", 1...1) { _ in (-1, 0) }
            test("\(prefix).IsInNext\(u)", 1...1) { _ in (1, 2) }
            test("\(prefix).IsInPreviousN\(u)s", 2...2) { a in (-(try MLib.index(a, 1)), 0) }
            test("\(prefix).IsInNextN\(u)s", 2...2) { a in (1, 1 + (try MLib.index(a, 1))) }
        }
        for unit in [MDate.Unit.day, .week, .month, .quarter, .year] { relative("Date", unit) }
        for unit in [MDate.Unit.second, .minute, .hour] { relative("DateTime", unit) }
        part("Date.IsInYearToDate") { t, _, ctx in
            let now = ctx.environment.localNow()
            return .logical(t.wall >= MDate.start(.year, now) && t.wall < MDate.add(.day, 1, to: MDate.start(.day, now)))
        }

        // MARK: Conversion
        lib.fn("Date.From", 1...2) { a, ctx in try MConvert.toDate(a[0], culture: try a.optText(1) ?? ctx.culture) }
        lib.fn("DateTime.From", 1...2) { a, ctx in try MConvert.toDateTime(a[0], culture: try a.optText(1) ?? ctx.culture) }
        lib.fn("DateTimeZone.From", 1...2) { a, ctx in try MConvert.toDateTimeZone(a[0], culture: try a.optText(1) ?? ctx.culture) }
        lib.fn("Time.From", 1...2) { a, ctx in try MConvert.toTime(a[0], culture: try a.optText(1) ?? ctx.culture) }
        lib.fn("Duration.From", 1) { a, _ in try MConvert.toDuration(a[0]) }
        func fromText(_ name: String, _ convert: @escaping (MValue, String?, String?) throws -> MValue) {
            lib.fn(name, 1...2) { a, ctx in
                if a[0].isNull { return .null }
                _ = try a.text(0)
                let o = try formatOptions(a, 1, textIsFormat: false, ctx)
                return try convert(a[0], o.culture, o.format)
            }
        }
        fromText("Date.FromText") { try MConvert.toDate($0, culture: $1, format: $2) }
        fromText("DateTime.FromText") { try MConvert.toDateTime($0, culture: $1, format: $2) }
        fromText("DateTimeZone.FromText") { try MConvert.toDateTimeZone($0, culture: $1, format: $2) }
        fromText("Time.FromText") { try MConvert.toTime($0, culture: $1, format: $2) }
        lib.fn("Duration.FromText", 1) { a, _ in a[0].isNull ? .null : try MConvert.toDuration(.text(try a.text(0))) }
        for name in ["Date.ToText", "DateTime.ToText", "DateTimeZone.ToText", "Time.ToText"] {
            lib.fn(name, 1...3) { a, ctx in
                let o = try formatOptions(a, 1, textIsFormat: true, ctx)
                return try MConvert.toText(a[0], culture: o.culture, format: o.format)
            }
        }
        lib.fn("Duration.ToText", 1...2) { a, _ in try MConvert.toText(a[0]) }

        // MARK: DateTime / DateTimeZone
        lib.fn("DateTime.LocalNow", 0) { _, ctx in .datetime(ctx.environment.localNow()) }
        lib.fn("DateTime.FixedLocalNow", 0) { _, ctx in .datetime(ctx.environment.localNow()) }
        func zoneNow(_ name: String, utc: Bool) {
            lib.fn(name, 0) { _, ctx in
                let now = ctx.now()
                return .datetimezone(now, offsetMinutes: utc ? 0 : ctx.environment.timeZone.secondsFromGMT(for: now) / 60)
            }
        }
        zoneNow("DateTimeZone.LocalNow", utc: false); zoneNow("DateTimeZone.FixedLocalNow", utc: false)
        zoneNow("DateTimeZone.UtcNow", utc: true); zoneNow("DateTimeZone.FixedUtcNow", utc: true)
        part("DateTime.Date") { t, _, _ in .date(MOps.dayFloor(t.wall)) }
        part("DateTime.Time") { t, _, _ in .time(t.wall.timeIntervalSince(MOps.dayFloor(t.wall))) }
        part("DateTime.ToRecord") { t, _, _ in
            let p = MDate.parts(t.wall), s = t.wall.timeIntervalSince(MOps.dayFloor(t.wall))
            return .record(MRecord(names: ["Year", "Month", "Day", "Hour", "Minute", "Second"],
                                   values: [.int(p.year), .int(p.month), .int(p.day), .int(Int(s / 3600)), .int(Int(s / 60) % 60),
                                            .number(s.truncatingRemainder(dividingBy: 60))]))
        }
        lib.fn("DateTime.AddZone", 2...3) { a, _ in
            guard let t = try temporal(a, 0) else { return .null }
            let off = try a.int(1) * 60 + (try a.optInt(2) ?? 0)
            return .datetimezone(t.wall.addingTimeInterval(-Double(off) * 60), offsetMinutes: off)
        }
        func zoned(_ name: String, _ arity: ClosedRange<Int>, _ f: @escaping (Date, Int, MArgs, MInterpreter) throws -> MValue) {
            lib.fn(name, arity) { a, ctx in
                if a[0].isNull { return .null }
                guard case .datetimezone(let d, let off) = a[0] else { throw MError.typeMismatch(expected: "datetimezone", got: a[0]) }
                return try f(d, off, a, ctx)
            }
        }
        zoned("DateTimeZone.SwitchZone", 2...3) { d, _, a, _ in .datetimezone(d, offsetMinutes: try a.int(1) * 60 + (try a.optInt(2) ?? 0)) }
        zoned("DateTimeZone.RemoveZone", 1...1) { d, off, _, _ in .datetime(d.addingTimeInterval(Double(off) * 60)) }
        zoned("DateTimeZone.ToUtc", 1...1) { d, _, _, _ in .datetimezone(d, offsetMinutes: 0) }
        zoned("DateTimeZone.ToLocal", 1...1) { d, _, _, ctx in .datetimezone(d, offsetMinutes: ctx.environment.timeZone.secondsFromGMT(for: d) / 60) }
        zoned("DateTimeZone.ZoneHours", 1...1) { _, off, _, _ in .int(off / 60) }
        zoned("DateTimeZone.ZoneMinutes", 1...1) { _, off, _, _ in .int(off % 60) }

        // MARK: Time
        func time(_ name: String, _ f: @escaping (Double) -> MValue) {
            lib.fn(name, 1) { a, _ in try timeOfDay(a, 0).map(f) ?? .null }
        }
        time("Time.Hour") { .int(Int($0 / 3600)) }
        time("Time.Minute") { .int(Int($0 / 60) % 60) }
        time("Time.Second") { .number($0.truncatingRemainder(dividingBy: 60)) }
        lib.fn("Time.ToRecord", 1) { a, _ in
            guard let s = try timeOfDay(a, 0) else { return .null }
            return .record(MRecord(names: ["Hour", "Minute", "Second"],
                                   values: [.int(Int(s / 3600)), .int(Int(s / 60) % 60), .number(s.truncatingRemainder(dividingBy: 60))]))
        }
        func hourEdge(_ name: String, end: Bool) {
            lib.fn(name, 1) { a, _ in
                if case .time(let s) = a[0] {
                    let start = (s / 3600).rounded(.down) * 3600
                    return .time(end ? (start + 3600).nextDown : start)
                }
                guard let t = try temporal(a, 0) else { return .null }
                let start = MDate.start(.hour, t.wall)
                return end ? t.makeEnd(before: start.addingTimeInterval(3600)) : t.make(start)
            }
        }
        hourEdge("Time.StartOfHour", end: false)
        hourEdge("Time.EndOfHour", end: true)

        // MARK: Duration
        func duration(_ name: String, _ f: @escaping (Double) -> Double) {
            lib.fn(name, 1) { a, _ in
                if a[0].isNull { return .null }
                guard case .duration(let s) = a[0] else { throw MError.typeMismatch(expected: "duration", got: a[0]) }
                return .number(f(s))
            }
        }
        duration("Duration.Days") { ($0 / 86400).rounded(.towardZero) }
        duration("Duration.Hours") { ($0.truncatingRemainder(dividingBy: 86400) / 3600).rounded(.towardZero) }
        duration("Duration.Minutes") { ($0.truncatingRemainder(dividingBy: 3600) / 60).rounded(.towardZero) }
        duration("Duration.Seconds") { $0.truncatingRemainder(dividingBy: 60) }
        duration("Duration.TotalDays") { $0 / 86400 }
        duration("Duration.TotalHours") { $0 / 3600 }
        duration("Duration.TotalMinutes") { $0 / 60 }
        duration("Duration.TotalSeconds") { $0 }
        lib.fn("Duration.ToRecord", 1) { a, _ in
            guard case .duration(let s) = a[0] else { throw MError.typeMismatch(expected: "duration", got: a[0]) }
            return .record(MRecord(names: ["Days", "Hours", "Minutes", "Seconds"], values: [
                .number((s / 86400).rounded(.towardZero)), .number((s.truncatingRemainder(dividingBy: 86400) / 3600).rounded(.towardZero)),
                .number((s.truncatingRemainder(dividingBy: 3600) / 60).rounded(.towardZero)), .number(s.truncatingRemainder(dividingBy: 60))]))
        }
    }
}
