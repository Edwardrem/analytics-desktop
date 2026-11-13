import Foundation
import FacetCore

/// Context-free financial functions (Excel-compatible formulas).
enum PureFinancial {
    private typealias A = PureArgs

    static func pmt(_ r: Double, _ n: Double, _ pv: Double, _ fv: Double, _ type: Double) -> Double {
        if r == 0 { return -(pv + fv) / n }
        let g = pow(1 + r, n)
        return -(r * (pv * g + fv)) / ((1 + r * type) * (g - 1))
    }
    static func fv(_ r: Double, _ n: Double, _ pmt: Double, _ pv: Double, _ type: Double) -> Double {
        if r == 0 { return -(pv + pmt * n) }
        let g = pow(1 + r, n)
        return -(pv * g + pmt * (1 + r * type) * (g - 1) / r)
    }
    static func pv(_ r: Double, _ n: Double, _ pmt: Double, _ fv: Double, _ type: Double) -> Double {
        if r == 0 { return -(fv + pmt * n) }
        let g = pow(1 + r, n)
        return -(fv + pmt * (1 + r * type) * (g - 1) / r) / g
    }
    static func ipmt(_ r: Double, _ per: Double, _ n: Double, _ pv: Double, _ fvv: Double, _ type: Double) -> Double {
        if type == 1, per == 1 { return 0 }
        let p = pmt(r, n, pv, fvv, type)
        var i = fv(r, per - 1, p, pv, type) * r
        if type == 1 { i /= (1 + r) }
        return i
    }
    private static func type(_ a: [Value], _ i: Int) throws -> Double { (try A.n(a, i)) != 0 ? 1 : 0 }
    private static func check(_ d: Double, _ fn: String) throws -> Value {
        guard d.isFinite else { throw DAXError("\(fn): the arguments do not produce a valid result.") }
        return .double(d)
    }

    /// Net present value of irregular cash flows, discounting by actual days / 365 from the first date.
    static func xnpv(rate: Double, values: [Double], dates: [Date]) -> Double {
        guard let d0 = dates.first else { return 0 }
        var total = 0.0
        for (v, d) in zip(values, dates) {
            let years = d.timeIntervalSince(d0) / 86400 / 365
            total += v / pow(1 + rate, years)
        }
        return total
    }

    /// Internal rate of return for irregular cash flows (Newton's method with a bisection fallback).
    static func xirr(values: [Double], dates: [Date], guess: Double) throws -> Double {
        guard values.count == dates.count, values.count >= 2 else {
            throw DAXError("XIRR needs at least two cash flows with matching dates.")
        }
        guard values.contains(where: { $0 > 0 }), values.contains(where: { $0 < 0 }) else {
            throw DAXError("XIRR needs at least one positive and one negative cash flow.")
        }
        let d0 = dates[0]
        let years = dates.map { $0.timeIntervalSince(d0) / 86400 / 365 }
        func f(_ r: Double) -> Double {
            var t = 0.0
            for (v, y) in zip(values, years) { t += v / pow(1 + r, y) }
            return t
        }
        func df(_ r: Double) -> Double {
            var t = 0.0
            for (v, y) in zip(values, years) { t += -y * v / pow(1 + r, y + 1) }
            return t
        }
        var r = guess > -1 ? guess : 0.1
        for _ in 0..<100 {
            let fx = f(r), d = df(r)
            guard fx.isFinite, d.isFinite, d != 0 else { break }
            let next = r - fx / d
            guard next.isFinite, next > -1 else { break }
            if abs(next - r) < 1e-10 { return next }
            r = next
        }
        // Bisection over a bracketing interval.
        var lo = -0.999999, hi = 1.0
        var flo = f(lo), fhi = f(hi)
        var tries = 0
        while flo.sign == fhi.sign, tries < 60 { hi = hi * 2 + 1; fhi = f(hi); tries += 1 }
        guard flo.isFinite, fhi.isFinite, flo.sign != fhi.sign else {
            throw DAXError("XIRR could not find a rate; try a different guess.")
        }
        for _ in 0..<300 {
            let mid = (lo + hi) / 2, fm = f(mid)
            if abs(fm) < 1e-10 || (hi - lo) < 1e-12 { return mid }
            if fm.sign == flo.sign { lo = mid; flo = fm } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static let functions: [String: PureFn] = {
        var f: [String: PureFn] = [:]

        f["PMT"] = { a in
            let n = try A.n(a, 1)
            if n == 0 { throw DAXError("PMT: the number of periods cannot be zero.") }
            return try check(pmt(try A.n(a, 0), n, try A.n(a, 2), try A.n(a, 3), try type(a, 4)), "PMT")
        }
        f["PV"] = { a in try check(pv(try A.n(a, 0), try A.n(a, 1), try A.n(a, 2), try A.n(a, 3), try type(a, 4)), "PV") }
        f["FV"] = { a in try check(fv(try A.n(a, 0), try A.n(a, 1), try A.n(a, 2), try A.n(a, 3), try type(a, 4)), "FV") }
        f["NPER"] = { a in
            let r = try A.n(a, 0), p = try A.n(a, 1), pvv = try A.n(a, 2), fvv = try A.n(a, 3), t = try type(a, 4)
            if r == 0 {
                if p == 0 { throw DAXError("NPER: the payment cannot be zero when the rate is zero.") }
                return .double(-(pvv + fvv) / p)
            }
            let k = p * (1 + r * t)
            return try check(log((k - fvv * r) / (k + pvv * r)) / log(1 + r), "NPER")
        }
        f["RATE"] = { a in
            let n = try A.n(a, 0), p = try A.n(a, 1), pvv = try A.n(a, 2), fvv = try A.n(a, 3), t = try type(a, 4)
            var r = try A.n(a, 5, default: 0.1)
            if n <= 0 { throw DAXError("RATE: the number of periods must be positive.") }
            func g(_ r: Double) -> Double {
                if abs(r) < 1e-12 { return pvv + p * n + fvv }
                let c = pow(1 + r, n)
                return pvv * c + p * (1 + r * t) * (c - 1) / r + fvv
            }
            for _ in 0..<200 {
                let y = g(r)
                let h = max(abs(r), 1e-4) * 1e-6
                let d = (g(r + h) - g(r - h)) / (2 * h)
                guard y.isFinite, d.isFinite, d != 0 else { break }
                let next = r - y / d
                guard next.isFinite, next > -1 else { break }
                if abs(next - r) < 1e-11 { return .double(next) }
                r = next
            }
            throw DAXError("RATE could not find a result; try a different guess.")
        }
        f["IPMT"] = { a in
            let per = try A.n(a, 1), n = try A.n(a, 2)
            if per < 1 || per > n { throw DAXError("IPMT: the period must be between 1 and the number of periods.") }
            return try check(ipmt(try A.n(a, 0), per, n, try A.n(a, 3), try A.n(a, 4), try type(a, 5)), "IPMT")
        }
        f["PPMT"] = { a in
            let r = try A.n(a, 0), per = try A.n(a, 1), n = try A.n(a, 2), pvv = try A.n(a, 3), fvv = try A.n(a, 4), t = try type(a, 5)
            if per < 1 || per > n { throw DAXError("PPMT: the period must be between 1 and the number of periods.") }
            return try check(pmt(r, n, pvv, fvv, t) - ipmt(r, per, n, pvv, fvv, t), "PPMT")
        }
        f["CUMIPMT"] = { a in
            let r = try A.n(a, 0), n = try A.n(a, 1), pvv = try A.n(a, 2), t = try type(a, 5)
            let s = try A.i(a, 3), e = try A.i(a, 4)
            if r <= 0 || n <= 0 || pvv <= 0 || s < 1 || e < s || Double(e) > n { throw DAXError("CUMIPMT: the arguments are out of range.") }
            var total = 0.0
            for per in s...e { total += ipmt(r, Double(per), n, pvv, 0, t) }
            return .double(total)
        }
        f["CUMPRINC"] = { a in
            let r = try A.n(a, 0), n = try A.n(a, 1), pvv = try A.n(a, 2), t = try type(a, 5)
            let s = try A.i(a, 3), e = try A.i(a, 4)
            if r <= 0 || n <= 0 || pvv <= 0 || s < 1 || e < s || Double(e) > n { throw DAXError("CUMPRINC: the arguments are out of range.") }
            let p = pmt(r, n, pvv, 0, t)
            var total = 0.0
            for per in s...e { total += p - ipmt(r, Double(per), n, pvv, 0, t) }
            return .double(total)
        }
        f["ISPMT"] = { a in
            let n = try A.n(a, 2)
            if n == 0 { throw DAXError("ISPMT: the number of periods cannot be zero.") }
            return .double(try A.n(a, 3) * A.n(a, 0) * (A.n(a, 1) / n - 1))
        }
        f["SLN"] = { a in
            let life = try A.n(a, 2)
            if life == 0 { throw DAXError("SLN: the life cannot be zero.") }
            return .double((try A.n(a, 0) - A.n(a, 1)) / life)
        }
        f["SYD"] = { a in
            let cost = try A.n(a, 0), salvage = try A.n(a, 1), life = try A.n(a, 2), per = try A.n(a, 3)
            if life <= 0 || per < 1 || per > life { throw DAXError("SYD: the period must be between 1 and the life.") }
            return .double((cost - salvage) * (life - per + 1) * 2 / (life * (life + 1)))
        }
        f["DB"] = { a in
            let cost = try A.n(a, 0), salvage = try A.n(a, 1)
            let life = try A.i(a, 2), period = try A.i(a, 3)
            let month = try A.n(a, 4, default: 12)
            if cost < 0 || salvage < 0 || life <= 0 || period < 1 || month < 1 || month > 12 || period > life + 1 {
                throw DAXError("DB: the arguments are out of range.")
            }
            if cost == 0 { return .double(0) }
            let rate = (PureMath.round(1 - pow(salvage / cost, 1 / Double(life)), digits: 3, mode: .toNearestOrAwayFromZero))
            var total = 0.0, dep = 0.0
            for p in 1...period {
                if p == 1 { dep = cost * rate * month / 12 }
                else if p == life + 1 { dep = (cost - total) * rate * (12 - month) / 12 }
                else { dep = (cost - total) * rate }
                total += dep
            }
            return .double(dep)
        }
        f["DDB"] = { a in
            let cost = try A.n(a, 0), salvage = try A.n(a, 1), life = try A.n(a, 2)
            let period = try A.i(a, 3)
            let factor = try A.n(a, 4, default: 2)
            if cost < 0 || salvage < 0 || life <= 0 || period < 1 || Double(period) > life || factor <= 0 {
                throw DAXError("DDB: the arguments are out of range.")
            }
            var total = 0.0, dep = 0.0
            for _ in 1...period {
                dep = min((cost - total) * factor / life, max(0, cost - salvage - total))
                total += dep
            }
            return .double(dep)
        }
        f["EFFECT"] = { a in
            let nominal = try A.n(a, 0), np = floor(try A.n(a, 1))
            if nominal <= 0 || np < 1 { throw DAXError("EFFECT: the nominal rate must be positive and npery at least 1.") }
            return .double(pow(1 + nominal / np, np) - 1)
        }
        f["NOMINAL"] = { a in
            let effect = try A.n(a, 0), np = floor(try A.n(a, 1))
            if effect <= 0 || np < 1 { throw DAXError("NOMINAL: the effective rate must be positive and npery at least 1.") }
            return .double(np * (pow(1 + effect, 1 / np) - 1))
        }
        f["RRI"] = { a in
            let n = try A.n(a, 0), pvv = try A.n(a, 1), fvv = try A.n(a, 2)
            if n <= 0 || pvv == 0 { throw DAXError("RRI: the number of periods must be positive and pv non-zero.") }
            return try check(pow(fvv / pvv, 1 / n) - 1, "RRI")
        }
        f["PDURATION"] = { a in
            let r = try A.n(a, 0), pvv = try A.n(a, 1), fvv = try A.n(a, 2)
            if r <= 0 || pvv <= 0 || fvv <= 0 { throw DAXError("PDURATION: all arguments must be positive.") }
            return .double((log(fvv) - log(pvv)) / log(1 + r))
        }
        f["DOLLARDE"] = { a in
            let x = try A.n(a, 0), fraction = floor(try A.n(a, 1))
            if fraction < 1 { throw DAXError("DOLLARDE: the fraction must be at least 1.") }
            let ip = x.rounded(.towardZero)
            let digits = pow(10, ceil(log10(fraction)))
            return .double(ip + (x - ip) * digits / fraction)
        }
        f["DOLLARFR"] = { a in
            let x = try A.n(a, 0), fraction = floor(try A.n(a, 1))
            if fraction < 1 { throw DAXError("DOLLARFR: the fraction must be at least 1.") }
            let ip = x.rounded(.towardZero)
            let digits = pow(10, ceil(log10(fraction)))
            return .double(ip + (x - ip) * fraction / digits)
        }
        return f
    }()
}
