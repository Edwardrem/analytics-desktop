import Foundation
import FacetCore

/// The grids of a visual at its higher levels, in the column layout of its deepest grid.
final class VisualLevels {
    private let leaf: TableValue
    private let axis: [Int]
    private var cache: [[Int]: TableValue] = [:]
    /// Supplied level grids in the leaf layout (nil where the level lacks a column), keyed by the axis columns they keep.
    private var supplied: [[Int]: [[Value?]]] = [:]

    /// - Parameter names: the grid's column names, by which supplied levels are matched.
    init(leaf: TableValue, names: [String], axis: [Int], supplied levels: [DataTable]) {
        self.leaf = leaf
        self.axis = axis
        cache[axis.sorted()] = leaf
        for level in levels {
            let source = names.map { level.columnIndex($0) }
            let kept = axis.filter { source[safe: $0].flatMap { $0 } != nil }.sorted()
            supplied[kept] = (0..<level.rowCount).map { r in
                source.map { $0.map { level.columns[$0].values[safe: r] ?? .null } }
            }
        }
    }

    /// The grid that keeps only the given axis columns: one row per combination of their values.
    /// Values come from the supplied grid of that level; a column it lacks, or a level that was
    /// not supplied, is summed from the leaf rows.
    func grid(keeping kept: [Int]) -> TableValue {
        let key = kept.sorted()
        if let hit = cache[key] { return hit }
        let keptSet = Set(key), axisSet = Set(axis)
        var order: [[Value]] = []
        var groups: [[Value]: [Int]] = [:]
        for (r, row) in leaf.data.enumerated() {
            let k = key.map { row[safe: $0] ?? .null }
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(r)
        }
        // The grand total exists even for an empty grid.
        if key.isEmpty, order.isEmpty { order = [[]]; groups[[]] = [] }
        var real: [[Value]: [Value?]] = [:]
        for row in supplied[key] ?? [] {
            let k = key.map { (row[safe: $0] ?? nil) ?? .null }
            if real[k] == nil { real[k] = row }
        }
        let rows: [[Value]] = order.map { k in
            let members = groups[k] ?? []
            return (0..<leaf.cols.count).map { c in
                if keptSet.contains(c) { return members.first.map { leaf.data[$0][safe: c] ?? .null } ?? .null }
                if axisSet.contains(c) { return .null }
                if let value = real[k]?[safe: c] ?? nil { return value }
                return VisualLevels.sum(members.map { leaf.data[$0][safe: c] ?? .null })
            }
        }
        let out = TableValue(cols: leaf.cols, rows: rows)
        cache[key] = out
        return out
    }

    /// The sum of the numeric values; blank when there are none.
    static func sum(_ values: [Value]) -> Value {
        var total = 0.0, any = false, allInt = true
        for v in values where v.isNumber {
            guard let d = v.asDouble else { continue }
            total += d; any = true
            if case .int = v {} else { allInt = false }
        }
        guard any else { return .null }
        return allInt ? .int(Int64(total)) : .double(total)
    }
}
