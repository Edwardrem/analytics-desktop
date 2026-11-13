import Foundation
import FacetCore

/// Arguments passed to a native library function, with typed accessors that raise M-style errors.
/// Missing optional arguments read as null.
public struct MArgs {
    public let values: [MValue]
    public let functionName: String
    public init(values: [MValue], functionName: String) { self.values = values; self.functionName = functionName }

    public var count: Int { values.count }
    /// Argument `i`, or null when not supplied.
    public subscript(i: Int) -> MValue { i < values.count ? values[i] : .null }
    /// True when argument `i` was supplied and is not null.
    public func has(_ i: Int) -> Bool { i < values.count && !values[i].isNull }

    private func mismatch(_ i: Int, _ expected: String) -> MError {
        let v = self[i]
        return MError("\(functionName): we cannot convert \(v.isNull ? "the value null" : "a value of type \(v.typeName.capitalized)") to type \(expected.capitalized) (argument \(i + 1)).",
                      detail: v.isStructured ? nil : v)
    }
    public func text(_ i: Int) throws -> String { if case .text(let s) = self[i] { return s }; throw mismatch(i, "text") }
    public func optText(_ i: Int) throws -> String? { has(i) ? try text(i) : nil }
    public func number(_ i: Int) throws -> Double { if case .number(let d) = self[i] { return d }; throw mismatch(i, "number") }
    public func optNumber(_ i: Int) throws -> Double? { has(i) ? try number(i) : nil }
    public func int(_ i: Int) throws -> Int {
        let d = try number(i)
        guard d.isFinite, abs(d) < 9e15 else { throw mismatch(i, "integer") }
        return Int(d.rounded(.towardZero))
    }
    public func optInt(_ i: Int) throws -> Int? { has(i) ? try int(i) : nil }
    public func logical(_ i: Int) throws -> Bool { if case .logical(let b) = self[i] { return b }; throw mismatch(i, "logical") }
    public func optLogical(_ i: Int) throws -> Bool? { has(i) ? try logical(i) : nil }
    public func list(_ i: Int) throws -> [MValue] { if case .list(let l) = self[i] { return l }; throw mismatch(i, "list") }
    public func optList(_ i: Int) throws -> [MValue]? { has(i) ? try list(i) : nil }
    public func record(_ i: Int) throws -> MRecord { if case .record(let r) = self[i] { return r }; throw mismatch(i, "record") }
    public func optRecord(_ i: Int) throws -> MRecord? { has(i) ? try record(i) : nil }
    public func table(_ i: Int) throws -> MTable { if case .table(let t) = self[i] { return t }; throw mismatch(i, "table") }
    public func optTable(_ i: Int) throws -> MTable? { has(i) ? try table(i) : nil }
    public func function(_ i: Int) throws -> MFunction { if case .function(let f) = self[i] { return f }; throw mismatch(i, "function") }
    public func optFunction(_ i: Int) throws -> MFunction? { has(i) ? try function(i) : nil }
    public func type(_ i: Int) throws -> MType { if case .type(let t) = self[i] { return t }; throw mismatch(i, "type") }
    public func binary(_ i: Int) throws -> Data { if case .binary(let d) = self[i] { return d }; throw mismatch(i, "binary") }
    /// A list of text (accepts a single text as a one-element list).
    public func textList(_ i: Int) throws -> [String] {
        if case .text(let s) = self[i] { return [s] }
        return try list(i).map { v in
            guard case .text(let s) = try v.forced() else { throw mismatch(i, "list of text") }
            return s
        }
    }
    /// Forced elements of a list argument (throws the first element error).
    public func forcedList(_ i: Int) throws -> [MValue] { try list(i).map { try $0.forced() } }
}

/// The M standard library: a registry of named functions and constants.
public final class MLibrary: @unchecked Sendable {
    public private(set) var values: [String: MValue] = [:]

    /// The full standard library (built once).
    public static let shared: MLibrary = {
        let lib = MLibrary()
        for register in MLibrary.registrars { register(lib) }
        return lib
    }()

    public init() {}

    /// Register a function with a fixed number of arguments.
    public func fn(_ name: String, _ arity: Int, _ impl: @escaping MFunction.Native) {
        values[name] = .function(MFunction(name: name, minArgs: arity, maxArgs: arity, native: impl))
    }
    /// Register a function with optional arguments (`1...3`); use `n...Int.max` for variadic.
    public func fn(_ name: String, _ arity: ClosedRange<Int>, _ impl: @escaping MFunction.Native) {
        values[name] = .function(MFunction(name: name, minArgs: arity.lowerBound,
                                           maxArgs: arity.upperBound == Int.max ? nil : arity.upperBound, native: impl))
    }
    /// Register a constant (enum member, type, …).
    public func const(_ name: String, _ value: MValue) { values[name] = value }
    /// Register `Prefix.Name = number` enum members.
    public func enumeration(_ prefix: String, _ members: [(String, Int)]) {
        for (n, v) in members { values["\(prefix).\(n)"] = .number(Double(v)) }
        values["\(prefix).Type"] = .type(.plainNumber)
    }
    /// Make `alias` refer to the same value as `name`.
    public func alias(_ alias: String, _ name: String) { if let v = values[name] { values[alias] = v } }

    public var names: [String] { values.keys.sorted() }
    public var functionNames: [String] { values.filter { $0.value.functionValue != nil }.keys.sorted() }
}
