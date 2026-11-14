import Foundation
import FacetCore

/// An error raised by M evaluation. Mirrors M's error record (`Reason`, `Message`, `Detail`).
public struct MError: Error, LocalizedError, CustomStringConvertible {
    public var reason: String
    public var message: String
    public var detail: MValue?

    public init(_ message: String, reason: String = "Expression.Error", detail: MValue? = nil) {
        self.reason = reason; self.message = message; self.detail = detail
    }
    public static func dataSource(_ message: String) -> MError { MError(message, reason: "DataSource.Error") }
    public static func dataFormat(_ message: String) -> MError { MError(message, reason: "DataFormat.Error") }
    public static func firewall(_ message: String) -> MError { MError(message, reason: "Formula.Firewall") }
    /// A source refused the credentials it was given (or needs some): `DataSource.Error` whose detail names the source,
    /// so the host app can ask for credentials and try again.
    public static func credentials(kind: String, location: String, _ message: String) -> MError {
        MError(message, reason: "DataSource.Error", detail: .record(MRecord([
            ("DataSourceKind", .text(kind)), ("DataSourcePath", .text(location)), ("CredentialsRequired", .logical(true)),
        ])))
    }
    /// The source of a `credentials(kind:location:_:)` error.
    public var credentialSource: (kind: String, location: String)? {
        guard reason == "DataSource.Error", case .record(let r)? = detail, case .logical(true)? = try? r.get("CredentialsRequired"),
              let kind = (try? r.text("DataSourceKind")) ?? nil, let location = (try? r.text("DataSourcePath")) ?? nil else { return nil }
        return (kind, location)
    }
    public static func typeMismatch(expected: String, got: MValue) -> MError {
        MError("We cannot convert a value of type \(got.typeName) to type \(expected).", detail: got.isStructured ? nil : got)
    }
    public var errorDescription: String? { "\(reason): \(message)" }
    public var description: String { "\(reason): \(message)" }

    /// The M error record `[Reason=…, Message=…, Detail=…]`.
    public var record: MRecord {
        MRecord(names: ["Reason", "Message", "Detail"], values: [.text(reason), .text(message), detail ?? .null])
    }
    /// Wrap any Swift error as an `MError`.
    public static func wrap(_ error: Error) -> MError {
        if let e = error as? MError { return e }
        return MError((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}

/// A lazily evaluated value (let bindings, record fields). Evaluated at most once; errors are cached too.
public final class MThunk: @unchecked Sendable {
    private var compute: (() throws -> MValue)?
    private var result: Result<MValue, Error>?
    private var running = false
    private let lock = NSRecursiveLock()

    public init(_ compute: @escaping () throws -> MValue) { self.compute = compute }

    public func force() throws -> MValue {
        lock.lock(); defer { lock.unlock() }
        if let r = result { return try r.get() }
        if running { throw MError("A cyclic reference was encountered during evaluation.") }
        running = true
        defer { running = false }
        guard let c = compute else { throw MError("Internal error: thunk has no computation.") }
        do {
            let v = try c().forced()
            result = .success(v); compute = nil
            return v
        } catch {
            result = .failure(error); compute = nil
            throw error
        }
    }
    public var isEvaluated: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
}

/// Any Power Query M value.
///
/// `.error` and `.lazy` are *storage* cases: they only appear inside lists, records and table cells
/// (cell-level errors, unevaluated record fields). Call `forced()` before inspecting a value taken out
/// of a container — it evaluates thunks and throws stored errors.
public enum MValue: @unchecked Sendable {
    case null
    case logical(Bool)
    case number(Double)
    case text(String)
    /// Midnight UTC of the calendar day.
    case date(Date)
    /// Wall-clock date-time, stored as if UTC (no zone).
    case datetime(Date)
    /// Absolute instant plus the zone offset in minutes.
    case datetimezone(Date, offsetMinutes: Int)
    /// Seconds since midnight.
    case time(Double)
    /// Seconds (may be negative / fractional).
    case duration(Double)
    case binary(Data)
    case list([MValue])
    case record(MRecord)
    case table(MTable)
    case function(MFunction)
    case type(MType)
    /// A cell-level error stored inside a container.
    indirect case error(MError)
    /// An unevaluated value stored inside a container.
    case lazy(MThunk)

    public static let `true` = MValue.logical(true)
    public static let `false` = MValue.logical(false)

    /// Evaluates thunks and throws stored cell errors; returns any other value unchanged.
    @inline(__always)
    public func forced() throws -> MValue {
        switch self {
        case .lazy(let t): return try t.force()
        case .error(let e): throw e
        default: return self
        }
    }
    /// Like `forced()` but converts a thrown error into a storable `.error` cell.
    public func forcedCell() -> MValue {
        switch self {
        case .lazy(let t): do { return try t.force() } catch { return .error(MError.wrap(error)) }
        default: return self
        }
    }
    /// Evaluate `body`, capturing a thrown error as a `.error` cell value.
    public static func capturing(_ body: () throws -> MValue) -> MValue {
        do { return try body().forced() } catch { return .error(MError.wrap(error)) }
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isError: Bool { if case .error = self { return true }; return false }
    public var isStructured: Bool {
        switch self { case .list, .record, .table, .function, .type, .binary: return true; default: return false }
    }
    /// The M type name of this value ("number", "text", "table", …).
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .logical: return "logical"
        case .number: return "number"
        case .text: return "text"
        case .date: return "date"
        case .datetime: return "datetime"
        case .datetimezone: return "datetimezone"
        case .time: return "time"
        case .duration: return "duration"
        case .binary: return "binary"
        case .list: return "list"
        case .record: return "record"
        case .table: return "table"
        case .function: return "function"
        case .type: return "type"
        case .error: return "error"
        case .lazy: return "any"
        }
    }

    // Convenience constructors
    public static func int(_ i: Int) -> MValue { .number(Double(i)) }
    public static func optText(_ s: String?) -> MValue { s.map(MValue.text) ?? .null }
    public static func optNumber(_ d: Double?) -> MValue { d.map(MValue.number) ?? .null }

    // Non-throwing peeks (nil when the value is of another kind)
    public var textValue: String? { if case .text(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var logicalValue: Bool? { if case .logical(let b) = self { return b }; return nil }
    public var listValue: [MValue]? { if case .list(let l) = self { return l }; return nil }
    public var recordValue: MRecord? { if case .record(let r) = self { return r }; return nil }
    public var tableValue: MTable? { if case .table(let t) = self { return t }; return nil }
    public var functionValue: MFunction? { if case .function(let f) = self { return f }; return nil }
    public var typeValue: MType? { if case .type(let t) = self { return t }; return nil }
    public var binaryValue: Data? { if case .binary(let d) = self { return d }; return nil }
}

/// Shared, immutable field-name list with an index, so row records of one table share a single header.
public final class MFieldNames: @unchecked Sendable {
    public let names: [String]
    public let index: [String: Int]
    public init(_ names: [String]) {
        self.names = names
        var ix = [String: Int](minimumCapacity: names.count)
        for (i, n) in names.enumerated() where ix[n] == nil { ix[n] = i }
        self.index = ix
    }
}

/// An M record: ordered, named, lazily evaluated fields.
public final class MRecord: @unchecked Sendable {
    public let fields: MFieldNames
    /// Raw storage; may hold `.lazy` / `.error`. Prefer `get`/`value(at:)`.
    public private(set) var values: [MValue]
    public var meta: MRecord?

    public init(fields: MFieldNames, values: [MValue]) { self.fields = fields; self.values = values }
    public convenience init(names: [String], values: [MValue]) { self.init(fields: MFieldNames(names), values: values) }
    public convenience init(_ pairs: [(String, MValue)]) { self.init(names: pairs.map(\.0), values: pairs.map(\.1)) }
    public static let empty = MRecord(names: [], values: [])

    public var names: [String] { fields.names }
    public var count: Int { values.count }
    public func has(_ name: String) -> Bool { fields.index[name] != nil }

    /// Forced value of field `i` (the forced result is cached).
    public func value(at i: Int) throws -> MValue {
        let v = values[i]
        if case .lazy(let t) = v { return try t.force() }
        if case .error(let e) = v { throw e }
        return v
    }
    /// Forced value of a field, or nil when the field does not exist.
    public func get(_ name: String) throws -> MValue? {
        guard let i = fields.index[name] else { return nil }
        return try value(at: i)
    }
    /// Forced value of a field; throws M's "field not found" error when missing.
    public func require(_ name: String) throws -> MValue {
        guard let i = fields.index[name] else {
            throw MError("The field '\(name)' of the record wasn't found.")
        }
        return try value(at: i)
    }
    /// Raw (possibly lazy / error) cell for field `i`, with thunks evaluated and failures captured as `.error`.
    public func cell(at i: Int) -> MValue { values[i].forcedCell() }
    /// All fields as cells (thunks evaluated, errors captured).
    public var cells: [MValue] { values.map { $0.forcedCell() } }
    /// All forced values; throws on the first field error.
    public func forcedValues() throws -> [MValue] { try (0..<values.count).map { try value(at: $0) } }

    // Convenience typed lookups for option records (nil when missing or null).
    public func text(_ name: String) throws -> String? { try get(name)?.textValue }
    public func number(_ name: String) throws -> Double? { try get(name)?.numberValue }
    public func logical(_ name: String) throws -> Bool? { try get(name)?.logicalValue }

    /// A new record with `name` set (replacing or appending).
    public func setting(_ name: String, _ value: MValue) -> MRecord {
        if let i = fields.index[name] {
            var v = values; v[i] = value
            return MRecord(fields: fields, values: v)
        }
        return MRecord(names: names + [name], values: values + [value])
    }
    /// A new record without the given fields.
    public func removing(_ remove: Set<String>) -> MRecord {
        var n: [String] = [], v: [MValue] = []
        for (i, name) in names.enumerated() where !remove.contains(name) { n.append(name); v.append(values[i]) }
        return MRecord(names: n, values: v)
    }
    /// Record merge (`a & b`): fields of `other` override.
    public func merging(_ other: MRecord) -> MRecord {
        var n = names, v = values
        var ix = fields.index
        for (i, name) in other.names.enumerated() {
            if let j = ix[name] { v[j] = other.values[i] } else { ix[name] = n.count; n.append(name); v.append(other.values[i]) }
        }
        return MRecord(names: n, values: v)
    }
}

/// One declared parameter of an M function.
public struct MParameter {
    public var name: String
    public var type: MType?
    public var isOptional: Bool
    public init(_ name: String, type: MType? = nil, optional: Bool = false) {
        self.name = name; self.type = type; self.isOptional = optional
    }
}

/// An M function value: either a native (Swift) implementation or an M closure.
public final class MFunction: @unchecked Sendable {
    public typealias Native = (_ args: MArgs, _ ctx: MInterpreter) throws -> MValue
    public enum Implementation {
        case native(Native)
        /// `body` evaluated in `env` extended with the parameters.
        case closure(body: MExpr, env: MEnv)
    }
    public let name: String?
    public let parameters: [MParameter]
    public let minArgs: Int
    /// nil = variadic.
    public let maxArgs: Int?
    public let returnType: MType?
    public let implementation: Implementation
    public var meta: MRecord?
    /// True for `each …` functions (single parameter `_`).
    public let isEach: Bool

    public init(name: String?, minArgs: Int, maxArgs: Int?, native: @escaping Native) {
        self.name = name; self.minArgs = minArgs; self.maxArgs = maxArgs
        self.parameters = (0..<(maxArgs ?? minArgs)).map { MParameter("arg\($0 + 1)", optional: $0 >= minArgs) }
        self.returnType = nil; self.implementation = .native(native); self.isEach = false
    }
    public init(name: String? = nil, parameters: [MParameter], returnType: MType? = nil, body: MExpr, env: MEnv, isEach: Bool = false) {
        self.name = name; self.parameters = parameters; self.returnType = returnType
        self.minArgs = parameters.filter { !$0.isOptional }.count
        self.maxArgs = parameters.count
        self.implementation = .closure(body: body, env: env); self.isEach = isEach
    }
    /// The closure's body and environment, when this is an M-defined function (used for query folding).
    public var closure: (body: MExpr, env: MEnv)? {
        if case .closure(let b, let e) = implementation { return (b, e) }
        return nil
    }
}
