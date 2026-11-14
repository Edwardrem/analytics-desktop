import Foundation
import FacetCore

/// SharePoint Online and OneDrive through Microsoft Graph, with the signed-in organizational account:
/// `SharePoint.Files` (every file of a site's document libraries), `SharePoint.Tables` (the site's lists and their
/// items) and OneDrive / SharePoint file addresses read by `Web.Contents`.
enum SharePointSource {
    static let service = "SharePoint"
    static let graphHost = "graph.microsoft.com"
    static var graphAuth: CloudHTTP.Auth { .entra(resource: EntraResource.graph) }

    /// `<tenant>.sharepoint.com` or `<tenant>-my.sharepoint.com`.
    static func isSharePointHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return CloudSource.hasSuffix(h, ".sharepoint.com") && !h.dropLast(".sharepoint.com".count).contains(".")
    }

    static func graph(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = graphHost; c.percentEncodedPath = "/v1.0" + path
        if !query.isEmpty { c.queryItems = query }
        guard let u = c.url else { throw MError.dataSource("Couldn't build a Microsoft Graph address for '\(path)'.") }
        return u
    }

    /// The Graph site id of a SharePoint site address such as `https://contoso.sharepoint.com/sites/Sales`.
    static func site(_ ctx: MInterpreter, _ address: String, function: String) throws -> (id: String, host: String, sitePath: [String]) {
        let (host, path) = try CloudSource.parse(address, function: function)
        guard isSharePointHost(host) else {
            throw MError.dataSource("\(function) needs a SharePoint Online site address such as https://contoso.sharepoint.com/sites/Sales; '\(host)' isn't one.")
        }
        try ctx.noteDataSource(kind: "SharePoint", location: siteLocation(host: host, path: path))
        let encodedPath = path.map { $0.addingPercentEncoding(withAllowedCharacters: CloudSource.segmentAllowed) ?? $0 }.joined(separator: "/")
        let url = try graph("/sites/\(host)" + (path.isEmpty ? "" : ":/\(encodedPath)"), [URLQueryItem(name: "$select", value: "id,webUrl")])
        guard case .record(let r) = try CloudSource.json(ctx, service: service, url: url, auth: graphAuth), let id = CloudSource.text(r, "id") else {
            throw MError.dataSource("SharePoint didn't return the site '\(address)'.")
        }
        return (id, host, path)
    }

    static func siteLocation(host: String, path: [String]) -> String {
        "https://\(host)" + (path.isEmpty ? "" : "/" + path.joined(separator: "/"))
    }

    static func segment(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CloudSource.segmentAllowed) ?? s }

    // MARK: SharePoint.Files

    static func files(_ ctx: MInterpreter, address: String) throws -> MTable {
        let site = try site(ctx, address, function: "SharePoint.Files")
        let drives = try CloudSource.pagedRecords(ctx, service: service, url: try graph("/sites/\(segment(site.id))/drives",
                                                                                         [URLQueryItem(name: "$select", value: "id,name,webUrl")]), auth: graphAuth)
        var files: [CloudSource.File] = []
        for drive in drives {
            guard let driveID = CloudSource.text(drive, "id") else { continue }
            let url = try graph("/drives/\(segment(driveID))/root/delta",
                                [URLQueryItem(name: "$select", value: "id,name,file,folder,size,webUrl,createdDateTime,lastModifiedDateTime,deleted,root")])
            for item in try CloudSource.pagedRecords(ctx, service: service, url: url, auth: graphAuth) {
                guard CloudSource.record(item, "file") != nil, CloudSource.record(item, "deleted") == nil,
                      let id = CloudSource.text(item, "id"), let name = CloudSource.text(item, "name") else { continue }
                files.append(file(item, id: id, name: name, driveID: driveID, ctx: ctx))
            }
        }
        files.sort { ($0.folderPath, $0.name) < ($1.folderPath, $1.name) }
        return CloudSource.fileTable(files, ctx)
    }

    private static func file(_ item: MRecord, id: String, name: String, driveID: String, ctx: MInterpreter) -> CloudSource.File {
        // Folder Path as Power BI shows it: the item's web address without its name, decoded, ending in "/".
        var folder = CloudSource.text(item, "webUrl").flatMap { $0.removingPercentEncoding } ?? ""
        if folder.hasSuffix(name) { folder.removeLast(name.count) }
        if !folder.hasSuffix("/") { folder += "/" }
        let content: () throws -> Data = {
            let url = try graph("/drives/\(segment(driveID))/items/\(segment(id))/content")
            return try CloudHTTP.send(ctx, service: service, url: url, auth: graphAuth).data
        }
        return CloudSource.File(name: name, folderPath: folder, size: Int(CloudSource.number(item, "size") ?? 0),
                                created: CloudSource.isoDate(CloudSource.text(item, "createdDateTime")),
                                modified: CloudSource.isoDate(CloudSource.text(item, "lastModifiedDateTime")), accessed: nil, content: content)
    }

    // MARK: SharePoint.Tables

    static func tables(_ ctx: MInterpreter, address: String) throws -> MTable {
        let site = try site(ctx, address, function: "SharePoint.Tables")
        let base = "/sites/\(segment(site.id))/lists"
        let lists = try CloudSource.pagedRecords(ctx, service: service, url: try graph(base, [URLQueryItem(name: "$select", value: "id,displayName,name,list")]), auth: graphAuth)
        let visible = lists.filter { CloudSource.record($0, "list").flatMap { (try? $0.logical("hidden")) ?? nil } != true }
        return CloudSource.navigation(visible.compactMap { list in
            guard let id = CloudSource.text(list, "id") else { return nil }
            let title = CloudSource.text(list, "displayName") ?? CloudSource.text(list, "name") ?? id
            return (title, "Table", [("Id", .text(id))], { .table(try items(ctx, listPath: base + "/" + segment(id))) })
        })
    }

    /// A list's items: `Id`, then every visible column under its display name.
    static func items(_ ctx: MInterpreter, listPath: String) throws -> MTable {
        let columns = try CloudSource.pagedRecords(ctx, service: service, url: try graph(listPath + "/columns"), auth: graphAuth)
            .filter { (try? $0.logical("hidden")) ?? nil != true }
            .compactMap { c -> (name: String, display: String)? in
                guard let n = CloudSource.text(c, "name") else { return nil }
                return (n, CloudSource.text(c, "displayName") ?? n)
            }
        let rows = try CloudSource.pagedRecords(ctx, service: service, url: try graph(listPath + "/items",
                                                [URLQueryItem(name: "$expand", value: "fields"), URLQueryItem(name: "$top", value: "999")]), auth: graphAuth)
        let names = MLib.uniqued(["Id"] + columns.map(\.display))
        let values = rows.map { item -> [MValue] in
            let fields = CloudSource.record(item, "fields")
            let id = CloudSource.text(item, "id").map { Double($0).map(MValue.number) ?? .text($0) } ?? .null
            return [id] + columns.map { c in (fields.flatMap { (try? $0.get(c.name)) ?? nil }) ?? .null }
        }
        return MTable(names: names, rows: values)
    }

    // MARK: OneDrive and SharePoint file addresses

    /// A file in OneDrive for work or school or SharePoint, by its web address, through Graph's shares API.
    static func download(_ ctx: MInterpreter, url: URL) throws -> Data {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil; c?.fragment = nil
        let address = c?.string ?? url.absoluteString
        let token = "u!" + Data(address.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return try CloudHTTP.send(ctx, service: "OneDrive", url: try graph("/shares/\(token)/driveItem/content"), auth: graphAuth).data
    }
}

extension MLibrary {
    static func registerSharePoint(_ lib: MLibrary) {
        lib.fn("SharePoint.Files", 1...2) { a, ctx in .table(try SharePointSource.files(ctx, address: try a.text(0))) }
        lib.fn("SharePoint.Tables", 1...2) { a, ctx in .table(try SharePointSource.tables(ctx, address: try a.text(0))) }
    }
}
