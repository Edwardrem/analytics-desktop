import Foundation
import Network
import Security
import FacetCore

/// What the PRELOGIN framer and the TLS verify block share with the transport that created them.
final class TDSHandshakeState: @unchecked Sendable {
    let preloginPackets: [UInt8]
    /// Set once, before the connection starts.
    var tlsOptions = NWProtocolTLS.Options()
    private let lock = NSLock()
    private var _response: TDSPrelogin.Response?
    private var _failure: String?
    init(preloginPackets: [UInt8]) { self.preloginPackets = preloginPackets }
    var response: TDSPrelogin.Response? {
        get { lock.lock(); defer { lock.unlock() }; return _response }
        set { lock.lock(); _response = newValue; lock.unlock() }
    }
    /// Why the handshake failed, in words for the user (first reason wins).
    var failure: String? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); if _failure == nil { _failure = newValue }; lock.unlock() }
    }
}

/// A framer below TLS for TDS 7.x: it sends PRELOGIN in the clear, then carries the TLS handshake inside TDS
/// PRELOGIN packets (MS-TDS 3.2.5.2), then steps aside once the first TLS application-data record goes out.
final class TDSPreloginFramer: NWProtocolFramerImplementation {
    static let label = "TDS PRELOGIN"
    static let definition = NWProtocolFramer.Definition(implementation: TDSPreloginFramer.self)
    static let stateKey = "Facet.TDS.handshake"

    private enum Phase { case prelogin, handshake, raw }
    private var phase = Phase.prelogin
    private var state: TDSHandshakeState?
    private var preloginPayload: [UInt8] = []
    /// Bytes of the TLS record that the previous output message left unfinished.
    private var recordRemaining = 0

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let s = framer.options[Self.stateKey] as? TDSHandshakeState else {
            framer.markFailed(error: .posix(.EINVAL))
            return .willMarkReady
        }
        state = s
        framer.writeOutput(data: Data(s.preloginPackets))
        return .willMarkReady
    }

    /// Parse one whole TDS packet from the input; nil when more bytes are needed.
    private func packet(_ framer: NWProtocolFramer.Instance) -> (type: UInt8, status: UInt8, payload: [UInt8])? {
        var length = 0
        _ = framer.parseInput(minimumIncompleteLength: 8, maximumLength: 8) { buffer, _ in
            if let b = buffer, b.count >= 8 { length = Int(b[2]) << 8 | Int(b[3]) }
            return 0
        }
        guard length > 0 else { return nil }
        guard length >= 8, length <= TDSLimits.maxPacketSize else {
            state?.failure = "The server sent a malformed PRELOGIN packet."
            framer.markFailed(error: .posix(.EBADMSG))
            return nil
        }
        var result: (UInt8, UInt8, [UInt8])?
        _ = framer.parseInput(minimumIncompleteLength: length, maximumLength: length) { buffer, _ in
            guard let b = buffer, b.count >= length else { return 0 }
            result = (b[0], b[1], Array(b[8..<length]))
            return length
        }
        return result
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            switch phase {
            case .prelogin:
                guard let p = packet(framer) else { return 8 }
                preloginPayload += p.payload
                guard preloginPayload.count <= 4096 else { state?.failure = "The PRELOGIN response is too large."; framer.markFailed(error: .posix(.EBADMSG)); return 0 }
                guard p.status & 0x01 != 0 else { continue }
                guard let state else { return 0 }
                do {
                    let response = try TDSPrelogin.parse(preloginPayload)
                    state.response = response
                    guard response.encryption == TDSPrelogin.Encryption.on.rawValue || response.encryption == TDSPrelogin.Encryption.required.rawValue else {
                        state.failure = "The server doesn't support encrypted connections, and \(AppIdentity.name) only connects with encryption. Install a certificate on the server, or use Encrypt = \"Strict\" on SQL Server 2022."
                        framer.markFailed(error: .posix(.EPROTONOSUPPORT))
                        return 0
                    }
                    try framer.prependApplicationProtocol(options: state.tlsOptions)
                    phase = .handshake
                    framer.markReady()
                } catch {
                    state.failure = (error as? TDSError)?.message ?? "Couldn't start TLS: \(error.localizedDescription)"
                    framer.markFailed(error: .posix(.EPROTO))
                    return 0
                }
            case .handshake:
                guard let p = packet(framer) else { return 8 }
                guard p.type == TDSPacketType.prelogin.rawValue || p.type == TDSPacketType.tabularResult.rawValue else {
                    state?.failure = "The server sent an unexpected packet during the TLS handshake."
                    framer.markFailed(error: .posix(.EBADMSG))
                    return 0
                }
                let message = NWProtocolFramer.Message(definition: Self.definition)
                framer.deliverInput(data: Data(p.payload), message: message, isComplete: false)
            case .raw:
                var bytes = Data()
                _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65536) { buffer, _ in
                    guard let b = buffer, !b.isEmpty else { return 0 }
                    bytes = Data(b)
                    return b.count
                }
                guard !bytes.isEmpty else { return 1 }
                framer.deliverInput(data: bytes, message: NWProtocolFramer.Message(definition: Self.definition), isComplete: false)
            }
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        guard phase == .handshake else {
            try? framer.writeOutputNoCopy(length: messageLength)
            return
        }
        var bytes: [UInt8] = []
        _ = framer.parseOutput(minimumIncompleteLength: messageLength, maximumLength: messageLength) { buffer, _ in
            guard let b = buffer else { return 0 }
            bytes = Array(b)
            return b.count
        }
        // Walk the TLS records: handshake records are wrapped, the first application-data record ends wrapping.
        var i = 0, split = bytes.count
        while i < bytes.count {
            if recordRemaining > 0 {
                let step = min(recordRemaining, bytes.count - i)
                i += step; recordRemaining -= step
                continue
            }
            if bytes[i] == 0x17 { split = i; break }
            guard i + 5 <= bytes.count else { i = bytes.count; break }
            recordRemaining = 5 + (Int(bytes[i + 3]) << 8 | Int(bytes[i + 4]))
        }
        if split > 0 {
            framer.writeOutput(data: Data(TDSWriter.packets(.prelogin, Array(bytes[0..<split]), packetSize: TDSLimits.initialPacketSize)))
        }
        if split < bytes.count {
            phase = .raw
            framer.writeOutput(data: Data(bytes[split...]))
        }
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

/// A blocking TCP connection to SQL Server with TLS: inside TDS (7.4) or first (8.0 strict). Every wait has a deadline.
final class TDSTransport: TDSByteInput, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Facet.TDS.connection")
    private let lock = NSLock()
    private var _deadline: Date?
    private var _cancelled = false
    let host: String
    let port: Int
    /// The server's PRELOGIN answer (TDS 7.4 connections; strict connections read it after TLS).
    private(set) var preloginResponse: TDSPrelogin.Response?

    /// Reads and writes fail after this time (the command timeout).
    var deadline: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _deadline }
        set { lock.lock(); _deadline = newValue; lock.unlock() }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    private init(connection: NWConnection, host: String, port: Int) { self.connection = connection; self.host = host; self.port = port }

    /// TLS settings: certificate checked against the host name unless the source trusts the server certificate.
    private static func tlsOptions(host: String, trustServerCertificate: Bool, strict: Bool,
                                   failure: @escaping @Sendable (String) -> Void) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        // TLS carried inside TDS packets is TLS 1.2 on every SQL Server version; TDS 8.0 allows 1.3.
        sec_protocol_options_set_max_tls_protocol_version(sec, strict ? .TLSv13 : .TLSv12)
        sec_protocol_options_set_tls_server_name(sec, host)
        if strict { sec_protocol_options_add_tls_application_protocol(sec, "tds/8.0") }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            if trustServerCertificate { complete(true); return }
            let ref = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(ref, SecPolicyCreateSSL(true, host as CFString))
            var error: CFError?
            let ok = SecTrustEvaluateWithError(ref, &error)
            if !ok {
                let reason = (error.map { CFErrorCopyDescription($0) as String }) ?? "it isn't trusted"
                failure("The server's certificate couldn't be verified for '\(host)': \(reason). If you trust this network, turn on “Trust server certificate” for this source.")
            }
            complete(ok)
        }, DispatchQueue(label: "Facet.TDS.verify"))
        return tls
    }

    /// Connect with TDS 7.4 encryption: PRELOGIN in the clear, then TLS inside TDS packets.
    static func connect(host: String, port: Int, prelogin: [UInt8], trustServerCertificate: Bool, timeout: TimeInterval) throws -> TDSTransport {
        let state = TDSHandshakeState(preloginPackets: TDSWriter.packets(.prelogin, prelogin, packetSize: TDSLimits.initialPacketSize))
        state.tlsOptions = tlsOptions(host: host, trustServerCertificate: trustServerCertificate, strict: false) { state.failure = $0 }
        let params = NWParameters(tls: nil, tcp: tcpOptions(timeout))
        let framer = NWProtocolFramer.Options(definition: TDSPreloginFramer.definition)
        framer[TDSPreloginFramer.stateKey] = state
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        let t = TDSTransport(connection: NWConnection(host: NWEndpoint.Host(host), port: try nwPort(port), using: params), host: host, port: port)
        try t.start(timeout: timeout) { state.failure }
        t.preloginResponse = state.response
        return t
    }

    /// Connect with TDS 8.0 strict encryption: TLS first (ALPN "tds/8.0").
    static func connectStrict(host: String, port: Int, trustServerCertificate: Bool, timeout: TimeInterval) throws -> TDSTransport {
        let reason = TDSHandshakeState(preloginPackets: [])
        let tls = tlsOptions(host: host, trustServerCertificate: trustServerCertificate, strict: true) { reason.failure = $0 }
        let params = NWParameters(tls: tls, tcp: tcpOptions(timeout))
        let t = TDSTransport(connection: NWConnection(host: NWEndpoint.Host(host), port: try nwPort(port), using: params), host: host, port: port)
        try t.start(timeout: timeout) { reason.failure }
        return t
    }

    private static func tcpOptions(_ timeout: TimeInterval) -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        return tcp
    }
    private static func nwPort(_ port: Int) throws -> NWEndpoint.Port {
        guard port > 0, port <= 65535, let p = NWEndpoint.Port(rawValue: UInt16(port)) else { throw TDSError.connection("The port \(port) isn't valid.") }
        return p
    }

    private func start(timeout: TimeInterval, reason: @escaping () -> String?) throws {
        let done = DispatchSemaphore(value: 0)
        let outcome = TDSBox<Result<Void, TDSError>?>(nil)
        let target = "\(host),\(port)"
        connection.stateUpdateHandler = { state in
            func finish(_ r: Result<Void, TDSError>) { if outcome.setIfEmpty(r) { done.signal() } }
            switch state {
            case .ready: finish(.success(()))
            case .failed(let e), .waiting(let e):
                if let r = reason() { finish(.failure(TDSError(kind: .tls, message: r))); return }
                finish(.failure(TDSTransport.describe(e, target: target)))
            case .cancelled: finish(.failure(TDSError(kind: .cancelled, message: "The connection to '\(target)' was cancelled.")))
            default: break
            }
        }
        connection.start(queue: queue)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw TDSError(kind: .timeout, message: "Couldn't connect to '\(target)' within \(Int(timeout)) seconds. Check the server name and port, and that the firewall allows TCP connections.")
        }
        if case .failure(let e)? = outcome.value { connection.cancel(); throw e }
    }

    static func describe(_ e: NWError, target: String) -> TDSError {
        switch e {
        case .posix(.ECONNREFUSED): return .connection("The server '\(target)' refused the connection. Check that SQL Server is running and accepts TCP/IP connections on that port.")
        case .dns: return .connection("The server name '\(target)' couldn't be found.")
        case .tls(let status): return TDSError(kind: .tls, message: "The secure connection to '\(target)' failed (\(status)).")
        default: return .connection("Couldn't connect to '\(target)': \(e.localizedDescription)")
        }
    }

    private func waitDeadline() -> DispatchTime {
        guard let d = deadline else { return .distantFuture }
        return .now() + max(0, d.timeIntervalSinceNow)
    }

    func send(_ bytes: [UInt8]) throws {
        let done = DispatchSemaphore(value: 0)
        let failure = TDSBox<NWError?>(nil)
        connection.send(content: Data(bytes), completion: .contentProcessed { error in failure.value = error; done.signal() })
        if done.wait(timeout: waitDeadline()) == .timedOut { throw TDSError(kind: .timeout, message: "Sending to the server timed out.") }
        if isCancelled { throw TDSError(kind: .cancelled, message: "The query was cancelled.") }
        if let e = failure.value { throw TDSTransport.describe(e, target: "\(host),\(port)") }
    }

    func read(maximum: Int) throws -> [UInt8] {
        let done = DispatchSemaphore(value: 0)
        let result = TDSBox<Result<[UInt8], TDSError>?>(nil)
        let target = "\(host),\(port)"
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, complete, error in
            if let data, !data.isEmpty { result.value = .success([UInt8](data)) }
            else if let error { result.value = .failure(TDSTransport.describe(error, target: target)) }
            else if complete { result.value = .failure(.connection("The server closed the connection.")) }
            else { result.value = .failure(.connection("The server sent no data.")) }
            done.signal()
        }
        if done.wait(timeout: waitDeadline()) == .timedOut {
            throw TDSError(kind: .timeout, message: "The server didn't answer in time.")
        }
        if isCancelled { throw TDSError(kind: .cancelled, message: "The query was cancelled.") }
        guard let r = result.value else { throw TDSError.connection("The server sent no data.") }
        return try r.get()
    }

    /// Send ATTENTION (cancel the running request), then close: a cancelled or timed-out connection is not reused.
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        let attention = TDSWriter.packets(.attention, [], packetSize: TDSLimits.initialPacketSize)
        connection.send(content: Data(attention), completion: .contentProcessed { [connection] _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 2) { [connection] in connection.cancel() }
    }

    func close() { connection.cancel() }
}

/// A lock-protected value shared with Network callbacks.
final class TDSBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    /// Set when still nil-like (first writer wins); returns whether this call set it.
    func setIfEmpty<U>(_ v: U) -> Bool where T == U? {
        lock.lock(); defer { lock.unlock() }
        if _value != nil { return false }
        _value = v
        return true
    }
}
