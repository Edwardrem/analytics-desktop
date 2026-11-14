import XCTest
import SwiftUI
import FacetCore
@testable import MicrosoftPowerBI

/// The narrative's Values well and live values: the well's measures go with the prompt, the figures the assistant
/// quotes from them become tokens that follow the filters, and a token's field or format can be changed or the
/// token turned back into plain text, each as one undoable change.
@MainActor
final class NarrativeValuesTests: XCTestCase {
    private let total = ReportFixture.total

    override func setUp() async throws {
        Features.registerAll()
    }

    override func tearDown() async throws {
        AssistantStub.uninstall()
    }

    /// The fixture with a chart and a narrative whose Values well holds Total (150 unfiltered).
    private func store() async -> (DocumentStore, UUID) {
        let store = ReportFixture.store()
        let chart = ReportFixture.chart("Amount by region")
        var narrative = VisualSpec(type: .narrative, frame: Frame(x: 464, y: 24, width: 300, height: 200), name: "Narrative")
        narrative.wells[Well.values.rawValue] = [total]
        let page = store.pageIndex
        store.mutate("Add Visuals", invalidates: .visuals(nil)) { $0.report.pages[page].visuals += [chart, narrative] }
        await Smoke.settle(store)
        return (store, narrative.id)
    }

    private func spec(_ store: DocumentStore, _ id: UUID) throws -> VisualSpec { try XCTUnwrap(store.visual(id)) }

    func testTheNarrativeHasAValuesWellAndQnAStillHasNone() {
        XCTAssertEqual(VisualType.narrative.wells, [.values])
        XCTAssertEqual(VisualType.qna.wells, [])
    }

    func testTheValuesWellGoesWithThePrompt() async throws {
        let (store, narrative) = await store()
        let current = NarrativeValues.current(try spec(store, narrative), data: try XCTUnwrap(store.visualData[narrative]))
        XCTAssertEqual(current.map(\.field.key), [total.key])
        XCTAssertEqual(current.first?.value.asDouble, 150)
        AssistantStub.install(replies: ["Total is 150."])
        _ = try await NarrativeAssistant.generate(prompt: "Summarize", scope: .page, excluding: narrative, store: store)
        let sent = AssistantStub.messageTexts(try XCTUnwrap(AssistantStubProtocol.seen.first)).joined(separator: "\n")
        XCTAssertTrue(sent.hasSuffix("Mention each of these values, written exactly as shown:\n<values>\nTotal: 150\n</values>"), sent)
    }

    func testKeptFiguresBecomeLiveValuesThatFollowTheFilters() async throws {
        let (store, narrative) = await store()
        XCTAssertTrue(NarrativeAssistant.keep("Total sales were 150, well above 1,150 or 150.5 elsewhere.", prompt: "Summarize",
                                              scope: .page, visual: narrative, store: store))
        let kept = try spec(store, narrative)
        let values = NarrativeValues.values(kept)
        XCTAssertEqual(values.count, 1)
        let value = try XCTUnwrap(values.first)
        XCTAssertEqual(value.field.key, total.key)
        XCTAssertEqual(value.written, "150")
        XCTAssertEqual(NarrativeAssistant.text(kept), "Total sales were \(NarrativeValues.token(value.id)), well above 1,150 or 150.5 elsewhere.",
                       "only the standalone figure becomes a value")
        XCTAssertEqual(store.undoName, "Write Narrative")

        // North: 10 + 20. No assistant request is needed for the value to follow.
        AssistantStub.install(replies: [])
        let page = store.pageIndex
        var filter = FilterSpec(field: ReportFixture.region)
        filter.values = [.string("North")]
        store.mutate("Filter", invalidates: .visuals(nil)) { $0.report.pages[page].filters = [filter] }
        await Smoke.settle(store)
        let data = try XCTUnwrap(store.visualData[narrative])
        XCTAssertEqual(NarrativeValues.plain(NarrativeAssistant.text(kept), spec: kept, data: data),
                       "Total sales were 30, well above 1,150 or 150.5 elsewhere.")
        XCTAssertTrue(AssistantStubProtocol.seen.isEmpty)
    }

    func testAValueCanChangeItsFormatAndFieldAndBeUndone() async throws {
        let (store, narrative) = await store()
        NarrativeAssistant.keep("Total is 150.", prompt: "Summarize", scope: .page, visual: narrative, store: store)
        let id = try XCTUnwrap(NarrativeValues.values(try spec(store, narrative)).first?.id)
        let data = try XCTUnwrap(store.visualData[narrative])

        NarrativeValues.change(id, format: "$#,0.00", visual: narrative, store: store)
        XCTAssertEqual(store.undoName, "Change Narrative Value")
        var current = try spec(store, narrative)
        XCTAssertEqual(NarrativeValues.plain(NarrativeAssistant.text(current), spec: current, data: data), "Total is $150.00.")

        // A field outside the Values well joins it, so the value has data.
        NarrativeValues.change(id, field: ReportFixture.destination, visual: narrative, store: store)
        current = try spec(store, narrative)
        XCTAssertEqual(current.fields(.values).map(\.key), [total.key, ReportFixture.destination.key])
        XCTAssertEqual(NarrativeValues.values(current).first?.field.key, ReportFixture.destination.key)
        await Smoke.settle(store)
        current = try spec(store, narrative)
        let after = try XCTUnwrap(store.visualData[narrative])
        // Destination is "Details" once the total passes 100; its format override does not apply to text.
        XCTAssertEqual(NarrativeValues.plain(NarrativeAssistant.text(current), spec: current, data: after), "Total is Details.")

        store.undo()
        current = try spec(store, narrative)
        XCTAssertEqual(current.fields(.values).map(\.key), [total.key])
        XCTAssertEqual(NarrativeValues.values(current).first?.format, "$#,0.00")
    }

    func testAValueWhoseFieldLeftTheWellShowsWhatWasWritten() async throws {
        let (store, narrative) = await store()
        NarrativeAssistant.keep("Total is 150.", prompt: "Summarize", scope: .page, visual: narrative, store: store)
        store.updateVisual(narrative, name: "Remove Field") { $0.wells[Well.values.rawValue] = [] }
        await Smoke.settle(store)
        let current = try spec(store, narrative)
        let value = try XCTUnwrap(NarrativeValues.values(current).first)
        let shown = NarrativeValues.display(value, spec: current, data: store.visualData[narrative] ?? VisualData())
        XCTAssertEqual(shown.text, "150")
        XCTAssertFalse(shown.isLive)
    }

    func testUseAsPlainTextFreezesTheValue() async throws {
        let (store, narrative) = await store()
        NarrativeAssistant.keep("Total is 150.", prompt: "Summarize", scope: .page, visual: narrative, store: store)
        let id = try XCTUnwrap(NarrativeValues.values(try spec(store, narrative)).first?.id)
        NarrativeValues.freeze(id, visual: narrative, store: store)
        let current = try spec(store, narrative)
        XCTAssertEqual(NarrativeAssistant.text(current), "Total is 150.")
        XCTAssertTrue(NarrativeValues.values(current).isEmpty)
        XCTAssertEqual(store.undoName, "Remove Narrative Value")
        store.undo()
        XCTAssertEqual(NarrativeValues.values(try spec(store, narrative)).count, 1)
    }

    func testUpdateKeepsAValuesIdAndFormat() async throws {
        let (store, narrative) = await store()
        NarrativeAssistant.keep("Total is 150.", prompt: "Summarize", scope: .page, visual: narrative, store: store)
        let first = try XCTUnwrap(NarrativeValues.values(try spec(store, narrative)).first)
        NarrativeValues.change(first.id, format: "#,0.00", visual: narrative, store: store)
        AssistantStub.install(replies: ["Sales total 150 this period."])
        try await NarrativeAssistant.update(visual: narrative, store: store)
        let current = try spec(store, narrative)
        XCTAssertEqual(NarrativeValues.values(current).first?.id, first.id)
        XCTAssertEqual(NarrativeValues.values(current).first?.format, "#,0.00")
        XCTAssertEqual(NarrativeValues.plain(NarrativeAssistant.text(current), spec: current, data: try XCTUnwrap(store.visualData[narrative])),
                       "Sales total 150.00 this period.")
    }

    func testTokensParseAndOnlyEditableTextLinks() throws {
        let id = UUID()
        XCTAssertEqual(NarrativeValues.pieces("A \(NarrativeValues.token(id)) b {{value:nope}} c"),
                       [.text("A "), .value(id), .text(" b {{value:nope}} c")])
        XCTAssertEqual(NarrativeValues.pieces("plain"), [.text("plain")])

        var spec = VisualSpec(type: .narrative, frame: Frame(x: 0, y: 0, width: 10, height: 10))
        spec.wells[Well.values.rawValue] = [total]
        spec.setFmt("narrative", "values", NarrativeValues.encoded([NarrativeValue(id: id, field: total, written: "150")]))
        let data = VisualData(table: DataTable(name: "", columnNames: ["Total"], rows: [[.int(150)]], types: [.integer]),
                              roles: [Well.values.rawValue: [0]], fields: [total], formats: [""])
        let text = "Total is \(NarrativeValues.token(id))."
        let editable = NarrativeValues.attributed(text, spec: spec, data: data, editable: true)
        XCTAssertEqual(String(editable.characters), "Total is 150.")
        let link = editable.runs.compactMap(\.link).first
        XCTAssertEqual(link.flatMap(NarrativeValues.valueID(from:)), id)
        XCTAssertTrue(NarrativeValues.attributed(text, spec: spec, data: data, editable: false).runs.allSatisfy { $0.link == nil })
        XCTAssertNil(NarrativeValues.valueID(from: try XCTUnwrap(URL(string: "https://example.com"))))
    }
}
