import Foundation

/// Microsoft Graph client for OneDrive and SharePoint files.
///
/// All methods are `async`, cancellable through the enclosing `Task`, and throw `GraphError`
/// (`CloudAPIError`) carrying Graph's own code, message and request id.
public final class GraphClient {
    public let cloud: MicrosoftCloud
    let rest: RESTClient
    let transferConfiguration: URLSessionConfiguration?
    private var baseURL: URL { cloud.graphEndpoint.appendingPathComponent("v1.0") }

    /// Files up to this size are uploaded with a single PUT; larger files use a resumable upload session.
    public static let simpleUploadLimit: Int64 = 4 * 1024 * 1024
    /// Upload-session chunk size: 10 MiB, a multiple of the 320 KiB Graph requires.
    public static let uploadChunkSize = 32 * 327_680
    /// Largest file `download` accepts unless told otherwise (8 GB).
    public static let defaultMaxDownloadBytes: Int64 = 8 * 1024 * 1024 * 1024

    /// - Parameters:
    ///   - tokenProvider: usually the app's `MicrosoftAccountManager`.
    ///   - sessionConfiguration: override for tests; defaults to an ephemeral configuration.
    public init(tokenProvider: AccessTokenProviding, cloud: MicrosoftCloud = .public, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.cloud = cloud
        self.transferConfiguration = sessionConfiguration
        let policy = EndpointPolicy(cloud: cloud)
        let session = RESTClient.makeSession(sessionConfiguration)
        self.rest = RESTClient(service: "Microsoft Graph", scope: MicrosoftResource.graph.scopeString(cloud: cloud),
                               tokenProvider: tokenProvider, session: session, policy: policy)
    }

    private func url(_ pathAndQuery: String) throws -> URL { try rest.url(baseURL, pathAndQuery) }

    private static func query(_ items: [(String, String)]) -> String {
        guard !items.isEmpty else { return "" }
        return "?" + items.map { "\($0.0)=\(HTTPHelpers.encodePathSegment($0.1))" }.joined(separator: "&")
    }

    // MARK: Profile

    /// The signed-in user (`GET /me`).
    public func me() async throws -> GraphUser {
        try await rest.getJSON(GraphUser.self, try url("/me?$select=id,displayName,userPrincipalName,mail,jobTitle"))
    }

    /// The signed-in user's profile photo bytes, or `nil` when they have none.
    public func myPhoto() async throws -> Data? {
        do {
            let (data, _) = try await rest.send(rest.request("GET", try url("/me/photo/$value")))
            return data.isEmpty ? nil : data
        } catch let e as CloudAPIError where e.kind == .notFound {
            return nil
        }
    }

    // MARK: Listing

    /// Lists a folder's children (first page). Continue with `nextPage`.
    /// - Parameter pageSize: Graph `$top` (default 200).
    public func children(of folder: DriveLocation = .myRoot, pageSize: Int = 200, orderBy: String? = nil) async throws -> GraphPage<DriveItem> {
        var q = [("$top", String(pageSize))]
        if let orderBy { q.append(("$orderby", orderBy)) }
        return try await rest.getJSON(GraphPage<DriveItem>.self, try url(folder.subresource("children") + Self.query(q)))
    }

    /// Fetches the page after `page` using its `@odata.nextLink`, or `nil` when `page` was the last one.
    public func nextPage<T>(after page: GraphPage<T>) async throws -> GraphPage<T>? {
        guard let next = page.nextLink else { return nil }
        guard next.host?.lowercased() == cloud.graphEndpoint.host?.lowercased(), next.scheme == "https" else {
            throw CloudAPIError(service: rest.service, kind: .invalidResponse, statusCode: 0, message: "The service returned a paging link to an unexpected host.")
        }
        return try await rest.getJSON(GraphPage<T>.self, next)
    }

    /// Lists every child of a folder, following all pages (up to `limit` items).
    public func allChildren(of folder: DriveLocation = .myRoot, limit: Int = 10_000) async throws -> [DriveItem] {
        var page: GraphPage<DriveItem>? = try await children(of: folder)
        var out: [DriveItem] = []
        while let p = page {
            out.append(contentsOf: p.items)
            if out.count >= limit { break }
            page = try await nextPage(after: p)
        }
        return Array(out.prefix(limit))
    }

    /// Searches a drive (`/root/search(q='…')`). Searches the user's OneDrive unless `driveID` is given.
    public func search(_ text: String, driveID: String? = nil, pageSize: Int = 100) async throws -> GraphPage<DriveItem> {
        // OData string literal: single quotes are doubled, then the whole segment is percent-encoded.
        let literal = HTTPHelpers.encodePathSegment(text.replacingOccurrences(of: "'", with: "''"))
        let root = driveID.map { "/drives/\(HTTPHelpers.encodePathSegment($0))/root" } ?? "/me/drive/root"
        return try await rest.getJSON(GraphPage<DriveItem>.self, try url("\(root)/search(q='\(literal)')?$top=\(pageSize)"))
    }

    /// Files the user opened or edited recently.
    public func recentFiles() async throws -> GraphPage<DriveItem> {
        try await rest.getJSON(GraphPage<DriveItem>.self, try url("/me/drive/recent?$top=100"))
    }

    /// Items other people shared with the user.
    public func sharedWithMe() async throws -> GraphPage<DriveItem> {
        try await rest.getJSON(GraphPage<DriveItem>.self, try url("/me/drive/sharedWithMe?$top=100"))
    }

    // MARK: SharePoint

    /// SharePoint sites the user follows.
    public func followedSites() async throws -> GraphPage<SharePointSite> {
        try await rest.getJSON(GraphPage<SharePointSite>.self, try url("/me/followedSites?$top=200"))
    }

    /// Searches SharePoint sites by keyword. An empty query lists sites the user can reach (`search=*`).
    public func searchSites(_ text: String) async throws -> GraphPage<SharePointSite> {
        let q = text.trimmingCharacters(in: .whitespaces)
        return try await rest.getJSON(GraphPage<SharePointSite>.self, try url("/sites" + Self.query([("search", q.isEmpty ? "*" : q), ("$top", "100")])))
    }

    /// Document libraries of a site.
    public func drives(inSite siteID: String) async throws -> GraphPage<GraphDrive> {
        try await rest.getJSON(GraphPage<GraphDrive>.self, try url("/sites/\(HTTPHelpers.encodePathSegment(siteID))/drives?$top=200"))
    }

    /// The user's own OneDrive.
    public func myDrive() async throws -> GraphDrive {
        try await rest.getJSON(GraphDrive.self, try url("/me/drive"))
    }

    // MARK: Items

    /// Item metadata, including `eTag`.
    public func item(at location: DriveLocation) async throws -> DriveItem {
        try await rest.getJSON(DriveItem.self, try url(location.resourcePath))
    }

    /// Creates a folder under `parent`.
    public func createFolder(named name: String, in parent: DriveLocation = .myRoot, conflict: ConflictBehavior = .fail) async throws -> DriveItem {
        let body: JSONValue = ["name": .string(name), "folder": [:], "@microsoft.graph.conflictBehavior": .string(conflict.rawValue)]
        return try await rest.sendJSON(DriveItem.self, "POST", try url(parent.subresource("children")), body: body)
    }

    /// Deletes an item (moves it to the recycle bin). Pass `ifMatchETag` to fail with `.preconditionFailed` if it changed.
    public func delete(_ location: DriveLocation, ifMatchETag: String? = nil) async throws {
        var headers: [String: String] = [:]
        if let ifMatchETag { headers["If-Match"] = ifMatchETag }
        _ = try await rest.send(rest.request("DELETE", try url(location.resourcePath), headers: headers))
    }

    /// Creates (or returns the existing) sharing link for an item.
    public func createSharingLink(for location: DriveLocation, type: SharingLink.LinkType = .view,
                                  scope: SharingLink.Scope = .organization) async throws -> SharingLink {
        struct Response: Decodable {
            struct Link: Decodable { let type: String?; let scope: String?; let webUrl: String? }
            let id: String?
            let link: Link?
        }
        let body: JSONValue = ["type": .string(type.rawValue), "scope": .string(scope.rawValue)]
        let r = try await rest.sendJSON(Response.self, "POST", try url(location.subresource("createLink")), body: body)
        guard let s = r.link?.webUrl, let u = URL(string: s) else {
            throw CloudAPIError(service: rest.service, kind: .invalidResponse, statusCode: 0, message: "The sharing link response did not contain a URL.")
        }
        return SharingLink(id: r.id, webURL: u, type: r.link?.type, scope: r.link?.scope)
    }

    // MARK: Download

    /// Downloads a file to disk. Graph answers with a 302 to a pre-authenticated URL, which is followed
    /// (without forwarding the bearer token); the body is streamed to a file with progress.
    /// - Parameters:
    ///   - destination: target file; defaults to a new file in Facet's temporary downloads folder.
    ///   - maxBytes: the download is stopped and refused once it grows past this size.
    /// - Returns: the local file URL.
    public func download(_ location: DriveLocation, suggestedName: String? = nil, destination: URL? = nil,
                         maxBytes: Int64 = GraphClient.defaultMaxDownloadBytes, progress: TransferProgressHandler? = nil) async throws -> URL {
        var name = suggestedName
        if name == nil, destination == nil { name = try await item(at: location).name }
        return try await downloadAttempt(location, name: name ?? "download", destination: destination, maxBytes: maxBytes,
                                         progress: progress, retryOn401: true)
    }

    private func downloadAttempt(_ location: DriveLocation, name: String, destination: URL?, maxBytes: Int64,
                                 progress: TransferProgressHandler?, retryOn401: Bool) async throws -> URL {
        var request = URLRequest(url: try url(location.subresource("content")))
        guard rest.policy.allowsCredentials(for: request.url) else {
            throw CloudAPIError(service: rest.service, kind: .badRequest, statusCode: 0, message: "Refused to send your sign-in to an address that is not Microsoft Graph.")
        }
        let token = try await rest.tokenProvider.accessToken(resource: rest.scope)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await FileDownloader.download(request, service: rest.service, suggestedName: name, destination: destination,
                                                     configuration: transferConfiguration, maxBytes: maxBytes, progress: progress)
        } catch let e as CloudAPIError where e.kind == .unauthorized && retryOn401 {
            if let r = rest.tokenProvider as? RefreshableAccessTokenProviding {
                _ = try await r.accessToken(resource: rest.scope, forceRefresh: true)
            }
            return try await downloadAttempt(location, name: name, destination: destination, maxBytes: maxBytes,
                                             progress: progress, retryOn401: false)
        }
    }

    // MARK: Upload

    /// Uploads a local file into `folder` as `name`. Files ≤ 4 MB use a single PUT; larger files use a
    /// resumable upload session with 10 MiB chunks, per-chunk retry, and resume from the server's expected range.
    public func upload(fileAt fileURL: URL, to folder: DriveLocation = .myRoot, named name: String? = nil,
                       conflict: ConflictBehavior = .replace, progress: TransferProgressHandler? = nil) async throws -> DriveItem {
        let fileName = name ?? fileURL.lastPathComponent
        let size = try LocalFile.size(of: fileURL, service: rest.service)
        if size <= Self.simpleUploadLimit {
            let data = try LocalFile.read(fileURL, limit: Self.simpleUploadLimit, service: rest.service)
            let item = try await upload(data: data, to: folder, named: fileName, conflict: conflict)
            progress?(TransferProgress(completedBytes: size, totalBytes: size))
            return item
        }
        return try await uploadLarge(fileURL: fileURL, size: size, sessionPath: folder.childPath(named: fileName) + "/createUploadSession",
                                     createBody: ["item": ["@microsoft.graph.conflictBehavior": .string(conflict.rawValue), "name": .string(fileName)]],
                                     ifMatchETag: nil, progress: progress)
    }

    /// Uploads in-memory data (≤ 4 MB) with a single PUT.
    public func upload(data: Data, to folder: DriveLocation = .myRoot, named name: String,
                       conflict: ConflictBehavior = .replace, contentType: String = "application/octet-stream") async throws -> DriveItem {
        guard Int64(data.count) <= Self.simpleUploadLimit else {
            throw CloudAPIError(service: rest.service, kind: .badRequest, statusCode: 0,
                                message: "Data larger than 4 MB must be uploaded from a file so it can be sent in chunks.")
        }
        let target = folder.childPath(named: name) + "/content?@microsoft.graph.conflictBehavior=\(conflict.rawValue)"
        var request = rest.request("PUT", try url(target))
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, _) = try await rest.send(request)
        return try rest.decode(DriveItem.self, from: body)
    }

    /// Replaces the content of an existing file ("save back"). With `ifMatchETag`, Graph refuses the write with
    /// HTTP 412 (`CloudAPIError.kind == .preconditionFailed`) when the file changed in the cloud since that eTag was
    /// read, so someone else's newer version is never silently overwritten.
    public func replaceContent(of location: DriveLocation, withFileAt fileURL: URL, ifMatchETag: String? = nil,
                               progress: TransferProgressHandler? = nil) async throws -> DriveItem {
        let size = try LocalFile.size(of: fileURL, service: rest.service)
        if size <= Self.simpleUploadLimit {
            var request = rest.request("PUT", try url(location.subresource("content")))
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let ifMatchETag, !ifMatchETag.isEmpty { request.setValue(ifMatchETag, forHTTPHeaderField: "If-Match") }
            request.httpBody = try LocalFile.read(fileURL, limit: Self.simpleUploadLimit, service: rest.service)
            let (body, _) = try await rest.send(request)
            progress?(TransferProgress(completedBytes: size, totalBytes: size))
            return try rest.decode(DriveItem.self, from: body)
        }
        return try await uploadLarge(fileURL: fileURL, size: size, sessionPath: location.subresource("createUploadSession"),
                                     createBody: ["item": ["@microsoft.graph.conflictBehavior": "replace"]],
                                     ifMatchETag: ifMatchETag, progress: progress)
    }

    struct UploadSession: Decodable {
        let uploadUrl: String
        let nextExpectedRanges: [String]?
    }

    /// The byte offset at which the server expects the next chunk, from `nextExpectedRanges` (e.g. `["26214400-"]`).
    static func nextOffset(from ranges: [String]?) -> Int64? {
        guard let first = ranges?.first, let start = first.split(separator: "-").first else { return nil }
        return Int64(start)
    }

    private func uploadLarge(fileURL: URL, size: Int64, sessionPath: String, createBody: JSONValue, ifMatchETag: String?,
                             progress: TransferProgressHandler?) async throws -> DriveItem {
        var headers: [String: String] = [:]
        if let ifMatchETag, !ifMatchETag.isEmpty { headers["If-Match"] = ifMatchETag }
        let session = try await rest.sendJSON(UploadSession.self, "POST", try url(sessionPath), body: createBody, headers: headers)
        guard let uploadURL = URL(string: session.uploadUrl), uploadURL.scheme == "https" else {
            throw CloudAPIError(service: rest.service, kind: .invalidResponse, statusCode: 0, message: "The upload session did not return a valid URL.")
        }
        let handle = try FileHandle(forReadingFrom: fileURL.resolvingSymlinksInPath())
        defer { try? handle.close() }
        var offset: Int64 = 0
        var resyncs = 0
        do {
            while offset < size {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(offset))
                let length = Int(min(Int64(Self.uploadChunkSize), size - offset))
                guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else {
                    throw CloudAPIError(service: rest.service, kind: .badRequest, statusCode: 0, message: "The file changed or could not be read during upload.")
                }
                var request = URLRequest(url: uploadURL)
                request.httpMethod = "PUT"
                request.httpBody = chunk
                request.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
                request.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
                do {
                    // Upload URLs are pre-authenticated; a bearer token must not be sent. Transient failures are retried by RESTClient.
                    let (data, http) = try await rest.send(request, authenticated: false)
                    if http.statusCode == 200 || http.statusCode == 201 {
                        progress?(TransferProgress(completedBytes: size, totalBytes: size))
                        return try rest.decode(DriveItem.self, from: data)
                    }
                    let status = try? rest.decode(UploadSession.self, from: data)
                    offset = Self.nextOffset(from: status?.nextExpectedRanges) ?? (offset + Int64(chunk.count))
                } catch let e as CloudAPIError where [416, 409, 500, 502, 503, 504].contains(e.statusCode) && e.code != "nameAlreadyExists" && resyncs < 5 {
                    // The server and client disagree about what was received: ask the session where to resume.
                    resyncs += 1
                    let (data, _) = try await rest.send(URLRequest(url: uploadURL), authenticated: false)
                    let status = try rest.decode(UploadSession.self, from: data)
                    guard let next = Self.nextOffset(from: status.nextExpectedRanges) else { throw e }
                    offset = next
                }
                progress?(TransferProgress(completedBytes: min(offset, size), totalBytes: size))
            }
        } catch {
            // Best effort: release the server-side session so partial data is discarded.
            var cancel = URLRequest(url: uploadURL)
            cancel.httpMethod = "DELETE"
            let rest = self.rest
            Task.detached { _ = try? await rest.send(cancel, authenticated: false) }
            throw error
        }
        throw CloudAPIError(service: rest.service, kind: .invalidResponse, statusCode: 0, message: "The upload finished without the service confirming the file.")
    }
}
