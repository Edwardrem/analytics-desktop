import Foundation
import FacetCore

/// A non-fatal problem found while importing or exporting a foreign format.
public struct ImportWarning: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case info, warning, error }
    public var severity: Severity
    public var message: String
    /// File or object the warning refers to, when known.
    public var location: String?

    public init(_ message: String, severity: Severity = .warning, location: String? = nil) {
        self.message = message; self.severity = severity; self.location = location
    }
    public var description: String {
        location.map { "[\(severity.rawValue)] \($0): \(message)" } ?? "[\(severity.rawValue)] \(message)"
    }
}

/// Errors shared by the interop readers and writers.
public enum InteropError: LocalizedError {
    case invalidFormat(String)
    case missingFile(String)
    case unsupported(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let m): return m
        case .missingFile(let m): return "Missing file: \(m)"
        case .unsupported(let m): return m
        case .io(let m): return m
        }
    }
}

// MARK: - Text decoding

enum TextDecoding {
    /// Decodes text that may be UTF-8 or UTF-16 (with or without a byte-order mark), as found in .pbix streams.
    static func string(from data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return String(data: data.dropFirst(3), encoding: .utf8) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if b.count >= 2, b[0] != 0, b[1] == 0, data.count % 2 == 0, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if b.count >= 2, b[0] == 0, b[1] != 0, data.count % 2 == 0, let s = String(data: data, encoding: .utf16BigEndian) { return s }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
    }
}

// MARK: - JSONValue helpers

public extension JSONValue {
    /// Parses JSON text (UTF-8 or UTF-16) into a `JSONValue`.
    static func parse(_ data: Data) throws -> JSONValue {
        guard let text = TextDecoding.string(from: data) else { throw InteropError.invalidFormat("The file is not valid text.") }
        return try parse(text)
    }
    static func parse(_ text: String) throws -> JSONValue {
        do {
            let any = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return JSONValue(any: any)
        } catch {
            throw InteropError.invalidFormat("Invalid JSON: \(error.localizedDescription)")
        }
    }

    /// Converts a Foundation JSON object graph.
    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// The Foundation object graph for `JSONSerialization`.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let d):
            if !d.isFinite { return NSNull() }
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return NSNumber(value: Int64(d)) }
            return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    /// Serialises with sorted keys so output is deterministic and diffs cleanly.
    func serialized(pretty: Bool = true) -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: any, options: opts)) ?? Data("null".utf8)
    }
    /// Compact single-line JSON text.
    var compactString: String { String(decoding: serialized(pretty: false), as: UTF8.self) }

    /// Encodes any `Encodable` into a `JSONValue`.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONValue.parse(String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }
    /// Decodes a `Decodable` from this value.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: serialized(pretty: false))
    }

    subscript(index: Int) -> JSONValue? { arrayValue?[safe: index] }
    var intValue: Int? { doubleValue.flatMap { $0.isFinite ? Int($0) : nil } }
    /// Follows a path of object keys.
    func at(_ path: String...) -> JSONValue? {
        var cur: JSONValue? = self
        for p in path { cur = cur?[p] }
        return cur
    }
    var isNull: Bool { if case .null = self { return true }; return false }
}

// Internal shorthand for building JSON.
@inline(__always) func jo(_ d: [String: JSONValue]) -> JSONValue { .object(d) }
@inline(__always) func ja(_ a: [JSONValue]) -> JSONValue { .array(a) }
@inline(__always) func js(_ s: String) -> JSONValue { .string(s) }
@inline(__always) func jn(_ d: Double) -> JSONValue { .number(d) }
@inline(__always) func jn(_ i: Int) -> JSONValue { .number(Double(i)) }
@inline(__always) func jb(_ b: Bool) -> JSONValue { .bool(b) }

extension UUID {
    /// Lower-case form used in TMDL lineage tags and PBIR object names.
    var lower: String { uuidString.lowercased() }
}

/// JSON-encodes with a stable key order (used for equality checks and annotations).
func canonicalJSON<T: Encodable>(_ value: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

extension FileManager {
    func writeCreatingDirectories(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
