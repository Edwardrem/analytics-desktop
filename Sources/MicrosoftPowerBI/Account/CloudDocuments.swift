import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetInterop

/// Documents in OneDrive and SharePoint: opening one into a working copy, saving it back (conditional on the version
/// that was opened, so a newer version is never silently overwritten), saving a document to the cloud, sharing a link.
///
/// What goes where:
/// - `.facet` documents travel as one zipped file; the working copy is the unpacked package.
/// - Power BI projects (`.pbip`) and `.facet` packages synced as folders are mirrored file by file.
/// - `.pbix` and `.pbit` files open as new documents (a `.pbix` brings pages and queries only); they are not written back.
@MainActor
enum CloudDocuments {
    /// The cloud clients in use; replaced in tests.
    static var services: () -> CloudServices = { MicrosoftRuntime.shared.services }
    static let documentExtensions: Set<String> = [DocumentPackage.fileExtension, "pbix", "pbit", "pbip"]

    /// Whether a browser entry opens as a document (a file of a known type, or a `.facet` package stored as a folder).
    static func isDocument(_ item: DriveItem) -> Bool {
        let ext = (item.name as NSString).pathExtension.lowercased()
        return item.isFolder ? ext == DocumentPackage.fileExtension : documentExtensions.contains(ext)
    }

    /// Project files that go back to the cloud: not local settings, caches or Finder litter.
    nonisolated static func isSyncedFile(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/")
        return !parts.contains(".pbi") && parts.last != ".DS_Store" && !(parts.last?.hasSuffix(".facet-tmp") ?? false)
    }

    // MARK: Open

    static func open(_ item: DriveItem, into store: DocumentStore) {
        let services = services()
        store.status = StatusMessage(kind: .info, text: "Downloading “\(item.name)”…")
        Task { @MainActor in
            do {
                let (local, link, note) = try await download(item, sync: services.sync)
                if let link { DocumentFiles.pending[local.standardizedFileURL] = .cloud(link) }
                FileOperations.open(local, into: store)
                if let note { store.status = StatusMessage(kind: .info, text: note) }
            } catch {
                store.status = StatusMessage(kind: .error, text: "Couldn't open “\(item.name)” from the cloud. \(AccountMessages.describe(error))")
            }
        }
    }

    /// Makes the working copy of `item`; returns the local URL to open, how it goes back, and a note for the user.
    static func download(_ item: DriveItem, sync: CloudDocumentSync) async throws -> (URL, DocumentFiles.CloudLink?, String?) {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let work = try CloudDocumentSync.makeWorkingDirectory()
        let stem = CloudDocumentSync.safeFileName((item.name as NSString).deletingPathExtension)
        guard let drive = item.effectiveDriveID else {
            throw CloudAPIError(service: "Microsoft Graph", kind: .invalidResponse, statusCode: 0, message: "The service didn't say which drive holds “\(item.name)”.")
        }
        let parentPath = CloudDocumentSync.relativeFolderPath(fromGraphPath: item.parentReference?.path)
        switch (item.isFolder, ext) {
        case (true, DocumentPackage.fileExtension):
            let root = work.appendingPathComponent("\(stem).\(ext)")
            let mirror = try await sync.downloadFolder(driveID: drive, folderItemID: item.effectiveItemID,
                                                       folderPath: parentPath.map { ($0.isEmpty ? "" : $0 + "/") + item.name },
                                                       only: nil, into: root)
            return (root, .folder(mirror, localRoot: root, name: item.name, webURL: item.webUrl), nil)
        case (false, DocumentPackage.fileExtension):
            let (zip, reference) = try await sync.download(item, into: work.appendingPathComponent("download"))
            guard FacetArchive.isArchive(zip) else {
                throw InteropError.invalidFormat("“\(item.name)” isn't a zipped \(AppIdentity.name) document.")
            }
            let package = work.appendingPathComponent("\(stem).\(ext)")
            try FacetArchive.unpack(zip, to: package)
            try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
            return (package, .packedDocument(reference), nil)
        case (false, FileOperations.projectExtension):
            guard let parent = item.parentReference?.id, item.remoteItemID == nil else {
                throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0,
                                    message: "A shared project can't be opened from “Shared with me”; add its folder to your OneDrive first.")
            }
            let names: Set<String> = [item.name, "\(stem).Report", "\(stem).SemanticModel"]
            let root = work.appendingPathComponent("project")
            let mirror = try await sync.downloadFolder(driveID: drive, folderItemID: parent, folderPath: parentPath, only: names, into: root)
            return (root.appendingPathComponent(item.name), .folder(mirror, localRoot: root, name: item.name, webURL: item.webUrl), nil)
        case (false, "pbix"), (false, "pbit"):
            let (file, _) = try await sync.download(item, into: work)
            let what = ext == "pbit" ? "a new document from the template" : "a copy"
            return (file, nil, "Opened \(what) “\(item.name)”. It isn't written back to the cloud; use Save to OneDrive to keep it there as an \(AppIdentity.name) document.")
        default:
            throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0,
                                message: "\(AppIdentity.name) opens .facet, .pbip, .pbix and .pbit files from the cloud.")
        }
    }

    // MARK: Save back

    /// Sends the just-saved working copy back. A save made while one is still uploading follows it.
    static func push(_ store: DocumentStore) {
        let files = DocumentFiles.of(store)
        guard files.cloud != nil else { return }
        if files.cloudState == .uploading { files.pushAgain = true; return }
        files.cloudState = .uploading
        Task { @MainActor in
            await upload(store, files: files, overwrite: false)
            if files.pushAgain { files.pushAgain = false; push(store) }
        }
    }

    private static func upload(_ store: DocumentStore, files: DocumentFiles, overwrite: Bool) async {
        guard let link = files.cloud, let local = store.fileURL else { files.cloudState = .idle; return }
        let sync = services().sync
        do {
            switch link {
            case .packedDocument(let reference):
                let zip = try CloudDocumentSync.makeWorkingDirectory().appendingPathComponent(reference.name)
                defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
                try FacetArchive.pack(package: local, to: zip)
                files.cloud = .packedDocument(try await sync.saveBack(fileAt: zip, to: reference, overwrite: overwrite))
            case .folder(let mirror, let root, let name, let web):
                let updated = try await sync.uploadChanges(from: root, mirror: mirror, overwrite: overwrite, relevant: isSyncedFile)
                files.cloud = .folder(updated, localRoot: root, name: name, webURL: web)
            }
            files.cloudState = .uploaded(Date())
            store.status = StatusMessage(kind: .success, text: "Saved “\(files.cloudName ?? store.displayName)” to \(files.cloudPlace).")
        } catch let e as CloudSaveError {
            await resolve(e, store: store, files: files)
        } catch {
            let message = AccountMessages.describe(error)
            files.cloudState = .failed(message)
            store.status = StatusMessage(kind: .error, text: "Saved on this Mac, but not to \(files.cloudPlace). \(message)")
        }
    }

    /// Choices offered when the cloud has a newer version, or the file is gone.
    enum ConflictChoice: Equatable { case replace, saveCopy, cancel }

    static func choices(for error: CloudSaveError, packed: Bool) -> [ConflictChoice] {
        switch error {
        case .conflict: return packed ? [.saveCopy, .replace, .cancel] : [.replace, .cancel]
        case .missing: return packed ? [.saveCopy, .cancel] : [.cancel]
        case .nameTaken, .tooLarge: return [.cancel]
        }
    }

    private static func resolve(_ error: CloudSaveError, store: DocumentStore, files: DocumentFiles) async {
        var packedReference: CloudFileReference?
        if case .packedDocument(let r)? = files.cloud { packedReference = r }
        let options = choices(for: error, packed: packedReference != nil)
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.informativeText = "Your changes are saved on this Mac. Keep both versions by saving yours as a copy, or replace the version in \(files.cloudPlace) with yours."
        for o in options {
            switch o {
            case .saveCopy: alert.addButton(withTitle: "Save as a Copy")
            case .replace: alert.addButton(withTitle: "Replace Cloud Version")
            case .cancel: alert.addButton(withTitle: "Cancel")
            }
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = options.indices.contains(index) ? options[index] : .cancel
        switch choice {
        case .replace:
            await upload(store, files: files, overwrite: true)
        case .saveCopy:
            guard let reference = packedReference, let local = store.fileURL else {
                files.cloudState = .failed(error.localizedDescription)
                return
            }
            do {
                let zip = try CloudDocumentSync.makeWorkingDirectory().appendingPathComponent(reference.name)
                defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
                try FacetArchive.pack(package: local, to: zip)
                let stem = (reference.name as NSString).deletingPathExtension
                let copy = try await services().sync.saveCopy(fileAt: zip, named: "\(stem) (my changes).\(DocumentPackage.fileExtension)", nextTo: reference)
                files.cloud = .packedDocument(copy)
                files.cloudState = .uploaded(Date())
                store.status = StatusMessage(kind: .success, text: "Saved your version as “\(copy.name)” next to the original.")
            } catch {
                files.cloudState = .failed(AccountMessages.describe(error))
                store.status = StatusMessage(kind: .error, text: "Couldn't save a copy. \(AccountMessages.describe(error))")
            }
        case .cancel:
            files.cloudState = .failed(error.localizedDescription)
            store.status = StatusMessage(kind: .warning, text: "Saved on this Mac only. \(error.localizedDescription)")
        }
    }

    // MARK: Save to the cloud

    /// Saves the document as a new `.facet` file in a cloud folder, asking before replacing a file of the same name,
    /// and makes that file the document's home.
    static func saveNew(_ store: DocumentStore, in folder: DriveLocation, folderName: String, name: String) async -> Bool {
        let sync = services().sync
        var fileName = CloudDocumentSync.safeFileName(name)
        if (fileName as NSString).pathExtension.lowercased() != DocumentPackage.fileExtension { fileName += "." + DocumentPackage.fileExtension }
        do {
            let work = try CloudDocumentSync.makeWorkingDirectory()
            let package = work.appendingPathComponent(fileName)
            try DocumentPackage.write(store.doc, to: package)
            let zip = work.appendingPathComponent("upload").appendingPathComponent(fileName)
            try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
            try FacetArchive.pack(package: package, to: zip)
            let reference: CloudFileReference
            do {
                reference = try await sync.saveNew(fileAt: zip, in: folder, named: fileName, replace: false)
            } catch CloudSaveError.nameTaken {
                let alert = NSAlert()
                alert.messageText = "“\(fileName)” already exists in \(folderName)."
                alert.informativeText = "Replacing it overwrites the file in the cloud for everyone who uses it."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Replace")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
                reference = try await sync.saveNew(fileAt: zip, in: folder, named: fileName, replace: true)
            }
            let files = DocumentFiles.of(store)
            files.reset()
            store.markSaved(at: package)
            AutoRecovery.shared.discard(store)
            files.cloud = .packedDocument(reference)
            files.cloudState = .uploaded(Date())
            store.status = StatusMessage(kind: .success, text: "Saved “\(reference.name)” to \(folderName).")
            return true
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't save to the cloud. \(AccountMessages.describe(error))")
            return false
        }
    }

    // MARK: Sharing

    static func copySharingLink(_ store: DocumentStore) {
        let files = DocumentFiles.of(store)
        let location: DriveLocation
        switch files.cloud {
        case .packedDocument(let r)?: location = r.location
        case .folder(let m, _, _, _)?: location = .item(driveID: m.driveID, itemID: m.folderItemID)
        case nil:
            store.status = StatusMessage(kind: .info, text: "Save the document to OneDrive or SharePoint first, then share a link to it.")
            return
        }
        let personal = MicrosoftRuntime.shared.activeAccount?.isPersonal ?? false
        Task { @MainActor in
            do {
                let link = try await services().graph.createSharingLink(for: location, type: .view,
                                                                                              scope: personal ? .anonymous : .organization)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.webURL.absoluteString, forType: .string)
                store.status = StatusMessage(kind: .success, text: personal ? "Copied a view-only link anyone with it can open."
                                                                             : "Copied a view-only link for people in your organization.")
            } catch {
                store.status = StatusMessage(kind: .error, text: "Couldn't create a sharing link. \(AccountMessages.describe(error))")
            }
        }
    }
}
