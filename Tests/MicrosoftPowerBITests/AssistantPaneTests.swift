import XCTest
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// The Assistant pane's conversation against a stubbed Messages API: the model description is the cached
/// context, the summary shortcuts send the page or report with its current values, a question that matches a
/// verified answer is answered from it, and without a key nothing is sent.
@MainActor
final class AssistantPaneTests: XCTestCase {
    override func setUp() async throws {
        Features.registerAll()
    }

    override func tearDown() async throws {
        AssistantStub.uninstall()
    }

    /// The fixture with a "Amount by region" chart on its first page.
    private func store() async -> (DocumentStore, VisualSpec) {
        let store = ReportFixture.store()
        var chart = ReportFixture.chart("Amount by region")
        chart.frame = Frame(x: 24, y: 24, width: 420, height: 280)
        let page = store.pageIndex
        store.mutate("Add Chart", invalidates: .visuals(nil)) { $0.report.pages[page].visuals.append(chart) }
        await Smoke.settle(store)
        return (store, chart)
    }

    private func finish(_ model: AssistantPaneModel) async {
        let done = await Smoke.wait { !model.isStreaming }
        XCTAssertTrue(done, "the turn finished")
    }

    func testSummarizePageSendsThePageWithItsValues() async throws {
        let (store, _) = await store()
        AssistantStub.install(replies: ["South leads with 70."])
        let model = AssistantPaneModel.of(store)
        XCTAssertTrue(model === AssistantPaneModel.of(store), "the pane and the commands share one conversation")
        model.summarizePage()
        await finish(model)

        XCTAssertEqual(model.transcript.map(\.text), ["Summarize the page \"Page 1\"", "South leads with 70."])
        let request = try XCTUnwrap(AssistantStubProtocol.seen.first)
        let sent = AssistantStub.messageTexts(request).joined(separator: "\n")
        XCTAssertTrue(sent.contains("<page>\nPage: Page 1"), sent)
        XCTAssertTrue(sent.contains("South | 70"), "the chart's current values go with the request")
        XCTAssertTrue(sent.contains("The user is looking at the report page \"Page 1\""), "a note says which page is open")
        let system = AssistantStub.systemText(request)
        XCTAssertTrue(system.contains("[Total] = SUM(Sales[Amount])"), "the model description is the context")
        XCTAssertEqual((request.body["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.count, 7)
    }

    func testSummarizeReportCoversEveryVisiblePage() async throws {
        let (store, _) = await store()
        store.addPage(named: "Details")
        store.mutate("Hide", invalidates: .layout) { d in
            if let i = d.report.pages.firstIndex(where: { $0.name == "Details" }) { d.report.pages[i].isHidden = true }
        }
        AssistantStub.install(replies: ["One page."])
        let model = AssistantPaneModel.of(store)
        model.summarizeReport()
        await finish(model)
        let sent = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        XCTAssertTrue(sent.contains("<report>\nReport: 1 page"), "the hidden page is left out: \(sent)")
        XCTAssertTrue(sent.contains("South | 70"))
    }

    func testAQuestionMatchingAVerifiedAnswerIsAnsweredFromIt() async throws {
        let (store, chart) = await store()
        store.mutate("Verify", invalidates: .layout) { d in
            var a = VerifiedAnswer(question: "What is the amount by region?")
            a.visualID = chart.id
            a.answer = "South sells the most."
            d.model.verifiedAnswers = [a]
        }
        AssistantStub.install(replies: ["South, with 70 (verified)."])
        let model = AssistantPaneModel.of(store)
        model.input = "show me amount by region"
        model.send()
        await finish(model)

        let verified = try XCTUnwrap(model.transcript.first { $0.role == .verified }?.verified)
        XCTAssertEqual(verified.question, "What is the amount by region?")
        XCTAssertEqual(verified.visualID, chart.id)
        XCTAssertEqual(verified.visualTitle, "Amount by region")
        let sent = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        XCTAssertTrue(sent.contains("Verified question: What is the amount by region?"), sent)
        XCTAssertTrue(sent.contains("Approved answer: South sells the most."), sent)
        XCTAssertTrue(sent.contains("South | 70"), "the verified visual's values go with it")

        store.addPage(named: "Other")
        model.show(verified)
        XCTAssertEqual(store.currentPage.name, "Page 1")
        XCTAssertEqual(store.selection, [chart.id])
    }

    func testAnUnrelatedQuestionIsNotTreatedAsVerified() async throws {
        let (store, chart) = await store()
        store.mutate("Verify", invalidates: .layout) { d in
            var a = VerifiedAnswer(question: "What is the amount by region?")
            a.visualID = chart.id
            d.model.verifiedAnswers = [a]
        }
        AssistantStub.install(replies: ["Three channels."])
        let model = AssistantPaneModel.of(store)
        model.send("How many channels are there?")
        await finish(model)
        XCTAssertFalse(model.transcript.contains { $0.role == .verified })
        let sent = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        XCTAssertFalse(sent.contains("Verified question"))
    }

    func testAModelChangeIsToldToTheConversation() async throws {
        let (store, _) = await store()
        AssistantStub.install(replies: ["First.", "Second."])
        let model = AssistantPaneModel.of(store)
        model.send("Hello")
        await finish(model)
        ModelOps.updateMeasures(store, [("Sales", "Total")], name: "Describe") { $0.description = "All sales." }
        model.send("And now?")
        await finish(model)
        let seen = AssistantStubProtocol.seen
        XCTAssertEqual(seen.count, 2)
        let second = AssistantStub.messageTexts(seen[1]).joined(separator: "\n")
        XCTAssertTrue(second.contains("The data model changed since the conversation started"), second)
        XCTAssertTrue(second.contains("All sales."), "the new description is included")
        XCTAssertEqual(second.components(separatedBy: "The user is looking at").count - 1, 1,
                       "the page note from the first turn is in the history; the page did not change, so it is not repeated")
    }

    func testWithoutAKeyNothingIsSentAndTheSetupMessageShows() async throws {
        let (store, _) = await store()
        AssistantStub.install(replies: ["unused"], configured: false)
        let model = AssistantPaneModel.of(store)
        XCTAssertFalse(model.hasKey, "the pane shows its setup card")
        model.summarizePage()
        XCTAssertEqual(model.error, AssistantTasks.setupMessage)
        XCTAssertFalse(model.isStreaming)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
    }

    func testSummaryCommandsOpenThePaneAndAsk() async throws {
        let (store, _) = await store()
        AssistantStub.install(replies: ["Summary."])
        let command = try XCTUnwrap(AppCommands.command(AIFeature.summarizePageID))
        XCTAssertNotNil(AppCommands.command(AIFeature.summarizeReportID))
        AppCommands.perform(command, store)
        XCTAssertEqual(store.inspector, .assistant)
        XCTAssertTrue(store.inspectorVisible)
        let model = AssistantPaneModel.of(store)
        await finish(model)
        XCTAssertEqual(model.transcript.last?.text, "Summary.")
    }
}
