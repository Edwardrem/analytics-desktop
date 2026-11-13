import Foundation
import FacetCore

/// A slice of the data whose distribution over the category differs from the overall distribution.
public struct DistributionSlice: Sendable {
    public struct Share: Sendable {
        public var category: Value
        /// Share within the slice and overall, 0…1.
        public var slice: Double
        public var overall: Double
        /// Raw measure value within the slice.
        public var value: Double
    }
    public var dimension: FieldRef
    public var value: Value
    /// Jensen–Shannon divergence (base 2) between the slice's and the overall distribution: 0 = identical, 1 = disjoint.
    public var divergence: Double
    /// Chi-square goodness-of-fit statistic of the slice against the overall shares, and its p-value.
    /// The p-value is only meaningful when the measure is a count.
    public var chiSquare: Double
    public var pValue: Double
    /// The slice's share of the overall total, 0…1.
    public var weight: Double
    /// Per-category comparison, in the overall category order.
    public var shares: [Share]
    public var sentence: String
    /// Filter selecting this slice.
    public var filter: FilterSpec {
        var f = FilterSpec(field: dimension, kind: .basic)
        f.values = [value]
        return f
    }
}

/// "Find where this distribution is different".
public enum DistributionDifference {
    /// Compares the distribution of the measure over `category` overall against its distribution within each
    /// value of every other dimension and returns the most different slices.
    /// - Parameters:
    ///   - category: the axis of the distribution being examined.
    ///   - dimensions: other fields whose values define candidate slices.
    ///   - filters: context filters passed to every query.
    ///   - query: see `AnalyticsQuery`. Called with `[category]` and `[dimension, category]`.
    ///   - minimumWeight: slices smaller than this share of the total are ignored.
    ///   - minimumDivergence: slices closer than this to the overall distribution are not reported.
    public static func find(category: FieldRef, dimensions: [FieldRef], filters: [FilterSpec] = [], query: AnalyticsQuery,
                            minimumWeight: Double = 0.01, minimumDivergence: Double = 0.01, maxResults: Int = 10) -> [DistributionSlice] {
        let overallTable = query([category], filters)
        guard overallTable.columnCount >= 2 else { return [] }
        var order: [Value] = []
        var overall: [Value: Double] = [:]
        for r in 0..<overallTable.rowCount {
            guard let v = overallTable.measureValue(row: r), v.isFinite else { continue }
            let k = overallTable[r, 0]
            if overall[k] == nil { order.append(k) }
            overall[k, default: 0] += max(0, v)
        }
        let total = overall.values.reduce(0, +)
        guard total > 0, order.count >= 2 else { return [] }
        let p = order.map { (overall[$0] ?? 0) / total }
        var out: [DistributionSlice] = []
        for dim in dimensions where dim.key != category.key {
            let t = query([dim, category], filters)
            guard t.columnCount >= 3 else { continue }
            var slices: [Value: [Value: Double]] = [:]
            var sliceOrder: [Value] = []
            for r in 0..<t.rowCount {
                guard let v = t.measureValue(row: r), v.isFinite else { continue }
                let s = t[r, 0]
                if slices[s] == nil { sliceOrder.append(s) }
                slices[s, default: [:]][t[r, 1], default: 0] += max(0, v)
            }
            guard sliceOrder.count >= 2 else { continue }
            for s in sliceOrder {
                let vals = order.map { slices[s]?[$0] ?? 0 }
                let sum = vals.reduce(0, +)
                guard sum > 0, sum / total >= minimumWeight else { continue }
                let q = vals.map { $0 / sum }
                let js = jensenShannon(p, q)
                guard js >= minimumDivergence else { continue }
                let chi = HypothesisTests.chiSquareGoodnessOfFit(observed: vals, expected: p)
                let shares = order.indices.map { DistributionSlice.Share(category: order[$0], slice: q[$0], overall: p[$0], value: vals[$0]) }
                // Describe the category with the largest share gap.
                let gapIdx = order.indices.max { abs(q[$0] - p[$0]) < abs(q[$1] - p[$1]) } ?? 0
                let sentence = "For \(dim.caption) \(Fmt.label(s)), \(Fmt.label(order[gapIdx])) makes up \(Fmt.percent(q[gapIdx])) "
                    + "of the total, compared with \(Fmt.percent(p[gapIdx])) overall."
                out.append(DistributionSlice(dimension: dim, value: s, divergence: js, chiSquare: chi?.statistic ?? 0,
                                             pValue: chi?.pValue ?? 1, weight: sum / total, shares: shares, sentence: sentence))
            }
        }
        out.sort { $0.divergence != $1.divergence ? $0.divergence > $1.divergence : $0.weight > $1.weight }
        return Array(out.prefix(maxResults))
    }

    /// Jensen–Shannon divergence in bits between two discrete distributions (each summing to 1).
    public static func jensenShannon(_ p: [Double], _ q: [Double]) -> Double {
        let n = min(p.count, q.count)
        var d = 0.0
        for i in 0..<n {
            let m = (p[i] + q[i]) / 2
            if p[i] > 0 { d += 0.5 * p[i] * log2(p[i] / m) }
            if q[i] > 0 { d += 0.5 * q[i] * log2(q[i] / m) }
        }
        return max(0, min(1, d))
    }
}
