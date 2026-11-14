import SwiftUI
import AppKit
import FacetCore
import FacetInterop
import FacetCloud

/// Where a document lives besides its window: a Power BI project folder watched for edits made elsewhere, a working
/// copy of a OneDrive / SharePoint file it saves back to, the foreign file it was imported from.
@MainActor
final class DocumentFiles: ObservableObject {
    /// How a cloud document goes back.
    enum CloudLink: Equatable {
        /// A `.facet` document kept in the cloud as one zipped file; `store.fileURL` is its unpacked working copy.
        case packedDocument(CloudFileReference)
        /// A folder tree mirrored file by file: a Power BI project, or a `.facet` package synced as a folder.
        case folder(CloudFolderMirror, localRoot: URL, name: String, webURL: String?)
    }
    enum CloudState: Equatable { case idle, uploading, uploaded(Date), failed(String) }

    @Published var cloud: CloudLink?
    @Published var cloudState: CloudState = .idle
    /// A save happened while the previous one was still uploading.
    var pushAgain = false
    /// The `.pbix` / `.pbit` this document was imported from, so it can be published as-is.
    @Published var importedFrom: URL?
    /// The `.pbip` whose folders are watched for external edits.
    @Published private(set) var watchedProject: URL?

    private weak var store: DocumentStore?
    private var watchers: [PBIPWatcher] = []
    private var asking = false

    private static var all: [ObjectIdentifier: DocumentFiles] = [:]

    static func of(_ store: DocumentStore) -> DocumentFiles {
        let key = ObjectIdentifier(store)
        if let existing = all[key], existing.store === store { return existing }
        all = all.filter { $0.value.store != nil }
        let files = DocumentFiles(store: store)
        all[key] = files
        return files
    }

    private init(store: DocumentStore) { self.store = store }

    /// Forgets everything: the document was replaced or saved somewhere else.
    func reset() {
        stopWatching()
        cloud = nil
        cloudState = .idle
        importedFrom = nil
    }

    // MARK: Cloud

    var cloudPlace: String {
        switch cloud {
        case .packedDocument(let ref): return ref.parentPath?.contains("/drives/") == true ? "SharePoint" : "OneDrive"
        case .folder: return "OneDrive"
        case nil: return "the cloud"
        }
    }
    var cloudWebURL: URL? {
        switch cloud {
        case .packedDocument(let ref): return ServiceLinks.openable(ref.webURL.flatMap(URL.init(string:)))
        case .folder(_, _, _, let web): return ServiceLinks.openable(web.flatMap(URL.init(string:)))
        case nil: return nil
        }
    }
    var cloudName: String? {
        switch cloud {
        case .packedDocument(let ref): return ref.name
        case .folder(_, _, let name, _): return name
        case nil: return nil
        }
    }

    // MARK: Project folders

    /// Starts watching the `.Report` and `.SemanticModel` folders of the project at `pbip` (not the folder holding it,
    /// which may be large and unrelated), so edits from VS Code, Git or an agent reload the document.
    func watchProject(_ pbip: URL) {
        stopWatching()
        let folder = pbip.deletingLastPathComponent()
        let name = pbip.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        for suffix in ["Report", "SemanticModel"] {
            let dir = folder.appendingPathComponent("\(name).\(suffix)")
            guard fm.fileExists(atPath: dir.path) else { continue }
            if let w = try? PBIPProject.watch(folder: dir, debounce: 0.4, onChange: { [weak self] urls in
                MainActor.assumeIsolated { self?.externalChange(urls) }
            }) {
                watchers.append(w)
            }
        }
        watchedProject = pbip
    }

    /// The app wrote the project itself; its own save is not an external edit.
    func projectSaved() { for w in watchers { w.markSynced() } }

    func stopWatching() {
        for w in watchers { w.stop() }
        watchers.removeAll()
        watchedProject = nil
    }

    /// What to do about files that changed on disk.
    enum ReloadDecision: Equatable { case reload, ask, ignore }
    static func decision(isDirty: Bool, changed: [URL], alreadyAsking: Bool) -> ReloadDecision {
        guard !changed.isEmpty, !alreadyAsking else { return .ignore }
        return isDirty ? .ask : .reload
    }

    private func externalChange(_ urls: [URL]) {
        guard let store, let pbip = watchedProject else { return }
        switch Self.decision(isDirty: store.isDirty, changed: urls, alreadyAsking: asking) {
        case .ignore: return
        case .reload: reload(store, from: pbip, changed: urls.count)
        case .ask:
            asking = true
            defer { asking = false }
            let alert = NSAlert()
            alert.messageText = "“\(pbip.deletingPathExtension().lastPathComponent)” changed on disk."
            alert.informativeText = "\(urls.count) project file\(urls.count == 1 ? " was" : "s were") changed by another app. Reload the project and lose your unsaved changes, or keep editing your version (saving it will overwrite those changes)."
            alert.addButton(withTitle: "Keep My Changes")
            alert.addButton(withTitle: "Reload from Disk")
            if alert.runModal() == .alertSecondButtonReturn { reload(store, from: pbip, changed: urls.count) }
        }
    }

    private func reload(_ store: DocumentStore, from pbip: URL, changed: Int) {
        do {
            let (doc, warnings) = try PBIPProject.read(from: pbip)
            let page = store.currentPageID
            let kept = (cloud, importedFrom)
            store.replaceDocument(doc, url: pbip)
            (cloud, importedFrom) = kept
            if doc.report.pages.contains(where: { $0.id == page }) { store.currentPageID = page }
            let note = warnings.isEmpty ? "" : " (\(warnings.count) note\(warnings.count == 1 ? "" : "s"))"
            store.status = StatusMessage(kind: .info, text: "Reloaded “\(store.displayName)” after \(changed) file\(changed == 1 ? "" : "s") changed on disk\(note).")
        } catch {
            store.status = StatusMessage(kind: .error, text: "The project changed on disk but couldn't be reloaded: \(error.localizedDescription)")
        }
    }

    // MARK: Windows opened for a URL

    /// What a window opened for a URL should remember about it (a cloud working copy, a recovered document…).
    enum PendingOrigin {
        case cloud(CloudLink)
        case importedFrom(URL)
        /// A recovery copy: show it as unsaved, belonging to `original` when known; `id` names its recovery files.
        case recovered(original: URL?, id: String)
    }
    static var pending: [URL: PendingOrigin] = [:]
}
