import Foundation
import FacetCore

/// "Mark as date table": the column must be a date, with no blanks, no repeats and no missing days.
enum DateTableLogic {
    struct Check: Equatable {
        var problems: [String] = []
        var rowCount = 0
        var first: Date?
        var last: Date?
        var isValid: Bool { problems.isEmpty }
    }

    static func candidates(_ table: ModelTable) -> [ModelColumn] {
        table.columns.filter { $0.dataType == .date || $0.dataType == .dateTime }
    }

    static func validate(_ values: [Value], type: DataType, column: String = "The column") -> Check {
        var check = Check(rowCount: values.count)
        guard type == .date || type == .dateTime else {
            check.problems.append("\(column) is \(type.displayName.lowercased()). A date table needs a Date or Date/Time column.")
            return check
        }
        if values.isEmpty {
            check.problems.append("\(column) has no rows.")
            return check
        }
        var days: [Int] = []
        days.reserveCapacity(values.count)
        var blanks = 0, notDates = 0
        var times = Set<Int>()
        for v in values {
            guard case .date(let d) = v else {
                if v.isNull { blanks += 1 } else { notDates += 1 }
                continue
            }
            let serial = Value.serial(from: d)
            let day = serial.rounded(.down)
            times.insert(Int(((serial - day) * 86400).rounded()))
            days.append(Int(day))
        }
        if blanks > 0 { check.problems.append("\(column) has \(blanks.formatted()) blank value\(blanks == 1 ? "" : "s"). Every row needs a date.") }
        if notDates > 0 { check.problems.append("\(column) has \(notDates.formatted()) value\(notDates == 1 ? "" : "s") that \(notDates == 1 ? "is not a date" : "are not dates").") }
        if times.count > 1 { check.problems.append("\(column) has \(times.count.formatted()) different times of day. A Date/Time column must carry the same time on every row.") }
        guard let lo = days.min(), let hi = days.max() else { return check }
        check.first = Value.date(fromSerial: Double(lo))
        check.last = Value.date(fromSerial: Double(hi))
        let distinct = Set(days)
        if distinct.count < days.count {
            let repeats = days.count - distinct.count
            check.problems.append("\(column) repeats \(repeats.formatted()) date\(repeats == 1 ? "" : "s"). Each date may appear only once.")
        }
        let span = hi - lo + 1
        if distinct.count < span {
            let missing = span - distinct.count
            var firstGap = lo
            while distinct.contains(firstGap) { firstGap += 1 }
            let gap = DateParsing.isoString(Value.date(fromSerial: Double(firstGap))).prefix(10)
            check.problems.append("\(column) is missing \(missing.formatted()) day\(missing == 1 ? "" : "s") between its first and last date, starting with \(gap). Dates must be contiguous.")
        }
        return check
    }

    static func summary(_ check: Check) -> String {
        guard check.isValid, let first = check.first, let last = check.last else { return "" }
        let a = DateParsing.isoString(first).prefix(10), b = DateParsing.isoString(last).prefix(10)
        return "\(check.rowCount.formatted()) contiguous dates, \(a) to \(b)."
    }
}

/// Calendars for calendar-based time intelligence.
enum CalendarLogic {
    static func unitTitle(_ unit: String) -> String {
        switch unit {
        case "year": return "Year"
        case "quarter": return "Quarter"
        case "month": return "Month"
        case "week": return "Week"
        default: return "Date"
        }
    }

    static func make(in table: ModelTable, model: SemanticModel, alongside drafts: [CalendarDefinition]) -> CalendarDefinition {
        let taken = model.tables.flatMap { t in ModelDAX.same(t.name, table.name) ? [] : t.calendars.map(\.name) }
            + drafts.map(\.name) + model.tables.map(\.name)
        var name = "Calendar"
        var n = 2
        while taken.contains(where: { ModelDAX.same($0, name) }) { name = "Calendar \(n)"; n += 1 }
        var units: [String: String] = [:]
        if let date = table.dateColumn ?? DateTableLogic.candidates(table).first?.name { units["date"] = date }
        // Columns named after a unit ("Year", "Fiscal Quarter"…) are mapped to it.
        for unit in ["year", "quarter", "month", "week"] {
            if let c = table.columns.first(where: { $0.name.lowercased() == unit })
                ?? table.columns.first(where: { $0.name.lowercased().hasSuffix(unit) && !units.values.contains($0.name) }) {
                units[unit] = c.name
            }
        }
        return CalendarDefinition(name: name, columnsByUnit: units)
    }

    static func problems(_ calendars: [CalendarDefinition], table: ModelTable, model: SemanticModel) -> [String] {
        var out: [String] = []
        let elsewhere = model.tables.flatMap { t in ModelDAX.same(t.name, table.name) ? [] : t.calendars.map(\.name) }
        for (i, c) in calendars.enumerated() {
            let name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = calendars.enumerated().filter { $0.offset < i }.map(\.element.name) + elsewhere
            if let p = ModelNames.problem(name, noun: "calendar", others: others) { if !out.contains(p) { out.append(p) }; continue }
            if model.table(name) != nil { out.append("“\(name)” is a table name. Calendars are referenced by name in DAX, so the name must not match a table.") }
            let mapped = c.columnsByUnit.filter { !$0.value.isEmpty }
            if mapped.isEmpty { out.append("Map at least one column in “\(name)”."); continue }
            for (unit, column) in mapped.sorted(by: { $0.key < $1.key }) {
                guard let col = table.column(column) else {
                    out.append("“\(name)” maps \(CalendarLogic.unitTitle(unit)) to “\(column)”, which is not a column of \(table.name).")
                    continue
                }
                if unit == "date", !(col.dataType == .date || col.dataType == .dateTime) {
                    out.append("“\(name)” needs a Date or Date/Time column for Date; \(column) is \(col.dataType.displayName.lowercased()).")
                }
            }
            if let dup = ModelNames.firstDuplicate(mapped.values.sorted()) { out.append("“\(name)” maps “\(dup)” to more than one unit.") }
            if mapped["date"] == nil, table.dateColumn == nil {
                out.append("Map the Date unit in “\(name)”, or mark \(table.name) as a date table.")
            }
            if !(1...12).contains(c.fiscalYearStartMonth) { out.append("The first month of the year in “\(name)” must be 1 to 12.") }
        }
        return out
    }

    static func cleaned(_ calendars: [CalendarDefinition]) -> [CalendarDefinition] {
        calendars.map { c in
            var c = c
            c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
            c.columnsByUnit = c.columnsByUnit.filter { !$0.value.isEmpty }
            return c
        }
    }
}
