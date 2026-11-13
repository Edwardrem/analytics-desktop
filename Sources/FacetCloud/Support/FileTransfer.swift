import Foundation

/// Progress of an upload or download.
public struct TransferProgress: Sendable, Equatable {
    public let completedBytes: Int64
    /// Total size when the server reported it.
    public let totalBytes: Int64?
    public init(completedBytes: Int64, totalBytes: Int64?) { self.completedBytes = completedBytes; self.totalBytes = totalBytes }
    /// 0…1 when the total is known.
    public var fraction: Double? {
        guard let t = totalBytes, t > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(t))
    }
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// Streams an HTTP response body to a file on disk with progress reporting and cancellation.
enum FileDownloader {
    /// Downloads `request` to `destination` (or a new file in Facet's temporary downloads folder).
    /// The `Authorization` header is dropped if the server redirects to a different host
    /// (e.g. Graph's 302 to a pre-authenticated storage URL).
    static func download(_ request: URLRequest, service: String, suggestedName: String, destination: URL? = nil,
                         configuration: URLSessionConfiguration? = nil,
                         progress: TransferProgressHandler? = nil) async throws -> URL {
        let dest = try destination ?? temporaryDestination(named: suggestedName)
        let delegate = DownloadDelegate(service: service, destination: dest, progress: progress)
        let cfg = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 120
            c.timeoutIntervalForResource = 24 * 3600
            return c
        }()
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        CloudLog.log("⇣ " + CloudLog.redactedDescription(of: request))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func temporaryDestination(named name: String) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FacetDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(safe.isEmpty ? "download" : safe)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let service: String
    let destination: URL
    let progress: TransferProgressHandler?
    var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private let once = OnceFlag()

    init(service: String, destination: URL, progress: TransferProgressHandler?) {
        self.service = service; self.destination = destination; self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(TransferProgress(completedBytes: totalBytesWritten,
                                   totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse else {
            outcome = .failure(CloudAPIError(service: service, kind: .invalidResponse, statusCode: 0, message: "The server returned a non-HTTP response."))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: location, options: .mappedIfSafe).prefix(64 * 1024)) ?? Data()
            outcome = .failure(CloudAPIError.from(service: service, response: http, data: Data(body)))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            outcome = .success(destination)
        } catch {
            outcome = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard once.claim() else { return }
        if let e = error as? URLError, e.code == .cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error { continuation?.resume(throwing: error) }
        else if let outcome { continuation?.resume(with: outcome) }
        else {
            continuation?.resume(throwing: CloudAPIError(service: service, kind: .invalidResponse, statusCode: 0, message: "The download ended without data."))
        }
        continuation = nil
    }
}
