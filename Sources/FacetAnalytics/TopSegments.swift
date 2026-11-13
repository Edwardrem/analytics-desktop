import Foundation
import FacetCore

/// One condition of a segment.
public struct SegmentPredicate: Sendable, Equatable {
    public enum Op: String, Sendable { case equals, notEquals, lessOrEqual, greaterThan }
    public var column: String
    public var op: Op
    public var value: Value
    public var description: String {
        let v = value.asDouble.flatMap { value.isNumber ? Fmt.number($0) : nil } ?? Fmt.label(value)
        switch op {
        case .equals: return "\(column) is \(v)"
        case .notEquals: return "\(column) is not \(v)"
        case .lessOrEqual: return "\(column) is less than or equal to \(v)"
        case .greaterThan: return "\(column) is more than \(v)"
        }
    }
    /// Equivalent filter for cross-filtering a report to this condition.
    public func filter(table: String) -> FilterSpec {
        var f = FilterSpec(field: .column(table, column), kind: .advanced)
        let op: FilterOperator
        switch self.op {
        case .equals: op = .equals
        case .notEquals: op = .notEquals
        case .lessOrEqual: op = .lessOrEqual
        case .greaterThan: op = .greaterThan
        }
        f.conditions = [FilterCondition(op: op, value: value)]
        return f
    }
}

/// A sub-population where the metric is notably high (or low).
public struct Segment: Sendable {
    /// Conditions that all hold for rows in the segment.
    public var predicates: [SegmentPredicate]
    /// Rows in the segment and their share of all analysed rows (0…1).
    public var size: Int
    public var share: Double
    /// Target rate (categorical metric, 0…1) or mean (continuous metric) inside the segment.
    public var value: Double
    /// `value` relative to the overall rate / mean.
    public var lift: Double
    public var sentence: String
}

/// Finds top segments with a shallow CART regression tree (variance-reduction splits, which for a
/// 0/1 target is equivalent to Gini impurity).
public enum SegmentFinder {
    /// Public entry point for callers that want segments without the influencer analysis.
    /// `y` must be aligned with the table rows; rows where `y` is nil are skipped.
    public static func find(table: DataTable, y: [Double?], explainBy: [String], wantHigh: Bool = true, isRate: Bool = false,
                            options: KeyInfluencers.Options = KeyInfluencers.Options()) -> [Segment] {
        let rows = (0..<min(table.rowCount, y.count)).filter { y[$0] != nil }
        let factors = explainBy.compactMap { table.column($0) }.map { KeyInfluencers.Factor(column: $0, rows: rows, options: options) }
        return find(factors: factors, y: rows.map { y[$0]! }, wantHigh: wantHigh, options: options, isRate: isRate)
    }

    static func find(factors: [KeyInfluencers.Factor], y: [Double], wantHigh: Bool, options: KeyInfluencers.Options, isRate: Bool) -> [Segment] {
        let n = y.count
        guard n >= 20, !factors.isEmpty else { return [] }
        let minLeaf = options.minSegmentSize ?? max(10, n / 50)
        let overall = Stats.mean(y)
        var leaves: [(rows: [Int], preds: [SegmentPredicate])] = []
        grow(rows: Array(0..<n), preds: [], depth: 0, factors: factors, y: y, minLeaf: minLeaf, maxDepth: max(1, min(options.maxDepth, 4)), leaves: &leaves)
        var out: [Segment] = []
        for leaf in leaves where !leaf.preds.isEmpty {
            let mean = leaf.rows.reduce(0.0) { $0 + y[$1] } / Double(leaf.rows.count)
            guard wantHigh ? mean > overall : mean < overall else { continue }
            let preds = simplify(leaf.preds)
            let lift = overall != 0 ? mean / overall : 0
            let cond = preds.map(\.description).joined(separator: " and ")
            let valueText = isRate ? Fmt.percent(mean) : Fmt.number(mean)
            let baseText = isRate ? Fmt.percent(overall) : Fmt.number(overall)
            let sentence = "When \(cond): \(isRate ? "rate" : "average") is \(valueText) vs \(baseText) overall "
                + "(\(leaf.rows.count) rows, \(Fmt.percent(Double(leaf.rows.count) / Double(n))) of the data)."
            out.append(Segment(predicates: preds, size: leaf.rows.count, share: Double(leaf.rows.count) / Double(n), value: mean,
                               lift: lift, sentence: sentence))
        }
        out.sort { wantHigh ? $0.value > $1.value : $0.value < $1.value }
        return Array(out.prefix(options.maxSegments))
    }

    private struct Split { var gain: Double; var left: [Int]; var right: [Int]; var leftPred: SegmentPredicate; var rightPred: SegmentPredicate }

    private static func grow(rows: [Int], preds: [SegmentPredicate], depth: Int, factors: [KeyInfluencers.Factor], y: [Double],
                             minLeaf: Int, maxDepth: Int, leaves: inout [(rows: [Int], preds: [SegmentPredicate])]) {
        guard depth < maxDepth, rows.count >= 2 * minLeaf, let split = bestSplit(rows: rows, factors: factors, y: y, minLeaf: minLeaf) else {
            leaves.append((rows, preds)); return
        }
        grow(rows: split.left, preds: preds + [split.leftPred], depth: depth + 1, factors: factors, y: y, minLeaf: minLeaf, maxDepth: maxDepth, leaves: &leaves)
        grow(rows: split.right, preds: preds + [split.rightPred], depth: depth + 1, factors: factors, y: y, minLeaf: minLeaf, maxDepth: maxDepth, leaves: &leaves)
    }

    private static func bestSplit(rows: [Int], factors: [KeyInfluencers.Factor], y: [Double], minLeaf: Int) -> Split? {
        let n = Double(rows.count)
        let sum = rows.reduce(0.0) { $0 + y[$1] }
        let sumSq = rows.reduce(0.0) { $0 + y[$1] * y[$1] }
        let parentSSE = sumSq - sum * sum / n
        guard parentSSE > 1e-12 else { return nil }
        var best: Split?
        // SSE reduction of splitting off a group with (count, sum): equals between-group sum of squares.
        func gain(_ cnt: Int, _ s: Double) -> Double {
            let l = Double(cnt), r = n - l
            guard cnt >= minLeaf, rows.count - cnt >= minLeaf else { return -1 }
            return s * s / l + (sum - s) * (sum - s) / r - sum * sum / n
        }
        for f in factors {
            switch f.data {
            case .categorical(let values):
                var agg: [Value: (Int, Double)] = [:]
                for r in rows { let v = values[r]; let c = agg[v] ?? (0, 0); agg[v] = (c.0 + 1, c.1 + y[r]) }
                guard agg.count >= 2 else { continue }
                for key in agg.keys.sorted() where !key.isNull {
                    let (cnt, s) = agg[key]!
                    let g = gain(cnt, s)
                    if g > (best?.gain ?? 1e-9 * parentSSE) {
                        best = Split(gain: g, left: rows.filter { values[$0] == key }, right: rows.filter { values[$0] != key },
                                     leftPred: SegmentPredicate(column: f.name, op: .equals, value: key),
                                     rightPred: SegmentPredicate(column: f.name, op: .notEquals, value: key))
                    }
                }
            case .numeric(let xs):
                let present = rows.filter { xs[$0] != nil }
                guard present.count >= 2 * minLeaf else { continue }
                let order = present.sorted { xs[$0]! < xs[$1]! }
                // Candidate thresholds at up to 24 evenly spaced ranks; rows with a missing value go right.
                let stepCount = min(24, order.count - 1)
                var tried = Set<Double>()
                var prefixCnt = 0, prefixSum = 0.0, cursor = 0
                for sIdx in 1...max(1, stepCount) {
                    let pos = sIdx * order.count / (stepCount + 1)
                    guard pos >= 1, pos < order.count else { continue }
                    let threshold = xs[order[pos - 1]]!
                    guard xs[order[order.count - 1]]! > threshold, tried.insert(threshold).inserted else { continue }
                    while cursor < order.count, xs[order[cursor]]! <= threshold { prefixCnt += 1; prefixSum += y[order[cursor]]; cursor += 1 }
                    let g = gain(prefixCnt, prefixSum)
                    if g > (best?.gain ?? 1e-9 * parentSSE) {
                        let t = threshold
                        best = Split(gain: g, left: rows.filter { xs[$0] != nil && xs[$0]! <= t }, right: rows.filter { xs[$0] == nil || xs[$0]! > t },
                                     leftPred: SegmentPredicate(column: f.name, op: .lessOrEqual, value: .double(t)),
                                     rightPred: SegmentPredicate(column: f.name, op: .greaterThan, value: .double(t)))
                    }
                }
            }
        }
        // Require the split to explain a meaningful share of the node's variance.
        if let b = best, b.gain < 0.01 * parentSSE { return nil }
        return best
    }

    /// Removes redundant conditions: keeps the tightest numeric bounds per column and drops
    /// "is not" conditions on a column that also has an "is" condition.
    static func simplify(_ preds: [SegmentPredicate]) -> [SegmentPredicate] {
        var out: [SegmentPredicate] = []
        for p in preds {
            switch p.op {
            case .equals:
                out.removeAll { $0.column == p.column && $0.op == .notEquals }
                out.append(p)
            case .notEquals:
                if !out.contains(where: { $0.column == p.column && $0.op == .equals }) { out.append(p) }
            case .lessOrEqual, .greaterThan:
                if let i = out.firstIndex(where: { $0.column == p.column && $0.op == p.op }) {
                    let old = out[i].value.asDouble ?? 0, new = p.value.asDouble ?? 0
                    if p.op == .lessOrEqual ? new < old : new > old { out[i] = p }
                } else { out.append(p) }
            }
        }
        return out
    }
}
