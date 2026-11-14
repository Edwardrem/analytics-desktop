import SwiftUI
import UniformTypeIdentifiers
import FacetCore
import FacetInterop
import FacetCloud

/// Opening and saving documents. Foreign formats (PBIP, PBIX, PBIT, PBIDS, TMDL…) plug in through `importers`.
///
/// A document saves to where it came from: a `.facet` package, or the `.pbip` of a Power BI project (written back as
/// TMDL + PBIR). A document opened from OneDrive or SharePoint is saved to its working copy and then sent back.
@MainActor
enum FileOperations {
    struct ImportResult { var document: FacetDocument; var warnings: [String] = [] }
    /// File extension (lowercased) → importer. Registered by the file formats feature.
    static var importers: [String: (URL) throws -> ImportResult] = [:]
    /// Called to open a URL in a new window when the current one is in use. Set by the app scene.
    static var openInNewWindow: ((URL) -> Void)?

    static let projectExtension = "pbip"

    static var openableExtensions: [String] { [DocumentPackage.fileExtension] + importers.keys.sorted() }

    static func open(into store: DocumentStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true     // .pbip projects are folders; .facet packages are treated as files
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = openableExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Open an \(AppIdentity.name) document, or a Power BI project, template, report or data source file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, into: store)
    }

    static func open(_ url: URL, into store: DocumentStore) {
        // Keep unsaved work: open in a new window unless this one is an untouched blank document.
        let blank = store.fileURL == nil && !store.isDirty && store.model.tables.isEmpty
        if !blank, let openInNewWindow { openInNewWindow(url); return }
        do {
            let result = try read(url)
            store.replaceDocument(result.document, url: documentURL(for: url))
            DocumentFiles.of(store).reset()
            adopt(url, store: store)
            RecentFiles.shared.note(url)
            if !result.warnings.isEmpty {
                store.status = StatusMessage(kind: .warning, text: "Opened with notes:\n" + result.warnings.prefix(8).joined(separator: "\n"))
            }
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't open “\(url.lastPathComponent)”. \(error.localizedDescription)")
        }
    }

    static func read(_ url: URL) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        if ext == DocumentPackage.fileExtension { return ImportResult(document: try DocumentPackage.read(from: url)) }
        if let importer = importers[ext] { return try importer(url) }
        // A plain folder may be a PBIP project.
        if let importer = importers[projectExtension], isDirectory(url) { return try importer(url) }
        throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "\(AppIdentity.name) can't read “.\(ext)” files."])
    }

    /// Where a document read from `url` saves back to: the `.facet` package or the project's `.pbip`. Nil for imports
    /// (.pbix, .pbit, .tmdl), which become new documents.
    static func documentURL(for url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        if ext == DocumentPackage.fileExtension || ext == projectExtension { return url }
        guard isDirectory(url) else { return nil }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        // Keep the folder's own spelling of the path (the listing may resolve /var to /private/var).
        return items.filter { $0.pathExtension.lowercased() == projectExtension }.map(\.lastPathComponent).sorted().first
            .map { url.appendingPathComponent($0) }
    }

    /// Finishes setting up a store whose document was read from `url`: the project to watch, the file it was imported
    /// from, and whatever the opener left for that URL (a cloud working copy, a recovery copy). Also called for the
    /// windows the app opens for a URL.
    static func adopt(_ url: URL?, store: DocumentStore) {
        guard let url else { return }
        let files = DocumentFiles.of(store)
        if store.fileURL == nil, let saved = documentURL(for: url) { store.fileURL = saved }
        let ext = url.pathExtension.lowercased()
        if ["pbix", "pbit"].contains(ext) { files.importedFrom = url }
        // A data source file starts in the Power Query Editor, where its data is chosen and loaded.
        if ext == "pbids" { DispatchQueue.main.async { NotificationCenter.default.post(name: .facetOpenQueryEditor, object: store) } }
        switch DocumentFiles.pending.removeValue(forKey: url.standardizedFileURL) {
        case .cloud(let link)?: files.cloud = link
        case .importedFrom(let original)?: files.importedFrom = original
        case .recovered(let original, let id)?:
            store.fileURL = original
            AutoRecovery.shared.adopt(store, recoveryID: id)
            // Recovered work has not been saved anywhere yet.
            store.mutate("Recover Document", invalidates: .layout) { _ in }
        case nil:
            // A window restored at launch for a copy whose origin this session doesn't know.
            if AutoRecovery.shared.contains(url) {
                store.fileURL = nil
                AutoRecovery.shared.adopt(store, recoveryID: url.deletingPathExtension().lastPathComponent)
                store.mutate("Recover Document", invalidates: .layout) { _ in }
            } else if CloudDocumentSync.isWorkingCopy(url) {
                store.fileURL = nil
                store.status = StatusMessage(kind: .warning, text: "This window showed a copy of a cloud document. Open it again from OneDrive or SharePoint to keep saving it there, or save it on this Mac.")
            }
        }
        // A project on this Mac is watched; a cloud working copy is replaced only by its own saves.
        if files.cloud == nil, let pbip = store.fileURL, pbip.pathExtension.lowercased() == projectExtension { files.watchProject(pbip) }
    }

    // MARK: Saving

    @discardableResult
    static func save(_ store: DocumentStore) -> Bool {
        guard let url = store.fileURL else { return saveAs(store) }
        return write(store, to: url)
    }

    @discardableResult
    static func saveAs(_ store: DocumentStore) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: DocumentPackage.fileExtension) ?? .package]
        panel.nameFieldStringValue = store.displayName + "." + DocumentPackage.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        DocumentFiles.of(store).reset()
        return write(store, to: url)
    }

    /// Save as a Power BI project: `<Name>.pbip` beside `<Name>.Report` (PBIR) and `<Name>.SemanticModel` (TMDL).
    @discardableResult
    static func saveAsProject(_ store: DocumentStore) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: projectExtension) ?? .json]
        panel.nameFieldStringValue = store.displayName + "." + projectExtension
        panel.canCreateDirectories = true
        panel.message = "The project is saved as text files next to the .pbip: a folder for the report and one for the semantic model."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        DocumentFiles.of(store).reset()
        return write(store, to: url)
    }

    static func write(_ store: DocumentStore, to url: URL) -> Bool {
        do {
            var notes: [ImportWarning] = []
            // DirectQuery tables are read from their sources, not saved.
            let doc = store.doc.withoutDirectQueryRows
            if url.pathExtension.lowercased() == projectExtension {
                notes = try writeProject(doc, to: url)
            } else {
                try DocumentPackage.write(doc, to: url)
            }
            store.markSaved(at: url)
            let files = DocumentFiles.of(store)
            if url.pathExtension.lowercased() == projectExtension, files.cloud == nil {
                if files.watchedProject != url { files.watchProject(url) } else { files.projectSaved() }
            }
            RecentFiles.shared.note(url)
            AutoRecovery.shared.discard(store)
            if files.cloud != nil { CloudDocuments.push(store) }
            let warnings = notes.filter { $0.severity != .info }
            if !warnings.isEmpty {
                store.status = StatusMessage(kind: .warning, text: "Saved with notes:\n" + warnings.prefix(6).map(\.description).joined(separator: "\n"))
            }
            return true
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't save. \(error.localizedDescription)")
            return false
        }
    }

    /// Writes `document` as the project whose `.pbip` is `pbip`. Unchanged files are left alone so the folder diffs cleanly.
    static func writeProject(_ document: FacetDocument, to pbip: URL) throws -> [ImportWarning] {
        let options = PBIPProject.WriteOptions(includeFacetDataCache: AppSettings.bool(.pbipDataCache), includeFacetAnnotations: true)
        return try PBIPProject.write(document: document, to: pbip.deletingLastPathComponent(),
                                     name: pbip.deletingPathExtension().lastPathComponent, options: options)
    }

    static func revert(_ store: DocumentStore) {
        guard let url = store.fileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Revert to the last saved version?"
        alert.informativeText = "Changes made since you last saved will be lost."
        alert.addButton(withTitle: "Revert"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            store.replaceDocument(try read(url).document, url: url)
            AutoRecovery.shared.discard(store)
        } catch { store.status = StatusMessage(kind: .error, text: "Couldn't revert. \(error.localizedDescription)") }
    }

    /// Ask to save unsaved changes. Returns false if the user cancelled.
    static func confirmClose(_ store: DocumentStore) -> Bool {
        guard store.isDirty else { AutoRecovery.shared.discard(store); return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(store.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save…"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(store)
        case .alertThirdButtonReturn: AutoRecovery.shared.discard(store); return true
        default: return false
        }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
