import XCTest
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// Measure descriptions from the assistant: the formula goes out with the model as context, the answer is cleaned,
/// and Keep stores it on the measure as one undoable change.
@MainActor
final class MeasureDescriptionTests: XCTestCase {
    override func setUp() async throws {
        Features.registerAll()
    }

    override func tearDown() async throws {
        AssistantStub.uninstall()
    }

    private func description(_ store: DocumentStore, _ measure: String = "Total") -> String? {
        store.model.table("Sales")?.measure(measure)?.description
    }

    func testGeneratedDescriptionIsCleanedAndKeptAsOneUndoableChange() async throws {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        AssistantStub.install(replies: ["Description: \"Total sales amount across every region and channel.\""])

        let text = try await MeasureDescriptions.generate(table: "Sales", measure: "Total", store: store)
        XCTAssertEqual(text, "Total sales amount across every region and channel.")
        let request = try XCTUnwrap(AssistantStubProtocol.seen.first)
        let prompt = AssistantStub.messageTexts(request).first ?? ""
        XCTAssertTrue(prompt.contains("Measure [Total] in table 'Sales'"), prompt)
        XCTAssertTrue(prompt.contains("SUM(Sales[Amount])"), "the formula is what gets described")

        XCTAssertTrue(MeasureDescriptions.apply(text, table: "Sales", measure: "Total", store: store))
        XCTAssertEqual(description(store), "Total sales amount across every region and channel.")
        XCTAssertEqual(store.undoName, "Generate Description")
        store.undo()
        XCTAssertEqual(description(store), "", "undo puts the old description back")
    }

    func testTheCurrentDescriptionIsOfferedForImprovement() async throws {
        let store = ReportFixture.store()
        ModelOps.updateMeasures(store, [("Sales", "Total")], name: "Describe") { $0.description = "Sum of amount" }
        AssistantStub.install(replies: ["Total sales amount."])
        _ = try await MeasureDescriptions.generate(table: "Sales", measure: "Total", store: store)
        let prompt = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).first ?? ""
        XCTAssertTrue(prompt.contains("Current description, to improve on: Sum of amount"), prompt)
    }

    func testNothingIsStoredOnAMeasureThatIsGoneOrForEmptyText() {
        let store = ReportFixture.store()
        XCTAssertFalse(MeasureDescriptions.apply("Some text", table: "Sales", measure: "Missing", store: store))
        XCTAssertFalse(MeasureDescriptions.apply("   ", table: "Sales", measure: "Total", store: store))
        XCTAssertEqual(store.undoName, "Load", "no change was recorded")
    }

    func testAMissingMeasureOrAMissingKeyIsAnErrorBeforeAnythingIsSent() async {
        let store = ReportFixture.store()
        AssistantStub.install(replies: ["unused"], configured: false)
        do {
            _ = try await MeasureDescriptions.generate(table: "Sales", measure: "Missing", store: store)
            XCTFail("no measure, no request")
        } catch { XCTAssertEqual(error as? MeasureDescriptionError, .missing("Missing")) }
        do {
            _ = try await MeasureDescriptions.generate(table: "Sales", measure: "Total", store: store)
            XCTFail("no key, no request")
        } catch { XCTAssertTrue(AssistantTasks.needsSetup(error)) }
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
    }

    func testCommandOpensTheReviewSheetForTheDataPaneMeasure() {
        let store = ReportFixture.store()
        let command = AppCommands.command(MeasureDescriptions.commandID)
        XCTAssertNotNil(command, "registered, so the Data pane menu and the Measure tools ribbon show it")
        XCTAssertNil(store.sheet)
        FieldPaneContext.run(MeasureDescriptions.commandID, table: "Sales", field: .measure("Sales", "Total"), store)
        XCTAssertNotNil(store.sheet, "the review sheet opens; nothing is sent until Generate")
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
    }

    func testCleaningKeepsOnlyTheDescription() {
        XCTAssertEqual(MeasureDescriptions.clean("  “Average order value.”  "), "Average order value.")
        XCTAssertEqual(MeasureDescriptions.clean("```\nAverage\n  order value.\n```"), "Average order value.")
        XCTAssertEqual(MeasureDescriptions.clean("Revenue minus cost, as a share of revenue."), "Revenue minus cost, as a share of revenue.")
    }
}
