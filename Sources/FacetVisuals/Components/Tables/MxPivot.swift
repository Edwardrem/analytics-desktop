import Foundation
import FacetCore

/// How a matrix value is aggregated into subtotals and grand totals (`format["totals"][<value name>]`).
enum CmpMxAggregate: String, CaseIterable {
    case sum, min, max, count, distinctCount, average, none
}

/// A row- or column-header node in the pivot tree. The root has an empty path.
final class CmpMxNode {
    let id: Int
    let path: [Value]
    weak var parent: CmpMxNode?
    var children: [CmpMxNode] = []
    fileprivate var childIndex: [Value: Int] = [:]
    /// Data rows under this node.
    var rows: [Int] = []
    init(id: Int, path: [Value], parent: CmpMxNode?) { self.id = id; self.path = path; self.parent = parent }
    var depth: Int { path.count }
    var isLeaf: Bool { children.isEmpty }
    /// Stable identity of the node within its tree, used in `VisualSpec.expandedPaths`.
    var pathKey: String { path.map(\.asString).joined(separator: "\u{1F}") }
}

/// Running aggregate of the values that fall into one matrix cell.
struct CmpMxAcc {
    var sum = 0.0
    var numbers = 0
    var nonNull = 0
    var lo = Double.infinity, hi = -Double.infinity
    var first: Value = .null
    var contributions = 0
    var distinct: Set<Value>?

    mutating func add(_ v: Value, trackDistinct: Bool) {
        contributions += 1
        guard !v.isNull else { return }
        if nonNull == 0 { first = v }
        nonNull += 1
        if v.isNumber, let d = v.asDouble, d.isFinite {
            sum += d; numbers += 1
            lo = Swift.min(lo, d); hi = Swift.max(hi, d)
        }
        if trackDistinct {
            if distinct == nil { distinct = [] }
            distinct?.insert(v)
        }
    }

    func result(_ agg: CmpMxAggregate) -> Value {
        guard nonNull > 0 else { return .null }
        switch agg {
        case .none: return .null
        case .count: return .int(Int64(nonNull))
        case .distinctCount: return .int(Int64(distinct?.count ?? 0))
        case .sum: return numbers > 0 ? .double(sum) : .null
        case .average: return numbers > 0 ? .double(sum / Double(numbers)) : .null
        case .min: return numbers > 0 ? .double(lo) : .null
        case .max: return numbers > 0 ? .double(hi) : .null
        }
    }
}

/// Pivots a long result (row fields, column fields, values) into two header trees and aggregated cells.
/// Header order follows first appearance in the data, so the query's sort order is preserved.
final class CmpMxPivot {
    let rowRoot: CmpMxNode
    let colRoot: CmpMxNode
    let valueCols: [Int]
    let aggregates: [CmpMxAggregate]
    private let table: DataTable
    private let totals: [Value]
    private var colNodeCount = 0
    private var rowNodeCount = 0
    private var colLeafOfRow: [CmpMxNode] = []
    private var cache: [Int: [CmpMxAcc]] = [:]

    init(data: VisualData, rowCols: [Int], colCols: [Int], valueCols: [Int], aggregates: [CmpMxAggregate]) {
        table = data.table
        totals = data.totals
        self.valueCols = valueCols
        self.aggregates = valueCols.indices.map { aggregates[safe: $0] ?? .sum }
        rowRoot = CmpMxNode(id: 0, path: [], parent: nil)
        colRoot = CmpMxNode(id: 0, path: [], parent: nil)
        rowNodeCount = 1; colNodeCount = 1
        let n = table.rowCount
        colLeafOfRow.reserveCapacity(n)
        let rowValues = rowCols.map { table.columns[$0].values }
        let colValues = colCols.map { table.columns[$0].values }
        for r in 0..<n {
            var node = rowRoot
            node.rows.append(r)
            for level in rowValues {
                node = child(of: node, value: level[r], counter: &rowNodeCount)
                node.rows.append(r)
            }
            var c = colRoot
            for level in colValues { c = child(of: c, value: level[r], counter: &colNodeCount) }
            colLeafOfRow.append(c)
        }
    }

    private func child(of node: CmpMxNode, value: Value, counter: inout Int) -> CmpMxNode {
        if let i = node.childIndex[value] { return node.children[i] }
        let c = CmpMxNode(id: counter, path: node.path + [value], parent: node)
        counter += 1
        node.childIndex[value] = node.children.count
        node.children.append(c)
        return c
    }

    /// Accumulators for one row node: index = colNode.id * valueCount + valueIndex.
    private func accumulators(_ row: CmpMxNode) -> [CmpMxAcc] {
        if let c = cache[row.id] { return c }
        let vc = valueCols.count
        var acc = [CmpMxAcc](repeating: CmpMxAcc(), count: colNodeCount * max(vc, 1))
        let columns = valueCols.map { table.columns[$0].values }
        let distinct = aggregates.map { $0 == .distinctCount }
        for r in row.rows {
            var node: CmpMxNode? = colLeafOfRow[r]
            while let n = node {
                for v in 0..<vc { acc[n.id * vc + v].add(columns[v][r], trackDistinct: distinct[v]) }
                node = n.parent
            }
        }
        cache[row.id] = acc
        return acc
    }

    /// The column leaf a data row falls under.
    func colLeaf(of row: Int) -> CmpMxNode? { colLeafOfRow[safe: row] }

    /// True when the cell (row × col) is a detail cell rather than a subtotal.
    func isDetail(row: CmpMxNode, col: CmpMxNode) -> Bool { row.isLeaf && col.isLeaf }

    /// The one data row behind a detail cell; nil for a subtotal or a cell several rows make up.
    func sourceRow(row: CmpMxNode, col: CmpMxNode) -> Int? {
        guard isDetail(row: row, col: col) else { return nil }
        var found: Int?
        for r in row.rows where colLeafOfRow[safe: r] === col {
            if found != nil { return nil }
            found = r
        }
        return found
    }

    /// The value shown at (row node × column node) for value index `v`.
    /// Detail cells backed by one data row show that row's value untouched; everything else aggregates
    /// with the value's aggregate. The grand total uses the query's `totals` when supplied.
    func value(row: CmpMxNode, col: CmpMxNode, v: Int) -> Value {
        guard v < valueCols.count else { return .null }
        if row === rowRoot, col === colRoot, let t = totals[safe: valueCols[v]], !t.isNull,
           !(rowRoot.isLeaf && colRoot.isLeaf) { return t }
        let acc = accumulators(row)[col.id * valueCols.count + v]
        if isDetail(row: row, col: col) {
            if acc.contributions == 1 { return acc.first }
            return acc.contributions == 0 ? .null : acc.result(aggregates[v] == .none ? .sum : aggregates[v])
        }
        return acc.result(aggregates[v])
    }

    /// True when at least one data row falls under (row × col) — used to leave empty cells blank.
    func hasData(row: CmpMxNode, col: CmpMxNode) -> Bool {
        guard !valueCols.isEmpty else { return false }
        return accumulators(row)[col.id * valueCols.count].contributions > 0
    }
}
