import XCTest
import FacetCore
@testable import FacetQuery

/// PostgreSQL protocol from byte fixtures: SCRAM (RFC 7677's vector), MD5, startup, extended query decoding, errors
/// and bounds. Expected values come from the RFC and from an independent Python hashlib computation.
final class PostgreSQLProtocolTests: XCTestCase {
    private let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

    func testSCRAMMatchesRFC7677() throws {
        var c = SCRAMClient(user: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        XCTAssertEqual(c.clientFirst, "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        XCTAssertEqual(try c.clientFinal(serverFirst: serverFirst),
                       "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        XCTAssertNoThrow(try c.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        XCTAssertThrowsError(try c.verify(serverFinal: "v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="))
        XCTAssertThrowsError(try c.verify(serverFinal: "e=invalid-proof"))
    }

    func testSCRAMRejectsHostileServerFirst() {
        var c = SCRAMClient(user: "", password: "x", clientNonce: "abc")
        XCTAssertThrowsError(try c.clientFinal(serverFirst: "r=zzz123,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"), "nonce must extend the client's")
        XCTAssertThrowsError(try c.clientFinal(serverFirst: "r=abc123,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=999999999"), "iteration count bound")
        XCTAssertThrowsError(try c.clientFinal(serverFirst: "r=abc123,s=!!,i=4096"))
        XCTAssertThrowsError(try c.clientFinal(serverFirst: "r=abc"))
    }

    func testChannelBindingChoice() throws {
        let plus = try SCRAMClient.choose(mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"], tls: true, binding: Data([1, 2]))
        XCTAssertEqual(plus.mechanism, "SCRAM-SHA-256-PLUS")
        XCTAssertEqual(plus.gs2, "p=tls-server-end-point,,")
        // Server offers PLUS but no binding could be computed: plain SCRAM with "n", never "y" (that would read as a downgrade).
        XCTAssertEqual(try SCRAMClient.choose(mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"], tls: true, binding: nil).gs2, "n,,")
        XCTAssertEqual(try SCRAMClient.choose(mechanisms: ["SCRAM-SHA-256"], tls: true, binding: Data([1])).gs2, "y,,")
        XCTAssertEqual(try SCRAMClient.choose(mechanisms: ["SCRAM-SHA-256"], tls: false, binding: nil).gs2, "n,,")
        XCTAssertThrowsError(try SCRAMClient.choose(mechanisms: ["OAUTHBEARER"], tls: true, binding: nil))
        // The binding goes into c=: base64("p=tls-server-end-point,," + hash).
        var c = SCRAMClient(user: "", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO", gs2Header: plus.gs2, channelBinding: Data([1, 2]))
        let final = try c.clientFinal(serverFirst: serverFirst)
        XCTAssertTrue(final.hasPrefix("c=" + (Data("p=tls-server-end-point,,".utf8) + Data([1, 2])).base64EncodedString() + ","), final)
    }

    func testCertificateSignatureAlgorithm() {
        // SEQUENCE { SEQUENCE {} (tbs), SEQUENCE { OID 1.2.840.113549.1.1.11 }, BIT STRING }
        let oid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        let body: [UInt8] = [0x30, 0x00, 0x30, UInt8(oid.count)] + oid + [0x03, 0x01, 0x00]
        let der = Data([0x30, UInt8(body.count)] + body)
        XCTAssertEqual(WireCrypto.signatureAlgorithmOID(der), "1.2.840.113549.1.1.11")
        XCTAssertEqual(WireCrypto.tlsServerEndPoint(certificate: der), WireCrypto.sha256(der))
        XCTAssertNil(WireCrypto.signatureAlgorithmOID(Data([0x30, 0x7F, 0x30])), "truncated certificates are refused")
    }

    func testMD5Password() {
        XCTAssertEqual(PGPassword.md5(user: "bob", password: "secret", salt: Data([1, 2, 3, 4])), "md5f21dfe33ff3a9e03dbc3e008251fe5cc")
    }

    private let login = PGConnection.Login(user: "bob", password: "pencil", database: "shop", applicationName: "Test")

    func testSCRAMStartupExchange() throws {
        var mechanisms = ByteWriter(); mechanisms.cString("SCRAM-SHA-256"); mechanisms.u8(0)
        let server = PGServer.auth(10, mechanisms.data) + PGServer.auth(11, Data(serverFirst.utf8))
            + PGServer.auth(12, Data("v=3HO6Qt1M4MKJrmlKaoOqLAI0/0TV0HZe7J9H3MBtSOg=".utf8)) + PGServer.authOK
            + PGServer.message("S", Data("server_version\u{0}17.2\u{0}".utf8)) + PGServer.backendKey(42) + PGServer.ready()
        let t = ScriptedTransport(server)
        let c = try PGConnection(transport: t, login: login, limits: WireLimits(), scramNonce: "rOprNGfwEbeRWgbNEkqO")
        XCTAssertEqual(c.processID, 42)
        XCTAssertEqual(c.serverParameters["server_version"], "17.2")
        let startup = String(decoding: t.sent, as: UTF8.self)
        XCTAssertTrue(startup.contains("user\u{0}bob\u{0}database\u{0}shop\u{0}"))
        let sent = try frontendMessages(t.sent)
        XCTAssertEqual(sent.count, 2)
        var initial = ByteWriter(); initial.cString("SCRAM-SHA-256"); let first = Data("n,,n=,r=rOprNGfwEbeRWgbNEkqO".utf8); initial.i32BE(Int32(first.count)); initial.append(first)
        XCTAssertEqual(sent[0].1, initial.data)
        XCTAssertEqual(String(decoding: sent[1].1, as: UTF8.self),
                       "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=qvT2SWdEH5Q06albL+hjSYuUhCG7VndFyzIb7CK4n9k=")
    }

    func testSCRAMServerMustProveItself() {
        var mechanisms = ByteWriter(); mechanisms.cString("SCRAM-SHA-256"); mechanisms.u8(0)
        // AuthenticationOk without SASLFinal: refused.
        let server = PGServer.auth(10, mechanisms.data) + PGServer.auth(11, Data(serverFirst.utf8)) + PGServer.session
        XCTAssertThrowsError(try PGConnection(transport: ScriptedTransport(server), login: login, limits: WireLimits(), scramNonce: "rOprNGfwEbeRWgbNEkqO")) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("without proving") ?? false, "\($0)")
        }
    }

    func testMD5AndCleartextAuthentication() throws {
        let t = ScriptedTransport(PGServer.auth(5, Data([1, 2, 3, 4])) + PGServer.session)
        _ = try PGConnection(transport: t, login: .init(user: "bob", password: "secret", database: "d"), limits: WireLimits())
        let sent = try frontendMessages(t.sent)
        XCTAssertEqual(sent.first?.0, "p")
        XCTAssertEqual(sent.first?.1, Data("md5f21dfe33ff3a9e03dbc3e008251fe5cc\u{0}".utf8))
        // Clear text only over TLS.
        let plain = ScriptedTransport(PGServer.auth(3) + PGServer.session)
        XCTAssertThrowsError(try PGConnection(transport: plain, login: login, limits: WireLimits())) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("clear text") ?? false)
        }
        XCTAssertTrue(try frontendMessages(plain.sent).isEmpty, "no password was sent")
        let tls = ScriptedTransport(PGServer.auth(3) + PGServer.session, tls: true)
        _ = try PGConnection(transport: tls, login: login, limits: WireLimits())
        XCTAssertEqual(try frontendMessages(tls.sent).first?.1, Data("pencil\u{0}".utf8))
        // Unsupported methods say which.
        XCTAssertThrowsError(try PGConnection(transport: ScriptedTransport(PGServer.auth(7)), login: login, limits: WireLimits())) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("GSSAPI") ?? false)
        }
    }

    func testStartupErrorResponse() {
        let server = PGServer.fields("E", [("S", "FATAL"), ("C", "28P01"), ("M", "password authentication failed for user \"bob\"")])
        XCTAssertThrowsError(try PGConnection(transport: ScriptedTransport(server), login: login, limits: WireLimits())) {
            XCTAssertEqual(($0 as? WireError)?.message, "PostgreSQL: password authentication failed for user \"bob\" (SQLSTATE 28P01)")
            XCTAssertEqual(($0 as? WireError)?.code, "28P01")
        }
    }

    func testExtendedQueryDecodesBinaryValues() throws {
        let columns: [(String, Int32)] = [("id", PGType.int4), ("amount", PGType.numeric), ("placed", PGType.date), ("note", PGType.text),
                                          ("flag", PGType.bool), ("span", PGType.interval), ("uid", PGType.uuid), ("at", PGType.timestamptz)]
        // 120.50: 2 digits, weight 0, positive, scale 2: 0120 5000.
        let numeric: Data = [2, 0, 0, 2, 120, 5000].reduce(Data()) { $0 + PGServer.be($1, 2) }
        // 2024-01-02 is 8767 days after 2000-01-01; 1 day 2 hours = 7,200,000,000 µs + 1 day + 0 months.
        var interval = PGServer.be(7_200_000_000, 8)
        interval += PGServer.be(1, 4)
        interval += PGServer.be(0, 4)
        let uuid = Data(hex: "a0eebc999c0b4ef8bb6d6bb9bd380a11") ?? Data()
        let cells1: [Data?] = [PGServer.be(1, 4), numeric, PGServer.be(8767, 4), Data("rush".utf8), Data([1]), interval, uuid, PGServer.be(0, 8)]
        let row1 = PGServer.dataRow(cells1)
        let row2 = PGServer.dataRow([PGServer.be(2, 4), nil, nil, nil, nil, nil, nil, nil])
        let notice = PGServer.fields("N", [("S", "NOTICE"), ("M", "hello")])
        var server: Data = PGServer.session
        server += PGServer.message("1", Data())
        server += PGServer.message("t", PGServer.be(0, 2))
        server += PGServer.rowDescription(columns)
        server += PGServer.ready()
        server += PGServer.message("2", Data())
        server += notice
        server += row1
        server += row2
        server += PGServer.message("C", Data("SELECT 2\u{0}".utf8))
        server += PGServer.ready()
        let t = ScriptedTransport(server)
        var notices: [String] = []
        let c = try PGConnection(transport: t, login: login, limits: WireLimits(), notice: { notices.append($0) })
        let r = try c.query("select …", parameters: [], limit: nil)
        XCTAssertEqual(r.columns.map(\.name), ["id", "amount", "placed", "note", "flag", "span", "uid", "at"])
        let types: [MType] = r.columns.map { $0.type }
        XCTAssertEqual(types, [.nullable(.number(.int32)), .nullable(.number(.decimal)), .nullable(.date), .nullable(.text),
                                               .nullable(.logical), .nullable(.duration), .nullable(.text), .nullable(.datetimezone)])
        XCTAssertEqual(r.cells.map { show($0[0]) }, ["1", "120.5", "#date(2024, 1, 2)", "rush", "true", "#duration(1, 2, 0, 0)",
                                                     "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "#datetimezone(2000, 1, 1, 0, 0, 0, 0, 0)"])
        XCTAssertEqual(r.cells.map { show($0[1]) }, ["2", "null", "null", "null", "null", "null", "null", "null"])
        XCTAssertEqual(notices, ["PostgreSQL NOTICE: hello"])
        // Parse + Describe + Sync, then Bind asking for binary results, Execute, Sync.
        let sent = try frontendMessages(t.sent).map(\.0)
        XCTAssertEqual(sent, ["P", "D", "S", "B", "E", "S"])
        let bind = try XCTUnwrap(try frontendMessages(t.sent).first { $0.0 == "B" }?.1)
        XCTAssertEqual(bind.suffix(18), PGServer.be(8, 2) + (0..<8).reduce(Data()) { d, _ in d + PGServer.be(1, 2) }, "eight binary result formats")
    }

    func testQueryErrorWaitsForReadyThenThrows() throws {
        let server = PGServer.session + PGServer.fields("E", [("S", "ERROR"), ("C", "42P01"), ("M", "relation \"x\" does not exist")]) + PGServer.ready()
        let c = try PGConnection(transport: ScriptedTransport(server), login: login, limits: WireLimits())
        XCTAssertThrowsError(try c.query("select * from x", parameters: [], limit: nil)) {
            XCTAssertEqual(($0 as? WireError)?.message, "PostgreSQL: relation \"x\" does not exist (SQLSTATE 42P01)")
        }
    }

    func testParameterCountMustMatch() throws {
        let server = PGServer.session + PGServer.message("1", Data()) + PGServer.message("t", PGServer.be(1, 2) + PGServer.be(25, 4))
            + PGServer.message("n", Data()) + PGServer.ready()
        let c = try PGConnection(transport: ScriptedTransport(server), login: login, limits: WireLimits())
        XCTAssertThrowsError(try c.query("select $1", parameters: [], limit: nil)) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("1 parameter") ?? false, "\($0)")
        }
    }

    func testReadsAreBounded() throws {
        var limits = WireLimits()
        limits.maxMessageBytes = 1024
        // A length field far past the limit is refused before anything is allocated.
        var huge = ByteWriter(); huge.u8(UInt8(ascii: "R")); huge.i32BE(Int32.max)
        XCTAssertThrowsError(try PGConnection(transport: ScriptedTransport(huge.data), login: login, limits: limits)) {
            XCTAssertTrue(($0 as? WireError)?.message.contains("limit") ?? false, "\($0)")
        }
        // A negative length.
        var negative = ByteWriter(); negative.u8(UInt8(ascii: "R")); negative.i32BE(-5)
        XCTAssertThrowsError(try PGConnection(transport: ScriptedTransport(negative.data), login: login, limits: limits))
        // A cell longer than its message, and a column count that disagrees with the description.
        XCTAssertThrowsError(try PGMessage.dataRow(PGServer.be(1, 2) + PGServer.be(1000, 4) + Data([1, 2]), columns: 1))
        XCTAssertThrowsError(try PGMessage.dataRow(PGServer.be(3, 2), columns: 1))
        XCTAssertThrowsError(try PGMessage.rowDescription(PGServer.be(5000, 2), maxColumns: 4096))
        // The total result size is capped.
        limits.maxResultBytes = 10
        var rows = RowCollector(fields: [PGMessage.Field(name: "a", typeOID: PGType.text, format: 0)], limits: limits)
        XCTAssertNoThrow(try rows.add(PGServer.be(1, 2) + PGServer.be(2, 4) + Data("ab".utf8)))
        XCTAssertThrowsError(try rows.add(PGServer.be(1, 2) + PGServer.be(2, 4) + Data("ab".utf8)))
        // A truncated stream is an error, not a hang or a crash.
        XCTAssertThrowsError(try PGConnection(transport: ScriptedTransport(PGServer.authOK.prefix(6)), login: login, limits: limits))
    }

    func testNumericBinary() {
        func numeric(_ weight: Int64, _ sign: Int64, _ digits: [Int64]) -> MValue {
            PGType.numericBinary(PGServer.be(Int64(digits.count), 2) + PGServer.be(weight, 2) + PGServer.be(sign, 2) + PGServer.be(4, 2)
                                 + digits.reduce(Data()) { $0 + PGServer.be($1, 2) })
        }
        XCTAssertEqual(show(numeric(1, 0, [1234, 5678, 9000])), "12345678.9")
        XCTAssertEqual(show(numeric(-1, 0x4000, [1])), "-0.0001")
        XCTAssertEqual(show(numeric(2, 0, [1])), "100000000")
        XCTAssertEqual(show(numeric(0, 0, [])), "0")
        XCTAssertEqual(show(numeric(0, 0, [10_000])), "<error>", "digits are base 10000")
        XCTAssertEqual(show(PGType.numericBinary(Data([0, 5]))), "<error>", "truncated")
    }

    func testTextFormat() {
        XCTAssertEqual(show(PGType.decodeText(PGType.timestamptz, "2024-01-02 03:04:05+02")), "#datetimezone(2024, 1, 2, 3, 4, 5, 2, 0)")
        // 03:04:05.5 at +02:00 is 01:04:05.5 UTC.
        guard case .datetimezone(let instant, 120) = PGType.decodeText(PGType.timestamptz, "2024-01-02 03:04:05.5+02") else { return XCTFail("not a datetimezone") }
        XCTAssertEqual(instant.timeIntervalSince1970, 1_704_157_445.5, accuracy: 0.0001)
        XCTAssertEqual(show(PGType.decodeText(PGType.timestamp, "2024-01-02 03:04:05")), "#datetime(2024, 1, 2, 3, 4, 5)")
        XCTAssertEqual(show(PGType.decodeText(PGType.interval, "1 year 2 mons 3 days 04:05:06")), "#duration(423, 4, 5, 6)")
        XCTAssertEqual(show(PGType.decodeText(PGType.interval, "-1 mons")), "#duration(-30, 0, 0, 0)")
        XCTAssertEqual(show(PGType.decodeText(PGType.bytea, "\\x01ff")), "<binary 2>")
        XCTAssertEqual(show(PGType.decodeText(PGType.bool, "t")), "true")
        XCTAssertEqual(show(PGType.decodeText(PGType.int8, "-42")), "-42")
        XCTAssertEqual(show(PGType.decodeText(PGType.date, "infinity")), "<error>")
        XCTAssertEqual(show(PGType.decodeBinary(PGType.date, PGServer.be(Int64(Int32.max), 4))), "<error>")
        XCTAssertEqual(show(PGType.decodeBinary(PGType.int4, Data([1, 2]))), "<error>", "wrong width")
    }

    func testServerAddress() throws {
        XCTAssertEqual(try ServerAddress.parse("db.example.com", defaultPort: 5432), ServerAddress(host: "db.example.com", port: 5432))
        XCTAssertEqual(try ServerAddress.parse("db:6543", defaultPort: 5432), ServerAddress(host: "db", port: 6543))
        XCTAssertEqual(try ServerAddress.parse("db,1433", defaultPort: 5432), ServerAddress(host: "db", port: 1433))
        XCTAssertEqual(try ServerAddress.parse("[::1]:5433", defaultPort: 5432), ServerAddress(host: "::1", port: 5433))
        XCTAssertEqual(try ServerAddress.parse("::1", defaultPort: 5432), ServerAddress(host: "::1", port: 5432))
        XCTAssertThrowsError(try ServerAddress.parse("db:0", defaultPort: 5432))
        XCTAssertThrowsError(try ServerAddress.parse("db:99999", defaultPort: 5432))
        XCTAssertThrowsError(try ServerAddress.parse(" ", defaultPort: 5432))
    }
}
