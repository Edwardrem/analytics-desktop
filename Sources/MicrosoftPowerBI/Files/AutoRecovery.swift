import SwiftUI
import AppKit
import FacetCore
import FacetInterop

/// Periodic recovery copies of open documents with unsaved changes, offered back on the next launch after the app
/// quit without the user deciding about them (a crash, a forced quit, power loss).
///
/// Each document with unsaved changes gets `<id>.facet` (a full package, data included) and `<id>.json` (its name,
/// where it was saved, when the copy was made) in the recovery folder. Saving, reverting, closing without saving and
/// quitting normally delete the copy.
@MainActor
final class AutoRecovery {
    static let shared = AutoRecovery()

    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var original: URL?
        var savedAt: Date
    }

    /// The folder recovery copies go to unless Settings names another one.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("AutoRecovery", isDirectory: true)
    }

    private let defaults: UserDefaults
    private let fixedDirectory: URL?
    private struct Slot { weak var store: DocumentStore?; var id: String; var lastWrite: Date? }
    private var slots: [ObjectIdentifier: Slot] = [:]
    private var timer: Timer?

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.fixedDirectory = directory
        self.defaults = defaults
    }

    var directory: URL {
        if let fixedDirectory { return fixedDirectory }
        let custom = defaults.string(forKey: AppSettings.Key.autoRecoveryLocation.rawValue) ?? ""
        return custom.isEmpty ? Self.defaultDirectory : URL(fileURLWithPath: custom, isDirectory: true)
    }
    var isEnabled: Bool { defaults.object(forKey: AppSettings.Key.autoRecovery.rawValue) as? Bool ?? true }
    var interval: TimeInterval {
        let minutes = defaults.integer(forKey: AppSettings.Key.autoRecoveryMinutes.rawValue)
        return TimeInterval(min(max(minutes == 0 ? 10 : minutes, 1), 60) * 60)
    }

    // MARK: Schedule

    /// Checks every 30 seconds which documents are due a copy. Settings changes apply at the next check.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { AutoRecovery.shared.tick(stores: StoreRegistry.shared.all) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Every document was saved or discarded by the user before a normal quit got this far.
            MainActor.assumeIsolated { AutoRecovery.shared.discardAll(StoreRegistry.shared.all) }
        }
    }

    static func isDue(isDirty: Bool, lastWrite: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard isDirty else { return false }
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) >= interval
    }

    func tick(stores: [DocumentStore], now: Date = Date()) {
        guard isEnabled else { return }
        for store in stores {
            let key = ObjectIdentifier(store)
            guard Self.isDue(isDirty: store.isDirty, lastWrite: slots[key]?.store === store ? slots[key]?.lastWrite : nil,
                             now: now, interval: interval) else { continue }
            do { try write(store, now: now) }
            catch { store.status = StatusMessage(kind: .warning, text: "Couldn't save a recovery copy: \(error.localizedDescription)") }
        }
    }

    // MARK: Copies

    private func slot(for store: DocumentStore) -> Slot {
        let key = ObjectIdentifier(store)
        if let s = slots[key], s.store === store { return s }
        slots = slots.filter { $0.value.store != nil }
        let s = Slot(store: store, id: UUID().uuidString, lastWrite: nil)
        slots[key] = s
        return s
    }

    func recoveryID(of store: DocumentStore) -> String? {
        let s = slots[ObjectIdentifier(store)]
        return s?.store === store ? s?.id : nil
    }

    /// Writes (or replaces) the store's recovery copy now.
    func write(_ store: DocumentStore, now: Date = Date()) throws {
        var s = slot(for: store)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DocumentPackage.write(store.doc, to: directory.appendingPathComponent("\(s.id).facet"))
        let entry = Entry(id: s.id, name: store.displayName, original: store.fileURL, savedAt: now)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(entry).write(to: directory.appendingPathComponent("\(s.id).json"), options: .atomic)
        s.lastWrite = now
        slots[ObjectIdentifier(store)] = s
    }

    /// Deletes the store's recovery copy: it was saved, reverted or closed without saving.
    func discard(_ store: DocumentStore) {
        let key = ObjectIdentifier(store)
        guard let s = slots[key], s.store === store else { return }
        remove(id: s.id)
        slots[key] = nil
    }

    func discardAll(_ stores: [DocumentStore]) { for s in stores { discard(s) } }

    /// A restored document keeps writing to the copy it came from until it is saved.
    func adopt(_ store: DocumentStore, recoveryID id: String) {
        slots = slots.filter { $0.value.store != nil }
        slots[ObjectIdentifier(store)] = Slot(store: store, id: id, lastWrite: Date())
    }

    /// Whether `url` is a recovery copy in the recovery folder.
    func contains(_ url: URL) -> Bool {
        url.pathExtension == DocumentPackage.fileExtension
            && url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
    }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).facet"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    /// Recovery copies left behind by an earlier session (not by a document open now), newest first.
    func leftovers() -> [Entry] {
        let live = Set(slots.values.filter { $0.store != nil }.map(\.id))
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Entry? in
            guard let data = try? BoundedFile.read(url, limit: 64 * 1024), let entry = try? d.decode(Entry.self, from: data),
                  entry.id == url.deletingPathExtension().lastPathComponent, !live.contains(entry.id),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(entry.id).facet").path) else { return nil }
            return entry
        }.sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: Restore prompt

    /// Asks whether to restore what an earlier session left behind. Called once, after launch; waits (briefly) for
    /// the first window, which restored documents open beside or into.
    func offerRestore(attempts: Int = 40) {
        let entries = leftovers()
        guard !entries.isEmpty else { return }
        guard FileOperations.openInNewWindow != nil else {
            if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.offerRestore(attempts: attempts - 1) } }
            return
        }
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "“\(entries[0].name)” has unsaved changes from last time."
            : "\(entries.count) documents have unsaved changes from last time."
        alert.informativeText = "\(AppIdentity.name) quit before they were saved. Restore them to keep working, or discard the recovered changes."
            + "\n\n" + entries.prefix(6).map { "• \($0.name) — \($0.savedAt.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n")
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The first goes into the untouched window the app opened with, if there is one.
            var blank = StoreRegistry.shared.all.first { $0.fileURL == nil && !$0.isDirty && $0.model.tables.isEmpty }
            for entry in entries {
                let url = directory.appendingPathComponent("\(entry.id).facet")
                DocumentFiles.pending[url.standardizedFileURL] = .recovered(original: entry.original, id: entry.id)
                if let store = blank { FileOperations.open(url, into: store); blank = nil }
                else { FileOperations.openInNewWindow?(url) }
            }
        case .alertThirdButtonReturn:
            for entry in entries { remove(id: entry.id) }
        default: break
        }
    }
}
