import Foundation
import FacetCore

/// Shared argument helpers for the context-free function libraries.
enum PureArgs {
    /// Numeric argument; BLANK and omitted arguments are 0.
    static func n(_ a: [Value], _ i: Int) throws -> Double { try DAXOps.number(a[safe: i] ?? .null) }
    /// Numeric argument with a default used when omitted or BLANK.
    static func n(_ a: [Value], _ i: Int, default d: Double) throws -> Double {
        guard let v = a[safe: i], !v.isNull else { return d }
        return try DAXOps.number(v)
    }
    static func isBlank(_ a: [Value], _ i: Int) -> Bool { (a[safe: i] ?? .null).isNull }
    static func s(_ a: [Value], _ i: Int) -> String { (a[safe: i] ?? .null).asString }
    static func flag(_ a: [Value], _ i: Int, default d: Bool = false) throws -> Bool {
        guard let v = a[safe: i], !v.isNull else { return d }
        return try DAXOps.truthy(v)
    }
    /// Whole-number argument (truncated toward zero).
    static func i(_ a: [Value], _ i: Int, default d: Int = 0) throws -> Int {
        guard let v = a[safe: i], !v.isNull else { return d }
        let x = try DAXOps.number(v)
        guard x.isFinite, abs(x) < 9e15 else { throw DAXError("The argument is too large or not a number.") }
        return Int(x.rounded(.towardZero))
    }
    /// A whole-number result when the double is integral and safely representable, else a double.
    static func whole(_ d: Double) -> Value {
        d.isFinite && abs(d) < 9e15 && d == d.rounded() ? .int(Int64(d)) : .double(d)
    }
    static func finite(_ d: Double, _ fn: String) throws -> Value {
        guard d.isFinite else { throw DAXError("An argument of function '\(fn)' has the wrong data type or the result is too large or too small.") }
        return .double(d)
    }
}

/// Context-free math, trigonometry and simple logical/information functions.
enum PureMath {
    private typealias A = PureArgs

    /// Rounds `x` to `digits` decimal places using the given rule on the scaled value.
    static func round(_ x: Double, digits: Int, mode: FloatingPointRoundingRule) -> Double {
        guard x.isFinite else { return x }
        let p = pow(10.0, Double(digits))
        var s = x * p
        guard s.isFinite else { return x }
        // Nudge to undo binary representation error (2.675 * 100 = 267.49999…).
        let eps = abs(s) * 1e-12
        switch mode {
        case .towardZero: s += s < 0 ? -eps : eps
        case .awayFromZero: s += s < 0 ? eps : -eps
        default: s += s < 0 ? -eps : eps
        }
        return s.rounded(mode) / p
    }

    private static func ceilingTo(_ x: Double, _ sig: Double) -> Double {
        if sig == 0 { return 0 }
        let q = x / sig
        let r = (q - abs(q) * 1e-12).rounded(.up)
        return r * sig
    }
    private static func floorTo(_ x: Double, _ sig: Double) -> Double {
        if sig == 0 { return 0 }
        let q = x / sig
        let r = (q + abs(q) * 1e-12).rounded(.down)
        return r * sig
    }
    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
    private static func factorial(_ n: Int) -> Double {
        var r = 1.0
        if n > 1 { for k in 2...n { r *= Double(k) } }
        return r
    }
    private static func unary(_ name: String, _ f: @escaping (Double) -> Double) -> PureFn {
        return { a in try A.finite(f(try A.n(a, 0)), name) }
    }

    static let functions: [String: PureFn] = {
        var f: [String: PureFn] = [:]

        f["ABS"] = { a in
            switch a[safe: 0] ?? .null {
            case .null: return .null
            case .int(let i): return .int(abs(i))
            case let v: return .double(abs(try DAXOps.number(v)))
            }
        }
        f["ROUND"] = { a in
            if A.isBlank(a, 0) { return .null }
            return .double(round(try A.n(a, 0), digits: try A.i(a, 1), mode: .toNearestOrAwayFromZero))
        }
        f["ROUNDUP"] = { a in
            if A.isBlank(a, 0) { return .null }
            return .double(round(try A.n(a, 0), digits: try A.i(a, 1), mode: .awayFromZero))
        }
        f["ROUNDDOWN"] = { a in
            if A.isBlank(a, 0) { return .null }
            return .double(round(try A.n(a, 0), digits: try A.i(a, 1), mode: .towardZero))
        }
        f["MROUND"] = { a in
            if A.isBlank(a, 0) { return .null }
            let x = try A.n(a, 0), m = try A.n(a, 1)
            if m == 0 { return .double(0) }
            if (x < 0) != (m < 0), x != 0 { throw DAXError("MROUND requires the number and the multiple to have the same sign.") }
            let q = x / m
            return .double((q + abs(q) * 1e-12).rounded(.toNearestOrAwayFromZero) * m)
        }
        f["INT"] = { a in
            if A.isBlank(a, 0) { return .null }
            if case .int(let i)? = a[safe: 0] { return .int(i) }
            return A.whole(floor(try A.n(a, 0)))
        }
        f["TRUNC"] = { a in
            if A.isBlank(a, 0) { return .null }
            let d = try A.i(a, 1)
            let r = round(try A.n(a, 0), digits: d, mode: .towardZero)
            return d <= 0 ? A.whole(r) : .double(r)
        }
        f["CEILING"] = { a in
            if A.isBlank(a, 0) { return .null }
            let x = try A.n(a, 0), sig = try A.n(a, 1, default: 1)
            if x > 0, sig < 0 { throw DAXError("CEILING requires the significance to have the same sign as the number.") }
            let r = ceilingTo(x, sig)
            return DAXOps.isIntLike(a[0]) && DAXOps.isIntLike(a[safe: 1] ?? .int(1)) ? A.whole(r) : .double(r)
        }
        f["FLOOR"] = { a in
            if A.isBlank(a, 0) { return .null }
            let x = try A.n(a, 0), sig = try A.n(a, 1, default: 1)
            if x > 0, sig < 0 { throw DAXError("FLOOR requires the significance to have the same sign as the number.") }
            if sig == 0 { throw DAXError("FLOOR cannot use a significance of zero.") }
            let r = floorTo(x, sig)
            return DAXOps.isIntLike(a[0]) && DAXOps.isIntLike(a[safe: 1] ?? .int(1)) ? A.whole(r) : .double(r)
        }
        f["ISO.CEILING"] = { a in
            if A.isBlank(a, 0) { return .null }
            let x = try A.n(a, 0), sig = abs(try A.n(a, 1, default: 1))
            return .double(ceilingTo(x, sig))
        }
        f["MOD"] = { a in
            let x = try A.n(a, 0), d = try A.n(a, 1)
            if d == 0 { throw DAXError("MOD cannot divide by zero.") }
            let r = x - d * floor(x / d)
            if DAXOps.isIntLike(a[safe: 0] ?? .int(0)) || A.isBlank(a, 0), DAXOps.isIntLike(a[safe: 1] ?? .null) { return A.whole(r) }
            return .double(r)
        }
        f["QUOTIENT"] = { a in
            let x = try A.n(a, 0), d = try A.n(a, 1)
            if d == 0 { throw DAXError("QUOTIENT cannot divide by zero.") }
            return A.whole((x / d).rounded(.towardZero))
        }
        f["DIVIDE"] = { a in
            let alt = a.count > 2 ? a[2] : Value.null
            guard let d = try DAXOps.num(a[safe: 1] ?? .null), d != 0 else { return alt }
            guard let x = try DAXOps.num(a[safe: 0] ?? .null) else { return .null }
            return .double(x / d)
        }
        f["POWER"] = { a in
            let r = pow(try A.n(a, 0), try A.n(a, 1))
            if r.isNaN { throw DAXError("An argument of function 'POWER' has the wrong data type or the result is too large or too small.") }
            if DAXOps.isIntLike(a[safe: 0] ?? .null), DAXOps.isIntLike(a[safe: 1] ?? .null), try A.n(a, 1) >= 0 { return A.whole(r) }
            return .double(r)
        }
        f["SQRT"] = { a in
            if A.isBlank(a, 0) { return .null }
            let x = try A.n(a, 0)
            if x < 0 { throw DAXError("SQRT cannot take the square root of a negative number.") }
            return .double(x.squareRoot())
        }
        f["SQRTPI"] = { a in
            let x = try A.n(a, 0)
            if x < 0 { throw DAXError("SQRTPI cannot take the square root of a negative number.") }
            return .double((x * Double.pi).squareRoot())
        }
        f["EXP"] = unary("EXP") { exp($0) }
        f["LN"] = { a in
            let x = try A.n(a, 0)
            if x <= 0 { throw DAXError("LN requires a positive number.") }
            return .double(log(x))
        }
        f["LOG10"] = { a in
            let x = try A.n(a, 0)
            if x <= 0 { throw DAXError("LOG10 requires a positive number.") }
            return .double(log10(x))
        }
        f["LOG"] = { a in
            let x = try A.n(a, 0), b = try A.n(a, 1, default: 10)
            if x <= 0 || b <= 0 || b == 1 { throw DAXError("LOG requires a positive number and a positive base other than 1.") }
            return .double(b == 10 ? log10(x) : log(x) / log(b))
        }
        f["SIGN"] = { a in
            if A.isBlank(a, 0) { return .null }
            let x = try A.n(a, 0)
            return .int(x > 0 ? 1 : (x < 0 ? -1 : 0))
        }
        f["PI"] = { _ in .double(Double.pi) }
        f["RAND"] = { _ in .double(Double.random(in: 0..<1)) }
        f["RANDBETWEEN"] = { a in
            let lo = Int64(ceil(try A.n(a, 0))), hi = Int64(floor(try A.n(a, 1)))
            if lo > hi { throw DAXError("RANDBETWEEN requires the bottom value to be less than or equal to the top value.") }
            return .int(Int64.random(in: lo...hi))
        }
        f["FACT"] = { a in
            let n = try A.i(a, 0)
            if n < 0 { throw DAXError("FACT requires a non-negative number.") }
            if n > 170 { throw DAXError("FACT: the result is too large.") }
            return A.whole(factorial(n))
        }
        f["COMBIN"] = { a in
            let n = try A.i(a, 0), k = try A.i(a, 1)
            if n < 0 || k < 0 || k > n { throw DAXError("COMBIN requires 0 <= number_chosen <= number.") }
            var r = 1.0
            let kk = min(k, n - k)
            if kk > 0 { for j in 1...kk { r = r * Double(n - kk + j) / Double(j) } }
            return A.whole(r.rounded())
        }
        f["PERMUT"] = { a in
            let n = try A.i(a, 0), k = try A.i(a, 1)
            if n < 0 || k < 0 || k > n { throw DAXError("PERMUT requires 0 <= number_chosen <= number.") }
            var r = 1.0
            if k > 0 { for j in 0..<k { r *= Double(n - j) } }
            return A.whole(r)
        }
        f["GCD"] = { a in
            let x = try A.i(a, 0), y = try A.i(a, 1)
            if x < 0 || y < 0 { throw DAXError("GCD requires non-negative numbers.") }
            return .int(gcd(Int64(x), Int64(y)))
        }
        f["LCM"] = { a in
            let x = try A.i(a, 0), y = try A.i(a, 1)
            if x < 0 || y < 0 { throw DAXError("LCM requires non-negative numbers.") }
            if x == 0 || y == 0 { return .int(0) }
            let g = gcd(Int64(x), Int64(y))
            let (r, o) = (Int64(x) / g).multipliedReportingOverflow(by: Int64(y))
            return o ? .double(Double(x) / Double(g) * Double(y)) : .int(r)
        }
        f["EVEN"] = { a in
            let x = try A.n(a, 0)
            let r = (abs(x) / 2 - abs(x) * 1e-13).rounded(.up) * 2
            return A.whole(x < 0 ? -r : r)
        }
        f["ODD"] = { a in
            let x = try A.n(a, 0)
            var r = (abs(x) - abs(x) * 1e-13).rounded(.up)
            if r.truncatingRemainder(dividingBy: 2) == 0 { r += 1 }
            return A.whole(x < 0 ? -r : r)
        }
        f["ISEVEN"] = { a in .bool(Int64((try A.n(a, 0)).rounded(.towardZero)) % 2 == 0) }
        f["ISODD"] = { a in .bool(Int64((try A.n(a, 0)).rounded(.towardZero)) % 2 != 0) }
        f["CURRENCY"] = { a in
            if A.isBlank(a, 0) { return .null }
            return .double(round(try A.n(a, 0), digits: 4, mode: .toNearestOrAwayFromZero))
        }

        // Trigonometry
        f["SIN"] = unary("SIN") { sin($0) }
        f["COS"] = unary("COS") { cos($0) }
        f["TAN"] = unary("TAN") { tan($0) }
        f["ASIN"] = unary("ASIN") { asin($0) }
        f["ACOS"] = unary("ACOS") { acos($0) }
        f["ATAN"] = unary("ATAN") { atan($0) }
        f["SINH"] = unary("SINH") { sinh($0) }
        f["COSH"] = unary("COSH") { cosh($0) }
        f["TANH"] = unary("TANH") { tanh($0) }
        f["ASINH"] = unary("ASINH") { asinh($0) }
        f["ACOSH"] = unary("ACOSH") { acosh($0) }
        f["ATANH"] = unary("ATANH") { atanh($0) }
        f["COT"] = unary("COT") { 1 / tan($0) }
        f["ACOT"] = unary("ACOT") { Double.pi / 2 - atan($0) }
        f["DEGREES"] = unary("DEGREES") { $0 * 180 / Double.pi }
        f["RADIANS"] = unary("RADIANS") { $0 * Double.pi / 180 }

        // Context-free logical and information functions
        f["AND"] = { a in .bool(try DAXOps.truthy(a[safe: 0] ?? .null) && DAXOps.truthy(a[safe: 1] ?? .null)) }
        f["OR"] = { a in .bool(try DAXOps.truthy(a[safe: 0] ?? .null) || DAXOps.truthy(a[safe: 1] ?? .null)) }
        f["NOT"] = { a in .bool(!(try DAXOps.truthy(a[safe: 0] ?? .null))) }
        f["TRUE"] = { _ in .bool(true) }
        f["FALSE"] = { _ in .bool(false) }
        f["BLANK"] = { _ in .null }
        f["ISBLANK"] = { a in .bool((a[safe: 0] ?? .null).isNull) }
        f["ISNUMBER"] = { a in .bool((a[safe: 0] ?? .null).isNumber) }
        f["ISTEXT"] = { a in if case .string? = a[safe: 0] { return .bool(true) }; return .bool(false) }
        f["ISNONTEXT"] = { a in if case .string? = a[safe: 0] { return .bool(false) }; return .bool(true) }
        f["ISLOGICAL"] = { a in if case .bool? = a[safe: 0] { return .bool(true) }; return .bool(false) }
        return f
    }()
}
