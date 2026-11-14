import XCTest
@testable import FacetQuery

/// TDS protocol tests against hand-built byte fixtures (MS-TDS layouts); no network.
final class SQLServerProtocolTests: XCTestCase {
    // MARK: Fixture helpers

    private func reader(_ payload: [UInt8], maxBytes: Int = 1 << 20) -> TDSMessageReader {
        TDSMessageReader(TDSMemoryInput(TDSWriter.packets(.tabularResult, payload, packetSize: 4096)), maxBytes: maxBytes)
    }
    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private func utf16(_ s: String) -> [UInt8] { TDSText.utf16Bytes(s) }
    private func bVarchar(_ s: String) -> [UInt8] { [UInt8(s.utf16.count)] + utf16(s) }
    private func usVarchar(_ s: String) -> [UInt8] { le16(s.utf16.count) + utf16(s) }
    private let latin1: [UInt8] = [0x09, 0x04, 0xD0, 0x00, 0x34]
    private func column(_ name: String, _ typeInfo: [UInt8], nullable: Bool = true) -> [UInt8] {
        le32(0) + le16(nullable ? 1 : 0) + typeInfo + bVarchar(name)
    }
    private func done(status: Int = 0x10, count: Int) -> [UInt8] { [0xFD] + le16(status) + le16(0xC1) + le32(count) + le32(0) }
    /// Decode one value of a type from its wire bytes.
    private func value(_ typeInfo: [UInt8], _ bytes: [UInt8]) throws -> MValue {
        let r = reader(typeInfo + bytes)
        return try TDSValues.read(try TDSTypeInfo.read(r), r)
    }
    private func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Double = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!.addingTimeInterval(s)
    }

    // MARK: Packets

    func testPacketsSplitAtThePacketSizeAndMarkTheLastOne() {
        let payload = [UInt8](repeating: 7, count: 5000)
        let bytes = TDSWriter.packets(.sqlBatch, payload, packetSize: 4096, resetConnection: true)
        // 4088 + 912 payload bytes → two packets.
        XCTAssertEqual(bytes.count, 5000 + 16)
        XCTAssertEqual(Array(bytes[0..<8]), [0x01, 0x08, 0x10, 0x00, 0, 0, 1, 0])          // reset, not EOM, length 4096
        XCTAssertEqual(Array(bytes[4096..<4104]), [0x01, 0x01, 0x03, 0x98, 0, 0, 2, 0])    // EOM, length 920
    }

    func testReaderJoinsPacketsAndRejectsBadHeaders() throws {
        let cut = Array(TDSWriter.packets(.tabularResult, [1, 2, 3], packetSize: 4096).prefix(9))
        XCTAssertThrowsError(try TDSMessageReader(TDSMemoryInput(cut), maxBytes: 100).bytes(3), "a packet cut short")
        let tooShort: [UInt8] = [0x04, 0x01, 0x00, 0x04, 0, 0, 1, 0]
        XCTAssertThrowsError(try TDSMessageReader(TDSMemoryInput(tooShort), maxBytes: 100).u8())
        let wrongType: [UInt8] = [0x12, 0x01, 0x00, 0x09, 0, 0, 1, 0, 0xFD]
        XCTAssertThrowsError(try TDSMessageReader(TDSMemoryInput(wrongType), maxBytes: 100).u8())
        let a = TDSWriter.packets(.tabularResult, [1, 2], packetSize: 4096)
        var first = a; first[1] = 0                                                           // not end of message
        let r = TDSMessageReader(TDSMemoryInput(first + TDSWriter.packets(.tabularResult, [3], packetSize: 4096)), maxBytes: 100)
        XCTAssertEqual(try r.bytes(3), [1, 2, 3])
        XCTAssertTrue(try r.isAtEnd)
        XCTAssertThrowsError(try reader([1, 2, 3]).bytes(4), "reading past the end of the message fails")
        XCTAssertThrowsError(try reader([UInt8](repeating: 0, count: 200), maxBytes: 100).bytes(1), "the message size is bounded")
    }

    // MARK: PRELOGIN

    func testPreloginRequestLayout() {
        let p = TDSPrelogin.request(encryption: .on, fedAuth: true)
        // Six options × 5 header bytes + terminator = 31; data follows in order.
        XCTAssertEqual(Array(p[0..<5]), [0x00, 0x00, 31, 0x00, 6])
        XCTAssertEqual(Array(p[5..<10]), [0x01, 0x00, 37, 0x00, 1])
        XCTAssertEqual(Array(p[25..<30]), [0x06, 0x00, 44, 0x00, 1])
        XCTAssertEqual(p[30], 0xFF)
        XCTAssertEqual(p[37], 0x01, "ENCRYPT_ON")
        XCTAssertEqual(p.count, 45)
        XCTAssertEqual(p[44], 0x01, "FEDAUTHREQUIRED")
    }

    func testPreloginResponseParseAndBounds() throws {
        let response: [UInt8] = [0x00, 0x00, 16, 0x00, 6, 0x01, 0x00, 22, 0x00, 1, 0x06, 0x00, 23, 0x00, 1, 0xFF,
                                 16, 0, 0x10, 0x00, 0, 0, 0x03, 0x01]
        let r = try TDSPrelogin.parse(response)
        XCTAssertEqual(r.encryption, 3)
        XCTAssertTrue(r.fedAuthRequired)
        XCTAssertEqual(r.serverVersion.major, 16)
        XCTAssertEqual(r.serverVersion.build, 4096)
        XCTAssertThrowsError(try TDSPrelogin.parse([0x01, 0x00, 0x40, 0x00, 1, 0xFF]), "an option outside the payload")
        XCTAssertThrowsError(try TDSPrelogin.parse([0x01, 0x00, 0x06]), "no terminator")
    }

    // MARK: LOGIN7

    func testPasswordObfuscation() {
        // 'a' = 61 00: nibbles swapped 16 00, XOR A5 → B3 A5.
        XCTAssertEqual(TDSLogin7.scramble("a"), [0xB3, 0xA5])
    }

    func testLogin7SQLAuthenticationLayout() {
        var l = TDSLogin7()
        l.hostName = "mac"; l.userName = "sa"; l.password = "a"; l.appName = "App"; l.serverName = "srv"
        l.libraryName = "Lib"; l.database = "db"
        let b = l.encode()
        XCTAssertEqual(Array(b[0..<4]), le32(b.count))
        XCTAssertEqual(Array(b[4..<8]), [0x04, 0x00, 0x00, 0x74], "TDS 7.4")
        XCTAssertEqual(b[27], 0x00, "no feature extension")
        // Host name at offset 94, 3 characters; user name right after it.
        XCTAssertEqual(Array(b[36..<40]), le16(94) + le16(3))
        XCTAssertEqual(Array(b[40..<44]), le16(100) + le16(2))
        XCTAssertEqual(Array(b[44..<48]), le16(104) + le16(1))
        XCTAssertEqual(Array(b[104..<106]), [0xB3, 0xA5])
        XCTAssertEqual(Array(b[94..<100]), utf16("mac"))
        // Database is the ninth field (offset 68 in the fixed part).
        let dbOffset = Int(b[68]) | Int(b[69]) << 8
        XCTAssertEqual(Array(b[dbOffset..<dbOffset + 4]), utf16("db"))
    }

    func testLogin7AccessTokenUsesTheFedAuthFeature() {
        var l = TDSLogin7()
        l.hostName = ""; l.userName = "ignored"; l.password = "ignored"; l.appName = ""; l.serverName = ""; l.libraryName = ""
        l.accessToken = "tok"; l.fedAuthEcho = true
        let b = l.encode()
        XCTAssertEqual(b[27], 0x10, "fExtension")
        XCTAssertEqual(Array(b[42..<44]), [0, 0], "no user name is sent")
        let ibExtension = Int(b[56]) | Int(b[57]) << 8
        XCTAssertEqual(Array(b[58..<60]), le16(4))
        let feature = Int(b[ibExtension]) | Int(b[ibExtension + 1]) << 8
        // FEDAUTH, length 1 + 4 + 6, options (security token << 1 | echo), token length, UTF-16 token, terminator.
        XCTAssertEqual(Array(b[feature...]), [0x02] + le32(11) + [0x03] + le32(6) + utf16("tok") + [0xFF])
    }

    // MARK: Requests

    func testSqlBatchAndRpcLayout() {
        let batch = TDSRequest.sqlBatch("go")
        XCTAssertEqual(Array(batch[0..<6]), le32(22) + [18, 0])
        XCTAssertEqual(Array(batch[22...]), utf16("go"))
        let rpc = TDSRequest.executeSQL("x", parameters: [TDSParameter(name: "@n", value: .bigint(5))], collation: TDSRequest.defaultCollation)
        XCTAssertEqual(Array(rpc[22..<28]), [0xFF, 0xFF, 10, 0, 0, 0], "sp_executesql by id")
        let stmt = bVarchar("@stmt") + [0, 0xE7, 0xFF, 0xFF] + latin1 + le32(2) + le32(0) + le32(2) + utf16("x") + le32(0)
        XCTAssertEqual(Array(rpc[28..<28 + stmt.count]), stmt)
        let tail = bVarchar("@n") + [0, 0x26, 8, 8, 5, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(Array(rpc.suffix(tail.count)), tail)
        XCTAssertEqual(TDSParameter(name: "@d", value: .datetime2(days: 0, ticks: 0)).declaration, "@d datetime2(7)")
    }

    // MARK: Token stream

    func testResultSetWithRowNbcRowAndDone() throws {
        var s: [UInt8] = [0x81] + le16(3)
        s += column("Id", [0x26, 4])
        s += column("Name", [0xE7] + le16(100) + latin1)
        s += column("Amount", [0x6A, 9, 18, 2])
        s += [0xD1, 4] + le32(1) + le16(6) + utf16("Ann") + [5, 1] + le32(12345)
        s += [0xD1, 4] + le32(2) + le16(4) + utf16("Bé") + [5, 0] + le32(50)
        s += [0xD2, 0b110, 4] + le32(3)
        s += done(count: 3)
        let r = try TDSTokenParser.parse(reader(s))
        XCTAssertEqual(r.resultSets.count, 1)
        let set = try XCTUnwrap(r.resultSets.first)
        XCTAssertEqual(set.columns.map(\.name), ["Id", "Name", "Amount"])
        XCTAssertEqual(set.columns.map(\.type.mType), [.number(.int32), .text, .number(.decimal)])
        XCTAssertEqual(set.values[1].map(\.textValue), ["Ann", "Bé", nil])
        XCTAssertEqual(set.values[2].map(\.numberValue), [123.45, -0.5, nil])
        XCTAssertEqual(r.rowsAffected, 3)
    }

    func testErrorInfoEnvChangeAndLoginAck() throws {
        let text = "Invalid object name 'x'."
        let body = le32(208) + [1, 16] + usVarchar(text) + bVarchar("srv") + bVarchar("") + le32(1)
        let info = le32(5701) + [2, 0] + usVarchar("Changed database context to 'db'.") + bVarchar("srv") + bVarchar("") + le32(1)
        let ack = [1, 0x74, 0, 0, 4] + bVarchar("Microsoft SQL Server") + [16, 0, 0x10, 0]
        var s: [UInt8] = [0xE3] + le16(1 + 5 + 1) + [1] + bVarchar("db") + [0]
        s += [0xAB] + le16(info.count) + info
        s += [0xAD] + le16(ack.count) + ack
        s += [0xE3] + le16(1 + 9 + 9) + [4] + bVarchar("8000") + bVarchar("4096")
        s += [0xE3] + le16(1 + 1 + 5 + 1) + [7, 5] + latin1 + [0]
        s += [0xAE, 0x02] + le32(0) + [0xFF]
        s += [0xAA] + le16(body.count) + body
        s += done(status: 2, count: 0)
        let r = try TDSTokenParser.parse(reader(s))
        XCTAssertEqual(r.database, "db")
        XCTAssertEqual(r.packetSize, 8000)
        XCTAssertEqual(r.collation, latin1)
        XCTAssertEqual(r.loginAck?.tdsVersion, 0x7400_0004)
        XCTAssertEqual(r.loginAck?.program, "Microsoft SQL Server")
        XCTAssertEqual(r.acknowledgedFeatures, [0x02])
        XCTAssertEqual(r.infos.first?.number, 5701)
        XCTAssertEqual(r.failure?.message, text)
        XCTAssertEqual(r.failure?.number, 208)
    }

    func testRoutingEnvChange() throws {
        let host = "x.tr1.westus.worker.database.windows.net"
        let value: [UInt8] = [0] + le16(11000) + usVarchar(host)
        let s: [UInt8] = [0xE3] + le16(1 + 2 + value.count + 2) + [20] + le16(value.count) + value + [0, 0] + done(status: 0, count: 0)
        let r = try TDSTokenParser.parse(reader(s))
        XCTAssertEqual(r.routing?.host, host)
        XCTAssertEqual(r.routing?.port, 11000)
    }

    func testHostileLengthsFail() {
        XCTAssertThrowsError(try TDSTokenParser.parse(reader([0x81] + le16(5000))), "more than 4096 columns")
        XCTAssertThrowsError(try TDSTokenParser.parse(reader([0xD1])), "a row before metadata")
        XCTAssertThrowsError(try TDSTokenParser.parse(reader([0x42])), "unknown token")
        let message = le32(1) + [1, 16] + usVarchar("hi") + bVarchar("") + bVarchar("") + le32(1)
        XCTAssertThrowsError(try TDSTokenParser.parse(reader([0xAA] + le16(message.count + 3) + message + [0, 0, 0])), "declared length disagrees")
        // A PLP value claiming 2 GB, and a short value longer than its column.
        XCTAssertThrowsError(try value([0xE7, 0xFF, 0xFF] + latin1, le32(0) + le32(0x8000)))
        XCTAssertThrowsError(try value([0xE7] + le16(10) + latin1, le16(9000)))
        XCTAssertThrowsError(try value([0x26, 4], [9] + [UInt8](repeating: 0, count: 9)), "INTN of 9 bytes")
        XCTAssertThrowsError(try value([0x2A, 9], [8]), "time scale above 7")
    }

    // MARK: Types

    func testIntegerBitFloatMoneyAndDecimal() throws {
        XCTAssertEqual(try value([0x30], [200]).numberValue, 200)
        XCTAssertEqual(try value([0x34], le16(0xFFFE)).numberValue, -2)
        XCTAssertEqual(try value([0x7F], [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).numberValue, -1)
        XCTAssertEqual(try value([0x26, 8], [0]).isNull, true)
        XCTAssertEqual(try value([0x68, 1], [1, 1]).logicalValue, true)
        XCTAssertEqual(try value([0x3B], Array(withUnsafeBytes(of: Float(1.5).bitPattern.littleEndian, Array.init))).numberValue, 1.5)
        XCTAssertEqual(try value([0x6D, 8], [8] + Array(withUnsafeBytes(of: (0.1).bitPattern.littleEndian, Array.init))).numberValue, 0.1)
        // money: high then low 32-bit halves of value × 10 000. -1 → -0.0001.
        XCTAssertEqual(try value([0x3C], [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).numberValue, -0.0001)
        XCTAssertEqual(try value([0x6E, 8], [8] + le32(0) + le32(25_000)).numberValue, 2.5)
        XCTAssertEqual(try value([0x7A], le32(10_000)).numberValue, 1)
        // decimal(38, 4): 12345678901234567890 / 10^4 needs more than 64 bits of magnitude bytes.
        let magnitude: [UInt8] = [0xD2, 0x0A, 0x1F, 0xEB, 0x8C, 0xA9, 0x54, 0xAB, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(try value([0x6C, 17, 38, 4], [17, 1] + magnitude).numberValue ?? 0, 1_234_567_890_123_456.789, accuracy: 0.001)
        XCTAssertEqual(try value([0x6A, 5, 9, 0], [5, 0] + le32(7)).numberValue, -7)
    }

    func testDateAndTimeTypes() throws {
        // datetime: days since 1900-01-01 and 1/300 s ticks (300 = 1 s; 1 tick = 3.33 ms, shown as .003).
        guard case .datetime(let dt)? = Optional(try value([0x3D], le32(1) + le32(301))) else { return XCTFail() }
        XCTAssertEqual(dt.timeIntervalSince1970, utcDate(1900, 1, 2, 0, 0, 1.003).timeIntervalSince1970, accuracy: 0.0001)
        guard case .datetime(let small)? = Optional(try value([0x6F, 4], [4] + le16(2) + le16(90))) else { return XCTFail() }
        XCTAssertEqual(small, utcDate(1900, 1, 3, 1, 30))
        // date: 3 bytes of days since 0001-01-01; 719 162 days is 1970-01-01.
        guard case .date(let d)? = Optional(try value([0x28], [3, 0x3A, 0xF9, 0x0A])) else { return XCTFail() }
        XCTAssertEqual(d, utcDate(1970, 1, 1))
        // time(7): 100 ns units, 5 bytes. 36 000 000 000 = 01:00:00.
        guard case .time(let t)? = Optional(try value([0x29, 7], [5, 0x00, 0x68, 0xC4, 0x61, 0x08])) else { return XCTFail() }
        XCTAssertEqual(t, 3600)
        guard case .time(let t0)? = Optional(try value([0x29, 0], [3] + [0x10, 0x0E, 0x00])) else { return XCTFail() }
        XCTAssertEqual(t0, 3600)
        // datetime2(3): 4 time bytes (ms) + date. 1970-01-02 00:00:00.500.
        guard case .datetime(let d2)? = Optional(try value([0x2A, 3], [7] + le32(500) + [0x3B, 0xF9, 0x0A])) else { return XCTFail() }
        XCTAssertEqual(d2.timeIntervalSince1970, 86_400.5, accuracy: 0.000_001)
        // datetimeoffset(0): UTC time + date + offset minutes (+120).
        guard case .datetimezone(let utc, let offset)? = Optional(try value([0x2B, 0], [8, 0x10, 0x0E, 0x00, 0x3A, 0xF9, 0x0A] + le16(120))) else { return XCTFail() }
        XCTAssertEqual(utc, utcDate(1970, 1, 1, 1))
        XCTAssertEqual(offset, 120)
    }

    func testTextBinaryGuidAndLargeValues() throws {
        XCTAssertEqual(try value([0xA7] + le16(10) + latin1, le16(2) + [0x43, 0xE9]).textValue, "Cé", "varchar in code page 1252")
        let utf8Collation: [UInt8] = [0x09, 0x04, 0x00, 0x04, 0x00]               // bit 26: UTF-8
        XCTAssertEqual(try value([0xA7] + le16(10) + utf8Collation, le16(3) + [0x43, 0xC3, 0xA9]).textValue, "Cé")
        XCTAssertEqual(try value([0xA5] + le16(10), le16(2) + [1, 2]).binaryValue, Data([1, 2]))
        XCTAssertTrue(try value([0xE7] + le16(10) + latin1, le16(0xFFFF)).isNull)
        let guid: [UInt8] = [0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        XCTAssertEqual(try value([0x24, 16], [16] + guid).textValue, "00112233-4455-6677-8899-aabbccddeeff")
        // nvarchar(max) in two PLP chunks, unknown total length.
        let plp = [0xFE] + [UInt8](repeating: 0xFF, count: 7) + le32(4) + utf16("ab") + le32(2) + utf16("c") + le32(0)
        XCTAssertEqual(try value([0xE7, 0xFF, 0xFF] + latin1, plp).textValue, "abc")
        XCTAssertTrue(try value([0xF1, 0], [UInt8](repeating: 0xFF, count: 8)).isNull, "null xml")
        // ntext: text pointer, timestamp, then a 4-byte length.
        let ntext = [16] + [UInt8](repeating: 0, count: 16) + [UInt8](repeating: 0, count: 8) + le32(4) + utf16("hi")
        XCTAssertEqual(try value([0x63] + le32(0x7FFF_FFFF) + latin1, ntext).textValue, "hi")
        // sql_variant holding an int: base type 0x38, no properties.
        XCTAssertEqual(try value([0x62] + le32(8016), le32(6) + [0x38, 0] + le32(42)).numberValue, 42)
    }

    // MARK: Addresses

    func testServerAddressForms() throws {
        XCTAssertEqual(try TDSServerAddress("tcp:db.example.com,1500"), TDSServerAddress(host: "db.example.com", port: 1500))
        XCTAssertEqual(try TDSServerAddress(".\\SQLEXPRESS"), TDSServerAddress(host: "localhost", instance: "SQLEXPRESS"))
        XCTAssertEqual(try TDSServerAddress("(local)"), TDSServerAddress(host: "localhost"))
        XCTAssertThrowsError(try TDSServerAddress("db,99999"))
        XCTAssertThrowsError(try TDSServerAddress("a b"))
        XCTAssertTrue(try TDSServerAddress("ws-abc.datawarehouse.fabric.microsoft.com").isMicrosoftCloud)
        XCTAssertFalse(try TDSServerAddress("database.windows.net.example.com").isMicrosoftCloud)
    }

    func testSQLServerBrowserAnswer() throws {
        let text = "ServerName;MAC;InstanceName;OTHER;IsClustered;No;Version;16.0.1000.6;tcp;50000;;ServerName;MAC;InstanceName;SQLEXPRESS;IsClustered;No;Version;16.0.1000.6;tcp;49172;;"
        let answer = [0x05] + le16(text.utf8.count) + Array(text.utf8)
        XCTAssertEqual(try SQLServerBrowser.parsePort(answer, instance: "sqlexpress"), 49172)
        XCTAssertThrowsError(try SQLServerBrowser.parsePort(answer, instance: "missing"))
        XCTAssertThrowsError(try SQLServerBrowser.parsePort([0x05, 0xFF, 0xFF, 0x41], instance: "x"), "length past the datagram")
    }
}
