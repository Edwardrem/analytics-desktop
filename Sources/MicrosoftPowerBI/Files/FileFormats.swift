import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FacetCore
import FacetInterop

/// Power BI file formats and the document's file lifecycle: PBIP projects (open, save, reload on external edits),
/// `.pbit` templates (export, import), `.pbix` reports (pages and queries only — the data model can't be decoded),
/// `.pbids` data source files (handed to the Power Query Editor), TMDL, themes, recent files and auto-recovery.
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

/// `.pbids` files: a new document whose queries open the named sources. Opening one shows the Power Query Editor so
/// the data can be chosen and loaded, as Power BI shows its navigator.
enum DataSourceFiles {
    static func document(from url: URL) throws -> FileOperations.ImportResult {
        let connections = try PBIDS.read(from: url)
        var doc = FacetDocument()
        doc.queries = queries(for: connections, existing: [])
        var notes = ["Added \(connections.count) data source\(connections.count == 1 ? "" : "s") from “\(url.lastPathComponent)”: " +
                     connections.map(\.summary).joined(separator: "; ") + ". Choose the data in the Power Query Editor, then Close & Apply."]
        if connections.contains(where: \.isDirectQuery) {
            notes.append("The file asks for DirectQuery; the queries are set up to import, which works for every source here.")
        }
        return FileOperations.ImportResult(document: doc, warnings: notes)
    }

    /// One query per connection, named so none clashes with `existing` or with each other.
    static func queries(for connections: [PBIDS.Connection], existing: Set<String>) -> [QueryDefinition] {
        var taken = Set(existing.map { $0.lowercased() })
        return connections.map { c in
            var name = c.queryName, n = 2
            while taken.contains(name.lowercased()) { name = "\(c.queryName) (\(n))"; n += 1 }
            taken.insert(name.lowercased())
            return QueryDefinition(name: name, mScript: c.mScript)
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
