import Foundation
import FacetCore

/// Sparklines in a matrix. Each detail row of the result carries its series at every point of the
/// sparkline's axis across the whole visual ("10.0||30.0": a blank where that row has no value), so
/// subtotal and total cells can combine the rows under them point by point, with the value's
/// subtotal aggregate, as the matrix does for its numbers.
public enum MatrixSparkline {
    /// The cell text for one row's series along the shared axis.
    public static func encode(_ points: [Double?]) -> Value {
        .string(points.map { $0.map { "\($0)" } ?? "" }.joined(separator: "|"))
    }

    /// The series a cell carries; nil when the cell isn't a matrix sparkline.
    public static func decode(_ v: Value) -> [Double?]? {
        guard case .string(let s) = v, !s.isEmpty else { return nil }
        var out: [Double?] = []
        for part in s.split(separator: "|", omittingEmptySubsequences: false) {
            if part.isEmpty { out.append(nil); continue }
            guard let d = Double(part), d.isFinite else { return nil }
            out.append(d)
        }
        return out
    }

    /// The points a cell draws: the rows' series combined at each axis point with `aggregate`,
    /// leaving out points where none of the rows has a value.
    static func combine(_ series: [[Double?]], _ aggregate: CmpMxAggregate) -> [Double] {
        let length = series.map(\.count).max() ?? 0
        guard length > 0, aggregate != .none else { return [] }
        return (0..<length).compactMap { i in
            let values = series.compactMap { $0[safe: i] ?? nil }
            guard !values.isEmpty else { return nil }
            switch aggregate {
            case .sum: return values.reduce(0, +)
            case .average: return values.reduce(0, +) / Double(values.count)
            case .min: return values.min()
            case .max: return values.max()
            case .count: return Double(values.count)
            case .distinctCount: return Double(Set(values).count)
            case .none: return nil
            }
        }
    }
}

extension MatrixSparkline {
    /// The value indices of a matrix drawn as sparklines, each with whether it draws columns.
    static func kinds(_ env: CmpEnv, valueCols: [Int]) -> [Int: Bool] {
        let card = env.spec.format["sparklines"] ?? [:]
        var out: [Int: Bool] = [:]
        for (v, c) in valueCols.enumerated() where c < env.data.table.columnCount {
            if let sp = card[env.data.table.columns[c].name] ?? card[env.caption(c)] {
                out[v] = sp["type"]?.stringValue == "column"
            }
        }
        return out
    }

    /// A cell's points: the series of the rows under it combined point by point with the value's
    /// subtotal aggregate (one row: its own series).
    static func points(_ pivot: CmpMxPivot, _ table: DataTable, row: CmpMxNode, col: CmpMxNode, v: Int) -> [Double]? {
        guard let c = pivot.valueCols[safe: v], c < table.columnCount else { return nil }
        let rows = pivot.rows(row: row, col: col)
        let series = rows.compactMap { decode(table[$0, c]) }
        let points = combine(series, rows.count == 1 ? .sum : pivot.aggregates[safe: v] ?? .sum)
        return points.isEmpty ? nil : points
    }
}

extension CmpMxPivot {
    /// The data rows under both a row node and a column node.
    func rows(row: CmpMxNode, col: CmpMxNode) -> [Int] {
        guard col !== colRoot else { return row.rows }
        return row.rows.filter { r in
            var node: CmpMxNode? = colLeaf(of: r)
            while let n = node {
                if n === col { return true }
                node = n.parent
            }
            return false
        }
    }
}
