import Foundation

/// Reads the MySQL greeting before TLS, then asks the server to start TLS (an SSLRequest packet).
final class MySQLStartTLS: StartTLSNegotiator, @unchecked Sendable {
    private(set) var greeting: MySQLProtocol.Handshake?
    private(set) var capabilities: UInt32 = 0

    override func received(_ buffer: Data) -> Step {
        guard buffer.count >= 4 else { return .needMore }
        let length = Int(buffer[buffer.startIndex]) | Int(buffer[buffer.startIndex + 1]) << 8 | Int(buffer[buffer.startIndex + 2]) << 16
        guard length <= 65_536 else { return .fail("The server's greeting is too large to be a MySQL greeting.") }
        guard buffer.count >= 4 + length else { return .needMore }
        guard buffer.count == 4 + length else { return .fail("The server sent data before the TLS handshake; the connection was closed.") }
        let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
        do {
            let hello = try MySQLProtocol.handshake(payload)
            guard hello.capabilities & MySQLProtocol.ssl != 0 else {
                return .fail("The MySQL server doesn't accept encrypted connections. Turn off Encrypt connection only if the network is trusted.")
            }
            greeting = hello
            capabilities = MySQLProtocol.clientCapabilities(server: hello.capabilities, tls: true)
            return .startTLS(send: MySQLProtocol.packet(MySQLProtocol.sslRequest(capabilities: capabilities), sequence: 1))
        } catch {
            return .fail((error as? WireError)?.message ?? "The server's greeting couldn't be read.")
        }
    }
}

/// One authenticated MySQL session.
final class MySQLConnection {
    struct Login {
        var user: String
        var password: String
        var database: String
    }

    private let transport: WireTransport
    private let limits: WireLimits
    private var sequence: UInt8 = 0
    private(set) var greeting: MySQLProtocol.Handshake
    private var capabilities: UInt32

    /// After TLS, `greeting` and `capabilities` come from the `MySQLStartTLS` negotiation; otherwise the greeting is read here.
    init(transport: WireTransport, login: Login, limits: WireLimits, greeting: MySQLProtocol.Handshake? = nil, capabilities: UInt32 = 0) throws {
        self.transport = transport; self.limits = limits
        let until = DispatchTime.now() + limits.connectTimeout
        var seq: UInt8 = 0
        let hello: MySQLProtocol.Handshake
        do { hello = try greeting ?? MySQLProtocol.handshake(try Self.readPacket(transport, limits, &seq, until)) } catch {
            transport.close()
            throw error
        }
        self.greeting = hello
        self.capabilities = greeting != nil ? capabilities : MySQLProtocol.clientCapabilities(server: hello.capabilities, tls: false)
        self.sequence = greeting != nil ? 2 : seq
        do { try authenticate(login, until) } catch {
            transport.close()
            throw error
        }
    }

    deinit { close() }
    private var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        sequence = 0
        try? send(Data([0x01])) // COM_QUIT
        transport.close()
    }

    // MARK: Packets

    /// One logical packet (joining 16 MiB continuation packets), bounded by the message limit.
    static func readPacket(_ t: WireTransport, _ limits: WireLimits, _ sequence: inout UInt8, _ until: DispatchTime) throws -> Data {
        var payload = Data()
        while true {
            var h = ByteReader(try t.read(4, deadline: until), what: "packet header")
            let length = Int(try h.uintLE(3))
            sequence = try h.u8() &+ 1
            guard payload.count + length <= limits.maxMessageBytes else {
                throw WireError("The server sent a packet larger than the limit of \(limits.maxMessageBytes) bytes. The connection was closed.")
            }
            payload += try t.read(length, deadline: until)
            if length < 0xFF_FFFF { return payload }
        }
    }
    private func read(_ until: DispatchTime) throws -> Data { try Self.readPacket(transport, limits, &sequence, until) }

    private func send(_ payload: Data) throws {
        var offset = 0
        repeat {
            let n = min(0xFF_FFFF, payload.count - offset)
            try transport.send(MySQLProtocol.packet(payload.subdata(in: offset..<(offset + n)), sequence: sequence), timeout: limits.connectTimeout)
            sequence &+= 1
            offset += n
            if n < 0xFF_FFFF { break }
        } while true
    }

    // MARK: Authentication

    static let supportedPlugins = ["mysql_native_password", "caching_sha2_password", "mysql_clear_password", "sha256_password"]

    /// The response to an authentication challenge for `plugin`.
    func authResponse(plugin: String, salt: Data, password: String) throws -> Data {
        switch plugin {
        case "mysql_native_password": return MySQLProtocol.nativeScramble(password: password, salt: salt)
        case "caching_sha2_password": return MySQLProtocol.cachingSHA2Scramble(password: password, salt: salt)
        case "mysql_clear_password", "sha256_password":
            guard transport.usesTLS else {
                throw WireError("The server asked for the password with \(plugin) over an unencrypted connection, so it wasn't sent. Turn on Encrypt connection.")
            }
            return Data(password.utf8) + Data([0])
        default:
            throw WireError("The server asked for the \(plugin) authentication plugin, which isn't supported. "
                            + "Use a user with caching_sha2_password or mysql_native_password.")
        }
    }

    private func authenticate(_ login: Login, _ until: DispatchTime) throws {
        var plugin = Self.supportedPlugins.contains(greeting.plugin) ? greeting.plugin : "mysql_native_password"
        var salt = greeting.salt
        try send(MySQLProtocol.handshakeResponse(capabilities: capabilities, user: login.user,
                                                 auth: try authResponse(plugin: plugin, salt: salt, password: login.password),
                                                 database: login.database, plugin: plugin))
        var switches = 0
        while true {
            let p = try read(until)
            switch p.first {
            case 0x00?: return
            case 0xFF?: throw try MySQLProtocol.error(p)
            case 0xFE?:
                switches += 1
                guard switches <= 2 else { throw WireError("The server kept switching authentication methods; the connection was closed.") }
                var r = ByteReader(p, what: "authentication switch")
                try r.skip(1)
                plugin = try r.cText()
                salt = r.rest()
                if salt.last == 0 { salt.removeLast() }
                try send(try authResponse(plugin: plugin, salt: salt, password: login.password))
            case 0x01?:
                guard plugin == "caching_sha2_password", p.count >= 2 else { throw WireError.malformed("authentication data") }
                switch p[p.startIndex + 1] {
                case 3: continue // fast authentication succeeded; OK follows
                case 4:
                    guard transport.usesTLS else {
                        throw WireError("This MySQL user needs full caching_sha2_password authentication, which sends the password and is only done over TLS. "
                                        + "Turn on Encrypt connection (or sign in once over TLS so the server caches the password).")
                    }
                    try send(Data(login.password.utf8) + Data([0]))
                default: throw WireError.malformed("authentication data")
                }
            default:
                throw WireError.malformed("authentication reply")
            }
        }
    }

    // MARK: Commands

    private func command(_ payload: Data) throws {
        sequence = 0
        try send(payload)
    }

    private func timeoutDeadline() -> DispatchTime { limits.commandTimeout.map { .now() + $0 } ?? .distantFuture }

    private func timed<T>(_ body: (DispatchTime) throws -> T) throws -> T {
        do { return try body(timeoutDeadline()) } catch let e as WireError where e.code == "timeout" {
            transport.close()
            throw WireError("The command didn't finish within \(Int(limits.commandTimeout ?? 0)) seconds; the connection was closed, which stops it. "
                            + "Raise CommandTimeout to allow more time.", code: "timeout")
        }
    }

    /// COM_QUERY with the text protocol. With `limit`, reading stops after that many rows (the session is closed after).
    func query(_ sql: String, limit: Int?) throws -> RemoteResult {
        try timed { until in
            try command(Data([0x03]) + Data(sql.utf8))
            return try resultSet(until, binary: false, limit: limit)
        }
    }

    /// Column definitions of a statement, from COM_STMT_PREPARE (the statement is closed again).
    func describe(_ sql: String) throws -> (parameters: Int, columns: [MySQLProtocol.Column]) {
        try timed { until in
            let prepared = try prepare(sql, until)
            try command(Data([0x19]) + prepared.idBytes)
            return (prepared.parameters, prepared.columns)
        }
    }

    /// COM_STMT_PREPARE + COM_STMT_EXECUTE with the binary protocol.
    func execute(_ sql: String, parameters: [MValue], limit: Int?) throws -> RemoteResult {
        try timed { until in
            let prepared = try prepare(sql, until)
            guard prepared.parameters == parameters.count else {
                throw WireError("The native query has \(prepared.parameters) parameter(s) but \(parameters.count) value(s) were given.")
            }
            var w = ByteWriter()
            w.u8(0x17); w.append(prepared.idBytes); w.u8(0); w.uintLE(1, 4)
            if !parameters.isEmpty {
                let values = try parameters.map(MySQLType.parameter)
                var bitmap = [UInt8](repeating: 0, count: (values.count + 7) / 8)
                for (i, v) in values.enumerated() where v.value == nil { bitmap[i / 8] |= 1 << UInt8(i % 8) }
                w.append(bitmap); w.u8(1)
                for v in values { w.u8(v.type); w.u8(0) }
                for v in values { if let d = v.value { w.append(d) } }
            }
            try command(w.data)
            return try resultSet(until, binary: true, limit: limit)
        }
    }

    private struct Prepared { var idBytes: Data; var parameters: Int; var columns: [MySQLProtocol.Column] }

    private func prepare(_ sql: String, _ until: DispatchTime) throws -> Prepared {
        try command(Data([0x16]) + Data(sql.utf8))
        let first = try read(until)
        if first.first == 0xFF { throw try MySQLProtocol.error(first) }
        var r = ByteReader(first, what: "prepare reply")
        guard try r.u8() == 0 else { throw WireError.malformed("prepare reply") }
        let id = try r.bytes(4)
        let columns = Int(try r.u16LE()), parameters = Int(try r.u16LE())
        guard columns <= limits.maxColumns, parameters <= 65_535 else { throw WireError("The statement has more columns than the limit of \(limits.maxColumns).") }
        if parameters > 0 {
            for _ in 0..<parameters { _ = try read(until) }
            if capabilities & 0x0100_0000 == 0 { _ = try read(until) } // EOF
        }
        var defs: [MySQLProtocol.Column] = []
        if columns > 0 {
            for _ in 0..<columns { defs.append(try MySQLProtocol.column(try read(until))) }
            if capabilities & 0x0100_0000 == 0 { _ = try read(until) }
        }
        return Prepared(idBytes: id, parameters: parameters, columns: defs)
    }

    /// Reads a result set; further result sets (from procedures) are read and dropped.
    private func resultSet(_ until: DispatchTime, binary: Bool, limit: Int?) throws -> RemoteResult {
        let first = try read(until)
        switch first.first {
        case 0x00?:
            let status = try MySQLProtocol.okStatus(first)
            if status & MySQLProtocol.serverMoreResults != 0 { return try resultSet(until, binary: binary, limit: limit) }
            return RemoteResult(columns: [], cells: [])
        case 0xFF?: throw try MySQLProtocol.error(first)
        case 0xFB?: throw WireError("The server asked to read a local file (LOAD DATA LOCAL), which is refused.")
        default: break
        }
        var r = ByteReader(first, what: "column count")
        guard let n = try MySQLProtocol.readLenenc(&r), n <= UInt64(limits.maxColumns) else {
            throw WireError("The result has more columns than the limit of \(limits.maxColumns).")
        }
        let columns = try (0..<Int(n)).map { _ in try MySQLProtocol.column(try read(until)) }
        _ = try read(until) // EOF after the column definitions
        var cells = [[MValue]](repeating: [], count: columns.count)
        var bytes = 0, rows = 0
        while true {
            let p = try read(until)
            if p.first == 0xFF { throw try MySQLProtocol.error(p) }
            if let status = MySQLProtocol.eofStatus(p) {
                if status & MySQLProtocol.serverMoreResults != 0 { _ = try? resultSet(until, binary: binary, limit: 0) }
                break
            }
            if let limit, rows >= limit { break }
            bytes += p.count
            guard bytes <= limits.maxResultBytes else {
                throw WireError("The result is larger than the limit of \(limits.maxResultBytes) bytes. Filter the query or raise the limit for large sources.")
            }
            var row = ByteReader(p, what: "row")
            if binary {
                guard try row.u8() == 0 else { throw WireError.malformed("binary row") }
                let bitmap = try row.bytes((columns.count + 9) / 8)
                for (i, c) in columns.enumerated() {
                    let bit = i + 2
                    if bitmap[bitmap.startIndex + bit / 8] & (1 << UInt8(bit % 8)) != 0 { cells[i].append(.null); continue }
                    cells[i].append(try MySQLType.decodeBinary(c, &row))
                }
            } else {
                for (i, c) in columns.enumerated() {
                    guard let d = try MySQLProtocol.readLenencBytes(&row) else { cells[i].append(.null); continue }
                    cells[i].append(MySQLType.decodeText(c, d))
                }
            }
            rows += 1
        }
        return RemoteResult(columns: columns.map { RemoteColumn(name: $0.name, type: MySQLType.mType($0)) }, cells: cells)
    }
}
