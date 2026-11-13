import Foundation
import FacetCore

/// Trend-line families.
public enum TrendKind: Sendable, Equatable {
    case linear
    case polynomial(degree: Int)
    /// y = a·e^(b·x); needs positive y.
    case exponential
    /// y = a + b·ln(x); needs positive x.
    case logarithmic
    /// y = a·x^b; needs positive x and y.
    case power
    /// Trailing moving average over `period` points.
    case movingAverage(period: Int)
}

/// A fitted trend line.
public struct TrendFit: Sendable {
    public var kind: TrendKind
    /// linear/polynomial: c0 + c1·x + c2·x² …; exponential: [a, b]; logarithmic: [a, b]; power: [a, b]; moving average: empty.
    public var coefficients: [Double]
    /// Coefficient of determination on the original y scale (nil where undefined).
    public var rSquared: Double?
    /// Trend value per input point (nil where the trend is undefined, e.g. the first points of a moving average).
    public var fitted: [Double?]
    /// Human-readable equation.
    public var equation: String

    /// Evaluates the trend at `x`. Returns nil for moving averages and out-of-domain inputs.
    public func predict(_ x: Double) -> Double? {
        switch kind {
        case .linear, .polynomial:
            var v = 0.0, p = 1.0
            for c in coefficients { v += c * p; p *= x }
            return v
        case .exponential: return coefficients[0] * exp(coefficients[1] * x)
        case .logarithmic: return x > 0 ? coefficients[0] + coefficients[1] * log(x) : nil
        case .power: return x > 0 ? coefficients[0] * pow(x, coefficients[1]) : nil
        case .movingAverage: return nil
        }
    }
}

public enum TrendLine {
    /// Fits a trend through `(x, y)` pairs. Returns nil when the data cannot support the requested family
    /// (too few points, non-positive values for log/exponential fits, …).
    public static func fit(x: [Double], y: [Double], kind: TrendKind) -> TrendFit? {
        let n = min(x.count, y.count)
        guard n >= 2 else { return nil }
        let xs = Array(x.prefix(n)), ys = Array(y.prefix(n))
        func r2(_ pred: [Double?]) -> Double? {
            let mean = Stats.mean(ys)
            var sse = 0.0, sst = 0.0, used = 0
            for i in 0..<n { if let p = pred[i] { sse += (ys[i] - p) * (ys[i] - p); sst += (ys[i] - mean) * (ys[i] - mean); used += 1 } }
            guard used >= 2, sst > 0 else { return sse == 0 && used >= 2 ? 1 : nil }
            return max(0, 1 - sse / sst)
        }
        func g(_ v: Double) -> String { String(format: "%.4g", v) }
        switch kind {
        case .linear, .polynomial:
            var degree = 1
            if case .polynomial(let d) = kind { degree = max(1, min(d, 6)) }
            guard n > degree else { return nil }
            // Centre and scale x for numerical stability, then expand back to raw-x coefficients.
            let mx = Stats.mean(xs)
            var sx = Stats.stdDev(xs, sample: false)
            if sx <= 0 { return nil }
            if !sx.isFinite { sx = 1 }
            let rows = xs.map { v -> [Double] in let u = (v - mx) / sx; return (1...degree).map { pow(u, Double($0)) } }
            guard let f = OLS.fit(x: rows, y: ys) else { return nil }
            // Expand Σ b_k ((x − mx)/sx)^k into powers of x.
            var coeffs = [Double](repeating: 0, count: degree + 1)
            for k in 0...degree {
                let bk = f.coefficients[k] / pow(sx, Double(k))
                for j in 0...k { coeffs[j] += bk * binomial(k, j) * pow(-mx, Double(k - j)) }
            }
            var fit = TrendFit(kind: degree == 1 ? .linear : .polynomial(degree: degree), coefficients: coeffs, rSquared: nil, fitted: [], equation: "")
            fit.fitted = xs.map { fit.predict($0) }
            fit.rSquared = r2(fit.fitted)
            fit.equation = "y = " + coeffs.enumerated().reversed().map { i, c in
                i == 0 ? g(c) : (i == 1 ? "\(g(c))x" : "\(g(c))x^\(i)")
            }.joined(separator: " + ").replacingOccurrences(of: "+ -", with: "− ")
            return fit
        case .exponential:
            guard ys.allSatisfy({ $0 > 0 }), let f = OLS.fit(x: xs, y: ys.map { log($0) }) else { return nil }
            var fit = TrendFit(kind: kind, coefficients: [exp(f.coefficients[0]), f.coefficients[1]], rSquared: nil, fitted: [], equation: "")
            fit.fitted = xs.map { fit.predict($0) }
            fit.rSquared = r2(fit.fitted)
            fit.equation = "y = \(g(fit.coefficients[0]))·e^(\(g(fit.coefficients[1]))x)"
            return fit
        case .logarithmic:
            guard xs.allSatisfy({ $0 > 0 }), let f = OLS.fit(x: xs.map { log($0) }, y: ys) else { return nil }
            var fit = TrendFit(kind: kind, coefficients: [f.coefficients[0], f.coefficients[1]], rSquared: nil, fitted: [], equation: "")
            fit.fitted = xs.map { fit.predict($0) }
            fit.rSquared = r2(fit.fitted)
            fit.equation = "y = \(g(fit.coefficients[0])) + \(g(fit.coefficients[1]))·ln(x)"
            return fit
        case .power:
            guard xs.allSatisfy({ $0 > 0 }), ys.allSatisfy({ $0 > 0 }),
                  let f = OLS.fit(x: xs.map { log($0) }, y: ys.map { log($0) }) else { return nil }
            var fit = TrendFit(kind: kind, coefficients: [exp(f.coefficients[0]), f.coefficients[1]], rSquared: nil, fitted: [], equation: "")
            fit.fitted = xs.map { fit.predict($0) }
            fit.rSquared = r2(fit.fitted)
            fit.equation = "y = \(g(fit.coefficients[0]))·x^\(g(fit.coefficients[1]))"
            return fit
        case .movingAverage(let period):
            let p = max(1, min(period, n))
            var fitted = [Double?](repeating: nil, count: n)
            var running = 0.0
            for i in 0..<n {
                running += ys[i]
                if i >= p { running -= ys[i - p] }
                if i >= p - 1 { fitted[i] = running / Double(p) }
            }
            return TrendFit(kind: .movingAverage(period: p), coefficients: [], rSquared: r2(fitted), fitted: fitted,
                            equation: "\(p)-period moving average")
        }
    }

    /// Fits a trend through an evenly spaced series, skipping nil values. x is the 1-based position.
    /// `fitted` in the result is parallel to `values` (nil stays nil for moving averages only).
    public static func fit(values: [Double?], kind: TrendKind) -> TrendFit? {
        let pairs = values.enumerated().compactMap { i, v in v.flatMap { $0.isFinite ? (Double(i + 1), $0) : nil } }
        guard var f = fit(x: pairs.map(\.0), y: pairs.map(\.1), kind: kind) else { return nil }
        if case .movingAverage = kind {
            var full = [Double?](repeating: nil, count: values.count)
            for (k, pair) in pairs.enumerated() { full[Int(pair.0) - 1] = f.fitted[k] }
            f.fitted = full
        } else {
            f.fitted = values.indices.map { f.predict(Double($0 + 1)) }
        }
        return f
    }

    static func binomial(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        var r = 1.0
        for i in 0..<min(k, n - k) { r = r * Double(n - i) / Double(i + 1) }
        return r
    }
}

/// Reference lines from the Analytics pane.
public enum ReferenceLineKind: Sendable, Equatable {
    case constant(Double), min, max, mean, median
    /// Percentile 0…100.
    case percentile(Double)
}

public enum ReferenceLines {
    /// The y-value of a reference line over a series. Returns nil for an empty series (except constants).
    public static func value(_ kind: ReferenceLineKind, values: [Double]) -> Double? {
        let v = values.filter(\.isFinite)
        if case .constant(let c) = kind { return c }
        guard !v.isEmpty else { return nil }
        switch kind {
        case .constant(let c): return c
        case .min: return v.min()
        case .max: return v.max()
        case .mean: return Stats.mean(v)
        case .median: return Stats.median(v)
        case .percentile(let p): return Stats.quantile(v, p / 100)
        }
    }

    /// Resolves an `AnalyticsItem` of a reference-line kind (constant, min, max, average, median, percentile).
    /// Returns nil for other kinds.
    public static func value(for item: AnalyticsItem, values: [Double]) -> Double? {
        switch item.kind {
        case .constantLine: return value(.constant(item.value), values: values)
        case .minLine: return value(.min, values: values)
        case .maxLine: return value(.max, values: values)
        case .averageLine: return value(.mean, values: values)
        case .medianLine: return value(.median, values: values)
        case .percentileLine: return value(.percentile(item.value), values: values)
        default: return nil
        }
    }
}

/// Error-bar definitions.
public enum ErrorBarKind: Sendable {
    /// ± multiplier × standard deviation.
    case standardDeviation(multiplier: Double)
    /// ± multiplier × standard error of the mean.
    case standardError(multiplier: Double)
    /// ± percentage of each value (e.g. 10 for ±10%).
    case percentage(Double)
    /// Lower/upper percentiles (0…100) of the observations.
    case percentile(lower: Double, upper: Double)
    /// Bounds supplied by fields. When `relative` is true the fields hold offsets from the value.
    case byField(upper: [Double?], lower: [Double?], relative: Bool)
}

public struct ErrorBar: Sendable, Equatable {
    public var lower: Double
    public var upper: Double
}

public enum ErrorBars {
    /// Computes one error bar per point.
    /// - Parameters:
    ///   - values: the plotted values (nil = no bar).
    ///   - samples: optional underlying observations per point. When given, deviation / error / percentile
    ///     bars are computed per point from its observations; otherwise from the plotted series as a whole.
    public static func compute(values: [Double?], kind: ErrorBarKind, samples: [[Double]]? = nil) -> [ErrorBar?] {
        let series = values.compactMap { $0 }.filter(\.isFinite)
        return values.enumerated().map { i, v in
            guard let v, v.isFinite else { return nil }
            let obs = samples?[safe: i] ?? series
            switch kind {
            case .standardDeviation(let k):
                guard obs.count >= 2 else { return nil }
                let d = k * Stats.stdDev(obs)
                return ErrorBar(lower: v - d, upper: v + d)
            case .standardError(let k):
                guard obs.count >= 2 else { return nil }
                let d = k * Stats.stdDev(obs) / sqrt(Double(obs.count))
                return ErrorBar(lower: v - d, upper: v + d)
            case .percentage(let p):
                let d = abs(v) * p / 100
                return ErrorBar(lower: v - d, upper: v + d)
            case .percentile(let lo, let hi):
                guard !obs.isEmpty else { return nil }
                return ErrorBar(lower: Stats.quantile(obs, lo / 100), upper: Stats.quantile(obs, hi / 100))
            case .byField(let upper, let lower, let relative):
                let u = upper[safe: i].flatMap { $0 }, l = lower[safe: i].flatMap { $0 }
                guard u != nil || l != nil else { return nil }
                if relative { return ErrorBar(lower: v - abs(l ?? 0), upper: v + abs(u ?? 0)) }
                return ErrorBar(lower: l ?? v, upper: u ?? v)
            }
        }
    }
}

/// Scatter-chart helpers: symmetry shading and ratio line.
public enum ScatterAnalytics {
    public struct Symmetry: Sendable {
        /// Indices of points where y > x, y < x and y == x.
        public var above: [Int]
        public var below: [Int]
        public var onLine: [Int]
        /// End points of the y = x line spanning the data extent.
        public var lineStart: Double
        public var lineEnd: Double
    }
    public struct RatioLine: Sendable {
        /// Σy / Σx — the overall ratio of the two measures.
        public var slope: Double
        public var start: (x: Double, y: Double)
        public var end: (x: Double, y: Double)
        /// Indices of points above / below the ratio line.
        public var above: [Int]
        public var below: [Int]
    }

    /// Splits points by the y = x diagonal for symmetry shading.
    public static func symmetry(x: [Double], y: [Double]) -> Symmetry {
        let n = min(x.count, y.count)
        var above: [Int] = [], below: [Int] = [], on: [Int] = []
        for i in 0..<n { if y[i] > x[i] { above.append(i) } else if y[i] < x[i] { below.append(i) } else { on.append(i) } }
        let all = Array(x.prefix(n)) + Array(y.prefix(n))
        return Symmetry(above: above, below: below, onLine: on, lineStart: min(0, all.min() ?? 0), lineEnd: all.max() ?? 0)
    }

    /// The ratio line y = (Σy / Σx)·x through the origin. Returns nil when Σx is zero.
    public static func ratioLine(x: [Double], y: [Double]) -> RatioLine? {
        let n = min(x.count, y.count)
        let sx = x.prefix(n).reduce(0, +), sy = y.prefix(n).reduce(0, +)
        guard n > 0, sx != 0 else { return nil }
        let slope = sy / sx
        let xmax = x.prefix(n).max() ?? 0, xmin = min(0, x.prefix(n).min() ?? 0)
        var above: [Int] = [], below: [Int] = []
        for i in 0..<n { if y[i] > slope * x[i] { above.append(i) } else if y[i] < slope * x[i] { below.append(i) } }
        return RatioLine(slope: slope, start: (xmin, slope * xmin), end: (xmax, slope * xmax), above: above, below: below)
    }
}
