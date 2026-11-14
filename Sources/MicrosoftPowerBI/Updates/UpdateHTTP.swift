import Foundation
import FacetCore

/// The only hosts the updater talks to, over https only. Release downloads start at github.com and are
/// redirected to GitHub's asset storage: `objects.githubusercontent.com` historically, and
/// `release-assets.githubusercontent.com` today (checked Nov 2026), so both are allowed. Hosts match exactly.
enum UpdateHosts {
    static let allowed: Set<String> = [
        "api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    static func check(_ url: URL?) throws -> URL {
        guard let url, let scheme = url.scheme?.lowercased() else {
            throw UpdateError.notAllowed("The update address is missing.")
        }
        guard scheme == "https" else {
            throw UpdateError.notAllowed("Updates are only fetched over https, not \(scheme)://.")
        }
        guard let host = url.host?.lowercased(), allowed.contains(host), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            throw UpdateError.notAllowed("Updates are only fetched from GitHub; “\(url.host ?? "")” isn't allowed.")
        }
        return url
    }
}

/// HTTP for the updater: unauthenticated, no cookies, no cache, no credentials, bounded sizes, and every URL,
/// redirects included, checked against `UpdateHosts`. The request carries only what HTTP needs: GitHub's
/// required User-Agent (app name and version), the Accept header, and an ETag when one is cached.
final class UpdateHTTP: @unchecked Sendable {
    static let apiLimit = 4 << 20          // the release list
    static let signatureLimit = 4 << 10    // a base64 Ed25519 signature is 88 bytes
    static let archiveLimit = 512 << 20

    private let configuration: URLSessionConfiguration

    /// `protocolClasses` replaces the network (tests pass URLProtocol stubs).
    init(protocolClasses: [AnyClass]? = nil, timeout: TimeInterval = 30) {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = 30 * 60
        c.waitsForConnectivity = false
        if let protocolClasses { c.protocolClasses = protocolClasses }
        configuration = c
    }

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    func request(_ url: URL, accept: String, etag: String? = nil) throws -> URLRequest {
        var r = URLRequest(url: try UpdateHosts.check(url))
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("AnalyticsDesktop/\(AppIdentity.version)", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return r
    }

    /// Fetches into memory, failing once more than `limit` bytes arrive.
    func data(_ request: URLRequest, limit: Int) async throws -> Response {
        try await run(request, limit: limit, file: nil)
    }

    /// Fetches into `file` (created or truncated), failing once more than `limit` bytes arrive.
    func download(_ request: URLRequest, to file: URL, limit: Int, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Response {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            throw UpdateError.install("Couldn't write the download to \(file.deletingLastPathComponent().path).")
        }
        defer { try? handle.close() }
        return try await run(request, limit: limit, file: handle, progress: progress)
    }

    private func run(_ request: URLRequest, limit: Int, file: FileHandle?, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Response {
        _ = try UpdateHosts.check(request.url)
        let fetch = Fetch(limit: limit, file: file, progress: progress)
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
                fetch.continuation = c
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// One transfer: checks redirects, counts bytes and stops at the limit.
    private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int
        let file: FileHandle?
        let progress: (@Sendable (Int64) -> Void)?
        var continuation: CheckedContinuation<Response, Error>?
        private var body = Data()
        private var received: Int64 = 0
        private var failure: Error?
        private let lock = NSLock()

        init(limit: Int, file: FileHandle?, progress: (@Sendable (Int64) -> Void)?) {
            self.limit = limit; self.file = file; self.progress = progress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            do {
                _ = try UpdateHosts.check(newRequest.url)
                var next = newRequest
                next.httpShouldHandleCookies = false
                completionHandler(next)
            } catch {
                fail(error); completionHandler(nil); task.cancel()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if response.expectedContentLength > Int64(limit) {
                fail(UpdateError.tooLarge("The download is larger than an update can be (\(ByteCountFormatter.string(fromByteCount: response.expectedContentLength, countStyle: .file)))."))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard failure == nil else { return }
            received += Int64(data.count)
            guard received <= Int64(limit) else {
                failure = UpdateError.tooLarge("The download went past the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) an update can be, so it was stopped.")
                dataTask.cancel()
                return
            }
            if let file {
                do { try file.write(contentsOf: data) } catch { failure = UpdateError.install("Couldn't save the download: \(error.localizedDescription)"); dataTask.cancel(); return }
            } else {
                body.append(data)
            }
            progress?(received)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let c = continuation; continuation = nil
            let stored = failure
            let data = body
            lock.unlock()
            guard let c else { return }
            if let stored { c.resume(throwing: stored); return }
            if let error {
                c.resume(throwing: UpdateError.network("Couldn't reach GitHub: \(error.localizedDescription)"))
                return
            }
            guard let http = task.response as? HTTPURLResponse else {
                c.resume(throwing: UpdateError.badResponse("GitHub sent no HTTP response.")); return
            }
            // The final URL after redirects must still be allowed (a redirect can't slip past the delegate,
            // but check once more before anything uses the body).
            do { _ = try UpdateHosts.check(http.url) } catch { c.resume(throwing: error); return }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
            c.resume(returning: Response(status: http.statusCode, headers: headers, body: data))
        }

        private func fail(_ error: Error) {
            lock.lock(); if failure == nil { failure = error }; lock.unlock()
        }
    }
}

/// The release list, fetched with an ETag so an unchanged list costs GitHub nothing (a 304 doesn't count
/// against the unauthenticated rate limit). The last body and its ETag are kept in the Caches folder.
final class ReleaseListCache {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    static var standard: ReleaseListCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ReleaseListCache(directory: base.appendingPathComponent(AppIdentity.bundleIdentifier).appendingPathComponent("Updates"))
    }

    private var bodyURL: URL { directory.appendingPathComponent("releases.json") }
    private var etagURL: URL { directory.appendingPathComponent("releases.etag") }

    var cached: (etag: String, body: Data)? {
        guard let body = try? Data(contentsOf: bodyURL), let etag = try? String(contentsOf: etagURL, encoding: .utf8),
              !etag.isEmpty else { return nil }
        return (etag, body)
    }

    func store(etag: String?, body: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let etag, !etag.isEmpty else {
            try? FileManager.default.removeItem(at: etagURL); return
        }
        try? body.write(to: bodyURL, options: .atomic)
        try? Data(etag.utf8).write(to: etagURL, options: .atomic)
    }

    /// The releases, from GitHub or, when GitHub says nothing changed, from the cache.
    func fetch(with http: UpdateHTTP, url: URL = ReleaseFeed.releasesURL) async throws -> [Release] {
        let known = cached
        let request = try http.request(url, accept: "application/vnd.github+json", etag: known?.etag)
        let response = try await http.data(request, limit: UpdateHTTP.apiLimit)
        switch response.status {
        case 200:
            let releases = try ReleaseFeed.decode(response.body)
            store(etag: response.header("ETag"), body: response.body)
            return releases
        case 304:
            if let known { return try ReleaseFeed.decode(known.body) }
            throw UpdateError.badResponse("GitHub said the release list hadn't changed, but no copy was kept. Check again.")
        case 403, 429:
            if response.header("X-RateLimit-Remaining") == "0" || response.status == 429 {
                let reset = response.header("X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                throw UpdateError.rateLimited(reset)
            }
            throw UpdateError.badResponse("GitHub refused the update check (HTTP \(response.status)).")
        case 404:
            throw UpdateError.badResponse("The release list for \(ReleaseFeed.owner)/\(ReleaseFeed.repository) wasn't found on GitHub.")
        default:
            throw UpdateError.badResponse("GitHub answered the update check with HTTP \(response.status).")
        }
    }
}
