import Foundation

// MARK: - Token provider protocols

/// Supplies bearer tokens for a resource. `resource` is either an OAuth scope string
/// (e.g. `https://api.fabric.microsoft.com/.default`) or a bare resource URL, in which case `/.default` is implied.
/// The app bridges this to other modules (for example the query engine's `CredentialProvider`).
public protocol AccessTokenProviding: AnyObject {
    func accessToken(resource: String) async throws -> String
}

/// A token provider that can bypass its cache, used to recover from an HTTP 401.
public protocol RefreshableAccessTokenProviding: AccessTokenProviding {
    func accessToken(resource: String, forceRefresh: Bool) async throws -> String
}

// MARK: - Errors

/// An error returned by a Microsoft REST service (Graph, Power BI, Fabric, OneLake).
public struct CloudAPIError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case badRequest, unauthorized, forbidden, notFound, conflict, preconditionFailed
        case throttled, serviceUnavailable, serverError, invalidResponse, other
    }
    /// Human-readable service name: "Microsoft Graph", "Power BI", "Fabric", "OneLake".
    public var service: String
    public var kind: Kind
    public var statusCode: Int
    /// The service's own error code, e.g. `itemNotFound`, `PowerBIEntityNotFound`.
    public var code: String?
    /// The service's own message.
    public var message: String
    /// The service request id (`request-id`, `RequestId`, `x-ms-request-id`), for support tickets.
    public var requestID: String?
    public var retryAfter: TimeInterval?

    public init(service: String, kind: Kind, statusCode: Int, code: String? = nil, message: String,
                requestID: String? = nil, retryAfter: TimeInterval? = nil) {
        self.service = service; self.kind = kind; self.statusCode = statusCode; self.code = code
        self.message = message; self.requestID = requestID; self.retryAfter = retryAfter
    }

    public var errorDescription: String? {
        var s = "\(service): \(message)"
        if let code, !code.isEmpty, !message.contains(code) { s += " (\(code))" }
        if statusCode > 0 { s += " [HTTP \(statusCode)]" }
        if let requestID { s += " Request ID: \(requestID)." }
        return s
    }

    static func kind(forStatus status: Int) -> Kind {
        switch status {
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 412: return .preconditionFailed
        case 429: return .throttled
        case 503: return .serviceUnavailable
        case 500...599: return .serverError
        default: return .other
        }
    }

    /// Builds an error from a non-success HTTP response, understanding the error JSON shapes used by
    /// Graph (`{"error":{"code","message","innerError":{"request-id"}}}`), Power BI
    /// (`{"error":{"code","message","pbi.error":{...}}}`) and Fabric (`{"errorCode","message","requestId"}`).
    public static func from(service: String, response: HTTPURLResponse, data: Data) -> CloudAPIError {
        var code: String?
        var message: String?
        var requestID: String?
        if let json = try? JSONValue.parse(data) {
            if let err = json["error"] {
                if let s = err.stringValue { message = s } // OAuth-style {"error":"x","error_description":"y"}
                code = err["code"]?.stringValue
                message = err["message"]?.stringValue ?? message
                requestID = err["innerError"]?["request-id"]?.stringValue ?? err["innererror"]?["request-id"]?.stringValue
                if message == nil || message?.isEmpty == true {
                    // Power BI often leaves `message` empty and puts detail in pbi.error.details[].detail.value
                    if let details = err["pbi.error"]?["details"]?.arrayValue {
                        let parts = details.compactMap { $0["detail"]?["value"]?.stringValue }
                        if !parts.isEmpty { message = parts.joined(separator: " ") }
                    }
                }
                if let d = json["error_description"]?.stringValue { message = d; code = err.stringValue }
            }
            if code == nil { code = json["errorCode"]?.stringValue ?? json["code"]?.stringValue }
            if message == nil || message?.isEmpty == true { message = json["message"]?.stringValue ?? json["Message"]?.stringValue }
            if requestID == nil { requestID = json["requestId"]?.stringValue }
        }
        for h in ["request-id", "RequestId", "x-ms-request-id", "x-ms-root-activity-id"] where requestID == nil {
            requestID = response.value(forHTTPHeaderField: h)
        }
        let fallback = HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
        let text = (message?.isEmpty == false ? message : nil) ?? (code?.isEmpty == false ? code : nil) ?? fallback
        return CloudAPIError(service: service, kind: kind(forStatus: response.statusCode), statusCode: response.statusCode,
                             code: code, message: text, requestID: requestID,
                             retryAfter: HTTPHelpers.retryAfter(from: response))
    }
}

/// Microsoft Graph errors use the common service error type.
public typealias GraphError = CloudAPIError

// MARK: - Logging

/// Optional debug logging for FacetCloud. Off by default. Requests are always described through
/// `redactedDescription`, so tokens, API keys and authorization codes never reach the handler.
public enum CloudLog {
    private static let lock = NSLock()
    private static var _handler: ((String) -> Void)?

    /// Set to receive debug lines (e.g. `{ print($0) }`). `nil` disables logging.
    public static var handler: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    static func log(_ message: @autoclosure () -> String) {
        guard let h = handler else { return }
        h(message())
    }

    static let sensitiveHeaders: Set<String> = ["authorization", "x-api-key", "proxy-authorization", "cookie", "set-cookie"]
    static let sensitiveQueryItems: Set<String> = [
        "code", "access_token", "refresh_token", "id_token", "client_secret", "code_verifier", "device_code",
        "sig", "tempauth", "token", "state", "nonce",
    ]

    /// A log-safe description of a request: secret headers and secret query values are replaced by `<redacted>`.
    public static func redactedDescription(of request: URLRequest) -> String {
        var s = "\(request.httpMethod ?? "GET") \(redact(url: request.url))"
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.map { k, v in
            "\(k): \(sensitiveHeaders.contains(k.lowercased()) ? "<redacted>" : v)"
        }
        if !headers.isEmpty { s += " {" + headers.joined(separator: ", ") + "}" }
        return s
    }

    /// A log-safe form of a URL.
    public static func redact(url: URL?) -> String {
        guard let url else { return "<no url>" }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems else {
            return url.absoluteString
        }
        comps.queryItems = items.map {
            sensitiveQueryItems.contains($0.name.lowercased()) ? URLQueryItem(name: $0.name, value: "<redacted>") : $0
        }
        return comps.url?.absoluteString.replacingOccurrences(of: "%3Credacted%3E", with: "<redacted>") ?? "<unprintable url>"
    }
}

// MARK: - Helpers

enum HTTPHelpers {
    /// Parses `Retry-After` as delta-seconds or an HTTP date.
    static func retryAfter(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let secs = Double(raw) { return max(0, secs) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = df.date(from: raw) { return max(0, d.timeIntervalSince(now)) }
        return nil
    }

    /// Capped exponential backoff with jitter. `attempt` starts at 0.
    static func backoffDelay(attempt: Int, retryAfter: TimeInterval?, base: TimeInterval = 1, cap: TimeInterval = 30,
                             retryAfterCap: TimeInterval = 120, jitter: Double = Double.random(in: 0...0.25)) -> TimeInterval {
        if let retryAfter { return min(retryAfter, retryAfterCap) }
        let exp = min(cap, base * pow(2, Double(attempt)))
        return min(cap, exp * (1 + jitter))
    }

    static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    /// `application/x-www-form-urlencoded` body from ordered pairs.
    static func formEncode(_ pairs: [(String, String)]) -> Data {
        let s = pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// Percent-encodes one URL path segment (so "/" inside a name is escaped).
    static func encodePathSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }
    /// Percent-encodes a slash-separated path, keeping the separators.
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { encodePathSegment(String($0)) }.joined(separator: "/")
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Constant-time string comparison (does not short-circuit on the first differing byte).
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// ISO-8601 parsing with or without fractional seconds, and with or without a zone (zone-less = UTC).
    static func parseISODate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        // Zone-less ("2024-01-31T08:00:00" or with a fraction): treat as UTC.
        var t = s
        if let dot = t.firstIndex(of: "."), !t.hasSuffix("Z") { t = String(t[..<dot]) }
        if !t.hasSuffix("Z"), t.count >= 19 { return plain.date(from: String(t.prefix(19)) + "Z") }
        return nil
    }

    /// A JSON decoder that accepts the ISO-8601 variants Microsoft services emit.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseISODate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
        }
        return d
    }
}

/// Builds a `multipart/form-data` body.
struct MultipartFormData {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "facet-" + UUID().uuidString) { self.boundary = boundary }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        let safeName = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}

// MARK: - REST client

/// Shared authenticated HTTP layer for Microsoft REST services.
///
/// - Adds `Authorization: Bearer` from the token provider.
/// - On 401: refreshes the token once (bypassing the cache) and retries.
/// - On 429/502/503/504: honours `Retry-After`, otherwise capped exponential backoff, up to `maxRetries`.
/// - Cancellation: every call is cancelled by cancelling the enclosing `Task`.
final class RESTClient {
    let service: String
    let scope: String
    let session: URLSession
    let tokenProvider: AccessTokenProviding
    var maxRetries = 4
    /// Injectable so the self-check can run retries without real waiting.
    var sleeper: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    let decoder = HTTPHelpers.makeDecoder()

    init(service: String, scope: String, tokenProvider: AccessTokenProviding, session: URLSession) {
        self.service = service; self.scope = scope; self.tokenProvider = tokenProvider; self.session = session
    }

    static func defaultSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 3600
        c.httpAdditionalHeaders = ["User-Agent": "Facet/1.0 (macOS)"]
        return URLSession(configuration: c)
    }

    /// Sends a request and returns the body for any 2xx/3xx status; throws `CloudAPIError` otherwise.
    /// - Parameter authenticated: pass `false` for pre-signed URLs (download/upload-session URLs) that must not carry a bearer token.
    func send(_ request: URLRequest, authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var refreshedToken = false
        while true {
            try Task.checkCancellation()
            var req = request
            if authenticated {
                let t = try await tokenProvider.accessToken(resource: scope)
                req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            }
            CloudLog.log("→ " + CloudLog.redactedDescription(of: req))
            let (data, raw): (Data, URLResponse)
            do {
                (data, raw) = try await session.data(for: req)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch let e as URLError where Self.isTransient(e) && attempt < maxRetries {
                try await sleeper(HTTPHelpers.backoffDelay(attempt: attempt, retryAfter: nil))
                attempt += 1
                continue
            }
            guard let http = raw as? HTTPURLResponse else {
                throw CloudAPIError(service: service, kind: .invalidResponse, statusCode: 0, message: "The server returned a non-HTTP response.")
            }
            CloudLog.log("← \(http.statusCode) \(CloudLog.redact(url: req.url))")
            if (200..<400).contains(http.statusCode) { return (data, http) }
            if http.statusCode == 401, authenticated, !refreshedToken {
                refreshedToken = true
                // One silent refresh, bypassing the token cache, then retry.
                if let r = tokenProvider as? RefreshableAccessTokenProviding {
                    _ = try await r.accessToken(resource: scope, forceRefresh: true)
                }
                continue
            }
            if [429, 502, 503, 504].contains(http.statusCode), attempt < maxRetries {
                try await sleeper(HTTPHelpers.backoffDelay(attempt: attempt, retryAfter: HTTPHelpers.retryAfter(from: http)))
                attempt += 1
                continue
            }
            throw CloudAPIError.from(service: service, response: http, data: data)
        }
    }

    static func isTransient(_ e: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(e.code)
    }

    func request(_ method: String, _ url: URL, json: JSONValue? = nil, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.httpBody = json.serializedData()
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch {
            throw CloudAPIError(service: service, kind: .invalidResponse, statusCode: 0,
                                message: "The response could not be read (\(Self.describe(error))).")
        }
    }

    func getJSON<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:]) async throws -> T {
        let (data, _) = try await send(request("GET", url, headers: headers))
        return try decode(type, from: data)
    }

    func sendJSON<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, body: JSONValue?, headers: [String: String] = [:]) async throws -> T {
        let (data, _) = try await send(request(method, url, json: body, headers: headers))
        return try decode(type, from: data)
    }

    static func describe(_ error: Error) -> String {
        guard let d = error as? DecodingError else { return error.localizedDescription }
        switch d {
        case .keyNotFound(let k, _): return "missing field '\(k.stringValue)'"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
        @unknown default: return "\(d)"
        }
    }

    /// Builds a URL from a base and a path that may already contain a query string.
    func url(_ base: URL, _ pathAndQuery: String) throws -> URL {
        let b = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        let p = pathAndQuery.hasPrefix("/") ? pathAndQuery : "/" + pathAndQuery
        guard let u = URL(string: b + p) else {
            throw CloudAPIError(service: service, kind: .badRequest, statusCode: 0, message: "Could not build a valid URL for \(p).")
        }
        return u
    }
}
