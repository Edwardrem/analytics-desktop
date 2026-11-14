import Foundation
import CryptoKit
import FacetCore

/// Azure Blob Storage (`AzureStorage.Blobs`), ADLS Gen2 and OneLake (`AzureStorage.DataLake`).
///
/// Credentials come from Data source settings (kind `AzureBlobs` / `AzureDataLakeStorage`, location `https://<host>`):
/// organizational account (the default), shared access signature, account key (Shared Key signing) or anonymous.
enum AzureStorageSource {
    static let version = "2023-11-03"

    enum Access {
        case entra, anonymous, sas([URLQueryItem]), sharedKey(account: String, key: Data)
    }

    static func access(_ ctx: MInterpreter, kind: String, host: String) throws -> Access {
        switch ctx.credential(kind: kind, location: "https://" + host) {
        case nil, .oauth?: return .entra
        case .anonymous?: return .anonymous
        case .sasToken(let token)?:
            let t = token.hasPrefix("?") ? String(token.dropFirst()) : token
            return .sas(URLComponents(string: "?" + t)?.queryItems ?? [])
        case .accountKey(let key)?:
            guard let data = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw MError.dataSource("The account key for '\(host)' isn't valid Base64. Copy it again from the storage account's Access keys.")
            }
            return .sharedKey(account: String(host.prefix { $0 != "." }), key: data)
        case .basic?, .apiKey?, .bearer?:
            throw MError.dataSource("Azure Storage accepts an organizational account, an account key, a shared access signature or anonymous access. Change the credentials for '\(host)' in Data source settings.")
        }
    }

    /// One signed request. `path` segments are unencoded; `query` excludes any SAS.
    static func send(_ ctx: MInterpreter, service: String, host: String, path: [String], query: [URLQueryItem], access: Access) throws -> CloudHTTP.Response {
        var items = query
        if case .sas(let sas) = access { items += sas }
        guard let url = CloudSource.url(host: host, path: path, query: items) else { throw MError.dataSource("Couldn't build the \(service) address.") }
        var headers = ["x-ms-version": version]
        let auth: CloudHTTP.Auth
        switch access {
        case .entra: auth = .entra(resource: EntraResource.storage)
        case .anonymous, .sas: auth = .none
        case .sharedKey(let account, let key):
            let date = httpDate(Date())
            headers["x-ms-date"] = date
            auth = .secretHeader(name: "Authorization", value: sharedKey(account: account, key: key, method: "GET", path: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/",
                                                                       query: query, headers: headers))
        }
        let kind = host.contains(".blob.") ? "AzureBlobs" : "AzureDataLakeStorage"
        return try CloudHTTP.send(ctx, service: service, url: url, headers: headers, auth: auth, credentialSource: (kind, "https://" + host))
    }

    /// The Shared Key `Authorization` value for a GET without a body (Azure Storage "Authorize with Shared Key").
    static func sharedKey(account: String, key: Data, method: String, path: String, query: [URLQueryItem], headers: [String: String]) -> String {
        let canonicalHeaders = headers.filter { $0.key.lowercased().hasPrefix("x-ms-") }
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)\n" }.joined()
        var resource = "/" + account + (path.isEmpty ? "/" : path)
        var grouped: [String: [String]] = [:]
        for q in query { grouped[q.name.lowercased(), default: []].append(q.value ?? "") }
        for name in grouped.keys.sorted() { resource += "\n\(name):" + (grouped[name] ?? []).sorted().joined(separator: ",") }
        // VERB, then 11 standard headers (all empty for a body-less GET), then x-ms-* headers and the resource.
        let toSign = method + "\n" + String(repeating: "\n", count: 11) + canonicalHeaders + resource
        let mac = HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: key))
        return "SharedKey \(account):" + Data(mac).base64EncodedString()
    }

    static func httpDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: d)
    }

    // MARK: Blobs

    static func blobHost(_ account: String) throws -> (host: String, path: [String]) {
        let t = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let (host, path) = try CloudSource.parse(t.contains(".") || t.contains("://") ? t : t + ".blob.core.windows.net", function: "AzureStorage.Blobs")
        guard CloudSource.hasSuffix(host, ".blob.core.windows.net") else {
            throw MError.dataSource("AzureStorage.Blobs needs a storage account name or an address such as https://contoso.blob.core.windows.net; '\(host)' isn't one.")
        }
        return (host, path)
    }

    static func blobs(_ ctx: MInterpreter, account: String) throws -> MTable {
        let (host, path) = try blobHost(account)
        try ctx.noteDataSource(kind: "AzureBlobs", location: "https://" + host)
        let access = try self.access(ctx, kind: "AzureBlobs", host: host)
        if let container = path.first {
            return CloudSource.fileTable(try listBlobs(ctx, host: host, container: container, prefix: path.dropFirst().joined(separator: "/"), access: access), ctx)
        }
        var containers: [(String, Date?)] = []
        var marker = ""
        for _ in 0..<CloudSource.maxPages {
            var q = [URLQueryItem(name: "comp", value: "list"), URLQueryItem(name: "maxresults", value: "5000")]
            if !marker.isEmpty { q.append(URLQueryItem(name: "marker", value: marker)) }
            let root = try XmlElement.parse(try send(ctx, service: "Azure Blob Storage", host: host, path: [], query: q, access: access).data)
            for c in root.child("Containers")?.children(named: "Container") ?? [] {
                guard let name = c.child("Name")?.trimmedText else { continue }
                containers.append((name, CloudSource.httpDate(c.child("Properties")?.child("Last-Modified")?.trimmedText)))
            }
            marker = root.child("NextMarker")?.trimmedText ?? ""
            if marker.isEmpty { break }
        }
        let offset = Double(ctx.environment.timeZone.secondsFromGMT())
        return CloudSource.navigation(containers.map { name, modified in
            (name, "Folder", [("Date modified", modified.map { .datetime($0.addingTimeInterval(offset)) } ?? .null)],
             { .table(CloudSource.fileTable(try listBlobs(ctx, host: host, container: name, prefix: "", access: access), ctx)) })
        })
    }

    static func listBlobs(_ ctx: MInterpreter, host: String, container: String, prefix: String, access: Access) throws -> [CloudSource.File] {
        var files: [CloudSource.File] = []
        var marker = ""
        let folder = "https://\(host)/\(container)/"
        for _ in 0..<CloudSource.maxPages {
            var q = [URLQueryItem(name: "restype", value: "container"), URLQueryItem(name: "comp", value: "list"), URLQueryItem(name: "maxresults", value: "5000")]
            if !prefix.isEmpty { q.append(URLQueryItem(name: "prefix", value: prefix)) }
            if !marker.isEmpty { q.append(URLQueryItem(name: "marker", value: marker)) }
            let root = try XmlElement.parse(try send(ctx, service: "Azure Blob Storage", host: host, path: [container], query: q, access: access).data)
            for b in root.child("Blobs")?.children(named: "Blob") ?? [] {
                guard let name = b.child("Name")?.trimmedText, !name.hasSuffix("/") else { continue }
                let p = b.child("Properties")
                files.append(CloudSource.File(
                    name: name, folderPath: folder, size: Int(p?.child("Content-Length")?.trimmedText ?? "") ?? 0,
                    created: CloudSource.httpDate(p?.child("Creation-Time")?.trimmedText), modified: CloudSource.httpDate(p?.child("Last-Modified")?.trimmedText),
                    accessed: nil,
                    content: { try send(ctx, service: "Azure Blob Storage", host: host, path: [container] + name.split(separator: "/").map(String.init), query: [], access: access).data }))
            }
            marker = root.child("NextMarker")?.trimmedText ?? ""
            if marker.isEmpty { break }
        }
        return files
    }

    // MARK: Data Lake (ADLS Gen2 and OneLake)

    static func isDataLakeHost(_ host: String) -> Bool {
        CloudSource.hasSuffix(host, ".dfs.core.windows.net") || host == "onelake.dfs.fabric.microsoft.com" || CloudSource.hasSuffix(host, ".dfs.fabric.microsoft.com")
    }

    static func dataLake(_ ctx: MInterpreter, url address: String) throws -> MTable {
        let (host, path) = try CloudSource.parse(address, function: "AzureStorage.DataLake")
        guard isDataLakeHost(host) else {
            throw MError.dataSource("AzureStorage.DataLake needs an address such as https://contoso.dfs.core.windows.net/container or a OneLake address (https://onelake.dfs.fabric.microsoft.com/<workspace>/<item>); '\(host)' isn't one.")
        }
        try ctx.noteDataSource(kind: "AzureDataLakeStorage", location: "https://" + host + (host.contains("fabric") && !path.isEmpty ? "/" + path[0] : ""))
        let access = try self.access(ctx, kind: "AzureDataLakeStorage", host: host)
        guard let filesystem = path.first else {
            let page = try JsonParser.parse(try send(ctx, service: "Azure Data Lake Storage", host: host, path: [], query: [URLQueryItem(name: "resource", value: "account")], access: access).data)
            let names = try CloudSource.records(page, "filesystems").compactMap { CloudSource.text($0, "name") }
            return CloudSource.navigation(names.map { fs in (fs, "Folder", [], { .table(try dataLake(ctx, url: "https://\(host)/\(fs)")) }) })
        }
        let directory = path.dropFirst().joined(separator: "/")
        var files: [CloudSource.File] = []
        var continuation = ""
        for _ in 0..<CloudSource.maxPages {
            var q = [URLQueryItem(name: "resource", value: "filesystem"), URLQueryItem(name: "recursive", value: "true"), URLQueryItem(name: "maxResults", value: "5000")]
            if !directory.isEmpty { q.append(URLQueryItem(name: "directory", value: directory)) }
            if !continuation.isEmpty { q.append(URLQueryItem(name: "continuation", value: continuation)) }
            let r = try send(ctx, service: "Azure Data Lake Storage", host: host, path: [filesystem], query: q, access: access)
            for p in try CloudSource.records(try JsonParser.parse(r.data), "paths") {
                guard let full = CloudSource.text(p, "name"), CloudSource.text(p, "isDirectory") != "true",
                      (try? p.logical("isDirectory")) ?? nil != true else { continue }
                let parts = full.split(separator: "/").map(String.init)
                guard let name = parts.last else { continue }
                let folder = "https://\(host)/\(filesystem)/" + parts.dropLast().map { $0 + "/" }.joined()
                files.append(CloudSource.File(
                    name: name, folderPath: folder, size: Int(CloudSource.number(p, "contentLength") ?? 0), created: nil,
                    modified: CloudSource.httpDate(CloudSource.text(p, "lastModified")), accessed: nil,
                    content: { try send(ctx, service: "Azure Data Lake Storage", host: host, path: [filesystem] + parts, query: [], access: access).data }))
            }
            continuation = r.header("x-ms-continuation") ?? ""
            if continuation.isEmpty { break }
        }
        files.sort { ($0.folderPath, $0.name) < ($1.folderPath, $1.name) }
        return CloudSource.fileTable(files, ctx)
    }
}

extension MLibrary {
    static func registerAzureStorage(_ lib: MLibrary) {
        lib.fn("AzureStorage.Blobs", 1...2) { a, ctx in .table(try AzureStorageSource.blobs(ctx, account: try a.text(0))) }
        lib.fn("AzureStorage.DataLake", 1...2) { a, ctx in .table(try AzureStorageSource.dataLake(ctx, url: try a.text(0))) }
    }
}
