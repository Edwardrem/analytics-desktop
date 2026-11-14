import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Step Properties (an applied step's name and description) and the comments of a query kept through the Advanced
/// Editor and the Applied Steps edits. Power Query keeps a step's description as the `//` lines above the step.
@MainActor
final class StepPropertiesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "StepPropertiesTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private static let table = "let\n    Source = #table({\"A\", \"B\"}, {{1, \"x\"}, {2, \"y\"}, {3, \"z\"}}),\n    #\"Kept First Rows\" = Table.FirstN(Source, 2)\nin\n    #\"Kept First Rows\""
    private static let commented = """
    // Sales by region
    let
        // Three regions
        Source = #table({"Region", "Amount"}, {{"North", 10}, {"South", 20}, {"East", 5}}),
        // Only the big ones
        Big = Table.SelectRows(Source, each [Amount] > 6) // more than 6
    in
        Big
    """

    private func session(_ script: String) async -> QueryEditorSession {
        var doc = FacetDocument()
        doc.queries = [QueryDefinition(name: "T", mScript: script)]
        let s = QueryEditorSession(store: DocumentStore(document: doc, services: .live()), security: QuerySecurity(defaults: defaults))
        s.refreshPreview()
        await s.waitForPreview()
        return s
    }
    private func script(_ s: QueryEditorSession) -> String { s.selectedQuery?.mScript ?? "" }

    func testPropertiesSetTheNameAndDescriptionAsOneStep() async throws {
        let s = await session(Self.table)
        XCTAssertNil(s.setStepProperties(at: 1, name: " Top Two ", description: "The first two rows\nof the table"))
        XCTAssertEqual(script(s), """
        let
            Source = #table({"A", "B"}, {{1, "x"}, {2, "y"}, {3, "z"}}),
            // The first two rows
            // of the table
            #"Top Two" = Table.FirstN(Source, 2)
        in
            #"Top Two"
        """)
        XCTAssertEqual(s.steps.map(\.name), ["Source", "Top Two"])
        XCTAssertEqual(s.steps[1].description, "The first two rows\nof the table")
        XCTAssertEqual(s.undoName, "Step Properties")

        s.undo()
        XCTAssertEqual(script(s), Self.table, "the name and the description come back together")
        XCTAssertNil(s.undoName)
        s.redo()
        XCTAssertEqual(s.steps[1].name, "Top Two")
        XCTAssertEqual(s.steps[1].description, "The first two rows\nof the table")

        // Clearing the description removes its lines and leaves the name.
        XCTAssertNil(s.setStepProperties(at: 1, name: "Top Two", description: ""))
        XCTAssertEqual(script(s), Self.table.replacingOccurrences(of: "Kept First Rows", with: "Top Two"))
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.rowCount, 2)
    }

    func testPropertiesRefuseANameInUseOrNoName() async throws {
        let s = await session(Self.table)
        XCTAssertEqual(s.setStepProperties(at: 1, name: "Source", description: "x"), "The query already has a step named “Source”.")
        XCTAssertEqual(s.setStepProperties(at: 1, name: "  ", description: "x"), "A step needs a name.")
        XCTAssertNil(s.setStepProperties(at: 1, name: "Kept First Rows", description: ""), "nothing changed is no problem")
        XCTAssertNil(s.setStepProperties(at: 7, name: "Gone", description: "x"), "a step that isn't there changes nothing")
        XCTAssertEqual(script(s), Self.table)
        XCTAssertNil(s.undoName, "and adds no undo step")
    }

    func testTheAdvancedEditorAndStepEditsKeepTheComments() async throws {
        let s = await session(Self.table)
        XCTAssertNil(s.setScript(Self.commented))
        XCTAssertEqual(script(s), Self.commented, "the Advanced Editor keeps the text as written")
        XCTAssertEqual(s.steps.map(\.description), ["Three regions", "Only the big ones"])

        s.renameStep(at: 0, to: "Regions")
        s.apply(.reverseRows)
        XCTAssertEqual(script(s), """
        // Sales by region
        let
            // Three regions
            Regions = #table({"Region", "Amount"}, {{"North", 10}, {"South", 20}, {"East", 5}}),
            // Only the big ones
            Big = Table.SelectRows(Regions, each [Amount] > 6), // more than 6
            #"Reversed Rows" = Table.ReverseRows(Big)
        in
            #"Reversed Rows"
        """)

        s.selectStep(1)
        XCTAssertNil(s.setStepExpression("= Table.SelectRows(Regions, each [Amount] > 15)"))
        s.deleteUntilEnd(from: 2)
        XCTAssertEqual(script(s), """
        // Sales by region
        let
            // Three regions
            Regions = #table({"Region", "Amount"}, {{"North", 10}, {"South", 20}, {"East", 5}}),
            // Only the big ones
            Big = Table.SelectRows(Regions, each [Amount] > 15) // more than 6
        in
            Big
        """)
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.column("Region")?.values, [.string("South")])

        // The Advanced Editor's Format lays the script out and keeps its comments too.
        let formatted = MScript.format(Self.commented)
        XCTAssertEqual(MScript.steps(of: formatted).map(\.description), ["Three regions", "Only the big ones"])
        XCTAssertEqual(MScript.steps(of: formatted).last?.trailingComment, "// more than 6")
        XCTAssertTrue(formatted.hasPrefix("// Sales by region\n"), formatted)
    }
}
