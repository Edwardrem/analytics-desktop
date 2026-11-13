import SwiftUI
import FacetCore
import FacetDesign

// Pure slicer logic: resolved configuration, distinct items, selection transitions, hierarchy
// tri-state, pasted-list parsing, relative-date ranges and input matching. No views here.

/// Resolved `format["slicer"]` settings shared by every slicer style.
struct CmpSlConfig {
    var style: String
    var singleSelect: Bool
    var selectAll: Bool
    var search: Bool
    var commandMulti: Bool
    var applyButton: Bool
    var forceSelection: Bool
    /// "hover" | "always" | "never"
    var clearMode: String
    var fontSize: Double
    var itemPadding: Double
    var text: Color
    var selectedHex: String
    var selected: Color { Color(hex: selectedHex) }
    /// Legible colour for content drawn on the selected colour.
    var onSelected: Color { Color(hex: CmpColor.readableText(on: selectedHex)) }
    var showSlider: Bool

    init(_ env: CmpEnv) {
        let f = env.f
        var s = f.string("slicer", "style", "list")
        if env.spec.type == .listSlicer { s = f.bool("slicer", "dropdown", false) ? "dropdown" : "list" }
        style = s
        singleSelect = f.bool("slicer", "singleSelect", false)
        selectAll = f.bool("slicer", "selectAll", false)
        search = f.bool("slicer", "search", s == "dropdown")
        commandMulti = f.bool("slicer", "multiSelectWithCommand", false)
        applyButton = f.bool("slicer", "applyButton", false)
        forceSelection = f.bool("slicer", "forceSelection", false)
        clearMode = f.string("slicer", "showClear", "hover")
        fontSize = f.double("slicer", "fontSize", env.theme.label.size + 1)
        itemPadding = f.double("slicer", "itemPadding", 4)
        text = f.color("slicer", "color", env.theme.foreground)
        selectedHex = f.string("slicer", "selectedColor", env.theme.accent)
        showSlider = f.bool("slicer", "slider", true)
    }
}

/// One distinct selectable value.
struct CmpSlItem: Identifiable, Hashable {
    let id: Int
    let value: Value
    let label: String
    var image: String?
}

enum CmpSlCheck { case off, on, mixed }

/// A node of a hierarchy slicer; `path` is the level-path from the root to this node.
final class CmpSlNode: Identifiable {
    let value: Value
    let label: String
    let path: [Value]
    var children: [CmpSlNode] = []
    init(value: Value, label: String, path: [Value]) { self.value = value; self.label = label; self.path = path }
    var key: String { CmpSlLogic.key(path) }
}

enum CmpSlLogic {
    static let blankLabel = "(Blank)"

    static func key(_ path: [Value]) -> String { path.map(\.asString).joined(separator: "\u{1F}") }

    // MARK: Flat values

    /// Distinct values of a column in first-seen order, with formatted labels.
    static func items(_ data: VisualData, column: Int, imageColumn: Int? = nil) -> [CmpSlItem] {
        guard column < data.table.columnCount else { return [] }
        var seen = Set<Value>()
        var out: [CmpSlItem] = []
        for r in 0..<data.table.rowCount {
            let v = data.table[r, column]
            guard seen.insert(v).inserted else { continue }
            let text = data.formatted(row: r, col: column)
            let image = imageColumn.flatMap { c -> String? in
                let s = data.table[r, c].asString
                return s.isEmpty ? nil : s
            }
            out.append(CmpSlItem(id: out.count, value: v, label: text.isEmpty ? blankLabel : text, image: image))
        }
        return out
    }

    /// Selection after activating `v`.
    /// - single: at most one value. - additive: toggle within the set (checkbox / ⌘-click); otherwise replace.
    /// - force: never leave the selection empty.
    static func toggle(_ v: Value, in selected: [Value], single: Bool, additive: Bool, force: Bool) -> [Value] {
        if single || !additive {
            if selected == [v] { return force ? selected : [] }
            return [v]
        }
        if selected.contains(v) {
            if force, selected.count == 1 { return selected }
            return selected.filter { $0 != v }
        }
        return selected + [v]
    }

    static func allState(all: [Value], selected: [Value]) -> CmpSlCheck {
        if selected.isEmpty { return .off }
        let s = Set(selected)
        return all.allSatisfy(s.contains) ? .on : .mixed
    }

    /// "Select all": everything selected → clear; otherwise select everything.
    static func toggleAll(all: [Value], selected: [Value]) -> [Value] {
        allState(all: all, selected: selected) == .on ? [] : all
    }

    static func filter(_ items: [CmpSlItem], query: String) -> [CmpSlItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.label.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Hierarchy

    /// Builds the tree from the rows of the given (level-ordered) columns.
    static func tree(_ data: VisualData, columns: [Int]) -> [CmpSlNode] {
        var roots: [CmpSlNode] = []
        var index: [String: CmpSlNode] = [:]
        for r in 0..<data.table.rowCount {
            var path: [Value] = []
            var parent: CmpSlNode?
            for c in columns where c < data.table.columnCount {
                let v = data.table[r, c]
                path.append(v)
                let k = key(path)
                if let n = index[k] { parent = n; continue }
                let text = data.formatted(row: r, col: c)
                let n = CmpSlNode(value: v, label: text.isEmpty ? blankLabel : text, path: path)
                index[k] = n
                if let parent { parent.children.append(n) } else { roots.append(n) }
                parent = n
            }
        }
        return roots
    }

    /// True when selection path `p` covers `path` (is a prefix of it, or equal).
    static func covers(_ p: [Value], _ path: [Value]) -> Bool {
        p.count <= path.count && Array(path.prefix(p.count)) == p
    }

    /// Tri-state of a node: on when a selected path covers it, mixed when a selected path lies beneath it.
    static func check(_ path: [Value], in paths: [[Value]]) -> CmpSlCheck {
        if paths.contains(where: { covers($0, path) }) { return .on }
        if paths.contains(where: { covers(path, $0) }) { return .mixed }
        return .off
    }

    /// Paths after toggling a node. A short path means "the whole subtree". The result is normalised:
    /// a parent whose children are all selected is stored as the parent path alone.
    static func toggleNode(_ node: CmpSlNode, paths: [[Value]], roots: [CmpSlNode], single: Bool) -> [[Value]] {
        if single { return paths == [node.path] ? [] : [node.path] }
        var out = paths
        if check(node.path, in: paths) == .on {
            guard let cover = out.first(where: { covers($0, node.path) }) else { return out }
            out.removeAll { $0 == cover }
            var level = roots
            for depth in 0..<node.path.count {
                guard let n = level.first(where: { $0.value == node.path[depth] }) else { break }
                if depth >= cover.count { out.append(contentsOf: level.filter { $0 !== n }.map(\.path)) }
                level = n.children
            }
            return out
        }
        out.removeAll { covers(node.path, $0) }
        out.append(node.path)
        return normalise(out, roots: roots)
    }

    static func normalise(_ paths: [[Value]], roots: [CmpSlNode]) -> [[Value]] {
        var out = paths
        @discardableResult func full(_ n: CmpSlNode) -> Bool {
            if out.contains(where: { covers($0, n.path) }) { return true }
            guard !n.children.isEmpty else { return false }
            var all = true
            for c in n.children where !full(c) { all = false }
            if all {
                out.removeAll { covers(n.path, $0) }
                out.append(n.path)
            }
            return all
        }
        for r in roots { full(r) }
        return out
    }

    /// Nodes matching the query, keeping ancestors of matches (returns keys to show, nil = all).
    static func matchingKeys(_ roots: [CmpSlNode], query: String) -> Set<String>? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        var keep = Set<String>()
        func visit(_ n: CmpSlNode, ancestorMatched: Bool) -> Bool {
            let own = n.label.localizedCaseInsensitiveContains(q)
            var any = own
            for c in n.children where visit(c, ancestorMatched: ancestorMatched || own) { any = true }
            if any || ancestorMatched { keep.insert(n.key) }
            return any
        }
        for r in roots { _ = visit(r, ancestorMatched: false) }
        return keep
    }

    // MARK: Input slicer

    /// Splits typed or pasted text into values: separators are newline, tab, comma and semicolon;
    /// double quotes keep separators inside a value. Trims, drops empties and duplicates.
    static func parseList(_ text: String) -> [String] {
        var out: [String] = [], cur = "", inQuote = false
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
            cur = ""
        }
        for ch in text {
            if ch == "\"" { inQuote.toggle(); continue }
            if !inQuote, ch == "\n" || ch == "\r" || ch == "\t" || ch == "," || ch == ";" || ch == "\r\n" { flush() } else { cur.append(ch) }
        }
        flush()
        return out
    }

    /// Typed term → value: a number when the field column is numeric and the term parses, else text.
    static func typedValue(_ term: String, numeric: Bool) -> Value {
        if numeric, let d = DataTable.parseNumber(term) {
            return d == d.rounded() && abs(d) < 1e15 ? .int(Int64(d)) : .double(d)
        }
        return .string(term)
    }

    static let inputOperators: [(id: String, label: String, single: Bool)] = [
        ("contains", "Contains", false), ("startsWith", "Starts with", false), ("endsWith", "Ends with", false),
        ("equals", "Is exactly", false), ("notContains", "Does not contain", false), ("notEquals", "Is not", false),
        ("greaterThan", "Greater than", true), ("greaterOrEqual", "At least", true),
        ("lessThan", "Less than", true), ("lessOrEqual", "At most", true),
    ]

    // MARK: Ranges

    /// Numeric extent of a column; dates are measured in seconds since 1970.
    static func extent(_ data: VisualData, column: Int, isDate: Bool) -> (min: Double, max: Double)? {
        guard column < data.table.columnCount else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for v in data.table.columns[column].values {
            let d: Double?
            if isDate { d = v.asDate?.timeIntervalSince1970 } else { d = v.isNumber ? v.asDouble : nil }
            if let d, d.isFinite { lo = min(lo, d); hi = max(hi, d) }
        }
        return lo <= hi ? (lo, hi) : nil
    }

    static func isDateColumn(_ data: VisualData, column: Int) -> Bool {
        guard let c = data.table.columns[safe: column] else { return false }
        if c.type == .date || c.type == .dateTime { return true }
        if let first = c.values.first(where: { !$0.isNull }), case .date = first { return true }
        return false
    }
}

// MARK: - Relative dates

enum CmpSlRelative {
    static let dateUnits: [RelativeDateFilter.Unit] = [.days, .weeks, .calendarWeeks, .months, .calendarMonths, .years, .calendarYears]
    static let timeUnits: [RelativeDateFilter.Unit] = [.minutes, .hours]

    static func label(_ u: RelativeDateFilter.Unit, plural: Bool = true) -> String {
        switch u {
        case .minutes: return plural ? "minutes" : "minute"
        case .hours: return plural ? "hours" : "hour"
        case .days: return plural ? "days" : "day"
        case .weeks: return plural ? "weeks" : "week"
        case .calendarWeeks: return plural ? "calendar weeks" : "calendar week"
        case .months: return plural ? "months" : "month"
        case .calendarMonths: return plural ? "calendar months" : "calendar month"
        case .years: return plural ? "years" : "year"
        case .calendarYears: return plural ? "calendar years" : "calendar year"
        }
    }
    static func label(_ d: RelativeDateFilter.Direction) -> String {
        switch d { case .last: return "Last"; case .this: return "This"; case .next: return "Next" }
    }

    /// The closed interval the filter describes, anchored at `now` (UTC calendar, like the model).
    static func range(_ r: RelativeDateFilter, now: Date = Date(), calendar: Calendar = .utc) -> (start: Date, end: Date) {
        let n = max(1, r.count)
        let cal = calendar
        func add(_ c: Calendar.Component, _ v: Int, _ d: Date) -> Date { cal.date(byAdding: c, value: v, to: d) ?? d }
        func interval(_ c: Calendar.Component, _ d: Date) -> (Date, Date) {
            guard let i = cal.dateInterval(of: c, for: d) else { return (d, d) }
            return (i.start, i.end.addingTimeInterval(-1))
        }
        switch r.unit {
        case .minutes, .hours:
            let comp: Calendar.Component = r.unit == .minutes ? .minute : .hour
            switch r.direction {
            case .last: return (add(comp, -n, now), now)
            case .next: return (now, add(comp, n, now))
            case .this: return interval(comp, now)
            }
        case .days, .weeks, .months, .years:
            let comp: Calendar.Component = r.unit == .days ? .day : r.unit == .weeks ? .weekOfYear : r.unit == .months ? .month : .year
            let today = cal.startOfDay(for: now)
            let endOfToday = add(.day, 1, today).addingTimeInterval(-1)
            switch r.direction {
            case .this:
                return r.unit == .days ? (today, endOfToday) : interval(comp, now)
            case .last:
                if r.includeToday { return (add(.day, 1, add(comp, -n, today)), endOfToday) }
                return (add(comp, -n, today), today.addingTimeInterval(-1))
            case .next:
                if r.includeToday { return (today, add(comp, n, today).addingTimeInterval(-1)) }
                return (add(.day, 1, today), add(.day, 1, add(comp, n, today)).addingTimeInterval(-1))
            }
        case .calendarWeeks, .calendarMonths, .calendarYears:
            let comp: Calendar.Component = r.unit == .calendarWeeks ? .weekOfYear : r.unit == .calendarMonths ? .month : .year
            let cur = interval(comp, now)
            switch r.direction {
            case .this: return cur
            case .last: return (add(comp, -n, cur.0), cur.0.addingTimeInterval(-1))
            case .next:
                let start = cur.1.addingTimeInterval(1)
                return (start, add(comp, n, start).addingTimeInterval(-1))
            }
        }
    }

    static func summary(_ r: RelativeDateFilter, now: Date = Date()) -> String {
        let (s, e) = range(r, now: now)
        let isTime = r.unit == .minutes || r.unit == .hours
        let f = isTime ? "d MMM HH:mm" : "d MMM yyyy"
        let a = DateParsing.string(s, format: f), b = DateParsing.string(e, format: f)
        return a == b ? a : "\(a) – \(b)"
    }

    static func sentence(_ r: RelativeDateFilter) -> String {
        if r.direction == .this { return "This \(label(r.unit, plural: false))" }
        return "\(label(r.direction)) \(r.count) \(label(r.unit, plural: r.count != 1))"
    }
}

// MARK: - Input matching (public so the host's filter engine can share the exact semantics)

/// Evaluates an input slicer's applied values against a cell value.
///
/// Positive operators (`contains`, `startsWith`, `endsWith`, `equals`) match when ANY term matches;
/// negative operators (`notContains`, `notEquals`) when NO term matches; comparison operators use the
/// first term. Text comparison is case-insensitive. In `equals`/`notEquals`, `*` and `?` are wildcards.
public enum CmpSlInputMatcher {
    public static func matches(_ value: Value, terms: [Value], op: String) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = value.asString
        func one(_ t: Value) -> Bool {
            let s = t.asString
            switch op {
            case "startsWith": return text.range(of: s, options: [.caseInsensitive, .anchored]) != nil
            case "endsWith": return text.range(of: s, options: [.caseInsensitive, .anchored, .backwards]) != nil
            case "equals", "notEquals":
                if s.contains("*") || s.contains("?") { return wildcard(text, s) }
                if value.isNumber, let a = value.asDouble, let b = t.asDouble { return a == b }
                return text.caseInsensitiveCompare(s) == .orderedSame
            default: return text.range(of: s, options: .caseInsensitive) != nil
            }
        }
        switch op {
        case "notContains", "notEquals": return !terms.contains(where: one)
        case "greaterThan", "greaterOrEqual", "lessThan", "lessOrEqual":
            guard let t = terms.first else { return true }
            let order: ComparisonResult
            if let a = value.asDouble, let b = t.asDouble, !value.isNull { order = a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame) }
            else { order = text.compare(t.asString, options: [.caseInsensitive, .numeric]) }
            switch op {
            case "greaterThan": return order == .orderedDescending
            case "greaterOrEqual": return order != .orderedAscending
            case "lessThan": return order == .orderedAscending
            default: return order != .orderedDescending
            }
        default: return terms.contains(where: one)
        }
    }

    static func wildcard(_ text: String, _ pattern: String) -> Bool {
        var rx = "^"
        for ch in pattern {
            switch ch {
            case "*": rx += ".*"
            case "?": rx += "."
            default: rx += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        rx += "$"
        return text.range(of: rx, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
