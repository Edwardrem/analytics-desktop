import Foundation
import FacetCore

/// Calendar arithmetic in UTC for time intelligence.
enum DateMath {
    static let cal = Calendar.utc
    static func ymd(_ d: Date) -> (y: Int, m: Int, d: Int) {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return (c.year ?? 1900, c.month ?? 1, c.day ?? 1)
    }
    static func make(_ y: Int, _ m: Int, _ d: Int) -> Date {
        // Normalise month overflow; clamp the day to the month length.
        var yy = y, mm = m
        while mm > 12 { mm -= 12; yy += 1 }
        while mm < 1 { mm += 12; yy -= 1 }
        let first = cal.date(from: DateComponents(year: yy, month: mm, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let len = cal.range(of: .day, in: .month, for: first)?.count ?? 28
        return cal.date(from: DateComponents(year: yy, month: mm, day: min(max(d, 1), len))) ?? first
    }
    static func addMonths(_ d: Date, _ n: Int) -> Date {
        let (y, m, day) = ymd(d)
        let base = make(y, m + n, day)
        return base.addingTimeInterval(d.timeIntervalSince(cal.startOfDay(for: d)))
    }
    static func addDays(_ d: Date, _ n: Int) -> Date { d.addingTimeInterval(Double(n) * 86400) }
    static func startOfMonth(_ d: Date) -> Date { let (y, m, _) = ymd(d); return make(y, m, 1) }
    static func endOfMonth(_ d: Date) -> Date { let (y, m, _) = ymd(d); return make(y, m, 31) }
    static func startOfQuarter(_ d: Date) -> Date { let (y, m, _) = ymd(d); return make(y, (m - 1) / 3 * 3 + 1, 1) }
    static func endOfQuarter(_ d: Date) -> Date { let (y, m, _) = ymd(d); return make(y, (m - 1) / 3 * 3 + 3, 31) }
    /// First day of the (fiscal) year containing `d`, where the year ends on month/day `end`.
    static func startOfYear(_ d: Date, end: (m: Int, d: Int)) -> Date {
        let (y, _, _) = ymd(d)
        let endThisYear = make(y, end.m, end.d)
        let day = cal.startOfDay(for: d)
        return day > endThisYear ? addDays(endThisYear, 1) : addDays(make(y - 1, end.m, end.d), 1)
    }
    static func endOfYear(_ d: Date, end: (m: Int, d: Int)) -> Date {
        let (y, _, _) = ymd(d)
        let endThisYear = make(y, end.m, end.d)
        return cal.startOfDay(for: d) > endThisYear ? make(y + 1, end.m, end.d) : endThisYear
    }
    /// Parses a year-end literal such as "6/30", "06-30" or "30 June".
    static func parseYearEnd(_ s: String) -> (m: Int, d: Int)? {
        let parts = s.split { !$0.isNumber }.compactMap { Int($0) }
        if parts.count >= 2 {
            if (1...12).contains(parts[0]), (1...31).contains(parts[1]) { return (parts[0], parts[1]) }
            if (1...12).contains(parts[1]), (1...31).contains(parts[0]) { return (parts[1], parts[0]) }
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let lower = s.lowercased()
        if let mi = months.firstIndex(where: { lower.contains($0) }), let day = parts.first { return (mi + 1, day) }
        return nil
    }
}

/// Sorted distinct dates of a date column, with lookup helpers.
final class DateIndex {
    let dates: [Date]
    let set: Set<Date>
    init(_ values: [Value]) {
        var s = Set<Date>()
        for v in values { if case .date(let d) = v { s.insert(d) } }
        set = s
        dates = s.sorted()
    }
    func between(_ lo: Date, _ hi: Date) -> [Date] {
        guard lo <= hi else { return [] }
        var a = 0, b = dates.count
        while a < b { let m = (a + b) / 2; if dates[m] < lo { a = m + 1 } else { b = m } }
        var out: [Date] = []
        var i = a
        while i < dates.count, dates[i] <= hi { out.append(dates[i]); i += 1 }
        return out
    }
}

struct DateArg {
    let cid: ColumnID
    /// Dates visible in the current context (or produced by the table argument), ascending.
    let visible: [Date]
    let yearEnd: (m: Int, d: Int)
    let calendar: CalendarDef?
}

extension DAXEngine {
    func dateIndex(_ cid: ColumnID) -> DateIndex {
        if let d = dateIndexCache[cid] { return d }
        let d = DateIndex(db.column(cid).dict)
        dateIndexCache[cid] = d
        return d
    }

    /// Resolves the `dates` argument: a date column, a calendar name, or a table expression with a date column.
    func dateArg(_ node: Node, _ ctx: Ctx, _ fn: String) throws -> DateArg {
        let (n, c) = deref(node, ctx)
        var calendar: CalendarDef?
        var name: String?
        if case .ident(let s) = n.kind { name = s } else if let s = n.stringConst { name = s }
        if let s = name, c.vars?.lookup(s.daxKey) == nil, let cal = calendars[s.daxKey] { calendar = cal }
        if let cal = calendar {
            let vis = distinctValues(cal.dateColumn, c.fc, blankRow: false).compactMap { v -> Date? in if case .date(let d) = v { return d }; return nil }.sorted()
            return DateArg(cid: cal.dateColumn, visible: vis, yearEnd: (cal.yearEndMonth, 31), calendar: cal)
        }
        if let cid = try modelColumn(n, c) {
            guard db.column(cid).isDateLike else { throw DAXError("\(fn): \(db.name(cid)) is not a date column.", range: n.range) }
            let vis = distinctValues(cid, c.fc, blankRow: false).compactMap { v -> Date? in if case .date(let d) = v { return d }; return nil }.sorted()
            return DateArg(cid: cid, visible: vis, yearEnd: (12, 31), calendar: nil)
        }
        guard isTableNode(n, c) else {
            throw DAXError("\(fn) expects a date column (for example 'Date'[Date]), a calendar name, or a table of dates.", range: n.range)
        }
        let t = try table(n, c)
        guard let k = t.cols.infos.firstIndex(where: { $0.lineage != nil }), let cid = t.cols.infos[k].lineage else {
            throw DAXError("\(fn): the table of dates must come from a date column of the model.", range: n.range)
        }
        let vis = Set(t.rows(db).compactMap { r -> Date? in if case .date(let d) = r[k] { return d }; return nil }).sorted()
        return DateArg(cid: cid, visible: vis, yearEnd: (12, 31), calendar: nil)
    }

    func datesTable(_ cid: ColumnID, _ dates: [Date]) -> TableValue {
        TableValue(cols: Columns([colInfo(cid)]), rows: dates.map { [.date($0)] })
    }

    private func yearEndArg(_ a: [Node], _ i: Int, _ ctx: Ctx, _ base: DateArg) throws -> (m: Int, d: Int) {
        guard let n = arg(a, i) else { return base.yearEnd }
        let v = try scalar(n, ctx)
        if v.isNull { return base.yearEnd }
        guard let p = DateMath.parseYearEnd(v.asString) else {
            throw DAXError("'\(v.asString)' is not a valid year-end date. Use a month/day literal such as \"6/30\".")
        }
        return p
    }

    enum Period { case day, month, quarter, year }

    func periodStart(_ d: Date, _ p: Period, _ ye: (m: Int, d: Int)) -> Date {
        switch p {
        case .day: return DateMath.cal.startOfDay(for: d)
        case .month: return DateMath.startOfMonth(d)
        case .quarter: return DateMath.startOfQuarter(d)
        case .year: return DateMath.startOfYear(d, end: ye)
        }
    }
    func periodEnd(_ d: Date, _ p: Period, _ ye: (m: Int, d: Int)) -> Date {
        switch p {
        case .day: return DateMath.cal.startOfDay(for: d)
        case .month: return DateMath.endOfMonth(d)
        case .quarter: return DateMath.endOfQuarter(d)
        case .year: return DateMath.endOfYear(d, end: ye)
        }
    }
    /// Includes the whole last day when the column stores times.
    private func dayEnd(_ d: Date) -> Date { DateMath.cal.startOfDay(for: d).addingTimeInterval(86399.999) }

    func toDate(_ da: DateArg, _ p: Period, _ ye: (m: Int, d: Int)) -> [Date] {
        guard let last = da.visible.last else { return [] }
        return dateIndex(da.cid).between(periodStart(last, p, ye), dayEnd(last))
    }

    func intervalArg(_ a: [Node], _ i: Int, _ ctx: Ctx, _ fn: String) throws -> (months: Int, days: Int) {
        switch try keywordArg(a, i, ctx) ?? "" {
        case "DAY": return (0, 1)
        case "WEEK": return (0, 7)
        case "MONTH": return (1, 0)
        case "QUARTER": return (3, 0)
        case "YEAR": return (12, 0)
        case let other: throw DAXError("\(fn): unknown interval '\(other)'. Use DAY, MONTH, QUARTER or YEAR.")
        }
    }

    func dateAdd(_ da: DateArg, _ n: Int, months: Int, days: Int) -> [Date] {
        let idx = dateIndex(da.cid)
        if months == 0 {
            return da.visible.map { DateMath.addDays($0, n * days) }.filter { idx.set.contains($0) }
        }
        // Month-based shift: fully selected months map to whole months; other dates shift day by day.
        var out = Set<Date>()
        var byMonth: [Int: [Date]] = [:]
        for d in da.visible { let (y, m, _) = DateMath.ymd(d); byMonth[y * 12 + m - 1, default: []].append(d) }
        for (key, ds) in byMonth {
            let monthStart = DateMath.make(key / 12, key % 12 + 1, 1)
            let all = idx.between(monthStart, dayEnd(DateMath.endOfMonth(monthStart)))
            let target = DateMath.addMonths(monthStart, n * months)
            if all.count == ds.count {
                for d in idx.between(target, dayEnd(DateMath.endOfMonth(target))) { out.insert(d) }
            } else {
                for d in ds { let s = DateMath.addMonths(d, n * months); if idx.set.contains(s) { out.insert(s) } }
            }
        }
        return out.sorted()
    }

    /// CALCULATE(expr, <dates table>, extra filter arguments…).
    func calculateOver(_ expr: Node, _ da: DateArg, _ dates: [Date], _ extra: [Node], _ ctx: Ctx) throws -> Value {
        let inner = try calculateContext(extra[...], ctx, tables: [datesTable(da.cid, dates)], clearTables: da.calendar.map { [$0.table] } ?? [])
        return try scalar(expr, inner)
    }

    static let timeFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        let periods: [(String, Period)] = [("YTD", .year), ("QTD", .quarter), ("MTD", .month)]
        for (suffix, p) in periods {
            d["DATES" + suffix] = { e, a, c, n in
                let da = try e.dateArg(a[0], c, "DATES" + suffix)
                let ye = p == .year ? try e.yearEndArg(a, 1, c, da) : da.yearEnd
                return .table(e.datesTable(da.cid, e.toDate(da, p, ye)))
            }
            d["TOTAL" + suffix] = { e, a, c, _ in
                let da = try e.dateArg(a[1], c, "TOTAL" + suffix)
                var ye = da.yearEnd
                var extra: [Node] = []
                for i in 2..<max(2, a.count) where !a[i].isMissing {
                    if p == .year, i == a.count - 1, !e.isTableNode(a[i], c), let s = try? e.scalar(a[i], c), case .string(let str) = s,
                       let parsed = DateMath.parseYearEnd(str) { ye = parsed } else { extra.append(a[i]) }
                }
                return .scalar(try e.calculateOver(a[0], da, e.toDate(da, p, ye), extra, c))
            }
        }
        d["SAMEPERIODLASTYEAR"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "SAMEPERIODLASTYEAR")
            return .table(e.datesTable(da.cid, e.dateAdd(da, -1, months: 12, days: 0)))
        }
        d["DATEADD"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "DATEADD")
            let n = Int(try DAXOps.number(e.scalar(a[1], c)))
            let iv = try e.intervalArg(a, 2, c, "DATEADD")
            return .table(e.datesTable(da.cid, e.dateAdd(da, n, months: iv.months, days: iv.days)))
        }
        d["PARALLELPERIOD"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "PARALLELPERIOD")
            let n = Int(try DAXOps.number(e.scalar(a[1], c)))
            let iv = try e.intervalArg(a, 2, c, "PARALLELPERIOD")
            guard iv.months > 0, let first = da.visible.first, let last = da.visible.last else {
                if iv.months == 0 { throw DAXError("PARALLELPERIOD: the interval must be MONTH, QUARTER or YEAR.") }
                return .table(e.datesTable(da.cid, []))
            }
            let p: Period = iv.months == 1 ? .month : (iv.months == 3 ? .quarter : .year)
            let lo = e.periodStart(DateMath.addMonths(first, n * iv.months), p, da.yearEnd)
            let hi = e.periodEnd(DateMath.addMonths(last, n * iv.months), p, da.yearEnd)
            return .table(e.datesTable(da.cid, e.dateIndex(da.cid).between(lo, e.dayEnd(hi))))
        }
        let units: [(String, Period)] = [("DAY", .day), ("MONTH", .month), ("QUARTER", .quarter), ("YEAR", .year)]
        for (unit, p) in units {
            d["PREVIOUS" + unit] = { e, a, c, _ in
                let da = try e.dateArg(a[0], c, "PREVIOUS" + unit)
                let ye = p == .year ? try e.yearEndArg(a, 1, c, da) : da.yearEnd
                guard let first = da.visible.first else { return .table(e.datesTable(da.cid, [])) }
                let prevEnd = DateMath.addDays(e.periodStart(first, p, ye), -1)
                return .table(e.datesTable(da.cid, e.dateIndex(da.cid).between(e.periodStart(prevEnd, p, ye), e.dayEnd(prevEnd))))
            }
            d["NEXT" + unit] = { e, a, c, _ in
                let da = try e.dateArg(a[0], c, "NEXT" + unit)
                let ye = p == .year ? try e.yearEndArg(a, 1, c, da) : da.yearEnd
                guard let last = da.visible.last else { return .table(e.datesTable(da.cid, [])) }
                let nextStart = DateMath.addDays(e.periodEnd(last, p, ye), 1)
                return .table(e.datesTable(da.cid, e.dateIndex(da.cid).between(nextStart, e.dayEnd(e.periodEnd(nextStart, p, ye)))))
            }
            guard p != .day else { continue }
            d["STARTOF" + unit] = { e, a, c, _ in
                let da = try e.dateArg(a[0], c, "STARTOF" + unit)
                let ye = p == .year ? try e.yearEndArg(a, 1, c, da) : da.yearEnd
                guard let first = da.visible.first else { return .table(e.datesTable(da.cid, [])) }
                let ds = e.dateIndex(da.cid).between(e.periodStart(first, p, ye), e.dayEnd(e.periodEnd(first, p, ye)))
                return .table(e.datesTable(da.cid, Array(ds.prefix(1))))
            }
            d["ENDOF" + unit] = { e, a, c, _ in
                let da = try e.dateArg(a[0], c, "ENDOF" + unit)
                let ye = p == .year ? try e.yearEndArg(a, 1, c, da) : da.yearEnd
                guard let last = da.visible.last else { return .table(e.datesTable(da.cid, [])) }
                let ds = e.dateIndex(da.cid).between(e.periodStart(last, p, ye), e.dayEnd(e.periodEnd(last, p, ye)))
                return .table(e.datesTable(da.cid, Array(ds.suffix(1))))
            }
            d["OPENINGBALANCE" + unit] = { e, a, c, _ in
                let da = try e.dateArg(a[1], c, "OPENINGBALANCE" + unit)
                guard let first = da.visible.first else { return .scalar(.null) }
                let prevEnd = DateMath.addDays(e.periodStart(first, p, da.yearEnd), -1)
                let ds = e.dateIndex(da.cid).between(DateMath.cal.startOfDay(for: prevEnd), e.dayEnd(prevEnd))
                return .scalar(try e.calculateOver(a[0], da, ds, Array(a.dropFirst(2).prefix(1)), c))
            }
            d["CLOSINGBALANCE" + unit] = { e, a, c, _ in
                let da = try e.dateArg(a[1], c, "CLOSINGBALANCE" + unit)
                guard let last = da.visible.last else { return .scalar(.null) }
                let ye = p == .year ? try e.yearEndArg(a, 3, c, da) : da.yearEnd
                let ds = e.dateIndex(da.cid).between(e.periodStart(last, p, ye), e.dayEnd(e.periodEnd(last, p, ye)))
                return .scalar(try e.calculateOver(a[0], da, Array(ds.suffix(1)), Array(a.dropFirst(2).prefix(1)), c))
            }
        }
        d["FIRSTDATE"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "FIRSTDATE")
            return .table(e.datesTable(da.cid, Array(da.visible.prefix(1))))
        }
        d["LASTDATE"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "LASTDATE")
            return .table(e.datesTable(da.cid, Array(da.visible.suffix(1))))
        }
        d["DATESBETWEEN"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "DATESBETWEEN")
            let idx = e.dateIndex(da.cid)
            let s = try e.scalar(a[1], c), en = try e.scalar(a[2], c)
            guard let lo = s.isNull ? idx.dates.first : s.asDate, let hi = en.isNull ? idx.dates.last : en.asDate else {
                return .table(e.datesTable(da.cid, []))
            }
            return .table(e.datesTable(da.cid, idx.between(lo, hi)))
        }
        d["DATESINPERIOD"] = { e, a, c, _ in
            let da = try e.dateArg(a[0], c, "DATESINPERIOD")
            guard let start = try e.scalar(a[1], c).asDate else { return .table(e.datesTable(da.cid, [])) }
            let n = Int(try DAXOps.number(e.scalar(a[2], c)))
            let iv = try e.intervalArg(a, 3, c, "DATESINPERIOD")
            let other = iv.months > 0 ? DateMath.addMonths(start, n * iv.months) : DateMath.addDays(start, n * iv.days)
            let idx = e.dateIndex(da.cid)
            if n >= 0 { return .table(e.datesTable(da.cid, idx.between(start, other.addingTimeInterval(-0.001)))) }
            return .table(e.datesTable(da.cid, idx.between(other.addingTimeInterval(86400), e.dayEnd(start))))
        }
        return d
    }()
}
