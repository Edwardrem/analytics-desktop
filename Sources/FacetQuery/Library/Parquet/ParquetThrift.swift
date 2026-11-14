import Foundation

/// A value read with the Thrift compact protocol, the encoding of Parquet's footer and page headers.
indirect enum ThriftValue {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case binary([UInt8])
    case list([ThriftValue])
    case structure(ThriftStruct)
    case map

    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var string: String? { if case .binary(let b) = self { return String(decoding: b, as: UTF8.self) }; return nil }
    var structure: ThriftStruct? { if case .structure(let s) = self { return s }; return nil }
    var list: [ThriftValue]? { if case .list(let l) = self { return l }; return nil }
}

/// A Thrift struct: field id → value. Unknown fields are kept and ignored by the readers.
struct ThriftStruct {
    var fields: [Int16: ThriftValue] = [:]
    subscript(_ id: Int16) -> ThriftValue? { fields[id] }
    func int(_ id: Int16) -> Int? { fields[id]?.int.flatMap { Int(exactly: $0) } }
    func int64(_ id: Int16) -> Int64? { fields[id]?.int }
    func string(_ id: Int16) -> String? { fields[id]?.string }
    func structure(_ id: Int16) -> ThriftStruct? { fields[id]?.structure }
    func list(_ id: Int16) -> [ThriftValue] { fields[id]?.list ?? [] }
    /// The member set in a Thrift union (the first field present).
    var unionMember: (id: Int16, value: ThriftStruct)? {
        guard let (id, v) = fields.min(by: { $0.key < $1.key }) else { return nil }
        return (id, v.structure ?? ThriftStruct())
    }
}

/// Reads compact-protocol structs from a byte buffer. Every length is checked against the bytes left, nesting is
/// limited, and malformed input throws instead of trapping.
struct ThriftReader {
    struct Malformed: Error { let message: String }
    let bytes: [UInt8]
    private(set) var position: Int
    private var depth = 0
    static let maxDepth = 32

    init(_ bytes: [UInt8], at position: Int = 0) { self.bytes = bytes; self.position = position }

    mutating func readStruct() throws -> ThriftStruct {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw Malformed(message: "metadata is nested too deeply") }
        var s = ThriftStruct()
        var lastID: Int16 = 0
        while true {
            let header = try byte()
            if header == 0 { return s }
            let type = header & 0x0F
            let delta = Int16(header >> 4)
            let id: Int16
            if delta == 0 {
                let raw = zigzag(try varint())
                guard let v = Int16(exactly: raw) else { throw Malformed(message: "field id out of range") }
                id = v
            } else {
                id = lastID &+ delta
            }
            lastID = id
            switch type {
            case 1: s.fields[id] = .bool(true)
            case 2: s.fields[id] = .bool(false)
            default: s.fields[id] = try value(ofType: type)
            }
        }
    }

    private mutating func value(ofType type: UInt8) throws -> ThriftValue {
        switch type {
        case 1: return .bool(true)
        case 2: return .bool(false)
        case 3: return .int(Int64(Int8(bitPattern: try byte())))
        case 4, 5, 6: return .int(zigzag(try varint()))
        case 7:
            guard bytes.count - position >= 8 else { throw Malformed(message: "metadata ends inside a number") }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
            position += 8
            return .double(Double(bitPattern: bits))
        case 8:
            let n = try length()
            defer { position += n }
            return .binary(Array(bytes[position..<(position + n)]))
        case 9, 10:
            let header = try byte()
            var count = Int(header >> 4)
            if count == 15 { count = try length(checkBytes: false) }
            let elementType = header & 0x0F
            // Each element takes at least one byte (bools in lists take one), so the count can't exceed what is left.
            guard count <= bytes.count - position else { throw Malformed(message: "a list is longer than the metadata") }
            var items: [ThriftValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                if elementType == 1 || elementType == 2 { items.append(.bool(try byte() == 1)) }
                else { items.append(try value(ofType: elementType)) }
            }
            return .list(items)
        case 11:
            let count = try length(checkBytes: false)
            if count == 0 { return .map }
            let kinds = try byte()
            guard count <= bytes.count - position else { throw Malformed(message: "a map is longer than the metadata") }
            for _ in 0..<count { _ = try value(ofType: kinds >> 4); _ = try value(ofType: kinds & 0x0F) }
            return .map
        case 12: return .structure(try readStruct())
        default: throw Malformed(message: "unknown field type \(type)")
        }
    }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw Malformed(message: "metadata ends early") }
        defer { position += 1 }
        return bytes[position]
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw Malformed(message: "a number in the metadata is too long") }
        }
    }
    private func zigzag(_ v: UInt64) -> Int64 { Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1))) }
    private mutating func length(checkBytes: Bool = true) throws -> Int {
        let v = try varint()
        guard v <= UInt64(Int32.max), !checkBytes || Int(v) <= bytes.count - position else {
            throw Malformed(message: "a length in the metadata runs past its end")
        }
        return Int(v)
    }
}
