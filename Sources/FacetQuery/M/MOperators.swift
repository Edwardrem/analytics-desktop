import Foundation
import FacetCore

/// Operator semantics for M values.
public enum MOps {
    public static func unary(_ op: MUnaryOp, _ v: MValue) throws -> MValue {
        if v.isNull { return .null }
        switch (op, v) {
        case (.plus, .number), (.plus, .duration): return v
        case (.minus, .number(let d)): return .number(-d)
        case (.minus, .duration(let d)): return .duration(-d)
        case (.not, .logical(let b)): return .logical(!b)
        default: throw MError("We cannot apply operator \(op.rawValue) to type \(v.typeName.capitalized).")
        }
    }

    public static func and(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.logical(let x), .logical(let y)): return .logical(x && y)
        case (.logical(false), .null), (.null, .logical(false)): return .logical(false)
        case (.logical(true), .null), (.null, .logical(true)), (.null, .null): return .null
        default: throw MError.typeMismatch(expected: "logical", got: a.logicalValue == nil && !a.isNull ? a : b)
        }
    }
    public static func or(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.logical(let x), .logical(let y)): return .logical(x || y)
        case (.logical(true), .null), (.null, .logical(true)): return .logical(true)
        case (.logical(false), .null), (.null, .logical(false)), (.null, .null): return .null
        default: throw MError.typeMismatch(expected: "logical", got: a.logicalValue == nil && !a.isNull ? a : b)
        }
    }

    public static func binary(_ op: MBinaryOp, _ a: MValue, _ b: MValue) throws -> MValue {
        switch op {
        case .equal: return .logical(MValue.equals(a, b))
        case .notEqual: return .logical(!MValue.equals(a, b))
        case .less, .lessEqual, .greater, .greaterEqual:
            if a.isNull || b.isNull { return .null }
            guard let c = try relational(a, b) else { return .logical(false) } // NaN comparisons
            switch op {
            case .less: return .logical(c < 0)
            case .lessEqual: return .logical(c <= 0)
            case .greater: return .logical(c > 0)
            default: return .logical(c >= 0)
            }
        case .add: return try add(a, b)
        case .subtract: return try subtract(a, b)
        case .multiply: return try multiply(a, b)
        case .divide: return try divide(a, b)
        case .concat: return try concat(a, b)
        case .and: return try and(a, b)
        case .or: return try or(a, b)
        case .coalesce: return a.isNull ? b : a
        }
    }

    private static func opError(_ op: String, _ a: MValue, _ b: MValue) -> MError {
        MError("We cannot apply operator \(op) to types \(a.typeName.capitalized) and \(b.typeName.capitalized).")
    }
    static func dayFloor(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 86400).rounded(.down) * 86400)
    }

    public static func add(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x + y)
        case (.duration(let x), .duration(let y)): return .duration(x + y)
        case (.date(let d), .duration(let s)), (.duration(let s), .date(let d)): return .date(dayFloor(d.addingTimeInterval(s)))
        case (.datetime(let d), .duration(let s)), (.duration(let s), .datetime(let d)): return .datetime(d.addingTimeInterval(s))
        case (.datetimezone(let d, let o), .duration(let s)), (.duration(let s), .datetimezone(let d, let o)):
            return .datetimezone(d.addingTimeInterval(s), offsetMinutes: o)
        case (.time(let t), .duration(let s)), (.duration(let s), .time(let t)):
            var r = (t + s).truncatingRemainder(dividingBy: 86400)
            if r < 0 { r += 86400 }
            return .time(r)
        case (.null, _), (_, .null):
            guard isArithmetic(a) || a.isNull, isArithmetic(b) || b.isNull else { throw opError("+", a, b) }
            return .null
        default: throw opError("+", a, b)
        }
    }
    private static func isArithmetic(_ v: MValue) -> Bool {
        switch v { case .number, .duration, .date, .datetime, .datetimezone, .time: return true; default: return false }
    }
    public static func subtract(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x - y)
        case (.duration(let x), .duration(let y)): return .duration(x - y)
        case (.date(let x), .date(let y)), (.datetime(let x), .datetime(let y)),
             (.date(let x), .datetime(let y)), (.datetime(let x), .date(let y)):
            return .duration(x.timeIntervalSince(y))
        case (.datetimezone(let x, _), .datetimezone(let y, _)): return .duration(x.timeIntervalSince(y))
        case (.time(let x), .time(let y)): return .duration(x - y)
        case (.date(let d), .duration(let s)): return .date(dayFloor(d.addingTimeInterval(-s)))
        case (.datetime(let d), .duration(let s)): return .datetime(d.addingTimeInterval(-s))
        case (.datetimezone(let d, let o), .duration(let s)): return .datetimezone(d.addingTimeInterval(-s), offsetMinutes: o)
        case (.time(let t), .duration(let s)):
            var r = (t - s).truncatingRemainder(dividingBy: 86400)
            if r < 0 { r += 86400 }
            return .time(r)
        case (.null, _), (_, .null):
            guard isArithmetic(a) || a.isNull, isArithmetic(b) || b.isNull else { throw opError("-", a, b) }
            return .null
        default: throw opError("-", a, b)
        }
    }
    public static func multiply(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x * y)
        case (.duration(let x), .number(let y)), (.number(let y), .duration(let x)): return .duration(x * y)
        case (.null, .number), (.number, .null), (.null, .null), (.null, .duration), (.duration, .null): return .null
        default: throw opError("*", a, b)
        }
    }
    public static func divide(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x / y)
        case (.duration(let x), .number(let y)): return .duration(x / y)
        case (.duration(let x), .duration(let y)): return .number(x / y)
        case (.null, .number), (.number, .null), (.null, .null), (.null, .duration), (.duration, .null): return .null
        default: throw opError("/", a, b)
        }
    }
    public static func concat(_ a: MValue, _ b: MValue) throws -> MValue {
        switch (a, b) {
        case (.text(let x), .text(let y)): return .text(x + y)
        case (.list(let x), .list(let y)): return .list(x + y)
        case (.record(let x), .record(let y)): return .record(x.merging(y))
        case (.table(let x), .table(let y)): return .table(try appendTables([x, y]))
        case (.date(let d), .time(let t)): return .datetime(d.addingTimeInterval(t))
        case (.binary(let x), .binary(let y)): return .binary(x + y)
        case (.null, .text), (.text, .null), (.null, .null): return .null
        default: throw opError("&", a, b)
        }
    }

    /// Append tables by column name (the union of columns; missing cells are null) — `Table.Combine`.
    public static func appendTables(_ tables: [MTable]) throws -> MTable {
        var names: [String] = [], types: [MType] = [], index: [String: Int] = [:]
        for t in tables {
            for (i, n) in t.columnNames.enumerated() {
                if let j = index[n] {
                    if types[j] != t.columnTypes[i] { types[j] = .any }
                } else { index[n] = names.count; names.append(n); types.append(t.columnTypes[i]) }
            }
        }
        var cols = [[MValue]](repeating: [], count: names.count)
        var total = 0
        for t in tables {
            let n = try t.rowCount, src = try t.columns
            for (j, name) in names.enumerated() {
                if let i = t.columnIndex(name) { cols[j].append(contentsOf: src[i]) }
                else { cols[j].append(contentsOf: [MValue](repeating: .null, count: n)) }
            }
            total += n
        }
        return MTable(names: names, types: types, columns: cols, rowCount: total)
    }

    /// Relational comparison for `<`-style operators. Returns nil for unordered (NaN). Throws on incomparable types.
    public static func relational(_ a: MValue, _ b: MValue) throws -> Int? {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            if x.isNaN || y.isNaN { return nil }
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.text(let x), .text(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        case (.logical(let x), .logical(let y)): return x == y ? 0 : (!x ? -1 : 1)
        case (.date(let x), .date(let y)), (.datetime(let x), .datetime(let y)), (.datetimezone(let x, _), .datetimezone(let y, _)),
             (.date(let x), .datetime(let y)), (.datetime(let x), .date(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.time(let x), .time(let y)), (.duration(let x), .duration(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        case (.binary(let x), .binary(let y)): return x == y ? 0 : (x.lexicographicallyPrecedes(y) ? -1 : 1)
        default:
            throw MError("We cannot apply operator < to types \(a.typeName.capitalized) and \(b.typeName.capitalized).")
        }
    }
}

public extension MValue {
    /// M value equality (`=`): deep for lists, records (field order ignored) and tables; null = null is true.
    static func equals(_ a: MValue, _ b: MValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.logical(let x), .logical(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.date(let x), .date(let y)), (.datetime(let x), .datetime(let y)): return x == y
        case (.datetimezone(let x, _), .datetimezone(let y, _)): return x == y
        case (.time(let x), .time(let y)), (.duration(let x), .duration(let y)): return x == y
        case (.binary(let x), .binary(let y)): return x == y
        case (.type(let x), .type(let y)): return x == y
        case (.function(let x), .function(let y)): return x === y
        case (.list(let x), .list(let y)):
            guard x.count == y.count else { return false }
            for i in 0..<x.count where !equals(x[i].forcedCell(), y[i].forcedCell()) { return false }
            return true
        case (.record(let x), .record(let y)):
            guard x.count == y.count else { return false }
            for (i, n) in x.names.enumerated() {
                guard let j = y.fields.index[n], equals(x.cell(at: i), y.cell(at: j)) else { return false }
            }
            return true
        case (.table(let x), .table(let y)):
            guard x.columnNames == y.columnNames, let cx = try? x.columns, let cy = try? y.columns,
                  (try? x.rowCount) == (try? y.rowCount) else { return false }
            for (c1, c2) in zip(cx, cy) {
                for i in 0..<c1.count where !equals(c1[i].forcedCell(), c2[i].forcedCell()) { return false }
            }
            return true
        case (.error, .error): return false
        default: return false
        }
    }

    private var orderRank: Int {
        switch self {
        case .null: return 0
        case .logical: return 1
        case .number: return 2
        case .time: return 3
        case .date, .datetime, .datetimezone: return 4
        case .duration: return 5
        case .text: return 6
        case .binary: return 7
        case .list: return 8
        case .record: return 9
        case .table: return 10
        case .function: return 11
        case .type: return 12
        case .error, .lazy: return 13
        }
    }
    /// A total order over all values, used for sorting: null first, then by kind, then by value.
    /// Text compares ordinally (case-sensitive), as M's default comparer does.
    static func order(_ a: MValue, _ b: MValue) -> Int {
        if let c = try? MOps.relational(a, b) { return c }
        if case .number(let x) = a, case .number(let y) = b { // NaN handling: NaN sorts first among numbers
            return x.isNaN ? (y.isNaN ? 0 : -1) : 1
        }
        if case .list(let x) = a, case .list(let y) = b {
            for i in 0..<min(x.count, y.count) {
                let c = order(x[i].forcedCell(), y[i].forcedCell())
                if c != 0 { return c }
            }
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        }
        let ra = a.orderRank, rb = b.orderRank
        return ra == rb ? 0 : (ra < rb ? -1 : 1)
    }
}

/// A hashable wrapper so M values can be dictionary keys (distinct, group, join).
/// Hashing/equality follow `MValue.equals`; with `ignoreCase`, text compares case-insensitively.
public struct MKey: Hashable {
    public let value: MValue
    public let ignoreCase: Bool
    public init(_ value: MValue, ignoreCase: Bool = false) {
        self.ignoreCase = ignoreCase
        if ignoreCase {
            self.value = MKey.fold(value)
        } else { self.value = value }
    }
    private static func fold(_ v: MValue) -> MValue {
        switch v {
        case .text(let s): return .text(s.lowercased())
        case .list(let l): return .list(l.map { fold($0.forcedCell()) })
        default: return v
        }
    }
    public static func == (a: MKey, b: MKey) -> Bool { MValue.equals(a.value, b.value) }
    public func hash(into h: inout Hasher) { MKey.hash(value, &h) }
    private static func hash(_ v: MValue, _ h: inout Hasher) {
        switch v {
        case .null: h.combine(0)
        case .logical(let b): h.combine(b)
        case .number(let d): h.combine(d)
        case .text(let s): h.combine(s)
        case .date(let d), .datetime(let d), .datetimezone(let d, _): h.combine(d)
        case .time(let t): h.combine(1); h.combine(t)
        case .duration(let t): h.combine(2); h.combine(t)
        case .binary(let d): h.combine(d)
        case .list(let l): for x in l { hash(x.forcedCell(), &h) }
        case .record(let r): h.combine(r.count) // field order is ignored by equality, so hash only the size
        case .table(let t): h.combine(t.columnNames)
        default: h.combine(99)
        }
    }
}
