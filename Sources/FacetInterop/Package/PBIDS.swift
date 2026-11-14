import Foundation
import FacetCore

/// Power BI data source files (`.pbids`): a small JSON document naming one or more connections.
/// Opening one starts Get Data with the connection filled in. No credentials are ever stored in a `.pbids` file.
public enum PBIDS {
    public static let maxFileSize = 1 * 1024 * 1024
    public static let maxConnections = 50

    public struct Connection: Equatable, Sendable {
        /// The `.pbids` protocol: `tds`, `file`, `folder`, `http`, `odata`, `sharepoint-list`, `postgresql`…
        public var protocolName: String
        /// `Import` or `DirectQuery`.
        public var mode: String
        /// A name for the query this connection becomes.
        public var queryName: String
        /// The Power Query (M) expression that opens the source.
        public var mScript: String
        /// One line describing the source, for messages.
        public var summary: String
        /// What the connection points at, as Get Data's connection form asks for it: the file or folder path, the
        /// web or feed address, the server, or the ODBC data source name.
        public var location: String
        public var isDirectQuery: Bool { mode.caseInsensitiveCompare("DirectQuery") == .orderedSame }
    }

    /// Reads at most `maxFileSize` bytes, and only from a regular file: a link is followed to its target, and a
    /// device, pipe or folder is refused rather than read without end.
    public static func read(from url: URL) throws -> [Connection] {
        let target = url.resolvingSymlinksInPath()
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileSize else { throw InteropError.invalidFormat("“\(url.lastPathComponent)” is too large to be a data source file.") }
        return try parse(try BoundedFile.read(target, limit: maxFileSize))
    }

    public static func parse(_ data: Data) throws -> [Connection] {
        guard data.count <= maxFileSize else { throw InteropError.invalidFormat("The data source file is too large.") }
        guard let json = try? JSONValue.parse(data), let list = json["connections"]?.arrayValue else {
            throw InteropError.invalidFormat("This isn't a Power BI data source file: it has no “connections” list.")
        }
        guard !list.isEmpty else { throw InteropError.invalidFormat("The data source file lists no connections.") }
        guard list.count <= maxConnections else { throw InteropError.invalidFormat("The data source file lists \(list.count) connections; at most \(maxConnections) are supported.") }
        return try list.enumerated().map { try connection($1, index: $0) }
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func script(_ source: String) -> String { "let\n    Source = \(source)\nin\n    Source" }

    private static func connection(_ c: JSONValue, index: Int) throws -> Connection {
        let details = c["details"]
        let proto = (details?["protocol"]?.stringValue ?? "").lowercased()
        let address = details?["address"]
        func text(_ key: String) -> String { (address?[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func need(_ key: String) throws -> String {
            let v = text(key)
            guard !v.isEmpty else { throw InteropError.invalidFormat("Connection \(index + 1) (\(proto)) is missing its “\(key)”.") }
            return v
        }
        let mode = c["mode"]?.stringValue ?? "Import"
        func make(_ name: String, _ source: String, _ summary: String, location: String) -> Connection {
            Connection(protocolName: proto, mode: mode, queryName: name.isEmpty ? "Query \(index + 1)" : name, mScript: script(source),
                       summary: summary, location: location)
        }
        func database(_ function: String, _ label: String) throws -> Connection {
            let server = try need("server"), db = text("database")
            let source = db.isEmpty ? "\(function)(\(quote(server)))" : "\(function)(\(quote(server)), \(quote(db)))"
            return make(db.isEmpty ? server : db, source, "\(label) \(server)" + (db.isEmpty ? "" : " / \(db)"), location: server)
        }
        switch proto {
        case "tds":
            let server = try need("server"), db = text("database")
            let source = db.isEmpty ? "Sql.Databases(\(quote(server)))" : "Sql.Database(\(quote(server)), \(quote(db)))"
            return make(db.isEmpty ? server : db, source, "SQL Server \(server)" + (db.isEmpty ? "" : " / \(db)"), location: server)
        case "postgresql": return try database("PostgreSQL.Database", "PostgreSQL")
        case "mysql": return try database("MySQL.Database", "MySQL")
        case "analysis-services": return try database("AnalysisServices.Database", "Analysis Services")
        case "oracle":
            let server = try need("server")
            return make(server, "Oracle.Database(\(quote(server)))", "Oracle \(server)", location: server)
        case "file":
            let path = try need("path")
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let contents = "File.Contents(\(quote(path)))"
            let source: String
            switch (path as NSString).pathExtension.lowercased() {
            case "csv", "txt", "tsv": source = "Csv.Document(\(contents))"
            case "xlsx", "xlsm", "xls": source = "Excel.Workbook(\(contents), null, true)"
            case "json": source = "Json.Document(\(contents))"
            case "xml": source = "Xml.Tables(\(contents))"
            case "parquet": source = "Parquet.Document(\(contents))"
            default: source = contents
            }
            return make(name, source, "File \(path)", location: path)
        case "folder":
            let path = try need("path")
            return make((path as NSString).lastPathComponent, "Folder.Files(\(quote(path)))", "Folder \(path)", location: path)
        case "http":
            let url = try need("url")
            return make(URL(string: url)?.host ?? "Web", "Web.Contents(\(quote(url)))", "Web \(url)", location: url)
        case "odata":
            let url = try need("url")
            return make(URL(string: url)?.host ?? "OData", "OData.Feed(\(quote(url)))", "OData feed \(url)", location: url)
        case "sharepoint-list":
            let url = try need("url")
            return make(URL(string: url)?.host ?? "SharePoint", "SharePoint.Tables(\(quote(url)), [ApiVersion = 15])", "SharePoint list \(url)", location: url)
        case "odbc":
            let dsn = address?["options"]?["dsn"]?.stringValue ?? text("dsn")
            guard !dsn.isEmpty else { throw InteropError.invalidFormat("Connection \(index + 1) (odbc) is missing its “dsn”.") }
            return make(dsn, "Odbc.DataSource(\(quote("dsn=" + dsn)), [HierarchicalNavigation = true])", "ODBC \(dsn)", location: dsn)
        case "":
            throw InteropError.invalidFormat("Connection \(index + 1) doesn't say which protocol it uses.")
        default:
            throw InteropError.unsupported("Connection \(index + 1) uses the “\(proto)” protocol, which \(AppIdentity.name) can't open from a data source file. Use Get Data to connect to it.")
        }
    }
}

/// A `.facet` document is a folder package. To travel as one file (OneDrive, SharePoint, e-mail) it is
/// zipped; this type packs and unpacks that single-file form with the limits applied to any untrusted archive.
public enum FacetArchive {
    public static let limits: ZipArchive.Limits = {
        var l = ZipArchive.Limits()
        l.maxEntryCount = 20_000
        l.maxTotalUncompressedSize = 8 * 1024 * 1024 * 1024
        return l
    }()

    /// True when `url` is a regular file that starts with a ZIP signature (rather than a package folder). A pipe or
    /// device is never opened, so this can't block.
    public static func isArchive(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: target) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        return head.count == 4 && head[head.startIndex] == 0x50 && head[head.startIndex + 1] == 0x4B
    }

    /// Zips the package folder at `package` into a single file at `zipURL`. Symbolic links are not followed or stored.
    public static func pack(package: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        let root = package.standardizedFileURL.path
        guard let walker = fm.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw InteropError.io("Couldn't read “\(package.lastPathComponent)”.")
        }
        var files: [(String, URL)] = []
        for case let f as URL in walker {
            let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = f.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            files.append((String(path.dropFirst(root.count + 1)), f))
            guard files.count <= limits.maxEntryCount else { throw InteropError.invalidFormat("The document holds too many files to upload.") }
        }
        guard files.contains(where: { $0.0 == "manifest.json" }) else {
            throw InteropError.invalidFormat("“\(package.lastPathComponent)” is not an \(AppIdentity.name) document.")
        }
        let writer = try ZipWriter(url: zipURL)
        for (path, url) in files.sorted(by: { $0.0 < $1.0 }) {
            try writer.add(path: path, data: try Data(contentsOf: url, options: .mappedIfSafe))
        }
        _ = try writer.finish()
    }

    /// Unpacks a zipped document into a package folder at `packageURL` (replacing it). Refuses archives that are not
    /// a document, hold unsafe paths, or exceed the size and entry limits.
    public static func unpack(_ zipURL: URL, to packageURL: URL) throws {
        let zip = try ZipArchive(url: zipURL, limits: limits)
        guard zip.contains("manifest.json") else {
            throw InteropError.invalidFormat("“\(zipURL.lastPathComponent)” is not an \(AppIdentity.name) document.")
        }
        let fm = FileManager.default
        let staging = packageURL.deletingLastPathComponent().appendingPathComponent(".unpack-\(UUID().uuidString)")
        do {
            try zip.extractAll(to: staging)
            if fm.fileExists(atPath: packageURL.path) { try fm.removeItem(at: packageURL) }
            try fm.moveItem(at: staging, to: packageURL)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
