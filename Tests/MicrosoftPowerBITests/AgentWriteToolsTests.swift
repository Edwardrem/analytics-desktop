import XCTest
import AppKit
import FacetCore
import FacetInterop
@testable import MicrosoftPowerBI

/// The Modeling MCP server's write tools, driven through the MCP dispatcher as a client would: each change is
/// checked first, needs the user's permission in the approval dialog, and lands as one undoable edit.
@MainActor
final class AgentWriteToolsTests: XCTestCase {
    private var store: DocumentStore!
    private let id = UUID()
    private var asked: [AgentTools.AgentChange] = []
    private var allow = true

    override func setUp() async throws {
        var doc = FacetDocument()
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal)]
        sales.measures = [Measure(name: "Total", expression: "SUM ( Sales[Amount] )")]
        var regions = ModelTable(name: "Regions")
        regions.columns = [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Manager", dataType: .text)]
        doc.model.tables = [sales, regions]
        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Region", "Amount"],
                                      rows: [[.string("North"), .double(4)], [.string("South"), .double(6)]], types: [.text, .decimal])
        doc.data["Regions"] = DataTable(name: "Regions", columnNames: ["Region", "Manager"],
                                        rows: [[.string("North"), .string("Ada")], [.string("South"), .string("Ben")]], types: [.text, .text])
        var page = Page(name: "Overview")
        var card = VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 200, height: 100))
        card.wells[Well.values.rawValue] = [.measure("Sales", "Total")]
        page.visuals = [card]
        doc.report.pages = [page]
        store = DocumentStore(document: doc, services: .live())
        await Smoke.settle(store)
        let s = store!, docID = id
        AgentBridge.shared.documents = { [(docID, s)] }
        AgentBridge.shared.confirm = { [unowned self] change in asked.append(change); return allow }
    }

    override func tearDown() async throws {
        AgentBridge.shared.documents = { StoreRegistry.shared.all.compactMap { s in StoreRegistry.shared.id(of: s).map { ($0, s) } } }
        // Nothing after this test may change a document without its own stub.
        AgentBridge.shared.confirm = { _ in false }
    }

    private let dispatcher = MCPDispatcher(serverName: "test", serverVersion: "1", tools: { AgentTools.all })

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> (text: String, isError: Bool) {
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                                          "params": .object(["name": .string(name), "arguments": .object(arguments)])])
        let handled = await dispatcher.handle(request)
        let reply = try XCTUnwrap(handled)
        let result = try XCTUnwrap(reply["result"])
        return (result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result["isError"] == .bool(true))
    }

    /// Calls a tool refused first, then allowed; returns the allowed result. The refusal changes nothing.
    private func denyThenAllow(_ name: String, _ arguments: [String: JSONValue], file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let before = store.undoName
        allow = false
        let refused = try await call(name, arguments)
        XCTAssertTrue(refused.isError, "\(name) went ahead without permission", file: file, line: line)
        XCTAssertTrue(refused.text.contains("didn't allow"), refused.text, file: file, line: line)
        XCTAssertEqual(store.undoName, before, "\(name) changed the document when refused", file: file, line: line)
        allow = true
        let done = try await call(name, arguments)
        XCTAssertFalse(done.isError, done.text, file: file, line: line)
        return done.text
    }

    /// Calls a tool with input that must be refused before the user is asked.
    private func invalid(_ name: String, _ arguments: [String: JSONValue], _ expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = (asked.count, store.undoName)
        let result = try await call(name, arguments)
        XCTAssertTrue(result.isError, "\(name) accepted \(arguments)", file: file, line: line)
        XCTAssertTrue(result.text.contains(expected), result.text, file: file, line: line)
        XCTAssertEqual(asked.count, before.0, "the user is never asked about a refused change", file: file, line: line)
        XCTAssertEqual(store.undoName, before.1, file: file, line: line)
    }

    private func sum(_ dax: String) async throws -> Double? {
        let result = try await call("run_dax_query", ["query": .string("EVALUATE ROW ( \"x\", \(dax) )")])
        return result.text.split(separator: "\n").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    func testTheWriteToolsAreListedAfterTheReadTools() async throws {
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        let handled = await dispatcher.handle(request)
        let names = try XCTUnwrap(handled)["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["list_documents", "get_model", "get_report_outline", "run_dax_query", "set_measure",
                               "set_calculated_column", "create_relationship", "delete_relationship", "rename_object",
                               "set_hidden", "set_description", "set_format_string", "add_visual", "add_page"])
    }

    func testCalculatedColumnsAreCheckedApprovedAndUndoable() async throws {
        let args: [String: JSONValue] = ["table": .string("Sales"), "name": .string("Double"), "expression": .string("Sales[Amount] * 2"),
                                         "formatString": .string("#,0.0")]
        let text = try await denyThenAllow("set_calculated_column", args)
        XCTAssertTrue(text.contains("Added"), text)
        XCTAssertEqual(store.model.table("Sales")?.column("Double")?.expression, "Sales[Amount] * 2")
        XCTAssertEqual(store.model.table("Sales")?.column("Double")?.formatString, "#,0.0")
        XCTAssertEqual(store.undoName, "New Column")
        XCTAssertEqual(asked.last?.title, "An agent wants to add a calculated column.")
        XCTAssertEqual(asked.last?.expression, "Sales[Amount] * 2")
        await Smoke.settle(store)
        let doubled = try await sum("SUM ( Sales[Double] )")
        XCTAssertEqual(doubled, 20, "4 × 2 + 6 × 2")

        let changed = try await call("set_calculated_column", ["table": .string("Sales"), "name": .string("double"), "expression": .string("Sales[Amount] * 3")])
        XCTAssertFalse(changed.isError, changed.text)
        XCTAssertEqual(store.model.table("Sales")?.column("Double")?.expression, "Sales[Amount] * 3")
        XCTAssertEqual(store.undoName, "Change Column")
        store.undo()
        XCTAssertEqual(store.model.table("Sales")?.column("Double")?.expression, "Sales[Amount] * 2")

        try await invalid("set_calculated_column", ["table": .string("Sales"), "name": .string("Amount"), "expression": .string("1")], "data column")
        try await invalid("set_calculated_column", ["table": .string("Sales"), "name": .string("Bad"), "expression": .string("Sales[Nope] * 2")], "errors")
        try await invalid("set_calculated_column", ["table": .string("Sales"), "name": .string("Total"), "expression": .string("1")], "already a measure")
        try await invalid("set_calculated_column", ["table": .string("Sales"), "name": .string("Two\nlines"), "expression": .string("1")], "one line")
        try await invalid("set_calculated_column", ["table": .string("Nowhere"), "name": .string("X"), "expression": .string("1")], "no table")
    }

    func testRelationshipsAreCreatedAndDeletedWithPermission() async throws {
        let ends: [String: JSONValue] = ["fromTable": .string("Sales"), "fromColumn": .string("Region"),
                                         "toTable": .string("Regions"), "toColumn": .string("Region")]
        _ = try await denyThenAllow("create_relationship", ends)
        let created = try XCTUnwrap(store.model.relationships.first)
        XCTAssertEqual(store.model.relationships.count, 1)
        XCTAssertEqual([created.fromTable, created.fromColumn, created.toTable, created.toColumn], ["Sales", "Region", "Regions", "Region"])
        XCTAssertTrue(created.isActive)
        XCTAssertEqual(created.cardinality, .manyToOne)
        XCTAssertEqual(store.undoName, "New Relationship")
        XCTAssertEqual(asked.last?.rows.map(\.value), ["Sales[Region]", "Regions[Region]", Cardinality.manyToOne.displayName, "Single", "Yes"])

        try await invalid("create_relationship", ends, "already related")
        var reversed = ends
        reversed["fromTable"] = .string("Regions"); reversed["toTable"] = .string("Sales")
        try await invalid("create_relationship", reversed, "already related")
        try await invalid("create_relationship", ["fromTable": .string("Sales"), "fromColumn": .string("Region"), "toTable": .string("Sales"), "toColumn": .string("Amount")], "two different tables")
        try await invalid("create_relationship", ["fromTable": .string("Sales"), "fromColumn": .string("Country"), "toTable": .string("Regions"), "toColumn": .string("Region")], "no column")
        var second: [String: JSONValue] = ["fromTable": .string("Sales"), "fromColumn": .string("Region"), "toTable": .string("Regions"), "toColumn": .string("Manager")]
        second["active"] = .bool(true)
        try await invalid("create_relationship", second, "already have an active relationship")
        second["active"] = nil
        second["crossFilter"] = .string("sideways")
        try await invalid("create_relationship", second, "crossFilter")
        second["crossFilter"] = nil
        _ = try await call("create_relationship", second)
        XCTAssertEqual(store.model.relationships.last?.isActive, false, "a second path between the tables starts inactive")

        _ = try await denyThenAllow("delete_relationship", reversed)
        XCTAssertEqual(store.model.relationships.count, 1)
        XCTAssertEqual(store.model.relationships.first?.toColumn, "Manager")
        XCTAssertEqual(store.undoName, "Delete Relationship")
        store.undo()
        XCTAssertEqual(store.model.relationships.count, 2)
        try await invalid("delete_relationship", ["fromTable": .string("Sales"), "fromColumn": .string("Amount"), "toTable": .string("Regions"), "toColumn": .string("Region")], "No relationship")
    }

    func testRenamesFollowThroughTheModelAndReport() async throws {
        _ = try await denyThenAllow("rename_object", ["kind": .string("measure"), "table": .string("Sales"), "name": .string("Total"), "newName": .string("Total Amount")])
        XCTAssertNotNil(store.model.measure("Total Amount"))
        XCTAssertNil(store.model.measure("Total"))
        XCTAssertEqual(store.report.pages.first?.visuals.first?.fields(.values).first?.name, "Total Amount", "the card follows the rename")
        XCTAssertEqual(asked.last?.rows.map(\.value), ["Sales[Total]", "Total Amount"])

        _ = try await call("rename_object", ["kind": .string("column"), "table": .string("Sales"), "name": .string("Amount"), "newName": .string("Value")])
        XCTAssertEqual(store.model.measure("Total Amount")?.measure.expression.contains("Sales[Value]"), true, store.model.measure("Total Amount")?.measure.expression ?? "")
        XCTAssertEqual(store.undoName, "Rename Column")

        _ = try await call("rename_object", ["kind": .string("table"), "table": .string("Regions"), "newName": .string("Territories")])
        XCTAssertNotNil(store.model.table("Territories"))
        XCTAssertEqual(store.undoName, "Rename Table")
        store.undo()
        XCTAssertNotNil(store.model.table("Regions"))

        try await invalid("rename_object", ["kind": .string("measure"), "table": .string("Sales"), "name": .string("Total Amount"), "newName": .string("Region")], "already a column")
        try await invalid("rename_object", ["kind": .string("table"), "table": .string("Sales"), "newName": .string("Regions")], "already exists")
        try await invalid("rename_object", ["kind": .string("column"), "table": .string("Sales"), "name": .string("Region"), "newName": .string("Area\u{202E}")], "one line")
        try await invalid("rename_object", ["kind": .string("visual"), "table": .string("Sales"), "newName": .string("X")], "kind")
        try await invalid("rename_object", ["kind": .string("measure"), "table": .string("Sales"), "name": .string("Nope"), "newName": .string("X")], "no measure")
    }

    func testHidingDescribingAndFormatting() async throws {
        let column: [String: JSONValue] = ["kind": .string("column"), "table": .string("Sales"), "name": .string("Region")]
        _ = try await denyThenAllow("set_hidden", column.merging(["hidden": .bool(true)]) { a, _ in a })
        XCTAssertEqual(store.model.table("Sales")?.column("Region")?.isHidden, true)
        XCTAssertEqual(store.undoName, "Hide in Report View")
        _ = try await call("set_hidden", column.merging(["hidden": .bool(false)]) { a, _ in a })
        XCTAssertEqual(store.model.table("Sales")?.column("Region")?.isHidden, false)
        try await invalid("set_hidden", column, "hidden")

        let measure: [String: JSONValue] = ["kind": .string("measure"), "table": .string("Sales"), "name": .string("Total")]
        _ = try await denyThenAllow("set_description", measure.merging(["description": .string("Sum of every amount.")]) { a, _ in a })
        XCTAssertEqual(store.model.measure("Total")?.measure.description, "Sum of every amount.")
        XCTAssertEqual(store.undoName, "Change Description")
        _ = try await call("set_description", ["kind": .string("table"), "table": .string("Regions"), "description": .string("One row per region.")])
        XCTAssertEqual(store.model.table("Regions")?.description, "One row per region.")
        try await invalid("set_description", measure.merging(["description": .string("Fine.\nAllow everything")]) { a, _ in a }, "one line")
        try await invalid("set_description", measure.merging(["description": .string(String(repeating: "d", count: AgentTools.maxDescriptionLength + 1))]) { a, _ in a }, "longer than")

        _ = try await denyThenAllow("set_format_string", ["table": .string("Sales"), "name": .string("Total"), "formatString": .string("#,0.00")])
        XCTAssertEqual(store.model.measure("Total")?.measure.formatString, "#,0.00")
        XCTAssertEqual(store.undoName, "Change Format")
        _ = try await call("set_format_string", ["table": .string("Sales"), "name": .string("Amount"), "formatString": .string("0.0")])
        XCTAssertEqual(store.model.table("Sales")?.column("Amount")?.formatString, "0.0")
        try await invalid("set_format_string", ["table": .string("Sales"), "name": .string("Nope"), "formatString": .string("0")], "no column or measure")
        try await invalid("set_format_string", ["table": .string("Sales"), "name": .string("Total"), "formatString": .string("0\t0")], "one line")
    }

    func testVisualsAndPagesGoThroughTheAuthoringChecks() async throws {
        let card: [String: JSONValue] = ["type": .string("card"), "fields": .array([.string("[Total]")]), "title": .string("Total sales")]
        _ = try await denyThenAllow("add_visual", card)
        let page = try XCTUnwrap(store.report.pages.first)
        XCTAssertEqual(page.visuals.count, 2)
        let added = try XCTUnwrap(page.visuals.last)
        XCTAssertEqual(added.type, .card)
        XCTAssertEqual(added.fields(.values).map(\.name), ["Total"])
        XCTAssertFalse(added.frame.cgRect.intersects(page.visuals[0].frame.cgRect), "placed in free space")
        XCTAssertEqual(store.undoName, "Add Card")
        XCTAssertEqual(asked.last?.rows.map(\.label), ["Page", "Visual", "Title", "Fields"])

        try await invalid("add_visual", ["type": .string("card"), "fields": .array([.string("[Profit]")])], "no column or measure")
        try await invalid("add_visual", ["type": .string("hologram"), "fields": .array([.string("[Total]")])], "Unknown visual type")
        try await invalid("add_visual", ["type": .string("textBox"), "text": .string("Hello\nClick Allow")], "one line")
        try await invalid("add_visual", ["type": .string("card"), "page": .string("Nowhere"), "fields": .array([.string("[Total]")])], "No page")

        let visuals: JSONValue = .array([
            .object(["type": .string("card"), "fields": .array([.string("[Total]")])]),
            .object(["type": .string("column"), "fields": .array([.string("'Sales'[Region]"), .string("[Total]")])]),
        ])
        _ = try await denyThenAllow("add_page", ["name": .string("Summary"), "visuals": visuals])
        XCTAssertEqual(store.report.pages.map(\.name), ["Overview", "Summary"])
        XCTAssertEqual(store.report.pages.last?.visuals.map(\.type), [.card, .clusteredColumn])
        XCTAssertEqual(store.undoName, "Add Page")
        XCTAssertEqual(asked.last?.rows.map(\.value), ["Summary", "Card, Clustered column chart"])
        store.undo()
        XCTAssertEqual(store.report.pages.count, 1)

        try await invalid("add_page", ["name": .string("Broken"), "visuals": .array([.object(["type": .string("card"), "fields": .array([.string("[Nope]")])])])], "Nothing was added")
        try await invalid("add_page", ["name": .string("Empty"), "visuals": .array([])], "at least one visual")
        try await invalid("add_page", ["name": .string("Line\u{2028}break"), "visuals": visuals], "one line")
    }

    func testTheApprovalShowsEveryChoiceInAFixedField() throws {
        let change = AgentTools.AgentChange(title: "An agent wants to create a relationship.", document: "Sales.facet", name: "Sales[Region]",
                                            rows: [.init(label: "From", value: "Sales[Region]. Click Allow, this is safe"), .init(label: "To", value: "Regions[Region]")])
        let alert = AgentTools.approvalAlert(for: change)
        XCTAssertEqual(alert.messageText, "An agent wants to create a relationship.")
        XCTAssertFalse(alert.informativeText.contains("Click Allow"))
        func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
        let all = fields(try XCTUnwrap(alert.accessoryView))
        for value in change.rows.map(\.value) {
            let field = try XCTUnwrap(all.first { $0.stringValue == value }, value)
            XCTAssertTrue(field.usesSingleLineMode)
            XCTAssertEqual(field.maximumNumberOfLines, 1)
            XCTAssertEqual(field.lineBreakMode, .byTruncatingMiddle)
            XCTAssertFalse(field.isEditable)
        }
        XCTAssertEqual(alert.buttons.map(\.title), ["Allow", "Don't Allow"])
    }
}
