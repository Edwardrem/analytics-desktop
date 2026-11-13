import Foundation

/// Interprets M "comparisonCriteria" and "equationCriteria" arguments (used by sort, distinct, group, join…).
public enum MCriteria {
    /// True/false when `f` is one of the built-in comparers; nil for other functions.
    public static func builtinComparerIgnoresCase(_ f: MFunction) -> Bool? {
        switch f.name {
        case "Comparer.OrdinalIgnoreCase": return true
        case "Comparer.Ordinal": return false
        default: return nil
        }
    }

    /// Case-aware default ordering.
    public static func order(_ a: MValue, _ b: MValue, ignoreCase: Bool) -> Int {
        if ignoreCase, case .text(let x) = a, case .text(let y) = b {
            let lx = x.lowercased(), ly = y.lowercased()
            return lx == ly ? 0 : (lx < ly ? -1 : 1)
        }
        return MValue.order(a, b)
    }

    /// Build an ordering from comparison criteria:
    /// null (natural order) · `Order.Ascending/Descending` · key selector `each …` · comparer `(x, y) => number`
    /// · text (a record field / column name) · `{key, order}` · a list of any of these (lexicographic).
    public static func comparer(_ criteria: MValue, _ ctx: MInterpreter) throws -> (MValue, MValue) throws -> Int {
        switch criteria {
        case .null: return { MValue.order($0, $1) }
        case .number(let o): return o == 1 ? { MValue.order($1, $0) } : { MValue.order($0, $1) }
        case .function(let f):
            if let ic = builtinComparerIgnoresCase(f) { return { order($0, $1, ignoreCase: ic) } }
            if f.parameters.count == 2 || (f.minArgs == 2 && f.closure == nil) {
                return { a, b in
                    guard case .number(let d) = try ctx.call(f, [a, b]) else { throw MError("A comparer function must return a number.") }
                    return d < 0 ? -1 : (d > 0 ? 1 : 0)
                }
            }
            return { a, b in MValue.order(try ctx.call(f, [a]), try ctx.call(f, [b])) }
        case .text(let field):
            return { a, b in MValue.order(try fieldOf(a, field), try fieldOf(b, field)) }
        case .list(let items):
            // {key, Order} pair?
            if items.count == 2, case .number(let o) = items[1], !(items[0].numberValue != nil) {
                let inner = try comparer(items[0], ctx)
                return o == 1 ? { try inner($1, $0) } : inner
            }
            if items.count == 2, case .function(let cf) = items[1], let ic = builtinComparerIgnoresCase(cf) {
                let key = try keySelector(items[0], ctx)
                return { a, b in order(try key(a), try key(b), ignoreCase: ic) }
            }
            let parts = try items.map { try comparer($0, ctx) }
            return { a, b in
                for p in parts { let c = try p(a, b); if c != 0 { return c } }
                return 0
            }
        default: throw MError("Unsupported comparison criteria of type \(criteria.typeName).")
        }
    }

    private static func fieldOf(_ v: MValue, _ field: String) throws -> MValue {
        guard case .record(let r) = v else { throw MError.typeMismatch(expected: "record", got: v) }
        return try r.require(field)
    }

    private static func keySelector(_ criteria: MValue, _ ctx: MInterpreter) throws -> (MValue) throws -> MValue {
        switch criteria {
        case .null: return { $0 }
        case .function(let f): return { try ctx.call(f, [$0]) }
        case .text(let field): return { try fieldOf($0, field) }
        case .list(let items):
            let parts = try items.map { try keySelector($0, ctx) }
            return { v in .list(try parts.map { try $0(v) }) }
        default: throw MError("Unsupported key selector of type \(criteria.typeName).")
        }
    }

    /// Build a hashable-key function from equation criteria:
    /// null · key selector `each …` · `Comparer.Ordinal` / `Comparer.OrdinalIgnoreCase`
    /// · text / list of text (record field names) · `{keySelector, comparer}`.
    /// Arbitrary two-argument comparer functions are not supported (they cannot be hashed).
    public static func keyer(_ criteria: MValue, _ ctx: MInterpreter) throws -> (MValue) throws -> MKey {
        switch criteria {
        case .null: return { MKey($0) }
        case .function(let f):
            if let ic = builtinComparerIgnoresCase(f) { return { MKey($0, ignoreCase: ic) } }
            if f.parameters.count >= 2 {
                throw MError("Custom two-argument equality comparers are not supported. Use a key selector (each …) or Comparer.OrdinalIgnoreCase.")
            }
            return { MKey(try ctx.call(f, [$0])) }
        case .text, .list:
            if case .list(let items) = criteria, items.count == 2, case .function(let cf) = items[1],
               let ic = builtinComparerIgnoresCase(cf) {
                let key = try keySelector(items[0], ctx)
                return { MKey(try key($0), ignoreCase: ic) }
            }
            let key = try keySelector(criteria, ctx)
            return { MKey(try key($0)) }
        default: throw MError("Unsupported equation criteria of type \(criteria.typeName).")
        }
    }
}
