import XCTest
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
        AgentBridge.shared.confirm = { [unowned self] message, _ in asked.append(message); return allow }
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
        XCTAssertEqual(names, ["list_documents", "get_model", "get_report_outline", "run_dax_query", "set_measure"])
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
