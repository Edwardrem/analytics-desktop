import Foundation
import FacetCore

/// Pure Table-view logic: the grid's columns, change tokens, the visible row order and copy
/// text. Kept free of UI and document state so it can be unit-tested.
enum TableGrid {
    struct Plan: Equatable {
        var columns: [GridColumn]
        var dataToken: Int
    }

    /// Maps a model table and its data onto the grid's columns. `data` is nil for calculated
    /// tables before their first evaluation; columns then have no data and render blank cells.
    /// `filters` drives the per-column filter marks the header cells draw.
    static func plan(for table: ModelTable, data: DataTable?, filters: [String: GridColumnFilter], revision: Int = 0) -> Plan {
        var dataIndex: [String: Int] = [:]
        if let data {
            for (i, c) in data.columns.enumerated() where dataIndex[c.name.lowercased()] == nil {
                dataIndex[c.name.lowercased()] = i
            }
        }
        let columns = table.columns.map { c -> GridColumn in
            let di = dataIndex[c.name.lowercased()]
            var type = c.dataType
            if type == .any, let di, let data, data.columns.indices.contains(di) { type = data.columns[di].type }
            return GridColumn(name: c.name, type: type, format: c.formatString,
                              isCalculated: c.isCalculated || c.grouping != nil,
                              isHidden: c.isHidden, isKey: c.isKey, dataIndex: di,
                              isFiltered: filters[c.name]?.isActive == true,
                              glyph: ModelGlyph.symbol(for: c))
        }
        return Plan(columns: columns, dataToken: dataToken(data, revision: revision))
    }

    /// A token that changes when the grid has to reload: when the data's shape changes, or when
    /// `revision` does. A refresh can return the same shape with new values, and comparing every
    /// value is too slow for big tables, so the caller passes a counter that is bumped whenever
    /// the engine publishes data (`ModelingState.dataRevision`).
    static func dataToken(_ data: DataTable?, revision: Int = 0) -> Int {
        guard let data else { return 0 }
        var hasher = Hasher()
        hasher.combine(revision)
        hasher.combine(data.rowCount)
        hasher.combine(data.columnCount)
        for c in data.columns {
            hasher.combine(c.values.count)
            hasher.combine(c.name)
        }
        return hasher.finalize()
    }

    /// The token the grid compares to decide whether the row order changed: the view state's
    /// revision, plus how many off-thread row indexes have arrived (a big table's order lands
    /// after the render that asked for it).
    static func indexToken(gridRevision: Int, arrivals: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(gridRevision)
        hasher.combine(arrivals)
        return hasher.finalize()
    }

    /// The visible row order for the view-only sort and filters; nil shows the table as stored.
    /// Pure; run it off the main thread for big tables.
    static func rows(for data: DataTable?, state: GridViewState) -> [Int]? {
        guard let data else { return nil }
        return GridIndexer.rows(data, state: state)
    }

    /// Tab-separated text for the rows and columns shown (sorted and filtered like the grid),
    /// formatted the way the grid formats them. `rowIndex` lists data rows in order; nil copies
    /// every row as stored. This is the one TSV builder: the grid's cell, column and table copies
    /// and the workspace's copy all go through it. Rows are joined, never trimmed, so trailing
    /// blank rows survive.
    static func tsv(data: DataTable?, columns: [GridColumn], rowIndex: [Int]?, headers: Bool) -> String {
        var lines: [String] = []
        if headers, !columns.isEmpty { lines.append(columns.map { clean($0.name) }.joined(separator: "\t")) }
        if let data {
            let rows = rowIndex ?? Array(0..<data.rowCount)
            lines.reserveCapacity(lines.count + rows.count)
            for r in rows {
                var line = ""
                var first = true
                for c in columns {
                    if !first { line += "\t" }
                    first = false
                    guard let di = c.dataIndex, data.columns.indices.contains(di) else { continue }
                    let values = data.columns[di].values
                    guard values.indices.contains(r) else { continue }
                    line += clean(ValueFormatter.format(values[r], c.format))
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Tabs and line breaks inside a value would break the row and column structure.
    static func clean(_ s: String) -> String {
        s.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" })
            ? s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            : s
    }

    /// How many data rows a copy of the shown rows holds.
    static func copiedRowCount(data: DataTable?, rowIndex: [Int]?) -> Int {
        rowIndex?.count ?? data?.rowCount ?? 0
    }

    /// The status text after a copy has reached the pasteboard.
    static func copyMessage(rows: Int, of name: String) -> String {
        "Copied \(rows.formatted()) row\(rows == 1 ? "" : "s") of \(name)."
    }

    /// "sorted", "filtered" or "sorted & filtered" for the status line; empty when neither.
    static func viewStateCaption(_ state: GridViewState) -> String {
        let sorted = state.sortColumn != nil
        let filtered = state.filters.values.contains { $0.isActive }
        switch (sorted, filtered) {
        case (true, true): return "sorted & filtered"
        case (true, false): return "sorted"
        case (false, true): return "filtered"
        case (false, false): return ""
        }
    }

    // MARK: Sort by column

    /// True when following "sort by column" links from `start` arrives at `target` (a column
    /// reaches itself). Stops on a repeat, so a cycle already in a document can't loop forever.
    static func sortChain(from start: String, reaches target: String, in table: ModelTable) -> Bool {
        var seen = Set<String>()
        var current: String? = start
        while let name = current, let column = table.column(name) {
            if ModelDAX.same(column.name, target) { return true }
            if !seen.insert(column.name.lowercased()).inserted { return false }
            current = column.sortByColumn
        }
        return false
    }

    /// Columns the "Sort by column" picker offers: the other columns of the same table whose own
    /// sort order does not depend on this column (A can't sort by B while B sorts by A).
    static func sortByCandidates(for column: ModelColumn, in table: ModelTable) -> [ModelColumn] {
        table.columns.filter { !sortChain(from: $0.name, reaches: column.name, in: table) }
    }

    /// Why `column` can't be sorted by `other`, or nil when it can. With `data`, also checks the
    /// rule Power BI enforces: each value of the column maps to exactly one value of the other.
    static func sortByProblem(column: String, by other: String, in table: ModelTable, data: DataTable?) -> String? {
        guard let target = table.column(column) else { return "“\(column)” is not a column of \(table.name)." }
        guard let by = table.column(other) else { return "“\(other)” is not a column of \(table.name)." }
        if ModelDAX.same(target.name, by.name) { return "A column can't be sorted by itself." }
        if sortChain(from: by.name, reaches: target.name, in: table) {
            return "“\(by.name)” is already sorted by “\(target.name)”, so “\(target.name)” can't be sorted by it."
        }
        guard let data, let a = data.column(target.name), let b = data.column(by.name) else { return nil }
        var mapped: [Value: Value] = [:]
        for i in 0..<min(a.values.count, b.values.count) {
            if let known = mapped[a.values[i]] {
                if known != b.values[i] {
                    return "Can't sort “\(target.name)” by “\(by.name)”: there is more than one value in “\(by.name)” for the same value in “\(target.name)”."
                }
            } else {
                mapped[a.values[i]] = b.values[i]
            }
        }
        return nil
    }

    // MARK: Tools

    /// What the Table view's tool strip edits.
    enum ToolsTarget: Equatable {
        case column(table: String, name: String)
        case measure(table: String, name: String)
        case table(String)
    }

    /// The selected column or measure when it still exists; otherwise the table the grid shows.
    /// A selection that no longer resolves (after undo, or a rename made elsewhere) falls back to
    /// the shown table, so the tools never disappear.
    static func toolsTarget(primary: ModelObjectRef?, shown: String, model: SemanticModel) -> ToolsTarget {
        switch primary {
        case .column(let t, let n)?:
            if let table = model.table(t), let column = table.column(n) { return .column(table: table.name, name: column.name) }
        case .measure(let t, let n)?:
            if let table = model.table(t), let measure = table.measure(n) { return .measure(table: table.name, name: measure.name) }
        default: break
        }
        return .table(model.table(shown)?.name ?? shown)
    }
}

/// Identifies one computed row order: the table, its data and the view state it was built from.
struct RowsKey: Hashable {
    var table: String
    var dataToken: Int
    var gridRevision: Int
}

/// Remembers the last row order the Table view computed, so a render that changes nothing about
/// the table, its data or its sort and filters (typing in the formula bar, hovering) reuses it
/// instead of filtering and sorting again.
final class RowIndexCache {
    private var key: RowsKey?
    private var rows: [Int]?
    /// How many times a row order was computed; lets tests see the cache working.
    private(set) var computations = 0

    /// The cached order for `key`, and whether there is one (a cached order may itself be nil).
    func lookup(_ key: RowsKey) -> (hit: Bool, rows: [Int]?) {
        self.key == key ? (true, rows) : (false, nil)
    }

    func store(_ rows: [Int]?, for key: RowsKey) {
        self.key = key
        self.rows = rows
    }

    /// The order for `key`, computing it only when the key differs from the cached one.
    func rows(for key: RowsKey, compute: () -> [Int]?) -> [Int]? {
        let cached = lookup(key)
        if cached.hit { return cached.rows }
        computations += 1
        let fresh = compute()
        store(fresh, for: key)
        return fresh
    }
}
