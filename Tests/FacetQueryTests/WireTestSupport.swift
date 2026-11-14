import XCTest
import FacetCore
@testable import FacetQuery

/// A server that replies with fixed bytes; what the client sends is recorded. No network.
final class ScriptedTransport: WireTransport {
    private var incoming: Data
    private var cursor = 0
    private(set) var sent = Data()
    let usesTLS: Bool
    let peerCertificate: Data?
    private(set) var closed = false

    init(_ incoming: Data, tls: Bool = false, certificate: Data? = nil) {
        self.incoming = incoming; self.usesTLS = tls; self.peerCertificate = certificate
    }
    func send(_ data: Data, timeout: TimeInterval) throws {
        guard !closed else { throw WireError("The connection to the server was closed.") }
        sent.append(data)
    }
    func read(_ n: Int, deadline: DispatchTime) throws -> Data {
        guard !closed else { throw WireError("The connection to the server was closed.") }
        guard incoming.count - cursor >= n else { throw WireError("The server closed the connection.") }
        defer { cursor += n }
        return incoming.subdata(in: cursor..<(cursor + n))
    }
    func close() { closed = true }
}

/// Builders for server messages.
enum PGServer {
    static func message(_ type: Character, _ body: Data) -> Data {
        var w = ByteWriter()
        w.u8(type.asciiValue ?? 0); w.i32BE(Int32(body.count + 4)); w.append(body)
        return w.data
    }
    static func auth(_ code: Int32, _ rest: Data = Data()) -> Data {
        var w = ByteWriter(); w.i32BE(code); w.append(rest)
        return message("R", w.data)
    }
    static func ready() -> Data { message("Z", Data("I".utf8)) }
    static func backendKey(_ pid: Int32) -> Data {
        var w = ByteWriter(); w.i32BE(pid); w.append([9, 9, 9, 9])
        return message("K", w.data)
    }
    static func fields(_ type: Character, _ f: [(Character, String)]) -> Data {
        var w = ByteWriter()
        for (code, value) in f { w.u8(code.asciiValue ?? 0); w.cString(value) }
        w.u8(0)
        return message(type, w.data)
    }
    static func rowDescription(_ columns: [(String, Int32)]) -> Data {
        var w = ByteWriter()
        w.i16BE(Int16(columns.count))
        for (name, oid) in columns {
            w.cString(name); w.i32BE(0); w.i16BE(0); w.i32BE(oid); w.i16BE(-1); w.i32BE(-1); w.i16BE(0)
        }
        return message("T", w.data)
    }
    static func dataRow(_ cells: [Data?]) -> Data {
        var w = ByteWriter()
        w.i16BE(Int16(cells.count))
        for c in cells {
            if let c { w.i32BE(Int32(c.count)); w.append(c) } else { w.i32BE(-1) }
        }
        return message("D", w.data)
    }
    static func be(_ v: Int64, _ n: Int) -> Data { var w = ByteWriter(); w.uintBE(UInt64(bitPattern: v), n); return w.data }
    static let authOK = auth(0)
    static let session = authOK + backendKey(42) + ready()
}

/// Splits what a PostgreSQL client sent after its startup message into (type, body) messages.
func frontendMessages(_ data: Data, skippingStartup: Bool = true) throws -> [(Character, Data)] {
    var r = ByteReader(data, what: "test")
    if skippingStartup { try r.skip(Int(try r.i32BE()) - 4) }
    var out: [(Character, Data)] = []
    while !r.isAtEnd {
        let t = Character(UnicodeScalar(try r.u8()))
        let n = Int(try r.i32BE())
        out.append((t, try r.bytes(n - 4)))
    }
    return out
}
