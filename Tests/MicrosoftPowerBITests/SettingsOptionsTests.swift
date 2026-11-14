import XCTest
import FacetCore
import FacetDAX
import FacetQuery
@testable import MicrosoftPowerBI

/// Settings that take effect: managed preferences, parallel loading, preview features, tracing, the model
/// language and the Current File options saved in the document.
@MainActor
final class SettingsOptionsTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        suite = "SettingsOptionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
    }
    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    /// UserDefaults reporting some keys as set by a configuration profile.
    private final class Managed: UserDefaults {
        var forced: Set<String> = []
        override func objectIsForced(forKey key: String) -> Bool { forced.contains(key) }
    }

    func testManagedOptionsAreLockedWithAReason() throws {
        let managed = try XCTUnwrap(Managed(suiteName: suite))
        managed.forced = [AppSettings.Key.privacyMode.rawValue]
        XCTAssertEqual(ManagedPreferences.lockReason([.privacyMode], managed), ManagedPreferences.explanation)
        XCTAssertNil(ManagedPreferences.lockReason([.tracing], managed))
        XCTAssertTrue(ManagedPreferences.lockReason([.tracing, .privacyMode], managed) != nil, "any managed key locks the control")
    }

    func testParallelLoadingCanBeTurnedOff() {
        let on = QueryEngine(queries: [], environment: QueryEnvironment(baseDirectory: nil))
        let usual = on.maxConcurrentRefreshes
        DataLoadOptions.configure(on, defaults: defaults)
        XCTAssertEqual(on.maxConcurrentRefreshes, usual, "on by default")
        XCTAssertGreaterThan(usual, 1)

        defaults.set(false, forKey: AppSettings.Key.parallelLoading.rawValue)
        let off = QueryEngine(queries: [], environment: QueryEnvironment(baseDirectory: nil))
        DataLoadOptions.configure(off, defaults: defaults)
        XCTAssertEqual(off.maxConcurrentRefreshes, 1)
    }

    func testPreviewTogglesReachTheEngineAndTheGallery() {
        XCTAssertEqual(PreviewFeatures.engineFeatures(defaults), DAXFeatures(), "all on by default")
        XCTAssertTrue(PreviewFeatures.offers(.gantt, defaults: defaults))
        defaults.set(false, forKey: AppSettings.Key.previewCalendarTI.rawValue)
        defaults.set(false, forKey: AppSettings.Key.previewFullTextSearch.rawValue)
        defaults.set(false, forKey: AppSettings.Key.previewUserContextColumns.rawValue)
        defaults.set(false, forKey: AppSettings.Key.previewGantt.rawValue)
        XCTAssertEqual(PreviewFeatures.engineFeatures(defaults),
                       DAXFeatures(calendarTimeIntelligence: false, textSearch: false, userContextColumns: false))
        XCTAssertFalse(PreviewFeatures.offers(.gantt, defaults: defaults))
        XCTAssertTrue(PreviewFeatures.offers(.table, defaults: defaults))
    }

    /// Turning a preview off reloads open documents, whose new engines then refuse the feature.
    func testApplyingPreviewsReloadsOpenDocuments() async throws {
        let saved = DAXFeatures.current
        defer { DAXFeatures.current = saved }
        DAXFeatures.current = DAXFeatures()
        let store = DocumentStore(services: .live())
        store.replaceDocument(document(), url: nil)
        try await waitForEngine(store)
        let before = await store.withEngine { (try? $0.scalar("COUNTROWS(FILTER(Sales, TEXTSEARCH(Sales[Item], \"pen\")))", filters: []))?.asDouble }
        XCTAssertEqual(before, 1)

        defaults.set(false, forKey: AppSettings.Key.previewFullTextSearch.rawValue)
        XCTAssertTrue(PreviewFeatures.apply(defaults, stores: [store]))
        XCTAssertFalse(PreviewFeatures.apply(defaults, stores: [store]), "nothing changed the second time")
        try await Task.sleep(nanoseconds: 200_000_000)
        let after: String? = await store.withEngine { engine in
            do { _ = try engine.scalar("COUNTROWS(FILTER(Sales, TEXTSEARCH(Sales[Item], \"pen\")))", filters: []); return nil } catch { return "\(error)" }
        }
        XCTAssertTrue(after?.contains("preview feature") == true, after ?? "no error")
    }

    // MARK: Tracing

    func testTracingWritesCountsAndTimesButNoValues() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Traces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = TraceLog.shared
        let savedDirectory = log.directory
        defer { log.directory = savedDirectory; log.setEnabled { AppSettings.bool(.tracing) } }
        log.directory = dir
        log.setEnabled { false }
        log.record("ignored", ["rows": .count(1)])
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.fileURL().path), "nothing is written while tracing is off")

        log.setEnabled { true }
        let store = DocumentStore(services: .live())
        store.replaceDocument(document(), url: nil)
        try await waitForEngine(store)
        log.flush()
        let text = try String(contentsOf: log.fileURL(), encoding: .utf8)
        let lines = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let load = try XCTUnwrap(lines.last { $0["event"] as? String == "engine.load" }, text)
        XCTAssertEqual(load["tables"] as? Int, 1)
        XCTAssertEqual(load["rows"] as? Int, 2)
        XCTAssertNotNil(load["ms"] as? Double)
        XCTAssertNotNil(load["time"] as? String)
        XCTAssertFalse(text.contains("Secret Pen"), "no data values")
        XCTAssertFalse(text.contains("SUM("), "no DAX text")
    }

    // MARK: Model language and Current File

    func testNewFilesTakeTheModelLanguage() {
        defaults.set("fr-FR", forKey: AppSettings.Key.modelLanguage.rawValue)
        XCTAssertEqual(DocumentStore.newDocument(defaults: defaults).model.culture, "fr-FR")
    }

    func testTheModelLanguageFormatsValues() async throws {
        let saved = ValueFormatter.culture
        defer { ValueFormatter.culture = saved }
        let store = DocumentStore(services: .live())
        store.replaceDocument(document(), url: nil)
        try await waitForEngine(store)
        CurrentFileOptions.setModelLanguage("de-DE", store)
        XCTAssertEqual(store.model.culture, "de-DE")
        for _ in 0..<200 where ValueFormatter.culture.identifier != "de-DE" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00"), "1.234,50", "on screen")
        let formatted = await store.withEngine { (try? $0.scalar("FORMAT([Total], \"#,0.00\")", filters: []))?.asString }
        XCTAssertEqual(formatted, "1.234,50", "in DAX: 1000 + 234.5")
        store.undo()
        XCTAssertEqual(store.model.culture, "en-US")
    }

    func testCurrentFileOptionsAreSavedInTheDocument() {
        let store = DocumentStore(services: .live())
        store.replaceDocument(document(), url: nil)
        CurrentFileOptions.setAutoDateTime(true, store)
        XCTAssertTrue(store.model.autoDateTime)

        XCTAssertNil(store.model.autodetectRelationships, "follows Settings until chosen")
        CurrentFileOptions.setAutodetectRelationships(false, store)
        XCTAssertEqual(store.model.autodetectRelationships, false)
        XCTAssertFalse(DataLoadOptions.autodetectRelationships(for: store.doc, defaults: defaults), "the file's choice wins over the global default (on)")

        CurrentFileOptions.setQueryReduction(\.slicerApplyButtons, true, store)
        XCTAssertTrue(store.report.settings.slicerApplyButtons)
        CurrentFileOptions.setQueryReduction(\.disableCrossHighlightByDefault, true, store)
        XCTAssertTrue(store.report.settings.disableCrossHighlightByDefault)

        store.undo(); store.undo(); store.undo(); store.undo()
        XCTAssertFalse(store.model.autoDateTime)
        XCTAssertNil(store.model.autodetectRelationships)
        XCTAssertFalse(store.report.settings.slicerApplyButtons)
        XCTAssertFalse(store.report.settings.disableCrossHighlightByDefault)
    }

    // MARK: Fixture

    /// Sales: (Secret Pen, 1000), (Ink, 234.5); [Total] = SUM(Sales[Amount]).
    private func document() -> FacetDocument {
        var doc = FacetDocument()
        var t = ModelTable(name: "Sales", columns: [ModelColumn(name: "Item", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal)])
        t.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        doc.model.tables = [t]
        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Item", "Amount"], rows: [["Secret Pen", 1000.0], ["Ink", 234.5]], types: [.text, .decimal])
        return doc
    }

    private func waitForEngine(_ store: DocumentStore) async throws {
        for _ in 0..<200 where store.computedData["Sales"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(store.computedData["Sales"], "the engine loaded")
    }
}
