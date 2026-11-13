import Foundation
import FacetCore

/// Descriptive statistics of a sample.
public struct DescriptiveStats: Sendable {
    public var count: Int
    public var sum: Double
    public var mean: Double
    public var min: Double
    public var max: Double
    /// Sample variance (n − 1 denominator).
    public var variance: Double
    public var stdDev: Double
    public var median: Double
    public var q1: Double
    public var q3: Double
    public var skewness: Double
    /// Excess kurtosis.
    public var kurtosis: Double
    public var iqr: Double { q3 - q1 }
    public var range: Double { max - min }
}

/// One histogram bin: `lower` inclusive, `upper` exclusive (the last bin includes its upper bound).
public struct HistogramBin: Sendable, Equatable {
    public var lower: Double
    public var upper: Double
    public var count: Int
}

/// Five-number summary with Tukey whiskers.
public struct BoxPlotSummary: Sendable {
    public var min: Double
    public var q1: Double
    public var median: Double
    public var q3: Double
    public var max: Double
    /// Lowest/highest observations within `whisker × IQR` of the quartiles.
    public var lowerWhisker: Double
    public var upperWhisker: Double
    public var mean: Double
    public var outliers: [Double]
}

/// The statistics toolkit used throughout FacetAnalytics.
public enum Stats {
    public enum BinRule: Sendable { case freedmanDiaconis, sturges, fixed(Int) }

    public static func sum(_ x: [Double]) -> Double { x.reduce(0, +) }
    public static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }

    /// Variance; sample (n − 1) by default, population when `sample` is false.
    public static func variance(_ x: [Double], sample: Bool = true) -> Double {
        let n = x.count
        guard n > (sample ? 1 : 0) else { return sample ? 0 : .nan }
        let m = mean(x)
        var s = 0.0
        for v in x { s += (v - m) * (v - m) }
        return s / Double(sample ? n - 1 : n)
    }
    public static func stdDev(_ x: [Double], sample: Bool = true) -> Double { sqrt(variance(x, sample: sample)) }
    public static func median(_ x: [Double]) -> Double { quantile(x, 0.5) }

    /// Quantile with linear interpolation between order statistics (R type 7, Excel PERCENTILE.INC). `p` in 0…1.
    public static func quantile(_ x: [Double], _ p: Double) -> Double { quantileSorted(x.sorted(), p) }

    /// As `quantile` but for data already sorted ascending.
    public static func quantileSorted(_ s: [Double], _ p: Double) -> Double {
        guard !s.isEmpty else { return .nan }
        let pp = Swift.max(0, Swift.min(1, p))
        let h = pp * Double(s.count - 1)
        let lo = Int(h.rounded(.down)), hi = Swift.min(s.count - 1, lo + 1)
        return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
    }

    /// Median absolute deviation from the median (unscaled).
    public static func mad(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let m = median(x)
        return median(x.map { abs($0 - m) })
    }

    public static func describe(_ x: [Double]) -> DescriptiveStats? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        let n = Double(x.count), m = mean(x)
        var m2 = 0.0, m3 = 0.0, m4 = 0.0
        for v in x { let d = v - m; m2 += d * d; m3 += d * d * d; m4 += d * d * d * d }
        m2 /= n; m3 /= n; m4 /= n
        let v = variance(x)
        return DescriptiveStats(count: x.count, sum: sum(x), mean: m, min: s[0], max: s[s.count - 1], variance: v,
                                stdDev: sqrt(v), median: quantileSorted(s, 0.5), q1: quantileSorted(s, 0.25),
                                q3: quantileSorted(s, 0.75), skewness: m2 > 0 ? m3 / pow(m2, 1.5) : 0,
                                kurtosis: m2 > 0 ? m4 / (m2 * m2) - 3 : 0)
    }

    /// Histogram with automatic bin count (Freedman–Diaconis by default, falling back to Sturges when the IQR is zero).
    public static func histogram(_ x: [Double], rule: BinRule = .freedmanDiaconis, maxBins: Int = 200) -> [HistogramBin] {
        let vals = x.filter(\.isFinite)
        guard let lo = vals.min(), let hi = vals.max() else { return [] }
        if lo == hi { return [HistogramBin(lower: lo, upper: hi, count: vals.count)] }
        let n = Double(vals.count)
        let sturges = Int(ceil(log2(n))) + 1
        var bins: Int
        switch rule {
        case .fixed(let k): bins = k
        case .sturges: bins = sturges
        case .freedmanDiaconis:
            let s = vals.sorted()
            let iqr = quantileSorted(s, 0.75) - quantileSorted(s, 0.25)
            let width = 2 * iqr / cbrt(n)
            bins = width > 0 ? Int(ceil((hi - lo) / width)) : sturges
        }
        bins = Swift.max(1, Swift.min(maxBins, bins))
        let width = (hi - lo) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for v in vals { counts[Swift.min(bins - 1, Int((v - lo) / width))] += 1 }
        return (0..<bins).map { HistogramBin(lower: lo + Double($0) * width, upper: $0 == bins - 1 ? hi : lo + Double($0 + 1) * width, count: counts[$0]) }
    }

    /// Box-plot summary. Points beyond `whisker × IQR` from the quartiles are outliers.
    public static func boxPlot(_ x: [Double], whisker: Double = 1.5) -> BoxPlotSummary? {
        let s = x.filter(\.isFinite).sorted()
        guard let lo = s.first, let hi = s.last else { return nil }
        let q1 = quantileSorted(s, 0.25), q3 = quantileSorted(s, 0.75)
        let lowFence = q1 - whisker * (q3 - q1), highFence = q3 + whisker * (q3 - q1)
        let inside = s.filter { $0 >= lowFence && $0 <= highFence }
        return BoxPlotSummary(min: lo, q1: q1, median: quantileSorted(s, 0.5), q3: q3, max: hi,
                              lowerWhisker: inside.first ?? q1, upperWhisker: inside.last ?? q3, mean: mean(s),
                              outliers: s.filter { $0 < lowFence || $0 > highFence })
    }

    /// Pearson product-moment correlation; nil when undefined (fewer than 2 points or zero variance).
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Swift.min(x.count, y.count)
        guard n >= 2 else { return nil }
        let mx = mean(Array(x.prefix(n))), my = mean(Array(y.prefix(n)))
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n { let dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        guard sxx > 0, syy > 0 else { return nil }
        return Swift.max(-1, Swift.min(1, sxy / sqrt(sxx * syy)))
    }

    /// Fractional ranks (1-based), ties receive their average rank.
    public static func ranks(_ x: [Double]) -> [Double] {
        let order = x.indices.sorted { x[$0] < x[$1] }
        var r = [Double](repeating: 0, count: x.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, x[order[j + 1]] == x[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }

    /// Spearman rank correlation.
    public static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Swift.min(x.count, y.count)
        return pearson(ranks(Array(x.prefix(n))), ranks(Array(y.prefix(n))))
    }

    /// Two-sided p-value for a correlation coefficient from `n` pairs (t distribution, n − 2 df).
    public static func correlationPValue(r: Double, n: Int) -> Double {
        guard n > 2 else { return 1 }
        if abs(r) >= 1 { return 0 }
        let t = r * sqrt(Double(n - 2) / (1 - r * r))
        return SpecialFunctions.tTwoSidedP(t, df: Double(n - 2))
    }

    /// Sample autocorrelation at `lag`.
    public static func autocorrelation(_ x: [Double], lag: Int) -> Double {
        let n = x.count
        guard lag >= 0, lag < n, n > 1 else { return 0 }
        let m = mean(x)
        var num = 0.0, den = 0.0
        for i in 0..<n { den += (x[i] - m) * (x[i] - m) }
        guard den > 0 else { return 0 }
        for i in lag..<n { num += (x[i] - m) * (x[i - lag] - m) }
        return num / den
    }

    /// Autocorrelation function for lags 0…maxLag.
    public static func acf(_ x: [Double], maxLag: Int) -> [Double] {
        (0...Swift.max(0, Swift.min(maxLag, x.count - 1))).map { autocorrelation(x, lag: $0) }
    }

    /// Gaussian kernel density estimate evaluated on an even grid of `points` covering the data
    /// (extended by three bandwidths). Bandwidth defaults to Silverman's rule of thumb.
    public static func kde(_ x: [Double], points: Int = 64, bandwidth: Double? = nil) -> [(x: Double, density: Double)] {
        let vals = x.filter(\.isFinite)
        guard let lo = vals.min(), let hi = vals.max(), points > 1 else { return [] }
        let n = Double(vals.count)
        var h = bandwidth ?? 0
        if h <= 0 {
            let s = vals.sorted()
            let sd = stdDev(vals), iqr = quantileSorted(s, 0.75) - quantileSorted(s, 0.25)
            var spread = Swift.min(sd, iqr / 1.34)
            if spread <= 0 || !spread.isFinite { spread = Swift.max(sd, iqr / 1.34) }
            h = spread > 0 ? 0.9 * spread * pow(n, -0.2) : Swift.max(abs(lo) * 0.01, 1e-3)
        }
        let a = lo - 3 * h, b = hi + 3 * h
        let step = (b - a) / Double(points - 1)
        let norm = 1 / (n * h * sqrt(2 * Double.pi))
        return (0..<points).map { i in
            let gx = a + Double(i) * step
            var d = 0.0
            for v in vals { let u = (gx - v) / h; if abs(u) < 8 { d += exp(-0.5 * u * u) } }
            return (gx, d * norm)
        }
    }

    /// Jenks natural breaks (Fisher–Jenks optimal classification). Returns `classes + 1` ascending
    /// boundaries from the minimum to the maximum. Large inputs are reduced to 1,000 evenly spaced order statistics.
    public static func jenksBreaks(_ x: [Double], classes: Int) -> [Double] {
        var s = x.filter(\.isFinite).sorted()
        guard let lo = s.first, let hi = s.last else { return [] }
        let distinct = Set(s).count
        let k = Swift.max(1, Swift.min(classes, distinct))
        if k == 1 { return [lo, hi] }
        if s.count > 1000 {
            let full = s
            s = (0..<1000).map { full[Int(Double($0) * Double(full.count - 1) / 999.0)] }
        }
        let n = s.count
        // Prefix sums for O(1) within-class sum of squares.
        var p1 = [Double](repeating: 0, count: n + 1), p2 = p1
        for i in 0..<n { p1[i + 1] = p1[i] + s[i]; p2[i + 1] = p2[i] + s[i] * s[i] }
        func ssd(_ i: Int, _ j: Int) -> Double { // inclusive range i...j
            let cnt = Double(j - i + 1), sm = p1[j + 1] - p1[i]
            return Swift.max(0, (p2[j + 1] - p2[i]) - sm * sm / cnt)
        }
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: n), count: k)
        var back = [[Int]](repeating: [Int](repeating: 0, count: n), count: k)
        for j in 0..<n { cost[0][j] = ssd(0, j) }
        if k > 1 {
            for c in 1..<k {
                for j in c..<n {
                    var best = Double.infinity, bestI = c
                    for i in c...j {
                        let v = cost[c - 1][i - 1] + ssd(i, j)
                        if v < best { best = v; bestI = i }
                    }
                    cost[c][j] = best; back[c][j] = bestI
                }
            }
        }
        var breaks = [Double](repeating: 0, count: k + 1)
        breaks[k] = hi; breaks[0] = lo
        var j = n - 1
        var c = k - 1
        while c > 0 {
            let i = back[c][j]
            breaks[c] = s[i]
            j = i - 1
            c -= 1
        }
        return breaks
    }

    /// Index of the Jenks class (0-based) a value falls into, given boundaries from `jenksBreaks`.
    public static func classIndex(of value: Double, breaks: [Double]) -> Int {
        guard breaks.count >= 2 else { return 0 }
        var idx = 0
        for c in 1..<(breaks.count - 1) where value >= breaks[c] { idx = c }
        return idx
    }
}

// MARK: - Shared helpers

/// Query callback used by analytics that need the model at different granularities.
/// The returned table must contain one column per `groupBy` field, in order, followed by the
/// analysed measure as the **last** column. With an empty `groupBy` it returns a single row.
public typealias AnalyticsQuery = (_ groupBy: [FieldRef], _ filters: [FilterSpec]) -> DataTable

/// Small deterministic pseudo-random generator (SplitMix64) so every analysis is reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Standard normal via Box–Muller.
    public mutating func normal() -> Double {
        let u = Swift.max(unit(), 1e-300), v = unit()
        return sqrt(-2 * log(u)) * cos(2 * Double.pi * v)
    }
}

enum Fmt {
    /// Human-readable number: honours a format string when given, otherwise compact for large magnitudes.
    static func number(_ d: Double, _ format: String = "") -> String {
        guard d.isFinite else { return "n/a" }
        if !format.isEmpty { return ValueFormatter.format(.double(d), format) }
        if abs(d) >= 10000 { return ValueFormatter.compact(d, decimals: 2) }
        if d == d.rounded() { return ValueFormatter.format(.double(d)) }
        if abs(d) < 1 { return String(format: "%.3g", d) }
        return ValueFormatter.format(.double((d * 100).rounded() / 100))
    }
    static func percent(_ fraction: Double, decimals: Int = 1) -> String {
        guard fraction.isFinite else { return "n/a" }
        var s = String(format: "%.\(decimals)f", fraction * 100)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        if s == "-0" { s = "0" }
        return s + "%"
    }
    static func signed(_ d: Double, _ format: String = "") -> String { (d >= 0 ? "+" : "") + number(d, format) }
    static func label(_ v: Value, _ format: String = "") -> String {
        if v.isNull { return "(Blank)" }
        return ValueFormatter.format(v, format)
    }
}
