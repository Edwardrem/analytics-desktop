import Foundation

/// The signed-in user's Graph profile (`/me`).
public struct GraphUser: Decodable, Sendable, Equatable {
    public let id: String
    public let displayName: String?
    public let userPrincipalName: String?
    public let mail: String?
    public let jobTitle: String?
}

/// Where an item lives: its drive and parent folder.
public struct DriveItemParent: Decodable, Sendable, Equatable {
    public let driveId: String?
    public let driveType: String?
    public let id: String?
    public let name: String?
    /// e.g. `/drive/root:/Reports/2024`
    public let path: String?
    public let siteId: String?
}

/// A file or folder in OneDrive or a SharePoint document library.
public struct DriveItem: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    public let isFolder: Bool
    public let childCount: Int?
    public let mimeType: String?
    public let webUrl: String?
    public let parentReference: DriveItemParent?
    public let eTag: String?
    public let cTag: String?
    /// Short-lived pre-authenticated download URL, when Graph included it.
    public let downloadURL: URL?
    /// For items shared from another drive: the item's real id and drive.
    public let remoteItemID: String?
    public let remoteDriveID: String?
    public let lastModifiedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, size, lastModifiedDateTime, createdDateTime, folder, file, webUrl, parentReference, eTag, cTag
        case remoteItem, package, lastModifiedBy
        case downloadURL = "@microsoft.graph.downloadUrl"
    }
    private struct Folder: Decodable { let childCount: Int? }
    private struct File: Decodable { let mimeType: String? }
    private struct Identity: Decodable { let displayName: String? }
    private struct IdentitySet: Decodable { let user: Identity? }
    private struct Remote: Decodable {
        let id: String?
        let name: String?
        let size: Int64?
        let folder: Folder?
        let file: File?
        let webUrl: String?
        let parentReference: DriveItemParent?
        let lastModifiedDateTime: Date?
    }
    private struct Package: Decodable { let type: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let remote = try c.decodeIfPresent(Remote.self, forKey: .remoteItem)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? remote?.name ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? remote?.size
        modified = try c.decodeIfPresent(Date.self, forKey: .lastModifiedDateTime) ?? remote?.lastModifiedDateTime
        created = try c.decodeIfPresent(Date.self, forKey: .createdDateTime)
        let folder = try c.decodeIfPresent(Folder.self, forKey: .folder) ?? remote?.folder
        let file = try c.decodeIfPresent(File.self, forKey: .file) ?? remote?.file
        // OneNote notebooks and similar "packages" are neither file nor folder; treat them as non-folders.
        isFolder = folder != nil
        childCount = folder?.childCount
        mimeType = file?.mimeType
        webUrl = try c.decodeIfPresent(String.self, forKey: .webUrl) ?? remote?.webUrl
        parentReference = try c.decodeIfPresent(DriveItemParent.self, forKey: .parentReference)
        eTag = try c.decodeIfPresent(String.self, forKey: .eTag)
        cTag = try c.decodeIfPresent(String.self, forKey: .cTag)
        downloadURL = (try c.decodeIfPresent(String.self, forKey: .downloadURL)).flatMap(URL.init(string:))
        remoteItemID = remote?.id
        remoteDriveID = remote?.parentReference?.driveId
        lastModifiedBy = (try c.decodeIfPresent(IdentitySet.self, forKey: .lastModifiedBy))?.user?.displayName
    }

    /// The drive that actually holds the item (the remote drive for shared items).
    public var effectiveDriveID: String? { remoteDriveID ?? parentReference?.driveId }
    /// The item id within `effectiveDriveID`.
    public var effectiveItemID: String { remoteItemID ?? id }
    /// Lower-cased file extension without the dot ("pbix"); empty for folders.
    public var fileExtension: String { isFolder ? "" : (name as NSString).pathExtension.lowercased() }
    /// The location to use for follow-up calls on this item.
    public var location: DriveLocation? {
        guard let drive = effectiveDriveID else { return nil }
        return .item(driveID: drive, itemID: effectiveItemID)
    }
}

/// A document library or OneDrive.
public struct GraphDrive: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let driveType: String?
    public let webUrl: String?
    public let description: String?
}

/// A SharePoint site.
public struct SharePointSite: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let displayName: String?
    public let webUrl: String?
    public let description: String?
    public var title: String { displayName ?? name ?? webUrl ?? id }
}

/// A sharing link created with `createLink`.
public struct SharingLink: Sendable, Equatable {
    public enum LinkType: String, Sendable { case view, edit, embed }
    public enum Scope: String, Sendable { case anonymous, organization, users }
    public let id: String?
    public let webURL: URL
    public let type: String?
    public let scope: String?
}

/// What to do when an uploaded or created item's name already exists.
public enum ConflictBehavior: String, Sendable { case replace, rename, fail }

/// Addresses a drive item for Graph calls.
public enum DriveLocation: Hashable, Sendable {
    /// Root of the signed-in user's OneDrive.
    case myRoot
    /// An item in the user's OneDrive by id.
    case myItem(id: String)
    /// A path in the user's OneDrive, e.g. `Reports/2024/Sales.facet`.
    case myPath(String)
    /// Root of a specific drive (e.g. a SharePoint document library).
    case driveRoot(driveID: String)
    case item(driveID: String, itemID: String)
    case path(driveID: String, path: String)

    /// The Graph resource path (after `/v1.0`) for this item, e.g. `/me/drive/root:/Reports:`.
    public var resourcePath: String {
        func seg(_ s: String) -> String { HTTPHelpers.encodePathSegment(s) }
        func rel(_ p: String) -> String { HTTPHelpers.encodePath(p) }
        switch self {
        case .myRoot: return "/me/drive/root"
        case .myItem(let id): return "/me/drive/items/\(seg(id))"
        case .myPath(let p): return rel(p).isEmpty ? "/me/drive/root" : "/me/drive/root:/\(rel(p)):"
        case .driveRoot(let d): return "/drives/\(seg(d))/root"
        case .item(let d, let i): return "/drives/\(seg(d))/items/\(seg(i))"
        case .path(let d, let p): return rel(p).isEmpty ? "/drives/\(seg(d))/root" : "/drives/\(seg(d))/root:/\(rel(p)):"
        }
    }

    /// The resource path for a sub-resource or action (`children`, `content`, `createLink`…).
    public func subresource(_ name: String) -> String { resourcePath + "/" + name }

    /// The path addressing a child by name under this folder, e.g. `/me/drive/root:/Sales.facet:`.
    public func childPath(named name: String) -> String {
        let n = HTTPHelpers.encodePathSegment(name)
        let base = resourcePath
        // Path-addressed folders already end with ":" — extend the path instead of nesting another ":/".
        if base.hasSuffix(":") { return String(base.dropLast()) + "/\(n):" }
        return base + ":/\(n):"
    }
}

/// One page of a Graph collection.
public struct GraphPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let items: [T]
    /// Pass to `GraphClient.nextPage` to continue; `nil` on the last page.
    public let nextLink: URL?

    private enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([T].self, forKey: .value) ?? []
        nextLink = (try c.decodeIfPresent(String.self, forKey: .nextLink)).flatMap(URL.init(string:))
    }
    public init(items: [T], nextLink: URL?) { self.items = items; self.nextLink = nextLink }
}
