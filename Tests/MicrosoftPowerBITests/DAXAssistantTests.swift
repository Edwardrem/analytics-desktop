import XCTest
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// The assistant in DAX query view: Explain and Ask are wired, a written query must parse and use only names the
/// model has before it reaches a tab, and without a key the features say how to set one up.
@MainActor
final class DAXAssistantTests: XCTestCase {
    override func setUp() async throws {
        Features.registerAll()
    }

    override func tearDown() async throws {
        AssistantStub.uninstall()
    }

    private func loadedStore() async -> DocumentStore {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        return store
    }

    func testRegistrationInstallsBothHooks() {
        XCTAssertNotNil(DAXAssistantHook.explain, "the Explain button only shows when this hook is set")
        XCTAssertNotNil(DAXAssistantHook.write, "the Ask assistant button only shows when this hook is set")
    }

    func testWrittenQueryThatChecksOutIsReturnedWithoutTheFence() async throws {
        let store = await loadedStore()
        AssistantStub.install(replies: ["Here it is:\n```dax\nEVALUATE SUMMARIZECOLUMNS('Sales'[Region], \"Total\", [Total])\n```"])
        let dax = try await DAXAssistant.write("Total by region", store: store)
        XCTAssertEqual(dax, "EVALUATE SUMMARIZECOLUMNS('Sales'[Region], \"Total\", [Total])")

        let seen = AssistantStubProtocol.seen
        XCTAssertEqual(seen.count, 1)
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.headers["x-api-key"], AssistantStub.key, "the key from the key store authenticates the request")
        XCTAssertNil(request.body["tools"], "a one-shot request offers no tools")
        XCTAssertEqual(AssistantStub.messageTexts(request), ["Total by region"])
        // The model schema rides along as context, so the model can only pick real names.
        let system = AssistantStub.systemText(request)
        XCTAssertTrue(system.contains("Table Sales"), system)
        XCTAssertTrue(system.contains("measure [Total] = SUM(Sales[Amount])"), system)
    }

    func testUnknownColumnIsSentBackAndTheRepairIsUsed() async throws {
        let store = await loadedStore()
        AssistantStub.install(replies: [
            "```dax\nEVALUATE SUMMARIZECOLUMNS('Sales'[Country], \"Total\", [Total])\n```",
            "```dax\nEVALUATE SUMMARIZECOLUMNS('Sales'[Region], \"Total\", [Total])\n```",
        ])
        let dax = try await DAXAssistant.write("Total by country", store: store)
        XCTAssertEqual(dax, "EVALUATE SUMMARIZECOLUMNS('Sales'[Region], \"Total\", [Total])")

        let seen = AssistantStubProtocol.seen
        XCTAssertEqual(seen.count, 2, "one repair round")
        let texts = AssistantStub.messageTexts(seen[1])
        XCTAssertEqual(texts.count, 3, "request, the rejected answer, and the problems")
        XCTAssertTrue(texts[2].contains("Column 'Country' cannot be found in table 'Sales'."), texts[2])
    }

    func testQueriesThatNeverCheckOutAreNotPlaced() async throws {
        let store = await loadedStore()
        let bad = "```dax\nEVALUATE ROW(\"x\", [Profit])\n```"
        AssistantStub.install(replies: [bad, bad, bad])
        do {
            _ = try await DAXAssistant.write("Profit", store: store)
            XCTFail("an invalid query must not be returned")
        } catch let e as DAXAssistantError {
            guard case .invalidQuery(let problems) = e else { return XCTFail("\(e)") }
            XCTAssertFalse(problems.isEmpty)
        }
        XCTAssertEqual(AssistantStubProtocol.seen.count, 1 + DAXAssistant.repairAttempts)
    }

    func testAnswerWithoutEvaluateFailsTheCheck() async {
        let store = await loadedStore()
        let problems = await DAXAssistant.validate("SUM(Sales[Amount])", store: store)
        XCTAssertEqual(problems, ["The query has no EVALUATE statement."])
        let fine = await DAXAssistant.validate("DEFINE MEASURE Sales[Twice] = [Total] * 2\nEVALUATE ROW(\"t\", [Twice])", store: store)
        XCTAssertEqual(fine, [], "a measure defined in the query counts as known")
    }

    func testExplainSendsTheQueryAndReturnsTheAnswer() async throws {
        let store = await loadedStore()
        AssistantStub.install(replies: ["Returns the total of Amount for each region."])
        let text = try await DAXAssistant.explain("EVALUATE SUMMARIZECOLUMNS('Sales'[Region], \"Total\", [Total])", store: store)
        XCTAssertEqual(text, "Returns the total of Amount for each region.")
        let request = try XCTUnwrap(AssistantStubProtocol.seen.first)
        XCTAssertTrue(AssistantStub.messageTexts(request)[0].contains("SUMMARIZECOLUMNS('Sales'[Region]"))
    }

    func testExplainingNothingSaysSo() async {
        let store = await loadedStore()
        AssistantStub.install(replies: [])
        do {
            _ = try await DAXAssistant.explain("   \n", store: store)
            XCTFail("an empty query has nothing to explain")
        } catch {
            XCTAssertEqual(error as? DAXAssistantError, .emptyQuery)
        }
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty, "nothing is sent")
    }

    func testWithoutAKeyNothingIsSentAndTheMessageSaysWhereToAddOne() async {
        let store = await loadedStore()
        AssistantStub.install(replies: ["unused"], configured: false)
        do {
            _ = try await DAXAssistant.write("Total by region", store: store)
            XCTFail("no key, no request")
        } catch {
            XCTAssertEqual(error as? AssistantError, .notConfigured)
            XCTAssertTrue(AssistantTasks.needsSetup(error))
            XCTAssertTrue(AssistantTasks.message(error).contains("Assistant settings"), AssistantTasks.message(error))
        }
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
        XCTAssertFalse(AssistantTasks.isConfigured)
    }

    func testQueryExtractionAndTabNames() {
        XCTAssertEqual(DAXAssistant.extractQuery("EVALUATE ROW(\"a\", 1)"), "EVALUATE ROW(\"a\", 1)")
        XCTAssertEqual(DAXAssistant.extractQuery("Sure.\n```\nEVALUATE Sales\n```\nDone."), "EVALUATE Sales")
        XCTAssertEqual(DAXAssistant.extractQuery("```dax\nEVALUATE Sales"), "EVALUATE Sales", "an unclosed fence runs to the end")
        XCTAssertEqual(DAXAssistant.tabName(for: "Top 10 products by sales this year in Europe"), "Top 10 products by sales this")
        XCTAssertEqual(DAXAssistant.tabName(for: "   "), "Assistant query")
    }
}
