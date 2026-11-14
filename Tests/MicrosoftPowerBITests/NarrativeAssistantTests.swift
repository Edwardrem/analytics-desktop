import XCTest
import AppKit
import SwiftUI
import FacetCore
import FacetCloud
import FacetVisuals
@testable import MicrosoftPowerBI

/// The narrative visual written by the assistant from a prompt: the page's current values go with the prompt
/// (never the narrative itself), the answer is cleaned to prose, Keep stores it as one undoable change, and a
/// change in the page's numbers is noticed so the text can be rewritten.
@MainActor
final class NarrativeAssistantTests: XCTestCase {
    override func setUp() async throws {
        Features.registerAll()
    }

    override func tearDown() async throws {
        AssistantStub.uninstall()
    }

    /// The fixture with an "Amount by region" chart and a narrative visual on its first page.
    private func store() async -> (DocumentStore, UUID) {
        let store = ReportFixture.store()
        var chart = ReportFixture.chart("Amount by region")
        chart.frame = Frame(x: 24, y: 24, width: 420, height: 280)
        let narrative = VisualSpec(type: .narrative, frame: Frame(x: 464, y: 24, width: 300, height: 200), name: "Narrative")
        let page = store.pageIndex
        store.mutate("Add Visuals", invalidates: .visuals(nil)) { $0.report.pages[page].visuals += [chart, narrative] }
        await Smoke.settle(store)
        return (store, narrative.id)
    }

    func testThePromptGoesWithThePageValuesAndTheAnswerIsCleaned() async throws {
        let (store, narrative) = await store()
        AssistantStub.install(replies: ["## Key insight\n\n**South** leads with 70.\n\n"])
        let text = try await NarrativeAssistant.generate(prompt: " Summarize the key insights ", scope: .page, excluding: narrative, store: store)
        XCTAssertEqual(text, "Key insight\n\nSouth leads with 70.")
        let sent = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        XCTAssertTrue(sent.hasPrefix("Summarize the key insights\n\n<page>\nPage: Page 1"), sent)
        XCTAssertTrue(sent.contains("South | 70"))
        XCTAssertFalse(sent.contains("[Narrative]"), "the narrative never describes itself")
    }

    func testReportScopeSendsEveryVisiblePage() async throws {
        let (store, narrative) = await store()
        AssistantStub.install(replies: ["Fine."])
        _ = try await NarrativeAssistant.generate(prompt: "Summarize", scope: .report, excluding: narrative, store: store)
        let sent = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        XCTAssertTrue(sent.contains("<report>\nReport: 1 page"), sent)
    }

    func testKeepStoresThePromptAndTextAsOneUndoableChange() async throws {
        let (store, narrative) = await store()
        XCTAssertTrue(NarrativeAssistant.keep("South leads.", prompt: "Summarize", scope: .report, visual: narrative, store: store))
        let spec = try XCTUnwrap(store.visual(narrative))
        XCTAssertEqual(NarrativeAssistant.text(spec), "South leads.")
        XCTAssertEqual(NarrativeAssistant.prompt(spec), "Summarize")
        XCTAssertEqual(NarrativeAssistant.scope(spec), .report)
        XCTAssertEqual(NarrativeAssistant.basis(spec), NarrativeAssistant.currentBasis(for: spec, store: store))
        XCTAssertEqual(store.undoName, "Write Narrative")
        store.undo()
        XCTAssertEqual(NarrativeAssistant.text(try XCTUnwrap(store.visual(narrative))), "")
        XCTAssertFalse(NarrativeAssistant.keep("x", prompt: "y", scope: .page, visual: UUID(), store: store), "a deleted visual keeps nothing")

        NarrativeAssistant.keep("South leads.", prompt: "Summarize", scope: .page, visual: narrative, store: store)
        NarrativeAssistant.clear(visual: narrative, store: store)
        XCTAssertEqual(NarrativeAssistant.prompt(try XCTUnwrap(store.visual(narrative))), "", "back to the on-device summary")
    }

    func testAFilterChangesTheBasisTheTextWasWrittenFrom() async throws {
        let (store, narrative) = await store()
        let before = NarrativeAssistant.currentBasis(for: try XCTUnwrap(store.visual(narrative)), store: store)
        XCTAssertEqual(before, NarrativeAssistant.currentBasis(for: try XCTUnwrap(store.visual(narrative)), store: store), "stable while nothing changes")
        let page = store.pageIndex
        var filter = FilterSpec(field: ReportFixture.region)
        filter.values = [.string("North")]
        store.mutate("Filter", invalidates: .visuals(nil)) { $0.report.pages[page].filters = [filter] }
        await Smoke.settle(store)
        XCTAssertNotEqual(NarrativeAssistant.currentBasis(for: try XCTUnwrap(store.visual(narrative)), store: store), before)
    }

    func testNoPromptOrNoKeySendsNothing() async throws {
        let (store, narrative) = await store()
        AssistantStub.install(replies: ["unused"], configured: false)
        do {
            _ = try await NarrativeAssistant.generate(prompt: "  ", scope: .page, excluding: narrative, store: store)
            XCTFail("an empty prompt is not sent")
        } catch { XCTAssertEqual(error as? NarrativeError, .emptyPrompt) }
        do {
            _ = try await NarrativeAssistant.generate(prompt: "Summarize", scope: .page, excluding: narrative, store: store)
            XCTFail("no key, no request")
        } catch { XCTAssertTrue(AssistantTasks.needsSetup(error)) }
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
    }

    func testFingerprintIsStableAcrossLaunches() {
        // FNV-1a 64 of "" is the offset basis; of "a" it is af63dc4c8601ec8c.
        XCTAssertEqual(NarrativeAssistant.fingerprint(""), "cbf29ce484222325")
        XCTAssertEqual(NarrativeAssistant.fingerprint("a"), "af63dc4c8601ec8c")
    }

    // MARK: Rewriting when the data changes

    /// Filters the page to North, so the chart's numbers differ from what the text was written from.
    private func filterToNorth(_ store: DocumentStore) async {
        let page = store.pageIndex
        var filter = FilterSpec(field: ReportFixture.region)
        filter.values = [.string("North")]
        store.mutate("Filter", invalidates: .visuals(nil)) { $0.report.pages[page].filters = [filter] }
        await Smoke.settle(store)
    }

    /// Hosts the narrative visual in an offscreen window, as the canvas does, until `condition` holds.
    private func host(_ id: UUID, _ store: DocumentStore, seconds: Double, until condition: () -> Bool) async -> Bool {
        guard let spec = store.visual(id) else { return false }
        let view = NarrativeView(spec: spec, data: VisualData(), context: VisualContext(), store: store).frame(width: 300, height: 200)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        return await Smoke.wait(seconds: seconds, until: condition)
    }

    func testRewritingIsOffByDefaultAndUpdateRewritesOnClick() async throws {
        let (store, narrative) = await store()
        AssistantStub.install(replies: ["North has 30."])
        NarrativeAssistant.keep("South leads with 70.", prompt: "Summarize", scope: .page, visual: narrative, store: store)
        await filterToNorth(store)
        let spec = try XCTUnwrap(store.visual(narrative))
        XCTAssertFalse(NarrativeAssistant.autoRewrite(spec))
        let now = NarrativeAssistant.currentBasis(for: spec, store: store)
        XCTAssertEqual(NarrativeAssistant.refreshAction(for: spec, now: now, shown: nil), .offerUpdate)

        // Shown on the canvas for longer than the settle delay, it sends nothing by itself.
        let sent = await host(narrative, store, seconds: 1.5) { !AssistantStubProtocol.seen.isEmpty }
        XCTAssertFalse(sent, "the page's data is not sent until the author clicks Update")

        let text = try await NarrativeAssistant.update(visual: narrative, store: store)
        XCTAssertEqual(text, "North has 30.")
        XCTAssertEqual(AssistantStubProtocol.seen.count, 1)
        let updated = try XCTUnwrap(store.visual(narrative))
        XCTAssertEqual(NarrativeAssistant.text(updated), "North has 30.")
        XCTAssertEqual(store.undoName, "Update Narrative")
        XCTAssertEqual(NarrativeAssistant.refreshAction(for: updated, now: NarrativeAssistant.currentBasis(for: updated, store: store), shown: nil), .none,
                       "the kept text now matches the numbers")
    }

    func testWithTheOptionOnTheVisualRewritesForDisplayOnly() async throws {
        let (store, narrative) = await store()
        AssistantStub.install(replies: ["North has 30."])
        NarrativeAssistant.keep("South leads with 70.", prompt: "Summarize", scope: .page, autoRewrite: true, visual: narrative, store: store)
        await filterToNorth(store)
        let spec = try XCTUnwrap(store.visual(narrative))
        XCTAssertEqual(NarrativeAssistant.refreshAction(for: spec, now: NarrativeAssistant.currentBasis(for: spec, store: store), shown: nil), .rewrite)

        let sent = await host(narrative, store, seconds: 10) { AssistantStubProtocol.seen.count == 1 }
        XCTAssertTrue(sent, "the visual sends the page again by itself")
        let request = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        // One row left, so it is described as name=value pairs.
        XCTAssertTrue(request.contains("Region=North, Sum of Amount=30"), request)
        XCTAssertEqual(NarrativeAssistant.text(try XCTUnwrap(store.visual(narrative))), "South leads with 70.",
                       "the rewrite is shown, not saved")
        XCTAssertEqual(store.undoName, "Filter")
    }

    func testTheOptionIsInTheFormatPane() throws {
        let property = try XCTUnwrap(FormatCatalog.visualCards(for: .narrative).flatMap(\.properties).first { $0.id == "narrative.autoRewrite" })
        XCTAssertEqual(property.label, "Rewrite when the data changes")
        XCTAssertEqual(property.defaultValue, .bool(false))
    }
}
