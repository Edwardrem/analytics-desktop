import Foundation

/// The hosts a bearer token may be sent to, and the URLs the app may open in the browser, for one Microsoft cloud.
///
/// Tokens are only ever attached to `https` requests whose host is on this list. Everything else
/// (pre-authenticated download and upload URLs handed out by Graph) is sent without credentials.
public struct EndpointPolicy: Sendable, Equatable {
    /// Exact host names (lower-cased).
    public private(set) var hosts: Set<String>
    /// Host suffixes, each starting with a dot (OneLake uses regional and per-workspace sub-domains).
    public private(set) var hostSuffixes: Set<String>
    /// Hosts the system browser may be sent to for sign-in.
    public private(set) var signInHosts: Set<String>
    public let cloud: MicrosoftCloud

    public init(cloud: MicrosoftCloud, extraHosts: [String] = []) {
        self.cloud = cloud
        var h: Set<String> = []
        for url in [cloud.graphEndpoint, cloud.powerBIEndpoint, cloud.fabricEndpoint, cloud.oneLakeEndpoint] {
            if let host = url?.host?.lowercased() { h.insert(host) }
        }
        for e in extraHosts { h.insert(e.lowercased()) }
        hosts = h
        hostSuffixes = cloud == .public ? [".dfs.fabric.microsoft.com", ".onelake.fabric.microsoft.com"] : []
        var s: Set<String> = ["microsoft.com", "www.microsoft.com"]
        if let a = cloud.authorityHost.host?.lowercased() { s.insert(a) }
        signInHosts = s
    }

    /// Whether a bearer token may be attached to a request for `url`.
    public func allowsCredentials(for url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil else { return false }
        if hosts.contains(host) { return true }
        return hostSuffixes.contains { host.hasSuffix($0) && host.count > $0.count }
    }

    /// Whether a token for `resource` may be sent to `host` (audience-bound rules, `TokenAudiencePolicy`).
    public func allowsToken(resource: String, host: String) -> Bool {
        TokenAudiencePolicy.allows(resource: resource, host: host, cloud: cloud)
    }

    /// Whether `url` is a Microsoft sign-in page the browser may be opened at (authorize endpoint, device login).
    public func allowsSignInPage(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil else { return false }
        return signInHosts.contains(host)
    }

    /// Whether `uri` is a loopback redirect URI of the form `http://localhost:<port>` (the only kind the app uses).
    public static func isLoopbackRedirect(_ uri: String) -> Bool {
        guard let c = URLComponents(string: uri), c.scheme == "http", c.user == nil, c.query == nil, c.fragment == nil,
              let host = c.host?.lowercased(), host == "localhost" || host == "127.0.0.1",
              let port = c.port, (1024...65535).contains(port), c.path.isEmpty || c.path == "/" else { return false }
        return true
    }
}

/// Reads HTTP bodies with a hard size limit, so a misbehaving or hostile server cannot exhaust memory.
enum BoundedHTTP {
    /// Limit for identity-platform responses (token, device code).
    static let identityLimit = 1 * 1024 * 1024
    /// Limit for REST JSON responses (file lists, DAX query results, item definitions).
    static let restLimit = 256 * 1024 * 1024
    /// Limit for profile photos.
    static let photoLimit = 4 * 1024 * 1024

    struct TooLarge: Error { let limit: Int }

    /// Like `URLSession.data(for:)`, but stops and throws `TooLarge` once the body exceeds `limit` bytes.
    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw TooLarge(limit: limit)
        }
        var buffer = [UInt8]()
        buffer.reserveCapacity(min(limit, max(1024, Int(max(0, response.expectedContentLength)))))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > limit {
                bytes.task.cancel()
                throw TooLarge(limit: limit)
            }
        }
        return (Data(buffer), response)
    }
}

/// Session delegate for authenticated REST calls: a redirect to another host never carries the bearer token,
/// and a redirect away from `https` is refused.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// When false every redirect is refused (identity endpoints never redirect).
    let followRedirects: Bool
    init(followRedirects: Bool = true) { self.followRedirects = followRedirects }

    static func nextRequest(original: URLRequest?, proposed: URLRequest, followRedirects: Bool) -> URLRequest? {
        guard followRedirects, proposed.url?.scheme?.lowercased() == "https" else { return nil }
        var next = proposed
        if proposed.url?.host?.lowercased() != original?.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.nextRequest(original: task.originalRequest, proposed: request, followRedirects: followRedirects))
    }
}
