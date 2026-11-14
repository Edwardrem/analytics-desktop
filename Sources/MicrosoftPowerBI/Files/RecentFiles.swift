import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// Documents, projects, templates and data source files opened or saved recently, newest first.
/// Kept in user defaults as paths plus bookmarks, so a file that was moved or renamed is still found.
@MainActor
final class RecentFiles: ObservableObject {
    static let shared = RecentFiles()
    static let limit = 20
    static let defaultsKey = "files.recent"

    struct Entry: Codable, Equatable, Identifiable {
        var path: String
        var bookmark: Data?
        var openedAt: Date
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
        var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
        var kind: String {
            switch url.pathExtension.lowercased() {
            case DocumentPackage.fileExtension: return "\(AppIdentity.name) document"
            case "pbip": return "Power BI project"
            case "pbix": return "Power BI report"
            case "pbit": return "Power BI template"
            case "pbids": return "Data source file"
            case "tmdl": return "TMDL model"
            default: return "Folder"
            }
        }
        var symbol: String {
            switch url.pathExtension.lowercased() {
            case "pbip": return "folder.badge.gearshape"
            case "pbit": return "doc.badge.plus"
            case "pbids": return "cylinder.split.1x2"
            default: return "doc.richtext"
            }
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let defaults: UserDefaults
    /// Folders whose files are never listed: cloud working copies and recovery copies.
    var excludedFolders: [URL]

    init(defaults: UserDefaults = .standard, excludedFolders: [URL]? = nil) {
        self.defaults = defaults
        self.excludedFolders = excludedFolders ?? [
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("AnalyticsDesktop"),
            FileManager.default.temporaryDirectory,
            AutoRecovery.defaultDirectory,
        ].compactMap { $0?.standardizedFileURL }
        if let data = defaults.data(forKey: Self.defaultsKey), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    func isExcluded(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedFolders.contains { path.hasPrefix($0.path + "/") }
    }

    /// Puts `url` at the top of the list.
    func note(_ url: URL, now: Date = Date()) {
        let u = url.standardizedFileURL
        guard u.isFileURL, !isExcluded(u) else { return }
        entries.removeAll { $0.path == u.path }
        entries.insert(Entry(path: u.path, bookmark: try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                             openedAt: now), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        persist()
        NSDocumentController.shared.noteNewRecentDocumentURL(u)
    }

    func remove(_ entry: Entry) { entries.removeAll { $0 == entry }; persist() }
    func clear() { entries.removeAll(); persist() }

    /// The file's current location (following a move through its bookmark), or nil when it is gone.
    func resolve(_ entry: Entry) -> URL? {
        if FileManager.default.fileExists(atPath: entry.path) { return entry.url }
        guard let bookmark = entry.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// File ▸ Open Recent: the recent list, searchable, with files that have gone shown as missing.
struct RecentFilesSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recents = RecentFiles.shared
    @State private var search = ""
    @State private var selection: RecentFiles.Entry.ID?

    private var visible: [RecentFiles.Entry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return recents.entries.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.folder.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent").font(Design.Typeface.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(Design.Space.l)
            Hairline()
            if visible.isEmpty {
                EmptyState(systemImage: "clock", title: recents.entries.isEmpty ? "No recent files" : "No matches",
                           message: recents.entries.isEmpty ? "Documents and projects you open or save appear here." : "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible, selection: $selection) { entry in
                    row(entry).tag(entry.id)
                        .contextMenu {
                            Button("Open") { open(entry) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            Button("Remove from List") { recents.remove(entry) }
                        }
                }
                .listStyle(.inset)
            }
            Hairline()
            HStack {
                Button("Clear List") { recents.clear() }.disabled(recents.entries.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let e = visible.first(where: { $0.id == selection }) { open(e) } }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
            .padding(Design.Space.l)
        }
        .frame(width: 560, height: 420)
    }

    private func row(_ entry: RecentFiles.Entry) -> some View {
        let missing = recents.resolve(entry) == nil
        return HStack(spacing: Design.Space.s) {
            Image(systemName: entry.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(Design.Typeface.body).foregroundStyle(missing ? .tertiary : .primary)
                Text(missing ? "Missing — \(entry.folder)" : "\(entry.kind) · \(entry.folder)")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.openedAt, format: .relative(presentation: .named)).font(Design.Typeface.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(entry) }
    }

    private func open(_ entry: RecentFiles.Entry) {
        guard let url = recents.resolve(entry) else {
            store.status = StatusMessage(kind: .warning, text: "“\(entry.name)” is no longer at \(entry.folder).")
            return
        }
        dismiss()
        FileOperations.open(url, into: store)
    }
}
