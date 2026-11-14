import Foundation

/// A file in OneDrive or SharePoint that a local working copy was made from. Saved with the document's window
/// state (not in the document), so a later save goes back to the same item and is checked against its eTag.
public struct CloudFileReference: Codable, Equatable, Sendable {
    public var driveID: String
    public var itemID: String
    public var name: String
    /// The version the working copy was made from or last saved as. Saves send it as `If-Match`.
    public var eTag: String?
    public var webURL: String?
    /// The folder holding the item, for "save a copy" next to it.
    public var parentItemID: String?
    /// Graph's display path of the folder, e.g. `/drive/root:/Reports`.
    public var parentPath: String?

    public init(driveID: String, itemID: String, name: String, eTag: String?, webURL: String? = nil,
                parentItemID: String? = nil, parentPath: String? = nil) {
        self.driveID = driveID; self.itemID = itemID; self.name = name; self.eTag = eTag
        self.webURL = webURL; self.parentItemID = parentItemID; self.parentPath = parentPath
    }

    /// The reference for a Graph item, or nil when Graph did not say which drive holds it.
    public init?(item: DriveItem) {
        guard let drive = item.effectiveDriveID, !drive.isEmpty else { return nil }
        self.init(driveID: drive, itemID: item.effectiveItemID, name: item.name, eTag: item.eTag, webURL: item.webUrl,
                  parentItemID: item.remoteItemID == nil ? item.parentReference?.id : nil,
                  parentPath: item.remoteItemID == nil ? item.parentReference?.path : nil)
    }

    public var location: DriveLocation { .item(driveID: driveID, itemID: itemID) }
    public var parentLocation: DriveLocation? { parentItemID.map { .item(driveID: driveID, itemID: $0) } }
    /// The folder as people read it: "OneDrive ▸ Reports", or the drive root.
    public var folderDisplayName: String {
        guard let p = parentPath, let r = p.range(of: "root:") else { return "OneDrive" }
        let rest = p[r.upperBound...].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        return rest.isEmpty ? "OneDrive" : rest.joined(separator: " ▸ ")
    }
}

/// Why a save to OneDrive or SharePoint did not happen.
public enum CloudSaveError: LocalizedError, Equatable {
    /// The file changed in the cloud since the working copy was made. `modifiedBy`/`modified` describe the newer version.
    case conflict(name: String, modifiedBy: String?, modified: Date?, currentETag: String?)
    /// The file was deleted or moved in the cloud.
    case missing(name: String)
    /// A file with that name already exists in the folder.
    case nameTaken(name: String)
    case tooLarge(name: String, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .conflict(let name, let who, let when, _):
            var s = "“\(name)” was changed in the cloud"
            if let who, !who.isEmpty { s += " by \(who)" }
            if let when { s += " on \(when.formatted(date: .abbreviated, time: .shortened))" }
            return s + " after you opened it, so it was not overwritten."
        case .missing(let name):
            return "“\(name)” is no longer in the cloud (it was deleted, moved, or you lost access to it)."
        case .nameTaken(let name):
            return "A file named “\(name)” already exists in that folder."
        case .tooLarge(let name, let limit):
            return "“\(name)” is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) and was not opened."
        }
    }
}

/// Opens documents from OneDrive / SharePoint into local working copies and saves them back, never silently
/// overwriting a newer version: every save back is conditional on the eTag the working copy was made from.
public final class CloudDocumentSync {
    public let graph: GraphClient
    /// Largest document opened from the cloud.
    public static let maxDocumentBytes: Int64 = 2 * 1024 * 1024 * 1024

    public init(graph: GraphClient) { self.graph = graph }

    /// Downloads `item` into `directory` (a new private folder when nil) and returns the local file and its reference.
    /// - Throws: `CloudSaveError.tooLarge` for files above `maxBytes`; `CloudAPIError` from Graph.
    public func download(_ item: DriveItem, into directory: URL? = nil, maxBytes: Int64 = CloudDocumentSync.maxDocumentBytes,
                         progress: TransferProgressHandler? = nil) async throws -> (file: URL, reference: CloudFileReference) {
        guard !item.isFolder, let reference = CloudFileReference(item: item) else {
            throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0, message: "“\(item.name)” is not a file that can be opened.")
        }
        if let size = item.size, size > maxBytes { throw CloudSaveError.tooLarge(name: item.name, limit: maxBytes) }
        let name = Self.safeFileName(item.name)
        let folder = try directory ?? Self.makeWorkingDirectory()
        let destination = folder.appendingPathComponent(name)
        do {
            let file = try await graph.download(reference.location, suggestedName: name, destination: destination,
                                                maxBytes: maxBytes, progress: progress)
            return (file, reference)
        } catch let e as CloudAPIError where e.kind == .invalidResponse && e.message.contains("larger than") {
            throw CloudSaveError.tooLarge(name: item.name, limit: maxBytes)
        }
    }

    /// Replaces the cloud file with the local file. Unless `overwrite` is true, the write only succeeds while the
    /// cloud file still has `reference.eTag`; otherwise `CloudSaveError.conflict` describes the newer version.
    /// - Returns: the reference updated with the new eTag.
    public func saveBack(fileAt fileURL: URL, to reference: CloudFileReference, overwrite: Bool = false,
                         progress: TransferProgressHandler? = nil) async throws -> CloudFileReference {
        do {
            let item = try await graph.replaceContent(of: reference.location, withFileAt: fileURL,
                                                      ifMatchETag: overwrite ? nil : reference.eTag, progress: progress)
            return Self.updated(reference, with: item)
        } catch let e as CloudAPIError where e.kind == .preconditionFailed {
            let current = try? await graph.item(at: reference.location)
            throw CloudSaveError.conflict(name: reference.name, modifiedBy: current?.lastModifiedBy,
                                          modified: current?.modified, currentETag: current?.eTag)
        } catch let e as CloudAPIError where e.kind == .notFound {
            throw CloudSaveError.missing(name: reference.name)
        }
    }

    /// Uploads the local file next to the original under a new name; Graph adds a number when the name is taken.
    public func saveCopy(fileAt fileURL: URL, named name: String, nextTo reference: CloudFileReference,
                         progress: TransferProgressHandler? = nil) async throws -> CloudFileReference {
        let folder = reference.parentLocation ?? .driveRoot(driveID: reference.driveID)
        let item = try await graph.upload(fileAt: fileURL, to: folder, named: Self.safeFileName(name), conflict: .rename, progress: progress)
        return try Self.reference(for: item, fallbackDrive: reference.driveID)
    }

    /// Saves a new file into a folder. With `replace` false an existing file of that name is left alone and
    /// `CloudSaveError.nameTaken` is thrown so the caller can ask.
    public func saveNew(fileAt fileURL: URL, in folder: DriveLocation, named name: String, replace: Bool,
                        progress: TransferProgressHandler? = nil) async throws -> CloudFileReference {
        let safe = Self.safeFileName(name)
        do {
            let item = try await graph.upload(fileAt: fileURL, to: folder, named: safe, conflict: replace ? .replace : .fail, progress: progress)
            return try Self.reference(for: item, fallbackDrive: nil)
        } catch let e as CloudAPIError where e.kind == .conflict || e.code == "nameAlreadyExists" {
            throw CloudSaveError.nameTaken(name: safe)
        }
    }

    // MARK: Helpers

    static func updated(_ reference: CloudFileReference, with item: DriveItem) -> CloudFileReference {
        var r = reference
        r.eTag = item.eTag ?? r.eTag
        r.webURL = item.webUrl ?? r.webURL
        if !item.name.isEmpty { r.name = item.name }
        return r
    }

    static func reference(for item: DriveItem, fallbackDrive: String?) throws -> CloudFileReference {
        if let r = CloudFileReference(item: item) { return r }
        guard let drive = fallbackDrive else {
            throw CloudAPIError(service: "Microsoft Graph", kind: .invalidResponse, statusCode: 0, message: "The service did not say where the file was saved.")
        }
        return CloudFileReference(driveID: drive, itemID: item.id, name: item.name, eTag: item.eTag, webURL: item.webUrl,
                                  parentItemID: item.parentReference?.id, parentPath: item.parentReference?.path)
    }

    /// A name that is safe as one local path component: no separators, no `..`, no control characters.
    public static func safeFileName(_ name: String) -> String {
        var s = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) { return "_" }
            return Character(scalar)
        })
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "download" }
        // At most 200 characters, and well inside the 255-byte limit on a file name.
        var out = String(s.prefix(200))
        while out.utf8.count > 240 { out.removeLast() }
        return out
    }

    /// Where working copies of cloud documents are made.
    public static var workingRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AnalyticsDesktop/Cloud", isDirectory: true)
    }

    /// Whether `url` is inside a working copy made by `makeWorkingDirectory`.
    public static func isWorkingCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(workingRoot.standardizedFileURL.path + "/")
    }

    /// A new private folder for working copies, under the user's caches.
    public static func makeWorkingDirectory() throws -> URL {
        let dir = workingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}
