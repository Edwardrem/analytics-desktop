import Foundation

/// Special functions and probability distributions used for p-values and intervals.
/// All implementations are self-contained (no Accelerate) and accurate to roughly 1e-10.
public enum SpecialFunctions {
    /// Natural log of the gamma function (Lanczos approximation, g = 7, n = 9).
    public static func lnGamma(_ x: Double) -> Double {
        if x < 0.5 {
            // Reflection formula.
            return log(Double.pi / abs(sin(Double.pi * x))) - lnGamma(1 - x)
        }
        let g = 7.0
        let c: [Double] = [
            0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
            -176.61502916214059, 12.507343278686905, -0.13857109526572012,
            9.9843695780195716e-6, 1.5056327351493116e-7,
        ]
        let xx = x - 1
        var a = c[0]
        let t = xx + g + 0.5
        for i in 1..<c.count { a += c[i] / (xx + Double(i)) }
        return 0.5 * log(2 * Double.pi) + (xx + 0.5) * log(t) - t + log(a)
    }

    /// Regularised lower incomplete gamma function P(a, x).
    public static func gammaP(_ a: Double, _ x: Double) -> Double {
        guard a > 0, x > 0 else { return 0 }
        if x < a + 1 {
            // Series representation.
            var sum = 1 / a, term = 1 / a, n = a
            for _ in 0..<1000 {
                n += 1
                term *= x / n
                sum += term
                if abs(term) < abs(sum) * 1e-15 { break }
            }
            return min(1, sum * exp(-x + a * log(x) - lnGamma(a)))
        }
        return 1 - gammaQContinuedFraction(a, x)
    }

    /// Regularised upper incomplete gamma function Q(a, x) = 1 − P(a, x).
    public static func gammaQ(_ a: Double, _ x: Double) -> Double {
        guard a > 0 else { return 0 }
        guard x > 0 else { return 1 }
        if x < a + 1 { return 1 - gammaP(a, x) }
        return gammaQContinuedFraction(a, x)
    }

    private static func gammaQContinuedFraction(_ a: Double, _ x: Double) -> Double {
        // Modified Lentz's method.
        let tiny = 1e-300
        var b = x + 1 - a
        var c = 1 / tiny
        var d = 1 / b
        var h = d
        for i in 1..<1000 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b
            if abs(d) < tiny { d = tiny }
            c = b + an / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-15 { break }
        }
        return max(0, min(1, exp(-x + a * log(x) - lnGamma(a)) * h))
    }

    /// Regularised incomplete beta function I_x(a, b).
    public static func betaI(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else { return .nan }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnFront = lnGamma(a + b) - lnGamma(a) - lnGamma(b) + a * log(x) + b * log(1 - x)
        if x < (a + 1) / (a + b + 2) {
            return exp(lnFront) * betaContinuedFraction(x, a, b) / a
        }
        return 1 - exp(lnFront) * betaContinuedFraction(1 - x, b, a) / b
    }

    private static func betaContinuedFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-300
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1..<1000 {
            let fm = Double(m), m2 = 2 * fm
            var aa = fm * (b - fm) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + fm) * (qab + fm) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-15 { break }
        }
        return h
    }

    /// Error function.
    public static func erf(_ x: Double) -> Double {
        x >= 0 ? gammaP(0.5, x * x) : -gammaP(0.5, x * x)
    }

    // MARK: Distributions

    /// Standard normal cumulative distribution function.
    public static func normalCDF(_ z: Double) -> Double {
        if z < -8 { return 0 }
        if z > 8 { return 1 }
        return z >= 0 ? 0.5 + 0.5 * gammaP(0.5, z * z / 2) : 0.5 * gammaQ(0.5, z * z / 2)
    }

    /// Standard normal density.
    public static func normalPDF(_ z: Double) -> Double { exp(-z * z / 2) / sqrt(2 * Double.pi) }

    /// Inverse standard normal CDF (Acklam's rational approximation plus one Halley refinement).
    public static func normalQuantile(_ p: Double) -> Double {
        if p <= 0 { return -.infinity }
        if p >= 1 { return .infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let pLow = 0.02425
        var x: Double
        if p < pLow {
            let q = sqrt(-2 * log(p))
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= 1 - pLow {
            let q = p - 0.5, r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = sqrt(-2 * log(1 - p))
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let e = normalCDF(x) - p
        let u = e * sqrt(2 * Double.pi) * exp(x * x / 2)
        x -= u / (1 + x * u / 2)
        return x
    }

    /// Student's t cumulative distribution function with `df` degrees of freedom.
    public static func tCDF(_ t: Double, df: Double) -> Double {
        guard df > 0 else { return .nan }
        let x = df / (df + t * t)
        let tail = 0.5 * betaI(x, df / 2, 0.5)
        return t >= 0 ? 1 - tail : tail
    }

    /// Two-sided p-value for a t statistic.
    public static func tTwoSidedP(_ t: Double, df: Double) -> Double {
        guard df > 0, t.isFinite else { return t.isNaN ? .nan : 0 }
        return min(1, betaI(df / (df + t * t), df / 2, 0.5))
    }

    /// Inverse Student's t CDF (bisection on `tCDF`).
    public static func tQuantile(_ p: Double, df: Double) -> Double {
        if p <= 0 { return -.infinity }
        if p >= 1 { return .infinity }
        if p == 0.5 { return 0 }
        var lo = -1.0, hi = 1.0
        while tCDF(lo, df: df) > p { lo *= 2; if lo < -1e12 { break } }
        while tCDF(hi, df: df) < p { hi *= 2; if hi > 1e12 { break } }
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            if tCDF(mid, df: df) < p { lo = mid } else { hi = mid }
            if hi - lo < 1e-13 * max(1, abs(mid)) { break }
        }
        return (lo + hi) / 2
    }

    /// Chi-square cumulative distribution function.
    public static func chiSquareCDF(_ x: Double, df: Double) -> Double {
        guard x > 0, df > 0 else { return 0 }
        return gammaP(df / 2, x / 2)
    }

    /// Upper-tail probability (p-value) of a chi-square statistic.
    public static func chiSquareSF(_ x: Double, df: Double) -> Double {
        guard df > 0 else { return .nan }
        guard x > 0 else { return 1 }
        return gammaQ(df / 2, x / 2)
    }

    /// Upper-tail probability of an F statistic with (d1, d2) degrees of freedom.
    public static func fSF(_ f: Double, d1: Double, d2: Double) -> Double {
        guard f > 0 else { return 1 }
        return betaI(d2 / (d2 + d1 * f), d2 / 2, d1 / 2)
    }
}

/// Result of a t-test.
public struct TTestResult: Sendable {
    public var statistic: Double
    public var degreesOfFreedom: Double
    /// Two-sided p-value.
    public var pValue: Double
    /// Difference of means (first − second, or sample mean − hypothesised mean).
    public var meanDifference: Double
}

/// Result of a chi-square test.
public struct ChiSquareResult: Sendable {
    public var statistic: Double
    public var degreesOfFreedom: Int
    public var pValue: Double
    /// Expected counts under the null hypothesis (row-major, same shape as the input).
    public var expected: [[Double]]
}

/// Classical hypothesis tests.
public enum HypothesisTests {
    /// Two-sample t-test. Welch's unequal-variance test by default; pooled when `equalVariance` is true.
    /// Returns nil when either sample has fewer than two observations or both variances are zero.
    public static func tTest(_ a: [Double], _ b: [Double], equalVariance: Bool = false) -> TTestResult? {
        guard a.count >= 2, b.count >= 2 else { return nil }
        let ma = Stats.mean(a), mb = Stats.mean(b)
        let va = Stats.variance(a), vb = Stats.variance(b)
        let na = Double(a.count), nb = Double(b.count)
        let se: Double, df: Double
        if equalVariance {
            df = na + nb - 2
            let pooled = ((na - 1) * va + (nb - 1) * vb) / df
            se = sqrt(pooled * (1 / na + 1 / nb))
        } else {
            let sa = va / na, sb = vb / nb
            se = sqrt(sa + sb)
            let denom = sa * sa / (na - 1) + sb * sb / (nb - 1)
            df = denom > 0 ? (sa + sb) * (sa + sb) / denom : na + nb - 2
        }
        guard se > 0 else {
            if ma == mb { return TTestResult(statistic: 0, degreesOfFreedom: df, pValue: 1, meanDifference: 0) }
            return TTestResult(statistic: ma > mb ? .infinity : -.infinity, degreesOfFreedom: df, pValue: 0, meanDifference: ma - mb)
        }
        let t = (ma - mb) / se
        return TTestResult(statistic: t, degreesOfFreedom: df, pValue: SpecialFunctions.tTwoSidedP(t, df: df), meanDifference: ma - mb)
    }

    /// One-sample t-test against a hypothesised mean.
    public static func tTest(_ a: [Double], mean mu: Double) -> TTestResult? {
        guard a.count >= 2 else { return nil }
        let m = Stats.mean(a), n = Double(a.count)
        let se = sqrt(Stats.variance(a) / n)
        guard se > 0 else { return nil }
        let t = (m - mu) / se
        return TTestResult(statistic: t, degreesOfFreedom: n - 1, pValue: SpecialFunctions.tTwoSidedP(t, df: n - 1), meanDifference: m - mu)
    }

    /// Chi-square test of independence on a contingency table (rows × columns of counts), without continuity correction.
    /// Returns nil for tables smaller than 2×2 after removing empty rows/columns, or with a zero grand total.
    public static func chiSquareIndependence(_ observed: [[Double]]) -> ChiSquareResult? {
        guard let width = observed.first?.count, width > 0, observed.allSatisfy({ $0.count == width }) else { return nil }
        let rowSums = observed.map { $0.reduce(0, +) }
        var colSums = [Double](repeating: 0, count: width)
        for r in observed { for (j, v) in r.enumerated() { colSums[j] += v } }
        let total = rowSums.reduce(0, +)
        let liveRows = rowSums.filter { $0 > 0 }.count, liveCols = colSums.filter { $0 > 0 }.count
        guard total > 0, liveRows >= 2, liveCols >= 2 else { return nil }
        var stat = 0.0
        var expected = observed
        for i in observed.indices {
            for j in 0..<width {
                let e = rowSums[i] * colSums[j] / total
                expected[i][j] = e
                if e > 0 { let d = observed[i][j] - e; stat += d * d / e }
            }
        }
        let df = (liveRows - 1) * (liveCols - 1)
        return ChiSquareResult(statistic: stat, degreesOfFreedom: df,
                               pValue: SpecialFunctions.chiSquareSF(stat, df: Double(df)), expected: expected)
    }

    /// Chi-square goodness-of-fit test. `expected` is rescaled to the observed total.
    public static func chiSquareGoodnessOfFit(observed: [Double], expected: [Double]) -> ChiSquareResult? {
        guard observed.count == expected.count, observed.count >= 2 else { return nil }
        let to = observed.reduce(0, +), te = expected.reduce(0, +)
        guard to > 0, te > 0 else { return nil }
        var stat = 0.0
        let scaled = expected.map { $0 * to / te }
        var cells = 0
        for (o, e) in zip(observed, scaled) where e > 0 {
            stat += (o - e) * (o - e) / e
            cells += 1
        }
        guard cells >= 2 else { return nil }
        return ChiSquareResult(statistic: stat, degreesOfFreedom: cells - 1,
                               pValue: SpecialFunctions.chiSquareSF(stat, df: Double(cells - 1)), expected: [scaled])
    }
}
