import Foundation
import Network
import Security
import FacetCore

/// One tool offered to MCP clients.
public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments object.
    public var inputSchema: JSONValue
    /// Runs the tool. Returns the text shown to the client; a thrown error is reported as a tool error.
    public var handler: @Sendable (JSONValue) async throws -> String

    public init(name: String, description: String, inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])]),
                handler: @escaping @Sendable (JSONValue) async throws -> String) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.handler = handler
    }
}

/// The JSON-RPC side of the Model Context Protocol: `initialize`, `ping`, `tools/list`, `tools/call`.
/// Separate from the transport so it can be tested without sockets.
public struct MCPDispatcher: Sendable {
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public var serverName: String
    public var serverVersion: String
    public var tools: @Sendable () -> [MCPTool]

    public init(serverName: String, serverVersion: String, tools: @escaping @Sendable () -> [MCPTool]) {
        self.serverName = serverName; self.serverVersion = serverVersion; self.tools = tools
    }

    static func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    static func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    /// Handles a request body (one message or a batch). Returns `nil` when nothing is to be sent back (notifications).
    public func handle(_ body: JSONValue) async -> JSONValue? {
        if let batch = body.arrayValue {
            guard !batch.isEmpty, batch.count <= 50 else { return Self.error(.null, -32600, "Invalid batch.") }
            var out: [JSONValue] = []
            for message in batch { if let r = await handleOne(message) { out.append(r) } }
            return out.isEmpty ? nil : .array(out)
        }
        return await handleOne(body)
    }

    private func handleOne(_ message: JSONValue) async -> JSONValue? {
        guard message.objectValue != nil, message["jsonrpc"]?.stringValue == "2.0", let method = message["method"]?.stringValue else {
            return Self.error(message["id"] ?? .null, -32600, "Invalid request.")
        }
        guard let id = message["id"], !id.isNull else { return nil }   // a notification: never answered
        let params = message["params"]
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return Self.result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
            ]))
        case "ping":
            return Self.result(id, .object([:]))
        case "tools/list":
            return Self.result(id, .object(["tools": .array(tools().map { t in
                .object(["name": .string(t.name), "description": .string(t.description), "inputSchema": t.inputSchema])
            })]))
        case "tools/call":
            guard let name = params?["name"]?.stringValue, let tool = tools().first(where: { $0.name == name }) else {
                return Self.error(id, -32602, "Unknown tool.")
            }
            let arguments = params?["arguments"] ?? .object([:])
            do {
                let text = try await tool.handler(arguments)
                return Self.result(id, .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(false)]))
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return Self.result(id, .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(true)]))
            }
        default:
            return Self.error(id, -32601, "Method not found.")
        }
    }
}

/// A Model Context Protocol server (Streamable HTTP, JSON responses) for AI agents and tools on this Mac.
///
/// Security properties:
/// - listens on 127.0.0.1 only, on an ephemeral port, and rejects peers that are not loopback;
/// - every request must carry `Authorization: Bearer <token>`; the token is 32 random bytes generated for
///   each start and is never written to disk or logged;
/// - the `Host` header must name the loopback address and any `Origin` header must be a loopback origin
///   (protects against DNS rebinding and against web pages calling the server);
/// - only `POST /mcp` with a JSON body of at most 1 MB is served; requests that do not arrive within
///   15 seconds are dropped; at most 16 connections are open at once.
public final class MCPServer: @unchecked Sendable {
    public static let maxBodyBytes = 1 * 1024 * 1024
    static let maxHeadBytes = 16 * 1024
    static let maxConnections = 16
    static let requestDeadline: TimeInterval = 15

    public let dispatcher: MCPDispatcher
    private let queue = DispatchQueue(label: "facet.mcp.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var _port: UInt16 = 0
    private var _token = ""

    public init(dispatcher: MCPDispatcher) { self.dispatcher = dispatcher }
    deinit { listener?.cancel() }

    public var port: UInt16 { queue.sync { _port } }
    /// The bearer token of the running session; empty when stopped.
    public var token: String { queue.sync { _token } }
    public var isRunning: Bool { queue.sync { listener != nil } }
    public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Starts listening and returns the port. Each start creates a new token.
    @discardableResult
    public func start() async throws -> UInt16 {
        stop()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let l: NWListener
        do { l = try NWListener(using: params) }
        catch { throw InteropError.io("The MCP server couldn't start: \(error.localizedDescription)") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let bound: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let p = l.port?.rawValue, p != 0 { cont.resume(returning: p) }
                    else { cont.resume(throwing: InteropError.io("The MCP server was not given a port.")) }
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: InteropError.io("The MCP server couldn't start: \(e.localizedDescription)"))
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: InteropError.io("The MCP server was stopped while starting."))
                default: break
                }
            }
            l.start(queue: queue)
        }
        queue.sync {
            listener = l
            _port = bound
            _token = Self.randomToken()
        }
        return bound
    }

    /// Stops listening, closes every connection and forgets the token.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for c in connections.values { c.cancel() }
            connections.removeAll()
            _port = 0
            _token = ""
        }
    }

    // MARK: Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard listener != nil, Self.isLoopback(connection.endpoint), connections.count < Self.maxConnections else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil, !self.inFlight.contains(id) else { return }
            connection.cancel()
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Connections whose request was accepted and is being answered (exempt from the read deadline).
    private var inFlight: Set<ObjectIdentifier> = []

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        default: return false
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let split = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || isComplete || buf.count > Self.maxHeadBytes { connection.cancel() }
                else { self.receive(on: connection, buffer: buf) }
                return
            }
            let head = String(decoding: buf.subdata(in: buf.startIndex..<split.lowerBound), as: UTF8.self)
            let body = buf.subdata(in: split.upperBound..<buf.endIndex)
            switch Self.evaluate(head: head, port: self._port, token: self._token) {
            case .reject(let status, let message, let extra):
                self.respond(connection, status: status, headers: extra, body: Data(message.utf8), contentType: "text/plain; charset=utf-8")
            case .accept(let length):
                if body.count > length { self.respond(connection, status: "400 Bad Request", body: Data("Body longer than Content-Length.".utf8), contentType: "text/plain; charset=utf-8"); return }
                self.readBody(on: connection, body: body, length: length, failed: error != nil || isComplete)
            }
        }
    }

    private func readBody(on connection: NWConnection, body: Data, length: Int, failed: Bool) {
        if body.count == length { serve(connection, body: body); return }
        if failed { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = body
            if let data { buf.append(data) }
            if buf.count > length { connection.cancel(); return }
            self.readBody(on: connection, body: buf, length: length, failed: error != nil || isComplete)
        }
    }

    private func serve(_ connection: NWConnection, body: Data) {
        guard let json = try? JSONValue.parse(body) else {
            let err = MCPDispatcher.error(.null, -32700, "Parse error.")
            respond(connection, status: "400 Bad Request", body: err.serialized(pretty: false), contentType: "application/json")
            return
        }
        let id = ObjectIdentifier(connection)
        inFlight.insert(id)
        let dispatcher = self.dispatcher
        Task { [weak self] in
            let reply = await dispatcher.handle(json)
            self?.queue.async {
                guard let self else { return }
                self.inFlight.remove(id)
                if let reply { self.respond(connection, status: "200 OK", body: reply.serialized(pretty: false), contentType: "application/json") }
                else { self.respond(connection, status: "202 Accepted", body: Data(), contentType: "application/json") }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, headers: [String] = [], body: Data, contentType: String) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        for h in headers { head += h + "\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Request checks (pure)

    enum Evaluation: Equatable {
        case reject(status: String, message: String, headers: [String])
        case accept(contentLength: Int)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let c = URLComponents(string: origin), c.scheme == "http" || c.scheme == "https", let host = c.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    /// Decides whether a request head may be served. Order matters: nothing about the server is revealed
    /// to a caller that fails the host, origin or token checks.
    static func evaluate(head: String, port: UInt16, token: String) -> Evaluation {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .reject(status: "400 Bad Request", message: "Malformed request.", headers: []) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if headers[key] != nil, ["host", "authorization", "content-length", "origin"].contains(key) {
                return .reject(status: "400 Bad Request", message: "Repeated header.", headers: [])
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let host = (headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .reject(status: "403 Forbidden", message: "Forbidden.", headers: [])
        }
        if let origin = headers["origin"], !isLoopbackOrigin(origin) {
            return .reject(status: "403 Forbidden", message: "Forbidden.", headers: [])
        }
        let auth = headers["authorization"] ?? ""
        guard !token.isEmpty, auth.lowercased().hasPrefix("bearer "),
              constantTimeEquals(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces), token) else {
            return .reject(status: "401 Unauthorized", message: "A valid session token is required.", headers: ["WWW-Authenticate: Bearer"])
        }
        let path = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard path == "/mcp" else { return .reject(status: "404 Not Found", message: "Not found.", headers: []) }
        guard parts[0] == "POST" else { return .reject(status: "405 Method Not Allowed", message: "Only POST is supported.", headers: ["Allow: POST"]) }
        guard headers["transfer-encoding"] == nil else { return .reject(status: "411 Length Required", message: "Content-Length is required.", headers: []) }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 else {
            return .reject(status: "411 Length Required", message: "Content-Length is required.", headers: [])
        }
        guard length <= maxBodyBytes else { return .reject(status: "413 Payload Too Large", message: "The request is too large.", headers: []) }
        guard (headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else {
            return .reject(status: "415 Unsupported Media Type", message: "Send application/json.", headers: [])
        }
        return .accept(contentLength: length)
    }
}
