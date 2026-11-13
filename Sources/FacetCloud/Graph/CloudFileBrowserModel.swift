import Foundation
import Combine

/// View model for cloud open/save panels: browses OneDrive and SharePoint through `GraphClient`.
///
/// Bind a SwiftUI view to `breadcrumbs`, `visibleEntries`, `isLoading` and `errorMessage`; call
/// `open(_:)`, `navigate(toBreadcrumbAt:)`, `goUp()`, `submitSearch()` and `loadMore()` from the UI.
@MainActor
public final class CloudFileBrowserModel: ObservableObject {
    /// Top-level places shown in the sidebar.
    public enum Place: String, CaseIterable, Identifiable, Sendable {
        case oneDrive, recent, shared, sites
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .oneDrive: return "OneDrive"
            case .recent: return "Recent"
            case .shared: return "Shared with me"
            case .sites: return "SharePoint sites"
            }
        }
    }

    /// One step in the location stack.
    public struct Breadcrumb: Identifiable, Equatable, Sendable {
        public enum Target: Equatable, Sendable {
            case place(Place)
            case folder(DriveLocation)
            case site(id: String)
            case searchResults(query: String)
        }
        public let id = UUID()
        public let title: String
        public let target: Target
        public static func == (a: Breadcrumb, b: Breadcrumb) -> Bool { a.title == b.title && a.target == b.target }
    }

    /// A row in the browser.
    public enum Entry: Identifiable, Equatable, Sendable {
        case item(DriveItem)
        case site(SharePointSite)
        case library(GraphDrive)

        public var id: String {
            switch self {
            case .item(let i): return "item:" + (i.effectiveDriveID ?? "") + ":" + i.effectiveItemID
            case .site(let s): return "site:" + s.id
            case .library(let d): return "drive:" + d.id
            }
        }
        public var name: String {
            switch self {
            case .item(let i): return i.name
            case .site(let s): return s.title
            case .library(let d): return d.name ?? "Documents"
            }
        }
        /// True when opening the entry navigates into it.
        public var isContainer: Bool {
            if case .item(let i) = self { return i.isFolder }
            return true
        }
        public var modified: Date? { if case .item(let i) = self { return i.modified }; return nil }
        public var size: Int64? { if case .item(let i) = self { return i.size }; return nil }
    }

    public enum SortKey: String, CaseIterable, Sendable { case name, modified, size }

    /// File extensions Facet can open, for use with `allowedExtensions`.
    public static let facetOpenableExtensions: Set<String> = ["facet", "pbix", "pbip", "pbit", "xlsx", "xls", "csv", "tsv", "txt", "json", "xml", "parquet"]

    @Published public private(set) var breadcrumbs: [Breadcrumb]
    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var errorMessage: String?
    /// The underlying error, for UI that reacts to specific cases (e.g. offering sign-in).
    @Published public private(set) var lastError: Error?
    @Published public private(set) var hasMore = false
    @Published public var sortKey: SortKey = .name
    @Published public var sortAscending = true
    /// Text bound to the search field. Call `submitSearch()` to run a search; clearing it and submitting returns to browsing.
    @Published public var searchText = ""
    /// Lower-case extensions without dots. Empty = show all files. Folders are always shown.
    @Published public var allowedExtensions: Set<String> = []
    @Published public var selection: Entry.ID?

    public let client: GraphClient
    private var nextItemPage: GraphPage<DriveItem>?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    public init(client: GraphClient, startAt place: Place = .oneDrive) {
        self.client = client
        self.breadcrumbs = [Breadcrumb(title: place.title, target: .place(place))]
    }

    // MARK: Derived state

    /// `entries` after the extension filter and sort; folders and other containers first.
    public var visibleEntries: [Entry] {
        let filtered = entries.filter { e in
            guard case .item(let i) = e, !i.isFolder, !allowedExtensions.isEmpty else { return true }
            return allowedExtensions.contains(i.fileExtension)
        }
        let asc = sortAscending
        return filtered.sorted { a, b in
            if a.isContainer != b.isContainer { return a.isContainer }
            switch sortKey {
            case .name: break
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                if x != y { return asc ? x < y : x > y }
            case .size:
                let x = a.size ?? 0, y = b.size ?? 0
                if x != y { return asc ? x < y : x > y }
            }
            let c = a.name.localizedStandardCompare(b.name)
            if c == .orderedSame { return a.id < b.id }
            return (sortKey == .name ? asc : true) ? c == .orderedAscending : c == .orderedDescending
        }
    }

    public var currentPlace: Place? {
        if case .place(let p) = breadcrumbs.first?.target { return p }
        return nil
    }

    /// The folder a new file would be saved into, when the current location is a real folder.
    public var currentFolder: DriveLocation? {
        switch breadcrumbs.last?.target {
        case .place(.oneDrive): return .myRoot
        case .folder(let loc): return loc
        default: return nil
        }
    }

    public var canGoUp: Bool { breadcrumbs.count > 1 }

    public var selectedEntry: Entry? { entries.first { $0.id == selection } }

    // MARK: Navigation

    /// Switches to a top-level place and loads it.
    public func show(_ place: Place) {
        searchText = ""
        breadcrumbs = [Breadcrumb(title: place.title, target: .place(place))]
        reload()
    }

    /// Opens an entry: navigates into folders, sites and libraries. Returns the item when it is a file
    /// (the caller then downloads/opens it), otherwise `nil`.
    @discardableResult
    public func open(_ entry: Entry) -> DriveItem? {
        switch entry {
        case .item(let item):
            guard item.isFolder else { return item }
            guard let loc = item.location else { return nil }
            push(Breadcrumb(title: item.name, target: .folder(loc)))
        case .site(let site):
            push(Breadcrumb(title: site.title, target: .site(id: site.id)))
        case .library(let drive):
            push(Breadcrumb(title: drive.name ?? "Documents", target: .folder(.driveRoot(driveID: drive.id))))
        }
        return nil
    }

    private func push(_ crumb: Breadcrumb) {
        // Leaving search results by opening a folder replaces the results crumb.
        if case .searchResults = breadcrumbs.last?.target { breadcrumbs.removeLast() }
        breadcrumbs.append(crumb)
        searchText = ""
        reload()
    }

    public func navigate(toBreadcrumbAt index: Int) {
        guard breadcrumbs.indices.contains(index), index < breadcrumbs.count - 1 else { return }
        breadcrumbs.removeSubrange((index + 1)...)
        searchText = ""
        reload()
    }

    public func goUp() { navigate(toBreadcrumbAt: breadcrumbs.count - 2) }

    /// Runs a search for `searchText` (files in the current drive, or sites when browsing SharePoint sites).
    /// An empty search returns to the location that was being browsed.
    public func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .searchResults = breadcrumbs.last?.target { breadcrumbs.removeLast() }
        if !q.isEmpty { breadcrumbs.append(Breadcrumb(title: "Results for “\(q)”", target: .searchResults(query: q))) }
        reload()
    }

    // MARK: Loading

    /// Reloads the current location, cancelling any load in progress.
    public func reload() {
        loadTask?.cancel()
        generation += 1
        let gen = generation
        guard let target = breadcrumbs.last?.target else { return }
        let scope = searchScope()
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        lastError = nil
        selection = nil
        loadTask = Task { [weak self, client] in
            do {
                let (entries, next) = try await Self.load(target, searchScope: scope, client: client)
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                self.entries = entries
                self.nextItemPage = next
                self.hasMore = next?.nextLink != nil
                self.isLoading = false
            } catch {
                guard let self, gen == self.generation else { return }
                self.isLoading = false
                if error is CancellationError || Task.isCancelled { return }
                self.entries = []
                self.hasMore = false
                self.lastError = error
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Loads the next page of the current folder or result list, if there is one.
    public func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore, let page = nextItemPage else { return }
        let gen = generation
        isLoadingMore = true
        Task { [weak self, client] in
            do {
                let next = try await client.nextPage(after: page)
                guard let self, gen == self.generation else { return }
                self.isLoadingMore = false
                self.entries.append(contentsOf: (next?.items ?? []).map(Entry.item))
                self.nextItemPage = next
                self.hasMore = next?.nextLink != nil
            } catch {
                guard let self, gen == self.generation else { return }
                self.isLoadingMore = false
                if error is CancellationError { return }
                self.lastError = error
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// What a search should cover, based on the location under the results crumb.
    private enum SearchScope { case myDrive, drive(String), sites }

    private func searchScope() -> SearchScope {
        for crumb in breadcrumbs.reversed() {
            switch crumb.target {
            case .folder(let loc):
                switch loc {
                case .driveRoot(let d), .item(let d, _), .path(let d, _): return .drive(d)
                default: return .myDrive
                }
            case .place(.sites), .site: return .sites
            case .place: return .myDrive
            case .searchResults: continue
            }
        }
        return .myDrive
    }

    private static func load(_ target: Breadcrumb.Target, searchScope: SearchScope, client: GraphClient) async throws -> ([Entry], GraphPage<DriveItem>?) {
        func items(_ page: GraphPage<DriveItem>) -> ([Entry], GraphPage<DriveItem>?) { (page.items.map(Entry.item), page) }
        switch target {
        case .place(.oneDrive): return items(try await client.children(of: .myRoot))
        case .place(.recent): return items(try await client.recentFiles())
        case .place(.shared): return items(try await client.sharedWithMe())
        case .place(.sites):
            // Followed sites first; fall back to everything searchable when the user follows none.
            var sites = (try? await client.followedSites().items) ?? []
            if sites.isEmpty { sites = try await client.searchSites("").items }
            return (sites.map(Entry.site), nil)
        case .site(let id):
            return (try await client.drives(inSite: id).items.map(Entry.library), nil)
        case .folder(let loc):
            return items(try await client.children(of: loc))
        case .searchResults(let q):
            switch searchScope {
            case .sites: return (try await client.searchSites(q).items.map(Entry.site), nil)
            case .drive(let d): return items(try await client.search(q, driveID: d))
            case .myDrive: return items(try await client.search(q))
            }
        }
    }

    // MARK: Actions

    /// Creates a folder in the current location and refreshes the listing.
    @discardableResult
    public func createFolder(named name: String) async throws -> DriveItem {
        guard let folder = currentFolder else {
            throw CloudAPIError(service: "Microsoft Graph", kind: .badRequest, statusCode: 0, message: "Folders can only be created inside OneDrive or a document library.")
        }
        let item = try await client.createFolder(named: name, in: folder)
        reload()
        return item
    }

    /// Deletes an item and removes it from the listing.
    public func delete(_ item: DriveItem) async throws {
        guard let loc = item.location else { return }
        try await client.delete(loc, ifMatchETag: nil)
        entries.removeAll { $0.id == Entry.item(item).id }
    }
}
