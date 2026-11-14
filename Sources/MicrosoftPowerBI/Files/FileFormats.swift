import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FacetCore
import FacetInterop
import FacetQuery

/// Power BI file formats and the document's file lifecycle: PBIP projects (open, save, reload on external edits),
/// `.pbit` templates (export, import), `.pbix` reports (pages and queries only — the data model can't be decoded),
/// `.pbids` data source files (opened in Get Data's navigator), TMDL, themes, recent files and auto-recovery.
@MainActor
enum FileFormatsFeature {
    static func register() {
        registerImporters()
        ThemeIO.importer = { try ThemeFiles.read($0) }
        ThemeIO.exporter = { try ThemeFiles.write($0, to: $1) }
        AppCommands.register { commands }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AutoRecovery.shared.start()
                // After the first window exists, so restored documents can open beside it.
                DispatchQueue.main.async { AutoRecovery.shared.offerRestore() }
            }
        }
    }

    static func registerImporters() {
        FileOperations.importers[FileOperations.projectExtension] = { url in
            let (doc, warnings) = try PBIPProject.read(from: url)
            return FileOperations.ImportResult(document: doc, warnings: warnings.map(\.description))
        }
        FileOperations.importers["tmdl"] = { url in try TMDLFiles.read(url) }
        for ext in ["pbix", "pbit"] {
            FileOperations.importers[ext] = { url in
                let (doc, warnings) = try PBIXPackage.read(from: url)
                return FileOperations.ImportResult(document: doc, warnings: warnings.map(\.description))
            }
        }
        FileOperations.importers["pbids"] = { url in try DataSourceFiles.document(from: url) }
    }

    static var commands: [AppCommand] {
        let isProject: @MainActor (DocumentStore) -> Bool = { $0.fileURL?.pathExtension.lowercased() == FileOperations.projectExtension }
        return [
            AppCommand(id: "file.openRecent", title: "Open Recent…", menu: .file, symbol: "clock",
                       shortcut: .init("o", modifiers: [.command, .shift])) { store in store.present { RecentFilesSheet() } },
            AppCommand(id: "file.saveAsProject", title: "Save as Power BI Project…", menu: .file, symbol: "folder.badge.gearshape",
                       separatorBefore: true) { FileOperations.saveAsProject($0) },
            AppCommand(id: "file.exportTemplate", title: "Export Power BI Template…", menu: .file, symbol: "doc.badge.plus") { exportTemplate($0) },
            AppCommand(id: "file.openInVSCode", title: "Open Project in Visual Studio Code", menu: .file, symbol: "chevron.left.forwardslash.chevron.right",
                       isEnabled: isProject) { store in
                guard let pbip = store.fileURL else { return }
                do { try PBIPProject.openInVSCode(folder: pbip.deletingLastPathComponent()) }
                catch { store.status = StatusMessage(kind: .error, text: error.localizedDescription) }
            },
        ]
    }

    /// File ▸ Export ▸ Power BI template: the model definition, queries, report and sensitivity label, no data.
    static func exportTemplate(_ store: DocumentStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pbit") ?? .data]
        panel.nameFieldStringValue = store.displayName + ".pbit"
        panel.message = "A template holds the model, queries and report without data. Opening it starts a new document."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PBIXPackage.writeTemplate(store.doc, to: url)
            RecentFiles.shared.note(url)
            store.status = StatusMessage(kind: .success, text: "Exported the template “\(url.lastPathComponent)”.")
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't export the template. \(error.localizedDescription)")
        }
    }
}

/// TMDL files or folders opened as a new document.
enum TMDLFiles {
    static func read(_ url: URL) throws -> FileOperations.ImportResult {
        var files: [TMDLFile] = []
        if FileOperations.isDirectory(url) {
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let f as URL in walker where f.pathExtension.lowercased() == "tmdl" {
                    guard files.count < BoundedFile.maxProjectFiles else { throw InteropError.invalidFormat("The folder holds too many TMDL files.") }
                    let data = try BoundedFile.read(f)
                    files.append(TMDLFile(path: String(f.path.dropFirst(url.path.count + 1)), text: String(decoding: data, as: UTF8.self)))
                }
            }
        } else {
            files.append(TMDLFile(path: url.lastPathComponent, text: String(decoding: try BoundedFile.read(url), as: UTF8.self)))
        }
        guard !files.isEmpty else { throw InteropError.missingFile("No TMDL definitions were found.") }
        let (model, queries) = try TMDL.parse(files: files.sorted { $0.path < $1.path })
        var doc = FacetDocument()
        doc.model = model
        doc.queries = queries
        return FileOperations.ImportResult(document: doc)
    }
}

/// `.pbids` files, opened as Power BI Desktop opens them: a new, empty document with Get Data's navigator for the
/// file's connection (preview, pick objects, Load or Transform Data), with the usual header and type detection.
enum DataSourceFiles {
    /// Reads the file (so a broken one is refused before a window opens) and starts an empty document; `adopt` then
    /// opens Get Data for it.
    static func document(from url: URL) throws -> FileOperations.ImportResult {
        _ = try PBIDS.read(from: url)
        return FileOperations.ImportResult(document: FacetDocument())
    }

    /// What opening a data source file does.
    enum Plan: Equatable {
        /// Get Data for `connector` at `location`, straight to the navigator; `notes` say what of the file was set aside.
        case navigator(connector: DataConnector, location: String, notes: [String])
        /// The connection names a source this app can't connect to.
        case unavailable(String)
    }

    /// The Get Data connector a connection opens with (it may be one this app lists as unavailable), or nil when
    /// the catalog has none for it.
    static func connectorID(for c: PBIDS.Connection) -> String? {
        switch c.protocolName {
        case "file":
            switch (c.location as NSString).pathExtension.lowercased() {
            case "csv", "txt", "tsv": return "csv"
            case "xlsx", "xlsm": return "excel"
            case "xls", "xlsb": return "excel-legacy"
            case "json": return "json"
            case "xml": return "xml"
            case "parquet": return "parquet"
            case "pdf": return "pdf"
            default: return nil
            }
        case "folder": return "folder"
        case "http": return "web"
        case "odata": return "odata"
        case "tds": return "sqlserver"
        case "postgresql": return "postgresql"
        case "mysql": return "mysql"
        case "oracle": return "oracle"
        case "analysis-services": return "ssas"
        case "odbc": return "odbc"
        case "sharepoint-list": return "sharepoint-list"
        default: return nil
        }
    }

    /// Power BI Desktop reads one connection per data source file; a file with more opens its first and names the rest.
    static func plan(for connections: [PBIDS.Connection], file: String) -> Plan {
        guard let first = connections.first else { return .unavailable("“\(file)” lists no connections.") }
        guard let connector = connectorID(for: first).flatMap(DataConnector.connector) else {
            return .unavailable("“\(file)” opens \(first.summary), which \(AppIdentity.name) can't read. Use Get Data to connect to the data another way.")
        }
        guard connector.isAvailable else {
            return .unavailable("“\(file)” opens \(first.summary) with the \(connector.name) connector, which isn't available in \(AppIdentity.name): "
                                + (connector.unavailableReason ?? "it isn't supported."))
        }
        var notes: [String] = []
        if connections.count > 1 {
            notes.append("“\(file)” lists \(connections.count) connections; a data source file opens one, so only \(first.summary) was opened. "
                         + "Use Get Data for " + connections.dropFirst().map(\.summary).joined(separator: "; ") + ".")
        }
        var location = first.location
        if connector.kind == .sqlServer, let source = MScript.steps(of: first.mScript).first, let r = SourcePlanner.request(fromSource: source.expression) {
            location = SQLServerConnection.location(server: r.location, database: r.database)   // the form splits it again
        }
        if first.isDirectQuery {
            notes.append(connector.kind == .sqlServer
                         ? "“\(file)” asks for DirectQuery: choose DirectQuery under Data connectivity mode before you connect."
                         : "“\(file)” asks for DirectQuery, which a \(connector.name) source doesn't support; its data is imported.")
        }
        return .navigator(connector: connector, location: location, notes: notes)
    }

    /// Opens Get Data in `store`'s window for the data source file at `url`.
    @MainActor
    static func startGetData(from url: URL, in store: DocumentStore) {
        let plan: Plan
        do { plan = Self.plan(for: try PBIDS.read(from: url), file: url.lastPathComponent) }
        catch { store.status = StatusMessage(kind: .error, text: "Couldn't open “\(url.lastPathComponent)”. \(error.localizedDescription)"); return }
        switch plan {
        case .navigator(let connector, let location, let notes):
            store.present { GetDataDialog(store: store, connector: connector, location: location, connectNow: true) }
            if !notes.isEmpty { store.status = StatusMessage(kind: .warning, text: notes.joined(separator: "\n")) }
        case .unavailable(let message):
            store.status = StatusMessage(kind: .error, text: message)
        }
    }
}

/// Theme files: Power BI's JSON theme format (with Analytics Desktop's own settings in an extension block, so a theme
/// round-trips), and the older native JSON form for import.
enum ThemeFiles {
    nonisolated static func read(_ url: URL) throws -> ThemeSpec {
        let data = try BoundedFile.read(url, limit: 16 * 1024 * 1024)
        do {
            var (theme, _) = try PowerBITheme.importTheme(from: data)
            if theme.name.trimmingCharacters(in: .whitespaces).isEmpty { theme.name = url.deletingPathExtension().lastPathComponent }
            return theme
        } catch {
            return try ThemeIO.nativeImport(url)
        }
    }

    nonisolated static func write(_ theme: ThemeSpec, to url: URL) throws {
        try PowerBITheme.export(theme, includeFacetExtensions: true).write(to: url, options: .atomic)
    }
}
