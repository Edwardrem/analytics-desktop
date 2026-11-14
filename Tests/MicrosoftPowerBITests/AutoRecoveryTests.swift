import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Recovery copies of unsaved documents, and the recent files list.
@MainActor
final class AutoRecoveryTests: XCTestCase {
    private var dir: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
        suite = "recovery-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.register(defaults: AppSettings.initial)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func editedStore() -> DocumentStore {
        let s = DocumentStore(services: .live())
        s.mutate("Add Table", invalidates: .layout) { $0.model.tables.append(ModelTable(name: "Budget")) }
        return s
    }

    func testCopiesAreDueOnlyForUnsavedDocumentsOncePerInterval() {
        let now = Date()
        XCTAssertFalse(AutoRecovery.isDue(isDirty: false, lastWrite: nil, now: now, interval: 600))
        XCTAssertTrue(AutoRecovery.isDue(isDirty: true, lastWrite: nil, now: now, interval: 600))
        XCTAssertFalse(AutoRecovery.isDue(isDirty: true, lastWrite: now.addingTimeInterval(-599), now: now, interval: 600))
        XCTAssertTrue(AutoRecovery.isDue(isDirty: true, lastWrite: now.addingTimeInterval(-600), now: now, interval: 600))

        defaults.set(0, forKey: AppSettings.Key.autoRecoveryMinutes.rawValue)
        XCTAssertEqual(AutoRecovery(directory: dir, defaults: defaults).interval, 600, "an unset interval is 10 minutes")
        defaults.set(500, forKey: AppSettings.Key.autoRecoveryMinutes.rawValue)
        XCTAssertEqual(AutoRecovery(directory: dir, defaults: defaults).interval, 3600, "at most an hour")
    }

    private func waitForCopy(_ id: String) async throws {
        let json = dir.appendingPathComponent("\(id).json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: json.path), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testUnsavedDocumentsAreCopiedAndOfferedBackAfterACrash() async throws {
        let recovery = AutoRecovery(directory: dir, defaults: defaults)
        let clean = DocumentStore(services: .live())
        let edited = editedStore()
        edited.fileURL = URL(fileURLWithPath: "/Users/me/Budget.facet")
        recovery.tick(stores: [clean, edited])
        let id = try XCTUnwrap(recovery.recoveryID(of: edited))
        try await waitForCopy(id)
        XCTAssertNil(recovery.recoveryID(of: clean), "a saved document gets no copy")
        XCTAssertEqual(try DocumentPackage.read(from: dir.appendingPathComponent("\(id).facet")).model.tables.map(\.name), ["Budget"])
        XCTAssertTrue(recovery.leftovers().isEmpty, "copies of documents that are still open aren't leftovers")

        // The next session finds what this one left.
        let next = AutoRecovery(directory: dir, defaults: defaults)
        let left = next.leftovers()
        XCTAssertEqual(left.map(\.id), [id])
        XCTAssertEqual(left.first?.name, "Budget")
        XCTAssertEqual(left.first?.original, URL(fileURLWithPath: "/Users/me/Budget.facet"))
    }

    func testRestoringReopensTheCopyAsUnsavedWorkForItsOriginalFile() throws {
        let recovery = AutoRecovery(directory: dir, defaults: defaults)
        let edited = editedStore()
        try recovery.write(edited)
        let id = try XCTUnwrap(recovery.recoveryID(of: edited))
        let copy = dir.appendingPathComponent("\(id).facet")
        let original = URL(fileURLWithPath: "/Users/me/Plan.facet")

        DocumentFiles.pending[copy.standardizedFileURL] = .recovered(original: original, id: id)
        let restored = DocumentStore(services: .live())
        FileOperations.open(copy, into: restored)
        XCTAssertEqual(restored.model.tables.map(\.name), ["Budget"])
        XCTAssertEqual(restored.fileURL, original, "saving goes to the original, not the recovery folder")
        XCTAssertTrue(restored.isDirty)
        AutoRecovery.shared.discard(restored)
    }

    func testSavingOrDiscardingRemovesTheCopy() throws {
        let recovery = AutoRecovery(directory: dir, defaults: defaults)
        let edited = editedStore()
        try recovery.write(edited)
        let id = try XCTUnwrap(recovery.recoveryID(of: edited))
        recovery.discard(edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).facet").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path))
        XCTAssertNil(recovery.recoveryID(of: edited))

        defaults.set(false, forKey: AppSettings.Key.autoRecovery.rawValue)
        recovery.tick(stores: [edited])
        XCTAssertNil(recovery.recoveryID(of: edited), "turned off in Settings")
    }

    func testACopyFinishedAfterTheDocumentWasSavedIsRemoved() async throws {
        let recovery = AutoRecovery(directory: dir, defaults: defaults)
        let edited = editedStore()
        recovery.tick(stores: [edited])
        let id = try XCTUnwrap(recovery.recoveryID(of: edited))
        recovery.discard(edited)            // saved while the copy was being written
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path))
        XCTAssertTrue(recovery.leftovers().isEmpty)
    }

    func testTheLocationSettingIsHonoured() {
        let custom = dir.appendingPathComponent("Elsewhere").path
        defaults.set(custom, forKey: AppSettings.Key.autoRecoveryLocation.rawValue)
        XCTAssertEqual(AutoRecovery(defaults: defaults).directory.path, custom)
        defaults.set("", forKey: AppSettings.Key.autoRecoveryLocation.rawValue)
        XCTAssertEqual(AutoRecovery(defaults: defaults).directory, AutoRecovery.defaultDirectory)
    }

    // MARK: Recent files

    func testRecentFilesListNewestFirstWithoutDuplicatesOrWorkingCopies() throws {
        let recents = RecentFiles(defaults: defaults, excludedFolders: [dir.appendingPathComponent("cache")])
        let a = dir.appendingPathComponent("A.facet"), b = dir.appendingPathComponent("B.pbip")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data().write(to: b)
        recents.note(a)
        recents.note(b)
        recents.note(a)
        recents.note(dir.appendingPathComponent("cache/Working.facet"))
        XCTAssertEqual(recents.entries.map(\.name), ["A.facet", "B.pbip"])
        XCTAssertEqual(recents.entries.last?.kind, "Power BI project")
        XCTAssertEqual(RecentFiles(defaults: defaults, excludedFolders: []).entries.map(\.name), ["A.facet", "B.pbip"], "kept across launches")

        for i in 0..<30 { recents.note(dir.appendingPathComponent("F\(i).facet")) }
        XCTAssertEqual(recents.entries.count, RecentFiles.limit)

        recents.clear()
        recents.note(b)
        try FileManager.default.removeItem(at: b)
        XCTAssertNil(recents.resolve(try XCTUnwrap(recents.entries.first)), "a deleted file is shown as missing")
    }
}
