import XCTest
import FacetCore
@testable import FacetQuery

/// An in-process HTTP stand-in for cloud services. Every request is answered by `handler`; nothing reaches the network.
/// Tokens, keys and passwords used with it are obvious fakes.
final class CloudStub: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
        static func json(_ text: String, status: Int = 200) -> Response { Response(status: status, body: Data(text.utf8)) }
        static func bytes(_ data: Data, type: String = "application/octet-stream") -> Response {
            Response(headers: ["Content-Type": type], body: data)
        }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> Response)?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: ((URLRequest) -> Response)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; _requests = []; lock.unlock() }
    }
    /// Requests seen since the handler was set, with their bodies read into `httpBody`.
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    static func install() {
        URLProtocol.registerClass(CloudStub.self)
        CloudHTTP.protocolClasses = [CloudStub.self]
    }
    static func uninstall() {
        URLProtocol.unregisterClass(CloudStub.self)
        CloudHTTP.protocolClasses = nil
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var seen = request
        if seen.httpBody == nil, let stream = seen.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            seen.httpBody = data
        }
        Self.lock.lock(); Self._requests.append(seen); let h = Self._handler; Self.lock.unlock()
        let r = h?(seen) ?? Response(status: 599, body: Data("no stub".utf8))
        guard let url = request.url, let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Credentials for tests: fixed stored credentials, and a token per resource. Records every token request.
final class FakeCredentials: CredentialProvider, @unchecked Sendable {
    var stored: [String: SourceCredential] = [:]
    /// Hosts allowed per resource; nil allows any host.
    var allowedHosts: [String: Set<String>]?
    private let lock = NSLock()
    private var _calls: [(resource: String, host: String)] = []
    var calls: [(resource: String, host: String)] { lock.lock(); defer { lock.unlock() }; return _calls }

    func credential(kind: String, location: String) -> SourceCredential? { stored["\(kind)|\(location)"] }
    private func record(_ resource: String, _ host: String) { lock.lock(); _calls.append((resource, host)); lock.unlock() }
    func accessToken(resource: String, host: String) async throws -> String {
        record(resource, host)
        if let allowed = allowedHosts, !(allowed[resource]?.contains(host) ?? false) {
            throw MError.dataSource("Refused to send a token for \(resource) to \(host).")
        }
        return "FAKE-TOKEN-for-" + resource
    }
}

class CloudStubTestCase: XCTestCase {
    var creds: FakeCredentials!
    var env: QueryEnvironment!
    override func setUp() {
        super.setUp()
        CloudStub.install()
        creds = FakeCredentials()
        env = QueryEnvironment(credentials: creds)
    }
    override func tearDown() { CloudStub.uninstall(); super.tearDown() }
    func eval(_ text: String) throws -> MValue { try MInterpreter(environment: env).evaluate(text) }
    func failure(_ text: String) -> MError? {
        do { _ = try eval(text); return nil } catch { return MError.wrap(error) }
    }
    func rows(_ text: String) throws -> [[String]] { try tableRows(try eval(text)) }
    func bearer(_ r: URLRequest) -> String? { r.value(forHTTPHeaderField: "Authorization") }
}
