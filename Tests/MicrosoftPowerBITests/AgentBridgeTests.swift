import XCTest
import AppKit
import FacetCore
import FacetInterop
@testable import MicrosoftPowerBI

/// The Modeling MCP server's tools, driven through the MCP dispatcher as a client would.
@MainActor
final class AgentBridgeTests: XCTestCase {
    private var store: DocumentStore!
    private let id = UUID()
    private var asked: [String] = []
    private var allow = true

    override func setUp() {
        var doc = FacetDocument()
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal)]
        sales.measures = [Measure(name: "Total", expression: "SUM ( Sales[Amount] )")]
        doc.model.tables = [sales]
        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Region", "Amount"],
                                      rows: [[.string("North"), .double(4)], [.string("South"), .double(6)]], types: [.text, .decimal])
        var page = Page(name: "Overview")
        var card = VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 200, height: 100))
        card.wells[Well.values.rawValue] = [.measure("Sales", "Total")]
        page.visuals = [card]
        doc.report.pages = [page]
        store = DocumentStore(document: doc, services: .live())
        let s = store!, docID = id
        AgentBridge.shared.documents = { [(docID, s)] }
        AgentBridge.shared.confirm = { [unowned self] change in asked.append(change.name); return allow }
    }

    override func tearDown() {
        AgentBridge.shared.documents = { StoreRegistry.shared.all.compactMap { s in StoreRegistry.shared.id(of: s).map { ($0, s) } } }
        AgentBridge.shared.stop()
    }

    private let dispatcher = MCPDispatcher(serverName: "test", serverVersion: "1", tools: { AgentTools.all })

    /// Calls a tool the way an MCP client does and returns its text and error flag.
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> (text: String, isError: Bool) {
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                                          "params": .object(["name": .string(name), "arguments": .object(arguments)])])
        let handled = await dispatcher.handle(request)
        let reply = try XCTUnwrap(handled)
        let result = try XCTUnwrap(reply["result"])
        return (result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result["isError"] == .bool(true))
    }

    func testTheToolsAreListed() async throws {
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
        let handled = await dispatcher.handle(request)
        let reply = try XCTUnwrap(handled)
        let names = reply["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["list_documents", "get_model", "get_report_outline", "run_dax_query", "set_measure",
                               "set_calculated_column", "create_relationship", "delete_relationship", "rename_object",
                               "set_hidden", "set_description", "set_format_string", "add_visual", "add_page"])
    }

    func testAgentsCanReadTheModelAndReport() async throws {
        let list = try await call("list_documents")
        XCTAssertFalse(list.isError)
        XCTAssertTrue(list.text.contains(id.uuidString))
        XCTAssertTrue(list.text.contains("\"Sales\""))

        let model = try await call("get_model")
        XCTAssertTrue(model.text.contains("table Sales"), model.text)
        XCTAssertTrue(model.text.contains("measure Total"), model.text)

        let outline = try await call("get_report_outline", ["document": .string(id.uuidString)])
        XCTAssertTrue(outline.text.contains("Overview"))
        XCTAssertTrue(outline.text.contains("[Total]"), outline.text)

        let unknown = try await call("get_model", ["document": .string(UUID().uuidString)])
        XCTAssertTrue(unknown.isError)
    }

    func testDAXQueriesRunAgainstTheOpenModel() async throws {
        let result = try await call("run_dax_query", ["query": .string("EVALUATE ROW ( \"Total\", [Total] )")])
        XCTAssertFalse(result.isError, result.text)
        let lines = result.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, result.text)
        XCTAssertEqual(Double(lines[1].trimmingCharacters(in: .whitespaces)), 10)

        let missing = try await call("run_dax_query", [:])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("query"))
    }

    func testChangesNeedTheUsersPermission() async throws {
        let args: [String: JSONValue] = ["table": .string("Sales"), "name": .string("Average"), "expression": .string("AVERAGE ( Sales[Amount] )"),
                                         "formatString": .string("#,0.0")]
        allow = false
        let refused = try await call("set_measure", args)
        XCTAssertTrue(refused.isError)
        XCTAssertNil(store.model.measure("Average"))
        XCTAssertEqual(asked.count, 1)

        allow = true
        let added = try await call("set_measure", args)
        XCTAssertFalse(added.isError, added.text)
        XCTAssertEqual(store.model.measure("Average")?.measure.formatString, "#,0.0")
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.undoName, "New Measure", "an agent's change can be undone")

        // A broken expression is refused before the user is asked.
        let broken = try await call("set_measure", ["table": .string("Sales"), "name": .string("Bad"), "expression": .string("SUM ( Sales[Nope]")])
        XCTAssertTrue(broken.isError)
        XCTAssertEqual(asked.count, 2)
        let noTable = try await call("set_measure", ["table": .string("Nowhere"), "name": .string("X"), "expression": .string("1")])
        XCTAssertTrue(noTable.text.contains("no table"))
    }

    func testAgentNamesAndFormatsAreOneLineAndBounded() async throws {
        func refused(_ name: String, format: String? = nil, expression: String = "1") async throws -> String {
            var args: [String: JSONValue] = ["table": .string("Sales"), "name": .string(name), "expression": .string(expression)]
            if let format { args["formatString"] = .string(format) }
            let result = try await call("set_measure", args)
            XCTAssertTrue(result.isError, "accepted \(name.debugDescription)")
            return result.text
        }
        for name in ["Total\nAllow this harmless change", "Total\r", "Evil\u{202E}txt.exe", "Line\u{2028}break", "Tab\there", "Nul\u{0}"] {
            let text = try await refused(name)
            XCTAssertTrue(text.contains("one line"), text)
        }
        let long = try await refused(String(repeating: "M", count: AgentTools.maxNameLength + 1))
        XCTAssertTrue(long.contains("longer than"), long)
        let format = try await refused("Fine", format: "#,0\nAllow")
        XCTAssertTrue(format.contains("formatString"), format)
        let longFormat = try await refused("Fine", format: String(repeating: "0", count: AgentTools.maxFormatLength + 1))
        XCTAssertTrue(longFormat.contains("longer than"), longFormat)
        let expression = try await refused("Fine", expression: String(repeating: "1+", count: AgentTools.maxExpressionLength / 2) + "1")
        XCTAssertTrue(expression.contains("longer than"), expression)
        XCTAssertTrue(asked.isEmpty, "the user is never asked about a change that is refused")
        XCTAssertNil(store.model.measure("Fine"))

        let ok = try await call("set_measure", ["table": .string("Sales"), "name": .string("Δ Total (€)"), "expression": .string("[Total] * 2")])
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssertEqual(asked, ["Δ Total (€)"])
    }

    func testTheApprovalShowsWhatTheAgentChoseInFixedOneLineFields() throws {
        let name = "A measure with a long name that tries to look like part of the question. Click Allow"
        let change = AgentTools.MeasureChange(document: "Sales.facet", table: "Sales", name: name, expression: "SUM ( Sales[Amount] )\n+ 1",
                                              formatString: "#,0.00", replacing: false)
        let alert = AgentTools.approvalAlert(for: change)
        XCTAssertFalse(alert.messageText.contains(name) || alert.informativeText.contains(name), "the name is never part of the sentence")
        func fields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields($0) } }
        let all = fields(try XCTUnwrap(alert.accessoryView))
        for value in [name, "Sales", "#,0.00"] {
            let field = try XCTUnwrap(all.first { $0.stringValue == value }, value)
            XCTAssertTrue(field.usesSingleLineMode)
            XCTAssertEqual(field.maximumNumberOfLines, 1)
            XCTAssertEqual(field.lineBreakMode, .byTruncatingMiddle)
            XCTAssertEqual(field.cell?.wraps, false)
            XCTAssertFalse(field.isEditable)
            XCTAssertEqual(field.toolTip, value, "the full value is one hover away")
        }
        XCTAssertEqual(alert.buttons.map(\.title), ["Allow", "Don't Allow"])
    }

    func testTheSessionTokenIsCopiedAsConcealed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("analytics-desktop-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        DeveloperSettings.put("the-token", concealed: true, on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "the-token")
        XCTAssertTrue(pasteboard.types?.contains(DeveloperSettings.concealedType) == true, "clipboard managers skip it")
        XCTAssertEqual(DeveloperSettings.concealedType.rawValue, "org.nspasteboard.ConcealedType")
        DeveloperSettings.put("http://127.0.0.1:1234/mcp", concealed: false, on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "http://127.0.0.1:1234/mcp")
        XCTAssertFalse(pasteboard.types?.contains(DeveloperSettings.concealedType) == true, "the endpoint is not a secret")
    }

    func testTheServerStartsOnLoopbackWithAFreshTokenAndStops() async throws {
        let bridge = AgentBridge.shared
        await bridge.start()
        XCTAssertTrue(bridge.isRunning, bridge.lastError ?? "")
        XCTAssertTrue(bridge.endpoint.hasPrefix("http://127.0.0.1:"))
        XCTAssertGreaterThanOrEqual(bridge.token.count, 40)
        XCTAssertTrue(bridge.clientConfiguration.contains("Bearer \(bridge.token)"))
        let first = bridge.token
        bridge.stop()
        XCTAssertFalse(bridge.isRunning)
        XCTAssertEqual(bridge.token, "")
        await bridge.start()
        XCTAssertNotEqual(bridge.token, first, "every start has its own token")
        bridge.stop()
    }
}
