import Foundation
import FacetCore

/// Power BI Desktop packages: `.pbix` (report + data) and `.pbit` (template: report + model definition, no data).
///
/// Both are ZIP archives. What can be read:
/// - `Report/Layout`: the report pages and visuals (UTF-16 JSON);
/// - `DataModelSchema` (.pbit only): the semantic model as TMSL JSON: tables, columns, measures, relationships, queries;
/// - `DataMashup`: the Power Query section document with every query.
///
/// Known limit, by design of the format: the `DataModel` stream of a `.pbix` is a compressed VertiPaq database
/// (XPress9) that cannot be decoded here. A `.pbix` therefore brings its pages and queries, not its data,
/// measures or relationships. Refresh the queries to load data again.
public enum PBIXPackage {
    /// Size limits for untrusted packages.
    public static let limits: ZipArchive.Limits = {
        var l = ZipArchive.Limits()
        l.maxEntryCount = 20_000
        l.maxTotalUncompressedSize = 8 * 1024 * 1024 * 1024
        // The DataModel entry can be most of a large file but is never read; text streams have their own cap below.
        l.maxEntrySize = l.maxTotalUncompressedSize
        return l
    }()
    /// Largest text stream (layout, schema, queries) read into memory.
    static let maxTextStream: UInt64 = 256 * 1024 * 1024

    public static let dataModelLimitNote =
        "The data model inside a .pbix file is stored in a compressed binary form that can't be decoded, so the pages and queries were imported but the data, measures and relationships were not. Refresh the queries to load data, or ask for the report as a .pbit template or .pbip project, which carry the model."

    public static func read(from url: URL) throws -> (FacetDocument, [ImportWarning]) {
        let zip = try ZipArchive(url: url, limits: limits)
        return try read(zip, name: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent)
    }

    public static func read(data: Data, name: String) throws -> (FacetDocument, [ImportWarning]) {
        try read(try ZipArchive(data: data, limits: limits), name: name, fileName: name)
    }

    private static func text(_ zip: ZipArchive, _ path: String) throws -> Data? {
        guard let entry = zip.entry(named: path) else { return nil }
        guard entry.uncompressedSize <= maxTextStream else { throw ZipError.tooLarge("“\(path)” is \(entry.uncompressedSize) bytes") }
        return try zip.data(for: entry)
    }

    private static func read(_ zip: ZipArchive, name: String, fileName: String) throws -> (FacetDocument, [ImportWarning]) {
        var doc = FacetDocument()
        var warnings: [ImportWarning] = []
        var hasReport = false
        var hasModel = false

        for path in ["Report/Layout", "Report/report.json", "Report/definition/report.json"] {
            guard let data = try text(zip, path), let json = try? JSONValue.parse(data) else { continue }
            let (report, w) = LegacyReportLayout.convert(json, resource: { _ in nil })
            if !report.pages.isEmpty { doc.report = report; hasReport = true }
            warnings += w
            break
        }

        if let data = try text(zip, "DataModelSchema"), let json = try? JSONValue.parse(data) {
            let (model, queries, w) = TMSLConverter.convert(json)
            doc.model = model
            if model.name.isEmpty || model.name == SemanticModel().name { doc.model.name = name }
            doc.queries = queries
            warnings += w
            hasModel = true
        }

        if let mashup = try text(zip, "DataMashup") {
            do {
                let queries = try DataMashup.queries(from: mashup)
                for q in queries where !doc.queries.contains(where: { $0.name == q.name }) { doc.queries.append(q) }
            } catch {
                warnings.append(ImportWarning("The Power Query queries couldn't be read: \(error.localizedDescription)", location: "DataMashup"))
            }
        }

        // A template written with a sensitivity label carries it in its metadata; keep it on the document.
        if doc.report.settings.sensitivityLabel.isEmpty, let meta = try text(zip, "Metadata"),
           let label = (try? JSONValue.parse(meta))?["SensitivityLabel"]?.stringValue, !label.isEmpty {
            doc.report.settings.sensitivityLabel = String(label.prefix(256))
        }
        guard hasReport || hasModel || !doc.queries.isEmpty else {
            throw InteropError.invalidFormat("“\(fileName)” holds no report layout, model definition or queries \(AppIdentity.name) can read.")
        }
        if zip.contains("DataModel") {
            warnings.append(ImportWarning(dataModelLimitNote, severity: .warning, location: "DataModel"))
        } else if hasModel {
            warnings.append(ImportWarning("This template carries the model definition but no data. Refresh to load it.", severity: .info))
        }
        if zip.contains("Connections") && !hasModel && doc.queries.isEmpty {
            warnings.append(ImportWarning("This report is connected live to a model in the Power BI service; connect to it with Get Data.", severity: .info, location: "Connections"))
        }
        return (doc, warnings)
    }

    // MARK: Writing a template

    static func utf16(_ j: JSONValue) -> Data {
        String(decoding: j.serialized(pretty: false), as: UTF8.self).data(using: .utf16LittleEndian) ?? Data()
    }

    static let contentTypes = """
    <?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="" /><Override PartName="/Version" ContentType="" /><Override PartName="/DataModelSchema" ContentType="" /><Override PartName="/Report/Layout" ContentType="" /><Override PartName="/Settings" ContentType="application/json" /><Override PartName="/Metadata" ContentType="application/json" /></Types>
    """

    /// The streams of a `.pbit` template for `document`: the model as TMSL and the report as a legacy layout.
    /// Data is never included (a template has none). Sensitivity is inherited through `ReportSettings.sensitivityLabel`
    /// in the package metadata.
    public static func templateFiles(for document: FacetDocument) -> [(path: String, data: Data)] {
        var metadata: [String: JSONValue] = ["Version": jn(5), "AutoCreatedRelationships": ja([]), "CreatedFrom": js(AppIdentity.name)]
        let label = document.report.settings.sensitivityLabel
        if !label.isEmpty { metadata["SensitivityLabel"] = js(label) }
        return [
            ("Version", "1.28".data(using: .utf16LittleEndian) ?? Data()),
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("DataModelSchema", utf16(TMSLWriter.document(model: document.model, queries: document.queries))),
            ("Report/Layout", utf16(LegacyLayoutWriter.layout(document.report))),
            ("Settings", utf16(jo(["Version": jn(4), "ReportSettings": jo([:]),
                                   "QueriesSettings": jo(["TypeDetectionEnabled": jb(true), "RelationshipImportEnabled": jb(true)])]))),
            ("Metadata", utf16(.object(metadata))),
        ]
    }

    /// Writes `document` as a `.pbit` template.
    public static func writeTemplate(_ document: FacetDocument, to url: URL) throws {
        let data = try ZipWriter.archive(templateFiles(for: document))
        do { try data.write(to: url, options: .atomic) }
        catch { throw InteropError.io("Couldn't write “\(url.lastPathComponent)”: \(error.localizedDescription)") }
    }

    /// The sensitivity label stored in a package's metadata, if any.
    public static func sensitivityLabel(in url: URL) -> String? {
        guard let zip = try? ZipArchive(url: url, limits: limits), let data = try? text(zip, "Metadata"),
              let json = try? JSONValue.parse(data) else { return nil }
        return json["SensitivityLabel"]?.stringValue
    }
}

/// The `DataMashup` stream (MS-QDEFF): a small header followed by an embedded ZIP whose
/// `Formulas/Section1.m` holds every query as a member of one M section document.
public enum DataMashup {
    static let limits: ZipArchive.Limits = {
        var l = ZipArchive.Limits()
        l.maxEntryCount = 1_000
        l.maxTotalUncompressedSize = 256 * 1024 * 1024
        l.maxEntrySize = 128 * 1024 * 1024
        return l
    }()

    public static func queries(from data: Data) throws -> [QueryDefinition] {
        let bytes = data.startIndex == 0 ? data : Data(data)
        guard bytes.count >= 8 else { throw InteropError.invalidFormat("The query stream is too short.") }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        guard u32(0) == 0 else { throw InteropError.invalidFormat("The query stream has an unknown version.") }
        let length = u32(4)
        guard length > 0, length <= bytes.count - 8 else { throw InteropError.invalidFormat("The query stream is truncated.") }
        let zip = try ZipArchive(data: bytes.subdata(in: 8..<(8 + length)), limits: limits)
        guard let section = zip.entry(named: "Formulas/Section1.m") else { return [] }
        let text = String(decoding: try zip.data(for: section), as: UTF8.self)
        return parseSection(text)
    }

    /// Splits an M section document (`section Section1; shared A = …; shared B = …;`) into its members.
    public static func parseSection(_ text: String) -> [QueryDefinition] {
        var members: [String] = []
        var current = ""
        var depth = 0
        let chars = Array(text)
        var i = 0
        func peek(_ o: Int) -> Character? { i + o < chars.count ? chars[i + o] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                // String or quoted identifier body: "" is an escaped quote.
                current.append(c); i += 1
                while i < chars.count {
                    current.append(chars[i])
                    if chars[i] == "\"" {
                        if peek(1) == "\"" { current.append("\""); i += 2; continue }
                        i += 1; break
                    }
                    i += 1
                }
                continue
            }
            if c == "/", peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { current.append(chars[i]); i += 1 }
                continue
            }
            if c == "/", peek(1) == "*" {
                while i < chars.count {
                    if chars[i] == "*", peek(1) == "/" { current.append("*/"); i += 2; break }
                    current.append(chars[i]); i += 1
                }
                continue
            }
            if "([{".contains(c) { depth += 1 }
            if ")]}".contains(c) { depth = max(0, depth - 1) }
            if c == ";", depth == 0 {
                members.append(current); current = ""; i += 1
                continue
            }
            current.append(c); i += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { members.append(current) }

        var out: [QueryDefinition] = []
        for member in members {
            var body = stripLeadingComments(member)
            if body.hasPrefix("section ") || body == "section" { continue }
            // Literal attributes such as [ Description = "…" ] may precede a member.
            var description = ""
            if body.hasPrefix("["), let close = closingBracket(in: body) {
                let attributes = String(body[body.index(after: body.startIndex)..<close])
                if let r = attributes.range(of: #"Description\s*=\s*"((?:[^"]|"")*)""#, options: .regularExpression) {
                    let match = String(attributes[r])
                    if let q = match.firstIndex(of: "\"") {
                        description = String(match[match.index(after: q)..<match.index(before: match.endIndex)]).replacingOccurrences(of: "\"\"", with: "\"")
                    }
                }
                body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if body.hasPrefix("shared ") { body = String(body.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let (name, expression) = splitMember(body) else { continue }
            var q = QueryDefinition(name: name, mScript: expression)
            q.description = description
            out.append(q)
        }
        return out
    }

    /// Drops comments and blank space that precede a section member.
    private static func stripLeadingComments(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            if body.hasPrefix("//") {
                body = body.firstIndex(of: "\n").map { String(body[$0...]) } ?? ""
            } else if body.hasPrefix("/*") {
                body = body.range(of: "*/").map { String(body[$0.upperBound...]) } ?? ""
            } else {
                return body
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func closingBracket(in s: String) -> String.Index? {
        var depth = 0, inString = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1; if depth == 0 { return i } }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// `Name = expression` or `#"Quoted name" = expression`.
    private static func splitMember(_ s: String) -> (String, String)? {
        var name: String
        var rest: Substring
        if s.hasPrefix("#\"") {
            var i = s.index(s.startIndex, offsetBy: 2)
            var collected = ""
            var closed = false
            while i < s.endIndex {
                if s[i] == "\"" {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == "\"" { collected.append("\""); i = s.index(after: next); continue }
                    closed = true; i = next; break
                }
                collected.append(s[i]); i = s.index(after: i)
            }
            guard closed else { return nil }
            name = collected; rest = s[i...]
        } else {
            guard let eq = s.firstIndex(of: "=") else { return nil }
            name = String(s[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines); rest = s[eq...]
        }
        let trimmed = rest.drop { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        guard trimmed.first == "=", !name.isEmpty else { return nil }
        return (name, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
