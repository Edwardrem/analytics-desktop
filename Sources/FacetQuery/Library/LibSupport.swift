import Foundation
import FacetCore

/// Small helpers shared by the library areas.
enum MLib {
    /// How many leading items a `countOrCondition` argument selects: a number, or a predicate applied while it holds.
    /// A missing argument selects `defaultCount`.
    static func leadingCount(_ arg: MValue, _ items: [MValue], _ ctx: MInterpreter, defaultCount: Int = 1) throws -> Int {
        switch arg {
        case .null: return min(defaultCount, items.count)
        case .number(let d):
            guard d >= 0, d == d.rounded() else { throw MError("The count must be a non-negative whole number.", detail: arg) }
            return d >= Double(items.count) ? items.count : Int(d)
        case .function(let f):
            var n = 0
            for item in items {
                guard case .logical(true) = try ctx.call(f, [try item.forced()]) else { break }
                n += 1
            }
            return n
        default: throw MError.typeMismatch(expected: "number", got: arg)
        }
    }
    /// Like `leadingCount` but counted from the end.
    static func trailingCount(_ arg: MValue, _ items: [MValue], _ ctx: MInterpreter, defaultCount: Int = 1) throws -> Int {
        try leadingCount(arg, items.reversed(), ctx, defaultCount: defaultCount)
    }
    /// True when a comparer argument asks for case-insensitive comparison.
    static func ignoresCase(_ comparer: MValue) -> Bool {
        if case .function(let f) = comparer { return MCriteria.builtinComparerIgnoresCase(f) ?? false }
        return false
    }
    /// A non-negative whole-number argument.
    static func index(_ a: MArgs, _ i: Int) throws -> Int {
        let n = try a.int(i)
        guard n >= 0 else { throw MError("\(a.functionName): the argument is out of range.", detail: a[i]) }
        return n
    }
    /// Evaluate a predicate on a value; null counts as false, anything else non-logical is an error.
    static func test(_ f: MFunction, _ v: MValue, _ ctx: MInterpreter) throws -> Bool {
        switch try ctx.call(f, [v]) {
        case .logical(let b): return b
        case .null: return false
        case let other: throw MError.typeMismatch(expected: "logical", got: other)
        }
    }
    /// The numbers of a list, ignoring nulls; any other value is a type error.
    static func numbers(_ items: [MValue]) throws -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(items.count)
        for v in items {
            switch try v.forced() {
            case .null: continue
            case .number(let d): out.append(d)
            case let other: throw MError.typeMismatch(expected: "number", got: other)
            }
        }
        return out
    }
    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let m = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2
    }
    /// Sample standard deviation (n − 1); nil for fewer than two values.
    static func standardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count > 1 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        return (xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count - 1)).squareRoot()
    }
    /// A column/field name list argument: text or a list of text.
    static func names(_ a: MArgs, _ i: Int) throws -> [String] { try a.textList(i) }
    /// Make names unique the way Power Query does when promoting headers: `a`, `a_1`, `a_2`.
    static func uniqued(_ names: [String]) -> [String] {
        var used = Set<String>(), out: [String] = []
        for n in names {
            var candidate = n, k = 1
            while used.contains(candidate) { candidate = "\(n)_\(k)"; k += 1 }
            used.insert(candidate); out.append(candidate)
        }
        return out
    }
    /// The option record of a function (missing → empty).
    static func options(_ a: MArgs, _ i: Int) throws -> MRecord { try a.optRecord(i) ?? .empty }
}

extension Array {
    /// Stable sort with a throwing comparator returning <0, 0, >0.
    func stableSorted(_ compare: (Element, Element) throws -> Int) throws -> [Element] {
        var failure: Error?
        let sorted = enumerated().sorted { x, y in
            if failure != nil { return false }
            do {
                let c = try compare(x.element, y.element)
                return c == 0 ? x.offset < y.offset : c < 0
            } catch { failure = error; return false }
        }
        if let failure { throw failure }
        return sorted.map(\.element)
    }
}
