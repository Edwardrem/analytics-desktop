import Foundation
import Network
import Security

/// The plaintext exchange some protocols need before TLS starts on the same connection (PostgreSQL's SSLRequest,
/// MySQL's greeting and SSLRequest). It runs inside a framer placed below TLS, so the TLS handshake begins only
/// once the server has agreed.
class StartTLSNegotiator: @unchecked Sendable {
    enum Step { case needMore, startTLS(send: Data), fail(String) }
    /// Why the negotiation failed, for the error shown to the user.
    var failure: String?
    /// Bytes sent as soon as the TCP connection is up (may be empty).
    func opening() -> Data { Data() }
    /// Called with everything received so far.
    func received(_ buffer: Data) -> Step { .fail("The server answered before TLS was requested.") }
}

/// Framer that performs a `StartTLSNegotiator`'s exchange, then passes bytes straight through.
private final class StartTLSFramer: NWProtocolFramerImplementation {
    static let label = "FacetStartTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
    static let optionKey = "negotiator"
    private var negotiator: StartTLSNegotiator?
    private var buffer = Data()
    private var finished = false

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let n = framer.options[Self.optionKey] as? StartTLSNegotiator else { return .ready }
        negotiator = n
        let first = n.opening()
        if !first.isEmpty { framer.writeOutput(data: first) }
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard !finished, let negotiator else { return 0 }
        while true {
            var chunk: Data?
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65_536) { buf, _ in
                guard let buf, buf.count > 0 else { return 0 }
                chunk = Data(buf)
                return buf.count
            }
            guard parsed, let chunk else { return 1 }
            buffer.append(chunk)
            guard buffer.count <= 1 << 20 else {
                negotiator.failure = "The server sent too much before TLS started."
                finished = true
                framer.markFailed(error: .posix(.EPROTO))
                return 0
            }
            switch negotiator.received(buffer) {
            case .needMore: continue
            case .startTLS(let send):
                if !send.isEmpty { framer.writeOutput(data: send) }
                finished = true
                framer.passThroughOutput()
                framer.passThroughInput()
                framer.markReady()
                return 0
            case .fail(let message):
                negotiator.failure = message
                finished = true
                framer.markFailed(error: .posix(.EPROTO))
                return 0
            }
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

/// A host and port typed as `host`, `host:port`, `host,port` or `[v6address]:port`.
struct ServerAddress: Equatable, Sendable {
    var host: String
    var port: UInt16

    static func parse(_ text: String, defaultPort: UInt16) throws -> ServerAddress {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw WireError("Type the server name.") }
        func port(_ p: Substring) throws -> UInt16 {
            guard let n = UInt16(p.trimmingCharacters(in: .whitespaces)), n > 0 else { throw WireError("The port in '\(s)' isn't a number between 1 and 65535.") }
            return n
        }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { throw WireError("The server '\(s)' is missing a closing ']'.") }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.isEmpty { return ServerAddress(host: host, port: defaultPort) }
            guard after.first == ":" || after.first == "," else { throw WireError("Couldn't read the server '\(s)'.") }
            return ServerAddress(host: host, port: try port(after.dropFirst()))
        }
        if let comma = s.lastIndex(of: ",") {
            return ServerAddress(host: String(s[..<comma]).trimmingCharacters(in: .whitespaces), port: try port(s[s.index(after: comma)...]))
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let colon = s.firstIndex(of: ":") {
            return ServerAddress(host: String(s[..<colon]), port: try port(s[s.index(after: colon)...]))
        }
        // No port, or a bare IPv6 address.
        return ServerAddress(host: s, port: defaultPort)
    }
    var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// A blocking TCP connection on Network.framework with optional TLS, for the engine's worker thread. Every wait has
/// a deadline; a timed-out connection is closed.
final class WireSocket: @unchecked Sendable {
    struct TLS {
        /// Accept a certificate that doesn't verify (self-signed, wrong name). Off by default.
        var trustServerCertificate = false
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "facet.wire.socket")
    private var buffer = Data()
    private var cursor = 0
    private var closed = false
    /// Filled in by the TLS verify block, on the socket's queue, before the connection becomes ready.
    private final class TrustState: @unchecked Sendable { var leaf: Data?; var failure: String? }
    private let trust = TrustState()
    private var trustFailure: String? { trust.failure }
    private let negotiator: StartTLSNegotiator?
    let address: ServerAddress
    let usesTLS: Bool
    /// The server's leaf certificate (DER), when TLS is in use: for channel binding.
    var peerCertificate: Data? { trust.leaf }

    /// Connect; with `tls`, TLS starts after the `negotiator`'s exchange (or at once without one).
    init(address: ServerAddress, tls: TLS?, negotiator: StartTLSNegotiator?, timeout: TimeInterval) throws {
        self.address = address
        self.usesTLS = tls != nil
        self.negotiator = negotiator
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcp.noDelay = true
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            let sec = options.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            sec_protocol_options_set_tls_server_name(sec, address.host)
            let host = address.host, trustAnyway = tls.trustServerCertificate, state = trust
            parameters = NWParameters(tls: options, tcp: tcp)
            sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))
                if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                    state.leaf = SecCertificateCopyData(leaf) as Data
                }
                var error: CFError?
                let trusted = SecTrustEvaluateWithError(secTrust, &error)
                if !trusted { state.failure = (error as Error?)?.localizedDescription ?? "The certificate couldn't be verified." }
                complete(trusted || trustAnyway)
            }, queue)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        if let negotiator {
            let framer = NWProtocolFramer.Options(definition: StartTLSFramer.definition)
            framer[StartTLSFramer.optionKey] = negotiator
            // Below TLS (the list runs from the top of the stack down).
            parameters.defaultProtocolStack.applicationProtocols.append(framer)
        }
        connection = NWConnection(host: NWEndpoint.Host(address.host), port: NWEndpoint.Port(rawValue: address.port) ?? 5432, using: parameters)
        try start(timeout: timeout)
    }

    private func start(timeout: TimeInterval) throws {
        let ready = DispatchSemaphore(value: 0)
        var outcome: Result<Void, Error>?
        let lock = NSLock()
        func finish(_ r: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard outcome == nil else { return }
            outcome = r
            ready.signal()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(.success(()))
            case .failed(let e): finish(.failure(e))
            case .waiting(let e):
                // The host can't be reached now (DNS failure, refused, no route): fail rather than wait.
                finish(.failure(e))
            case .cancelled: finish(.failure(WireError("The connection was closed.")))
            default: break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw WireError("Couldn't connect to \(address.description) within \(Int(timeout)) seconds.", code: "timeout")
        }
        lock.lock(); let result = outcome; lock.unlock()
        if case .failure(let e)? = result {
            connection.cancel()
            throw describe(e)
        }
    }

    private func describe(_ error: Error) -> WireError {
        if let message = negotiator?.failure { return WireError(message) }
        if let trustFailure {
            return WireError("The server's certificate isn't trusted (\(trustFailure)). Install its certificate authority, or turn on "
                             + "Trust server certificate for this source only if you know the server.")
        }
        if let e = error as? WireError { return e }
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code) where code == .ECONNREFUSED:
                return WireError("The server \(address.description) refused the connection. Check the server name and port, and that the database accepts TCP connections.")
            case .dns:
                return WireError("The server name '\(address.host)' couldn't be found.")
            case .tls(let status):
                return WireError("The TLS connection to \(address.description) failed (\(status)).")
            default:
                return WireError("Couldn't connect to \(address.description): \(nw.localizedDescription)")
            }
        }
        return WireError("Couldn't connect to \(address.description): \(error.localizedDescription)")
    }

    func send(_ data: Data, timeout: TimeInterval) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.send(content: data, completion: .contentProcessed { e in failure = e; done.signal() })
        if done.wait(timeout: .now() + timeout) == .timedOut {
            close()
            throw WireError("Sending to the server timed out after \(Int(timeout)) seconds.", code: "timeout")
        }
        if let failure { close(); throw describe(failure) }
    }

    /// Exactly `n` bytes, waiting until `deadline` at most.
    func read(_ n: Int, deadline: DispatchTime) throws -> Data {
        guard n >= 0 else { throw WireError.malformed("length") }
        while buffer.count - cursor < n {
            try receiveMore(deadline: deadline)
        }
        let out = Data(buffer[cursor..<(cursor + n)])
        cursor += n
        if cursor > 1 << 20, cursor > buffer.count / 2 {
            buffer = Data(buffer[cursor...])
            cursor = 0
        }
        return out
    }

    private func receiveMore(deadline: DispatchTime) throws {
        guard !closed else { throw WireError("The connection to the server was closed.") }
        let done = DispatchSemaphore(value: 0)
        var chunk: Data?, ended = false, failure: Error?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            chunk = data; ended = isComplete; failure = error
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            close()
            throw WireError("The server didn't answer in time.", code: "timeout")
        }
        if let failure { close(); throw describe(failure) }
        if let chunk, !chunk.isEmpty { buffer.append(chunk); return }
        if ended { close(); throw WireError("The server closed the connection.") }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }
    deinit { close() }
}
