import Foundation
import FacetCore

/// Decomposition-tree engine: expands nodes by a chosen dimension or by an "AI split".
///
/// The tree does not hold data. It calls the `query` closure with the dimension to group by and the
/// filters that describe the path from the root to the node being expanded.
public struct DecompositionTree {
    /// One step on the path from the root: a dimension fixed to a value.
    public struct PathStep: Sendable, Hashable {
        public var dimension: FieldRef
        public var value: Value
        public init(dimension: FieldRef, value: Value) { self.dimension = dimension; self.value = value }
        /// Basic filter selecting this member.
        public var filter: FilterSpec {
            var f = FilterSpec(field: dimension, kind: .basic)
            f.values = [value]
            return f
        }
    }

    public struct Child: Sendable {
        public var value: Value
        public var amount: Double
        /// Share of the level's total (sum of all children), 0…1; nil when the total is zero.
        public var share: Double?
        /// Path step to pass back when expanding this child.
        public var step: PathStep
    }

    public struct Level: Sendable {
        public var dimension: FieldRef
        /// All members of the dimension under the expanded node, sorted (descending unless a low-value split).
        public var children: [Child]
        /// Set for AI splits.
        public var split: SplitKind?
        public var mode: SplitMode?
        /// Index into `children` of the member the AI split picked (always 0 for AI splits).
        public var highlightedIndex: Int?
        /// Why this dimension was chosen (AI splits only).
        public var explanation: String
    }

    public enum SplitKind: String, Sendable { case highValue, lowValue }
    /// `absolute` compares raw member values across dimensions. `relative` compares how far each
    /// dimension's extreme member stands out from that dimension's other members.
    public enum SplitMode: String, Sendable { case absolute, relative }

    public var dimensions: [FieldRef]
    /// Filters always applied (page/report filters).
    public var baseFilters: [FilterSpec]
    public var query: AnalyticsQuery

    /// - Parameters:
    ///   - dimensions: the "Explain by" fields.
    ///   - query: see `AnalyticsQuery`; the analysed measure is the last column of the result.
    public init(dimensions: [FieldRef], baseFilters: [FilterSpec] = [], query: @escaping AnalyticsQuery) {
        self.dimensions = dimensions; self.baseFilters = baseFilters; self.query = query
    }

    /// Value of the analysed measure at a node (the root for an empty path).
    public func value(at path: [PathStep] = []) -> Double? {
        query([], baseFilters + path.map(\.filter)).scalarMeasure
    }

    /// Children of the node at `path`, broken down by `dimension`.
    public func children(of path: [PathStep] = [], by dimension: FieldRef, descending: Bool = true) -> Level {
        let table = query([dimension], baseFilters + path.map(\.filter))
        var kids: [Child] = []
        if table.columnCount >= 2 {
            for r in 0..<table.rowCount {
                guard let amount = table.measureValue(row: r), amount.isFinite else { continue }
                let v = table[r, 0]
                kids.append(Child(value: v, amount: amount, share: nil, step: PathStep(dimension: dimension, value: v)))
            }
        }
        let total = kids.reduce(0.0) { $0 + $1.amount }
        for i in kids.indices { kids[i].share = total != 0 ? kids[i].amount / total : nil }
        kids.sort { a, b in
            if a.amount != b.amount { return descending ? a.amount > b.amount : a.amount < b.amount }
            return a.value < b.value
        }
        return Level(dimension: dimension, children: kids, split: nil, mode: nil, highlightedIndex: nil, explanation: "")
    }

    /// Dimensions not yet used on `path`.
    public func availableDimensions(for path: [PathStep]) -> [FieldRef] {
        let used = Set(path.map { $0.dimension.key })
        return dimensions.filter { !used.contains($0.key) }
    }

    /// AI split: picks the dimension whose member has the highest (or lowest) value under the node at `path`
    /// and returns that dimension's level with the picked member first.
    /// - Parameter candidates: dimensions to consider; defaults to those not already on the path.
    /// - Returns: nil when no candidate dimension yields at least one member.
    public func aiSplit(path: [PathStep] = [], kind: SplitKind, mode: SplitMode = .absolute, candidates: [FieldRef]? = nil) -> Level? {
        let dims = candidates ?? availableDimensions(for: path)
        var best: (level: Level, score: Double)?
        for dim in dims {
            var level = children(of: path, by: dim, descending: kind == .highValue)
            guard let top = level.children.first else { continue }
            let amounts = level.children.map(\.amount)
            let score: Double
            switch mode {
            case .absolute:
                score = kind == .highValue ? top.amount : -top.amount
            case .relative:
                // How far the extreme member stands out from the average of the other members.
                guard amounts.count >= 2 else { continue }
                let others = Array(amounts.dropFirst())
                let mean = Stats.mean(others)
                let denom = max(abs(mean), 1e-12)
                score = kind == .highValue ? (top.amount - mean) / denom : (mean - top.amount) / denom
            }
            if best == nil || score > best!.score {
                level.split = kind; level.mode = mode; level.highlightedIndex = 0
                let what = kind == .highValue ? "highest" : "lowest"
                switch mode {
                case .absolute:
                    level.explanation = "\(dim.caption) \(Fmt.label(top.value)) has the \(what) value (\(Fmt.number(top.amount))) of any candidate field at this level."
                case .relative:
                    level.explanation = "\(dim.caption) \(Fmt.label(top.value)) (\(Fmt.number(top.amount))) stands out the most from the other \(dim.caption) values."
                }
                best = (level, score)
            }
        }
        return best?.level
    }
}
