import XCTest
import FacetCore
@testable import FacetQuery

/// MySQL protocol from byte fixtures: greeting, scrambles (expected values from Python hashlib), caching_sha2 fast and
/// full authentication, auth switch, errors, text and binary result sets, and bounds.
final class MySQLProtocolTests: XCTestCase {
    private let salt = Data(1...20)
    private let caps: UInt32 = MySQLProtocol.longPassword | MySQLProtocol.longFlag | MySQLProtocol.connectWithDB | MySQLProtocol.protocol41
        | MySQLProtocol.ssl | MySQLProtocol.transactions | MySQLProtocol.secureConnection | MySQLProtocol.multiResults
        | MySQLProtocol.psMultiResults | MySQLProtocol.pluginAuth | MySQLProtocol.pluginAuthLenencData

    private func packet(_ payload: Data, _ seq: UInt8) -> Data { MySQLProtocol.packet(payload, sequence: seq) }

    private func greeting(plugin: String = "caching_sha2_password", version: String = "8.4.3") -> Data {
        var w = ByteWriter()
        w.u8(10); w.cString(version); w.uintLE(7, 4)
        w.append(salt.prefix(8)); w.u8(0)
        w.uintLE(UInt64(caps & 0xFFFF), 2); w.u8(255); w.uintLE(2, 2); w.uintLE(UInt64(caps >> 16), 2)
        w.u8(21); w.append(Data(count: 10))
        w.append(salt.suffix(12)); w.u8(0)
        w.cString(plugin)
        return w.data
    }
    private let ok = Data([0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
    private let login = MySQLConnection.Login(user: "bob", password: "pass", database: "shop")

    func testGreeting() throws {
        let h = try MySQLProtocol.handshake(greeting())
        XCTAssertEqual(h.serverVersion, "8.4.3")
        XCTAssertEqual(h.connectionID, 7)
        XCTAssertEqual(h.salt, salt)
        XCTAssertEqual(h.plugin, "caching_sha2_password")
        XCTAssertEqual(h.capabilities, caps)
        XCTAssertTrue(try MySQLProtocol.handshake(greeting(version: "5.5.5-10.11.6-MariaDB")).isMariaDB)
        XCTAssertThrowsError(try MySQLProtocol.handshake(Data([9])), "protocol 9")
        XCTAssertThrowsError(try MySQLProtocol.handshake(Data([10, 0x41])), "truncated")
    }

    func testScrambles() {
        XCTAssertEqual(MySQLProtocol.nativeScramble(password: "pass", salt: salt).hexString, "1c2b71bfe92d826fc0f1fafffda26efcfe3ea07c")
        XCTAssertEqual(MySQLProtocol.cachingSHA2Scramble(password: "pass", salt: salt).hexString, "5fa07a9b857271a04b80530e319bebe1c09283599a913a722d3e120a7e244135")
        XCTAssertEqual(MySQLProtocol.nativeScramble(password: "", salt: salt), Data(), "an empty password sends nothing")
    }

    /// The client's packets (payloads) in order, without the COM_QUIT a closed session ends with.
    private func payloads(_ data: Data) throws -> [Data] {
        var r = ByteReader(data, what: "test"), out: [Data] = []
        while !r.isAtEnd {
            let n = Int(try r.uintLE(3)); _ = try r.u8()
            out.append(try r.bytes(n))
        }
        if out.last == Data([0x01]) { out.removeLast() }
        return out
    }

    func testCachingSHA2FastAuth() throws {
        let t = ScriptedTransport(packet(greeting(), 0) + packet(Data([0x01, 0x03]), 2) + packet(ok, 3))
        _ = try MySQLConnection(transport: t, login: login, limits: WireLimits())
        let response = try XCTUnwrap(try payloads(t.sent).first)
        var r = ByteReader(response, what: "test")
        let clientCaps = UInt32(try r.uintLE(4))
        XCTAssertEqual(clientCaps & MySQLProtocol.ssl, 0, "no TLS was requested on this connection")
        try r.skip(4 + 1 + 23)
        XCTAssertEqual(try r.cText(), "bob")
        XCTAssertEqual(try r.u8(), 32)
        XCTAssertEqual(try r.bytes(32).hexString, "5fa07a9b857271a04b80530e319bebe1c09283599a913a722d3e120a7e244135")
        XCTAssertEqual(try r.cText(), "shop")
        XCTAssertEqual(try r.cText(), "caching_sha2_password")
    }

    func testCachingSHA2FullAuthOnlyOverTLS() throws {
        let server = packet(greeting(), 0) + packet(Data([0x01, 0x04]), 2) + packet(ok, 4)
        let plain = ScriptedTransport(server)
        XCTAssertThrowsError(try MySQLConnection(transport: plain, login: login, limits: WireLimits())) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("only done over TLS") ?? false, "\($0)")
        }
        XCTAssertEqual(try payloads(plain.sent).count, 1, "the password was not sent")
        // Over TLS the greeting came during negotiation; the password goes in the clear inside TLS.
        let tls = ScriptedTransport(packet(Data([0x01, 0x04]), 2) + packet(ok, 4), tls: true)
        _ = try MySQLConnection(transport: tls, login: login, limits: WireLimits(), greeting: try MySQLProtocol.handshake(greeting()),
                                capabilities: MySQLProtocol.clientCapabilities(server: caps, tls: true))
        let sent = try payloads(tls.sent)
        XCTAssertEqual(sent.last, Data("pass\u{0}".utf8))
        var r = ByteReader(try XCTUnwrap(sent.first), what: "test")
        XCTAssertNotEqual(UInt32(try r.uintLE(4)) & MySQLProtocol.ssl, 0)
    }

    func testStartTLSNegotiator() {
        let n = MySQLStartTLS()
        let full = packet(greeting(), 0)
        if case .needMore = n.received(full.prefix(10)) {} else { XCTFail("needs the whole greeting") }
        guard case .startTLS(let send) = n.received(full) else { return XCTFail("should start TLS") }
        XCTAssertEqual(send.count, 4 + 32)
        XCTAssertEqual(send[send.startIndex + 3], 1, "SSLRequest is packet 1")
        XCTAssertEqual(n.greeting?.salt, salt)
        // A server without TLS is refused rather than downgraded.
        var noSSL = greeting()
        noSSL[noSSL.startIndex + 1 + 6 + 4 + 8 + 1 + 1] &= ~UInt8(0x08)
        guard case .fail(let message) = MySQLStartTLS().received(packet(noSSL, 0)) else { return XCTFail("should fail") }
        XCTAssertTrue(message.contains("encrypted"), message)
        guard case .fail = MySQLStartTLS().received(full + Data([1])) else { return XCTFail("bytes before TLS are refused") }
    }

    func testAuthSwitchToNativePassword() throws {
        var sw = ByteWriter(); sw.u8(0xFE); sw.cString("mysql_native_password"); sw.append(salt); sw.u8(0)
        let t = ScriptedTransport(packet(greeting(), 0) + packet(sw.data, 2) + packet(ok, 4))
        _ = try MySQLConnection(transport: t, login: login, limits: WireLimits())
        XCTAssertEqual(try payloads(t.sent).last?.hexString, "1c2b71bfe92d826fc0f1fafffda26efcfe3ea07c")
        // Unknown plugins are named; clear-text plugins need TLS.
        var ed = ByteWriter(); ed.u8(0xFE); ed.cString("client_ed25519"); ed.append(salt)
        XCTAssertThrowsError(try MySQLConnection(transport: ScriptedTransport(packet(greeting(), 0) + packet(ed.data, 2)), login: login, limits: WireLimits())) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("client_ed25519") ?? false)
        }
        var clear = ByteWriter(); clear.u8(0xFE); clear.cString("mysql_clear_password")
        XCTAssertThrowsError(try MySQLConnection(transport: ScriptedTransport(packet(greeting(), 0) + packet(clear.data, 2)), login: login, limits: WireLimits()))
    }

    func testErrorPacket() {
        var e = ByteWriter(); e.u8(0xFF); e.uintLE(1045, 2); e.append(Data("#28000".utf8)); e.append(Data("Access denied for user 'bob'".utf8))
        XCTAssertThrowsError(try MySQLConnection(transport: ScriptedTransport(packet(greeting(), 0) + packet(e.data, 2)), login: login, limits: WireLimits())) {
            XCTAssertEqual(($0 as? WireError)?.message, "MySQL: Access denied for user 'bob' (error 1045, SQLSTATE 28000)")
        }
    }

    private func columnDef(_ name: String, type: UInt8, charset: UInt16 = 45, length: UInt32 = 11, flags: UInt16 = 0) -> Data {
        var w = ByteWriter()
        for part in ["def", "shop", "t", "t", name, name] { w.append(MySQLProtocol.lenenc(part.utf8.count)); w.append(Data(part.utf8)) }
        w.u8(0x0c); w.uintLE(UInt64(charset), 2); w.uintLE(UInt64(length), 4); w.u8(type); w.uintLE(UInt64(flags), 2); w.u8(0); w.uintLE(0, 2)
        return w.data
    }
    private let eof = Data([0xFE, 0x00, 0x00, 0x02, 0x00])
    private func session(_ rest: Data) throws -> (MySQLConnection, ScriptedTransport) {
        let t = ScriptedTransport(packet(greeting(plugin: "mysql_native_password"), 0) + packet(ok, 2) + rest)
        return (try MySQLConnection(transport: t, login: login, limits: WireLimits()), t)
    }
    private func lenencText(_ s: String) -> Data { MySQLProtocol.lenenc(s.utf8.count) + Data(s.utf8) }

    func testTextResultSet() throws {
        let rows = packet(lenencText("1") + lenencText("Ann") + lenencText("2024-01-02 03:04:05.250000") + lenencText("1"), 7)
            + packet(lenencText("2") + Data([0xFB]) + lenencText("0000-00-00 00:00:00") + lenencText("0"), 8)
        let reply = packet(Data([4]), 1) + packet(columnDef("id", type: MySQLType.longlong), 2) + packet(columnDef("name", type: MySQLType.varString), 3)
            + packet(columnDef("at", type: MySQLType.datetime), 4) + packet(columnDef("flag", type: MySQLType.tiny, length: 1), 5)
        let (c, _) = try session(reply + packet(eof, 6) + rows + packet(eof, 9))
        let r = try c.query("select …", limit: nil)
        XCTAssertEqual(r.columns, [RemoteColumn(name: "id", type: .nullable(.int64)), RemoteColumn(name: "name", type: .nullable(.text)),
                                   RemoteColumn(name: "at", type: .nullable(.datetime)), RemoteColumn(name: "flag", type: .nullable(.logical))])
        XCTAssertEqual(r.cells.map { $0.map(show) }, [["1", "2"], ["Ann", "null"], ["#datetime(2024, 1, 2, 3, 4, 5.25)", "null"], ["true", "false"]])
    }

    func testBinaryResultSetFromPreparedStatement() throws {
        var prepareOK = ByteWriter(); prepareOK.u8(0); prepareOK.uintLE(1, 4); prepareOK.uintLE(2, 2); prepareOK.uintLE(1, 2); prepareOK.u8(0); prepareOK.uintLE(0, 2)
        let prepare = packet(prepareOK.data, 1) + packet(columnDef("?", type: MySQLType.varString), 2) + packet(eof, 3)
            + packet(columnDef("n", type: MySQLType.longlong, flags: 0x20), 4) + packet(columnDef("d", type: MySQLType.datetime), 5) + packet(eof, 6)
        var row = ByteWriter()
        row.u8(0); row.u8(0) // header, null bitmap (offset 2): nothing null
        row.uintLE(UInt64.max, 8)                          // unsigned 18446744073709551615
        row.u8(7); row.uintLE(2024, 2); row.u8(1); row.u8(2); row.u8(3); row.u8(4); row.u8(5)
        var nullRow = ByteWriter(); nullRow.u8(0); nullRow.u8(0b0000_1100) // both null
        let execute = packet(Data([2]), 1) + packet(columnDef("n", type: MySQLType.longlong, flags: 0x20), 2) + packet(columnDef("d", type: MySQLType.datetime), 3)
            + packet(eof, 4) + packet(row.data, 5) + packet(nullRow.data, 6) + packet(eof, 7)
        let (c, t) = try session(prepare + execute)
        let r = try c.execute("select ? + 0 as n, now() as d", parameters: [.number(5)], limit: nil)
        XCTAssertEqual(r.cells.map { $0.map(show) }, [["1.8446744073709552e+19", "null"], ["#datetime(2024, 1, 2, 3, 4, 5)", "null"]])
        let sent = try payloads(t.sent)
        // COM_STMT_EXECUTE: id 1, no cursor, 1 iteration, null bitmap 0, types bound, LONGLONG 5.
        var expected = ByteWriter()
        expected.u8(0x17); expected.uintLE(1, 4); expected.u8(0); expected.uintLE(1, 4); expected.u8(0); expected.u8(1)
        expected.u8(MySQLType.longlong); expected.u8(0); expected.uintLE(5, 8)
        XCTAssertEqual(sent.last, expected.data)
        XCTAssertThrowsError(try session(prepare).0.execute("select ?", parameters: [], limit: nil), "parameter count")
    }

    func testLocalInfileAndBounds() throws {
        let (c, _) = try session(packet(Data([0xFB]) + Data("/etc/passwd".utf8), 1))
        XCTAssertThrowsError(try c.query("load data local infile …", limit: nil)) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("local file") ?? false)
        }
        var limits = WireLimits(); limits.maxMessageBytes = 100
        var big = ByteWriter(); big.uintLE(5000, 3); big.u8(0)
        XCTAssertThrowsError(try MySQLConnection(transport: ScriptedTransport(big.data), login: login, limits: limits)) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("limit") ?? false)
        }
        // A cell longer than its row.
        var row = ByteReader(Data([0xFC, 0xFF, 0x00, 0x41]), what: "row")
        XCTAssertThrowsError(try MySQLProtocol.readLenencBytes(&row))
        // Too many columns.
        let (wide, _) = try session(packet(MySQLProtocol.lenenc(100_000), 1))
        XCTAssertThrowsError(try wide.query("select …", limit: nil))
    }

    func testTextValues() {
        let time = MySQLProtocol.Column(name: "t", type: MySQLType.time, flags: 0, charset: 63, length: 10, decimals: 0)
        XCTAssertEqual(show(MySQLType.decodeText(time, Data("12:30:00".utf8))), "#time(12, 30, 0)")
        XCTAssertEqual(show(MySQLType.decodeText(time, Data("838:59:59".utf8))), "<error>", "an elapsed time isn't a time of day")
        let blob = MySQLProtocol.Column(name: "b", type: MySQLType.blob, flags: 0, charset: 63, length: 10, decimals: 0)
        XCTAssertEqual(show(MySQLType.decodeText(blob, Data([0, 1, 2]))), "<binary 3>")
        let dec = MySQLProtocol.Column(name: "d", type: MySQLType.newDecimal, flags: 0, charset: 63, length: 10, decimals: 2)
        XCTAssertEqual(show(MySQLType.decodeText(dec, Data("-12.50".utf8))), "-12.5")
        let date = MySQLProtocol.Column(name: "d", type: MySQLType.date, flags: 0, charset: 63, length: 10, decimals: 0)
        XCTAssertEqual(show(MySQLType.decodeText(date, Data("0000-00-00".utf8))), "null")
        XCTAssertEqual(show(MySQLType.decodeText(date, Data("2024-02-30".utf8))), "<error>")
    }
}
