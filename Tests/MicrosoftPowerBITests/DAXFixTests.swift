import XCTest
import AppKit
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// Fix with assistant in DAX query view: a failed run remembers what failed, the request carries the query, the
/// error and the schema, the proposal passes the same checks as a written query, it shows as a line diff, and
/// accepting it replaces only the text that failed, runs it, and can be undone.
@MainActor
final class DAXFixTests: XCTestCase {
    private let failing = "EVALUATE ROW(\"x\", [Profit])"
    private let fixed = "EVALUATE ROW(\"x\", [Total])"

    /// The session holds its store weakly, so each test keeps its store here.
    private var kept: DocumentStore?

    override func setUp() async throws {
        Features.registerAll()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        AssistantStub.uninstall()
        kept = nil
    }

    /// A loaded store whose DAX session has one tab holding `text`, run once.
    private func failedRun(_ text: String) async -> (DocumentStore, DAXQuerySession, UUID) {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        kept = store
        let session = DAXQuerySession.of(store)
        let id = session.addTab(name: "Broken", text: text, run: true) ?? UUID()
        _ = await Smoke.wait(seconds: 5) { session.runs[id]?.hasRun == true && session.runs[id]?.isRunning == false }
        return (store, session, id)
    }

    func testRegistrationInstallsTheFixHook() {
        XCTAssertNotNil(DAXAssistantHook.fix, "the Fix with assistant button only shows when this hook is set")
    }

    func testAFailedRunRemembersWhatFailedAndASuccessForgetsIt() async throws {
        let (_, session, id) = await failedRun(failing)
        let run = try XCTUnwrap(session.runs[id])
        XCTAssertNotNil(run.error)
        XCTAssertEqual(run.failedText, failing)
        XCTAssertEqual(run.failedOffset, 0)

        session.setText(fixed, for: id)
        session.run(useSelection: false)
        _ = await Smoke.wait(seconds: 5) { session.runs[id]?.isRunning == false && session.runs[id]?.error == nil }
        XCTAssertNil(session.runs[id]?.error)
        XCTAssertNil(session.runs[id]?.failedText)
    }

    func testTheRequestCarriesTheQueryTheErrorAndTheSchema() async throws {
        let (store, session, id) = await failedRun(failing)
        let error = try XCTUnwrap(session.runs[id]?.error)
        AssistantStub.install(replies: ["Use the measure the model has:\n```dax\n\(fixed)\n```"])

        let proposal = try await DAXAssistant.fix(failing, error: error, store: store)
        XCTAssertEqual(proposal, fixed)

        let request = try XCTUnwrap(AssistantStubProtocol.seen.first)
        XCTAssertEqual(AssistantStubProtocol.seen.count, 1)
        let message = try XCTUnwrap(AssistantStub.messageTexts(request).first)
        XCTAssertTrue(message.contains(failing), message)
        XCTAssertTrue(message.contains(error), message)
        let system = AssistantStub.systemText(request)
        XCTAssertTrue(system.contains("Table Sales"), system)
        XCTAssertTrue(system.contains("measure [Total] = SUM(Sales[Amount])"), system)
        XCTAssertNil(request.body["tools"], "a one-shot request offers no tools")
    }

    func testAProposalThatFailsTheCheckIsSentBackThenRejected() async {
        let (store, _, _) = await failedRun(failing)
        let bad = "```dax\nEVALUATE ROW(\"x\", [Margin])\n```"
        AssistantStub.install(replies: [bad, bad, bad])
        do {
            _ = try await DAXAssistant.fix(failing, error: "Cannot find [Profit].", store: store)
            XCTFail("a proposal that does not check out must not be offered")
        } catch let e as DAXAssistantError {
            guard case .invalidQuery(let problems) = e else { return XCTFail("\(e)") }
            XCTAssertFalse(problems.isEmpty)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(AssistantStubProtocol.seen.count, 1 + DAXAssistant.repairAttempts)
    }

    func testAProposalWithoutEvaluateIsRepaired() async throws {
        let (store, _, _) = await failedRun(failing)
        AssistantStub.install(replies: ["```dax\nROW(\"x\", [Total])\n```", "```dax\n\(fixed)\n```"])
        let proposal = try await DAXAssistant.fix(failing, error: "Cannot find [Profit].", store: store)
        XCTAssertEqual(proposal, fixed)
        let seen = AssistantStubProtocol.seen
        XCTAssertEqual(seen.count, 2)
        let texts = AssistantStub.messageTexts(seen[1])
        XCTAssertEqual(texts.count, 3, "request, the rejected answer, and the problem")
        XCTAssertTrue(texts[2].contains("The query has no EVALUATE statement."), texts[2])
    }

    func testRepeatingTheQueryIsNotAFix() async {
        let (store, _, _) = await failedRun(failing)
        AssistantStub.install(replies: ["```dax\n\(fixed)\n```"])
        do {
            _ = try await DAXAssistant.fix(fixed, error: "Timed out.", store: store)
            XCTFail("the same query is not a proposal")
        } catch {
            XCTAssertEqual(error as? DAXAssistantError, .invalidQuery(["The answer repeated the failing query."]))
        }
    }

    func testWithoutAKeyNothingIsSent() async {
        let (store, _, _) = await failedRun(failing)
        AssistantStub.install(replies: ["unused"], configured: false)
        do {
            _ = try await DAXAssistant.fix(failing, error: "Cannot find [Profit].", store: store)
            XCTFail("no key, no request")
        } catch {
            XCTAssertEqual(error as? AssistantError, .notConfigured)
            XCTAssertTrue(AssistantTasks.needsSetup(error), "the notice offers Assistant settings")
        }
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
    }

    func testTheDiffKeepsCommonLinesAndMarksTheChange() {
        let old = "EVALUATE\nSUMMARIZECOLUMNS(\n    'Sales'[Country],\n    \"Total\", [Total]\n)"
        let new = "EVALUATE\nSUMMARIZECOLUMNS(\n    'Sales'[Region],\n    \"Total\", [Total]\n)"
        XCTAssertEqual(DAXDiff.lines(from: old, to: new), [
            DAXDiffLine(kind: .same, text: "EVALUATE"),
            DAXDiffLine(kind: .same, text: "SUMMARIZECOLUMNS("),
            DAXDiffLine(kind: .removed, text: "    'Sales'[Country],"),
            DAXDiffLine(kind: .added, text: "    'Sales'[Region],"),
            DAXDiffLine(kind: .same, text: "    \"Total\", [Total]"),
            DAXDiffLine(kind: .same, text: ")"),
        ])
        XCTAssertEqual(DAXDiff.lines(from: "A\nB\nC", to: "A\nX\nB\nC"), [
            DAXDiffLine(kind: .same, text: "A"), DAXDiffLine(kind: .added, text: "X"),
            DAXDiffLine(kind: .same, text: "B"), DAXDiffLine(kind: .same, text: "C"),
        ])
        XCTAssertEqual(DAXDiff.lines(from: "A\nB\nC", to: "A\nC"), [
            DAXDiffLine(kind: .same, text: "A"), DAXDiffLine(kind: .removed, text: "B"), DAXDiffLine(kind: .same, text: "C"),
        ])
        XCTAssertEqual(DAXDiff.lines(from: "A", to: "B\nC"), [
            DAXDiffLine(kind: .removed, text: "A"), DAXDiffLine(kind: .added, text: "B"), DAXDiffLine(kind: .added, text: "C"),
        ])
    }

    func testAcceptReplacesTheQueryRunsItAndUndoes() async throws {
        let (store, session, id) = await failedRun(failing)
        XCTAssertTrue(session.applyFix(fixed, tab: id, original: failing, offset: 0))
        XCTAssertEqual(session.tabs.first { $0.id == id }?.text, fixed)

        _ = await Smoke.wait(seconds: 5) { session.runs[id]?.isRunning == false && session.runs[id]?.error == nil }
        let run = try XCTUnwrap(session.runs[id])
        XCTAssertNil(run.error, "the accepted query runs")
        XCTAssertEqual(run.results.first?.rowCount, 1, "ROW returns one row")

        store.undo()
        XCTAssertEqual(session.tabs.first { $0.id == id }?.text, failing, "the fix is one undo step")
    }

    func testAcceptReplacesOnlyTheTextThatFailed() async {
        let prefix = "// Profit by row\n"
        let (_, session, id) = await failedRun(prefix + failing)
        // A selection that ran starts after the comment; the fix goes exactly there.
        XCTAssertTrue(session.applyFix(fixed, tab: id, original: failing, offset: (prefix as NSString).length))
        XCTAssertEqual(session.tabs.first { $0.id == id }?.text, prefix + fixed)
    }

    func testAcceptAfterTheQueryWasEditedChangesNothing() async {
        let (_, session, id) = await failedRun(failing)
        let edited = "EVALUATE ROW(\"y\", [Profit])"
        session.setText(edited, for: id)
        XCTAssertFalse(session.applyFix(fixed, tab: id, original: failing, offset: 0))
        XCTAssertEqual(session.tabs.first { $0.id == id }?.text, edited)
        XCTAssertFalse(session.applyFix(fixed, tab: id, original: edited, offset: 40), "a range past the end is refused")
        XCTAssertFalse(session.applyFix(fixed, tab: UUID(), original: edited, offset: 0), "another tab is refused")
        XCTAssertEqual(session.tabs.first { $0.id == id }?.text, edited)
    }
}
