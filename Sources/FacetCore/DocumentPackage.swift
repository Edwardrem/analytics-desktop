import Foundation

/// Reads and writes `.facet` document packages: a folder of plain JSON so documents
/// diff cleanly in Git, with table data kept in separate columnar files.
///
///     Sales.facet/
///       manifest.json   format version and app version
///       model.json      semantic model metadata
///       report.json     pages, visuals, bookmarks, theme
///       queries.json    Power Query (M) queries
///       sources.json    remembered data sources (no secrets)
///       data/<table>.json
public enum DocumentPackage {
    public static let formatVersion = 1
    public static let fileExtension = "facet"

    struct Manifest: Codable { var formatVersion: Int; var app: String; var savedAt: Date }

    public enum PackageError: LocalizedError {
        case notAPackage(URL), newerFormat(Int)
        public var errorDescription: String? {
            switch self {
            case .notAPackage(let u): return "“\(u.lastPathComponent)” is not a Facet document."
            case .newerFormat(let v): return "This document was saved by a newer version of Facet (format \(v))."
            }
        }
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Writes atomically: builds the package beside the destination, then swaps it in.
    public static func write(_ doc: FacetDocument, to url: URL, includeData: Bool = true) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).facet-tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let e = encoder(pretty: true)
            try e.encode(Manifest(formatVersion: formatVersion, app: "Facet", savedAt: Date())).write(to: tmp.appendingPathComponent("manifest.json"))
            try e.encode(doc.model).write(to: tmp.appendingPathComponent("model.json"))
            try e.encode(doc.report).write(to: tmp.appendingPathComponent("report.json"))
            try e.encode(doc.queries).write(to: tmp.appendingPathComponent("queries.json"))
            try e.encode(doc.dataSources).write(to: tmp.appendingPathComponent("sources.json"))
            if includeData {
                let dataDir = tmp.appendingPathComponent("data")
                try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
                let compact = encoder(pretty: false)
                for (name, table) in doc.data.tables {
                    try compact.encode(table).write(to: dataDir.appendingPathComponent(fileName(for: name) + ".json"))
                }
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public static func read(from url: URL) throws -> FacetDocument {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw PackageError.notAPackage(url) }
        let d = decoder
        let manifest = try d.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion <= formatVersion else { throw PackageError.newerFormat(manifest.formatVersion) }
        var doc = FacetDocument()
        doc.model = try d.decode(SemanticModel.self, from: Data(contentsOf: url.appendingPathComponent("model.json")))
        doc.report = try d.decode(Report.self, from: Data(contentsOf: url.appendingPathComponent("report.json")))
        if let q = try? Data(contentsOf: url.appendingPathComponent("queries.json")) {
            doc.queries = try d.decode([QueryDefinition].self, from: q)
        }
        if let s = try? Data(contentsOf: url.appendingPathComponent("sources.json")) {
            doc.dataSources = (try? d.decode([DataSourceRecord].self, from: s)) ?? []
        }
        let dataDir = url.appendingPathComponent("data")
        if let files = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                let t = try d.decode(DataTable.self, from: Data(contentsOf: f))
                doc.data[t.name] = t
            }
        }
        return doc
    }

    /// File-system-safe name for a table.
    public static func fileName(for table: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        let s = String(table.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        return s.isEmpty ? "table" : s
    }
}
