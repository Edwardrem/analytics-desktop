import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Pure logic of the Power Query Editor: synchronising with the document, Close & Apply plans, naming,
/// column moves and selection, filter clauses, typed dialog values, the dependencies diagram and the ribbon table.
@MainActor
final class QueryEditorPlansTests: XCTestCase {
    private func q(_ name: String, _ script: String = "let\n    Source = 1\nin\n    Source", load: Bool = true) -> QueryDefinition {
        var d = QueryDefinition(name: name, mScript: script)
        d.loadEnabled = load
        return d
    }

    // MARK: Merge

    func testMergeKeepsLocalEditsAndTakesDocumentEdits() {
        let a = q("A"), b = q("B"), gone = q("Gone"), dropped = q("Dropped")
        var aLocal = a; aLocal.mScript = "let\n    Source = 2\nin\n    Source"
        var bRemote = b; bRemote.mScript = "let\n    Source = 3\nin\n    Source"
        let added = q("Added"), mine = q("Mine")
        let merged = QueryEditorPlans.merge(base: [a, b, gone, dropped], local: [aLocal, b, dropped, mine], remote: [a, bRemote, gone, added])
        // A edited here, B edited in the document, Gone deleted here, Dropped deleted in the document, Mine and Added new.
        XCTAssertEqual(merged.map(\.name), ["A", "B", "Mine", "Added"])
        XCTAssertEqual(merged[0].mScript, aLocal.mScript)
        XCTAssertEqual(merged[1].mScript, bRemote.mScript)
    }

    func testMergeKeepsALocallyEditedQueryTheDocumentDeleted() {
        let a = q("A")
        var edited = a; edited.description = "kept"
        XCTAssertEqual(QueryEditorPlans.merge(base: [a], local: [edited], remote: []).map(\.description), ["kept"])
    }

    // MARK: Apply plan

    func testApplyPlanRenamesRemovesAndLoadsNewQueries() {
        let sales = q("Sales"), old = q("Old"), staging = q("Staging")
        var revenue = sales; revenue.name = "Revenue"
        var connectionOnly = staging; connectionOnly.loadEnabled = false
        let new = q("New")
        let plan = QueryEditorPlans.applyPlan(before: [sales, old, staging], after: [revenue, connectionOnly, new],
                                              loadedTables: ["Sales": "Sales", "Old": "Old", "Staging": "Staging"])
        XCTAssertEqual(plan.renames, [.init(from: "Sales", to: "Revenue")])
        XCTAssertEqual(plan.removedTables, ["Old", "Staging"])
        XCTAssertEqual(plan.refresh, ["New"], "a renamed query keeps its data; only the never-loaded query loads")
    }

    func testChangingAParameterRefreshesTheQueriesThatUseIt() {
        var p = q("Year", "2024 meta [IsParameterQuery=true]", load: false)
        p.kind = .parameter
        var param = QueryParameter(); param.type = .integer; param.currentValue = .int(2024)
        p.parameter = param
        let uses = q("Sales", "let\n    Source = Year\nin\n    Source")
        let other = q("Other")
        var changed = p; changed.parameter?.currentValue = .int(2025)
        let plan = QueryEditorPlans.applyPlan(before: [p, uses, other], after: [changed, uses, other], loadedTables: ["Sales": "Sales", "Other": "Other"])
        XCTAssertEqual(plan.refresh, ["Sales"])
        XCTAssertTrue(plan.renames.isEmpty)
        XCTAssertTrue(plan.removedTables.isEmpty)
    }

    func testEnablingLoadAgainLoadsTheQuery() {
        let off = q("T", load: false)
        var on = off; on.loadEnabled = true
        XCTAssertEqual(QueryEditorPlans.applyPlan(before: [off], after: [on], loadedTables: [:]).refresh, ["T"])
        XCTAssertEqual(QueryEditorPlans.applyPlan(before: [on], after: [on], loadedTables: ["T": "T"]).refresh, [], "unchanged and loaded")
    }

    func testAFunctionQueryIsNotLoaded() {
        var f = q("fx", "(x) => x + 1")
        f.kind = .function
        let plan = QueryEditorPlans.applyPlan(before: [], after: [f], loadedTables: [:])
        XCTAssertEqual(plan.refresh, [])
    }

    // MARK: Names

    func testNames() {
        XCTAssertEqual(QueryEditorPlans.newQueryName(taken: ["Query1", "Query2"]), "Query3")
        XCTAssertEqual(QueryEditorPlans.newQueryName("Merge", taken: []), "Merge1")
        XCTAssertEqual(QueryEditorPlans.uniqueColumnName("Index", taken: ["Index", "Index.1"]), "Index.2")
        XCTAssertEqual(QueryEditorPlans.uniqueColumnName("Year", taken: ["Date"]), "Year")
    }

    func testQueryNameProblems() {
        let a = q("Sales"), b = q("Regions")
        let tables = ["Sales": "Sales", "Calendar": ""]
        XCTAssertNil(QueryEditorPlans.queryNameProblem("Revenue", for: a.id, queries: [a, b], modelTables: tables))
        XCTAssertNotNil(QueryEditorPlans.queryNameProblem("regions", for: a.id, queries: [a, b], modelTables: tables), "names are case-insensitive")
        XCTAssertNotNil(QueryEditorPlans.queryNameProblem("Calendar", for: a.id, queries: [a, b], modelTables: tables), "a calculated table owns the name")
        XCTAssertNil(QueryEditorPlans.queryNameProblem("SALES", for: a.id, queries: [a, b], modelTables: tables), "its own table")
        XCTAssertEqual(QueryEditorPlans.queryNameProblem("  ", for: a.id, queries: [a], modelTables: [:]), "A query needs a name.")
    }

    // MARK: Columns

    func testMovingColumns() {
        let all = ["A", "B", "C", "D"]
        XCTAssertEqual(QueryEditorPlans.movedColumns(all, selected: ["C"], .left), ["A", "C", "B", "D"])
        XCTAssertEqual(QueryEditorPlans.movedColumns(all, selected: ["B", "C"], .right), ["A", "D", "B", "C"])
        XCTAssertEqual(QueryEditorPlans.movedColumns(all, selected: ["D"], .toBeginning), ["D", "A", "B", "C"])
        XCTAssertEqual(QueryEditorPlans.movedColumns(all, selected: ["C", "A"], .toEnd), ["B", "D", "A", "C"], "selected columns keep their order")
        XCTAssertEqual(QueryEditorPlans.movedColumns(all, selected: ["A"], .left), all)
        XCTAssertEqual(QueryEditorPlans.movedColumns(all, selected: ["D"], .right), all)
    }

    func testHeaderSelection() {
        let all = ["A", "B", "C", "D"]
        XCTAssertEqual(QueryEditorPlans.select("B", in: all, current: ["A"], toggle: false, range: false), ["B"])
        XCTAssertEqual(QueryEditorPlans.select("D", in: all, current: ["B"], toggle: true, range: false), ["B", "D"])
        XCTAssertEqual(QueryEditorPlans.select("B", in: all, current: ["B", "D"], toggle: true, range: false), ["D"])
        XCTAssertEqual(QueryEditorPlans.select("D", in: all, current: ["B"], toggle: false, range: true), ["B", "C", "D"])
    }

    // MARK: Filter clauses

    func testFilterClausesCombineLeftToRight() {
        let types: [String: DataType] = ["Region": .text, "Amount": .decimal]
        let clauses = [
            FilterClause(column: "Region", op: .equals, value: "North"),
            FilterClause(column: "Amount", op: .greater, value: "10", and: true),
            FilterClause(column: "Amount", op: .less, value: "2", and: false),
        ]
        let condition = try? XCTUnwrap(FilterClause.combine(clauses, types: types))
        XCTAssertEqual(condition?.mExpression(previous: "Source"), "(([Region] = \"North\") and ([Amount] > 10)) or ([Amount] < 2)")
        let text = FilterClause(column: "Region", op: .notBeginsWith, value: "N").condition(type: .text)
        XCTAssertEqual(text.mExpression(previous: "Source"), "not Text.StartsWith([Region], \"N\")")
    }

    func testFilterClausesOfAStepRoundTrip() throws {
        let types: [String: DataType] = ["Region": .text, "Amount": .decimal]
        let condition = RowFilter.and([.compare(column: "Amount", .greaterOrEqual, .double(5), type: .decimal), .isNotNull(column: "Region")])
        let clauses = try XCTUnwrap(FilterClause.clauses(of: condition, types: types))
        XCTAssertEqual(clauses.map(\.op), [.greaterOrEqual, .isNotNull])
        XCTAssertEqual(clauses.map(\.value), ["5", ""])
        XCTAssertEqual(FilterClause.combine(clauses, types: types)?.mExpression(previous: "S"), condition.mExpression(previous: "S"))
        XCTAssertNil(FilterClause.clauses(of: .custom("[A] + [B] > 3"), types: types), "a custom condition is edited as a formula")
    }

    func testRelativeDateClauses() throws {
        let types: [String: DataType] = ["Day": .date]
        let three = FilterClause(column: "Day", op: .inPrevious, value: "3", unit: .month).condition(type: .date)
        XCTAssertEqual(three.mExpression(previous: "S"), "Date.IsInPreviousNMonths([Day], 3)")
        XCTAssertEqual(FilterClause(column: "Day", op: .inNext, value: "1", unit: .week).condition(type: .date).mExpression(previous: "S"), "Date.IsInNextWeek([Day])")
        XCTAssertEqual(FilterClause(column: "Day", op: .inCurrent, unit: .year).condition(type: .date).mExpression(previous: "S"), "Date.IsInCurrentYear([Day])")
        let back = try XCTUnwrap(FilterClause.clauses(of: three, types: types))
        XCTAssertEqual(back, [FilterClause(column: "Day", op: .inPrevious, value: "3", unit: .month)])
        XCTAssertTrue(FilterClause.Op.offered(for: .date).contains(.yearToDate))
        XCTAssertFalse(FilterClause.Op.offered(for: .text).contains(.inPrevious))
    }

    // MARK: Dialog values

    func testTypedValues() {
        XCTAssertEqual(EditorValues.parse("12", as: .integer), .int(12))
        XCTAssertEqual(EditorValues.parse("1.5", as: .decimal), .double(1.5))
        XCTAssertEqual(EditorValues.parse("NULL", as: .text), .null)
        XCTAssertEqual(EditorValues.parse("", as: .text), .string(""))
        XCTAssertEqual(EditorValues.parse("", as: .integer), .null)
        XCTAssertEqual(EditorValues.parse("abc", as: .integer), .string("abc"), "not a number stays text, so the step fails visibly")
        XCTAssertEqual(EditorValues.parse("TRUE", as: .boolean), .bool(true))
        var c = DateComponents(); c.year = 2024; c.month = 3; c.day = 1
        XCTAssertEqual(EditorValues.parse("2024-03-01", as: .date), .date(Calendar.utc.date(from: c) ?? Date()))
        XCTAssertEqual(ConditionalColumnDialog.output("7"), .int(7))
        XCTAssertEqual(ConditionalColumnDialog.output("High"), .string("High"))
        XCTAssertEqual(ConditionalColumnDialog.output(""), .null)
    }

    func testCustomColumnSyntaxCheck() {
        XCTAssertNil(CustomColumnDialog.problem(in: "[Quantity] * [Price]", known: []))
        XCTAssertNil(CustomColumnDialog.problem(in: "= Text.Upper([Name])", known: []))
        XCTAssertNotNil(CustomColumnDialog.problem(in: "[Quantity] *", known: []))
        XCTAssertEqual(CustomColumnDialog.problem(in: "  ", known: []), "Type a formula.")
    }

    func testFunctionParametersAreReadFromTheScript() {
        XCTAssertEqual(InvokeFunctionDialog.parameters(of: "(a as text, optional b as number) => a & Text.From(b)"), ["a", "b"])
        XCTAssertEqual(InvokeFunctionDialog.parameters(of: "let\n    fn = (x) => x * 2\nin\n    fn"), ["x"])
        XCTAssertNil(InvokeFunctionDialog.parameters(of: "let\n    Source = 1\nin\n    Source"))
    }

    func testMergeMatchEstimateIgnoresNullKeys() {
        let left = DataTable(columnNames: ["K"], rows: [[.int(1)], [.int(2)], [.int(3)], [.null]], types: [.integer])
        let right = DataTable(columnNames: ["Id"], rows: [[.int(2)], [.int(3)], [.int(3)], [.null]], types: [.integer])
        XCTAssertEqual(MergeEstimate.matches(left: left, leftKeys: ["K"], right: right, rightKeys: ["Id"]), 2)
        XCTAssertNil(MergeEstimate.matches(left: left, leftKeys: ["K"], right: right, rightKeys: []))
    }

    func testSplitCounts() {
        XCTAssertEqual(SplitCount.parts(of: "HelloWorldFoo", .lowerToUpper), 3)
        XCTAssertEqual(SplitCount.parts(of: "abc123def", .digitToNonDigit), 2)
        XCTAssertEqual(SplitCount.parts(of: "abc123def", .nonDigitToDigit), 2)
        XCTAssertEqual(SplitCount.parts(of: "a,b,,c", delimiter: ","), 4)
    }

    func testVisibleWhitespace() {
        XCTAssertEqual(QueryCellText.visibleWhitespace(" a\tb\n"), "·a→b¶")
    }

    // MARK: Source step settings

    func testSourceStepsReadBackAsConnectionDetails() throws {
        var csv = SourceRequest(kind: .csv, location: "/data/s.csv")
        csv.delimiter = ";"; csv.encoding = 1252
        var web = SourceRequest(kind: .web, location: "https://h/t.html")
        web.webContent = .html
        for r in [csv, SourceRequest(kind: .excel, location: "/b.xlsx"), SourceRequest(kind: .json, location: "/j.json"),
                  SourceRequest(kind: .xml, location: "/x.xml"), SourceRequest(kind: .folder, location: "/in"),
                  SourceRequest(kind: .sqlite, location: "/db.sqlite"), SourceRequest(kind: .odata, location: "https://h/svc"), web] {
            let back = try XCTUnwrap(SourcePlanner.request(fromSource: SourcePlanner.sourceExpression(r)), "\(r.kind)")
            XCTAssertEqual(SourcePlanner.sourceExpression(back), SourcePlanner.sourceExpression(r), "\(r.kind)")
        }
        let pbi = try XCTUnwrap(SourcePlanner.request(fromSource: #"Csv.Document(File.Contents("C:\x.csv"),[Delimiter=";", Columns=3, Encoding=1252, QuoteStyle=QuoteStyle.None])"#))
        XCTAssertEqual(pbi.kind, .csv)
        XCTAssertEqual(pbi.location, #"C:\x.csv"#)
        XCTAssertEqual(pbi.delimiter, ";")
        XCTAssertEqual(pbi.encoding, 1252)
        XCTAssertNil(SourcePlanner.request(fromSource: "Table.FirstN(Source, 3)"))
    }

    func testStepsWithSettingsDialogs() {
        XCTAssertTrue(StepSettings.hasDialog(.keepTopRows(3)))
        XCTAssertTrue(StepSettings.hasDialog(.groupBy(keys: ["A"], aggregations: [("Count", .countRows)])))
        XCTAssertTrue(StepSettings.hasDialog(.changeType([("A", .date)], culture: "en-GB")))
        XCTAssertFalse(StepSettings.hasDialog(.changeType([("A", .date)], culture: nil)), "Changed Type is edited from the column header")
        XCTAssertFalse(StepSettings.hasDialog(.removeColumns(["A"])))
        XCTAssertFalse(StepSettings.hasDialog(.number(columns: ["A"], .absolute, newColumn: nil)))
        XCTAssertTrue(StepSettings.hasDialog(.number(columns: ["A"], .round(digits: 2), newColumn: nil)))
    }

    // MARK: Dependencies

    func testDependencyLayoutPutsSourcesFirstThenQueriesByLevel() {
        let sales = q("Sales", "let\n    Source = Csv.Document(File.Contents(\"/d/sales.csv\"))\nin\n    Source")
        let regions = q("Regions", "let\n    Source = Excel.Workbook(File.Contents(\"/d/r.xlsx\"), null, true)\nin\n    Source", load: false)
        var year = q("Year", "2024 meta [IsParameterQuery=true]", load: false)
        year.kind = .parameter
        let merged = q("Merged", "let\n    Source = Table.NestedJoin(Sales, {\"R\"}, Regions, {\"R\"}, \"Regions\", JoinKind.LeftOuter),\n    F = Table.SelectRows(Source, each [Y] = Year)\nin\n    F")
        let layout = DependencyLayout.make(queries: [sales, regions, year, merged])
        let file = DependencyLayout.sourceID(QueryDataSource(kind: "File", location: "/d/sales.csv"))
        let book = DependencyLayout.sourceID(QueryDataSource(kind: "File", location: "/d/r.xlsx"))
        func node(_ id: String) -> DependencyLayout.Node? { layout.nodes.first { $0.id == id } }
        XCTAssertEqual(node(file)?.column, 0)
        XCTAssertEqual(node(file)?.title, "sales.csv")
        XCTAssertEqual(node(book)?.row, 1)
        XCTAssertEqual(node(DependencyLayout.queryID("Sales"))?.column, 1)
        XCTAssertEqual(node(DependencyLayout.queryID("Year"))?.subtitle, "Parameter")
        XCTAssertEqual(node(DependencyLayout.queryID("Regions"))?.subtitle, "Connection only")
        XCTAssertEqual(node(DependencyLayout.queryID("Merged"))?.column, 2)
        XCTAssertEqual(Set(layout.edges), [
            .init(from: file, to: "query:Sales"), .init(from: book, to: "query:Regions"),
            .init(from: "query:Sales", to: "query:Merged"), .init(from: "query:Regions", to: "query:Merged"), .init(from: "query:Year", to: "query:Merged"),
        ])
        XCTAssertEqual(layout.connected(to: "query:Sales"), [file, "query:Sales", "query:Merged"])
    }

    // MARK: Ribbon and menus

    func testEveryRibbonAndMenuEntryNamesACommand() {
        let ids = Set(EditorCommands.all.map(\.id))
        XCTAssertEqual(ids.count, EditorCommands.all.count, "command ids repeat")
        for id in EditorRibbonLayout.referencedIDs { XCTAssertNotNil(EditorCommands.command(id), id) }
        func walk(_ entries: [EditorRibbonLayout.Entry]) -> [String] {
            entries.flatMap { e -> [String] in
                switch e {
                case .command(let id): return [id]
                case .divider: return []
                case .submenu(_, let inner): return walk(inner)
                }
            }
        }
        for id in walk(EditorMenus.headerEntries) + walk(EditorMenus.contextEntries) { XCTAssertNotNil(EditorCommands.command(id), id) }
        XCTAssertEqual(EditorRibbonLayout.tabs.map(\.title), ["Home", "Transform", "Add Column", "View", "Tools"])
    }

    func testUnavailableAICommandsSayWhy() {
        let s = QueryEditorSession(store: DocumentStore(services: .live()))
        for id in ["pq.ai.text", "pq.ai.vision", "pq.ai.ml"] {
            XCTAssertEqual(EditorCommands.command(id)?.blocker(s), "Needs Azure Cognitive Services with a Microsoft sign-in, which the query engine cannot reach.")
        }
    }
}
