import Foundation
import Network

/// A SQL Server address as Power BI accepts it: `host`, `host,port`, `host\instance`, `tcp:host,port`, `.` or `(local)`.
struct TDSServerAddress: Equatable {
    var host: String
    var port: Int?
    var instance: String?

    init(host: String, port: Int? = nil, instance: String? = nil) { self.host = host; self.port = port; self.instance = instance }

    init(_ text: String) throws {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("tcp:") { s = String(s.dropFirst(4)) }
        guard !s.isEmpty else { throw TDSError.connection("Enter the name of a SQL Server.") }
        if let comma = s.lastIndex(of: ",") {
            let portText = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            guard let p = Int(portText), p > 0, p <= 65535 else { throw TDSError.connection("'\(portText)' isn't a valid port number.") }
            port = p
            s = String(s[..<comma])
        }
        if let slash = s.firstIndex(of: "\\") {
            let name = String(s[s.index(after: slash)...])
            instance = name.isEmpty ? nil : name
            s = String(s[..<slash])
        }
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }        // IPv6 literal
        if [".", "(local)", "(localdb)"].contains(s.lowercased()) { s = "localhost" }
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ";" }) else {
            throw TDSError.connection("'\(text)' isn't a valid server name.")
        }
        host = s
    }

    /// Azure SQL, Synapse and Fabric endpoints, which take Microsoft Entra tokens.
    var isMicrosoftCloud: Bool {
        let h = host.lowercased()
        return [".database.windows.net", ".sql.azuresynapse.net", ".datawarehouse.fabric.microsoft.com", ".database.fabric.microsoft.com",
                ".pbidedicated.windows.net", ".database.chinacloudapi.cn", ".database.usgovcloudapi.net"].contains { h.hasSuffix($0) }
    }
}

/// How the connection signs in.
enum TDSAuthentication {
    case sql(user: String, password: String)
    case accessToken(String)
}

struct TDSConnectOptions {
    var address: TDSServerAddress
    var database: String
    var authentication: TDSAuthentication
    var trustServerCertificate = false
    /// TDS 8.0: TLS before PRELOGIN (SQL Server 2022, Azure SQL).
    var strictEncryption = false
    var readOnlyIntent = false
    var connectTimeout: TimeInterval = 15
    /// The largest response one query may return.
    var maxResultBytes = 4 << 30
}

/// Asks the SQL Server Browser service (UDP 1434) for the TCP port of a named instance.
enum SQLServerBrowser {
    static func port(host: String, instance: String, timeout: TimeInterval = 3) throws -> Int {
        guard let endpointPort = NWEndpoint.Port(rawValue: 1434) else { throw TDSError.connection("SQL Server Browser port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        let queue = DispatchQueue(label: "Facet.TDS.browser")
        let done = DispatchSemaphore(value: 0)
        let answer = TDSBox<Data?>(nil)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data([0x04] + Array(instance.utf8) + [0x00]), completion: .contentProcessed { _ in })
                connection.receiveMessage { data, _, _, _ in answer.value = data; done.signal() }
            } else if case .failed = state { done.signal() }
        }
        connection.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        guard let data = answer.value else {
            throw TDSError.connection("The SQL Server Browser on '\(host)' didn't answer for the instance '\(instance)'. Enter the port instead (server,port).")
        }
        return try parsePort(Array(data), instance: instance)
    }

    /// SVR_RESP: 0x05, a 2-byte length, then `ServerName;…;InstanceName;…;tcp;1433;;`.
    static func parsePort(_ b: [UInt8], instance: String) throws -> Int {
        guard b.count >= 3, b[0] == 0x05 else { throw TDSError.protocolViolation("SQL Server Browser answer") }
        let length = Int(b[1]) | Int(b[2]) << 8
        guard length <= b.count - 3, length <= 4096 else { throw TDSError.protocolViolation("SQL Server Browser length") }
        let text = String(decoding: b[3..<3 + length], as: UTF8.self)
        // One answer can list several instances, each ending with ";;".
        for entry in text.components(separatedBy: ";;") {
            let parts = entry.components(separatedBy: ";")
            var fields: [String: String] = [:]
            var i = 0
            while i + 1 < parts.count { fields[parts[i].lowercased()] = parts[i + 1]; i += 2 }
            if fields["instancename"]?.lowercased() == instance.lowercased(), let p = fields["tcp"].flatMap(Int.init), p > 0, p <= 65535 { return p }
        }
        throw TDSError.connection("The instance '\(instance)' doesn't accept TCP/IP connections, or doesn't exist.")
    }
}

/// One signed-in TDS session. Not thread-safe: use from one thread at a time (the pool hands it out exclusively).
final class TDSConnection: @unchecked Sendable {
    private let transport: TDSTransport
    let options: TDSConnectOptions
    private(set) var packetSize = TDSLimits.initialPacketSize
    private(set) var collation = TDSRequest.defaultCollation
    private(set) var database: String
    /// False once the session is in an unknown state (timeout, cancel, protocol error); it is then discarded.
    private(set) var isUsable = true
    /// Set when the pool hands out a used connection: the next request resets the session first.
    var needsReset = false

    private init(transport: TDSTransport, options: TDSConnectOptions) { self.transport = transport; self.options = options; self.database = options.database }

    /// Connect, encrypt, sign in, and follow an Azure gateway redirect.
    static func open(_ options: TDSConnectOptions) throws -> TDSConnection {
        var target = options.address
        if target.port == nil, let instance = target.instance {
            target.port = try SQLServerBrowser.port(host: target.host, instance: instance, timeout: min(options.connectTimeout, 5))
        }
        var trust = options.trustServerCertificate
        for _ in 0..<3 {
            let (connection, routing) = try login(options, host: target.host, port: target.port ?? 1433, trust: trust)
            guard let routing else { return connection }
            connection.close()
            let next = TDSServerAddress(host: routing.host, port: routing.port)
            // The sign-in (password or Entra token) is sent again to the routed host, so a redirect may only move
            // between Microsoft cloud SQL hosts, and "Trust server certificate" covers only the host the user named.
            guard options.address.isMicrosoftCloud, next.isMicrosoftCloud else {
                throw TDSError.connection("The server '\(target.host)' redirected the connection to '\(routing.host)', which isn't a Microsoft cloud SQL host, so the sign-in wasn't sent there.")
            }
            target = next
            trust = false
        }
        throw TDSError.connection("The server redirected the connection too many times.")
    }

    private static func login(_ options: TDSConnectOptions, host: String, port: Int, trust: Bool) throws -> (TDSConnection, (host: String, port: Int)?) {
        let usesToken: Bool
        if case .accessToken = options.authentication { usesToken = true } else { usesToken = false }
        let deadline = Date().addingTimeInterval(options.connectTimeout)
        let transport: TDSTransport
        let prelogin: TDSPrelogin.Response
        if options.strictEncryption {
            transport = try TDSTransport.connectStrict(host: host, port: port, trustServerCertificate: trust, timeout: options.connectTimeout)
            transport.deadline = deadline
            try transport.send(TDSWriter.packets(.prelogin, TDSPrelogin.request(encryption: .on, fedAuth: usesToken), packetSize: TDSLimits.initialPacketSize))
            let reader = TDSMessageReader(transport, maxBytes: 4096)
            var payload: [UInt8] = []
            while try !reader.isAtEnd { payload.append(try reader.u8()) }
            prelogin = try TDSPrelogin.parse(payload)
        } else {
            transport = try TDSTransport.connect(host: host, port: port, prelogin: TDSPrelogin.request(encryption: .on, fedAuth: usesToken),
                                                 trustServerCertificate: trust, timeout: options.connectTimeout)
            transport.deadline = deadline
            guard let r = transport.preloginResponse else { transport.close(); throw TDSError.protocolViolation("no PRELOGIN response") }
            prelogin = r
        }
        let connection = TDSConnection(transport: transport, options: options)
        do {
            var login = TDSLogin7()
            login.tdsVersion = options.strictEncryption ? TDSLogin7.tds80 : TDSLogin7.tds74
            login.serverName = host
            login.database = options.database
            login.readOnlyIntent = options.readOnlyIntent
            login.fedAuthEcho = prelogin.fedAuthRequired
            switch options.authentication {
            case .sql(let user, let password): login.userName = user; login.password = password
            case .accessToken(let token): login.accessToken = token
            }
            try transport.send(TDSWriter.packets(.login7, login.encode(), packetSize: TDSLimits.initialPacketSize))
            let response = try TDSTokenParser.parse(TDSMessageReader(transport, maxBytes: 1 << 20))
            if let e = response.errors.first {
                throw TDSError(kind: .login, message: loginMessage(e, host: host), number: e.number)
            }
            if let routing = response.routing { return (connection, routing) }
            guard response.loginAck != nil else { throw TDSError.protocolViolation("the login wasn't acknowledged") }
            if usesToken, !response.acknowledgedFeatures.contains(0x02) {
                throw TDSError(kind: .login, message: "The server '\(host)' doesn't accept Microsoft Entra sign-in.")
            }
            connection.packetSize = response.packetSize ?? TDSLimits.initialPacketSize
            if let c = response.collation { connection.collation = c }
            if let db = response.database { connection.database = db }
            transport.deadline = nil
            return (connection, nil)
        } catch {
            transport.close()
            throw error
        }
    }

    private static func loginMessage(_ e: TDSServerMessage, host: String) -> String {
        switch e.number {
        case 18456: return e.text + " Check the user name and password in Data source settings."
        case 4060: return e.text + " Check the database name, and that this user may open it."
        case 40615: return e.text + " The server's firewall doesn't allow this computer; add its address to the firewall rules in the Azure portal."
        default: return e.text
        }
    }

    /// Run a batch (or, with parameters, `sp_executesql`) and read the whole response.
    /// A timeout or a cancel sends ATTENTION and leaves the connection unusable.
    func execute(_ sql: String, parameters: [TDSParameter] = [], timeout: TimeInterval?) throws -> TDSResponse {
        guard isUsable else { throw TDSError.connection("The connection is closed.") }
        let cancellation = QueryCancellation.current
        if cancellation?.isCancelled == true { throw TDSError(kind: .cancelled, message: "The query was cancelled.") }
        let handle = cancellation?.onCancel { [transport] in transport.cancel() }
        defer { if let handle { cancellation?.remove(handle) } }
        transport.deadline = timeout.map { Date().addingTimeInterval($0) }
        defer { transport.deadline = nil }
        let payload = parameters.isEmpty ? TDSRequest.sqlBatch(sql) : TDSRequest.executeSQL(sql, parameters: parameters, collation: collation)
        do {
            try transport.send(TDSWriter.packets(parameters.isEmpty ? .sqlBatch : .rpc, payload, packetSize: packetSize, resetConnection: needsReset))
            needsReset = false
            let response = try TDSTokenParser.parse(TDSMessageReader(transport, maxBytes: options.maxResultBytes))
            if let f = response.failure { throw f }
            return response
        } catch let e as TDSError {
            switch e.kind {
            case .server: throw e
            case .timeout:
                isUsable = false
                transport.cancel()
                throw TDSError(kind: .timeout, message: "The query didn't finish within the command timeout of \(Int(timeout ?? 0)) seconds. Increase CommandTimeout, or filter the query.")
            default:
                isUsable = false
                if e.kind != .cancelled { transport.close() }
                throw e
            }
        }
    }

    func close() { isUsable = false; transport.close() }
}

/// Reuses signed-in connections per server, database and identity (a login with TLS costs several round trips).
final class TDSConnectionPool: @unchecked Sendable {
    static let shared = TDSConnectionPool()
    private let lock = NSLock()
    private var idle: [String: [(connection: TDSConnection, since: Date)]] = [:]
    static let maxIdlePerKey = 4
    static let idleLifetime: TimeInterval = 240

    /// Run `body` on a connection for `key`; a pooled connection that turns out to be dead is replaced once.
    func with<T>(key: String, open: () throws -> TDSConnection, _ body: (TDSConnection) throws -> T) throws -> T {
        if let reused = take(key) {
            do {
                let result = try body(reused)
                give(reused, key: key)
                return result
            } catch let e as TDSError where e.kind == .connection || e.kind == .protocolViolation {
                reused.close()
            } catch {
                give(reused, key: key)
                throw error
            }
        }
        let fresh = try open()
        do {
            let result = try body(fresh)
            give(fresh, key: key)
            return result
        } catch {
            give(fresh, key: key)
            throw error
        }
    }

    private func take(_ key: String) -> TDSConnection? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var list = idle[key] ?? []
        for stale in list where now.timeIntervalSince(stale.since) > Self.idleLifetime { stale.connection.close() }
        list.removeAll { now.timeIntervalSince($0.since) > Self.idleLifetime }
        let c = list.popLast()?.connection
        idle[key] = list
        c?.needsReset = true
        return c
    }
    private func give(_ c: TDSConnection, key: String) {
        guard c.isUsable else { c.close(); return }
        lock.lock(); defer { lock.unlock() }
        var list = idle[key] ?? []
        if list.count >= Self.maxIdlePerKey { c.close(); return }
        list.append((c, Date()))
        idle[key] = list
    }
    /// Close every idle connection.
    func drain() {
        lock.lock(); let all = idle.values.flatMap { $0 }; idle = [:]; lock.unlock()
        for c in all { c.connection.close() }
    }
}
