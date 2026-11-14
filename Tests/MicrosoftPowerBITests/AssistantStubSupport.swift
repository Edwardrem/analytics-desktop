import Foundation
import XCTest
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// An in-process stand-in for the Anthropic Messages API: answers each request with the next queued reply as
/// a server-sent event stream, and records what it was sent. No request leaves the machine.
final class AssistantStubProtocol: URLProtocol {
    struct Seen { var headers: [String: String]; var body: FacetCloud.JSONValue }

    private static let lock = NSLock()
    private static var replies: [String] = []
    private static var _seen: [Seen] = []

    static var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }

    static func reset(replies: [String]) {
        lock.lock(); self.replies = replies; _seen = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
        }
        Self.lock.lock()
        Self._seen.append(Seen(headers: request.allHTTPHeaderFields ?? [:], body: (try? FacetCloud.JSONValue.parse(body)) ?? .null))
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        let status = reply == nil ? 500 : 200
        let payload = reply.map { Self.events(text: $0) }
            ?? Data(#"{"type":"error","error":{"type":"api_error","message":"no stub reply queued"}}"#.utf8)
        let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The SSE stream of a response whose only content is `text`.
    static func events(text: String) -> Data {
        let quoted = FacetCloud.JSONValue.string(text).serialized()
        let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_stub","model":"claude-sonnet-5-5","usage":{"input_tokens":10}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\(quoted)}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        return Data(stream.utf8)
    }
}

@MainActor
enum AssistantStub {
    static let key = "sk-ant-test-key"

    /// A client with a key in memory (never the Keychain) whose requests go to `AssistantStubProtocol`.
    static func client(configured: Bool = true) -> AssistantClient {
        let keys = InMemorySecretStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssistantStubProtocol.self]
        let client = AssistantClient(configuration: AssistantConfiguration(), keyStore: keys, sessionConfiguration: config)
        client.maxRetries = 0
        if configured { try? client.setAPIKey(key) }
        return client
    }

    /// Routes every one-shot assistant feature to the stub, answering with `replies` in order.
    static func install(replies: [String], configured: Bool = true) {
        AssistantStubProtocol.reset(replies: replies)
        AssistantTasks.makeClient = { client(configured: configured) }
    }

    static func uninstall() {
        AssistantTasks.makeClient = { AssistantClient() }
        AssistantStubProtocol.reset(replies: [])
    }

    /// The text of every message in a recorded request, in order.
    static func messageTexts(_ seen: AssistantStubProtocol.Seen) -> [String] {
        (seen.body["messages"]?.arrayValue ?? []).map { m in
            (m["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
        }
    }

    /// The system prompt of a recorded request.
    static func systemText(_ seen: AssistantStubProtocol.Seen) -> String {
        (seen.body["system"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }
}
