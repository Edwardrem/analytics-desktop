import Foundation
import FacetCore

/// One ranked influencer of the analysed metric.
public struct Influencer: Sendable {
    public enum Kind: Sendable, Equatable {
        /// The factor equals a specific value.
        case category(Value)
        /// The (numeric) factor falls in a bin: lower inclusive, upper exclusive (the last bin is inclusive).
        case bin(lower: Double, upper: Double)
        /// The (numeric) factor goes up (or, when `increase` is false, down) by `amount` (one standard deviation).
        case perUnit(amount: Double, increase: Bool)
    }
    /// Explanatory column name.
    public var factor: String
    public var kind: Kind
    /// Categorical target: how many times more likely the target value is ("2.3x").
    /// Continuous target: nil.
    public var multiplier: Double?
    /// Continuous target: average change of the metric (signed). Categorical target: nil.
    public var difference: Double?
    public var pValue: Double
    /// Rows where the condition holds (all rows for per-unit influencers).
    public var support: Int
    /// Target rate (categorical) or mean (continuous) when the condition holds, and otherwise.
    public var valueWhenTrue: Double
    public var valueOtherwise: Double
    public var sentence: String
    /// Data for the detail chart: rate or mean of the target per value / bin of this factor.
    public var distribution: [DistributionPoint]

    public struct DistributionPoint: Sendable {
        public var label: String
        public var value: Double
        public var count: Int
        public var isHighlighted: Bool
    }
    /// Ranking strength: the multiplier, or the absolute difference.
    public var strength: Double { multiplier ?? abs(difference ?? 0) }
}

public struct KeyInfluencersResult: Sendable {
    public enum TargetKind: String, Sendable { case categorical, continuous }
    public var targetKind: TargetKind
    /// Overall target rate (categorical) or mean (continuous).
    public var baseline: Double
    /// Rows analysed (rows with a blank target are dropped).
    public var rowCount: Int
    public var influencers: [Influencer]
    public var segments: [Segment]
}

public enum KeyInfluencersError: LocalizedError {
    case missingColumn(String)
    case notEnoughData
    case targetValueRequired
    case constantTarget
    public var errorDescription: String? {
        switch self {
        case .missingColumn(let c): return "The column “\(c)” was not found in the data."
        case .notEnoughData: return "There isn't enough data to analyse. At least 20 rows with a non-blank target are needed."
        case .targetValueRequired: return "Choose which value of the metric to analyse."
        case .constantTarget: return "The metric has the same value on every row, so nothing can influence it."
        }
    }
}

/// Key influencers analysis (what drives a metric) and top segments.
public enum KeyInfluencers {
    public enum Direction: String, Sendable { case increase, decrease }

    public struct Options: Sendable {
        /// Significance level.
        public var alpha = 0.05
        /// Minimum rows in a category / bin for it to be reported.
        public var minSupport = 10
        /// Bonferroni-correct p-values across all candidates tested.
        public var correctMultipleTests = true
        /// Numeric columns with at most this many distinct values are treated as categories.
        public var maxCategoricalDistinct = 8
        /// Categorical target: minimum likelihood multiplier worth reporting.
        public var minMultiplier = 1.1
        public var maxInfluencers = 20
        public var bins = 5
        /// Top segments: tree depth, minimum rows per segment (nil = max(10, 2% of rows)), and how many to return.
        public var maxDepth = 4
        public var minSegmentSize: Int? = nil
        public var maxSegments = 6
        public init() {}
    }

    /// Analyses what influences `target`.
    /// - Parameters:
    ///   - table: one row per observation.
    ///   - target: name of the metric column.
    ///   - targetValue: for a categorical metric, the value of interest ("what influences Rating to be Low").
    ///     Pass nil for a continuous (numeric) metric.
    ///   - direction: for a continuous metric, whether to find what increases or decreases it.
    ///   - explainBy: names of the candidate explanatory columns.
    public static func analyze(table: DataTable, target: String, targetValue: Value? = nil, direction: Direction = .increase,
                               explainBy: [String], options: Options = Options()) throws -> KeyInfluencersResult {
        guard let tIdx = table.columnIndex(target) else { throw KeyInfluencersError.missingColumn(target) }
        var factorIdx: [Int] = []
        for name in explainBy {
            guard let i = table.columnIndex(name) else { throw KeyInfluencersError.missingColumn(name) }
            if i != tIdx { factorIdx.append(i) }
        }
        let targetCol = table.columns[tIdx]
        let categorical = targetValue != nil
        if !categorical, !targetCol.values.contains(where: { $0.isNumber }) { throw KeyInfluencersError.targetValueRequired }
        // Response vector.
        var rows: [Int] = [], y: [Double] = []
        for r in 0..<table.rowCount {
            let v = targetCol.values[r]
            if v.isNull { continue }
            if let tv = targetValue { rows.append(r); y.append(v == tv || v.asString == tv.asString ? 1 : 0) }
            else if let d = v.asDouble, d.isFinite { rows.append(r); y.append(d) }
        }
        guard rows.count >= 20 else { throw KeyInfluencersError.notEnoughData }
        let baseline = Stats.mean(y)
        guard let ymin = y.min(), let ymax = y.max(), ymin < ymax else { throw KeyInfluencersError.constantTarget }
        let wantUp = categorical || direction == .increase

        let factors = factorIdx.map { Factor(column: table.columns[$0], rows: rows, options: options) }
        var candidates: [Influencer] = []
        var tests = 0
        let targetLabel = categorical ? "\(target) is \(Fmt.label(targetValue ?? .null))" : target
        if categorical {
            for f in factors {
                switch f.data {
                case .categorical(let values):
                    let (found, tested) = categoricalInfluencers(f, values: values, y: y, categorical: categorical, wantUp: wantUp,
                                                                  targetLabel: targetLabel, options: options)
                    candidates += found; tests += tested
                case .numeric(let xs):
                    let (found, tested) = numericInfluencers(f, xs: xs, y: y, categorical: categorical, wantUp: wantUp,
                                                             targetLabel: targetLabel, options: options)
                    candidates += found; tests += tested
                }
            }
        } else {
            // Power BI semantics: for a numeric metric each factor's effect holds the other factors
            // constant, so correlated drivers are not conflated. A multivariate regression supplies
            // the adjusted effects; the per-factor tests are the fallback when the model is unusable.
            let (found, tested) = adjustedInfluencers(factors, y: y, wantUp: wantUp, targetLabel: targetLabel, options: options)
            if found.isEmpty {
                for f in factors {
                    switch f.data {
                    case .categorical(let values):
                        let (f2, t2) = categoricalInfluencers(f, values: values, y: y, categorical: categorical, wantUp: wantUp,
                                                               targetLabel: targetLabel, options: options)
                        candidates += f2; tests += t2
                    case .numeric(let xs):
                        let (f2, t2) = numericInfluencers(f, xs: xs, y: y, categorical: categorical, wantUp: wantUp,
                                                           targetLabel: targetLabel, options: options)
                        candidates += f2; tests += t2
                    }
                }
            } else {
                candidates = found; tests = tested
            }
        }
        let correction = options.correctMultipleTests ? Double(max(1, tests)) : 1
        var influencers = candidates.compactMap { c -> Influencer? in
            var c = c
            c.pValue = min(1, c.pValue * correction)
            guard c.pValue < options.alpha else { return nil }
            if categorical, (c.multiplier ?? 0) < options.minMultiplier { return nil }
            return c
        }
        influencers.sort { $0.strength != $1.strength ? $0.strength > $1.strength : $0.pValue < $1.pValue }
        influencers = Array(influencers.prefix(options.maxInfluencers))

        let segments = SegmentFinder.find(factors: factors, y: y, wantHigh: wantUp, options: options,
                                          isRate: categorical)
        return KeyInfluencersResult(targetKind: categorical ? .categorical : .continuous, baseline: baseline,
                                    rowCount: rows.count, influencers: influencers, segments: segments)
    }

    // MARK: Factors

    /// A prepared explanatory column, aligned to the analysed rows.
    struct Factor {
        enum Data { case categorical([Value]), numeric([Double?]) }
        var name: String
        var data: Data

        init(column: DataColumn, rows: [Int], options: Options) {
            name = column.name
            let vals = rows.map { column.values[$0] }
            let numericCount = vals.filter { $0.isNumber }.count
            let nonNull = vals.filter { !$0.isNull }.count
            let isNumeric = nonNull > 0 && numericCount == nonNull
            if isNumeric, Set(vals.filter { !$0.isNull }).count > options.maxCategoricalDistinct {
                data = .numeric(vals.map { $0.asDouble })
            } else if case .date = vals.first(where: { !$0.isNull }) ?? .null, Set(vals).count > options.maxCategoricalDistinct {
                data = .numeric(vals.map { $0.asDouble })
            } else {
                data = .categorical(vals)
            }
        }
    }

    // MARK: Categorical factors

    static func categoricalInfluencers(_ f: Factor, values: [Value], y: [Double], categorical: Bool, wantUp: Bool,
                                       targetLabel: String, options: Options) -> ([Influencer], Int) {
        var groups: [Value: [Int]] = [:]
        for (i, v) in values.enumerated() where !v.isNull { groups[v, default: []].append(i) }
        let total = groups.values.reduce(0) { $0 + $1.count }
        guard groups.count >= 2 else { return ([], 0) }
        let keys = groups.keys.sorted()
        let allIdx = keys.flatMap { groups[$0] ?? [] }
        let sumAll = allIdx.reduce(0.0) { $0 + y[$1] }
        var stats: [(key: Value, n: Int, mean: Double)] = []
        for k in keys { let idx = groups[k] ?? []; stats.append((k, idx.count, idx.reduce(0.0) { $0 + y[$1] } / Double(max(1, idx.count)))) }
        var out: [Influencer] = []
        var tested = 0
        for s in stats where s.n >= options.minSupport && total - s.n >= options.minSupport {
            tested += 1
            let sumIn = s.mean * Double(s.n)
            let restN = total - s.n
            let restMean = (sumAll - sumIn) / Double(restN)
            let dist = stats.map { Influencer.DistributionPoint(label: Fmt.label($0.key), value: $0.mean, count: $0.n, isHighlighted: $0.key == s.key) }
            if categorical {
                guard s.mean > restMean else { continue }
                let a = sumIn, b = Double(s.n) - sumIn, c = sumAll - sumIn, d = Double(restN) - c
                guard let chi = HypothesisTests.chiSquareIndependence([[a, b], [c, d]]) else { continue }
                let ratio = restMean > 0 ? s.mean / restMean : Double(s.n) * s.mean + 1 // rest never has the target value
                out.append(Influencer(
                    factor: f.name, kind: .category(s.key), multiplier: ratio, difference: nil, pValue: chi.pValue, support: s.n,
                    valueWhenTrue: s.mean, valueOtherwise: restMean,
                    sentence: "When \(f.name) is \(Fmt.label(s.key)), the likelihood that \(targetLabel) is \(mult(ratio)) higher than otherwise.",
                    distribution: dist))
            } else {
                let inside = (groups[s.key] ?? []).map { y[$0] }
                let insideSet = Set(groups[s.key] ?? [])
                let outside = allIdx.filter { !insideSet.contains($0) }.map { y[$0] }
                guard let t = HypothesisTests.tTest(inside, outside) else { continue }
                let diff = t.meanDifference
                guard wantUp ? diff > 0 : diff < 0 else { continue }
                out.append(Influencer(
                    factor: f.name, kind: .category(s.key), multiplier: nil, difference: diff, pValue: t.pValue, support: s.n,
                    valueWhenTrue: s.mean, valueOtherwise: restMean,
                    sentence: "When \(f.name) is \(Fmt.label(s.key)), the average of \(targetLabel) \(diff > 0 ? "increases" : "decreases") by \(Fmt.number(abs(diff))).",
                    distribution: dist))
            }
        }
        return (out, tested)
    }

    // MARK: Numeric factors

    /// Adjusted effects of every factor on a numeric metric, from one multivariate regression:
    /// numeric factors enter standardized (a coefficient is the effect of one standard deviation),
    /// categorical factors as 0/1 dummies against their alphabetically-first level (a coefficient is
    /// the effect of that level versus the reference). The per-level detail chart keeps the raw means.
    static func adjustedInfluencers(_ factors: [Factor], y: [Double], wantUp: Bool, targetLabel: String,
                                    options: Options) -> ([Influencer], Int) {
        // Design matrix: standardized numeric factors, then one dummy per non-reference level.
        var columns: [[Double]] = []           // one column of feature values per matrix column
        var plan: [(factor: Int, level: Value?)] = []   // matrix column → factor index and level (nil = numeric)
        var columnOf: [String: Int] = [:]      // factor name → first matrix column
        for (fi, f) in factors.enumerated() {
            switch f.data {
            case .numeric(let xs):
                let vals = xs.compactMap { $0 }
                guard vals.count == y.count else { continue }
                let mx = Stats.mean(vals), sd = Stats.stdDev(vals)
                guard sd > 1e-12 else { continue }
                columns.append(xs.map { (($0 ?? mx) - mx) / sd })
                plan.append((fi, nil))
                columnOf[f.name] = columns.count - 1
            case .categorical(let values):
                let levels = Array(Set(values.filter { !$0.isNull })).sorted { Fmt.label($0) < Fmt.label($1) }
                guard levels.count >= 2 else { continue }
                let reference = levels[0]
                for level in levels.dropFirst() {
                    columns.append(values.map { $0 == level ? 1 : 0 })
                    plan.append((fi, level))
                }
                columnOf[f.name] = columns.count - (levels.count - 1)
            }
        }
        guard !columns.isEmpty else { return ([], 0) }
        let x = (0..<y.count).map { r in columns.map { $0[r] } }
        guard let fit = OLS.fit(x: x, y: y) else { return ([], 0) }

        var out: [Influencer] = []
        var tested = 0
        // Coefficients per factor: a dummy coefficient is the level's effect; the reference level's
        // effect is minus the sum of its factor's other dummy coefficients.
        var dummyCoefficient: [String: [(level: Value, coefficient: Double, pValue: Double, column: Int)]] = [:]
        var numericEffect: [String: (effect: Double, pValue: Double)] = [:]
        for (ci, entry) in plan.enumerated() where ci + 1 < fit.coefficients.count {
            let f = factors[entry.factor]
            if let level = entry.level {
                dummyCoefficient[f.name, default: []].append((level, fit.coefficients[ci + 1], fit.pValues[ci + 1], ci + 1))
            } else {
                numericEffect[f.name] = (fit.coefficients[ci + 1], fit.pValues[ci + 1])
            }
        }
        for f in factors {
            // The detail chart: the raw mean of the metric per value of this factor.
            switch f.data {
            case .categorical(let values):
                var groups: [Value: [Int]] = [:]
                for (i, v) in values.enumerated() where !v.isNull { groups[v, default: []].append(i) }
                guard groups.count >= 2, var dummies = dummyCoefficient[f.name] else { continue }
                let keys = groups.keys.sorted { Fmt.label($0) < Fmt.label($1) }
                guard let reference = keys.first else { continue }
                let stats: [(key: Value, n: Int, mean: Double)] = keys.map { k in
                    let idx = groups[k] ?? []
                    return (k, idx.count, idx.reduce(0.0) { $0 + y[$1] } / Double(max(1, idx.count)))
                }
                let total = stats.reduce(0) { $0 + $1.n }
                for s in stats where s.n >= options.minSupport && total - s.n >= options.minSupport {
                    tested += 1
                    let effect: Double, pValue: Double
                    if s.key == reference {
                        let sum = dummies.reduce(0.0) { $0 + $1.coefficient }
                        effect = -sum
                        // The reference level's significance: the weakest of the factor's dummy tests.
                        pValue = dummies.map(\.pValue).max() ?? 1
                    } else if let hit = dummies.first(where: { $0.level == s.key }) {
                        effect = hit.coefficient
                        pValue = hit.pValue
                    } else { continue }
                    guard wantUp ? effect > 0 : effect < 0 else { continue }
                    let restN = total - s.n
                    let restMean = (stats.reduce(0.0) { $0 + $1.mean * Double($1.n) } - s.mean * Double(s.n)) / Double(max(1, restN))
                    let dist = stats.map { Influencer.DistributionPoint(label: Fmt.label($0.key), value: $0.mean, count: $0.n, isHighlighted: $0.key == s.key) }
                    out.append(Influencer(
                        factor: f.name, kind: .category(s.key), multiplier: nil, difference: effect, pValue: pValue, support: s.n,
                        valueWhenTrue: s.mean, valueOtherwise: restMean,
                        sentence: "When \(f.name) is \(Fmt.label(s.key)), the average of \(targetLabel) \(effect > 0 ? "increases" : "decreases") by \(Fmt.number(abs(effect))).",
                        distribution: dist))
                }
            case .numeric(let xs):
                guard let (coefficient, pValue) = numericEffect[f.name] else { continue }
                tested += 1
                // A significant numeric factor always moves the metric somehow: phrase it in the
                // direction of x that moves the metric the requested way.
                let up = (coefficient > 0) == wantUp
                let diff = abs(coefficient) * (wantUp ? 1 : -1)
                let vals = xs.compactMap { $0 }
                guard vals.count == y.count else { continue }
                let sd = Stats.stdDev(vals)
                guard sd > 1e-12 else { continue }
                let mean = Stats.mean(y)
                let chart = dist(for: xs, y: y, options: options)
                out.append(Influencer(
                    factor: f.name, kind: .perUnit(amount: sd, increase: up), multiplier: nil, difference: diff,
                    pValue: pValue, support: y.count, valueWhenTrue: mean + diff, valueOtherwise: mean,
                    sentence: "When \(f.name) goes \(up ? "up" : "down") by \(Fmt.number(sd)), the average of \(targetLabel) \(wantUp ? "increases" : "decreases") by \(Fmt.number(abs(diff))).",
                    distribution: chart))
            }
        }
        return (out, tested)
    }

    /// Quantile-bin means of `y` along a numeric factor, for the detail chart.
    static func dist(for xs: [Double?], y: [Double], options: Options) -> [Influencer.DistributionPoint] {
        let idx = xs.indices.filter { xs[$0] != nil && xs[$0]!.isFinite }
        guard idx.count >= 2 else { return [] }
        let x = idx.map { xs[$0]! }
        let sorted = x.sorted()
        var edges: [Double] = [sorted[0]]
        for b in 1..<max(2, options.bins) {
            let q = Stats.quantileSorted(sorted, Double(b) / Double(max(2, options.bins)))
            if q > edges[edges.count - 1] { edges.append(q) }
        }
        if sorted[sorted.count - 1] > edges[edges.count - 1] { edges.append(sorted[sorted.count - 1]) }
        let binCount = max(1, edges.count - 1)
        var binN = [Int](repeating: 0, count: binCount), binSum = [Double](repeating: 0, count: binCount)
        for (v, t) in zip(x, idx.map({ y[$0] })) {
            var b = 0
            for e in 1..<max(1, edges.count - 1) where v >= edges[e] { b = e }
            b = min(b, binCount - 1)
            binN[b] += 1; binSum[b] += t
        }
        return (0..<binCount).map {
            Influencer.DistributionPoint(label: "\(Fmt.number(edges[$0])) – \(Fmt.number(edges[min($0 + 1, edges.count - 1)]))",
                                         value: binN[$0] > 0 ? binSum[$0] / Double(binN[$0]) : 0, count: binN[$0], isHighlighted: false)
        }
    }

    // MARK: Numeric factors

    static func numericInfluencers(_ f: Factor, xs: [Double?], y: [Double], categorical: Bool, wantUp: Bool,
                                   targetLabel: String, options: Options) -> ([Influencer], Int) {
        let idx = xs.indices.filter { xs[$0] != nil && xs[$0]!.isFinite }
        guard idx.count >= max(20, 2 * options.minSupport) else { return ([], 0) }
        let x = idx.map { xs[$0]! }, yy = idx.map { y[$0] }
        let mx = Stats.mean(x), sd = Stats.stdDev(x)
        guard sd > 0 else { return ([], 0) }
        // Quantile bins for the detail chart and the non-linear fallback.
        let sorted = x.sorted()
        var edges: [Double] = [sorted[0]]
        for b in 1..<max(2, options.bins) {
            let q = Stats.quantileSorted(sorted, Double(b) / Double(max(2, options.bins)))
            if q > edges[edges.count - 1] { edges.append(q) }
        }
        if sorted[sorted.count - 1] > edges[edges.count - 1] { edges.append(sorted[sorted.count - 1]) }
        let binCount = max(1, edges.count - 1)
        func bin(_ v: Double) -> Int {
            var b = 0
            for e in 1..<max(1, edges.count - 1) where v >= edges[e] { b = e }
            return min(b, binCount - 1)
        }
        var binN = [Int](repeating: 0, count: binCount), binSum = [Double](repeating: 0, count: binCount)
        var binRows = [[Double]](repeating: [], count: binCount)
        for (v, t) in zip(x, yy) { let b = bin(v); binN[b] += 1; binSum[b] += t; binRows[b].append(t) }
        func label(_ b: Int) -> String { "\(Fmt.number(edges[b])) – \(Fmt.number(edges[min(b + 1, edges.count - 1)]))" }
        func dist(highlight: Int?) -> [Influencer.DistributionPoint] {
            (0..<binCount).map { Influencer.DistributionPoint(label: label($0), value: binN[$0] > 0 ? binSum[$0] / Double(binN[$0]) : 0,
                                                              count: binN[$0], isHighlighted: $0 == highlight) }
        }
        let total = yy.reduce(0, +)
        var tested = 1
        // Linear effect per standard deviation.
        if categorical {
            let z = x.map { [($0 - mx) / sd] }
            if let fit = LogisticRegression.fit(x: z, y: yy.map { $0 > 0.5 }), fit.pValues[1] < options.alpha {
                let up = fit.coefficients[1] > 0
                let p0 = fit.probability([0]), p1 = fit.probability([up ? 1 : -1])
                let ratio = p0 > 0 ? p1 / p0 : 1
                if ratio > 1 {
                    let inf = Influencer(
                        factor: f.name, kind: .perUnit(amount: sd, increase: up), multiplier: ratio, difference: nil,
                        pValue: fit.pValues[1], support: x.count, valueWhenTrue: p1, valueOtherwise: p0,
                        sentence: "When \(f.name) goes \(up ? "up" : "down") by \(Fmt.number(sd)), the likelihood that \(targetLabel) increases by \(mult(ratio)).",
                        distribution: dist(highlight: nil))
                    return ([inf], tested)
                }
            }
        } else if let fit = OLS.fit(x: x, y: yy), fit.pValues[1] < options.alpha {
            let slope = fit.coefficients[1]
            // Report the direction of x that moves the metric the requested way.
            let up = (slope > 0) == wantUp
            let diff = abs(slope) * sd * (wantUp ? 1 : -1)
            let inf = Influencer(
                factor: f.name, kind: .perUnit(amount: sd, increase: up), multiplier: nil, difference: diff,
                pValue: fit.pValues[1], support: x.count, valueWhenTrue: Stats.mean(yy) + diff, valueOtherwise: Stats.mean(yy),
                sentence: "When \(f.name) goes \(up ? "up" : "down") by \(Fmt.number(sd)), the average of \(targetLabel) \(wantUp ? "increases" : "decreases") by \(Fmt.number(abs(diff))).",
                distribution: dist(highlight: nil))
            return ([inf], tested)
        }
        // Non-linear fallback: test each bin against the rest.
        var out: [Influencer] = []
        guard binCount >= 2 else { return ([], tested) }
        for b in 0..<binCount where binN[b] >= options.minSupport && x.count - binN[b] >= options.minSupport {
            tested += 1
            let meanIn = binSum[b] / Double(binN[b])
            let restN = x.count - binN[b]
            let meanOut = (total - binSum[b]) / Double(restN)
            let kind = Influencer.Kind.bin(lower: edges[b], upper: edges[min(b + 1, edges.count - 1)])
            if categorical {
                guard meanIn > meanOut else { continue }
                let a = binSum[b], bb = Double(binN[b]) - a, c = total - a, d = Double(restN) - c
                guard let chi = HypothesisTests.chiSquareIndependence([[a, bb], [c, d]]) else { continue }
                let ratio = meanOut > 0 ? meanIn / meanOut : Double(binN[b]) * meanIn + 1
                out.append(Influencer(factor: f.name, kind: kind, multiplier: ratio, difference: nil, pValue: chi.pValue, support: binN[b],
                                      valueWhenTrue: meanIn, valueOtherwise: meanOut,
                                      sentence: "When \(f.name) is \(label(b)), the likelihood that \(targetLabel) is \(mult(ratio)) higher than otherwise.",
                                      distribution: dist(highlight: b)))
            } else {
                var rest: [Double] = []
                for o in 0..<binCount where o != b { rest += binRows[o] }
                guard let t = HypothesisTests.tTest(binRows[b], rest) else { continue }
                guard wantUp ? t.meanDifference > 0 : t.meanDifference < 0 else { continue }
                out.append(Influencer(factor: f.name, kind: kind, multiplier: nil, difference: t.meanDifference, pValue: t.pValue,
                                      support: binN[b], valueWhenTrue: meanIn, valueOtherwise: meanOut,
                                      sentence: "When \(f.name) is \(label(b)), the average of \(targetLabel) \(t.meanDifference > 0 ? "increases" : "decreases") by \(Fmt.number(abs(t.meanDifference))).",
                                      distribution: dist(highlight: b)))
            }
        }
        return (out, tested)
    }

    static func mult(_ r: Double) -> String { String(format: "%.2fx", r) }
}
