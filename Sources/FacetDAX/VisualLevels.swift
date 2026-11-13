import Foundation
import FacetCore

/// The grids of a visual at its higher levels, in the column layout of its deepest grid.
final class VisualLevels {
    private let leaf: TableValue
    private let axis: [Int]
    /// Supplied level grids, keyed by the axis columns they keep.
    private var cache: [[Int]: TableValue] = [:]

    init(leaf: TableValue, axis: [Int], supplied: [DataTable]) {
        self.leaf = leaf
        self.axis = axis
        cache[axis.sorted()] = leaf
        for level in supplied {
            // Map the level's columns onto the leaf layout by name; columns it lacks are blank.
            let source = leaf.cols.infos.map { level.columnIndex($0.name) }
            let kept = axis.filter { source[$0] != nil }.sorted()
            let rows: [[Value]] = (0..<level.rowCount).map { r in
                source.map { $0.map { level.columns[$0].values[safe: r] ?? .null } ?? .null }
            }
            cache[kept] = TableValue(cols: leaf.cols, rows: rows)
        }
    }

    /// The grid that keeps only the given axis columns: one row per combination of their values.
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
        let rows: [[Value]] = order.map { k in
            let members = groups[k] ?? []
            return (0..<leaf.cols.count).map { c in
                if keptSet.contains(c) { return leaf.data[members[0]][safe: c] ?? .null }
                if axisSet.contains(c) { return .null }
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
