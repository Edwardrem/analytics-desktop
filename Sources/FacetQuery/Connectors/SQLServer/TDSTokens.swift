import Foundation

struct TDSColumn: Equatable {
    var name: String
    var type: TDSTypeInfo
    var nullable: Bool
}

/// An ERROR or INFO token.
struct TDSServerMessage: Equatable {
    var number: Int
    var state: Int
    var severity: Int
    var text: String
    var server: String
    var procedure: String
    var line: Int
}

struct TDSResultSet {
    var columns: [TDSColumn]
    /// Column-major values.
    var values: [[MValue]]
    var rowCount: Int { values.first?.count ?? 0 }
}

/// Everything one response message carried.
struct TDSResponse {
    var resultSets: [TDSResultSet] = []
    var errors: [TDSServerMessage] = []
    var infos: [TDSServerMessage] = []
    var database: String?
    var packetSize: Int?
    var collation: [UInt8]?
    /// ENVCHANGE routing (Azure SQL gateway redirect).
    var routing: (host: String, port: Int)?
    var loginAck: (tdsVersion: UInt32, program: String)?
    /// FEATUREEXTACK feature ids.
    var acknowledgedFeatures: [UInt8] = []
    var rowsAffected: Int?
    var attentionAcknowledged = false

    /// The first error as a `TDSError`, if any.
    var failure: TDSError? {
        guard let e = errors.first else { return nil }
        return TDSError(kind: .server, message: e.text, number: e.number)
    }
}

/// Parses a token stream (MS-TDS 2.2.7). Unknown tokens are protocol errors: TDS has no generic way to skip them.
enum TDSTokenParser {
    enum Token {
        static let colMetadata: UInt8 = 0x81, row: UInt8 = 0xD1, nbcRow: UInt8 = 0xD2
        static let done: UInt8 = 0xFD, doneProc: UInt8 = 0xFE, doneInProc: UInt8 = 0xFF
        static let error: UInt8 = 0xAA, info: UInt8 = 0xAB, envChange: UInt8 = 0xE3, loginAck: UInt8 = 0xAD
        static let featureExtAck: UInt8 = 0xAE, fedAuthInfo: UInt8 = 0xEE, returnStatus: UInt8 = 0x79, returnValue: UInt8 = 0xAC
        static let order: UInt8 = 0xA9, tabName: UInt8 = 0xA4, colInfo: UInt8 = 0xA5, sspi: UInt8 = 0xED
        static let sessionState: UInt8 = 0xE4, offset: UInt8 = 0x78
    }

    static func parse(_ r: TDSMessageReader) throws -> TDSResponse {
        var response = TDSResponse()
        var columns: [TDSColumn]?
        var current: [[MValue]] = []
        func finishResultSet() {
            if let c = columns { response.resultSets.append(TDSResultSet(columns: c, values: current)) }
            columns = nil; current = []
        }
        while try !r.isAtEnd {
            let token = try r.u8()
            switch token {
            case Token.colMetadata:
                finishResultSet()
                let count = Int(try r.u16())
                if count == 0xFFFF { continue }                       // no metadata
                guard count <= TDSLimits.maxColumns else { throw TDSError.protocolViolation("\(count) columns") }
                var list: [TDSColumn] = []
                list.reserveCapacity(count)
                for _ in 0..<count {
                    _ = try r.u32()                                    // user type
                    let flags = try r.u16()
                    let type = try TDSTypeInfo.read(r)
                    if type.isLongLength {                             // table name parts
                        let parts = Int(try r.u8())
                        for _ in 0..<parts { _ = try r.usVarchar() }
                    }
                    list.append(TDSColumn(name: try r.bVarchar(), type: type, nullable: flags & 0x01 != 0))
                }
                columns = list
                current = [[MValue]](repeating: [], count: count)
            case Token.row, Token.nbcRow:
                guard let cols = columns else { throw TDSError.protocolViolation("a row before its column metadata") }
                var nulls: [UInt8] = []
                if token == Token.nbcRow { nulls = try r.bytes((cols.count + 7) / 8) }
                for (i, c) in cols.enumerated() {
                    if token == Token.nbcRow, nulls[i / 8] & (1 << UInt8(i % 8)) != 0 { current[i].append(.null); continue }
                    current[i].append(try TDSValues.read(c.type, r))
                }
            case Token.done, Token.doneProc, Token.doneInProc:
                let status = try r.u16()
                _ = try r.u16()                                        // current command
                let count = try r.u64()
                if status & 0x10 != 0, token != Token.doneInProc || response.rowsAffected == nil { response.rowsAffected = Int(clamping: count) }
                if status & 0x20 != 0 { response.attentionAcknowledged = true }
                if token != Token.doneInProc { finishResultSet() }
            case Token.error, Token.info:
                let length = Int(try r.u16())
                let message = try serverMessage(r, length: length)
                if token == Token.error { response.errors.append(message) } else { response.infos.append(message) }
            case Token.envChange:
                try envChange(r, into: &response)
            case Token.loginAck:
                let length = Int(try r.u16())
                guard length >= 10 else { throw TDSError.protocolViolation("LOGINACK length") }
                _ = try r.u8()                                         // interface
                let version = try r.bytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let nameLength = Int(try r.u8())
                guard 1 + 4 + 1 + nameLength * 2 + 4 == length else { throw TDSError.protocolViolation("LOGINACK layout") }
                let program = try r.utf16(characters: nameLength)
                _ = try r.bytes(4)                                     // program version
                response.loginAck = (version, program)
            case Token.featureExtAck:
                while true {
                    let id = try r.u8()
                    if id == 0xFF { break }
                    let length = Int(try r.u32())
                    try r.skip(length)
                    response.acknowledgedFeatures.append(id)
                }
            case Token.fedAuthInfo, Token.sessionState:
                try r.skip(Int(try r.u32()))
            case Token.returnStatus:
                _ = try r.i32()
            case Token.order, Token.tabName, Token.colInfo, Token.sspi:
                try r.skip(Int(try r.u16()))
            case Token.offset:
                try r.skip(4)
            case Token.returnValue:
                _ = try r.u16()                                        // ordinal
                _ = try r.bVarchar()
                _ = try r.u8()                                         // status
                _ = try r.u32()                                        // user type
                _ = try r.u16()                                        // flags
                let type = try TDSTypeInfo.read(r)
                _ = try TDSValues.readBytes(type, r)
            default:
                throw TDSError.protocolViolation("unknown token 0x\(String(token, radix: 16))")
            }
        }
        finishResultSet()
        return response
    }

    private static func serverMessage(_ r: TDSMessageReader, length: Int) throws -> TDSServerMessage {
        let number = Int(try r.i32()), state = Int(try r.u8()), severity = Int(try r.u8())
        let text = try r.usVarchar(), server = try r.bVarchar(), procedure = try r.bVarchar()
        let line = Int(try r.i32())
        let used = 4 + 1 + 1 + 2 + text.utf16.count * 2 + 1 + server.utf16.count * 2 + 1 + procedure.utf16.count * 2 + 4
        guard used == length else { throw TDSError.protocolViolation("message token length") }
        return TDSServerMessage(number: number, state: state, severity: severity, text: text, server: server, procedure: procedure, line: line)
    }

    private static func envChange(_ r: TDSMessageReader, into response: inout TDSResponse) throws {
        let length = Int(try r.u16())
        guard length >= 1 else { throw TDSError.protocolViolation("ENVCHANGE length") }
        let body = try r.bytes(length)
        let sub = TDSMessageReader(TDSMemoryInput(TDSWriter.packets(.tabularResult, body, packetSize: TDSLimits.maxPacketSize)),
                                   maxBytes: length)
        let type = try sub.u8()
        switch type {
        case 1: response.database = try sub.bVarchar()
        case 4:
            let size = Int(try sub.bVarchar()) ?? 0
            guard size >= 512, size <= TDSLimits.maxPacketSize else { throw TDSError.protocolViolation("packet size \(size)") }
            response.packetSize = size
        case 7:
            let n = Int(try sub.u8())
            if n == 5 { response.collation = try sub.bytes(5) }
        case 20:
            let valueLength = Int(try sub.u16())
            guard valueLength >= 5, try sub.u8() == 0 else { throw TDSError.protocolViolation("routing") }
            let port = Int(try sub.u16())
            let host = try sub.usVarchar()
            guard !host.isEmpty, port > 0 else { throw TDSError.protocolViolation("routing target") }
            response.routing = (host, port)
        default: break                                                 // language, transactions, mirroring…
        }
    }
}
