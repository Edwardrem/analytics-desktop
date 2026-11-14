import Foundation

/// PRELOGIN (MS-TDS 2.2.6.5): the first, unencrypted exchange that negotiates encryption.
enum TDSPrelogin {
    enum Encryption: UInt8 { case off = 0, on = 1, notSupported = 2, required = 3 }

    struct Response: Equatable {
        var encryption: UInt8 = Encryption.notSupported.rawValue
        var fedAuthRequired = false
        var nonce: [UInt8]?
        var serverVersion: (major: Int, minor: Int, build: Int) = (0, 0, 0)
        static func == (a: Response, b: Response) -> Bool {
            a.encryption == b.encryption && a.fedAuthRequired == b.fedAuthRequired && a.nonce == b.nonce
                && a.serverVersion == b.serverVersion
        }
    }

    /// The request payload (without packet headers).
    static func request(encryption: Encryption, fedAuth: Bool) -> [UInt8] {
        var options: [(UInt8, [UInt8])] = [
            (0x00, [0x0F, 0x00, 0x07, 0xD0, 0x00, 0x00]), // client version 15.0.2000
            (0x01, [encryption.rawValue]),
            (0x02, [0x00]),                                // instance: default
            (0x03, [0x00, 0x00, 0x00, 0x00]),              // thread id
            (0x04, [0x00]),                                // MARS off
        ]
        if fedAuth { options.append((0x06, [0x01])) }
        var w = TDSWriter()
        var offset = options.count * 5 + 1
        for (token, data) in options {
            w.u8(token); w.u16be(UInt16(offset)); w.u16be(UInt16(data.count))
            offset += data.count
        }
        w.u8(0xFF)
        for (_, data) in options { w.append(data) }
        return w.bytes
    }

    /// Parse a PRELOGIN response payload. Every option's offset and length is checked against the payload.
    static func parse(_ payload: [UInt8]) throws -> Response {
        var r = Response(), i = 0
        while true {
            guard i < payload.count else { throw TDSError.protocolViolation("PRELOGIN has no terminator") }
            let token = payload[i]
            if token == 0xFF { break }
            guard i + 5 <= payload.count else { throw TDSError.protocolViolation("PRELOGIN option header") }
            let offset = Int(payload[i + 1]) << 8 | Int(payload[i + 2]), length = Int(payload[i + 3]) << 8 | Int(payload[i + 4])
            guard offset + length <= payload.count else { throw TDSError.protocolViolation("PRELOGIN option \(token) out of range") }
            let data = Array(payload[offset..<offset + length])
            switch token {
            case 0x00 where length >= 6:
                r.serverVersion = (Int(data[0]), Int(data[1]), Int(data[2]) << 8 | Int(data[3]))
            case 0x01 where length >= 1: r.encryption = data[0]
            case 0x06 where length >= 1: r.fedAuthRequired = data[0] == 1
            case 0x07 where length == 32: r.nonce = data
            default: break
            }
            i += 5
        }
        return r
    }
}

/// LOGIN7 (MS-TDS 2.2.6.4), with SQL authentication or a Microsoft Entra access token (FEDAUTH feature extension).
struct TDSLogin7 {
    static let tds74: UInt32 = 0x7400_0004
    static let tds80: UInt32 = 0x0800_0000

    var tdsVersion = TDSLogin7.tds74
    var packetSize = UInt32(TDSLimits.requestedPacketSize)
    var hostName = ProcessInfo.processInfo.hostName
    var userName = ""
    var password = ""
    var appName = "Analytics Desktop"
    var serverName = ""
    var libraryName = "Analytics Desktop TDS"
    var database = ""
    /// A Microsoft Entra access token; when set, user name and password are not sent.
    var accessToken: String?
    /// Echo of the server's PRELOGIN FEDAUTHREQUIRED.
    var fedAuthEcho = false
    var readOnlyIntent = false

    /// SQL Server's password obfuscation: swap the nibbles of each UTF-16LE byte, then XOR with 0xA5.
    static func scramble(_ password: String) -> [UInt8] {
        TDSText.utf16Bytes(password).map { b in ((b << 4) | (b >> 4)) ^ 0xA5 }
    }

    func encode() -> [UInt8] {
        let fixedLength = 94
        var data = TDSWriter()
        var offsets: [(UInt16, UInt16)] = []
        func text(_ s: String, scrambled: Bool = false) {
            let units = s.utf16.count
            offsets.append((UInt16(fixedLength + data.count), UInt16(units)))
            data.append(scrambled ? TDSLogin7.scramble(s) : TDSText.utf16Bytes(s))
        }
        let usesToken = accessToken != nil
        text(hostName); text(usesToken ? "" : userName); text(usesToken ? "" : password, scrambled: true); text(appName); text(serverName)
        // Extension: a DWORD holding the offset of the feature extension block, patched below.
        let extensionField = data.count
        offsets.append((UInt16(fixedLength + extensionField), usesToken ? 4 : 0))
        if usesToken { data.u32(0) }
        text(libraryName); text(""); text(database)
        let tailOffset = UInt16(fixedLength + data.count)
        if let token = accessToken {
            data.patchU32(UInt32(fixedLength + data.count), at: extensionField)
            let tokenBytes = TDSText.utf16Bytes(token)
            data.u8(0x02)                                       // FEDAUTH
            data.u32(UInt32(1 + 4 + tokenBytes.count))
            data.u8(0x01 << 1 | (fedAuthEcho ? 1 : 0))          // security token library + echo
            data.u32(UInt32(tokenBytes.count))
            data.append(tokenBytes)
            data.u8(0xFF)
        }
        var w = TDSWriter()
        w.u32(UInt32(fixedLength + data.count))
        w.u32(tdsVersion)
        w.u32(packetSize)
        w.u32(0x0700_0000)                                        // client program version
        w.u32(UInt32(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier))
        w.u32(0)                                                  // connection id
        w.u8(0xE0)                                                // fUseDB | fDatabase fatal | fSetLang
        w.u8(0x03)                                                // fLanguage fatal | ODBC (ANSI defaults)
        w.u8(readOnlyIntent ? 0x20 : 0x00)
        w.u8(usesToken ? 0x10 : 0x00)                             // fExtension
        w.i32(0)                                                  // client time zone
        w.u32(0x0409)                                             // client LCID
        for (i, (offset, length)) in offsets.enumerated() {
            w.u16(offset); w.u16(length)
            if i == offsets.count - 1 {
                w.append([0, 0, 0, 0, 0, 0])                      // client id
                w.u16(tailOffset); w.u16(0)                       // SSPI
                w.u16(tailOffset); w.u16(0)                       // attach database file
                w.u16(tailOffset); w.u16(0)                       // change password
                w.u32(0)                                          // long SSPI
            }
        }
        w.append(data.bytes)
        return w.bytes
    }
}

/// A parameter of `sp_executesql`.
struct TDSParameter: Equatable {
    enum Value: Equatable {
        case null, bigint(Int64), float(Double), bit(Bool), text(String), binary(Data)
        case date(days: Int), time(ticks: UInt64), datetime2(days: Int, ticks: UInt64), datetimeoffset(days: Int, ticks: UInt64, offsetMinutes: Int)
    }
    var name: String
    var value: Value

    var declaration: String {
        let type: String
        switch value {
        case .null, .text: type = "nvarchar(max)"
        case .bigint: type = "bigint"
        case .float: type = "float"
        case .bit: type = "bit"
        case .binary: type = "varbinary(max)"
        case .date: type = "date"
        case .time: type = "time(7)"
        case .datetime2: type = "datetime2(7)"
        case .datetimeoffset: type = "datetimeoffset(7)"
        }
        return name + " " + type
    }
}

/// SQL batch and RPC request payloads.
enum TDSRequest {
    static let defaultCollation: [UInt8] = [0x09, 0x04, 0xD0, 0x00, 0x34] // Latin1_General_CI_AS

    /// ALL_HEADERS with the transaction descriptor header (auto-commit, one outstanding request).
    static func allHeaders(_ w: inout TDSWriter) {
        w.u32(22); w.u32(18); w.u16(2); w.u64(0); w.u32(1)
    }
    static func sqlBatch(_ sql: String) -> [UInt8] {
        var w = TDSWriter()
        allHeaders(&w)
        w.utf16(sql)
        return w.bytes
    }

    /// `sp_executesql @stmt, @params, @p1 = …`.
    static func executeSQL(_ sql: String, parameters: [TDSParameter], collation: [UInt8]) -> [UInt8] {
        var w = TDSWriter()
        allHeaders(&w)
        w.u16(0xFFFF); w.u16(10)                                  // well-known procedure id: sp_executesql
        w.u16(0)                                                  // option flags
        func plp(_ bytes: [UInt8]?) {
            guard let bytes else { w.u64(UInt64.max); return }
            w.u64(UInt64(bytes.count))
            if !bytes.isEmpty { w.u32(UInt32(bytes.count)); w.append(bytes) }
            w.u32(0)
        }
        func nvarcharMax(_ name: String, _ s: String?) {
            w.bVarchar(name); w.u8(0); w.u8(0xE7); w.u16(0xFFFF); w.append(collation)
            plp(s.map(TDSText.utf16Bytes))
        }
        nvarcharMax("@stmt", sql)
        if !parameters.isEmpty {
            nvarcharMax("@params", parameters.map(\.declaration).joined(separator: ", "))
        }
        for p in parameters {
            switch p.value {
            case .null: nvarcharMax(p.name, nil)
            case .text(let s): nvarcharMax(p.name, s)
            default:
                w.bVarchar(p.name); w.u8(0)
                switch p.value {
                case .bigint(let v): w.u8(0x26); w.u8(8); w.u8(8); w.i64(v)
                case .float(let v): w.u8(0x6D); w.u8(8); w.u8(8); w.u64(v.bitPattern)
                case .bit(let b): w.u8(0x68); w.u8(1); w.u8(1); w.u8(b ? 1 : 0)
                case .binary(let d): w.u8(0xA5); w.u16(0xFFFF); plp(Array(d))
                case .date(let days): w.u8(0x28); w.u8(3); dateBytes(days, &w)
                case .time(let ticks): w.u8(0x29); w.u8(7); w.u8(5); timeBytes(ticks, &w)
                case .datetime2(let days, let ticks): w.u8(0x2A); w.u8(7); w.u8(8); timeBytes(ticks, &w); dateBytes(days, &w)
                case .datetimeoffset(let days, let ticks, let offset):
                    w.u8(0x2B); w.u8(7); w.u8(10); timeBytes(ticks, &w); dateBytes(days, &w); w.u16(UInt16(bitPattern: Int16(clamping: offset)))
                case .null, .text: break
                }
            }
        }
        return w.bytes
    }
    private static func dateBytes(_ days: Int, _ w: inout TDSWriter) {
        let d = UInt32(clamping: max(0, days))
        w.u8(UInt8(d & 0xFF)); w.u8(UInt8((d >> 8) & 0xFF)); w.u8(UInt8((d >> 16) & 0xFF))
    }
    private static func timeBytes(_ ticks: UInt64, _ w: inout TDSWriter) {
        for i in 0..<5 { w.u8(UInt8((ticks >> (8 * UInt64(i))) & 0xFF)) }
    }
}
