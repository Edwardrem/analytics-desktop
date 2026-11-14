import Foundation

/// One column of a server result.
struct RemoteColumn: Equatable {
    var name: String
    var type: MType
}

/// A server result, column-major.
struct RemoteResult {
    var columns: [RemoteColumn]
    var cells: [[MValue]]
    var rowCount: Int { cells.first?.count ?? 0 }
}

/// A failure talking to a database server. `message` is shown to the user as a `DataSource.Error`.
struct WireError: Error, CustomStringConvertible {
    var message: String
    /// The server's SQLSTATE (PostgreSQL) or error number and state (MySQL), when the server sent one.
    var code: String?
    init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
    var description: String { message }

    static func malformed(_ what: String) -> WireError {
        WireError("The server sent a malformed \(what). The connection was closed.")
    }
}

/// Bounds-checked reading of a server message. Every read fails with `WireError` instead of trapping, so a
/// truncated or hostile message can't read past its end.
struct ByteReader {
    let data: Data
    private(set) var offset: Int
    /// Name of the message being read, for error messages.
    let what: String

    init(_ data: Data, what: String) {
        self.data = data
        self.offset = data.startIndex
        self.what = what
    }

    var remaining: Int { data.endIndex - offset }
    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw WireError.malformed(what) }
        let out = data[offset..<(offset + n)]
        offset += n
        return Data(out)
    }
    mutating func skip(_ n: Int) throws { _ = try bytes(n) }
    mutating func rest() -> Data {
        let out = Data(data[offset..<data.endIndex])
        offset = data.endIndex
        return out
    }
    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.malformed(what) }
        defer { offset += 1 }
        return data[offset]
    }
    /// Unsigned big-endian integer of `n` bytes.
    mutating func uintBE(_ n: Int) throws -> UInt64 {
        guard n <= 8, remaining >= n else { throw WireError.malformed(what) }
        var v: UInt64 = 0
        for i in 0..<n { v = v << 8 | UInt64(data[offset + i]) }
        offset += n
        return v
    }
    /// Unsigned little-endian integer of `n` bytes.
    mutating func uintLE(_ n: Int) throws -> UInt64 {
        guard n <= 8, remaining >= n else { throw WireError.malformed(what) }
        var v: UInt64 = 0
        for i in (0..<n).reversed() { v = v << 8 | UInt64(data[offset + i]) }
        offset += n
        return v
    }
    mutating func i16BE() throws -> Int16 { Int16(truncatingIfNeeded: try uintBE(2)) }
    mutating func i32BE() throws -> Int32 { Int32(truncatingIfNeeded: try uintBE(4)) }
    mutating func i64BE() throws -> Int64 { Int64(bitPattern: try uintBE(8)) }
    mutating func u16LE() throws -> UInt16 { UInt16(truncatingIfNeeded: try uintLE(2)) }
    mutating func u32LE() throws -> UInt32 { UInt32(truncatingIfNeeded: try uintLE(4)) }

    /// Bytes up to (not including) the next NUL, which is consumed.
    mutating func cString() throws -> Data {
        guard let end = data[offset...].firstIndex(of: 0) else { throw WireError.malformed(what) }
        let out = Data(data[offset..<end])
        offset = end + 1
        return out
    }
    mutating func cText() throws -> String { String(decoding: try cString(), as: UTF8.self) }
}

/// Builds a client message.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func append(_ d: Data) { data.append(d) }
    mutating func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func uintBE(_ v: UInt64, _ n: Int) {
        for i in (0..<n).reversed() { data.append(UInt8(truncatingIfNeeded: v >> (UInt64(i) * 8))) }
    }
    mutating func uintLE(_ v: UInt64, _ n: Int) {
        for i in 0..<n { data.append(UInt8(truncatingIfNeeded: v >> (UInt64(i) * 8))) }
    }
    mutating func i16BE(_ v: Int16) { uintBE(UInt64(UInt16(bitPattern: v)), 2) }
    mutating func i32BE(_ v: Int32) { uintBE(UInt64(UInt32(bitPattern: v)), 4) }
    mutating func i64BE(_ v: Int64) { uintBE(UInt64(bitPattern: v), 8) }
    /// UTF-8 text followed by a NUL.
    mutating func cString(_ s: String) {
        data.append(contentsOf: Array(s.utf8))
        data.append(0)
    }
}

/// Limits that keep a server from making the client allocate or wait without bound.
struct WireLimits: Sendable {
    /// Largest single protocol message (PostgreSQL) or logical packet (MySQL) accepted.
    var maxMessageBytes = 256 << 20
    /// Largest total size of one result's row data.
    var maxResultBytes = 4 << 30
    /// Most columns a result may have.
    var maxColumns = 4096
    /// Seconds to establish the connection, including TLS and authentication.
    var connectTimeout: TimeInterval = 30
    /// Seconds a command may run before it is cancelled (nil: no limit).
    var commandTimeout: TimeInterval? = 600
}

extension Data {
    /// Lower-case hexadecimal.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let h = nibble(chars[i]), let l = nibble(chars[i + 1]) else { return nil }
            out.append(h << 4 | l)
            i += 2
        }
        self = out
    }
}
