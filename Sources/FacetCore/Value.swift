import Foundation

/// Logical data types of a model column.
public enum DataType: String, Codable, CaseIterable, Sendable {
    case text, integer, decimal, currency, boolean, date, dateTime, time, duration, binary, any

    public var isNumeric: Bool { self == .integer || self == .decimal || self == .currency || self == .duration }
    public var isTemporal: Bool { self == .date || self == .dateTime || self == .time }
    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .integer: return "Whole number"
        case .decimal: return "Decimal number"
        case .currency: return "Fixed decimal number"
        case .boolean: return "True/False"
        case .date: return "Date"
        case .dateTime: return "Date/Time"
        case .time: return "Time"
        case .duration: return "Duration"
        case .binary: return "Binary"
        case .any: return "Any"
        }
    }
}

/// A single scalar cell value. Used everywhere: storage, DAX, Power Query, visuals.
/// `int` and `double` compare and hash numerically equal (1 == 1.0) so joins behave.
public enum Value: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isNumber: Bool {
        switch self { case .int, .double: return true; default: return false }
    }

    /// Numeric coercion (DAX-like): bools become 0/1, dates become OLE serial days, numeric strings parse.
    public var asDouble: Double? {
        switch self {
        case .null: return nil
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .date(let d): return Value.serial(from: d)
        }
    }
    public var asInt: Int64? {
        switch self {
        case .int(let i): return i
        default:
            guard let d = asDouble, d.isFinite else { return nil }
            return Int64(d.rounded(.towardZero))
        }
    }
    public var asBool: Bool? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s):
            switch s.lowercased() { case "true", "yes", "1": return true; case "false", "no", "0": return false; default: return nil }
        case .date: return true
        }
    }
    public var asDate: Date? {
        switch self {
        case .date(let d): return d
        case .int, .double: return asDouble.map(Value.date(fromSerial:))
        case .string(let s): return DateParsing.parse(s)
        default: return nil
        }
    }
    /// Plain, unformatted text representation (empty string for null).
    public var asString: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .string(let s): return s
        case .date(let d): return DateParsing.isoString(d)
        }
    }

    public var dataType: DataType {
        switch self {
        case .null: return .any
        case .bool: return .boolean
        case .int: return .integer
        case .double: return .decimal
        case .string: return .text
        case .date: return .dateTime
        }
    }

    // OLE automation serial dates (days since 1899-12-30), as DAX uses.
    static let oleEpoch: Date = {
        var c = DateComponents(); c.year = 1899; c.month = 12; c.day = 30
        return Calendar.utc.date(from: c)!
    }()
    public static func serial(from date: Date) -> Double { date.timeIntervalSince(oleEpoch) / 86400 }
    public static func date(fromSerial s: Double) -> Date { oleEpoch.addingTimeInterval(s * 86400) }

    /// Convert to the requested type, returning `.null` when conversion is impossible.
    public func converted(to type: DataType) -> Value {
        if isNull { return .null }
        switch type {
        case .any, .binary: return self
        case .text: return .string(asString)
        case .integer: return asInt.map(Value.int) ?? .null
        case .decimal, .currency, .duration: return asDouble.map(Value.double) ?? .null
        case .boolean: return asBool.map(Value.bool) ?? .null
        case .date:
            guard let d = asDate else { return .null }
            return .date(Calendar.utc.startOfDay(for: d))
        case .dateTime, .time: return asDate.map(Value.date) ?? .null
        }
    }
}

extension Value: Hashable {
    public static func == (a: Value, b: Value) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.date(let x), .date(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.int, .double), (.double, .int), (.double, .double): return a.asDouble == b.asDouble
        default: return false
        }
    }
    public func hash(into h: inout Hasher) {
        switch self {
        case .null: h.combine(0)
        case .bool(let b): h.combine(1); h.combine(b)
        case .int(let i): h.combine(2); h.combine(Double(i))
        case .double(let d): h.combine(2); h.combine(d)
        case .string(let s): h.combine(3); h.combine(s)
        case .date(let d): h.combine(4); h.combine(d)
        }
    }
}

extension Value: Comparable {
    private var rank: Int {
        switch self { case .null: return 0; case .bool: return 1; case .int, .double: return 2; case .date: return 3; case .string: return 4 }
    }
    /// Total order: null < bool < number < date < text. Text compares case-insensitively first.
    public static func < (a: Value, b: Value) -> Bool {
        switch (a, b) {
        case (.bool(let x), .bool(let y)): return !x && y
        case (.string(let x), .string(let y)):
            let r = x.compare(y, options: [.caseInsensitive, .numeric])
            return r == .orderedSame ? x < y : r == .orderedAscending
        case (.date(let x), .date(let y)): return x < y
        default:
            if a.rank == 2, b.rank == 2 { return (a.asDouble ?? 0) < (b.asDouble ?? 0) }
            return a.rank < b.rank
        }
    }
}

extension Value: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let o = try? c.decode([String: Double].self), let t = o["$d"] { self = .date(Date(timeIntervalSince1970: t)) }
        else { self = .null }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): if d.isFinite { try c.encode(d) } else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .date(let d): try c.encode(["$d": d.timeIntervalSince1970])
        }
    }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

public extension Calendar {
    /// All model date arithmetic is done in UTC so results don't shift with the machine's zone.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }()
}

public enum DateParsing {
    private static let formats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy",
        "M/d/yyyy", "dd-MMM-yyyy", "d MMM yyyy", "MMM d, yyyy", "MMMM d, yyyy", "dd.MM.yyyy", "yyyyMMdd", "HH:mm:ss", "HH:mm",
    ]
    private static let lock = NSLock()
    private static let formatters: [DateFormatter] = formats.map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = f
        df.isLenient = false
        return df
    }
    private static let iso: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 4, t.count <= 32, let first = t.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return nil }
        lock.lock(); defer { lock.unlock() }
        for (i, df) in formatters.enumerated() {
            if formats[i] == "yyyyMMdd" && t.count != 8 { continue }
            if let d = df.date(from: t) { return d }
        }
        return nil
    }
    public static func isoString(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        let secs = d.timeIntervalSince1970
        iso.dateFormat = secs.truncatingRemainder(dividingBy: 86400) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return iso.string(from: d)
    }
    public static func string(_ d: Date, format: String) -> String {
        lock.lock(); defer { lock.unlock() }
        iso.dateFormat = format
        return iso.string(from: d)
    }
    private static var localized: [String: DateFormatter] = [:]
    /// Formats in a culture: its month and day names and AM/PM symbols.
    public static func string(_ d: Date, format: String, locale: Locale) -> String {
        lock.lock(); defer { lock.unlock() }
        let df: DateFormatter
        if let cached = localized[locale.identifier] { df = cached } else {
            df = DateFormatter()
            df.locale = locale; df.timeZone = TimeZone(identifier: "UTC")
            localized[locale.identifier] = df
        }
        df.dateFormat = format
        return df.string(from: d)
    }
}

/// Loosely typed JSON, used for format property bags and theme files.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}
