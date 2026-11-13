import Foundation
import FacetCore

/// Exponential-smoothing model families the forecaster chooses between.
public enum ForecastModel: String, Sendable, CaseIterable {
    case simple, holt, dampedHolt, holtWintersAdditive, holtWintersMultiplicative
    public var displayName: String {
        switch self {
        case .simple: return "Simple exponential smoothing"
        case .holt: return "Holt linear trend"
        case .dampedHolt: return "Damped trend"
        case .holtWintersAdditive: return "Holt-Winters (additive seasonality)"
        case .holtWintersMultiplicative: return "Holt-Winters (multiplicative seasonality)"
        }
    }
    var hasTrend: Bool { self != .simple }
    var isSeasonal: Bool { self == .holtWintersAdditive || self == .holtWintersMultiplicative }
}

/// Output of `Forecaster.forecast`.
public struct ForecastResult: Sendable {
    /// Point forecasts. The first `ignoredCount` entries overlap the ignored tail of the input; the rest are future periods.
    public var forecast: [Double]
    public var lower: [Double]
    public var upper: [Double]
    /// One-step-ahead fitted values for the points used in fitting.
    public var fitted: [Double]
    /// Input after interpolation of gaps and removal of the ignored tail.
    public var cleanedValues: [Double]
    public var model: ForecastModel
    public var alpha: Double
    public var beta: Double?
    public var gamma: Double?
    /// Trend damping factor (1 = undamped).
    public var phi: Double?
    /// Season length used, or nil when the series was treated as non-seasonal.
    public var seasonLength: Int?
    /// In-sample mean absolute percentage error, in percent.
    public var mape: Double
    public var aic: Double
    public var residualStdDev: Double
    /// Index in the original series of the first forecast point.
    public var startIndex: Int
    /// Number of trailing input points that were ignored (and are re-forecast).
    public var ignoredCount: Int
    public var confidence: Double
}

public enum ForecastError: LocalizedError {
    case notEnoughData(needed: Int, got: Int)
    case invalidHorizon
    public var errorDescription: String? {
        switch self {
        case .notEnoughData(let needed, let got):
            return "Forecasting needs at least \(needed) data points, but only \(got) are available."
        case .invalidHorizon: return "The forecast length must be at least 1."
        }
    }
}

/// Time-series forecasting by exponential smoothing with automatic model selection.
public enum Forecaster {
    /// Forecasts `horizon` periods beyond the series.
    /// - Parameters:
    ///   - values: evenly spaced observations; nil entries are interpolated.
    ///   - horizon: number of future periods.
    ///   - seasonality: season length in points; nil auto-detects via autocorrelation; 0 or 1 forces non-seasonal.
    ///   - confidence: prediction-interval level, e.g. 0.95.
    ///   - ignoreLast: trailing points to exclude from fitting (they are forecast instead).
    public static func forecast(values: [Double?], horizon: Int, seasonality: Int? = nil, confidence: Double = 0.95,
                                ignoreLast: Int = 0) throws -> ForecastResult {
        guard horizon >= 1 else { throw ForecastError.invalidHorizon }
        let ignored = max(0, min(ignoreLast, values.count))
        let y = interpolate(Array(values.prefix(values.count - ignored)))
        guard y.count >= 3 else { throw ForecastError.notEnoughData(needed: 3 + ignored, got: values.count) }
        let n = y.count
        var m: Int? = nil
        if let s = seasonality { if s >= 2, n >= 2 * s { m = s } }
        else { m = detectSeasonLength(y) }

        var candidates: [ForecastModel] = [.simple]
        if n >= 5 { candidates += [.holt, .dampedHolt] }
        if m != nil {
            candidates.append(.holtWintersAdditive)
            if (y.min() ?? 0) > 0 { candidates.append(.holtWintersMultiplicative) }
        }
        var best: Fit?
        for model in candidates {
            guard let fit = optimise(y, model: model, m: m ?? 1) else { continue }
            if best == nil || fit.aic < best!.aic { best = fit }
        }
        guard let fit = best else { throw ForecastError.notEnoughData(needed: 3, got: n) }

        let steps = horizon + ignored
        let point = fit.state.forecast(steps: steps)
        let z = SpecialFunctions.normalQuantile(0.5 + max(0.01, min(0.9999, confidence)) / 2)
        let sigma = fit.sigma
        var lower: [Double] = [], upper: [Double] = []
        var cumulative = 1.0
        let p = fit.params
        for h in 1...steps {
            if h > 1 {
                let j = h - 1
                var c = p.alpha
                if fit.model.hasTrend { c += p.beta * dampedSum(p.phi, j) }
                if fit.model.isSeasonal, let mm = m, j % mm == 0 { c += p.gamma }
                cumulative += c * c
            }
            let half = z * sigma * sqrt(cumulative)
            lower.append(point[h - 1] - half); upper.append(point[h - 1] + half)
        }
        var apeSum = 0.0, apeCount = 0
        for i in 0..<n where y[i] != 0 { apeSum += abs((y[i] - fit.fitted[i]) / y[i]); apeCount += 1 }
        return ForecastResult(
            forecast: point, lower: lower, upper: upper, fitted: fit.fitted, cleanedValues: y, model: fit.model,
            alpha: p.alpha, beta: fit.model.hasTrend ? p.beta : nil, gamma: fit.model.isSeasonal ? p.gamma : nil,
            phi: fit.model.hasTrend ? p.phi : nil, seasonLength: fit.model.isSeasonal ? m : nil,
            mape: apeCount > 0 ? apeSum / Double(apeCount) * 100 : 0, aic: fit.aic, residualStdDev: sigma,
            startIndex: n, ignoredCount: ignored, confidence: confidence)
    }

    /// Forecast packaged for a chart: continues the axis labels and fills `AnalyticsOverlays.Forecast`.
    /// - Parameter axis: the chart's category values, parallel to `values`.
    public static func overlay(axis: [Value], values: [Double?], seriesColumn: Int, horizon: Int, seasonality: Int? = nil,
                               confidence: Double = 0.95, ignoreLast: Int = 0) throws -> AnalyticsOverlays.Forecast {
        let r = try forecast(values: values, horizon: horizon, seasonality: seasonality, confidence: confidence, ignoreLast: ignoreLast)
        var labels: [Value] = []
        if r.ignoredCount > 0, axis.count >= r.ignoredCount { labels = Array(axis.suffix(r.ignoredCount)) }
        else if r.ignoredCount > 0 { labels = nextLabels(after: axis, count: r.ignoredCount) }
        labels += nextLabels(after: axis, count: horizon)
        return AnalyticsOverlays.Forecast(seriesColumn: seriesColumn, labels: labels, values: r.forecast, lower: r.lower, upper: r.upper)
    }

    /// Linear interpolation of missing values; leading/trailing gaps take the nearest observation.
    public static func interpolate(_ values: [Double?]) -> [Double] {
        let known = values.indices.filter { values[$0] != nil && values[$0]!.isFinite }
        guard let first = known.first, let last = known.last else { return [] }
        var out = [Double](repeating: 0, count: values.count)
        var k = 0
        for i in values.indices {
            if i <= first { out[i] = values[first]! }
            else if i >= last { out[i] = values[last]! }
            else {
                while k + 1 < known.count, known[k + 1] <= i { k += 1 }
                let a = known[k], b = known[min(k + 1, known.count - 1)]
                if a == i || a == b { out[i] = values[a]! }
                else { out[i] = values[a]! + (values[b]! - values[a]!) * Double(i - a) / Double(b - a) }
            }
        }
        return out
    }

    /// Detects a season length from the autocorrelation of the linearly detrended series.
    /// Returns nil when no lag has a clear, significant autocorrelation peak or fewer than two seasons are available.
    public static func detectSeasonLength(_ y: [Double], maxLag: Int? = nil) -> Int? {
        let n = y.count
        guard n >= 8 else { return nil }
        let xs = (0..<n).map(Double.init)
        guard let fit = OLS.fit(x: xs, y: y) else { return nil }
        let resid = fit.residuals
        let limit = min(maxLag ?? n / 2, n / 2)
        guard limit >= 2 else { return nil }
        let acf = Stats.acf(resid, maxLag: min(limit + 1, n - 1))
        let threshold = max(0.3, 2 / sqrt(Double(n)))
        var peaks: [(lag: Int, r: Double)] = []
        for lag in 2...limit where lag < acf.count {
            let r = acf[lag]
            let prev = acf[lag - 1], next = lag + 1 < acf.count ? acf[lag + 1] : -1
            if r > threshold, r > prev, r >= next { peaks.append((lag, r)) }
        }
        guard let top = peaks.map(\.r).max() else { return nil }
        return peaks.first { $0.r >= 0.8 * top }?.lag
    }

    // MARK: Axis continuation

    /// Calendar cadence detected on a date axis.
    public enum Cadence: Equatable, Sendable { case day, week, month, quarter, year, seconds(Double) }

    /// Detects the cadence of a run of dates from the median gap.
    public static func cadence(of dates: [Date]) -> Cadence? {
        guard dates.count >= 2 else { return nil }
        var gaps: [Double] = []
        for i in 1..<dates.count { gaps.append(dates[i].timeIntervalSince(dates[i - 1])) }
        let med = Stats.median(gaps)
        guard med > 0 else { return nil }
        let days = med / 86400
        if abs(days - 1) < 0.05 { return .day }
        if abs(days - 7) < 0.05 { return .week }
        if days >= 27.5, days <= 31.5 { return .month }
        if days >= 88, days <= 93 { return .quarter }
        if days >= 364, days <= 367 { return .year }
        return .seconds(med)
    }

    /// Continues a date or number axis by `count` labels, following its detected cadence
    /// (day / week / month / quarter / year, or the median numeric step). Text axes that are neither
    /// dates nor numbers continue as "+1", "+2", ….
    public static func nextLabels(after axis: [Value], count: Int) -> [Value] {
        guard count > 0 else { return [] }
        let nonNull = axis.filter { !$0.isNull }
        // Dates
        let dates: [Date] = nonNull.compactMap { if case .date(let d) = $0 { return d }; return nil }
        if dates.count == nonNull.count, let last = dates.last {
            let cad = cadence(of: dates) ?? .day
            let cal = Calendar.utc
            let endOfMonth = dates.allSatisfy { d in
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { return false }
                return cal.component(.day, from: next) == 1
            } && cal.component(.day, from: last) >= 28
            func addMonths(_ k: Int) -> Date {
                if endOfMonth {
                    let first = cal.date(from: cal.dateComponents([.year, .month], from: last)) ?? last
                    let target = cal.date(byAdding: .month, value: k + 1, to: first) ?? last
                    let day = cal.date(byAdding: .day, value: -1, to: target) ?? target
                    let tod = last.timeIntervalSince(cal.startOfDay(for: last))
                    return cal.startOfDay(for: day).addingTimeInterval(tod)
                }
                return cal.date(byAdding: .month, value: k, to: last) ?? last
            }
            return (1...count).map { i in
                switch cad {
                case .day: return .date(cal.date(byAdding: .day, value: i, to: last) ?? last)
                case .week: return .date(cal.date(byAdding: .day, value: 7 * i, to: last) ?? last)
                case .month: return .date(addMonths(i))
                case .quarter: return .date(addMonths(3 * i))
                case .year: return .date(addMonths(12 * i))
                case .seconds(let s): return .date(last.addingTimeInterval(s * Double(i)))
                }
            }
        }
        // Numbers (including numeric text such as "2024")
        let nums = nonNull.compactMap { v -> Double? in
            switch v { case .int, .double: return v.asDouble; case .string(let s): return Double(s); default: return nil }
        }
        if nums.count == nonNull.count, let last = nums.last {
            var step = 1.0
            if nums.count >= 2 {
                var gaps: [Double] = []
                for i in 1..<nums.count { gaps.append(nums[i] - nums[i - 1]) }
                let med = Stats.median(gaps)
                if med != 0 { step = med }
            }
            let allInt = nonNull.allSatisfy { if case .int = $0 { return true }; return false } && step == step.rounded()
            let allString = nonNull.allSatisfy { if case .string = $0 { return true }; return false }
            return (1...count).map { i in
                let v = last + step * Double(i)
                if allString { return .string(Value.double(v).asString) }
                return allInt ? .int(Int64(v)) : .double(v)
            }
        }
        return (1...count).map { .string("+\($0)") }
    }

    // MARK: Model fitting (error-correction form of additive-error ETS)

    struct Params { var alpha: Double; var beta: Double; var gamma: Double; var phi: Double }

    struct State {
        var level: Double
        var trend: Double
        var seasonal: [Double]   // ring buffer; `pos` is the season index of the next observation
        var pos: Int
        var model: ForecastModel
        var phi: Double

        func forecast(steps: Int) -> [Double] {
            var out: [Double] = []
            let m = seasonal.count
            for h in 1...max(1, steps) {
                var v = level + (model.hasTrend ? Forecaster.dampedSum(phi, h) * trend : 0)
                if model == .holtWintersAdditive { v += seasonal[(pos + h - 1) % m] }
                else if model == .holtWintersMultiplicative { v *= seasonal[(pos + h - 1) % m] }
                out.append(v)
            }
            return out
        }
    }

    struct Fit { var model: ForecastModel; var params: Params; var sse: Double; var aic: Double; var sigma: Double; var fitted: [Double]; var state: State }

    /// φ + φ² + … + φʰ.
    static func dampedSum(_ phi: Double, _ h: Int) -> Double {
        if abs(phi - 1) < 1e-12 { return Double(h) }
        return phi * (1 - pow(phi, Double(h))) / (1 - phi)
    }

    static func initialState(_ y: [Double], model: ForecastModel, m: Int, phi: Double) -> State {
        let n = y.count
        if model.isSeasonal {
            let seasons = n / m
            let means = (0..<seasons).map { s in Stats.mean(Array(y[(s * m)..<((s + 1) * m)])) }
            let trend = seasons >= 2 ? (means[seasons - 1] - means[0]) / Double((seasons - 1) * m) : 0
            // Level at "time zero" so that the first season's mean sits mid-season.
            let level = means[0] - trend * Double(m + 1) / 2
            var seasonal = [Double](repeating: 0, count: m)
            for i in 0..<m {
                var acc = 0.0
                for s in 0..<seasons {
                    let base = means[s] + trend * (Double(i) - Double(m - 1) / 2)
                    acc += model == .holtWintersAdditive ? y[s * m + i] - base : (base != 0 ? y[s * m + i] / base : 1)
                }
                seasonal[i] = acc / Double(seasons)
            }
            if model == .holtWintersAdditive {
                let avg = Stats.mean(seasonal); seasonal = seasonal.map { $0 - avg }
            } else {
                let avg = Stats.mean(seasonal); if avg != 0 { seasonal = seasonal.map { $0 / avg } }
            }
            return State(level: level, trend: trend, seasonal: seasonal, pos: 0, model: model, phi: phi)
        }
        var trend = 0.0
        var level = y[0]
        if model.hasTrend {
            let k = min(n, 10)
            if let f = OLS.fit(x: (0..<k).map(Double.init), y: Array(y.prefix(k))) {
                trend = f.coefficients[1]; level = f.coefficients[0] - trend
            }
        }
        return State(level: level, trend: trend, seasonal: [0], pos: 0, model: model, phi: phi)
    }

    static func run(_ y: [Double], model: ForecastModel, m: Int, params p: Params) -> (sse: Double, fitted: [Double], state: State) {
        var s = initialState(y, model: model, m: m, phi: model == .dampedHolt ? p.phi : 1)
        var sse = 0.0
        var fitted = [Double](repeating: 0, count: y.count)
        let mm = s.seasonal.count
        for t in 0..<y.count {
            let base = s.level + (model.hasTrend ? s.phi * s.trend : 0)
            let season = s.seasonal[s.pos]
            let yhat: Double
            switch model {
            case .holtWintersAdditive: yhat = base + season
            case .holtWintersMultiplicative: yhat = base * season
            default: yhat = base
            }
            let e = y[t] - yhat
            fitted[t] = yhat
            sse += e * e
            switch model {
            case .holtWintersMultiplicative:
                let sd = abs(season) > 1e-9 ? season : 1e-9
                let bd = abs(base) > 1e-9 ? base : 1e-9
                s.level = base + p.alpha * e / sd
                s.trend = s.phi * s.trend + p.beta * e / sd
                s.seasonal[s.pos] = season + p.gamma * e / bd
            case .holtWintersAdditive:
                s.level = base + p.alpha * e
                s.trend = s.phi * s.trend + p.beta * e
                s.seasonal[s.pos] = season + p.gamma * e
            default:
                s.level = base + p.alpha * e
                if model.hasTrend { s.trend = s.phi * s.trend + p.beta * e }
            }
            s.pos = (s.pos + 1) % mm
            if !sse.isFinite { return (.infinity, fitted, s) }
        }
        return (sse, fitted, s)
    }

    static func optimise(_ y: [Double], model: ForecastModel, m: Int) -> Fit? {
        if model.isSeasonal, y.count < 2 * m { return nil }
        // Unconstrained parameters mapped through a logistic: alpha, beta*/alpha, gamma*/(1-alpha), phi in 0.8…0.98.
        func sig(_ v: Double) -> Double { 1 / (1 + exp(-v)) }
        func decode(_ u: [Double]) -> Params {
            let alpha = 0.001 + 0.998 * sig(u[0])
            var p = Params(alpha: alpha, beta: 0, gamma: 0, phi: 1)
            var i = 1
            if model.hasTrend { p.beta = alpha * (0.0005 + 0.999 * sig(u[i])); i += 1 }
            if model.isSeasonal { p.gamma = (1 - alpha) * (0.0005 + 0.999 * sig(u[i])); i += 1 }
            if model == .dampedHolt { p.phi = 0.8 + 0.18 * sig(u[i]) }
            return p
        }
        let dims = 1 + (model.hasTrend ? 1 : 0) + (model.isSeasonal ? 1 : 0) + (model == .dampedHolt ? 1 : 0)
        let objective: ([Double]) -> Double = { u in run(y, model: model, m: m, params: decode(u)).sse }
        var bestU: [Double] = [], bestV = Double.infinity
        // A few deterministic starting points, each refined by Nelder–Mead.
        let starts: [[Double]] = [
            [Double](repeating: -1, count: dims), [Double](repeating: 0.5, count: dims),
            [1.5] + [Double](repeating: -2, count: dims - 1), [-2] + [Double](repeating: 0, count: dims - 1),
        ]
        for s in starts {
            let (u, v) = NelderMead.minimise(objective, start: s, step: 1.0, maxIterations: 300, tolerance: 1e-10)
            if v < bestV { bestV = v; bestU = u }
        }
        guard bestV.isFinite, !bestU.isEmpty else { return nil }
        let params = decode(bestU)
        let r = run(y, model: model, m: m, params: params)
        let n = Double(y.count)
        // Free parameters: smoothing parameters + initial level (+ trend) (+ m − 1 seasonal states).
        let k = Double(dims + 1 + (model.hasTrend ? 1 : 0) + (model.isSeasonal ? m - 1 : 0))
        let sse = max(r.sse, 1e-12 * max(1, y.map { $0 * $0 }.reduce(0, +)))
        let aic = n * log(sse / n) + 2 * k
        let sigma = sqrt(r.sse / max(1, n - Double(dims)))
        return Fit(model: model, params: params, sse: r.sse, aic: aic, sigma: sigma, fitted: r.fitted, state: r.state)
    }
}

/// Derivative-free Nelder–Mead simplex minimiser.
public enum NelderMead {
    /// Minimises `f` starting from `start`. Returns the best point and its value.
    public static func minimise(_ f: ([Double]) -> Double, start: [Double], step: Double = 1, maxIterations: Int = 500,
                                tolerance: Double = 1e-9) -> (point: [Double], value: Double) {
        let n = start.count
        guard n > 0 else { return (start, f(start)) }
        var simplex: [[Double]] = [start]
        for i in 0..<n { var p = start; p[i] += step; simplex.append(p) }
        var values = simplex.map { let v = f($0); return v.isNaN ? Double.infinity : v }
        for _ in 0..<maxIterations {
            let order = values.indices.sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }; values = order.map { values[$0] }
            if abs(values[n] - values[0]) <= tolerance * (abs(values[0]) + tolerance) { break }
            var centroid = [Double](repeating: 0, count: n)
            for i in 0..<n { for j in 0..<n { centroid[j] += simplex[i][j] / Double(n) } }
            func along(_ t: Double) -> [Double] { (0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) } }
            func eval(_ p: [Double]) -> Double { let v = f(p); return v.isNaN ? .infinity : v }
            let reflected = along(-1), fr = eval(reflected)
            if fr < values[0] {
                let expanded = along(-2), fe = eval(expanded)
                if fe < fr { simplex[n] = expanded; values[n] = fe } else { simplex[n] = reflected; values[n] = fr }
            } else if fr < values[n - 1] {
                simplex[n] = reflected; values[n] = fr
            } else {
                let contracted = fr < values[n] ? along(-0.5) : along(0.5), fc = eval(contracted)
                if fc < min(fr, values[n]) { simplex[n] = contracted; values[n] = fc }
                else {
                    for i in 1...n {
                        simplex[i] = (0..<n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }
                        values[i] = eval(simplex[i])
                    }
                }
            }
        }
        let best = values.indices.min { values[$0] < values[$1] } ?? 0
        return (simplex[best], values[best])
    }
}
