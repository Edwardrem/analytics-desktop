import Foundation
import FacetCore

/// The byte stream a protocol client talks over: a `WireSocket`, or a scripted server in tests.
protocol WireTransport: AnyObject {
    func send(_ data: Data, timeout: TimeInterval) throws
    func read(_ n: Int, deadline: DispatchTime) throws -> Data
    var usesTLS: Bool { get }
    var peerCertificate: Data? { get }
    func close()
}
extension WireSocket: WireTransport {}

/// Sends PostgreSQL's SSLRequest and starts TLS when the server answers 'S'.
final class PGStartTLS: StartTLSNegotiator, @unchecked Sendable {
    override func opening() -> Data { PGMessage.sslRequest() }
    override func received(_ buffer: Data) -> Step {
        switch buffer.first {
        case UInt8(ascii: "S")?:
            return buffer.count == 1 ? .startTLS(send: Data()) : .fail("The server sent data before the TLS handshake; the connection was closed.")
        case UInt8(ascii: "N")?:
            return .fail("The PostgreSQL server doesn't accept encrypted connections. Turn off Encrypt connection only if the network is trusted.")
        default:
            return .fail("The server didn't answer the TLS request as a PostgreSQL server would.")
        }
    }
}

/// One authenticated PostgreSQL session (protocol 3.0).
final class PGConnection {
    struct Login {
        var user: String
        var password: String
        var database: String
        var applicationName = AppIdentity.name
    }

    private let transport: WireTransport
    private let limits: WireLimits
    private let notice: (String) -> Void
    private(set) var serverParameters: [String: String] = [:]
    private(set) var processID: Int32 = 0
    private(set) var secretKey = Data()
    /// Opens a second connection for a cancel request (nil: cancelling isn't possible).
    var cancelTransport: (() throws -> WireTransport)?

    /// Starts the session: startup message, authentication, then waits for the server to be ready.
    init(transport: WireTransport, login: Login, limits: WireLimits, scramNonce: String? = nil, notice: @escaping (String) -> Void = { _ in }) throws {
        self.transport = transport; self.limits = limits; self.notice = notice
        do { try startup(login, scramNonce: scramNonce) } catch { transport.close(); throw error }
    }

    deinit { close() }

    private var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        try? transport.send(PGMessage.terminate(), timeout: 2)
        transport.close()
    }

    // MARK: Messages

    private func readMessage(_ deadline: DispatchTime) throws -> (type: UInt8, body: Data) {
        while true {
            var header = ByteReader(try transport.read(5, deadline: deadline), what: "message header")
            let type = try header.u8()
            let length = Int(try header.i32BE())
            guard length >= 4, length - 4 <= limits.maxMessageBytes else {
                throw WireError("The server sent a message of \(length) bytes, more than the limit of \(limits.maxMessageBytes). The connection was closed.")
            }
            let body = try transport.read(length - 4, deadline: deadline)
            switch type {
            case UInt8(ascii: "N"):
                if let f = try? PGMessage.fields(body), let m = f["M"] { notice("PostgreSQL \(f["S"] ?? "NOTICE"): \(m)") }
            case UInt8(ascii: "S"):
                var r = ByteReader(body, what: "parameter status")
                if let k = try? r.cText(), let v = try? r.cText() { serverParameters[k] = v }
            case UInt8(ascii: "A"):
                break // asynchronous notification: not used
            default:
                return (type, body)
            }
        }
    }

    private func deadline(_ seconds: TimeInterval?) -> DispatchTime {
        seconds.map { .now() + $0 } ?? .distantFuture
    }

    // MARK: Startup and authentication

    private func startup(_ login: Login, scramNonce: String?) throws {
        let until = deadline(limits.connectTimeout)
        try transport.send(PGMessage.startup([("user", login.user), ("database", login.database), ("client_encoding", "UTF8"),
                                              ("DateStyle", "ISO"), ("application_name", login.applicationName)]), timeout: limits.connectTimeout)
        var scram: SCRAMClient?, scramVerified = false
        while true {
            let m = try readMessage(until)
            switch m.type {
            case UInt8(ascii: "R"):
                var r = ByteReader(m.body, what: "authentication request")
                let code = try r.i32BE()
                switch code {
                case 0: break
                case 3:
                    guard transport.usesTLS else {
                        throw WireError("The server asked for the password in clear text over an unencrypted connection, so it wasn't sent. Turn on Encrypt connection.")
                    }
                    try transport.send(PGMessage.password(login.password), timeout: limits.connectTimeout)
                case 5:
                    let salt = try r.bytes(4)
                    try transport.send(PGMessage.password(PGPassword.md5(user: login.user, password: login.password, salt: salt)), timeout: limits.connectTimeout)
                case 10:
                    var mechanisms: [String] = []
                    while r.remaining > 0 {
                        let name = try r.cText()
                        if name.isEmpty { break }
                        mechanisms.append(name)
                    }
                    let binding = transport.peerCertificate.flatMap(WireCrypto.tlsServerEndPoint)
                    let choice = try SCRAMClient.choose(mechanisms: mechanisms, tls: transport.usesTLS, binding: binding)
                    var client = SCRAMClient(user: "", password: login.password, gs2Header: choice.gs2, channelBinding: choice.binding)
                    if let scramNonce { client = SCRAMClient(user: "", password: login.password, clientNonce: scramNonce, gs2Header: choice.gs2, channelBinding: choice.binding) }
                    try transport.send(PGMessage.saslInitial(mechanism: choice.mechanism, client.clientFirst), timeout: limits.connectTimeout)
                    scram = client
                case 11:
                    guard var client = scram else { throw WireError.malformed("SASL exchange") }
                    let final = try client.clientFinal(serverFirst: String(decoding: r.rest(), as: UTF8.self))
                    scram = client
                    try transport.send(PGMessage.saslResponse(final), timeout: limits.connectTimeout)
                case 12:
                    guard let client = scram else { throw WireError.malformed("SASL exchange") }
                    try client.verify(serverFinal: String(decoding: r.rest(), as: UTF8.self))
                    scramVerified = true
                default:
                    let names: [Int32: String] = [2: "Kerberos", 7: "GSSAPI", 9: "SSPI", 14: "Redshift SHA-256"]
                    throw WireError("The server asked for \(names[code] ?? "authentication method \(code)") authentication, which isn't supported. "
                                    + "Use a user with SCRAM-SHA-256 or MD5 password authentication.")
                }
                if code == 0, scram != nil, !scramVerified {
                    throw WireError("The server ended SCRAM authentication without proving its identity; the connection was closed.")
                }
            case UInt8(ascii: "K"):
                var r = ByteReader(m.body, what: "backend key")
                processID = try r.i32BE()
                guard r.remaining >= 4, r.remaining <= 256 else { throw WireError.malformed("backend key") }
                secretKey = r.rest()
            case UInt8(ascii: "E"):
                throw PGMessage.error(from: try PGMessage.fields(m.body))
            case UInt8(ascii: "v"):
                break // NegotiateProtocolVersion: the server speaks 3.0 without the options it didn't recognise
            case UInt8(ascii: "Z"):
                return
            default:
                throw WireError.malformed("startup reply")
            }
        }
    }

    // MARK: Queries

    /// Wait for ReadyForQuery after an error, then report the error.
    private func drain(_ error: WireError, _ until: DispatchTime) throws -> Never {
        while try readMessage(until).type != UInt8(ascii: "Z") {}
        throw error
    }

    /// Runs `body`; on a command timeout the server is asked to cancel the statement.
    private func timed<T>(_ body: (DispatchTime) throws -> T) throws -> T {
        do { return try body(deadline(limits.commandTimeout)) } catch let e as WireError where e.code == "timeout" {
            if let open = cancelTransport, let t = try? open() {
                try? t.send(PGMessage.cancel(processID: processID, secretKey: secretKey), timeout: 5)
                t.close()
            }
            transport.close()
            throw WireError("The command didn't finish within \(Int(limits.commandTimeout ?? 0)) seconds and was cancelled. Raise CommandTimeout to allow more time.", code: "timeout")
        }
    }

    /// Prepares `sql` and returns its parameter types and result fields (nil fields: the statement returns no rows).
    func describe(_ sql: String) throws -> (parameters: [Int32], fields: [PGMessage.Field]?) {
        try timed { until in
            try transport.send(PGMessage.parse(sql) + PGMessage.describeStatement() + PGMessage.sync(), timeout: limits.connectTimeout)
            var parameters: [Int32] = [], fields: [PGMessage.Field]?
            while true {
                let m = try readMessage(until)
                switch m.type {
                case UInt8(ascii: "1"): break
                case UInt8(ascii: "t"):
                    var r = ByteReader(m.body, what: "parameter description")
                    let n = Int(try r.i16BE())
                    guard n >= 0 else { throw WireError.malformed("parameter description") }
                    parameters = try (0..<n).map { _ in try r.i32BE() }
                case UInt8(ascii: "T"): fields = try PGMessage.rowDescription(m.body, maxColumns: limits.maxColumns)
                case UInt8(ascii: "n"): fields = nil
                case UInt8(ascii: "E"): try drain(PGMessage.error(from: try PGMessage.fields(m.body)), until)
                case UInt8(ascii: "Z"): return (parameters, fields)
                default: throw WireError.malformed("describe reply")
                }
            }
        }
    }

    /// Extended query: parse, describe, then bind (binary results where the type allows) and execute.
    func query(_ sql: String, parameters: [String?], limit: Int?) throws -> RemoteResult {
        let described = try describe(sql)
        guard described.parameters.count == parameters.count else {
            throw WireError("The native query has \(described.parameters.count) parameter(s) but \(parameters.count) value(s) were given.")
        }
        let fields = (described.fields ?? []).map { f -> PGMessage.Field in
            var f = f; f.format = PGType.readsBinary(f.typeOID) ? 1 : 0; return f
        }
        return try timed { until in
            let maxRows = limit.map { Int32(clamping: max(0, $0)) } ?? 0
            try transport.send(PGMessage.bind(parameters: parameters, resultFormats: fields.map(\.format)) + PGMessage.execute(maxRows: maxRows)
                               + PGMessage.sync(), timeout: limits.connectTimeout)
            var rows = RowCollector(fields: fields, limits: limits)
            while true {
                let m = try readMessage(until)
                switch m.type {
                case UInt8(ascii: "2"), UInt8(ascii: "C"), UInt8(ascii: "s"), UInt8(ascii: "I"): break
                case UInt8(ascii: "D"): try rows.add(m.body)
                case UInt8(ascii: "E"): try drain(PGMessage.error(from: try PGMessage.fields(m.body)), until)
                case UInt8(ascii: "Z"): return rows.result
                default: throw WireError.malformed("query reply")
                }
            }
        }
    }

    /// Simple query (text results). With several statements, the first result set is returned.
    func simpleQuery(_ sql: String, limit: Int? = nil) throws -> RemoteResult {
        try timed { until in
            try transport.send(PGMessage.query(sql), timeout: limits.connectTimeout)
            var current: RowCollector?, first: RemoteResult?
            var failure: WireError?
            while true {
                let m = try readMessage(until)
                switch m.type {
                case UInt8(ascii: "T"): current = RowCollector(fields: try PGMessage.rowDescription(m.body, maxColumns: limits.maxColumns), limits: limits)
                case UInt8(ascii: "D"):
                    guard current != nil else { throw WireError.malformed("data row") }
                    if first == nil, limit.map({ (current?.count ?? 0) < $0 }) ?? true { try current?.add(m.body) }
                case UInt8(ascii: "C"):
                    if first == nil, let c = current { first = c.result }
                    current = nil
                case UInt8(ascii: "I"): break
                case UInt8(ascii: "E"):
                    let e = PGMessage.error(from: try PGMessage.fields(m.body))
                    if failure == nil { failure = e }
                case UInt8(ascii: "Z"):
                    if let failure { throw failure }
                    return first ?? RemoteResult(columns: [], cells: [])
                default: throw WireError.malformed("query reply")
                }
            }
        }
    }
}

/// Decodes DataRows into columns, keeping the total size within the limit.
struct RowCollector {
    let fields: [PGMessage.Field]
    let limits: WireLimits
    private var cells: [[MValue]]
    private var bytes = 0
    private(set) var count = 0

    init(fields: [PGMessage.Field], limits: WireLimits) {
        self.fields = fields; self.limits = limits
        cells = [[MValue]](repeating: [], count: fields.count)
    }

    mutating func add(_ body: Data) throws {
        bytes += body.count
        guard bytes <= limits.maxResultBytes else {
            throw WireError("The result is larger than the limit of \(limits.maxResultBytes) bytes. Filter the query or raise the limit for large sources.")
        }
        let row = try PGMessage.dataRow(body, columns: fields.count)
        for (i, cell) in row.enumerated() {
            guard let cell else { cells[i].append(.null); continue }
            let f = fields[i]
            cells[i].append(f.format == 1 ? PGType.decodeBinary(f.typeOID, cell)
                                          : PGType.decodeText(f.typeOID, String(decoding: cell, as: UTF8.self)))
        }
        count += 1
    }

    var result: RemoteResult {
        RemoteResult(columns: fields.map { RemoteColumn(name: $0.name, type: PGType.mType($0.typeOID)) }, cells: cells)
    }
}
