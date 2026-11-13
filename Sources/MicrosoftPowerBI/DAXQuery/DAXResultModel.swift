import Foundation
import FacetCore

/// A view-only filter on one result column: a simple condition plus a set of excluded values.
struct DAXColumnFilter: Equatable {
    enum Op: String, CaseIterable, Identifiable {
        case none, contains, notContains, equals, notEquals, startsWith, endsWith
        case greater, greaterOrEqual, less, lessOrEqual, isBlank, isNotBlank
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Any value"
            case .contains: return "Contains"
            case .notContains: return "Does not contain"
            case .equals: return "Is"
            case .notEquals: return "Is not"
            case .startsWith: return "Starts with"
            case .endsWith: return "Ends with"
            case .greater: return "Greater than"
            case .greaterOrEqual: return "Greater than or equal to"
            case .less: return "Less than"
            case .lessOrEqual: return "Less than or equal to"
            case .isBlank: return "Is blank"
            case .isNotBlank: return "Is not blank"
            }
        }
        var needsOperand: Bool { self != .none && self != .isBlank && self != .isNotBlank }
    }
    var op: Op = .none
    var operand: String = ""
    /// Distinct values switched off in the value list.
    var excluded: Set<Value> = []

    var conditionActive: Bool { op != .none && (!op.needsOperand || !operand.isEmpty) }
    var isActive: Bool { conditionActive || !excluded.isEmpty }

    /// `display` is the formatted cell text, used for text matching.
    func matches(_ v: Value, display: @autoclosure () -> String) -> Bool {
        if !excluded.isEmpty, excluded.contains(v) { return false }
        guard conditionActive else { return true }
        switch op {
        case .none: return true
        case .isBlank: return v.isNull || v == .string("")
        case .isNotBlank: return !(v.isNull || v == .string(""))
        case .contains: return display().localizedCaseInsensitiveContains(operand)
        case .notContains: return !display().localizedCaseInsensitiveContains(operand)
        case .startsWith: return display().lowercased().hasPrefix(operand.lowercased())
        case .endsWith: return display().lowercased().hasSuffix(operand.lowercased())
        case .equals, .notEquals:
            let equal: Bool
            if let c = compare(v) { equal = c == 0 }
            else { equal = display().caseInsensitiveCompare(operand) == .orderedSame || v.asString.caseInsensitiveCompare(operand) == .orderedSame }
            return op == .equals ? equal : !equal
        case .greater, .greaterOrEqual, .less, .lessOrEqual:
            guard !v.isNull else { return false }
            let c: Int
            if let n = compare(v) { c = n }
            else {
                switch v.asString.caseInsensitiveCompare(operand) { case .orderedAscending: c = -1; case .orderedDescending: c = 1; default: c = 0 }
            }
            switch op {
            case .greater: return c > 0
            case .greaterOrEqual: return c >= 0
            case .less: return c < 0
            default: return c <= 0
            }
        }
    }

    /// Numeric or date comparison of the value with the operand: -1, 0, 1; nil when either side isn't comparable that way.
    private func compare(_ v: Value) -> Int? {
        switch v {
        case .int, .double, .bool:
            guard let a = v.asDouble, let b = DataTable.parseNumber(operand) else { return nil }
            return a < b ? -1 : (a > b ? 1 : 0)
        case .date(let d):
            guard let b = DateParsing.parse(operand) else { return nil }
            return d < b ? -1 : (d > b ? 1 : 0)
        default: return nil
        }
    }
}

/// A rectangular block of selected cells in display coordinates.
struct DAXCellSelection: Equatable {
    var anchorRow: Int, anchorColumn: Int
    var focusRow: Int, focusColumn: Int
    var rows: ClosedRange<Int> { min(anchorRow, focusRow)...max(anchorRow, focusRow) }
    var columns: ClosedRange<Int> { min(anchorColumn, focusColumn)...max(anchorColumn, focusColumn) }
}

/// One result table plus its view state: sort, per-column filters and selection. The data is never copied or changed.
@MainActor
final class DAXResultModel: ObservableObject, Identifiable {
    let id = UUID()
    let table: DataTable
    /// Format string per column ("" = default formatting for the value).
    let formats: [String]
    let rightAligned: [Bool]

    /// Display order as source row indices; nil means every row in source order.
    private(set) var order: [Int]?
    @Published private(set) var revision = 0
    @Published private(set) var sort: (column: Int, ascending: Bool)?
    @Published private(set) var filters: [Int: DAXColumnFilter] = [:]
    @Published private(set) var isWorking = false
    var selection: DAXCellSelection?
    private var generation = 0

    init(table: DataTable, model: SemanticModel) {
        self.table = table
        self.formats = table.columns.map { DAXResultFormat.format(for: $0, model: model) }
        self.rightAligned = table.columns.map { c in
            if c.type.isNumeric { return true }
            if c.type == .any, let v = c.values.first(where: { !$0.isNull }) { return v.isNumber }
            return false
        }
    }

    var rowCount: Int { order?.count ?? table.rowCount }
    var totalRows: Int { table.rowCount }
    var columnCount: Int { table.columnCount }
    var isFiltered: Bool { filters.values.contains { $0.isActive } }

    func sourceRow(_ displayRow: Int) -> Int { order?[displayRow] ?? displayRow }
    func value(row: Int, column: Int) -> Value { table.columns[column].values[sourceRow(row)] }
    func text(row: Int, column: Int) -> String { DAXResultFormat.text(value(row: row, column: column), formats[column]) }

    func filter(_ column: Int) -> DAXColumnFilter { filters[column] ?? DAXColumnFilter() }

    func setFilter(_ filter: DAXColumnFilter, column: Int) {
        guard self.filter(column) != filter else { return }
        filters[column] = filter == DAXColumnFilter() ? nil : filter
        recompute()
    }
    func clearFilters() { guard !filters.isEmpty else { return }; filters = [:]; recompute() }

    /// Header click: ascending → descending → source order.
    func cycleSort(column: Int) {
        if let s = sort, s.column == column { sort = s.ascending ? (column, false) : nil } else { sort = (column, true) }
        recompute()
    }
    func setSort(column: Int, ascending: Bool?) {
        sort = ascending.map { (column, $0) }
        recompute()
    }

    /// Computes the display order for the given view state. Pure, so it can run off the main thread.
    nonisolated static func order(table: DataTable, formats: [String], filters: [Int: DAXColumnFilter],
                                  sort: (column: Int, ascending: Bool)?) -> [Int]? {
        let active = filters.filter { $0.value.isActive && $0.key < table.columnCount }.sorted { $0.key < $1.key }
        if active.isEmpty, sort == nil { return nil }
        var rows: [Int]
        if active.isEmpty { rows = Array(0..<table.rowCount) } else {
            rows = []
            for r in 0..<table.rowCount {
                var keep = true
                for (c, f) in active {
                    let v = table.columns[c].values[r]
                    if !f.matches(v, display: DAXResultFormat.text(v, formats[c])) { keep = false; break }
                }
                if keep { rows.append(r) }
            }
        }
        if let sort, sort.column < table.columnCount {
            let values = table.columns[sort.column].values
            rows.sort { a, b in
                let x = values[a], y = values[b]
                if x == y { return a < b }
                return sort.ascending ? x < y : y < x
            }
        }
        return rows
    }

    private func recompute() {
        generation += 1
        let gen = generation
        selection = nil
        let table = self.table, formats = self.formats, filters = self.filters, sort = self.sort
        if table.rowCount <= 20_000 {
            order = Self.order(table: table, formats: formats, filters: filters, sort: sort)
            isWorking = false
            revision += 1
            return
        }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            let result = Self.order(table: table, formats: formats, filters: filters, sort: sort)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.order = result
                self.isWorking = false
                self.revision += 1
            }
        }
    }

    // MARK: Copy and export

    /// Tab-separated text of the given display rows and columns, using the formatted cell text.
    func tsv(rows: ClosedRange<Int>? = nil, columns: ClosedRange<Int>? = nil, headers: Bool) -> String {
        guard columnCount > 0 else { return "" }
        let cols = columns ?? 0...(columnCount - 1)
        func clean(_ s: String) -> String {
            s.contains(where: { $0 == "\t" || $0.isNewline }) ? String(s.map { $0 == "\t" || $0.isNewline ? " " : $0 }) : s
        }
        var lines: [String] = []
        if headers { lines.append(cols.map { clean(table.columns[$0].name) }.joined(separator: "\t")) }
        if rowCount > 0 {
            for r in rows ?? 0...(rowCount - 1) {
                lines.append(cols.map { clean(text(row: r, column: $0)) }.joined(separator: "\t"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// RFC 4180 CSV (CRLF line ends, quoted where needed) of the rows as displayed, with unformatted values.
    func csv() -> String {
        var out = table.columns.map { DAXResultFormat.csvField($0.name) }.joined(separator: ",") + "\r\n"
        out.reserveCapacity(rowCount * columnCount * 8)
        for r in 0..<rowCount {
            let src = sourceRow(r)
            var first = true
            for c in table.columns {
                if !first { out.append(",") }
                first = false
                out.append(DAXResultFormat.csvField(DAXResultFormat.raw(c.values[src])))
            }
            out.append("\r\n")
        }
        return out
    }
}

/// Formatting rules for result cells.
enum DAXResultFormat {
    /// Splits a result column name such as `Sales[Amount]`, `'My Table'[Col]` or `[Measure]`.
    static func parseName(_ name: String) -> (table: String?, name: String)? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.hasSuffix("]"), let open = n.firstIndex(of: "[") else { return nil }
        let inner = String(n[n.index(after: open)..<n.index(before: n.endIndex)]).replacingOccurrences(of: "]]", with: "]")
        var table = String(n[..<open]).trimmingCharacters(in: .whitespaces)
        if table.count >= 2, table.hasPrefix("'"), table.hasSuffix("'") {
            table = String(table.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return (table.isEmpty ? nil : table, inner)
    }

    /// The model's format string when the column maps to a model column or measure; otherwise a default for its type.
    static func format(for column: DataColumn, model: SemanticModel) -> String {
        let parsed = parseName(column.name)
        if let p = parsed {
            if let t = p.table, let table = model.table(t) {
                if let c = table.column(p.name), !c.formatString.isEmpty { return c.formatString }
                if let m = table.measure(p.name), !m.formatString.isEmpty { return m.formatString }
            } else if let m = model.measure(p.name), !m.measure.formatString.isEmpty {
                return m.measure.formatString
            }
        }
        switch column.type {
        case .integer:
            // Model columns are usually keys and years; computed values read better grouped.
            return parsed != nil && parsed?.table == nil ? "#,0" : "0"
        case .currency: return "#,0.00"
        case .date: return "yyyy-MM-dd"
        default: return ""
        }
    }

    static func text(_ value: Value, _ format: String) -> String {
        if format.isEmpty, case .date(let d) = value {
            let hasTime = d.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) != 0
            return ValueFormatter.formatDate(d, hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd")
        }
        return ValueFormatter.format(value, format)
    }

    /// Unformatted, machine-readable text for export.
    static func raw(_ value: Value) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .int(let i): return String(i)
        case .double(let d):
            guard d.isFinite else { return "" }
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return s
        case .date(let d):
            let hasTime = d.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) != 0
            return ValueFormatter.formatDate(d, hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd")
        }
    }

    static func csvField(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) || s.hasPrefix(" ") || s.hasSuffix(" ") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func glyph(for type: DataType) -> String {
        switch type {
        case .text: return "textformat"
        case .integer, .decimal, .duration: return "number"
        case .currency: return "dollarsign"
        case .boolean: return "checkmark.square"
        case .date, .dateTime: return "calendar"
        case .time: return "clock"
        case .binary: return "doc"
        case .any: return "circle.dashed"
        }
    }
}
