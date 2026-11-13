import Foundation

/// Dense linear-algebra helpers (small systems only).
public enum LinearAlgebra {
    /// Solves `A x = b` by Gaussian elimination with partial pivoting. Returns nil when singular.
    public static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a, y = b
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<max(col + 1, n) where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { m.swapAt(pivot, col); y.swapAt(pivot, col) }
            for r in (col + 1)..<max(col + 1, n) {
                let f = m[r][col] / m[col][col]
                if f == 0 { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                y[r] -= f * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for j in (i + 1)..<max(i + 1, n) { s -= m[i][j] * x[j] }
            x[i] = s / m[i][i]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Matrix inverse via Gauss–Jordan. Returns nil when singular.
    public static func invert(_ a: [[Double]]) -> [[Double]]? {
        let n = a.count
        guard n > 0, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a
        var inv = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(pivot, col); inv.swapAt(pivot, col)
            let d = m[col][col]
            for c in 0..<n { m[col][c] /= d; inv[col][c] /= d }
            for r in 0..<n where r != col {
                let f = m[r][col]
                if f == 0 { continue }
                for c in 0..<n { m[r][c] -= f * m[col][c]; inv[r][c] -= f * inv[col][c] }
            }
        }
        return inv
    }
}

/// Ordinary least squares fit.
public struct OLSResult: Sendable {
    /// Coefficients; the intercept comes first when the model has one.
    public var coefficients: [Double]
    public var standardErrors: [Double]
    public var tStatistics: [Double]
    /// Two-sided p-values per coefficient.
    public var pValues: [Double]
    public var rSquared: Double
    public var adjustedRSquared: Double
    public var residualStdError: Double
    public var fitted: [Double]
    public var residuals: [Double]
    public var hasIntercept: Bool
    /// True when the normal equations were singular and a small ridge penalty was applied.
    public var usedRidge: Bool

    public func predict(_ features: [Double]) -> Double {
        var v = hasIntercept ? coefficients[0] : 0
        let off = hasIntercept ? 1 : 0
        for (i, f) in features.enumerated() where i + off < coefficients.count { v += coefficients[i + off] * f }
        return v
    }
}

public enum OLS {
    /// Multivariate least squares via the normal equations, falling back to ridge when they are singular.
    /// - Parameters:
    ///   - x: one row of feature values per observation.
    ///   - y: the response.
    public static func fit(x: [[Double]], y: [Double], intercept: Bool = true) -> OLSResult? {
        let n = y.count
        guard n > 0, x.count == n else { return nil }
        let p0 = x[0].count
        guard x.allSatisfy({ $0.count == p0 }) else { return nil }
        let p = p0 + (intercept ? 1 : 0)
        guard p > 0, n >= p else { return nil }
        func row(_ i: Int) -> [Double] { intercept ? [1] + x[i] : x[i] }
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var xty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            let r = row(i)
            for a in 0..<p {
                xty[a] += r[a] * y[i]
                for b in a..<p { xtx[a][b] += r[a] * r[b] }
            }
        }
        for a in 0..<p { for b in 0..<a { xtx[a][b] = xtx[b][a] } }
        var usedRidge = false
        var inv = LinearAlgebra.invert(xtx)
        if inv == nil {
            usedRidge = true
            let scale = (0..<p).map { xtx[$0][$0] }.max() ?? 1
            var lambda = max(scale, 1) * 1e-8
            for _ in 0..<8 {
                var r = xtx
                for a in (intercept ? 1 : 0)..<p { r[a][a] += lambda }
                if intercept, r[0][0] == 0 { r[0][0] = lambda }
                inv = LinearAlgebra.invert(r)
                if inv != nil { break }
                lambda *= 100
            }
        }
        guard let xtxInv = inv else { return nil }
        let beta = (0..<p).map { a in (0..<p).reduce(0.0) { $0 + xtxInv[a][$1] * xty[$1] } }
        var fitted = [Double](repeating: 0, count: n), resid = fitted
        var sse = 0.0
        let ybar = y.reduce(0, +) / Double(n)
        var sst = 0.0
        for i in 0..<n {
            let r = row(i)
            var f = 0.0
            for a in 0..<p { f += r[a] * beta[a] }
            fitted[i] = f; resid[i] = y[i] - f
            sse += resid[i] * resid[i]
            sst += intercept ? (y[i] - ybar) * (y[i] - ybar) : y[i] * y[i]
        }
        let df = Double(n - p)
        let sigma2 = df > 0 ? sse / df : 0
        let se = (0..<p).map { sqrt(max(0, sigma2 * xtxInv[$0][$0])) }
        let t = (0..<p).map { se[$0] > 0 ? beta[$0] / se[$0] : (beta[$0] == 0 ? 0 : Double.infinity * (beta[$0] > 0 ? 1 : -1)) }
        let pv = t.map { df > 0 ? SpecialFunctions.tTwoSidedP($0, df: df) : Double.nan }
        let r2 = sst > 0 ? max(0, 1 - sse / sst) : (sse == 0 ? 1 : 0)
        let adj = df > 0 && n > 1 ? 1 - (1 - r2) * Double(n - (intercept ? 1 : 0)) / df : r2
        return OLSResult(coefficients: beta, standardErrors: se, tStatistics: t, pValues: pv, rSquared: r2,
                         adjustedRSquared: adj, residualStdError: sqrt(sigma2), fitted: fitted, residuals: resid,
                         hasIntercept: intercept, usedRidge: usedRidge)
    }

    /// Simple regression of `y` on a single predictor.
    public static func fit(x: [Double], y: [Double]) -> OLSResult? { fit(x: x.map { [$0] }, y: y) }
}

/// Logistic regression fit.
public struct LogisticResult: Sendable {
    /// Coefficients on the log-odds scale; the intercept comes first.
    public var coefficients: [Double]
    public var standardErrors: [Double]
    /// Wald z statistics and two-sided p-values per coefficient.
    public var zStatistics: [Double]
    public var pValues: [Double]
    public var logLikelihood: Double
    public var iterations: Int
    public var converged: Bool

    /// Predicted probability for one observation's features (without the intercept column).
    public func probability(_ features: [Double]) -> Double {
        var eta = coefficients[0]
        for (i, f) in features.enumerated() where i + 1 < coefficients.count { eta += coefficients[i + 1] * f }
        return 1 / (1 + exp(-eta))
    }
    /// Odds ratio for a one-unit increase of feature `index` (0-based, excluding the intercept).
    public func oddsRatio(_ index: Int) -> Double { exp(coefficients[index + 1]) }
}

public enum LogisticRegression {
    /// Fits a binary logistic regression with an intercept by iteratively reweighted least squares.
    /// A small ridge penalty (`ridge`) keeps the fit finite under perfect separation.
    public static func fit(x: [[Double]], y: [Bool], maxIterations: Int = 50, tolerance: Double = 1e-8,
                           ridge: Double = 1e-6) -> LogisticResult? {
        let n = y.count
        guard n > 0, x.count == n else { return nil }
        let p0 = x[0].count
        guard x.allSatisfy({ $0.count == p0 }) else { return nil }
        let p = p0 + 1
        guard n > p else { return nil }
        var beta = [Double](repeating: 0, count: p)
        let positives = y.filter { $0 }.count
        guard positives > 0, positives < n else { return nil }
        beta[0] = log(Double(positives) / Double(n - positives))
        var converged = false
        var iterations = 0
        var hessianInv: [[Double]]?
        var lastLL = -Double.infinity
        for iter in 1...maxIterations {
            iterations = iter
            var h = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
            var g = [Double](repeating: 0, count: p)
            var ll = 0.0
            for i in 0..<n {
                var eta = beta[0]
                for j in 0..<p0 { eta += beta[j + 1] * x[i][j] }
                eta = max(-30, min(30, eta))
                let mu = 1 / (1 + exp(-eta))
                let yi = y[i] ? 1.0 : 0.0
                ll += yi * log(max(mu, 1e-300)) + (1 - yi) * log(max(1 - mu, 1e-300))
                let w = max(mu * (1 - mu), 1e-10)
                let e = yi - mu
                g[0] += e; h[0][0] += w
                for a in 0..<p0 {
                    let xa = x[i][a]
                    g[a + 1] += e * xa
                    h[0][a + 1] += w * xa
                    for b in a..<p0 { h[a + 1][b + 1] += w * xa * x[i][b] }
                }
            }
            for a in 0..<p { for b in 0..<a { h[a][b] = h[b][a] } }
            for a in 1..<max(1, p) { h[a][a] += ridge; g[a] -= ridge * beta[a] }
            guard let inv = LinearAlgebra.invert(h) else { return nil }
            hessianInv = inv
            var maxStep = 0.0
            var step = [Double](repeating: 0, count: p)
            for a in 0..<p {
                for b in 0..<p { step[a] += inv[a][b] * g[b] }
                maxStep = max(maxStep, abs(step[a]))
            }
            // Dampen wild steps (quasi-separation).
            let damp = maxStep > 10 ? 10 / maxStep : 1
            for a in 0..<p { beta[a] += damp * step[a] }
            if maxStep < tolerance || abs(ll - lastLL) < tolerance * 1e-2 { converged = true; lastLL = ll; break }
            lastLL = ll
        }
        guard let inv = hessianInv else { return nil }
        let se = (0..<p).map { sqrt(max(0, inv[$0][$0])) }
        let z = (0..<p).map { se[$0] > 0 ? beta[$0] / se[$0] : 0 }
        let pv = z.map { SpecialFunctions.gammaQ(0.5, $0 * $0 / 2) }
        return LogisticResult(coefficients: beta, standardErrors: se, zStatistics: z, pValues: pv,
                              logLikelihood: lastLL, iterations: iterations, converged: converged)
    }
}
