import Foundation
import FacetCore

/// Facets of M's `number` type (`Int64.Type`, `Currency.Type`, …).
public enum MNumberKind: String, Sendable {
    case double, int64, int32, int16, int8, byte, single, decimal, currency, percentage
    /// The library identifier, e.g. `Int64.Type`; nil for plain `number`.
    public var libraryName: String? {
        switch self {
        case .double: return nil
        case .int64: return "Int64.Type"
        case .int32: return "Int32.Type"
        case .int16: return "Int16.Type"
        case .int8: return "Int8.Type"
        case .byte: return "Byte.Type"
        case .single: return "Single.Type"
        case .decimal: return "Decimal.Type"
        case .currency: return "Currency.Type"
        case .percentage: return "Percentage.Type"
        }
    }
    public var isInteger: Bool { [.int64, .int32, .int16, .int8, .byte].contains(self) }
}

/// A field of a record or table type.
public struct MTypeField: Equatable, Sendable {
    public var name: String
    public var type: MType
    public var isOptional: Bool
    public init(_ name: String, _ type: MType = .any, optional: Bool = false) {
        self.name = name; self.type = type; self.isOptional = optional
    }
}

/// An M type value.
public indirect enum MType: Equatable, Sendable {
    case any, anynonnull, none, null, logical, text, date, datetime, datetimezone, time, duration, binary, action, function, type
    case number(MNumberKind)
    /// `type list` is `.list(.any)`; `type {text}` is `.list(.text)`.
    case list(MType)
    case record([MTypeField], open: Bool)
    case table([MTypeField])
    case nullable(MType)

    public static let plainNumber = MType.number(.double)
    public static let int64 = MType.number(.int64)
    public static let anyRecord = MType.record([], open: true)
    public static let anyTable = MType.table([])
    public static let anyList = MType.list(.any)

    public var isNullable: Bool {
        switch self { case .nullable, .any, .null: return true; default: return false }
    }
    public var nonNullable: MType {
        switch self {
        case .nullable(let t): return t.nonNullable
        case .any: return .anynonnull
        default: return self
        }
    }
    public var asNullable: MType { isNullable ? self : .nullable(self) }

    /// Whether `value` conforms to this type (`value is type`).
    public func matches(_ value: MValue) -> Bool {
        switch self {
        case .any: return true
        case .anynonnull: return !value.isNull
        case .none: return false
        case .null: return value.isNull
        case .nullable(let t): return value.isNull || t.matches(value)
        case .logical: if case .logical = value { return true }; return false
        case .number: if case .number = value { return true }; return false
        case .text: if case .text = value { return true }; return false
        case .date: if case .date = value { return true }; return false
        case .datetime: if case .datetime = value { return true }; return false
        case .datetimezone: if case .datetimezone = value { return true }; return false
        case .time: if case .time = value { return true }; return false
        case .duration: if case .duration = value { return true }; return false
        case .binary: if case .binary = value { return true }; return false
        case .list: if case .list = value { return true }; return false
        case .record: if case .record = value { return true }; return false
        case .table: if case .table = value { return true }; return false
        case .function: if case .function = value { return true }; return false
        case .type: if case .type = value { return true }; return false
        case .action: return false
        }
    }

    /// The type of a runtime value (`Value.Type`).
    public static func of(_ value: MValue) -> MType {
        switch value {
        case .null: return .null
        case .logical: return .logical
        case .number: return .plainNumber
        case .text: return .text
        case .date: return .date
        case .datetime: return .datetime
        case .datetimezone: return .datetimezone
        case .time: return .time
        case .duration: return .duration
        case .binary: return .binary
        case .list: return .anyList
        case .record(let r): return .record(r.names.map { MTypeField($0) }, open: false)
        case .table(let t): return t.tableType
        case .function: return .function
        case .type: return .type
        case .error, .lazy: return .any
        }
    }

    /// M source text for this type as it would follow the `type` keyword, or a library identifier
    /// for number facets — e.g. `text`, `nullable number`, `Int64.Type`, `table [a = text]`.
    public var mText: String {
        switch self {
        case .any: return "any"
        case .anynonnull: return "anynonnull"
        case .none: return "none"
        case .null: return "null"
        case .logical: return "logical"
        case .text: return "text"
        case .date: return "date"
        case .datetime: return "datetime"
        case .datetimezone: return "datetimezone"
        case .time: return "time"
        case .duration: return "duration"
        case .binary: return "binary"
        case .action: return "action"
        case .function: return "function"
        case .type: return "type"
        case .number(let k): return k.libraryName ?? "number"
        case .list(let t): return t == .any ? "list" : "{\(t.mText)}"
        case .record(let f, let open):
            if f.isEmpty && open { return "record" }
            let parts = f.map { ($0.isOptional ? "optional " : "") + MSyntax.identifier($0.name) + " = " + $0.type.mText }
            return "[" + (parts + (open ? ["..."] : [])).joined(separator: ", ") + "]"
        case .table(let f):
            if f.isEmpty { return "table" }
            return "table [" + f.map { MSyntax.identifier($0.name) + " = " + $0.type.mText }.joined(separator: ", ") + "]"
        case .nullable(let t): return "nullable " + t.mText
        }
    }
    /// A complete M expression that evaluates to this type: `type text`, `Int64.Type`, `type nullable number`.
    public var mExpression: String {
        if case .number(let k) = self, let n = k.libraryName { return n }
        return "type " + mText
    }

    /// The closest FacetCore model data type.
    public var dataType: DataType {
        switch nonNullable {
        case .logical: return .boolean
        case .number(let k):
            if k.isInteger { return .integer }
            if k == .currency { return .currency }
            return .decimal
        case .text: return .text
        case .date: return .date
        case .datetime, .datetimezone: return .dateTime
        case .time: return .time
        case .duration: return .duration
        case .binary: return .binary
        default: return .any
        }
    }
    /// The M type corresponding to a FacetCore data type.
    public init(dataType: DataType) {
        switch dataType {
        case .text: self = .text
        case .integer: self = .number(.int64)
        case .decimal: self = .plainNumber
        case .currency: self = .number(.currency)
        case .boolean: self = .logical
        case .date: self = .date
        case .dateTime: self = .datetime
        case .time: self = .time
        case .duration: self = .duration
        case .binary: self = .binary
        case .any: self = .any
        }
    }
    /// Field list for record/table types (empty otherwise).
    public var fields: [MTypeField] {
        switch self {
        case .record(let f, _), .table(let f): return f
        case .nullable(let t): return t.fields
        default: return []
        }
    }
}
