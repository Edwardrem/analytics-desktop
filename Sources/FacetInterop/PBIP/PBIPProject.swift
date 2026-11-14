import Foundation
import FacetCore

/// Reads and writes Power BI Project (PBIP) folders: TMDL semantic model + PBIR report, as text files for source control.
public enum PBIPProject {
    public struct WriteOptions: Sendable {
        /// Also drop Facet's table data in `<Name>.SemanticModel/.pbi/facet-cache/` (git-ignored), so reopening needs no refresh.
        public var includeFacetDataCache = false
        /// Store the full Facet objects in `Facet_*` annotations for a lossless round trip. Turn off for a pure Power BI project.
        public var includeFacetAnnotations = true
        public init(includeFacetDataCache: Bool = false, includeFacetAnnotations: Bool = true) {
            self.includeFacetDataCache = includeFacetDataCache; self.includeFacetAnnotations = includeFacetAnnotations
        }
    }

    static let platformSchema = "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json"
    static let gitignore = "**/.pbi/localSettings.json\n**/.pbi/cache.abf\n**/.pbi/facet-cache/\n"

    /// Generates every file of the project in memory (paths relative to the project folder), plus export warnings.
    public static func files(for document: FacetDocument, name: String, options: WriteOptions = WriteOptions(),
                             logicalIDs: (report: String, model: String) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased())) -> (files: [(path: String, data: Data)], warnings: [ImportWarning]) {
        var out: [(String, Data)] = []
        var warnings: [ImportWarning] = []
        let annotate = options.includeFacetAnnotations
        func add(_ path: String, _ j: JSONValue) { out.append((path, j.serialized())) }
        let model = "\(name).SemanticModel", report = "\(name).Report"

        add("\(name).pbip", jo(["$schema": js("https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json"),
                                "version": js("1.0"), "artifacts": ja([jo(["report": jo(["path": js(report)])])]),
                                "settings": jo(["enableAutoRecovery": jb(true)])]))
        out.append((".gitignore", Data(gitignore.utf8)))

        // Semantic model.
        func platform(_ type: String, _ id: String) -> JSONValue {
            jo(["$schema": js(platformSchema), "metadata": jo(["type": js(type), "displayName": js(name)]),
                "config": jo(["version": js("2.0"), "logicalId": js(id)])])
        }
        add("\(model)/.platform", platform("SemanticModel", logicalIDs.model))
        add("\(model)/definition.pbism", jo(["$schema": js("https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json"),
                                             "version": js("4.2"), "settings": jo([:])]))
        for f in TMDL.serialize(model: document.model, queries: document.queries) {
            out.append(("\(model)/definition/\(f.path)", Data(f.text.utf8)))
        }
        if options.includeFacetDataCache {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            var used = Set<String>()
            for (tableName, table) in document.data.tables.sorted(by: { $0.key < $1.key }) {
                var file = DocumentPackage.fileName(for: tableName)
                while !used.insert(file.lowercased()).inserted { file += "_" }
                var t = table
                t.name = tableName
                if let d = try? e.encode(t) { out.append(("\(model)/.pbi/facet-cache/\(file).json", d)) }
            }
        }

        // Report.
        add("\(report)/.platform", platform("Report", logicalIDs.report))
        add("\(report)/definition.pbir", jo(["$schema": js("https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json"),
                                             "version": js("4.0"), "datasetReference": jo(["byPath": jo(["path": js("../\(model)")])])]))
        let def = "\(report)/definition"
        add("\(def)/version.json", jo(["$schema": PBIR.schema("versionMetadata"), "version": js("2.0.0")]))
        let themeFile = PowerBITheme.resourceName(for: document.report.theme)
        add("\(def)/report.json", PBIR.reportJSON(document, themeFile: themeFile, includeAnnotations: annotate))
        out.append(("\(report)/StaticResources/RegisteredResources/\(themeFile)", PowerBITheme.export(document.report.theme, includeFacetExtensions: annotate)))

        let r = document.report
        let active = r.landingPageID.flatMap { id in r.pages.first { $0.id == id } } ?? r.pages.first
        var pagesIndex: [String: JSONValue] = ["$schema": PBIR.schema("pagesMetadata"), "pageOrder": ja(r.pages.map { js($0.id.lower) })]
        if let active { pagesIndex["activePageName"] = js(active.id.lower) }
        add("\(def)/pages/pages.json", .object(pagesIndex))
        for p in r.pages {
            let dir = "\(def)/pages/\(p.id.lower)"
            add("\(dir)/page.json", PBIR.pageJSON(p, includeAnnotations: annotate))
            for v in p.visuals {
                add("\(dir)/visuals/\(v.id.lower)/visual.json", PBIR.visualJSON(v, includeAnnotations: annotate))
                if let m = v.mobileFrame { add("\(dir)/visuals/\(v.id.lower)/mobile.json", PBIR.mobileJSON(m, z: v.zIndex)) }
                if !PowerBIMapping.hasPowerBIEquivalent(v.type) {
                    warnings.append(ImportWarning("“\(v.name)” is a \(v.type.displayName), which Power BI doesn't have; it was written as custom visual type “\(PowerBIMapping.powerBIType(for: v.type))” and will only render in Facet.",
                                                  location: "\(p.name)/\(v.name)"))
                }
            }
            for (gid, gname) in p.groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                add("\(dir)/visuals/\(gid.lower)/visual.json", PBIR.groupJSON(id: gid, name: gname, members: p.visuals.filter { $0.groupID == gid }))
            }
        }
        if !r.bookmarks.isEmpty {
            add("\(def)/bookmarks/bookmarks.json", PBIR.bookmarksIndex(r.bookmarks))
            for b in r.bookmarks { add("\(def)/bookmarks/\(b.id.lower).bookmark.json", PBIR.bookmarkJSON(b, includeAnnotations: annotate)) }
        }
        if !document.data.tables.isEmpty, !options.includeFacetDataCache {
            warnings.append(ImportWarning("Table data isn't stored in a project; it is reloaded by refreshing the queries.", severity: .info))
        }
        return (out, warnings)
    }

    /// Writes the project into `folder` (created if needed). Unchanged files are left untouched and files for deleted
    /// pages, visuals, bookmarks and tables are removed, so the folder diffs cleanly in Git.
    @discardableResult
    public static func write(document: FacetDocument, to folder: URL, name: String, options: WriteOptions = WriteOptions()) throws -> [ImportWarning] {
        let fm = FileManager.default
        let safeName = DocumentPackage.fileName(for: name)
        // Keep the logical ids of an existing project stable.
        func existingID(_ item: String) -> String? {
            let url = folder.appendingPathComponent("\(safeName).\(item)/.platform")
            return BoundedFile.readIfPresent(url).flatMap { try? JSONValue.parse($0) }?.at("config", "logicalId")?.stringValue
        }
        let ids = (report: existingID("Report") ?? UUID().lower, model: existingID("SemanticModel") ?? UUID().lower)
        let generated = files(for: document, name: safeName, options: options, logicalIDs: ids)
        let managed = ["\(safeName).Report/definition", "\(safeName).SemanticModel/definition", "\(safeName).SemanticModel/.pbi/facet-cache",
                       "\(safeName).Report/StaticResources/RegisteredResources"]
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw InteropError.io("Couldn't write the project to “\(folder.path)”: \(error.localizedDescription)") }
        guard let root = ProjectPaths.realPath(folder) else { throw InteropError.io("Couldn't open the project folder “\(folder.path)”.") }
        // Check every target before writing anything, so a link planted in the project changes nothing.
        for path in generated.files.map(\.path) + managed { try ProjectPaths.checkWritable(path, in: folder, root: root) }
        do {
            var written = Set<String>()
            for (path, data) in generated.files {
                written.insert(path)
                let url = folder.appendingPathComponent(path)
                if let old = BoundedFile.readIfPresent(url, limit: max(data.count, 1)), old == data { continue }
                try fm.writeCreatingDirectories(data, to: url)
            }
            for base in managed { prune(base, keeping: written, in: folder, root: root) }
        } catch {
            throw InteropError.io("Couldn't write the project to “\(folder.path)”: \(error.localizedDescription)")
        }
        return generated.warnings
    }

    /// Removes generated files under `managed` that this save didn't write (deleted pages, visuals, tables).
    /// Links are never followed or deleted, and nothing outside the project folder is touched.
    static func prune(_ managed: String, keeping written: Set<String>, in folder: URL, root: String) {
        let fm = FileManager.default
        let base = folder.appendingPathComponent(managed)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard !ProjectPaths.isSymbolicLink(base), ProjectPaths.isInside(base, root: root), let baseReal = ProjectPaths.realPath(base),
              let walker = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: []) else { return }
        var dirs: [URL] = []
        // The URL enumerator lists a link but never descends into it; links themselves are left in place.
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink == false, let real = ProjectPaths.realPath(url), real.hasPrefix(baseReal + "/") else { continue }
            if values?.isDirectory == true { dirs.append(url); continue }
            guard values?.isRegularFile == true, !written.contains(managed + "/" + real.dropFirst(baseReal.count + 1)) else { continue }
            try? fm.removeItem(at: url)
        }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) where (try? fm.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
            try? fm.removeItem(at: d)
        }
    }

    /// Opens a project: pass the project folder, the `.pbip` file, or a `.Report` / `.SemanticModel` folder.
    /// Unknown content never fails the import; it is reported in the warnings.
    public static func read(from url: URL) throws -> (FacetDocument, [ImportWarning]) {
        let fm = FileManager.default
        var warnings: [ImportWarning] = []
        var reportDir: URL?, modelDir: URL?

        var pbip: URL?
        // The project folder: everything is read from inside it, whatever paths or links the project holds.
        var folder = url.deletingLastPathComponent()
        if url.pathExtension.lowercased() == "pbip" { pbip = url }
        else if fm.isDirectory(url) {
            if url.lastPathComponent.hasSuffix(".Report") { reportDir = url }
            else if url.lastPathComponent.hasSuffix(".SemanticModel") || url.lastPathComponent.hasSuffix(".Dataset") { modelDir = url }
            else {
                folder = url
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                pbip = items.filter { $0.pathExtension.lowercased() == "pbip" }.sorted { $0.path < $1.path }.first
                if pbip == nil {
                    reportDir = items.first { $0.lastPathComponent.hasSuffix(".Report") }
                    modelDir = items.first { $0.lastPathComponent.hasSuffix(".SemanticModel") || $0.lastPathComponent.hasSuffix(".Dataset") }
                }
            }
        }
        guard let root = ProjectPaths.realPath(folder) else {
            throw InteropError.missingFile("“\(url.lastPathComponent)” doesn't contain a Power BI project (.pbip, .Report or .SemanticModel).")
        }
        let inside = { (u: URL) in ProjectPaths.isInside(u, root: root) }
        func json(_ u: URL) -> JSONValue? { inside(u) ? BoundedFile.readIfPresent(u).flatMap { try? JSONValue.parse($0) } : nil }
        func confine(_ dir: URL, _ what: String, _ written: String) throws {
            guard inside(dir) else {
                throw InteropError.invalidFormat("The project's \(what) (“\(written)”) is outside the folder that holds the project, so it wasn't opened. \(AppIdentity.name) only reads a project's report and semantic model from inside that folder. Move the folder there, or open it directly.")
            }
        }
        if let pbip {
            guard let j = json(pbip) else { throw InteropError.invalidFormat("“\(pbip.lastPathComponent)” is not a valid Power BI project file.") }
            if let path = j["artifacts"]?[0]?["report"]?["path"]?.stringValue {
                reportDir = pbip.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                if let reportDir { try confine(reportDir, "report folder", path) }
            }
        }
        if let reportDir, modelDir == nil {
            if let pbir = json(reportDir.appendingPathComponent("definition.pbir")) {
                if let path = pbir["datasetReference"]?["byPath"]?["path"]?.stringValue {
                    let dir = reportDir.appendingPathComponent(path).standardizedFileURL
                    try confine(dir, "semantic model", path)
                    modelDir = dir
                } else if pbir["datasetReference"]?["byConnection"] != nil {
                    warnings.append(ImportWarning("The report uses a live connection to a published semantic model; no model was imported.", location: "definition.pbir"))
                }
            }
        }
        guard reportDir != nil || modelDir != nil else {
            throw InteropError.missingFile("“\(url.lastPathComponent)” doesn't contain a Power BI project (.pbip, .Report or .SemanticModel).")
        }

        var doc = FacetDocument()
        doc.report.pages = []
        // Semantic model.
        if let modelDir {
            let defDir = modelDir.appendingPathComponent("definition")
            if fm.isDirectory(defDir) {
                var tmdl: [TMDLFile] = []
                if let walker = fm.enumerator(at: defDir, includingPropertiesForKeys: nil) {
                    for case let f as URL in walker where f.pathExtension.lowercased() == "tmdl" {
                        guard tmdl.count < BoundedFile.maxProjectFiles else {
                            throw InteropError.invalidFormat("“\(modelDir.lastPathComponent)” holds more than \(BoundedFile.maxProjectFiles) model files.")
                        }
                        guard inside(f), let text = BoundedFile.readIfPresent(f).flatMap(TextDecoding.string(from:)) else {
                            warnings.append(ImportWarning("“\(f.lastPathComponent)” couldn't be read (missing, unreadable or too large).", location: f.lastPathComponent))
                            continue
                        }
                        tmdl.append(TMDLFile(path: String(f.path.dropFirst(defDir.path.count + 1)), text: text))
                    }
                }
                tmdl.sort { $0.path < $1.path }
                let parsed = try TMDL.parseDetailed(files: tmdl)
                doc.model = parsed.model
                doc.queries = parsed.queries
                warnings += parsed.warnings
            } else if let bim = json(modelDir.appendingPathComponent("model.bim")) {
                let converted = TMSLConverter.convert(bim)
                doc.model = converted.model; doc.queries = converted.queries; warnings += converted.warnings
            } else {
                warnings.append(ImportWarning("No semantic model definition was found in “\(modelDir.lastPathComponent)”.", location: modelDir.lastPathComponent))
            }
            let cache = modelDir.appendingPathComponent(".pbi/facet-cache")
            for f in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" && inside(f) {
                if let d = BoundedFile.readIfPresent(f, limit: BoundedFile.dataLimit), let t = try? JSONDecoder().decode(DataTable.self, from: d) { doc.data[t.name] = t }
            }
        }
        // Report.
        if let reportDir {
            let def = reportDir.appendingPathComponent("definition")
            let resources = reportDir.appendingPathComponent("StaticResources/RegisteredResources")
            if let reportJSON = json(def.appendingPathComponent("report.json")) {
                try readPBIR(def: def, reportJSON: reportJSON, resources: resources, root: root, into: &doc, warnings: &warnings)
            } else if let legacy = json(reportDir.appendingPathComponent("report.json")) {
                let converted = LegacyReportLayout.convert(legacy) { name in resource(resources, name, root: root) }
                doc.report = converted.report
                warnings += converted.warnings
            } else {
                warnings.append(ImportWarning("No report definition was found in “\(reportDir.lastPathComponent)”.", location: reportDir.lastPathComponent))
            }
        }
        if doc.report.pages.isEmpty { doc.report.pages = [Page(name: "Page 1")] }
        return (doc, warnings)
    }

    /// A registered resource (theme, image) by the name the report gives it; names that would leave the folder are refused.
    /// With `root`, a resource reached through a link that leaves the project folder is refused too.
    static func resource(_ folder: URL, _ name: String, root: String? = nil) -> Data? {
        guard BoundedFile.isSafeResourceName(name) else { return nil }
        let url = folder.appendingPathComponent(name)
        if let root, !ProjectPaths.isInside(url, root: root) { return nil }
        return BoundedFile.readIfPresent(url)
    }

    private static func readPBIR(def: URL, reportJSON: JSONValue, resources: URL, root: String, into doc: inout FacetDocument, warnings: inout [ImportWarning]) throws {
        let fm = FileManager.default
        func json(_ u: URL) -> JSONValue? {
            ProjectPaths.isInside(u, root: root) ? BoundedFile.readIfPresent(u).flatMap { try? JSONValue.parse($0) } : nil
        }
        let head = PBIR.readReport(reportJSON, resource: { resource(resources, $0, root: root) }, warnings: &warnings)
        doc.report = head.report
        doc.dataSources = head.dataSources

        let pagesDir = def.appendingPathComponent("pages")
        let index = json(pagesDir.appendingPathComponent("pages.json"))
        var pageDirs = ((try? fm.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil)) ?? []).filter { fm.isDirectory($0) }
        let order = index?["pageOrder"]?.arrayValue?.compactMap(\.stringValue) ?? []
        pageDirs.sort { a, b in
            let ia = order.firstIndex(of: a.lastPathComponent) ?? Int.max, ib = order.firstIndex(of: b.lastPathComponent) ?? Int.max
            return ia != ib ? ia < ib : a.lastPathComponent < b.lastPathComponent
        }
        for dir in pageDirs {
            let location = "pages/\(dir.lastPathComponent)"
            guard let pj = json(dir.appendingPathComponent("page.json")) else {
                warnings.append(ImportWarning("page.json is missing or invalid; the page was skipped.", location: location))
                continue
            }
            var visuals: [VisualSpec] = []
            var groups: [UUID: String] = [:]
            let visualDirs = ((try? fm.contentsOfDirectory(at: dir.appendingPathComponent("visuals"), includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for vd in visualDirs {
                let vloc = "\(location)/visuals/\(vd.lastPathComponent)"
                guard let vj = json(vd.appendingPathComponent("visual.json")) else {
                    warnings.append(ImportWarning("visual.json is missing or invalid; the visual was skipped.", location: vloc))
                    continue
                }
                if let g = vj["visualGroup"] {
                    groups[stableUUID(from: vj["name"]?.stringValue ?? vd.lastPathComponent)] = g["displayName"]?.stringValue ?? "Group"
                } else if let v = PBIR.readVisual(vj, mobile: json(vd.appendingPathComponent("mobile.json")), warnings: &warnings, location: vloc) {
                    visuals.append(v)
                }
            }
            // Restore the saved visual order (file listing is alphabetical); otherwise order by z.
            let saved = PBIR.annotation(pj, PBIR.Annotation.page)
            if let savedOrder = saved?["visualOrder"]?.arrayValue?.compactMap({ $0.stringValue.flatMap(UUID.init(uuidString:)) }) {
                visuals.sort { (savedOrder.firstIndex(of: $0.id) ?? Int.max, $0.zIndex) < (savedOrder.firstIndex(of: $1.id) ?? Int.max, $1.zIndex) }
            } else {
                visuals.sort { ($0.zIndex, $0.frame.y, $0.frame.x) < ($1.zIndex, $1.frame.y, $1.frame.x) }
            }
            doc.report.pages.append(PBIR.readPage(pj, visuals: visuals, groups: groups, warnings: &warnings, location: location))
        }
        if let active = index?["activePageName"]?.stringValue.map(stableUUID) {
            // Facet writes the landing page (or the first page) as the active page; a different value is an external edit.
            let hasSaved = PBIR.annotation(reportJSON, PBIR.Annotation.report) != nil
            let expected = head.report.landingPageID ?? doc.report.pages.first?.id
            if !hasSaved || expected != active { doc.report.landingPageID = active }
        }

        // Bookmarks.
        let bmDir = def.appendingPathComponent("bookmarks")
        if let bmIndex = json(bmDir.appendingPathComponent("bookmarks.json")) {
            var seen = Set<String>()
            func load(_ name: String, group: String) {
                guard seen.insert(name).inserted else { return }
                guard let bj = json(bmDir.appendingPathComponent("\(name).bookmark.json")) else {
                    warnings.append(ImportWarning("Bookmark file “\(name).bookmark.json” is missing.", location: "bookmarks"))
                    return
                }
                doc.report.bookmarks.append(PBIR.readBookmark(bj, group: group, warnings: &warnings, location: "bookmarks/\(name)"))
            }
            for item in bmIndex["items"]?.arrayValue ?? [] {
                if let children = item["children"]?.arrayValue {
                    for c in children.compactMap(\.stringValue) { load(c, group: item["displayName"]?.stringValue ?? "") }
                } else if let n = item["name"]?.stringValue { load(n, group: "") }
            }
            if let order = head.bookmarkOrder, Set(order) == Set(doc.report.bookmarks.map(\.id)) {
                doc.report.bookmarks.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            }
        }
    }
}
