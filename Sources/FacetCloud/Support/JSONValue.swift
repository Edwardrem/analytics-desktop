import Foundation

/// A JSON value that preserves object key order and the integer/decimal distinction.
///
/// Used wherever FacetCloud handles free-form JSON: tool schemas and tool inputs for the
/// assistant, Power BI `executeQueries` rows (where key order is the column order), and
/// content blocks that must be echoed back to a service unchanged.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Key/value pairs in document order.
    case object([JSONMember])

    // MARK: Convenience construction

    /// Builds an object from key/value pairs, keeping the given order.
    public static func dict(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(pairs.map { JSONMember(key: $0.key, value: $0.value) })
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, index >= 0, index < a.count else { return nil }
        return a[index]
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded() && abs(d) < 9e15: return Int64(d)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var members: [JSONMember]? { if case .object(let m) = self { return m }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Returns a copy of an object with `key` set (replacing an existing member in place, else appending).
    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        if let i = members.firstIndex(where: { $0.key == key }) { members[i].value = value }
        else { members.append(JSONMember(key: key, value: value)) }
        return .object(members)
    }

    // MARK: Parsing and serialisation

    /// Strictly parses JSON text. Throws `JSONParseError` on any malformed input or trailing garbage.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }
    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    /// Compact JSON text. Object members are written in their stored order, so output is deterministic.
    public func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }
    public func serializedData() -> Data { Data(serialized().utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite { out += d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : "\(d)" }
            else { out += "null" }
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; v.write(to: &out) }
            out += "]"
        case .object(let m):
            out += "{"
            for (i, kv) in m.enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(kv.key, to: &out)
                out += ":"
                kv.value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }

    // MARK: Foundation bridging

    /// Converts to Foundation objects (`NSNull`, `Bool`, `Int64`, `Double`, `String`, `[Any]`, `[String: Any]`).
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let m):
            var d: [String: Any] = [:]
            for kv in m { d[kv.key] = kv.value.foundationObject }
            return d
        }
    }

    /// Encodes any `Encodable` value into a `JSONValue`.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try parse(JSONEncoder().encode(value))
    }
    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: serializedData())
    }
}

/// One key/value pair of a JSON object.
public struct JSONMember: Sendable, Equatable {
    public var key: String
    public var value: JSONValue
    public init(key: String, value: JSONValue) { self.key = key; self.value = value }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(elements.map { JSONMember(key: $0.0, value: $0.1) })
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        // Decoding through Codable loses object key order (Foundation limitation); use `parse` when order matters.
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else {
            let o = try c.decode([String: JSONValue].self)
            self = .object(o.keys.sorted().map { JSONMember(key: $0, value: o[$0] ?? .null) })
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let m):
            var d: [String: JSONValue] = [:]
            for kv in m { d[kv.key] = kv.value }
            try c.encode(d)
        }
    }
}

/// A JSON syntax error with the byte offset at which it was detected.
public struct JSONParseError: LocalizedError, Equatable {
    public let message: String
    public let offset: Int
    public var errorDescription: String? { "Invalid JSON at byte \(offset): \(message)" }
}

/// Strict recursive-descent JSON parser (RFC 8259) that keeps key order.
private struct JSONParser {
    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSONValue {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        skipWhitespace()
        let v = try parseValue()
        skipWhitespace()
        guard i == bytes.count else { throw fail("unexpected trailing characters") }
        return v
    }

    private func fail(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    private mutating func skipWhitespace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard i < bytes.count else { throw fail("unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ literal: String) throws {
        let l = Array(literal.utf8)
        guard i + l.count <= bytes.count, Array(bytes[i..<i + l.count]) == l else { throw fail("unexpected token") }
        i += l.count
    }

    private mutating func parseObject() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 512 else { throw fail("nesting too deep") }
        i += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            i += 1
            skipWhitespace()
            members.append(JSONMember(key: key, value: try parseValue()))
            skipWhitespace()
            guard i < bytes.count else { throw fail("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw fail("expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 512 else { throw fail("nesting too deep") }
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw fail("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw fail("expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw fail("unterminated string") }
            let b = bytes[i]
            if b == UInt8(ascii: "\"") { i += 1; break }
            if b < 0x20 { throw fail("control character in string") }
            if b != UInt8(ascii: "\\") { out.append(b); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw fail("unterminated escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try parseHex4()
                if (0xD800...0xDBFF).contains(scalar) {
                    guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                        throw fail("unpaired surrogate")
                    }
                    i += 2
                    let low = try parseHex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw fail("invalid surrogate pair") }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    throw fail("unpaired surrogate")
                }
                guard let u = Unicode.Scalar(scalar) else { throw fail("invalid unicode escape") }
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default: throw fail("invalid escape")
            }
        }
        guard let s = String(bytes: out, encoding: .utf8) else { throw fail("invalid UTF-8 in string") }
        return s
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii), let v = UInt32(s, radix: 16) else {
            throw fail("invalid unicode escape")
        }
        i += 4
        return v
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = i
        var isInteger = true
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 else { throw fail("unexpected character") }
        if bytes[i] == 0x30 { i += 1 } else { while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 } }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            isInteger = false
            i += 1
            guard i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 else { throw fail("invalid number") }
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            isInteger = false
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 else { throw fail("invalid number") }
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if isInteger, let v = Int64(text) { return .int(v) }
        guard let d = Double(text) else { throw fail("invalid number") }
        return .double(d)
    }
}
