import Foundation
import FacetCore

extension MTable {
    /// A copy of this table with other columns (names, types and data), all of the given row count.
    static func make(_ names: [String], _ types: [MType], _ columns: [[MValue]], rows: Int) throws -> MTable {
        if let dup = Dictionary(grouping: names, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw MError("The field '\(dup)' already exists in the record.", detail: .text(dup))
        }
        return MTable(names: names, types: types, columns: columns, rowCount: rows)
    }
    /// Same schema, different rows (row-major).
    func with(rows: [[MValue]]) -> MTable { MTable(names: columnNames, types: columnTypes, rows: rows) }
    /// Indices of the named columns; a missing column is an error unless `missing` says otherwise
    /// (`MissingField.Ignore` = 1 drops it, `MissingField.UseNull` = 2 yields nil).
    func indices(of names: [String], missing: Int = 0) throws -> [Int?] {
        var out: [Int?] = []
        for n in names {
            if let i = columnIndex(n) { out.append(i) }
            else if missing == 2 { out.append(nil) }
            else if missing != 1 { _ = try requireColumn(n) }
        }
        return out
    }
    func requiredIndices(_ names: [String]) throws -> [Int] { try names.map(requireColumn) }
    /// Apply `f` to every cell of column `i`, capturing failures as cell errors.
    func mappingColumn(_ i: Int, type: MType? = nil, _ f: (MValue) throws -> MValue) throws -> MTable {
        var cols = try columns, types = columnTypes
        cols[i] = cols[i].map { cell in MValue.capturing { try f(try cell.forced()) } }
        if let type { types[i] = type }
        return MTable(names: columnNames, types: types, columns: cols, rowCount: try rowCount)
    }
}

extension MLib {
    /// Hashable key of a row over some columns.
    static func rowKey(_ cols: [[MValue]], _ indices: [Int], _ row: Int, ignoreCase: Bool = false) -> MKey {
        MKey(.list(indices.map { cols[$0][row].forcedCell() }), ignoreCase: ignoreCase)
    }
    /// The `columns` argument of table constructors: names, a table type, a column count, or nothing.
    static func columnSpec(_ v: MValue, defaultCount: Int) throws -> (names: [String], types: [MType]?) {
        switch v {
        case .null: return ((0..<defaultCount).map { "Column\($0 + 1)" }, nil)
        case .number(let n): return ((0..<Int(n)).map { "Column\($0 + 1)" }, nil)
        case .text(let s): return ([s], nil)
        case .list(let l):
            return (try l.map { item in
                guard case .text(let s) = try item.forced() else { throw MError("Column names must be text.") }
                return s
            }, nil)
        case .type(let t):
            guard case .table(let f) = t.nonNullable else { throw MError("A table type is needed to describe the columns.") }
            return (f.map(\.name), f.map(\.type))
        default: throw MError.typeMismatch(expected: "list", got: v)
        }
    }
    /// Pairs such as `{"a", x}` or `{{"a", x}, {"b", y}}` (also triples); returns each inner list.
    static func specList(_ v: MValue) throws -> [[MValue]] {
        guard case .list(let outer) = v else { throw MError.typeMismatch(expected: "list", got: v) }
        let forced = try outer.map { try $0.forced() }
        if let first = forced.first, case .list = first {
            return try forced.map { item in
                guard case .list(let inner) = item else { throw MError.typeMismatch(expected: "list", got: item) }
                return try inner.map { try $0.forced() }
            }
        }
        return forced.isEmpty ? [] : [forced]
    }
    /// Sort keys when the criteria name columns only (what a source can fold); nil for functions.
    static func sortColumns(_ criteria: MValue) -> [(column: String, descending: Bool)]? {
        switch criteria {
        case .text(let s): return [(s, false)]
        case .list(let items):
            if items.count == 2, case .text(let s) = items[0], case .number(let o) = items[1] { return [(s, o == 1)] }
            var out: [(column: String, descending: Bool)] = []
            for item in items {
                guard let part = sortColumns(item.forcedCell()), part.count == 1 else { return nil }
                out.append(part[0])
            }
            return out
        default: return nil
        }
    }
}
