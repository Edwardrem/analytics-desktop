import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Close & Apply is one undo step, as Get Data's load is: renamed tables, the query changes and the load of the
/// changed queries come back together. Also the store's undo groups that make it so.
@MainActor
final class ApplyQueryChangesUndoTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "ApplyQueryChangesUndoTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private static let table = "let\n    Source = #table({\"A\", \"B\"}, {{1, \"x\"}, {2, \"y\"}, {3, \"z\"}})\nin\n    Source"
    private static let extra = "let\n    Source = #table({\"K\"}, {{7}})\nin\n    Source"

    /// T and Staging both loaded, as after Get Data.
    private func store() -> DocumentStore {
        var doc = FacetDocument()
        doc.queries = [QueryDefinition(name: "T", mScript: Self.table), QueryDefinition(name: "Staging", mScript: Self.table)]
        for name in ["T", "Staging"] {
            doc.data[name] = DataTable(columnNames: ["A", "B"], rows: [[.int(1), .string("x")]], types: [.integer, .text])
            var m = ModelTable(name: name, columns: [ModelColumn(name: "A", dataType: .integer), ModelColumn(name: "B", dataType: .text)])
            m.sourceQuery = name
            doc.model.tables.append(m)
        }
        return DocumentStore(document: doc, services: .live())
    }

    private func waitForData(_ store: DocumentStore, _ table: String) async throws {
        for _ in 0..<250 where store.doc.data[table] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(store.doc.data[table], "\(table) never loaded")
    }

    func testCloseAndApplyIsOneUndoStep() async throws {
        let store = store()
        let s = QueryEditorSession(store: store, security: QuerySecurity(defaults: defaults))
        s.renameQuery(s.queries[0].id, to: "Facts")              // renames the table T feeds
        s.setLoadEnabled(s.queries[1].id, false)                 // removes the Staging table
        s.addQuery(QueryDefinition(name: "Extra", mScript: Self.extra), name: "New")   // loads a new table
        s.applyChanges()
        try await waitForData(store, "Extra")

        XCTAssertEqual(store.doc.model.tables.map(\.name).sorted(), ["Extra", "Facts"])
        XCTAssertEqual(store.undoName, "Apply Query Changes")

        store.undo()
        XCTAssertEqual(store.doc.queries.map(\.name), ["T", "Staging"])
        XCTAssertEqual(store.doc.model.tables.map(\.name), ["T", "Staging"])
        XCTAssertNil(store.doc.data["Extra"])
        XCTAssertNotNil(store.doc.data["T"])
        XCTAssertNil(store.undoName, "the rename, the query changes and the load were one step")
        XCTAssertEqual(store.redoName, "Apply Query Changes")

        store.redo()
        XCTAssertEqual(store.doc.queries.map(\.name), ["Facts", "Staging", "Extra"])
        XCTAssertEqual(store.doc.data["Extra"]?.column("K")?.values, [.int(7)])
        XCTAssertNil(store.doc.data["Staging"])
    }

    func testAChangeMadeBeforeTheLoadLandsKeepsItsOwnStep() async throws {
        let store = store()
        let s = QueryEditorSession(store: store, security: QuerySecurity(defaults: defaults))
        s.addQuery(QueryDefinition(name: "Extra", mScript: Self.extra), name: "New")
        s.applyChanges()
        // Nothing has suspended yet, so the load hasn't finished: this edit comes between Apply and the load.
        store.mutate("Rename Page", invalidates: .layout) { $0.report.pages[0].name = "Overview" }
        try await waitForData(store, "Extra")

        XCTAssertEqual(store.undoName, "Refresh Data", "the load can't join a step that is no longer the latest")
        store.undo()
        XCTAssertNil(store.doc.data["Extra"])
        XCTAssertEqual(store.doc.report.pages[0].name, "Overview")
        XCTAssertEqual(store.undoName, "Rename Page")
        store.undo()
        XCTAssertEqual(store.undoName, "Apply Query Changes")
        store.undo()
        XCTAssertEqual(store.doc.queries.map(\.name), ["T", "Staging"])
        XCTAssertNil(store.undoName)
    }

    func testAnUndoGroupNamesItsOneStepAndLaterWritesCanJoinIt() {
        let store = store()
        let group = store.undoGroup("Tidy Model") {
            store.mutate("Hide Table") { $0.model.tables[0].isHidden = true }
            store.mutate("Describe Table") { $0.model.tables[1].description = "staging" }
        }
        XCTAssertEqual(store.undoName, "Tidy Model")
        store.mutate("Load", joining: group) { $0.model.tables[0].description = "facts" }
        XCTAssertEqual(store.undoName, "Tidy Model")
        store.undo()
        XCTAssertEqual(store.doc.model.tables.map(\.isHidden), [false, false])
        XCTAssertEqual(store.doc.model.tables.map(\.description), ["", ""])
        XCTAssertNil(store.undoName)

        // An inner group joins the outer one.
        store.undoGroup("Outer") {
            store.mutate("A") { $0.model.tables[0].isHidden = true }
            store.undoGroup("Inner") { store.mutate("B") { $0.model.tables[1].isHidden = true } }
        }
        XCTAssertEqual(store.undoName, "Outer")
        store.undo()
        XCTAssertEqual(store.doc.model.tables.map(\.isHidden), [false, false])

        // A group with no writes adds no step; joining it later starts a step of its own.
        let empty = store.undoGroup("Nothing") {}
        XCTAssertNil(store.undoName)
        store.mutate("Late", joining: empty) { $0.model.tables[0].isHidden = true }
        XCTAssertEqual(store.undoName, "Late")
    }
}
