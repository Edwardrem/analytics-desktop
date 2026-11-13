import Foundation
import FacetCore

enum MNumber {
    /// Round to `digits` decimal places. `mode` only decides ties (M's `RoundingMode`): 0 up, 1 down,
    /// 2 away from zero, 3 toward zero, 4 to even (the default, "banker's rounding").
    static func round(_ x: Double, digits: Int = 0, mode: Int = 4) -> Double {
        guard x.isFinite else { return x }
        let scale = pow(10.0, Double(digits)), scaled = x * scale
        guard scaled.isFinite else { return x }
        let floor = scaled.rounded(.down), fraction = scaled - floor
        let isTie = abs(fraction - 0.5) <= max(abs(scaled), 1) * 4 * Double.ulpOfOne
        let rounded: Double
        if !isTie { rounded = scaled.rounded(.toNearestOrAwayFromZero) }
        else {
            switch mode {
            case 0: rounded = floor + 1
            case 1: rounded = floor
            case 2: rounded = scaled >= 0 ? floor + 1 : floor
            case 3: rounded = scaled >= 0 ? floor : floor + 1
            default: rounded = floor.truncatingRemainder(dividingBy: 2) == 0 ? floor : floor + 1
            }
        }
        return rounded / scale
    }
    static func directed(_ x: Double, digits: Int, _ rule: FloatingPointRoundingRule) -> Double {
        let scale = pow(10.0, Double(digits))
        // Guard against representation noise such as 2.3 * 100 = 229.99999999999997.
        let scaled = x * scale, nearest = scaled.rounded()
        if abs(scaled - nearest) <= max(abs(scaled), 1) * 4 * Double.ulpOfOne { return nearest / scale }
        return scaled.rounded(rule) / scale
    }
    static func factorial(_ n: Double) throws -> Double {
        guard n >= 0, n == n.rounded(), n <= 170 else { throw MError("Number.Factorial needs a whole number from 0 to 170.", detail: .number(n)) }
        return n < 2 ? 1 : (2...Int(n)).reduce(1.0) { $0 * Double($1) }
    }
}

extension MLibrary {
    static func registerNumber(_ lib: MLibrary) {
        lib.enumeration("RoundingMode", [("Up", 0), ("Down", 1), ("AwayFromZero", 2), ("TowardZero", 3), ("ToEven", 4)])
        lib.const("Number.PI", .number(.pi))
        lib.const("Number.E", .number(M_E))
        lib.const("Number.NaN", .number(.nan))
        lib.const("Number.PositiveInfinity", .number(.infinity))
        lib.const("Number.NegativeInfinity", .number(-.infinity))
        lib.const("Number.Epsilon", .number(4.94065645841247e-324))

        /// One-number functions: null in, null out.
        func unary(_ name: String, _ f: @escaping (Double) throws -> Double) {
            lib.fn(name, 1) { a, _ in a[0].isNull ? .null : .number(try f(try a.number(0))) }
        }
        unary("Number.Abs", abs)
        unary("Number.Sign") { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        unary("Number.Sqrt") { $0.squareRoot() }
        unary("Number.Exp", exp)
        unary("Number.Ln", log)
        unary("Number.Log10", log10)
        unary("Number.Sin", sin); unary("Number.Cos", cos); unary("Number.Tan", tan)
        unary("Number.Asin", asin); unary("Number.Acos", acos); unary("Number.Atan", atan)
        unary("Number.Sinh", sinh); unary("Number.Cosh", cosh); unary("Number.Tanh", tanh)
        unary("Number.Factorial", MNumber.factorial)
        lib.fn("Number.Log", 1...2) { a, _ in
            if a[0].isNull { return .null }
            let x = try a.number(0)
            return .number(try a.optNumber(1).map { log(x) / log($0) } ?? log(x))
        }
        func binary(_ name: String, _ f: @escaping (Double, Double) throws -> Double) {
            lib.fn(name, 2...3) { a, _ in (a[0].isNull || a[1].isNull) ? .null : .number(try f(try a.number(0), try a.number(1))) }
        }
        binary("Number.Power", pow)
        binary("Number.Atan2", atan2)
        binary("Number.Mod") { $0.truncatingRemainder(dividingBy: $1) }
        binary("Number.IntegerDivide") { ($0 / $1).rounded(.towardZero) }
        binary("Number.Combinations") { n, k in
            guard k >= 0, k <= n else { throw MError("Number.Combinations: the combination size must be between 0 and the set size.") }
            return (try MNumber.factorial(n) / (try MNumber.factorial(k) * (try MNumber.factorial(n - k)))).rounded()
        }
        binary("Number.Permutations") { n, k in
            guard k >= 0, k <= n else { throw MError("Number.Permutations: the permutation size must be between 0 and the set size.") }
            return (try MNumber.factorial(n) / (try MNumber.factorial(n - k))).rounded()
        }
        func bits(_ name: String, _ f: @escaping (Int64, Int64) -> Int64) {
            lib.fn(name, 2) { a, _ in (a[0].isNull || a[1].isNull) ? .null : .number(Double(f(Int64(try a.int(0)), Int64(try a.int(1))))) }
        }
        bits("Number.BitwiseAnd", &); bits("Number.BitwiseOr", |); bits("Number.BitwiseXor", ^)
        bits("Number.BitwiseShiftLeft") { $0 << $1 }
        bits("Number.BitwiseShiftRight") { $0 >> $1 }
        lib.fn("Number.BitwiseNot", 1) { a, _ in a[0].isNull ? .null : .number(Double(~Int64(try a.int(0)))) }

        lib.fn("Number.Round", 1...3) { a, _ in
            a[0].isNull ? .null : .number(MNumber.round(try a.number(0), digits: try a.optInt(1) ?? 0, mode: try a.optInt(2) ?? 4))
        }
        func directed(_ name: String, _ rule: FloatingPointRoundingRule) {
            lib.fn(name, 1...2) { a, _ in a[0].isNull ? .null : .number(MNumber.directed(try a.number(0), digits: try a.optInt(1) ?? 0, rule)) }
        }
        directed("Number.RoundUp", .up)
        directed("Number.RoundDown", .down)
        directed("Number.RoundTowardZero", .towardZero)
        directed("Number.RoundAwayFromZero", .awayFromZero)

        lib.fn("Number.IsNaN", 1) { a, _ in .logical(try a.number(0).isNaN) }
        func parity(_ name: String, even: Bool) {
            lib.fn(name, 1) { a, _ in
                let d = try a.number(0)
                guard d == d.rounded() else { throw MError("\(name) needs a whole number.", detail: a[0]) }
                return .logical((d.truncatingRemainder(dividingBy: 2) == 0) == even)
            }
        }
        parity("Number.IsEven", even: true)
        parity("Number.IsOdd", even: false)
        lib.fn("Number.Random", 0) { _, _ in .number(Double.random(in: 0..<1)) }
        lib.fn("Number.RandomBetween", 2) { a, _ in
            let lo = try a.number(0), hi = try a.number(1)
            return .number(lo <= hi ? Double.random(in: lo...hi) : Double.random(in: hi...lo))
        }

        // MARK: Conversion
        lib.fn("Number.From", 1...2) { a, ctx in try MConvert.toNumber(a[0], culture: try a.optText(1) ?? ctx.culture) }
        lib.fn("Number.FromText", 1...2) { a, ctx in
            if a[0].isNull { return .null }
            _ = try a.text(0)
            return try MConvert.toNumber(a[0], culture: try a.optText(1) ?? ctx.culture)
        }
        lib.fn("Number.ToText", 1...3) { a, ctx in
            if a[0].isNull { return .null }
            return .text(MConvert.formatNumber(try a.number(0), format: try a.optText(1), culture: try a.optText(2) ?? ctx.culture))
        }
        func whole(_ name: String, _ range: ClosedRange<Double>) {
            lib.fn(name, 1...3) { a, ctx in
                guard case .number(let d) = try MConvert.toNumber(a[0], culture: try a.optText(1) ?? ctx.culture) else { return .null }
                let r = MNumber.round(d, mode: try a.optInt(2) ?? 4)
                guard r.isFinite, range.contains(r) else {
                    throw MError("The number is out of range of a \(name.dropLast(5)) value.", detail: a[0])
                }
                return .number(r)
            }
        }
        whole("Int64.From", -9.223372036854776e18...9.223372036854776e18)
        whole("Int32.From", -2147483648...2147483647)
        whole("Int16.From", -32768...32767)
        whole("Int8.From", -128...127)
        whole("Byte.From", 0...255)
        for name in ["Double.From", "Decimal.From", "Single.From", "Percentage.From"] {
            lib.fn(name, 1...2) { a, ctx in try MConvert.toNumber(a[0], culture: try a.optText(1) ?? ctx.culture) }
        }
        lib.fn("Currency.From", 1...3) { a, ctx in
            guard case .number(let d) = try MConvert.toNumber(a[0], culture: try a.optText(1) ?? ctx.culture) else { return .null }
            return .number(MNumber.round(d, digits: 4, mode: try a.optInt(2) ?? 4))
        }
    }
}
