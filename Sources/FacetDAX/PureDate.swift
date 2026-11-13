import Foundation
import FacetCore

/// Context-free date and time functions. All arithmetic is in UTC.
enum PureDate {
    private typealias A = PureArgs

    /// Clock used by TODAY/NOW/UTCNOW/UTCTODAY; replace to pin time in tests or "as of" evaluation.
    static var now: () -> Date = { Date() }

    private static let cal = Calendar.utc

    /// Coerces a value to a date: BLANK is serial 0, numbers are serials, text is parsed.
    static func toDate(_ v: Value, _ fn: String = "date function") throws -> Date {
        switch v {
        case .date(let d): return d
        case .null: return Value.date(fromSerial: 0)
        case .string(let s):
            if let d = DateParsing.parse(s) { return d }
            if let n = Double(s.trimmingCharacters(in: .whitespaces)) { return Value.date(fromSerial: n) }
            throw DAXError("Cannot convert value '\(s)' of type Text to type Date in \(fn).")
        default:
            let n = try DAXOps.number(v)
            guard n.isFinite, abs(n) < 3_000_000 else { throw DAXError("The value \(v.asString) is not a valid date in \(fn).") }
            return Value.date(fromSerial: n)
        }
    }
    private static func d(_ a: [Value], _ i: Int, _ fn: String) throws -> Date { try toDate(a[safe: i] ?? .null, fn) }

    static func ymd(_ date: Date) -> (y: Int, m: Int, d: Int) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 1899, c.month ?? 12, c.day ?? 30)
    }
    /// Builds a date, rolling out-of-range months and days over like DAX's DATE.
    static func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = 1; c.day = 1
        let base = cal.date(from: c) ?? Value.date(fromSerial: 0)
        let withMonth = cal.date(byAdding: .month, value: m - 1, to: base) ?? base
        return cal.date(byAdding: .day, value: d - 1, to: withMonth) ?? withMonth
    }
    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        cal.range(of: .day, in: .month, for: makeDate(y, m, 1))?.count ?? 30
    }
    /// Adds months, clamping the day to the end of the target month and keeping the time of day.
    static func addMonths(_ date: Date, _ n: Int) -> Date {
        let (y, m, dd) = ymd(date)
        let total = y * 12 + (m - 1) + n
        let ny = Int(floor(Double(total) / 12)), nm = total - ny * 12 + 1
        let day = min(dd, daysInMonth(ny, nm))
        let time = date.timeIntervalSince(cal.startOfDay(for: date))
        return makeDate(ny, nm, day).addingTimeInterval(time)
    }
    static func endOfMonth(_ date: Date, offset: Int = 0) -> Date {
        let (y, m, _) = ymd(date)
        let total = y * 12 + (m - 1) + offset
        let ny = Int(floor(Double(total) / 12)), nm = total - ny * 12 + 1
        return makeDate(ny, nm, daysInMonth(ny, nm))
    }
    private static func dayNumber(_ date: Date) -> Int { Int(floor(Value.serial(from: date) + 1e-9)) }
    /// 1 = Sunday … 7 = Saturday.
    static func weekdaySunday1(_ date: Date) -> Int { cal.component(.weekday, from: date) }
    private static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    private static func timeParts(_ date: Date) -> (h: Int, m: Int, s: Int) {
        // Round to the nearest second to absorb serial-number noise.
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded())
        let c = cal.dateComponents([.hour, .minute, .second], from: rounded)
        return (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func isoWeek(_ date: Date) -> Int {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = cal.timeZone
        return iso.component(.weekOfYear, from: date)
    }

    private static func yearFrac(_ s0: Date, _ e0: Date, basis: Int) throws -> Double {
        var s = cal.startOfDay(for: s0), e = cal.startOfDay(for: e0)
        if s > e { swap(&s, &e) }
        let (y1, m1, d1) = ymd(s), (y2, m2, d2) = ymd(e)
        let actual = Double(dayNumber(e) - dayNumber(s))
        switch basis {
        case 0:
            var a = d1, b = d2
            let sLast = d1 == daysInMonth(y1, m1), eLast = d2 == daysInMonth(y2, m2)
            if m1 == 2, sLast, m2 == 2, eLast { b = 30 }
            if m1 == 2, sLast { a = 30 }
            if b == 31, a >= 30 { b = 30 }
            if a == 31 { a = 30 }
            return Double((y2 - y1) * 360 + (m2 - m1) * 30 + (b - a)) / 360
        case 1:
            if y1 == y2 { return actual / (isLeap(y1) ? 366 : 365) }
            // Within one year span: leap day inside the range makes it 366; otherwise average year length.
            let oneYearLater = makeDate(y1 + 1, m1, d1)
            if e <= oneYearLater {
                let hasLeapDay = (isLeap(y1) && s <= makeDate(y1, 2, 29)) || (isLeap(y2) && e >= makeDate(y2, 2, 29))
                return actual / (hasLeapDay ? 366 : 365)
            }
            var total = 0.0
            for y in y1...y2 { total += isLeap(y) ? 366 : 365 }
            return actual / (total / Double(y2 - y1 + 1))
        case 2: return actual / 360
        case 3: return actual / 365
        case 4:
            let a = min(d1, 30), b = min(d2, 30)
            return Double((y2 - y1) * 360 + (m2 - m1) * 30 + (b - a)) / 360
        default: throw DAXError("YEARFRAC: basis must be between 0 and 4.")
        }
    }

    /// Weekend weekday numbers (1 = Sunday … 7 = Saturday) for a NETWORKDAYS weekend code.
    private static func weekendDays(_ code: Int) throws -> Set<Int> {
        switch code {
        case 1...7:
            // 1: Sat,Sun  2: Sun,Mon  3: Mon,Tue … 7: Fri,Sat
            let first = code == 1 ? 7 : code - 1
            return [first, first % 7 + 1]
        case 11...17: return [code - 10]
        default: throw DAXError("NETWORKDAYS: the weekend argument must be 1–7 or 11–17.")
        }
    }

    static let functions: [String: PureFn] = {
        var f: [String: PureFn] = [:]

        f["DATE"] = { a in
            var y = try A.i(a, 0)
            let m = try A.i(a, 1), dd = try A.i(a, 2)
            if y < 0 || y > 9999 { throw DAXError("DATE: the year must be between 0 and 9999.") }
            if y < 1900 { y += 1900 }
            return .date(makeDate(y, m, dd))
        }
        f["TIME"] = { a in
            let secs = try A.n(a, 0) * 3600 + A.n(a, 1) * 60 + A.n(a, 2)
            var frac = (secs / 86400).truncatingRemainder(dividingBy: 1)
            if frac < 0 { frac += 1 }
            return .date(Value.date(fromSerial: frac))
        }
        f["DATEVALUE"] = { a in
            if A.isBlank(a, 0) { return .null }
            return .date(cal.startOfDay(for: try d(a, 0, "DATEVALUE")))
        }
        f["TIMEVALUE"] = { a in
            if A.isBlank(a, 0) { return .null }
            let dt = try d(a, 0, "TIMEVALUE")
            return .date(Value.date(fromSerial: 0).addingTimeInterval(dt.timeIntervalSince(cal.startOfDay(for: dt))))
        }
        f["YEAR"] = { a in .int(Int64(ymd(try d(a, 0, "YEAR")).y)) }
        f["MONTH"] = { a in .int(Int64(ymd(try d(a, 0, "MONTH")).m)) }
        f["DAY"] = { a in .int(Int64(ymd(try d(a, 0, "DAY")).d)) }
        f["HOUR"] = { a in .int(Int64(timeParts(try d(a, 0, "HOUR")).h)) }
        f["MINUTE"] = { a in .int(Int64(timeParts(try d(a, 0, "MINUTE")).m)) }
        f["SECOND"] = { a in .int(Int64(timeParts(try d(a, 0, "SECOND")).s)) }
        f["QUARTER"] = { a in .int(Int64((ymd(try d(a, 0, "QUARTER")).m - 1) / 3 + 1)) }
        f["WEEKDAY"] = { a in
            let w = weekdaySunday1(try d(a, 0, "WEEKDAY"))
            switch try A.i(a, 1, default: 1) {
            case 1: return .int(Int64(w))
            case 2: return .int(Int64((w + 5) % 7 + 1))
            case 3: return .int(Int64((w + 5) % 7))
            default: throw DAXError("WEEKDAY: the return type must be 1, 2 or 3.")
            }
        }
        f["WEEKNUM"] = { a in
            let date = try d(a, 0, "WEEKNUM")
            let type = try A.i(a, 1, default: 1)
            if type == 21 { return .int(Int64(isoWeek(date))) }
            let weekStart: Int
            switch type {
            case 1, 17: weekStart = 1
            case 2, 11: weekStart = 2
            case 12...16: weekStart = type - 9
            default: throw DAXError("WEEKNUM: the return type is not supported.")
            }
            let y = ymd(date).y
            let jan1 = makeDate(y, 1, 1)
            let offset = (weekdaySunday1(jan1) - weekStart + 7) % 7
            let dayOfYear = dayNumber(date) - dayNumber(jan1)
            return .int(Int64((dayOfYear + offset) / 7 + 1))
        }
        f["NOW"] = { _ in .date(now()) }
        f["UTCNOW"] = { _ in .date(now()) }
        f["TODAY"] = { _ in .date(cal.startOfDay(for: now())) }
        f["UTCTODAY"] = { _ in .date(cal.startOfDay(for: now())) }
        f["EOMONTH"] = { a in
            if A.isBlank(a, 0) && a.count < 2 { return .null }
            return .date(endOfMonth(try d(a, 0, "EOMONTH"), offset: try A.i(a, 1)))
        }
        f["EDATE"] = { a in
            .date(addMonths(cal.startOfDay(for: try d(a, 0, "EDATE")), try A.i(a, 1)))
        }
        f["DATEDIFF"] = { a in
            let s = try d(a, 0, "DATEDIFF"), e = try d(a, 1, "DATEDIFF")
            let (y1, m1, _) = ymd(s), (y2, m2, _) = ymd(e)
            let t1 = s.timeIntervalSince1970.rounded(), t2 = e.timeIntervalSince1970.rounded()
            func boundaries(_ unit: Double) -> Int64 { Int64(floor(t2 / unit) - floor(t1 / unit)) }
            switch A.s(a, 2).uppercased() {
            case "SECOND": return .int(boundaries(1))
            case "MINUTE": return .int(boundaries(60))
            case "HOUR": return .int(boundaries(3600))
            case "DAY": return .int(boundaries(86400))
            case "WEEK":
                // Weeks start on Sunday; count Sunday boundaries crossed.
                func weekIndex(_ dt: Date) -> Int { Int(floor(Double(dayNumber(dt) - 1) / 7)) }   // serial 1 = Sunday 1899-12-31
                return .int(Int64(weekIndex(e) - weekIndex(s)))
            case "MONTH": return .int(Int64((y2 - y1) * 12 + (m2 - m1)))
            case "QUARTER": return .int(Int64((y2 * 4 + (m2 - 1) / 3) - (y1 * 4 + (m1 - 1) / 3)))
            case "YEAR": return .int(Int64(y2 - y1))
            case let other: throw DAXError("DATEDIFF: '\(other)' is not a valid interval. Use SECOND, MINUTE, HOUR, DAY, WEEK, MONTH, QUARTER or YEAR.")
            }
        }
        f["YEARFRAC"] = { a in
            .double(try yearFrac(try d(a, 0, "YEARFRAC"), try d(a, 1, "YEARFRAC"), basis: try A.i(a, 2, default: 0)))
        }
        f["NETWORKDAYS"] = { a in
            var s = dayNumber(try d(a, 0, "NETWORKDAYS")), e = dayNumber(try d(a, 1, "NETWORKDAYS"))
            let weekend = try weekendDays(try A.i(a, 2, default: 1))
            let sign: Int64 = s > e ? -1 : 1
            if s > e { swap(&s, &e) }
            let total = e - s + 1
            let fullWeeks = total / 7
            var count = fullWeeks * (7 - weekend.count)
            // Serial 1 (1899-12-31) is a Sunday → weekday(1=Sun) = ((n - 1) mod 7) + 1.
            var n = s + fullWeeks * 7
            while n <= e {
                let wd = ((n - 1) % 7 + 7) % 7 + 1
                if !weekend.contains(wd) { count += 1 }
                n += 1
            }
            return .int(Int64(count) * sign)
        }
        return f
    }()
}
