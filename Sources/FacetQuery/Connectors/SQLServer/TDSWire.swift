import Foundation

/// A failure in the TDS client. `message` is shown to the user (prefixed "Microsoft SQL: " by the connector).
struct TDSError: Error, CustomStringConvertible {
    enum Kind { case protocolViolation, server, timeout, cancelled, connection, tls, login, unsupported }
    let kind: Kind
    let message: String
    /// The SQL Server error number for `.server` / `.login` errors.
    var number = 0
    var description: String { message }

    static func protocolViolation(_ m: String) -> TDSError { TDSError(kind: .protocolViolation, message: "The server sent a malformed response (\(m)).") }
    static func connection(_ m: String) -> TDSError { TDSError(kind: .connection, message: m) }
}

/// TDS packet types (MS-TDS 2.2.3.1.1).
enum TDSPacketType: UInt8 {
    case sqlBatch = 0x01, rpc = 0x03, tabularResult = 0x04, attention = 0x06, login7 = 0x10, prelogin = 0x12
}

enum TDSLimits {
    static let headerLength = 8
    /// The packet size requested at login; the server confirms or changes it with an ENVCHANGE.
    static let requestedPacketSize = 8000
    /// Packets before the server confirms a size, and the smallest size it may choose.
    static let initialPacketSize = 4096
    /// The largest packet the protocol allows.
    static let maxPacketSize = 32767
    static let maxColumns = 4096
}

/// Builds little-endian (and, where TDS asks, big-endian) binary messages.
struct TDSWriter {
    private(set) var bytes: [UInt8] = []
    init() {}
    var count: Int { bytes.count }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u16be(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u32be(_ v: UInt32) { for i in (0..<4).reversed() { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func append(_ d: Data) { bytes.append(contentsOf: d) }
    /// UTF-16LE text without a length.
    mutating func utf16(_ s: String) { for unit in s.utf16 { u16(unit) } }
    /// B_VARCHAR: a 1-byte character count and UTF-16LE text (truncated to 255 characters).
    mutating func bVarchar(_ s: String) {
        let units = Array(s.utf16.prefix(255))
        u8(UInt8(units.count)); for unit in units { u16(unit) }
    }
    /// Overwrite a little-endian UInt32 at `offset` (for length fields written before the data is known).
    mutating func patchU32(_ v: UInt32, at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }
    mutating func patchU16(_ v: UInt16, at offset: Int) {
        bytes[offset] = UInt8(v & 0xFF); bytes[offset + 1] = UInt8(v >> 8)
    }

    /// Split a message into packets of at most `packetSize` bytes, the last one marked end-of-message.
    static func packets(_ type: TDSPacketType, _ payload: [UInt8], packetSize: Int, resetConnection: Bool = false) -> [UInt8] {
        let room = max(512, min(packetSize, TDSLimits.maxPacketSize)) - TDSLimits.headerLength
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + (payload.count / room + 1) * TDSLimits.headerLength)
        var start = 0, id: UInt8 = 1
        repeat {
            let end = min(payload.count, start + room)
            let last = end == payload.count
            let length = UInt16(end - start + TDSLimits.headerLength)
            var status: UInt8 = last ? 0x01 : 0x00
            if resetConnection, start == 0 { status |= 0x08 }
            out += [type.rawValue, status, UInt8(length >> 8), UInt8(length & 0xFF), 0, 0, id, 0]
            out += payload[start..<end]
            start = end; id = id &+ 1
        } while start < payload.count
        return out
    }
}

/// A source of raw bytes (a network connection or, in tests, a fixture).
protocol TDSByteInput: AnyObject {
    /// At least one byte, or a throw at end of stream / timeout.
    func read(maximum: Int) throws -> [UInt8]
}

/// An in-memory byte input, for fixtures.
final class TDSMemoryInput: TDSByteInput {
    private let bytes: [UInt8]
    private var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    func read(maximum: Int) throws -> [UInt8] {
        guard position < bytes.count else { throw TDSError.connection("The server closed the connection.") }
        let end = min(bytes.count, position + maximum)
        defer { position = end }
        return Array(bytes[position..<end])
    }
}

/// Reads one TDS message (a run of packets ending with the end-of-message flag) as a bounded byte cursor.
/// Every read checks the remaining length, so a malformed or hostile length field fails instead of over-reading.
final class TDSMessageReader {
    private let input: TDSByteInput
    private var raw: [UInt8] = []          // bytes received but not yet split into packets
    private var rawStart = 0
    private var buffer: [UInt8] = []       // payload bytes of the message
    private var position = 0
    private(set) var sawEndOfMessage = false
    private(set) var payloadBytes = 0
    private let maxBytes: Int
    let expectedType: TDSPacketType

    /// `maxBytes` bounds the whole message (a result set larger than this fails with a clear error).
    init(_ input: TDSByteInput, expecting type: TDSPacketType = .tabularResult, maxBytes: Int) {
        self.input = input; self.expectedType = type; self.maxBytes = maxBytes
    }

    private func rawAvailable() -> Int { raw.count - rawStart }
    private func fillRaw(_ n: Int) throws {
        while rawAvailable() < n {
            if rawStart > 0 { raw.removeFirst(rawStart); rawStart = 0 }
            raw += try input.read(maximum: 65536)
        }
    }
    /// Append the next packet's payload to the buffer.
    private func nextPacket() throws {
        guard !sawEndOfMessage else { throw TDSError.protocolViolation("the message ended early") }
        try fillRaw(TDSLimits.headerLength)
        let h = rawStart
        guard let type = TDSPacketType(rawValue: raw[h]), type == expectedType else {
            throw TDSError.protocolViolation("unexpected packet type 0x\(String(raw[h], radix: 16))")
        }
        let status = raw[h + 1]
        let length = Int(raw[h + 2]) << 8 | Int(raw[h + 3])
        guard length >= TDSLimits.headerLength, length <= TDSLimits.maxPacketSize else {
            throw TDSError.protocolViolation("packet length \(length)")
        }
        try fillRaw(length)
        let body = rawStart + TDSLimits.headerLength, end = rawStart + length
        payloadBytes += end - body
        guard payloadBytes <= maxBytes else {
            throw TDSError(kind: .unsupported, message: "The result is larger than the \(maxBytes >> 20) MB this app reads from one query. Filter the query or select fewer columns.")
        }
        if position > 0, position == buffer.count { buffer.removeAll(keepingCapacity: true); position = 0 }
        else if position > 1 << 20 { buffer.removeFirst(position); position = 0 }
        buffer += raw[body..<end]
        rawStart = end
        if status & 0x01 != 0 { sawEndOfMessage = true }
    }
    private func ensure(_ n: Int) throws {
        guard n >= 0 else { throw TDSError.protocolViolation("negative length") }
        while buffer.count - position < n { try nextPacket() }
    }

    /// True once every byte of the message has been read.
    var isAtEnd: Bool {
        get throws {
            while position == buffer.count {
                if sawEndOfMessage { return true }
                try nextPacket()
            }
            return false
        }
    }
    /// Discard the rest of the message.
    func drain() throws { while !sawEndOfMessage { try nextPacket() }; position = buffer.count }

    func u8() throws -> UInt8 { try ensure(1); defer { position += 1 }; return buffer[position] }
    func u16() throws -> UInt16 { try ensure(2); defer { position += 2 }; return UInt16(buffer[position]) | UInt16(buffer[position + 1]) << 8 }
    func u16be() throws -> UInt16 { try ensure(2); defer { position += 2 }; return UInt16(buffer[position]) << 8 | UInt16(buffer[position + 1]) }
    func u32() throws -> UInt32 {
        try ensure(4); defer { position += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[position + $1]) << (8 * UInt32($1)) }
    }
    func u64() throws -> UInt64 {
        try ensure(8); defer { position += 8 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(buffer[position + $1]) << (8 * UInt64($1)) }
    }
    func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    func bytes(_ n: Int) throws -> [UInt8] {
        guard n <= maxBytes else { throw TDSError.protocolViolation("length \(n)") }
        try ensure(n); defer { position += n }
        return Array(buffer[position..<position + n])
    }
    func skip(_ n: Int) throws {
        guard n <= maxBytes else { throw TDSError.protocolViolation("length \(n)") }
        var left = n
        while left > 0 {
            if position == buffer.count { try nextPacket() }
            let step = min(left, buffer.count - position)
            position += step; left -= step
        }
    }
    func utf16(characters n: Int) throws -> String { TDSText.utf16(try bytes(n * 2)) }
    /// B_VARCHAR: 1-byte character count.
    func bVarchar() throws -> String { try utf16(characters: Int(try u8())) }
    /// US_VARCHAR: 2-byte character count.
    func usVarchar() throws -> String { try utf16(characters: Int(try u16())) }
}

enum TDSText {
    static func utf16(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count { units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }
    static func utf16Bytes(_ s: String) -> [UInt8] { var w = TDSWriter(); w.utf16(s); return w.bytes }
}
