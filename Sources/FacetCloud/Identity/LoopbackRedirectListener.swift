import Foundation
import FacetCore
import Network

/// A one-shot HTTP listener on the loopback interface that receives the OAuth redirect
/// (`http://localhost:<port>/?code=…&state=…`) from the system browser.
///
/// Security properties:
/// - binds to 127.0.0.1 (and, best effort, ::1) only, on an ephemeral port;
/// - rejects connections whose peer is not a loopback address;
/// - serves only `GET /`; any other path or method gets 404/405 and does not complete the flow;
/// - requires the `state` parameter to match (constant-time comparison); mismatches get 400 and are ignored,
///   so another local process cannot complete or abort the sign-in with a forged request;
/// - never logs the query string.
public final class LoopbackRedirectListener: @unchecked Sendable {
    /// The outcome delivered by the browser redirect.
    public enum Result: Equatable {
        case code(String)
        case failure(MicrosoftAuthError)
    }

    private let expectedState: String
    private let queue = DispatchQueue(label: "com.facet.cloud.loopback")
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pendingResult: Swift.Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var stopped = false
    public private(set) var port: UInt16 = 0

    public init(expectedState: String) { self.expectedState = expectedState }

    deinit { stopListeners() }

    /// The redirect URI to send to the identity platform. Valid after `start()`.
    public var redirectURI: String { "http://localhost:\(port)" }

    /// Starts listening and returns the bound port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let v4 = try makeListener(host: .ipv4(.loopback), port: .any)
        let bound: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            v4.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let p = v4.port?.rawValue, p != 0 { cont.resume(returning: p) }
                    else { cont.resume(throwing: MicrosoftAuthError.listenerFailed("no port was assigned")) }
                case .failed(let e):
                    guard once.claim() else { return }
                    cont.resume(throwing: MicrosoftAuthError.listenerFailed(e.localizedDescription))
                case .cancelled:
                    guard once.claim() else { return }
                    cont.resume(throwing: MicrosoftAuthError.cancelled)
                default: break
                }
            }
            v4.start(queue: queue)
        }
        queue.sync {
            self.port = bound
            self.listeners.append(v4)
        }
        // Browsers may resolve "localhost" to ::1 first; also listen there on the same port when possible.
        if let p = NWEndpoint.Port(rawValue: bound), let v6 = try? makeListener(host: .ipv6(.loopback), port: p) {
            v6.stateUpdateHandler = { [weak v6] state in
                if case .failed = state { v6?.cancel() }
            }
            v6.start(queue: queue)
            queue.sync { self.listeners.append(v6) }
        }
        return bound
    }

    private func makeListener(host: NWEndpoint.Host, port: NWEndpoint.Port) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: host, port: port)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            return l
        } catch {
            throw MicrosoftAuthError.listenerFailed(error.localizedDescription)
        }
    }

    /// Waits for a valid redirect. Throws `MicrosoftAuthError.timedOut` after `timeout`, `.cancelled` if the task
    /// is cancelled or `stop()` is called, or the error the identity platform sent back.
    public func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async {
                    if let r = self.pendingResult {
                        self.pendingResult = nil
                        cont.resume(with: r)
                        return
                    }
                    if self.stopped { cont.resume(throwing: MicrosoftAuthError.cancelled); return }
                    self.waiter = cont
                    let work = DispatchWorkItem { self.finish(.failure(MicrosoftAuthError.timedOut)) }
                    self.timeoutWork = work
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(MicrosoftAuthError.cancelled)) }
        }
    }

    /// Stops listening. A pending `waitForCode` throws `.cancelled`.
    public func stop() {
        queue.async {
            self.finish(.failure(MicrosoftAuthError.cancelled))
        }
    }

    // MARK: Internals (all on `queue`)

    private func finish(_ result: Swift.Result<String, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let w = waiter {
            waiter = nil
            w.resume(with: result)
        } else if pendingResult == nil, !stopped {
            pendingResult = result
        }
        stopped = true
        // Give in-flight responses a moment to flush before tearing the sockets down.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.stopListeners() }
    }

    private func stopListeners() {
        for l in listeners { l.cancel() }
        listeners.removeAll()
        for c in connections.values { c.cancel() }
        connections.removeAll()
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
                _ = connection
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(head: buf.subdata(in: buf.startIndex..<range.lowerBound), on: connection)
            } else if error != nil || isComplete || buf.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buf)
            }
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.components(separatedBy: "\r\n").first ?? ""
        switch Self.evaluate(requestLine: requestLine, expectedState: expectedState) {
        case .reject(let status, let message):
            respond(connection, status: status, html: SignInPages.error(title: "Request not accepted", detail: message))
        case .complete(.code(let code)):
            respond(connection, status: "200 OK", html: SignInPages.success())
            finish(.success(code))
        case .complete(.failure(let err)):
            respond(connection, status: "200 OK",
                    html: SignInPages.error(title: "Sign-in didn't complete", detail: err.errorDescription ?? "Sign-in failed."))
            finish(.failure(err))
        }
    }

    enum Evaluation: Equatable {
        case reject(status: String, message: String)
        case complete(Result)
    }

    /// Pure request evaluation, separated for testing.
    static func evaluate(requestLine: String, expectedState: String) -> Evaluation {
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .reject(status: "400 Bad Request", message: "Malformed request.") }
        guard parts[0] == "GET" else { return .reject(status: "405 Method Not Allowed", message: "Only GET is supported.") }
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard path == "/" else { return .reject(status: "404 Not Found", message: "Nothing here.") }
        let query = parseQuery(target)
        guard query["code"] != nil || query["error"] != nil else {
            return .reject(status: "400 Bad Request", message: "This address only receives the sign-in response from Microsoft.")
        }
        guard let state = query["state"], HTTPHelpers.constantTimeEquals(state, expectedState) else {
            return .reject(status: "400 Bad Request", message: "This response does not belong to the current sign-in attempt.")
        }
        if let error = query["error"] {
            let desc = OAuthProtocolError.clean(query["error_description"] ?? "")
            let perr = OAuthProtocolError(code: error, description: desc, subError: query["error_subcode"], correlationID: nil, errorCodes: [])
            return .complete(.failure(perr.asAuthError))
        }
        guard let code = query["code"], !code.isEmpty else {
            return .reject(status: "400 Bad Request", message: "The sign-in response was empty.")
        }
        return .complete(.code(code))
    }

    /// Parses the query of a request target, decoding `+` as space and percent-escapes.
    static func parseQuery(_ target: String) -> [String: String] {
        guard let q = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String {
                let plus = s.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            guard let k = kv.first else { continue }
            if out[dec(k)] == nil { out[dec(k)] = kv.count > 1 ? dec(kv[1]) : "" }
        }
        return out
    }

    private func respond(_ connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n" +
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// The small HTML pages shown in the browser at the end of sign-in. Self-contained: no scripts, no external resources.
enum SignInPages {
    private static func page(title: String, heading: String, detail: String, accent: String, glyph: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --bg:#f5f5f7; --card:#ffffff; --ink:#1d1d1f; --muted:#6e6e73; --line:rgba(0,0,0,.08); --accent:\(accent); }
        @media (prefers-color-scheme: dark) { :root { --bg:#111113; --card:#1c1c1f; --ink:#f5f5f7; --muted:#a1a1a6; --line:rgba(255,255,255,.1); } }
        * { box-sizing: border-box; }
        body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px; background:var(--bg); color:var(--ink);
               font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
        main { width:100%; max-width:420px; padding:40px 32px 32px; text-align:center; background:var(--card);
               border:1px solid var(--line); border-radius:20px; box-shadow:0 12px 40px rgba(0,0,0,.08); }
        .mark { width:64px; height:64px; margin:0 auto 20px; border-radius:50%; display:grid; place-items:center;
                background:color-mix(in srgb, var(--accent) 14%, transparent); color:var(--accent); font-size:30px; font-weight:600; }
        h1 { margin:0 0 8px; font-size:22px; font-weight:600; letter-spacing:-.01em; }
        p { margin:0; color:var(--muted); overflow-wrap:anywhere; }
        .foot { margin-top:24px; padding-top:16px; border-top:1px solid var(--line); font-size:13px; }
        </style></head>
        <body><main>
        <div class="mark" aria-hidden="true">\(glyph)</div>
        <h1>\(escape(heading))</h1>
        <p>\(escape(detail))</p>
        <p class="foot">Analytics Desktop</p>
        </main></body></html>
        """
    }

    static func success() -> String {
        page(title: "Signed in — Analytics Desktop", heading: "You're signed in",
             detail: "Return to \(AppIdentity.name) to continue. You can close this tab.", accent: "#1f8a4c", glyph: "&#10003;")
    }

    static func error(title: String, detail: String) -> String {
        // Keep long setup instructions out of the browser page; Facet shows the full message.
        let short = detail.count > 400 ? String(detail.prefix(400)) + "…" : detail
        return page(title: "Sign-in — Analytics Desktop", heading: title, detail: short + " Return to Analytics Desktop to try again.", accent: "#c4372b", glyph: "!")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Thread-safe "first caller wins" flag for resuming a continuation exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// Returns true for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
