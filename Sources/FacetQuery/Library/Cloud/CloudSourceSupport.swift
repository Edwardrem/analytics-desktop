import Foundation
import FacetCore

/// Shared pieces of the cloud connectors: JSON calls, paging, the file-listing table, dates and host checks.
enum CloudSource {
    /// Pages followed per listing before giving up (a guard against a service that never stops paging).
    static let maxPages = 5_000

    /// GET (or POST) JSON, parsed with the order-keeping M JSON reader.
    static func json(_ ctx: MInterpreter, service: String, url: URL, method: String = "GET", body: Data? = nil,
                     headers: [String: String] = [:], auth: CloudHTTP.Auth) throws -> MValue {
        var h = headers
        h["Accept"] = h["Accept"] ?? "application/json"
        if body != nil { h["Content-Type"] = h["Content-Type"] ?? "application/json" }
        let r = try CloudHTTP.send(ctx, service: service, method: method, url: url, headers: h, body: body, auth: auth)
        do { return try JsonParser.parse(r.data) } catch {
            throw MError.dataSource("\(service) answered '\(CloudHTTP.display(url))' with something that isn't JSON.")
        }
    }

    /// The records of a JSON array field (`value`, `paths`…).
    static func records(_ v: MValue, _ field: String) throws -> [MRecord] {
        guard case .record(let r) = v, case .list(let items)? = try r.get(field) else { return [] }
        return try items.compactMap { try $0.forced().recordValue }
    }
    static func text(_ r: MRecord, _ name: String) -> String? { (try? r.get(name))??.textValue }
    static func record(_ r: MRecord, _ name: String) -> MRecord? { (try? r.get(name))??.recordValue }
    static func number(_ r: MRecord, _ name: String) -> Double? {
        guard let v = (try? r.get(name)) ?? nil else { return nil }
        return v.numberValue ?? v.textValue.flatMap(Double.init)
    }

    /// The next page of an OData-style listing. A next link on another host or scheme is refused, so a response can't
    /// steer a token-bearing request elsewhere.
    static func nextLink(_ v: MValue, field: String = "@odata.nextLink", from url: URL, service: String) throws -> URL? {
        guard case .record(let r) = v, let next = text(r, field), !next.isEmpty else { return nil }
        guard let u = URL(string: next), u.scheme?.lowercased() == "https", u.host?.lowercased() == url.host?.lowercased() else {
            throw MError.dataSource("\(service) returned a next-page link to another address; it wasn't followed.")
        }
        return u
    }

    /// Every page of an OData-style listing.
    static func pagedRecords(_ ctx: MInterpreter, service: String, url start: URL, field: String = "value",
                             headers: [String: String] = [:], auth: CloudHTTP.Auth) throws -> [MRecord] {
        var out: [MRecord] = []
        var next: URL? = start
        var pages = 0
        while let url = next {
            pages += 1
            guard pages <= maxPages else { throw MError.dataSource("\(service) kept returning more pages; the listing was stopped.") }
            let page = try json(ctx, service: service, url: url, headers: headers, auth: auth)
            out += try records(page, field)
            next = try nextLink(page, from: url, service: service)
        }
        return out
    }

    // MARK: File listings

    struct File {
        var name: String
        var folderPath: String
        var size: Int
        var created: Date?
        var modified: Date?
        var accessed: Date?
        var content: () throws -> Data
    }

    /// The file table Power Query's file connectors return (the same columns as `Folder.Files`).
    static func fileTable(_ files: [File], _ ctx: MInterpreter) -> MTable {
        let offset = Double(ctx.environment.timeZone.secondsFromGMT())
        func stamp(_ d: Date?) -> MValue { d.map { .datetime($0.addingTimeInterval(offset)) } ?? .null }
        let rows = files.map { f -> [MValue] in
            let ext = (f.name as NSString).pathExtension
            let attributes = MRecord(names: ["Hidden", "Directory", "Size", "Kind"], values: [.logical(false), .logical(false), .int(f.size), .text("File")])
            let load = f.content
            let content = MValue.lazy(MThunk {
                let data = try load()
                try ctx.checkSize(data.count, of: "The file '\(f.name)'")
                return .binary(data)
            })
            return [content, .text(f.name), .text(ext.isEmpty ? "" : "." + ext), stamp(f.accessed), stamp(f.modified), stamp(f.created),
                    .record(attributes), .text(f.folderPath)]
        }
        return MTable(names: ["Content", "Name", "Extension", "Date accessed", "Date modified", "Date created", "Attributes", "Folder Path"],
                      types: [.binary, .text, .text, .nullable(.datetime), .nullable(.datetime), .nullable(.datetime), .anyRecord, .text], rows: rows)
    }

    /// A navigation table: one row per object, its table in `Data` (loaded when first used).
    static func navigation(_ items: [(name: String, kind: String, extra: [(String, MValue)], data: () throws -> MValue)]) -> MTable {
        let extraNames = items.first?.extra.map(\.0) ?? []
        let rows = items.map { item -> [MValue] in
            let load = item.data
            return [.text(item.name)] + item.extra.map(\.1) + [.lazy(MThunk { try load() }), .text(item.kind)]
        }
        return MTable(names: ["Name"] + extraNames + ["Data", "Kind"],
                      types: [.text] + extraNames.map { _ in MType.any } + [.anyTable, .text], rows: rows)
    }

    /// Records (JSON objects) as a table: columns in first-seen order, skipping OData annotations (`@odata.etag`,
    /// `revenue@OData.Community.Display.V1.FormattedValue`), which always contain "@".
    static func table(from records: [MRecord], skip: (String) -> Bool = { $0.contains("@") }) -> MTable {
        var names: [String] = [], seen = Set<String>()
        for r in records { for n in r.names where !skip(n) && seen.insert(n).inserted { names.append(n) } }
        let rows = records.map { r in names.map { n in r.fields.index[n].map { r.cell(at: $0) } ?? MValue.null } }
        return MTable(names: names, rows: rows)
    }

    // MARK: Dates

    static func isoDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    /// RFC 1123 (`Thu, 10 Sep 2020 12:00:00 GMT`), as Azure Storage sends `Last-Modified`.
    static func httpDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    // MARK: Addresses

    static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;"))

    /// `https://host` plus a path, every segment percent-encoded.
    static func url(host: String, path: [String], query: [URLQueryItem] = []) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? $0 }.joined(separator: "/")
        if !query.isEmpty { c.queryItems = query }
        return c.url
    }

    /// Parses a user-typed address into host and path segments; adds https:// when there is no scheme.
    static func parse(_ address: String, function: String) throws -> (host: String, path: [String]) {
        let t = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t.contains("://") ? t : "https://" + t), let host = c.host?.lowercased(), !host.isEmpty else {
            throw MError.dataSource("\(function) needs a web address; '\(address)' isn't one.")
        }
        guard (c.scheme ?? "https").lowercased() == "https" else { throw MError.dataSource("\(function) only connects over https.") }
        let path = c.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        return (host, path)
    }

    /// Exact host-suffix check (`a.blob.core.windows.net` for `.blob.core.windows.net`; not `blob.core.windows.net.evil`).
    static func hasSuffix(_ host: String, _ suffix: String) -> Bool {
        let h = host.lowercased()
        guard h.hasSuffix(suffix), h.count > suffix.count else { return false }
        let label = h.dropLast(suffix.count)
        return !label.hasSuffix(".") && label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }
    }
}
