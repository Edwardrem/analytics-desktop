import Foundation
import FacetCore

/// A block of the system prompt.
public struct AssistantSystemBlock: Sendable, Equatable {
    public var text: String
    /// Marks the end of a stable prefix that should be prompt-cached (`cache_control: ephemeral`).
    public var cache: Bool
    public init(_ text: String, cache: Bool = false) { self.text = text; self.cache = cache }
}

/// One Messages API request.
public struct AssistantRequest: Sendable {
    public var system: [AssistantSystemBlock]
    public var messages: [AssistantMessage]
    public var tools: [AssistantTool]
    public init(system: [AssistantSystemBlock] = [], messages: [AssistantMessage], tools: [AssistantTool] = []) {
        self.system = system; self.messages = messages; self.tools = tools
    }
}

/// Client for the Anthropic Claude Messages API (`POST /v1/messages`) with SSE streaming.
///
/// - The API key lives in the Keychain (service `AppIdentity.keychainService("assistant")`) and is never logged.
/// - Nothing is sent unless the app calls `stream`/`countTokens`; there is no telemetry.
/// - `AssistantSession` builds on this to manage history, prompt caching and the tool-use loop.
public final class AssistantClient: @unchecked Sendable {
    public static let keychainService = AppIdentity.keychainService("assistant")
    static let apiKeyAccount = "anthropic-api-key"
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let keyStore: SecretStoring
    private let session: URLSession
    private let baseURL: URL
    private let lock = NSLock()
    private var _configuration: AssistantConfiguration
    /// Automatic retries for rate-limit/overload/server errors that occur before any output is received.
    public var maxRetries = 2
    var sleeper: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    public var configuration: AssistantConfiguration {
        get { lock.lock(); defer { lock.unlock() }; return _configuration }
        set { lock.lock(); _configuration = newValue; lock.unlock() }
    }

    public init(configuration: AssistantConfiguration = .load(),
                keyStore: SecretStoring = KeychainStore(service: AssistantClient.keychainService),
                sessionConfiguration: URLSessionConfiguration? = nil,
                baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self._configuration = configuration
        self.keyStore = keyStore
        self.baseURL = baseURL
        let cfg = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 600   // idle time between stream events; long reasoning pauses are normal
            c.timeoutIntervalForResource = 3600
            return c
        }()
        self.session = URLSession(configuration: cfg)
    }

    // MARK: API key

    /// True when an API key is stored.
    public var isConfigured: Bool { (try? keyStore.getString(account: Self.apiKeyAccount))??.isEmpty == false }

    /// Saves the Anthropic API key to the Keychain. An empty key removes it.
    public func setAPIKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try keyStore.delete(account: Self.apiKeyAccount) }
        else { try keyStore.setString(k, account: Self.apiKeyAccount) }
    }
    public func removeAPIKey() throws { try keyStore.delete(account: Self.apiKeyAccount) }

    private func apiKey() throws -> String {
        guard let k = try keyStore.getString(account: Self.apiKeyAccount), !k.isEmpty else { throw AssistantError.notConfigured }
        return k
    }

    // MARK: Request building

    /// The JSON body for a streaming Messages request. Deterministic for identical inputs (tools are sorted by
    /// name) so the prompt cache prefix stays byte-stable.
    static func body(for request: AssistantRequest, configuration: AssistantConfiguration, stream: Bool = true) -> JSONValue {
        var members: [JSONMember] = [
            JSONMember(key: "model", value: .string(configuration.modelID)),
            JSONMember(key: "max_tokens", value: .int(Int64(configuration.maxOutputTokens))),
        ]
        if stream { members.append(JSONMember(key: "stream", value: true)) }
        if !request.tools.isEmpty {
            members.append(JSONMember(key: "tools", value: .array(request.tools.sorted { $0.name < $1.name }.map(\.definition))))
        }
        let system = request.system.filter { !$0.text.isEmpty }
        if !system.isEmpty {
            members.append(JSONMember(key: "system", value: .array(system.map { b in
                b.cache ? ["type": "text", "text": .string(b.text), "cache_control": ["type": "ephemeral"]]
                        : ["type": "text", "text": .string(b.text)]
            })))
        }
        members.append(JSONMember(key: "messages", value: .array(request.messages.map(\.json))))
        // Automatic caching of the growing conversation tail, alongside the explicit system breakpoint.
        members.append(JSONMember(key: "cache_control", value: ["type": "ephemeral"]))
        if configuration.showThinkingSummaries {
            members.append(JSONMember(key: "thinking", value: ["type": "adaptive", "display": "summarized"]))
        }
        if let effort = configuration.effort {
            members.append(JSONMember(key: "output_config", value: ["effort": .string(effort.rawValue)]))
        }
        if configuration.refusalFallback, AssistantModel.supportsServerFallback(configuration.modelID) {
            members.append(JSONMember(key: "fallbacks", value: "default"))
        }
        return .object(members)
    }

    func urlRequest(path: String, body: JSONValue, configuration: AssistantConfiguration, streaming: Bool) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue(try apiKey(), forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if body["fallbacks"] != nil { r.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        r.httpBody = body.serializedData()
        return r
    }

    // MARK: Streaming

    /// Sends one request and streams the response. Events end with `.responseFinished`.
    /// Cancelling the consuming task (or dropping the stream) cancels the HTTP request.
    public func stream(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func normalize(_ error: Error) -> Error {
        if error is AssistantError || error is CancellationError { return error }
        if let e = error as? URLError { return e.code == .cancelled ? CancellationError() : AssistantError.network(e.localizedDescription) }
        return error
    }

    private func run(_ request: AssistantRequest, emit: (AssistantEvent) -> Void) async throws {
        let cfg = configuration
        let urlRequest = try self.urlRequest(path: "v1/messages", body: Self.body(for: request, configuration: cfg), configuration: cfg, streaming: true)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var accumulator = AssistantStreamAccumulator()
            do {
                CloudLog.log("→ " + CloudLog.redactedDescription(of: urlRequest))
                let (bytes, response) = try await session.bytes(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { throw AssistantError.invalidResponse("not an HTTP response") }
                guard http.statusCode == 200 else {
                    var body = Data()
                    for try await b in bytes { body.append(b); if body.count > 65_536 { break } }
                    throw AssistantError.from(status: http.statusCode, body: body) { http.value(forHTTPHeaderField: $0) }
                }
                var parser = SSEParser()
                for try await byte in bytes {
                    guard let sse = parser.feed(byte) else { continue }
                    for event in try accumulator.consume(sse) { emit(event) }
                    if accumulator.isComplete { break }
                }
                guard accumulator.isComplete else { throw AssistantError.network("the response stream ended early") }
                emit(.responseFinished(accumulator.response()))
                return
            } catch {
                let e = Self.normalize(error)
                // Retry only when nothing has been shown yet, so text is never duplicated.
                guard let ae = e as? AssistantError, ae.isRetryable, !accumulator.hasEmittedContent, attempt < maxRetries else { throw e }
                var retryAfter: TimeInterval?
                switch ae {
                case .rateLimited(let r, _, _), .overloaded(let r, _): retryAfter = r
                default: break
                }
                try await sleeper(HTTPHelpers.backoffDelay(attempt: attempt, retryAfter: retryAfter, base: 1, cap: 20, retryAfterCap: 60))
                attempt += 1
            }
        }
    }

    // MARK: Token counting

    /// Counts the input tokens a request would use (`POST /v1/messages/count_tokens`). Makes a network call.
    public func countTokens(_ request: AssistantRequest) async throws -> Int {
        let cfg = configuration
        var members = (Self.body(for: request, configuration: cfg, stream: false).members ?? [])
        members.removeAll { ["max_tokens", "fallbacks", "cache_control"].contains($0.key) }
        let urlRequest = try self.urlRequest(path: "v1/messages/count_tokens", body: .object(members), configuration: cfg, streaming: false)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw AssistantError.invalidResponse("not an HTTP response") }
            guard http.statusCode == 200 else {
                throw AssistantError.from(status: http.statusCode, body: data) { http.value(forHTTPHeaderField: $0) }
            }
            guard let n = (try? JSONValue.parse(data))?["input_tokens"]?.intValue else {
                throw AssistantError.invalidResponse("no token count in the response")
            }
            return Int(n)
        } catch {
            throw Self.normalize(error)
        }
    }
}
