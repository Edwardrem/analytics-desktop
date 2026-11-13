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
    static func plan(for table: ModelTable, data: DataTable?, filters: [String: GridColumnFilter]) -> Plan {
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
        return Plan(columns: columns, dataToken: dataToken(data))
    }

    /// A token that changes when the data's shape changes, so the grid reloads only then. Cell
    /// values are always read from the current table, so in-place edits only need the metadata
    /// refresh the grid already does when a column's type or format changes.
    static func dataToken(_ data: DataTable?) -> Int {
        guard let data else { return 0 }
        var token = data.rowCount &+ data.columnCount
        for c in data.columns { token = token &+ c.values.count &+ c.name.hashValue }
        return token
    }

    /// The visible row order for the view-only sort and filters; nil shows the table as stored.
    /// Pure; run it off the main thread for big tables.
    static func rows(for data: DataTable?, state: GridViewState) -> [Int]? {
        guard let data else { return nil }
        return GridIndexer.rows(data, state: state)
    }

    /// Tab-separated text for the rows and columns shown (sorted and filtered like the grid),
    /// formatted the way the grid formats them.
    static func tsv(data: DataTable?, columns: [GridColumn], rowIndex: [Int]?, headers: Bool) -> String {
        var out = ""
        if headers, !columns.isEmpty { out += columns.map(\.name).joined(separator: "\t") + "\n" }
        guard let data else { return out }
        for r in rowIndex ?? Array(0..<data.rowCount) {
            var first = true
            for c in columns {
                if !first { out += "\t" }
                first = false
                guard let di = c.dataIndex, di < data.columns.count else { continue }
                let values = data.columns[di].values
                let v = r < values.count ? values[r] : Value.null
                out += clean(ValueFormatter.format(v, c.format))
            }
            out += "\n"
        }
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    private static func clean(_ s: String) -> String {
        s.contains(where: { $0 == "\t" || $0 == "\n" })
            ? s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            : s
    }

    /// Columns the "Sort by column" picker offers: the other columns of the same table.
    static func sortByCandidates(for column: ModelColumn, in table: ModelTable) -> [ModelColumn] {
        table.columns.filter { !ModelDAX.same($0.name, column.name) }
    }
}
