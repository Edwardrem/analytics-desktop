import XCTest
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// The Assistant pane's tools, run as the model would call them: visuals arrive with their fields bound and in
/// free space, a page arrives with its visuals laid out, a measure is checked before it is added, and every
/// change is one undoable step. No request leaves the machine; the tools are called directly.
@MainActor
final class AssistantToolsTests: XCTestCase {
    override func setUp() async throws {
        Features.registerAll()
    }

    private func json(_ text: String) throws -> FacetCloud.JSONValue { try FacetCloud.JSONValue.parse(text) }

    private func tool(_ name: String, _ store: DocumentStore) throws -> AssistantTool {
        try XCTUnwrap(AssistantTools.tools(for: store).first { $0.name == name }, "no \(name) tool")
    }

    func testTheModelIsOfferedTheReadingAndAuthoringTools() {
        let names = AssistantTools.tools(for: ReportFixture.store()).map(\.name)
        XCTAssertEqual(names, ["run_dax", "get_model_schema", "describe_page", "describe_report", "add_visual", "create_page", "add_measure"])
    }

    func testAddVisualBindsTheFieldsAndPlacesItInFreeSpace() async throws {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        let add = try tool("add_visual", store)
        let first = try await add.handler(json(#"{"type":"column","fields":[{"field":"'Sales'[Region]"},{"field":"[Total]"}],"title":"Total by region"}"#))
        XCTAssertFalse(first.isError, first.content)
        let v = try XCTUnwrap(store.currentPage.visuals.first)
        XCTAssertEqual(v.type, .clusteredColumn)
        XCTAssertEqual(v.fields(.category).map(\.key), [FieldRef.column("Sales", "Region").key])
        XCTAssertEqual(v.fields(.values).map(\.key), [FieldRef.measure("Sales", "Total").key])
        XCTAssertEqual(v.fmtString("title", "text", ""), "Total by region")
        XCTAssertEqual(v.frame, Frame(x: 24, y: 24, width: 420, height: 280))
        XCTAssertEqual(store.selection, [v.id])
        XCTAssertEqual(store.undoName, "Add Clustered column chart")

        // Fields given as plain references; the second chart goes beside the first, 16 points clear on the grid.
        let second = try await add.handler(json(#"{"type":"bar","fields":["[Channel]","Sales[Amount]"]}"#))
        XCTAssertFalse(second.isError, second.content)
        let w = try XCTUnwrap(store.currentPage.visuals.last)
        XCTAssertEqual(w.frame, Frame(x: 464, y: 24, width: 420, height: 280))
        XCTAssertEqual(w.fields(.values).map(\.key), [FieldRef.column("Sales", "Amount", .sum).key])
        XCTAssertTrue(second.content.contains("Sum of Amount"), second.content)

        await Smoke.settle(store)
        XCTAssertEqual(store.visualData[v.id]?.table.rowCount, 3, "the chart has data: three regions")
        store.undo()
        XCTAssertEqual(store.currentPage.visuals.map(\.id), [v.id], "Undo takes back the last visual only")
    }

    func testAVisualThatFailsTheCheckIsNotAdded() async throws {
        let store = ReportFixture.store()
        let add = try tool("add_visual", store)
        let unknown = try await add.handler(json(#"{"type":"column","fields":["[Region]","[Profit]"]}"#))
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.content.contains("[Profit]"), unknown.content)
        let badType = try await add.handler(json(#"{"type":"hologram","fields":["[Total]"]}"#))
        XCTAssertTrue(badType.content.contains("Unknown visual type"), badType.content)
        let badPage = try await add.handler(json(#"{"type":"card","fields":["[Total]"],"page":"Nowhere"}"#))
        XCTAssertTrue(badPage.content.contains("no page named \"Nowhere\""), badPage.content)
        XCTAssertTrue(store.currentPage.visuals.isEmpty)
        XCTAssertEqual(store.undoName, "Load", "nothing was recorded")
    }

    func testCreatePageLaysOutItsVisualsAndOpensIt() async throws {
        let store = ReportFixture.store()
        let first = store.currentPageID
        let create = try tool("create_page", store)
        let out = try await create.handler(json(#"""
        {"name":"Overview","visuals":[
          {"type":"card","fields":["[Total]"],"title":"Total"},
          {"type":"bar","fields":["'Sales'[Channel]","[Total]"]}
        ]}
        """#))
        XCTAssertFalse(out.isError, out.content)
        XCTAssertEqual(store.report.pages.count, 2)
        let page = store.currentPage
        XCTAssertNotEqual(page.id, first)
        XCTAssertEqual(page.name, "Overview")
        // The card in the top band; the bar chart alone takes the full width (1280 − 48) under it (720 − 24 − 170).
        XCTAssertEqual(page.visuals.map(\.frame), [Frame(x: 24, y: 24, width: 220, height: 130), Frame(x: 24, y: 170, width: 1232, height: 526)])
        XCTAssertEqual(page.visuals.last?.fields(.category).map(\.key), [FieldRef.column("Sales", "Channel").key])
        XCTAssertEqual(store.undoName, "Create Page \"Overview\"")
        store.undo()
        XCTAssertEqual(store.report.pages.count, 1, "one Undo removes the page and its visuals")

        // A second page with the same name gets a number.
        _ = try await create.handler(json(#"{"name":"Page 1","visuals":[{"type":"card","fields":["[Total]"]}]}"#))
        XCTAssertEqual(store.currentPage.name, "Page 1 2")
    }

    func testCreatePageMakesNothingWhenAVisualFailsTheCheck() async throws {
        let store = ReportFixture.store()
        let out = try await tool("create_page", store).handler(json(#"""
        {"name":"Overview","visuals":[{"type":"card","fields":["[Total]"]},{"type":"line","fields":["[Profit]"]}]}
        """#))
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.content.hasPrefix("Visual 2 (line):"), out.content)
        XCTAssertTrue(out.content.contains("Nothing was created."), out.content)
        XCTAssertEqual(store.report.pages.count, 1)
        let empty = try await tool("create_page", store).handler(json(#"{"name":"Overview","visuals":[]}"#))
        XCTAssertTrue(empty.isError)
    }

    func testAddMeasureChecksAndEvaluatesTheFormulaFirst() async throws {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        let add = try tool("add_measure", store)
        // (10 + 20 + 30 + 40 + 50) / 5 = 30.
        let ok = try await add.handler(json(#"{"table":"sales","name":"Average Amount","expression":"AVERAGE(Sales[Amount])","format_string":"0.0","description":"Average sale."}"#))
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertTrue(ok.content.contains("evaluates to 30"), ok.content)
        let m = try XCTUnwrap(store.model.table("Sales")?.measure("Average Amount"))
        XCTAssertEqual(m.formatString, "0.0")
        XCTAssertEqual(m.description, "Average sale.")
        XCTAssertEqual(store.undoName, "Add Measure")

        let missing = try await add.handler(json(#"{"table":"Sales","name":"Profit Total","expression":"SUM(Sales[Profit])"}"#))
        XCTAssertTrue(missing.isError)
        XCTAssertNil(store.model.measure("Profit Total"))
        let duplicate = try await add.handler(json(#"{"table":"Sales","name":"Total","expression":"1"}"#))
        XCTAssertTrue(duplicate.content.contains("already exists"), duplicate.content)
        let noTable = try await add.handler(json(#"{"table":"Budget","name":"X","expression":"1"}"#))
        XCTAssertTrue(noTable.content.contains("no table named \"Budget\""), noTable.content)

        store.undo()
        XCTAssertNil(store.model.measure("Average Amount"))
    }

    func testDescribePageReportsWhatTheVisualsShow() async throws {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        var chart = ReportFixture.chart("Amount by region")
        chart.frame = Frame(x: 24, y: 24, width: 420, height: 280)
        let page = store.pageIndex
        store.mutate("Add", invalidates: .visuals(nil)) { $0.report.pages[page].visuals.append(chart) }
        await Smoke.settle(store)

        let out = try await tool("describe_page", store).handler(json("{}"))
        // South 30 + 40 = 70, East 50, North 10 + 20 = 30: largest first.
        let lines = out.content.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Page: \(store.currentPage.name)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("- [Clustered column chart] Amount by region") }, out.content)
        let rows = lines.filter { $0.hasPrefix("  ") }.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(Array(rows.dropFirst().prefix(3)), ["South | 70", "East | 50", "North | 30"], out.content)

        let missing = try await tool("describe_page", store).handler(json(#"{"page":"Nowhere"}"#))
        XCTAssertTrue(missing.isError)
        let report = try await tool("describe_report", store).handler(json("{}"))
        XCTAssertTrue(report.content.hasPrefix("Report: 1 page"), report.content)
    }

    func testRunDAXReturnsRowsOrTheError() async throws {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        let run = try tool("run_dax", store)
        let ok = try await run.handler(json(#"{"dax":"EVALUATE ROW(\"Sum\", [Total])"}"#))
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertEqual(ok.content.components(separatedBy: "\n").last, "150", "10 + 20 + 30 + 40 + 50")
        let bad = try await run.handler(json(#"{"dax":"EVALUATE ROW(\"x\", [Nope])"}"#))
        XCTAssertTrue(bad.isError)
    }
}
