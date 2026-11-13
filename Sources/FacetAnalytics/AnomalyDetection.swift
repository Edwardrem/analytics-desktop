import Foundation
import FacetCore

/// One flagged point.
public struct AnomalyPoint: Sendable {
    public enum Direction: String, Sendable { case high, low }
    public var index: Int
    public var value: Double
    public var expected: Double
    public var lower: Double
    public var upper: Double
    /// Robust z-score of the residual (|residual| / robust scale).
    public var score: Double
    public var direction: Direction
}

/// Output of `AnomalyDetector.detect`. All arrays are parallel to the input series.
public struct AnomalyResult: Sendable {
    public var anomalies: [AnomalyPoint]
    public var expected: [Double]
    public var lower: [Double]
    public var upper: [Double]
    public var trend: [Double]
    public var seasonal: [Double]
    public var residual: [Double]
    public var seasonLength: Int?
    /// Robust residual scale (1.4826 × MAD) used for the thresholds.
    public var scale: Double
    /// Residual threshold in scale units implied by the sensitivity.
    public var threshold: Double
    /// Interpolated input.
    public var values: [Double]
}

/// A possible explanation of an anomaly: one member of one dimension that accounts for part of the deviation.
public struct AnomalyExplanation: Sendable {
    public var dimension: FieldRef
    public var member: Value
    public var actual: Double
    public var expected: Double
    /// Share of the anomaly's deviation this member accounts for, 0…100.
    public var strength: Double
    public var sentence: String
}

/// Robust anomaly detection for evenly spaced series.
public enum AnomalyDetector {
    /// Detects anomalies by a median-based seasonal-trend decomposition and MAD-scaled residual thresholds.
    /// - Parameters:
    ///   - values: the series; nil entries are interpolated and never flagged.
    ///   - sensitivity: 0…100. Higher values narrow the expected range and flag more points.
    ///   - seasonality: season length in points; nil auto-detects; 0 or 1 disables the seasonal component.
    public static func detect(values: [Double?], sensitivity: Double = 70, seasonality: Int? = nil) -> AnomalyResult {
        let y = Forecaster.interpolate(values)
        let n = y.count
        let s = max(0, min(100, sensitivity))
        // 0 → 9 scales, 70 → ~3.4, 100 → 1 scale.
        let k = 9 - 8 * s / 100
        guard n >= 4 else {
            return AnomalyResult(anomalies: [], expected: y, lower: y, upper: y, trend: y, seasonal: [Double](repeating: 0, count: n),
                                 residual: [Double](repeating: 0, count: n), seasonLength: nil, scale: 0, threshold: k, values: y)
        }
        // 1. Robust global slope (Theil–Sen) so edge windows of the running median are unbiased.
        let slope = theilSenSlope(y)
        let detrended = (0..<n).map { y[$0] - slope * Double($0) }
        var m: Int? = nil
        if let given = seasonality { if given >= 2, n >= 2 * given { m = given } }
        else { m = Forecaster.detectSeasonLength(y) }

        var seasonal = [Double](repeating: 0, count: n)
        var trendPart = [Double](repeating: 0, count: n)
        var window = m ?? max(5, min(21, n / 6))
        if let mm = m { window = max(window, mm) }
        if window % 2 == 0 { window += 1 }
        window = min(window, n % 2 == 0 ? n - 1 : n)
        for pass in 0..<2 {
            let base = (0..<n).map { detrended[$0] - seasonal[$0] }
            trendPart = smooth(runningMedian(base, window: max(3, window)), window: 3)
            if let mm = m {
                var phases = [[Double]](repeating: [], count: mm)
                for i in 0..<n { phases[i % mm].append(detrended[i] - trendPart[i]) }
                var med = phases.map { Stats.median($0) }
                let centre = Stats.mean(med)
                med = med.map { $0 - centre }
                for i in 0..<n { seasonal[i] = med[i % mm] }
            } else if pass == 0 { break }
        }
        let trend = (0..<n).map { trendPart[$0] + slope * Double($0) }
        let expected = (0..<n).map { trend[$0] + seasonal[$0] }
        let residual = (0..<n).map { y[$0] - expected[$0] }
        var scale = 1.4826 * Stats.mad(residual)
        if scale <= 0 { scale = 1.2533 * Stats.mean(residual.map { abs($0) }) }
        // Floor so numerically clean series are not flagged for rounding-level residuals.
        let spread = 1.4826 * Stats.mad(y)
        let floor = max(0.02 * spread, 1e-9 * (y.map { abs($0) }.max() ?? 0), 1e-12)
        scale = max(scale, floor)
        let half = k * scale
        var anomalies: [AnomalyPoint] = []
        for i in 0..<n {
            guard i < values.count, let raw = values[i], raw.isFinite else { continue }
            if abs(residual[i]) > half {
                anomalies.append(AnomalyPoint(index: i, value: y[i], expected: expected[i], lower: expected[i] - half,
                                              upper: expected[i] + half, score: abs(residual[i]) / scale,
                                              direction: residual[i] > 0 ? .high : .low))
            }
        }
        return AnomalyResult(anomalies: anomalies, expected: expected, lower: expected.map { $0 - half },
                             upper: expected.map { $0 + half }, trend: trend, seasonal: seasonal, residual: residual,
                             seasonLength: m, scale: scale, threshold: k, values: y)
    }

    /// Runs detection and writes `anomalies` and `expectedBands[seriesColumn]` into `overlays`.
    @discardableResult
    public static func apply(to overlays: inout AnalyticsOverlays, values: [Double?], seriesColumn: Int,
                             sensitivity: Double = 70, seasonality: Int? = nil) -> AnomalyResult {
        let r = detect(values: values, sensitivity: sensitivity, seasonality: seasonality)
        overlays.anomalies.removeAll { $0.seriesColumn == seriesColumn }
        for a in r.anomalies {
            let text = "\(Fmt.number(a.value)) is \(a.direction == .high ? "above" : "below") the expected range "
                + "\(Fmt.number(a.lower)) – \(Fmt.number(a.upper)) (expected \(Fmt.number(a.expected)))."
            overlays.anomalies.append(AnalyticsOverlays.Anomaly(seriesColumn: seriesColumn, row: a.index, expected: a.expected,
                                                                lower: a.lower, upper: a.upper, explanation: text))
        }
        overlays.expectedBands[seriesColumn] = zip(r.lower, r.upper).map { (lower: $0, upper: $1) }
        return r
    }

    /// Ranks dimension members that best explain an anomaly.
    ///
    /// For each dimension the `breakdown` closure is asked for the per-member values of the series at the
    /// anomalous point and at up to six neighbouring normal points; each member's expected value is the
    /// median of its neighbours. A member's strength is the share of the anomaly's deviation it accounts for.
    /// - Parameters:
    ///   - anomalyIndex: index of the anomalous point in the series.
    ///   - result: the detection result the index refers to.
    ///   - dimensions: candidate "explain by" fields.
    ///   - breakdown: returns `(member, value)` pairs for a dimension at a series index.
    public static func explain(anomalyIndex: Int, in result: AnomalyResult, dimensions: [FieldRef],
                               breakdown: (_ dimension: FieldRef, _ index: Int) -> [(member: Value, value: Double)],
                               maxResults: Int = 5, minimumStrength: Double = 10) -> [AnomalyExplanation] {
        let n = result.values.count
        guard anomalyIndex >= 0, anomalyIndex < n else { return [] }
        let deviation = result.values[anomalyIndex] - result.expected[anomalyIndex]
        guard deviation != 0 else { return [] }
        let flagged = Set(result.anomalies.map(\.index))
        var neighbours: [Int] = []
        var offset = 1
        while neighbours.count < 6, offset < n {
            for i in [anomalyIndex - offset, anomalyIndex + offset] where i >= 0 && i < n && !flagged.contains(i) && neighbours.count < 6 {
                neighbours.append(i)
            }
            offset += 1
        }
        guard !neighbours.isEmpty else { return [] }
        var out: [AnomalyExplanation] = []
        for dim in dimensions {
            let actual = breakdown(dim, anomalyIndex)
            var history: [Value: [Double]] = [:]
            for i in neighbours { for (member, v) in breakdown(dim, i) { history[member, default: []].append(v) } }
            var best: AnomalyExplanation?
            var members = Dictionary(actual.map { ($0.member, $0.value) }, uniquingKeysWith: +)
            for key in history.keys where members[key] == nil { members[key] = 0 }
            for (member, value) in members.sorted(by: { $0.key < $1.key }) {
                let hist = history[member] ?? []
                // Members missing from some neighbours contributed zero there.
                let padded = hist + [Double](repeating: 0, count: max(0, neighbours.count - hist.count))
                let expected = Stats.median(padded)
                let share = (value - expected) / deviation
                guard share > 0 else { continue }
                let strength = min(100, share * 100)
                if strength >= minimumStrength, strength > (best?.strength ?? 0) {
                    let dir = deviation > 0 ? "higher" : "lower"
                    best = AnomalyExplanation(
                        dimension: dim, member: member, actual: value, expected: expected, strength: strength,
                        sentence: "\(dim.caption) \(Fmt.label(member)) was \(dir) than expected "
                            + "(\(Fmt.number(value)) vs \(Fmt.number(expected))), explaining \(Fmt.percent(strength / 100, decimals: 0)) of the deviation.")
                }
            }
            if let b = best { out.append(b) }
        }
        return Array(out.sorted { $0.strength > $1.strength }.prefix(maxResults))
    }

    // MARK: Building blocks

    /// Theil–Sen slope estimate (median of pairwise slopes); pairs are subsampled for long series.
    public static func theilSenSlope(_ y: [Double]) -> Double {
        let n = y.count
        guard n >= 2 else { return 0 }
        var slopes: [Double] = []
        let stride = max(1, n / 300)
        var i = 0
        while i < n {
            var j = i + stride
            while j < n { slopes.append((y[j] - y[i]) / Double(j - i)); j += stride }
            i += stride
        }
        return slopes.isEmpty ? 0 : Stats.median(slopes)
    }

    /// Centred running median; windows shrink symmetrically near the edges.
    public static func runningMedian(_ y: [Double], window: Int) -> [Double] {
        let n = y.count, half = max(1, window / 2)
        return (0..<n).map { i in
            let h = min(half, i, n - 1 - i)
            if h == 0 {
                // Edge: use the nearest full-ish window's median to avoid passing spikes straight through.
                let lo = max(0, min(i, n - 1 - half)), hi = min(n - 1, lo + half)
                return Stats.median(Array(y[min(lo, hi)...hi]))
            }
            return Stats.median(Array(y[(i - h)...(i + h)]))
        }
    }

    /// Centred moving average with edge shrinkage.
    public static func smooth(_ y: [Double], window: Int) -> [Double] {
        let n = y.count, half = max(0, window / 2)
        return (0..<n).map { i in
            let h = min(half, i, n - 1 - i)
            return Stats.mean(Array(y[(i - h)...(i + h)]))
        }
    }
}
