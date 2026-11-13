import Foundation
import FacetCore

/// One automatically discovered finding, with a visual that shows it.
public struct QuickInsight: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case categoryOutlier, majority, lowVariance, trend, changePoint, seasonality, timeSeriesOutlier, correlation, steadyShare
        public var displayName: String {
            switch self {
            case .categoryOutlier: return "Category outlier"
            case .majority: return "Majority"
            case .lowVariance: return "Low variance"
            case .trend: return "Trend"
            case .changePoint: return "Change point in a time series"
            case .seasonality: return "Seasonality in a time series"
            case .timeSeriesOutlier: return "Time series outlier"
            case .correlation: return "Correlation"
            case .steadyShare: return "Steady share"
            }
        }
    }
    public var kind: Kind
    /// 0…1, higher is more notable.
    public var score: Double
    public var sentence: String
    /// A ready-to-render visual illustrating the insight.
    public var spec: VisualSpec
    /// The fields involved (dimension first).
    public var fields: [FieldRef]
}

/// Scans a dataset for notable patterns.
public enum QuickInsights {
    /// Returns a table with one column per `groupBy` field (in order) followed by one column per measure (in order).
    public typealias Query = (_ groupBy: [FieldRef], _ measures: [FieldRef]) -> DataTable

    public struct Options: Sendable {
        public var maxDimensions = 8
        public var maxMeasures = 6
        public var maxInsights = 20
        public var minimumScore = 0.3
        public init() {}
    }

    /// - Parameters:
    ///   - dimensions: categorical fields to slice by.
    ///   - measures: aggregated fields to examine.
    ///   - dateField: the time axis, when the data has one.
    public static func scan(dimensions: [FieldRef], measures: [FieldRef], dateField: FieldRef? = nil, query: Query,
                            options: Options = Options()) -> [QuickInsight] {
        let dims = Array(dimensions.filter { $0.key != dateField?.key }.prefix(options.maxDimensions))
        let ms = Array(measures.prefix(options.maxMeasures))
        guard !ms.isEmpty else { return [] }
        var out: [QuickInsight] = []
        for dim in dims { out += categoryInsights(dim: dim, measures: ms, table: query([dim], ms)) }
        if let date = dateField {
            out += timeInsights(date: date, measures: ms, table: query([date], ms))
            for dim in dims.prefix(3) { out += steadyShare(date: date, dim: dim, measure: ms[0], table: query([date, dim], [ms[0]])) }
        }
        out = out.filter { $0.score >= options.minimumScore && $0.score.isFinite }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.sentence < $1.sentence }
        return Array(out.prefix(options.maxInsights))
    }

    static func spec(_ type: VisualType, _ wells: [(Well, [FieldRef])], title: String, sort: SortSpec? = nil) -> VisualSpec {
        var s = VisualSpec(type: type, frame: Frame(x: 0, y: 0, width: 480, height: 300), name: title)
        for (w, f) in wells { s.setFields(w, f) }
        if let sort { s.sort = [sort] }
        return s
    }

    // MARK: Category insights

    static func categoryInsights(dim: FieldRef, measures: [FieldRef], table t: DataTable) -> [QuickInsight] {
        guard t.columnCount >= 1 + measures.count, t.rowCount >= 3 else { return [] }
        var out: [QuickInsight] = []
        var series: [[Double?]] = []
        for (j, m) in measures.enumerated() {
            let col = t.columns[1 + j].values.map { $0.asDouble.flatMap { $0.isFinite ? $0 : nil } }
            series.append(col)
            let idx = col.indices.filter { col[$0] != nil && !t[$0, 0].isNull }
            let v = idx.map { col[$0]! }
            let n = v.count
            guard n >= 3 else { continue }
            let title = "\(m.caption) by \(dim.caption)"
            let bar = spec(.clusteredBar, [(.category, [dim]), (.values, [m])], title: title, sort: SortSpec(field: m, descending: true))
            // Outliers.
            if n >= 5 {
                let med = Stats.median(v), scale = 1.4826 * Stats.mad(v)
                if scale > 0, let k = v.indices.max(by: { abs(v[$0] - med) < abs(v[$1] - med) }) {
                    let z = abs(v[k] - med) / scale
                    if z > 3.5 {
                        out.append(QuickInsight(kind: .categoryOutlier, score: min(1, 0.55 + (z - 3.5) / 20),
                            sentence: "\(Fmt.label(t[idx[k], 0])) has a noticeably \(v[k] > med ? "higher" : "lower") \(m.caption) (\(Fmt.number(v[k]))) than other \(dim.caption) values (median \(Fmt.number(med))).",
                            spec: bar, fields: [dim, m]))
                    }
                }
            }
            // Majority.
            let total = v.reduce(0, +)
            if v.allSatisfy({ $0 >= 0 }), total > 0, let k = v.indices.max(by: { v[$0] < v[$1] }), v[k] / total > 0.5 {
                out.append(QuickInsight(kind: .majority, score: min(1, v[k] / total),
                    sentence: "\(Fmt.label(t[idx[k], 0])) accounts for the majority (\(Fmt.percent(v[k] / total, decimals: 0))) of \(m.caption).",
                    spec: spec(.pie, [(.legend, [dim]), (.values, [m])], title: title), fields: [dim, m]))
            }
            // Low variance.
            let mean = Stats.mean(v)
            if n >= 4, mean != 0 {
                let cv = Stats.stdDev(v) / abs(mean)
                if cv < 0.05 {
                    out.append(QuickInsight(kind: .lowVariance, score: 0.4 + 0.4 * (1 - cv / 0.05),
                        sentence: "\(m.caption) is very similar across all \(dim.caption) values (around \(Fmt.number(mean)), varying by about \(Fmt.percent(cv))).",
                        spec: bar, fields: [dim, m]))
                }
            }
        }
        // Correlated measures.
        for a in 0..<measures.count {
            for b in (a + 1)..<max(a + 1, measures.count) {
                var xs: [Double] = [], ys: [Double] = []
                for r in 0..<t.rowCount { if let x = series[a][r], let y = series[b][r] { xs.append(x); ys.append(y) } }
                guard xs.count >= 8, let r = Stats.pearson(xs, ys), abs(r) >= 0.8 else { continue }
                out.append(QuickInsight(kind: .correlation, score: min(1, abs(r)) * 0.95,
                    sentence: "\(measures[a].caption) and \(measures[b].caption) are \(r > 0 ? "positively" : "negatively") correlated across \(dim.caption) values (r = \(String(format: "%.2f", r))).",
                    spec: spec(.scatter, [(.details, [dim]), (.x, [measures[a]]), (.y, [measures[b]])], title: "\(measures[a].caption) vs \(measures[b].caption)"),
                    fields: [dim, measures[a], measures[b]]))
            }
        }
        return out
    }

    // MARK: Time insights

    static func timeInsights(date: FieldRef, measures: [FieldRef], table t: DataTable) -> [QuickInsight] {
        guard t.columnCount >= 1 + measures.count, t.rowCount >= 6 else { return [] }
        let order = (0..<t.rowCount).filter { !t[$0, 0].isNull }.sorted { t[$0, 0] < t[$1, 0] }
        var out: [QuickInsight] = []
        for (j, m) in measures.enumerated() {
            let rows = order.filter { t[$0, 1 + j].asDouble?.isFinite == true }
            let v = rows.map { t[$0, 1 + j].asDouble ?? 0 }
            let n = v.count
            guard n >= 6 else { continue }
            func label(_ i: Int) -> String { Fmt.label(t[rows[i], 0]) }
            let title = "\(m.caption) by \(date.caption)"
            let line = spec(.line, [(.category, [date]), (.values, [m])], title: title)
            let xs = (0..<n).map(Double.init)
            let linear = OLS.fit(x: xs, y: v)
            let season = Forecaster.detectSeasonLength(v)
            // Change point: the split that best separates two level means.
            var stepFound = false
            if n >= 8, let lin = linear {
                var best: (k: Int, sse: Double)?
                var prefix = [0.0], prefixSq = [0.0]
                for x in v { prefix.append(prefix.last! + x); prefixSq.append(prefixSq.last! + x * x) }
                func sse(_ a: Int, _ b: Int) -> Double { // [a, b)
                    let c = Double(b - a), s = prefix[b] - prefix[a]
                    return max(0, prefixSq[b] - prefixSq[a] - s * s / c)
                }
                for k in 3...(n - 3) {
                    let e = sse(0, k) + sse(k, n)
                    if best == nil || e < best!.sse { best = (k, e) }
                }
                if let b = best {
                    let linSSE = lin.residuals.reduce(0.0) { $0 + $1 * $1 }
                    let before = Array(v[..<b.k]), after = Array(v[b.k...])
                    if let tt = HypothesisTests.tTest(before, after), tt.pValue < 0.001, b.sse < 0.6 * linSSE, season == nil {
                        stepFound = true
                        let shift = Stats.mean(after) - Stats.mean(before)
                        out.append(QuickInsight(kind: .changePoint, score: min(1, 0.6 + 0.4 * (1 - b.sse / max(linSSE, 1e-300))),
                            sentence: "\(m.caption) shifted \(shift > 0 ? "up" : "down") at \(label(b.k)): the average went from \(Fmt.number(Stats.mean(before))) to \(Fmt.number(Stats.mean(after))).",
                            spec: line, fields: [date, m]))
                    }
                }
            }
            // Trend.
            if let lin = linear, lin.rSquared >= 0.6, !stepFound {
                let slope = lin.coefficients[1]
                out.append(QuickInsight(kind: .trend, score: min(1, lin.rSquared) * 0.9,
                    sentence: "\(m.caption) has been trending \(slope > 0 ? "upward" : "downward") from \(label(0)) to \(label(n - 1)) (\(Fmt.number(v[0])) → \(Fmt.number(v[n - 1]))).",
                    spec: line, fields: [date, m]))
            }
            // Seasonality.
            if let s = season, let lin = linear {
                let strength = Stats.autocorrelation(lin.residuals, lag: s)
                out.append(QuickInsight(kind: .seasonality, score: min(1, max(0, strength)),
                    sentence: "\(m.caption) shows a repeating pattern roughly every \(s) periods.",
                    spec: line, fields: [date, m]))
            }
            // Outliers.
            let anomalies = AnomalyDetector.detect(values: v.map { Optional($0) }, sensitivity: 55).anomalies
            if let a = anomalies.max(by: { $0.score < $1.score }), anomalies.count <= max(2, n / 10), !stepFound {
                out.append(QuickInsight(kind: .timeSeriesOutlier, score: min(1, 0.5 + a.score / 40),
                    sentence: "\(m.caption) was unexpectedly \(a.direction == .high ? "high" : "low") at \(label(a.index)) (\(Fmt.number(a.value)) vs an expected \(Fmt.number(a.expected))).",
                    spec: line, fields: [date, m]))
            }
        }
        return out
    }

    // MARK: Steady share

    static func steadyShare(date: FieldRef, dim: FieldRef, measure: FieldRef, table t: DataTable) -> [QuickInsight] {
        guard t.columnCount >= 3 else { return [] }
        var byDate: [Value: [Value: Double]] = [:]
        for r in 0..<t.rowCount {
            guard let v = t[r, 2].asDouble, v.isFinite, v >= 0, !t[r, 0].isNull else { continue }
            byDate[t[r, 0], default: [:]][t[r, 1], default: 0] += v
        }
        let periods = byDate.keys.sorted()
        guard periods.count >= 6 else { return [] }
        let members = Set(byDate.values.flatMap(\.keys)).sorted()
        guard members.count >= 2, members.count <= 12 else { return [] }
        var out: [QuickInsight] = []
        for mbr in members {
            var shares: [Double] = []
            for p in periods {
                let total = byDate[p]?.values.reduce(0, +) ?? 0
                if total > 0 { shares.append((byDate[p]?[mbr] ?? 0) / total) }
            }
            guard shares.count >= 6 else { continue }
            let mean = Stats.mean(shares), sd = Stats.stdDev(shares)
            // Totals must actually move, otherwise a steady share is trivial.
            let totals = periods.map { byDate[$0]?.values.reduce(0, +) ?? 0 }
            let totalCV = Stats.mean(totals) > 0 ? Stats.stdDev(totals) / Stats.mean(totals) : 0
            if mean >= 0.1, mean <= 0.9, sd <= 0.02, totalCV >= 0.05 {
                out.append(QuickInsight(kind: .steadyShare, score: 0.45 + 0.4 * (1 - sd / 0.02),
                    sentence: "\(Fmt.label(mbr))'s share of \(measure.caption) stays steady at around \(Fmt.percent(mean, decimals: 0)) over time.",
                    spec: spec(.stackedColumn100, [(.category, [date]), (.legend, [dim]), (.values, [measure])], title: "\(measure.caption) by \(date.caption) and \(dim.caption)"),
                    fields: [date, dim, measure]))
            }
        }
        // One steady-share insight per dimension is enough.
        return Array(out.sorted { $0.score > $1.score }.prefix(1))
    }
}
