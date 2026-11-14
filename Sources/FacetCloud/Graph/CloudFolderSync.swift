import Foundation
import CryptoKit

/// One file of a folder tree mirrored from the cloud: its item, the version that was downloaded or last saved,
/// and a digest of those bytes so local edits can be told apart from untouched files.
public struct CloudTrackedFile: Codable, Equatable, Sendable {
    public var itemID: String
    public var eTag: String?
    public var sha256: String
    public init(itemID: String, eTag: String?, sha256: String) { self.itemID = itemID; self.eTag = eTag; self.sha256 = sha256 }
}

/// A local copy of part of a cloud folder (a Power BI project: `.pbip` + `.Report` + `.SemanticModel`).
public struct CloudFolderMirror: Codable, Equatable, Sendable {
    public var driveID: String
    public var folderItemID: String
    /// The folder's path below the drive root ("Reports/Sales"), used to address files the app adds. Nil when unknown.
    public var folderPath: String?
    /// Relative path (with "/") → tracked file.
    public var files: [String: CloudTrackedFile]
    public init(driveID: String, folderItemID: String, folderPath: String?, files: [String: CloudTrackedFile] = [:]) {
        self.driveID = driveID; self.folderItemID = folderItemID; self.folderPath = folderPath; self.files = files
    }
}

public extension CloudDocumentSync {
    /// Bounds on a mirrored folder tree.
    struct FolderLimits: Sendable {
        public var maxFiles = 5_000
        public var maxTotalBytes: Int64 = 1024 * 1024 * 1024
        public var maxDepth = 24
        public init() {}
    }

    /// What `uploadChanges` would send.
    struct FolderChanges: Equatable, Sendable {
        public var changed: [String] = []
        public var added: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }
    }

    /// The folder path below the drive root from a Graph `parentReference.path` (`/drive/root:/A/B` → `A/B`).
    static func relativeFolderPath(fromGraphPath path: String?) -> String? {
        guard let path, let r = path.range(of: "root:") else { return nil }
        let rest = path[r.upperBound...].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        return rest.joined(separator: "/")
    }

    /// A path component a cloud item may use locally: not empty, not `.`/`..`, no separators or control characters.
    static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 255 else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0) }
    }

    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the entries of a cloud folder named in `names` (files, and folders with everything in them; every
    /// entry when `names` is nil) into `localRoot`, keeping their relative paths. Refuses unsafe names, deep trees and
    /// trees above the limits.
    func downloadFolder(driveID: String, folderItemID: String, folderPath: String?, only names: Set<String>?,
                        into localRoot: URL, limits: FolderLimits = FolderLimits()) async throws -> CloudFolderMirror {
        var mirror = CloudFolderMirror(driveID: driveID, folderItemID: folderItemID, folderPath: folderPath)
        var total: Int64 = 0
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        func walk(_ folderID: String, prefix: String, depth: Int, top: Bool) async throws {
            guard depth <= limits.maxDepth else {
                throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0, message: "The project folder is nested too deeply to open.")
            }
            for child in try await graph.allChildren(of: .item(driveID: driveID, itemID: folderID), limit: limits.maxFiles + 1) {
                if top, let names, !names.contains(child.name) { continue }
                guard Self.isSafeComponent(child.name) else {
                    throw CloudAPIError(service: "Microsoft Graph", kind: .invalidResponse, statusCode: 0, message: "The project contains an item with an unsafe name (“\(child.name)”).")
                }
                let rel = prefix.isEmpty ? child.name : prefix + "/" + child.name
                if child.isFolder {
                    try FileManager.default.createDirectory(at: localRoot.appendingPathComponent(rel), withIntermediateDirectories: true)
                    try await walk(child.id, prefix: rel, depth: depth + 1, top: false)
                    continue
                }
                guard mirror.files.count < limits.maxFiles else {
                    throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0, message: "The project holds more than \(limits.maxFiles) files.")
                }
                let remaining = limits.maxTotalBytes - total
                guard (child.size ?? 0) <= remaining else { throw CloudSaveError.tooLarge(name: "The project", limit: limits.maxTotalBytes) }
                let destination = localRoot.appendingPathComponent(rel)
                let file: URL
                do {
                    file = try await graph.download(.item(driveID: driveID, itemID: child.id), suggestedName: child.name,
                                                    destination: destination, maxBytes: remaining)
                } catch let e as CloudAPIError where e.kind == .invalidResponse && e.message.contains("larger than") {
                    throw CloudSaveError.tooLarge(name: "The project", limit: limits.maxTotalBytes)
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
                total += size
                mirror.files[rel] = CloudTrackedFile(itemID: child.id, eTag: child.eTag, sha256: try Self.digest(of: file))
            }
        }
        try await walk(folderItemID, prefix: "", depth: 0, top: true)
        return mirror
    }

    /// Compares `localRoot` with `mirror`: files whose bytes changed, new files and files that are gone.
    /// Only paths for which `relevant` is true are considered (local caches and settings are left out).
    static func changes(in localRoot: URL, since mirror: CloudFolderMirror, relevant: (String) -> Bool) throws -> FolderChanges {
        var out = FolderChanges()
        var seen = Set<String>()
        let fm = FileManager.default
        if let walker = fm.enumerator(at: localRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let root = localRoot.standardizedFileURL.path
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root + "/") else { continue }
                let rel = String(path.dropFirst(root.count + 1))
                guard relevant(rel) else { continue }
                seen.insert(rel)
                if let tracked = mirror.files[rel] {
                    if try digest(of: url) != tracked.sha256 { out.changed.append(rel) }
                } else {
                    out.added.append(rel)
                }
            }
        }
        out.removed = mirror.files.keys.filter { relevant($0) && !seen.contains($0) }
        out.changed.sort(); out.added.sort(); out.removed.sort()
        return out
    }

    /// Sends local edits under `localRoot` back to the cloud folder. Unless `overwrite` is true, every file about to be
    /// replaced or removed is first checked against the version that was downloaded, and nothing is written when any of
    /// them changed in the cloud (`CloudSaveError.conflict`). Returns the mirror with the new versions.
    func uploadChanges(from localRoot: URL, mirror: CloudFolderMirror, overwrite: Bool = false,
                       relevant: (String) -> Bool) async throws -> CloudFolderMirror {
        let delta = try Self.changes(in: localRoot, since: mirror, relevant: relevant)
        guard !delta.isEmpty else { return mirror }
        var result = mirror
        let drive = mirror.driveID
        if !overwrite {
            for rel in delta.changed + delta.removed {
                guard let tracked = mirror.files[rel] else { continue }
                let current: DriveItem
                do { current = try await graph.item(at: .item(driveID: drive, itemID: tracked.itemID)) }
                catch let e as CloudAPIError where e.kind == .notFound {
                    if delta.removed.contains(rel) { continue }
                    throw CloudSaveError.missing(name: rel)
                }
                if let then = tracked.eTag, let now = current.eTag, then != now {
                    throw CloudSaveError.conflict(name: rel, modifiedBy: current.lastModifiedBy, modified: current.modified, currentETag: now)
                }
            }
        }
        for rel in delta.changed {
            guard let tracked = mirror.files[rel] else { continue }
            let file = localRoot.appendingPathComponent(rel)
            do {
                let item = try await graph.replaceContent(of: .item(driveID: drive, itemID: tracked.itemID), withFileAt: file,
                                                          ifMatchETag: overwrite ? nil : tracked.eTag)
                result.files[rel] = CloudTrackedFile(itemID: item.id, eTag: item.eTag, sha256: try Self.digest(of: file))
            } catch let e as CloudAPIError where e.kind == .preconditionFailed {
                throw CloudSaveError.conflict(name: rel, modifiedBy: nil, modified: nil, currentETag: nil)
            }
        }
        if !delta.added.isEmpty {
            guard let base = mirror.folderPath else {
                throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0,
                                    message: "New files can't be added to this shared folder; save a copy to your OneDrive instead.")
            }
            for rel in delta.added {
                let parts = rel.split(separator: "/").map(String.init)
                guard let name = parts.last, parts.allSatisfy(Self.isSafeComponent) else { continue }
                let dir = ([base] + parts.dropLast()).filter { !$0.isEmpty }.joined(separator: "/")
                let folder: DriveLocation = dir.isEmpty ? .driveRoot(driveID: drive) : .path(driveID: drive, path: dir)
                let file = localRoot.appendingPathComponent(rel)
                do {
                    let item = try await graph.upload(fileAt: file, to: folder, named: name, conflict: overwrite ? .replace : .fail)
                    result.files[rel] = CloudTrackedFile(itemID: item.id, eTag: item.eTag, sha256: try Self.digest(of: file))
                } catch let e as CloudAPIError where e.kind == .conflict || e.code == "nameAlreadyExists" {
                    throw CloudSaveError.conflict(name: rel, modifiedBy: nil, modified: nil, currentETag: nil)
                }
            }
        }
        for rel in delta.removed {
            guard let tracked = mirror.files[rel] else { continue }
            do { try await graph.delete(.item(driveID: drive, itemID: tracked.itemID), ifMatchETag: overwrite ? nil : tracked.eTag) }
            catch let e as CloudAPIError where e.kind == .notFound {}
            catch let e as CloudAPIError where e.kind == .preconditionFailed {
                throw CloudSaveError.conflict(name: rel, modifiedBy: nil, modified: nil, currentETag: nil)
            }
            result.files[rel] = nil
        }
        return result
    }
}
