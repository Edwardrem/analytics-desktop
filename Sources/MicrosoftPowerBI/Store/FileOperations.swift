import SwiftUI
import UniformTypeIdentifiers
import FacetCore

/// Opening and saving documents. Foreign formats (PBIP, PBIX, PBIT, TMDL…) plug in through `importers`/`exporters`.
@MainActor
enum FileOperations {
    struct ImportResult { var document: FacetDocument; var warnings: [String] = [] }
    /// File extension (lowercased) → importer. Registered by the interop bridge.
    static var importers: [String: (URL) throws -> ImportResult] = [:]
    /// Called to open a URL in a new window when the current one is in use. Set by the app scene.
    static var openInNewWindow: ((URL) -> Void)?

    static var openableExtensions: [String] { [DocumentPackage.fileExtension] + importers.keys.sorted() }

    static func open(into store: DocumentStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true     // .pbip projects are folders; .facet packages are treated as files
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = openableExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Open a Power BI document, project, template, or report."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, into: store)
    }

    static func open(_ url: URL, into store: DocumentStore) {
        // Keep unsaved work: open in a new window unless this one is an untouched blank document.
        let blank = store.fileURL == nil && !store.isDirty && store.model.tables.isEmpty
        if !blank, let openInNewWindow { openInNewWindow(url); return }
        do {
            let result = try read(url)
            let isNative = url.pathExtension.lowercased() == DocumentPackage.fileExtension
            store.replaceDocument(result.document, url: isNative ? url : nil)
            if isNative { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
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
        if let importer = importers["pbip"], (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return try importer(url)
        }
        throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Power BI can't read “.\(ext)” files."])
    }

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
        return write(store, to: url)
    }

    private static func write(_ store: DocumentStore, to url: URL) -> Bool {
        do {
            try DocumentPackage.write(store.doc, to: url)
            store.markSaved(at: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't save. \(error.localizedDescription)")
            return false
        }
    }

    static func revert(_ store: DocumentStore) {
        guard let url = store.fileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Revert to the last saved version?"
        alert.informativeText = "Changes made since you last saved will be lost."
        alert.addButton(withTitle: "Revert"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { store.replaceDocument(try DocumentPackage.read(from: url), url: url) }
        catch { store.status = StatusMessage(kind: .error, text: "Couldn't revert. \(error.localizedDescription)") }
    }

    /// Ask to save unsaved changes. Returns false if the user cancelled.
    static func confirmClose(_ store: DocumentStore) -> Bool {
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(store.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save…"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(store)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
