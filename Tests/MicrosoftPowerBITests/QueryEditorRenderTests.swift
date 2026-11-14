import XCTest
import SwiftUI
import AppKit
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Lays out and draws the Power Query Editor and each of its dialogs in an offscreen window, so a view that traps
/// (an index out of range in a binding, a missing environment object) fails here rather than in the app.
@MainActor
final class QueryEditorRenderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "QueryEditorRenderTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private static let sales = """
    let
        Source = #table({"Region", "Amount", "Day", "Nested"}, {{"North", 10, #date(2024, 1, 5), [a = 1]}, {"South", 20, #date(2024, 2, 9), [a = 2]}}),
        #"Kept First Rows" = Table.FirstN(Source, 2)
    in
        #"Kept First Rows"
    """

    private func makeSession() async -> QueryEditorSession {
        var doc = FacetDocument()
        var p = QueryParameter(); p.type = .integer; p.currentValue = .int(2024)
        var year = QueryDefinition(name: "Year", mScript: MScript.parameterScript(p))
        year.kind = .parameter; year.parameter = p
        var fx = QueryDefinition(name: "fxDouble", mScript: "(x as number) => x * 2")
        fx.kind = .function
        var other = QueryDefinition(name: "Regions", mScript: "let\n    Source = #table({\"Region\", \"Manager\"}, {{\"North\", \"Ann\"}})\nin\n    Source")
        other.group = "Lookups"
        doc.queries = [QueryDefinition(name: "Sales", mScript: Self.sales), other, year, fx]
        let s = QueryEditorSession(store: DocumentStore(document: doc, services: .live()), security: QuerySecurity(defaults: defaults))
        s.refreshPreview()
        await s.waitForPreview()
        return s
    }

    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 640), _ label: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("\(label): no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertNotNil(rep.colorAt(x: 5, y: 5), label)
        window.contentView = nil
        window.close()
    }

    func testTheEditorDrawsWithEveryViewOptionOn() async throws {
        let s = await makeSession()
        XCTAssertEqual(s.preview?.table.rowCount, 2)
        s.showQuality = true; s.showDistribution = true; s.showProfile = true; s.monospaced = true; s.showWhitespace = true
        s.clickColumn("Amount", toggle: false, range: false)
        render(QueryEditorView(store: s.store), size: CGSize(width: 1280, height: 800), "editor")
        render(ColumnProfilePanel(session: s), "column profile")
        render(PreviewArea(session: s), "preview")
        render(QueriesPane(session: s), size: CGSize(width: 240, height: 500), "queries pane")
        render(QuerySettingsPane(session: s), size: CGSize(width: 280, height: 500), "query settings")
        render(EditorRibbonView(session: s), size: CGSize(width: 1280, height: 110), "ribbon")
    }

    func testEveryDialogDraws() async throws {
        let s = await makeSession()
        let table = try XCTUnwrap(s.preview?.table)
        let sales = try XCTUnwrap(s.selectedQueryID)
        let year = try XCTUnwrap(s.query(named: "Year")?.id)
        let dialogs: [EditorDialog] = [
            .rows(.keepTop), .rows(.keepRange), .rows(.removeAlternate), .chooseColumns, .goToColumn, .renameColumn("Region"),
            .advancedEditor, .sourceSettings(step: 0), .queryProperties(sales), .renameQuery(sales), .createFunction(sales),
            .newGroup(moving: [sales]), .renameGroup("Lookups"), .manageParameters(select: year), .manageParameters(select: nil),
            .dependencies, .diagnostics(s.lastEvents, title: "Diagnostics"), .nativeQuery("select 1"), .script(python: true),
            .enterData, .dataSourceSettings, .recentSources, .newSource,
            .filter(column: "Region"), .groupBy, .merge(asNew: false), .append(asNew: true), .customColumn, .conditionalColumn,
            .indexColumn, .invokeFunction, .columnFromExamples(columns: nil), .split(column: "Region", .delimiter),
            .changeTypeWithLocale(columns: ["Day"]), .replaceValues(columns: ["Region"]), .replaceErrors(columns: ["Amount"]),
            .mergeColumns(columns: ["Region", "Amount"], asNewColumn: true), .affix(columns: ["Region"], suffix: false),
            .extract(columns: ["Region"], .between, asNewColumn: true), .numberValue(columns: ["Amount"], .round, asNewColumn: false),
            .pivot(column: "Region"), .expand(column: "Nested"), .aggregate(column: "Nested"), .extractValues(column: "Nested"),
        ]
        for d in dialogs { render(EditorDialogHost(session: s, dialog: d), size: CGSize(width: 820, height: 640), d.id) }
        // The dialogs behind the router, with their table.
        render(FilterRowsDialog(session: s, table: table, column: "Day", edit: nil), "filter on a date")
        render(GroupByDialog(session: s, table: table, edit: nil), "group by")
        render(ConditionalColumnDialog(session: s, table: table, edit: nil), "conditional column")
        render(ColumnFromExamplesDialog(session: s, table: table, sourceColumns: ["Region"]), "column from examples")
        render(SplitColumnDialog(session: s, table: table, column: "Region", kind: .positions, edit: nil), "split by positions")
        render(MergeQueriesDialog(session: s, asNew: true, edit: nil), "merge as new")
        render(AppendQueriesDialog(session: s, asNew: false, edit: nil), "append")
        render(FunctionInvokePanel(session: s, query: try XCTUnwrap(s.query(named: "fxDouble"))), "invoke function")
        // A step's gear.
        if case .editStep(let e)? = StepSettings.dialog(forStep: 1, in: s) {
            render(EditorDialogHost(session: s, dialog: .editStep(e)), "edit step")
        } else {
            XCTFail("Kept First Rows has a settings dialog")
        }
    }
}
