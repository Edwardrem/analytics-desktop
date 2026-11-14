import Foundation
import FacetCore

/// HTTP for the cloud connectors (SharePoint, Dataverse, Azure Storage, Kusto, Power BI, OneLake).
///
/// - https only; the request's own host is the one named to the token provider, which enforces its allow-list.
/// - Bodies are read with a hard limit (`QueryEnvironment.maxSourceBytes` or a smaller per-call limit).
/// - A redirect never carries the `Authorization` header (or any other secret header) to another host, and a
///   redirect away from https is refused.
/// - Nothing about the request is traced; error messages name the host and path, never headers or query strings.
enum CloudHTTP {
    /// URL protocol classes for tests (`URLProtocol` stubs). Nil in the app.
    nonisolated(unsafe) static var protocolClasses: [AnyClass]?

    enum Auth {
        case none
        /// An Entra bearer token for the resource, requested for the request's host.
        case entra(resource: String)
        /// A header whose value is a secret (API key, shared-key signature).
        case secretHeader(name: String, value: String)
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let data: Data
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Headers that carry secrets; they are dropped on any cross-host redirect.
    static let secretHeaders: Set<String> = ["authorization", "x-ms-authorization", "api-key", "x-api-key", "ocp-apim-subscription-key"]

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "\(AppIdentity.name.replacingOccurrences(of: " ", with: ""))/1.0 (macOS)"]
        if let classes = protocolClasses { c.protocolClasses = classes + (c.protocolClasses ?? []) }
        return URLSession(configuration: c)
    }

    /// Sends one request and returns any 2xx response; other statuses throw `DataSource.Error` naming `service`.
    static func send(_ ctx: MInterpreter, service: String, method: String = "GET", url: URL, headers: [String: String] = [:],
                     body: Data? = nil, auth: Auth, limit: Int? = nil, timeout: TimeInterval? = nil, accept: Set<Int> = []) throws -> Response {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty, url.user == nil else {
            throw MError.dataSource("\(service) is only reached over https; '\(display(url))' isn't an https address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout ?? ctx.environment.networkTimeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        switch auth {
        case .none: break
        case .entra(let resource):
            request.setValue("Bearer " + (try ctx.accessToken(resource: resource, host: host)), forHTTPHeaderField: "Authorization")
        case .secretHeader(let name, let value): request.setValue(value, forHTTPHeaderField: name)
        }
        let cap = min(limit ?? ctx.environment.maxSourceBytes, ctx.environment.maxSourceBytes)
        var attempt = 0
        while true {
            let r = try perform(request, limit: cap, service: service)
            if (200..<300).contains(r.status) || accept.contains(r.status) { return r }
            if [429, 503].contains(r.status), attempt < 2 {
                let wait = min(10, max(1, Double(r.header("Retry-After") ?? "") ?? Double(attempt + 1)))
                Thread.sleep(forTimeInterval: wait)
                attempt += 1
                continue
            }
            throw failure(service: service, url: url, response: r)
        }
    }

    /// A readable error for a failed response: the service's own message when it sends one.
    static func failure(service: String, url: URL, response r: Response) -> MError {
        var detail = HTTPURLResponse.localizedString(forStatusCode: r.status)
        if let json = try? JSONSerialization.jsonObject(with: r.data.prefix(64 * 1024)) as? [String: Any] {
            let error = json["error"] as? [String: Any] ?? json["odata.error"] as? [String: Any]
            if let m = error?["message"] as? String { detail = m }
            else if let m = (error?["message"] as? [String: Any])?["value"] as? String { detail = m }
            else if let m = json["message"] as? String ?? json["Message"] as? String { detail = m }
        } else if let text = String(data: r.data.prefix(4096), encoding: .utf8),
                  let start = text.range(of: "<Message>"), let end = text.range(of: "</Message>"), start.upperBound < end.lowerBound {
            detail = String(text[start.upperBound..<end.lowerBound])
        }
        var advice = ""
        if r.status == 401 { advice = " Check the credentials in Data source settings, or sign in again from the Account menu." }
        if r.status == 403 { advice = " The signed-in account doesn't have permission to read it." }
        return MError.dataSource("\(service) refused '\(display(url))' (\(r.status)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines)).\(advice)")
    }

    /// Host and path only: query strings can hold SAS signatures.
    static func display(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil; c?.fragment = nil; c?.user = nil; c?.password = nil
        return c?.string ?? (url.host ?? "the address")
    }

    private static func perform(_ request: URLRequest, limit: Int, service: String) throws -> Response {
        let collector = Collector(limit: limit, originalHost: request.url?.host?.lowercased())
        let s = session()
        defer { s.finishTasksAndInvalidate() }
        let task = s.dataTask(with: request)
        task.delegate = collector
        task.resume()
        collector.done.wait()
        if collector.tooLarge {
            throw MError.dataSource("The response from \(service) is too large to load (the limit is \(limit) bytes).")
        }
        if let e = collector.error {
            throw MError.dataSource("Couldn't reach \(service) at '\(request.url?.host ?? "")': \(e.localizedDescription)")
        }
        guard let http = collector.response else { throw MError.dataSource("\(service) returned a response that isn't HTTP.") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
        return Response(status: http.statusCode, headers: headers, data: collector.data)
    }

    /// Collects one response body up to a limit, and guards redirects.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int
        let originalHost: String?
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var tooLarge = false
        init(limit: Int, originalHost: String?) { self.limit = limit; self.originalHost = originalHost }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(limit) { tooLarge = true; completionHandler(.cancel); return }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            if data.count + chunk.count > limit { tooLarge = true; dataTask.cancel(); return }
            data.append(chunk)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard request.url?.scheme?.lowercased() == "https" else { completionHandler(nil); return }
            var next = request
            if request.url?.host?.lowercased() != originalHost {
                for name in (request.allHTTPHeaderFields ?? [:]).keys where CloudHTTP.secretHeaders.contains(name.lowercased()) {
                    next.setValue(nil, forHTTPHeaderField: name)
                }
            }
            completionHandler(next)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if !tooLarge { self.error = error }
            done.signal()
        }
    }
}
