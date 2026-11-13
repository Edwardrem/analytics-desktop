import Foundation
import FacetCore

/// An error raised while parsing or evaluating DAX. `range` is a UTF-16 offset range into the source text.
public struct DAXError: LocalizedError, Sendable {
    public var message: String
    public var range: Range<Int>?
    public init(_ message: String, range: Range<Int>? = nil) { self.message = message; self.range = range }
    public var errorDescription: String? { message }
}

/// An error attached to one model object, returned by `DAXEngine.refreshCalculatedObjects()`.
public struct DAXObjectError: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case calculatedTable, calculatedColumn, grouping, measure, function, role, parameter, calculationGroup, autoDateTime
    }
    public var kind: Kind
    /// "Table", "Table[Column]" or the object name.
    public var object: String
    public var message: String
    public init(kind: Kind, object: String, message: String) { self.kind = kind; self.object = object; self.message = message }
}

/// What an expression is, for `DAXEngine.diagnostics(for:kind:homeTable:)`.
public enum DAXExpressionKind: String, Sendable, CaseIterable {
    case measure, calculatedColumn, calculatedTable, query, visualCalculation, securityFilter, function, formatString
}

/// One problem found in an expression. `range` is a UTF-16 offset range into the source text.
public struct DAXDiagnostic: Sendable, Hashable {
    public enum Severity: String, Sendable { case error, warning }
    public var range: Range<Int>
    public var message: String
    public var severity: Severity
    public init(range: Range<Int>, message: String, severity: Severity = .error) {
        self.range = range; self.message = message; self.severity = severity
    }
    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// Objects an expression refers to.
public struct DAXReferences: Sendable, Hashable {
    public struct Column: Sendable, Hashable {
        public var table: String
        public var column: String
        public init(table: String, column: String) { self.table = table; self.column = column }
    }
    /// Measure names, in order of first use.
    public var measures: [String] = []
    public var columns: [Column] = []
    public var tables: [String] = []
    /// Upper-cased function names (built-in and user-defined).
    public var functions: [String] = []
    public init() {}
}

/// Scalar semantics of DAX operators: blank propagation, loose comparison, coercion.
enum DAXOps {
    /// Numeric coercion: nil for blank; throws for text that is not a number.
    static func num(_ v: Value) throws -> Double? {
        switch v {
        case .null: return nil
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .date(let d): return Value.serial(from: d)
        case .string(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            if let d = DataTable.parseNumber(s) { return d }
            if let d = DateParsing.parse(s) { return Value.serial(from: d) }
            throw DAXError("Cannot convert value '\(s)' of type Text to type Number.")
        }
    }
    static func number(_ v: Value) throws -> Double { try num(v) ?? 0 }
    static func isIntLike(_ v: Value) -> Bool {
        switch v { case .int, .bool: return true; default: return false }
    }
    static func intOf(_ v: Value) -> Int64 {
        switch v { case .int(let i): return i; case .bool(let b): return b ? 1 : 0; default: return 0 }
    }
    static func isDate(_ v: Value) -> Bool { if case .date = v { return true }; return false }

    static func add(_ a: Value, _ b: Value) throws -> Value {
        if a.isNull && b.isNull { return .null }
        if isIntLike(a) || a.isNull, isIntLike(b) || b.isNull {
            let (r, o) = intOf(a).addingReportingOverflow(intOf(b))
            if !o { return .int(r) }
        }
        let r = try number(a) + number(b)
        if isDate(a) != isDate(b) { return .date(Value.date(fromSerial: r)) }
        return .double(r)
    }
    static func sub(_ a: Value, _ b: Value) throws -> Value {
        if a.isNull && b.isNull { return .null }
        if isIntLike(a) || a.isNull, isIntLike(b) || b.isNull {
            let (r, o) = intOf(a).subtractingReportingOverflow(intOf(b))
            if !o { return .int(r) }
        }
        let r = try number(a) - number(b)
        if isDate(a), !isDate(b) { return .date(Value.date(fromSerial: r)) }
        return .double(r)
    }
    static func mul(_ a: Value, _ b: Value) throws -> Value {
        if a.isNull || b.isNull { return .null }
        if isIntLike(a), isIntLike(b) {
            let (r, o) = intOf(a).multipliedReportingOverflow(by: intOf(b))
            if !o { return .int(r) }
        }
        return .double(try number(a) * number(b))
    }
    static func div(_ a: Value, _ b: Value) throws -> Value {
        if a.isNull { return .null }
        return .double(try number(a) / number(b))
    }
    static func pow(_ a: Value, _ b: Value) throws -> Value {
        if a.isNull && b.isNull { return .null }
        let r = Foundation.pow(try number(a), try number(b))
        if isIntLike(a), isIntLike(b), intOf(b) >= 0, abs(r) < 9e15 { return .int(Int64(r)) }
        return .double(r)
    }
    static func negate(_ a: Value) throws -> Value {
        switch a {
        case .null: return .null
        case .int(let i): return .int(-i)
        default: return .double(-(try number(a)))
        }
    }
    static func text(_ v: Value) -> String { v.asString }

    /// Loose DAX comparison (`=`, `<`, …): blank equals 0, "" and FALSE; text compares case-insensitively.
    static func compare(_ a: Value, _ b: Value) -> Int {
        switch (a, b) {
        case (.null, .null): return 0
        case (.string(let x), .string(let y)): return cmpText(x, y)
        case (.null, .string(let y)): return y.isEmpty ? 0 : -1
        case (.string(let x), .null): return x.isEmpty ? 0 : 1
        case (.string(let x), _): return cmpText(x, b.asString)
        case (_, .string(let y)): return cmpText(a.asString, y)
        default:
            let x = a.asDouble ?? 0, y = b.asDouble ?? 0
            return x < y ? -1 : (x > y ? 1 : 0)
        }
    }
    static func cmpText(_ x: String, _ y: String) -> Int {
        switch x.compare(y, options: [.caseInsensitive]) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }
    static func equals(_ a: Value, _ b: Value) -> Bool { compare(a, b) == 0 }
    /// `==`: like `=` but blank only equals blank.
    static func strictEquals(_ a: Value, _ b: Value) -> Bool {
        if a.isNull || b.isNull { return a.isNull && b.isNull }
        return compare(a, b) == 0
    }
    static func truthy(_ v: Value) throws -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .date: return true
        case .string(let s):
            switch s.lowercased() {
            case "true": return true
            case "false", "": return false
            default: throw DAXError("Cannot convert value '\(s)' of type Text to type True/False.")
            }
        }
    }
    /// Ordering used by ORDER BY, TOPN, RANKX and window functions: blanks first, then by value.
    static func sortLess(_ a: Value, _ b: Value) -> Bool { a < b }
    static func sortCompare(_ a: Value, _ b: Value) -> Int { a < b ? -1 : (b < a ? 1 : 0) }

    /// Normalises a double result: whole numbers stay doubles (type is decided by the caller).
    static func value(_ d: Double) -> Value { .double(d) }

    /// A DAX literal for a value, used when generating queries.
    static func literal(_ v: Value) -> String {
        switch v {
        case .null: return "BLANK()"
        case .bool(let b): return b ? "TRUE()" : "FALSE()"
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .date(let d):
            let c = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            if (c.hour ?? 0) == 0, (c.minute ?? 0) == 0, (c.second ?? 0) == 0 {
                return "DATE(\(c.year ?? 1900), \(c.month ?? 1), \(c.day ?? 1))"
            }
            return "(DATE(\(c.year ?? 1900), \(c.month ?? 1), \(c.day ?? 1)) + TIME(\(c.hour ?? 0), \(c.minute ?? 0), \(c.second ?? 0)))"
        }
    }
}

/// Signature of a context-free scalar function: evaluated arguments in, value out.
/// Omitted optional arguments arrive as `.null` only when explicitly skipped; check `args.count`.
typealias PureFn = (_ args: [Value]) throws -> Value

extension String {
    /// Upper-cased ASCII-fast key used for case-insensitive name lookup.
    var daxKey: String { self.lowercased() }
}
