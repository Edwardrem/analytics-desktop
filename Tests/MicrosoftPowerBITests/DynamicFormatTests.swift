import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Format ▸ Dynamic for measures: the editor's starting text and preview, the document change, the
/// command, and the format a visual shows.
@MainActor
final class DynamicFormatTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    func testTheEditorStartsFromTheStaticFormat() {
        var m = Measure(name: "Total", expression: "SUM(Sales[Amount])", formatString: "#,0 \"units\"")
        XCTAssertEqual(DynamicFormat.initialExpression(for: m), "\"#,0 \"\"units\"\"\"")
        m.formatExpression = "\"0\""
        XCTAssertEqual(DynamicFormat.initialExpression(for: m), "\"0\"")
    }

    func testThePreviewReadsTheSelectedMeasureAsTheMeasure() {
        let m = Measure(name: "Total", expression: "1", formatString: "#,0")
        let source = """
        IF(SELECTEDMEASURE () > 1, "SELECTEDMEASURE()", SELECTEDMEASURENAME() & SelectedMeasureFormatString())
        // SELECTEDMEASURE()
        & ISSELECTEDMEASURE([Total]) & 'SELECTEDMEASURE()'[x] & [SELECTEDMEASURE()]
        """
        XCTAssertEqual(DynamicFormat.previewExpression(source, measure: m, reference: "[Total]"), """
        IF([Total] > 1, "SELECTEDMEASURE()", "Total" & "#,0")
        // SELECTEDMEASURE()
        & ISSELECTEDMEASURE([Total]) & 'SELECTEDMEASURE()'[x] & [SELECTEDMEASURE()]
        """)
    }

    private func store() -> DocumentStore {
        let store = DocumentStore(services: .live())
        store.installTables([DataTable(name: "Sales", columnNames: ["Region", "Amount"], rows: [["East", 400], ["West", 800]], types: [.text, .integer])])
        store.updateModel("Measure") { m in
            if let i = m.tableIndex("Sales") { m.tables[i].measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])", formatString: "0")] }
        }
        store.view = .model
        store.modeling.select(.measure(table: "Sales", name: "Total"))
        return store
    }

    func testSettingAndRemovingTheExpressionIsOneUndoStepEach() {
        let store = store()
        DynamicFormat.set(store, table: "Sales", measure: "Total", expression: "\"#,0\"")
        XCTAssertEqual(store.model.table("Sales")?.measure("Total")?.formatExpression, "\"#,0\"")
        XCTAssertEqual(AppCommands.command("model.measure.dynamicFormat")?.isOn?(store), true)
        DynamicFormat.set(store, table: "Sales", measure: "Total", expression: "  \n")
        XCTAssertNil(store.model.table("Sales")?.measure("Total")?.formatExpression, "blank text removes it")
        XCTAssertEqual(store.model.table("Sales")?.measure("Total")?.formatString, "0", "the static format stays")
        store.undo()
        XCTAssertEqual(store.model.table("Sales")?.measure("Total")?.formatExpression, "\"#,0\"")
        XCTAssertEqual(AppCommands.command("model.measure.dynamicFormat")?.isEnabled(store), true)
    }

    /// East 400, West 800: the total is 1200, East alone 400.
    func testVisualsShowTheFormatForTheirFilters() {
        let store = store()
        DynamicFormat.set(store, table: "Sales", measure: "Total", expression: "IF(SELECTEDMEASURE() >= 1000, \"#,0.00\", \"0\")")
        let service = LiveCalculation()
        XCTAssertTrue(service.load(model: store.model, data: store.doc.data, roles: [], userName: "").isEmpty)
        var card = VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 200, height: 100))
        card.setFields(.values, [.measure("Sales", "Total")])
        XCTAssertEqual(service.visualData(spec: card, request: VisualRequest()).formats.first, "#,0.00")
        var east = FilterSpec(field: .column("Sales", "Region"))
        east.values = [.string("East")]
        var request = VisualRequest()
        request.filters = [east]
        XCTAssertEqual(service.visualData(spec: card, request: request).formats.first, "0")
    }
}
