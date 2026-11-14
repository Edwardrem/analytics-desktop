import Foundation

/// MySQL client/server protocol pieces (MySQL 5.7+, 8.x and MariaDB): capability flags, the handshake, scrambles,
/// OK/ERR packets and column definitions.
enum MySQLProtocol {
    static let longPassword: UInt32 = 0x1, longFlag: UInt32 = 0x4, connectWithDB: UInt32 = 0x8, protocol41: UInt32 = 0x200
    static let ssl: UInt32 = 0x800, transactions: UInt32 = 0x2000, secureConnection: UInt32 = 0x8000
    static let multiResults: UInt32 = 0x20000, psMultiResults: UInt32 = 0x40000, pluginAuth: UInt32 = 0x80000
    static let pluginAuthLenencData: UInt32 = 0x200000
    static let serverMoreResults: UInt16 = 0x0008
    /// utf8mb4_general_ci: known to MySQL 5.5+ and MariaDB.
    static let charset: UInt8 = 45
    static let maxPacket: UInt32 = 1 << 24

    /// The capabilities this client asks for, limited to what the server offers.
    static func clientCapabilities(server: UInt32, tls: Bool) -> UInt32 {
        var c = longPassword | longFlag | connectWithDB | protocol41 | transactions | secureConnection | multiResults
            | psMultiResults | pluginAuth | pluginAuthLenencData
        if tls { c |= ssl }
        return c & (server | ssl)
    }

    /// One wire packet: 3-byte length, sequence number, payload.
    static func packet(_ payload: Data, sequence: UInt8) -> Data {
        var w = ByteWriter()
        w.uintLE(UInt64(payload.count), 3)
        w.u8(sequence)
        w.append(payload)
        return w.data
    }

    // MARK: Handshake

    struct Handshake: Equatable {
        var serverVersion: String
        var connectionID: UInt32
        var capabilities: UInt32
        /// The 20-byte scramble seed.
        var salt: Data
        var plugin: String
        var isMariaDB: Bool { serverVersion.lowercased().contains("mariadb") }
    }

    static func handshake(_ payload: Data) throws -> Handshake {
        var r = ByteReader(payload, what: "server greeting")
        let version = try r.u8()
        if version == 0xFF { throw try error(payload) }
        guard version == 10 else { throw WireError("The server speaks MySQL protocol version \(version); only version 10 is supported.") }
        let serverVersion = try r.cText()
        let id = try r.u32LE()
        var salt = try r.bytes(8)
        try r.skip(1)
        var caps = UInt32(try r.u16LE())
        var plugin = "mysql_native_password"
        if r.remaining > 0 {
            try r.skip(3) // charset, status
            caps |= UInt32(try r.u16LE()) << 16
            let authLength = Int(try r.u8())
            try r.skip(10)
            if caps & secureConnection != 0 {
                let n = max(13, authLength - 8)
                var part = try r.bytes(min(n, r.remaining))
                if part.last == 0 { part.removeLast() }
                salt += part
            }
            if caps & pluginAuth != 0, r.remaining > 0 {
                let rest = r.rest()
                plugin = String(decoding: rest.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        guard caps & protocol41 != 0, caps & secureConnection != 0 else {
            throw WireError("The MySQL server (\(serverVersion)) is too old: it lacks the 4.1 protocol.")
        }
        return Handshake(serverVersion: serverVersion, connectionID: id, capabilities: caps, salt: salt, plugin: plugin)
    }

    /// The short HandshakeResponse that asks the server to start TLS.
    static func sslRequest(capabilities: UInt32) -> Data {
        var w = ByteWriter()
        w.uintLE(UInt64(capabilities), 4)
        w.uintLE(UInt64(maxPacket), 4)
        w.u8(charset)
        w.append(Data(count: 23))
        return w.data
    }

    static func handshakeResponse(capabilities: UInt32, user: String, auth: Data, database: String, plugin: String) -> Data {
        var w = ByteWriter()
        w.uintLE(UInt64(capabilities), 4)
        w.uintLE(UInt64(maxPacket), 4)
        w.u8(charset)
        w.append(Data(count: 23))
        w.cString(user)
        if capabilities & pluginAuthLenencData != 0 { w.append(lenenc(auth.count)); w.append(auth) } else { w.u8(UInt8(clamping: auth.count)); w.append(auth) }
        if capabilities & connectWithDB != 0 { w.cString(database) }
        if capabilities & pluginAuth != 0 { w.cString(plugin) }
        return w.data
    }

    // MARK: Scrambles

    /// `mysql_native_password`: SHA1(password) XOR SHA1(salt + SHA1(SHA1(password))).
    static func nativeScramble(password: String, salt: Data) -> Data {
        guard !password.isEmpty else { return Data() }
        let p1 = WireCrypto.sha1(Data(password.utf8))
        return WireCrypto.xor(p1, WireCrypto.sha1(salt.prefix(20) + WireCrypto.sha1(p1)))
    }
    /// `caching_sha2_password`: SHA256(password) XOR SHA256(SHA256(SHA256(password)) + salt).
    static func cachingSHA2Scramble(password: String, salt: Data) -> Data {
        guard !password.isEmpty else { return Data() }
        let p1 = WireCrypto.sha256(Data(password.utf8))
        return WireCrypto.xor(p1, WireCrypto.sha256(WireCrypto.sha256(p1) + salt.prefix(20)))
    }

    // MARK: Generic packets

    static func lenenc(_ n: Int) -> Data {
        var w = ByteWriter()
        switch n {
        case ..<251: w.u8(UInt8(n))
        case ..<(1 << 16): w.u8(0xFC); w.uintLE(UInt64(n), 2)
        case ..<(1 << 24): w.u8(0xFD); w.uintLE(UInt64(n), 3)
        default: w.u8(0xFE); w.uintLE(UInt64(n), 8)
        }
        return w.data
    }

    /// A length-encoded integer; nil for 0xFB (NULL).
    static func readLenenc(_ r: inout ByteReader) throws -> UInt64? {
        let first = try r.u8()
        switch first {
        case 0xFB: return nil
        case 0xFC: return try r.uintLE(2)
        case 0xFD: return try r.uintLE(3)
        case 0xFE: return try r.uintLE(8)
        case 0xFF: throw WireError.malformed("length")
        default: return UInt64(first)
        }
    }
    static func readLenencBytes(_ r: inout ByteReader) throws -> Data? {
        guard let n = try readLenenc(&r) else { return nil }
        guard n <= UInt64(r.remaining) else { throw WireError.malformed(r.what) }
        return try r.bytes(Int(n))
    }

    static func error(_ payload: Data) throws -> WireError {
        var r = ByteReader(payload, what: "error packet")
        _ = try r.u8()
        let code = try r.u16LE()
        var state = ""
        if r.remaining >= 6, payload[r.offset] == UInt8(ascii: "#") {
            try r.skip(1)
            state = String(decoding: try r.bytes(5), as: UTF8.self)
        }
        let message = String(decoding: r.rest(), as: UTF8.self)
        return WireError("MySQL: \(message) (error \(code)\(state.isEmpty ? "" : ", SQLSTATE \(state)"))", code: state.isEmpty ? String(code) : state)
    }

    /// True for an EOF packet (0xFE with a payload shorter than 9 bytes); its status flags.
    static func eofStatus(_ payload: Data) -> UInt16? {
        guard payload.first == 0xFE, payload.count < 9 else { return nil }
        var r = ByteReader(payload, what: "EOF packet")
        _ = try? r.u8()
        guard (try? r.u16LE()) != nil, let status = try? r.u16LE() else { return 0 }
        return status
    }
    /// Status flags of an OK packet.
    static func okStatus(_ payload: Data) throws -> UInt16 {
        var r = ByteReader(payload, what: "OK packet")
        _ = try r.u8()
        _ = try readLenenc(&r); _ = try readLenenc(&r)
        return r.remaining >= 2 ? try r.u16LE() : 0
    }

    // MARK: Columns

    struct Column: Equatable {
        var name: String
        var type: UInt8
        var flags: UInt16
        var charset: UInt16
        var length: UInt32
        var decimals: UInt8
        var isUnsigned: Bool { flags & 0x20 != 0 }
        var isBinary: Bool { charset == 63 }
    }

    static func column(_ payload: Data) throws -> Column {
        var r = ByteReader(payload, what: "column definition")
        for _ in 0..<4 { _ = try readLenencBytes(&r) } // catalog, schema, table, original table
        let name = String(decoding: try readLenencBytes(&r) ?? Data(), as: UTF8.self)
        _ = try readLenencBytes(&r) // original name
        _ = try readLenenc(&r)      // length of the fixed fields (0x0c)
        let charset = try r.u16LE()
        let length = try r.u32LE()
        let type = try r.u8()
        let flags = try r.u16LE()
        let decimals = try r.u8()
        return Column(name: name, type: type, flags: flags, charset: charset, length: length, decimals: decimals)
    }
}
