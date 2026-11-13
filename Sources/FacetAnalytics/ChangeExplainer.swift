import Foundation
import FacetCore

/// One way of explaining a change: the breakdown of the delta by one dimension.
public struct ChangeExplanation: Sendable {
    public struct Contribution: Sendable {
        public var member: Value
        public var before: Double
        public var after: Double
        /// after − before.
        public var change: Double
        /// change / total delta (can be negative or exceed 1 when members offset each other).
        public var shareOfDelta: Double
    }
    /// Waterfall-ready steps: start, the top contributions, "Other", end.
    public struct Waterfall: Sendable {
        public var start: Double
        public var contributions: [Contribution]
        /// Net change of all members not listed individually.
        public var other: Double
        public var end: Double
    }
    public var dimension: FieldRef
    /// 0…1: how concentrated the change is in few members of this dimension.
    public var score: Double
    /// Every member's contribution, largest absolute change first.
    public var contributions: [Contribution]
    public var waterfall: Waterfall
    public var sentence: String
}

public struct ChangeExplanationResult: Sendable {
    public var before: Double
    public var after: Double
    public var delta: Double
    public var isIncrease: Bool { delta >= 0 }
    /// Explanations ranked by score, best first.
    public var explanations: [ChangeExplanation]
}

/// "Explain the increase / decrease" between two data points.
public enum ChangeExplainer {
    /// - Parameters:
    ///   - before: filters selecting the earlier point (e.g. Month = Jan) plus any context filters.
    ///   - after: filters selecting the later point.
    ///   - dimensions: candidate fields to break the change down by.
    ///   - query: see `AnalyticsQuery`.
    ///   - maxContributors: members listed individually in each waterfall; the rest are netted into "Other".
    public static func explain(before: [FilterSpec], after: [FilterSpec], dimensions: [FieldRef], query: AnalyticsQuery,
                               maxContributors: Int = 5, measureFormat: String = "") -> ChangeExplanationResult {
        var start = query([], before).scalarMeasure
        var end = query([], after).scalarMeasure
        var explanations: [ChangeExplanation] = []
        var fallbackTotals: (Double, Double)?
        for dim in dimensions {
            let b = members(query([dim], before)), a = members(query([dim], after))
            let keys = Set(b.keys).union(a.keys).sorted()
            guard !keys.isEmpty else { continue }
            let sumB = b.values.reduce(0, +), sumA = a.values.reduce(0, +)
            if fallbackTotals == nil { fallbackTotals = (sumB, sumA) }
            let s = start ?? sumB, e = end ?? sumA
            let delta = e - s
            var contribs = keys.map { k -> ChangeExplanation.Contribution in
                let vb = b[k] ?? 0, va = a[k] ?? 0
                return .init(member: k, before: vb, after: va, change: va - vb, shareOfDelta: delta != 0 ? (va - vb) / delta : 0)
            }
            contribs.sort { abs($0.change) != abs($1.change) ? abs($0.change) > abs($1.change) : $0.member < $1.member }
            let movement = contribs.reduce(0.0) { $0 + abs($1.change) }
            guard movement > 0 else { continue }
            // Concentration: normalised Herfindahl index of absolute changes, tempered by how much
            // of the movement survives netting (members that merely offset each other explain little).
            let n = Double(contribs.count)
            let h = contribs.reduce(0.0) { $0 + pow(abs($1.change) / movement, 2) }
            let concentration = n > 1 ? (h - 1 / n) / (1 - 1 / n) : 0
            let efficiency = min(1, abs(contribs.reduce(0.0) { $0 + $1.change }) / movement)
            let score = max(0, min(1, concentration * (0.5 + 0.5 * efficiency)))
            let top = Array(contribs.prefix(max(1, maxContributors)))
            let other = delta - top.reduce(0.0) { $0 + $1.change }
            let lead = top[0]
            let verb = delta >= 0 ? "increase" : "decrease"
            var sentence: String
            if delta != 0, lead.shareOfDelta > 0 {
                sentence = "\(dim.caption) \(Fmt.label(lead.member)) accounted for \(Fmt.percent(lead.shareOfDelta, decimals: 0)) of the \(verb) "
                    + "(\(Fmt.signed(lead.change, measureFormat)))."
            } else {
                sentence = "\(dim.caption) \(Fmt.label(lead.member)) changed the most (\(Fmt.signed(lead.change, measureFormat))), against the overall \(verb)."
            }
            if top.count > 1, let offset = top.dropFirst().first(where: { ($0.change > 0) != (delta > 0) && $0.change != 0 }) {
                sentence += " \(Fmt.label(offset.member)) partly offset it (\(Fmt.signed(offset.change, measureFormat)))."
            }
            explanations.append(ChangeExplanation(
                dimension: dim, score: score, contributions: contribs,
                waterfall: .init(start: s, contributions: top, other: abs(other) < 1e-9 * max(1, abs(delta)) ? 0 : other, end: e),
                sentence: sentence))
        }
        if start == nil { start = fallbackTotals?.0 }
        if end == nil { end = fallbackTotals?.1 }
        explanations.sort { $0.score > $1.score }
        let s = start ?? 0, e = end ?? 0
        return ChangeExplanationResult(before: s, after: e, delta: e - s, explanations: explanations)
    }

    static func members(_ t: DataTable) -> [Value: Double] {
        var out: [Value: Double] = [:]
        guard t.columnCount >= 2 else { return out }
        for r in 0..<t.rowCount {
            if let v = t.measureValue(row: r), v.isFinite { out[t[r, 0], default: 0] += v }
        }
        return out
    }
}
