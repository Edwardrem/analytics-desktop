import XCTest
import SQLite3
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// The Power Query Editor session against the real query engine: applied steps, the formula bar, commands,
/// query and parameter management, Close & Apply / discard, synchronisation with the document, folding and diagnostics.
@MainActor
final class QueryEditorSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var dir: URL!

    override func setUpWithError() throws {
        suite = "QueryEditorSessionTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("QueryEditorSessionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private static let table = "let\n    Source = #table({\"A\", \"B\"}, {{1, \"x\"}, {2, \"y\"}, {3, \"z\"}})\nin\n    Source"

    private func session(_ queries: [QueryDefinition]) async -> QueryEditorSession {
        var doc = FacetDocument()
        doc.queries = queries
        let s = QueryEditorSession(store: DocumentStore(document: doc, services: .live()), security: QuerySecurity(defaults: defaults))
        s.refreshPreview()
        await s.waitForPreview()
        return s
    }
    private func run(_ id: String, _ s: QueryEditorSession) async {
        guard let c = EditorCommands.command(id) else { return XCTFail("no command \(id)") }
        XCTAssertNil(c.blocker(s), id)
        c.run(s)
        await s.waitForPreview()
    }
    private func names(_ s: QueryEditorSession) -> [String] { s.steps.map(\.name) }

    // MARK: Steps

    func testRemovingAColumnAppendsAStepAndUpdatesThePreview() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        XCTAssertEqual(s.preview?.table.rowCount, 3)
        XCTAssertEqual(EditorCommands.command("pq.removeColumns")?.blocker(s), "Select one or more columns first.")
        s.clickColumn("A", toggle: false, range: false)
        await run("pq.removeColumns", s)
        XCTAssertEqual(names(s), ["Source", "Removed Columns"])
        XCTAssertEqual(s.steps.last?.expression, "Table.RemoveColumns(Source, {\"A\"})")
        XCTAssertEqual(s.preview?.table.columnNames, ["B"])
        XCTAssertTrue(s.hasPendingChanges)
        XCTAssertTrue(s.store.doc.queries[0].mScript == Self.table, "the document changes only on Apply")
    }

    func testATransformOnAnEarlierStepIsInsertedAfterIt() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.apply(.removeColumns(["A"]))
        s.selectStep(0)
        s.apply(.keepTopRows(2))
        await s.waitForPreview()
        XCTAssertEqual(names(s), ["Source", "Kept First Rows", "Removed Columns"])
        XCTAssertEqual(s.steps[2].expression, "Table.RemoveColumns(#\"Kept First Rows\", {\"A\"})")
        XCTAssertEqual(s.currentStepIndex, 1)
        XCTAssertEqual(s.preview?.table.columnNames, ["A", "B"], "the preview shows the inserted step")
        XCTAssertEqual(s.preview?.table.rowCount, 2)
        s.selectStep(nil)
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.column("B")?.values, [.string("x"), .string("y")])
    }

    func testRenameMoveAndDeleteSteps() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.apply(.keepTopRows(2))
        s.apply(.removeColumns(["A"]))
        s.renameStep(at: 1, to: "Top Two")
        XCTAssertEqual(s.steps[2].expression, "Table.RemoveColumns(#\"Top Two\", {\"A\"})")
        s.renameStep(at: 1, to: "Removed Columns")
        XCTAssertEqual(s.message?.text, "The query already has a step named “Removed Columns”.")
        s.moveStep(at: 2, by: -1)
        XCTAssertEqual(names(s), ["Source", "Removed Columns", "Top Two"])
        XCTAssertEqual(s.steps[1].expression, "Table.RemoveColumns(Source, {\"A\"})")
        XCTAssertEqual(s.steps[2].expression, "Table.FirstN(#\"Removed Columns\", 2)")
        s.deleteStep(at: 1)
        XCTAssertEqual(names(s), ["Source", "Top Two"])
        XCTAssertEqual(s.steps[1].expression, "Table.FirstN(Source, 2)")
        s.apply(.reverseRows)
        s.deleteUntilEnd(from: 1)
        XCTAssertEqual(names(s), ["Source"])
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.rowCount, 3)
    }

    func testFormulaBarEditsTheSelectedStepAndRejectsSyntaxErrors() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.apply(.keepTopRows(2))
        XCTAssertNil(s.setStepExpression("= Table.FirstN(Source, 1)"))
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.rowCount, 1)
        let before = s.selectedQuery?.mScript
        let problem = s.setStepExpression("= Table.FirstN(Source,")
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.hasPrefix("Expression.SyntaxError") ?? false)
        XCTAssertEqual(s.selectedQuery?.mScript, before)
        s.insertCustomStep()
        XCTAssertEqual(names(s), ["Source", "Kept First Rows", "Custom1"])
        XCTAssertEqual(s.steps[2].expression, "#\"Kept First Rows\"")
    }

    func testUndoAndRedo() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.apply(.reverseRows)
        XCTAssertEqual(s.undoName, "Reversed Rows")
        s.undo()
        XCTAssertEqual(names(s), ["Source"])
        XCTAssertFalse(s.hasPendingChanges)
        s.redo()
        XCTAssertEqual(names(s), ["Source", "Reversed Rows"])
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.column("A")?.values, [.int(3), .int(2), .int(1)])
    }

    func testGearEditsAStepInPlace() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.apply(.keepTopRows(2))
        s.apply(.removeColumns(["B"]))
        guard case .editStep(let edit)? = StepSettings.dialog(forStep: 1, in: s), case .keepTopRows(2) = edit.transform else {
            return XCTFail("Kept First Rows has a settings dialog")
        }
        XCTAssertEqual(edit.previous, "Source")
        XCTAssertNil(StepSettings.dialog(forStep: 2, in: s), "Removed Columns has no dialog")
        s.replaceStep(at: edit.index, with: .keepTopRows(1), previous: edit.previous)
        XCTAssertEqual(s.steps[1].expression, "Table.FirstN(Source, 1)")
        XCTAssertEqual(names(s), ["Source", "Kept First Rows", "Removed Columns"])
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.rowCount, 1)
    }

    // MARK: Commands

    func testCommandsFollowTheSelectedColumnsType() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.clickColumn("A", toggle: false, range: false)
        XCTAssertEqual(EditorCommands.command("pq.text.uppercase")?.blocker(s), "Select text columns.")
        XCTAssertNil(EditorCommands.command("pq.num.absolute")?.blocker(s))
        await run("pq.add.num.isEven", s)
        XCTAssertEqual(s.preview?.table.column("Is Even")?.values, [.bool(false), .bool(true), .bool(false)])
        s.clickColumn("B", toggle: false, range: false)
        await run("pq.text.uppercase", s)
        XCTAssertEqual(s.preview?.table.column("B")?.values, [.string("X"), .string("Y"), .string("Z")])
        await run("pq.moveToBeginning", s)
        XCTAssertEqual(s.preview?.table.columnNames, ["B", "A", "Is Even"])
        await run("pq.groupBy", s)
        if case .groupBy? = s.dialog {} else { XCTFail("Group By opens its dialog") }
    }

    func testUnpivotColumnsKeepsTheOthers() async throws {
        let wide = "let\n    Source = #table({\"Region\", \"Q1\", \"Q2\"}, {{\"N\", 1, 2}})\nin\n    Source"
        let s = await session([QueryDefinition(name: "W", mScript: wide)])
        s.clickColumn("Q1", toggle: false, range: false)
        s.clickColumn("Q2", toggle: true, range: false)
        await run("pq.unpivot", s)
        XCTAssertEqual(s.steps.last?.expression, "Table.UnpivotOtherColumns(Source, {\"Region\"}, \"Attribute\", \"Value\")")
        XCTAssertEqual(s.preview?.table.column("Attribute")?.values, [.string("Q1"), .string("Q2")])
    }

    func testAddAsNewQueryDrillsIntoTheColumn() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.clickColumn("B", toggle: false, range: false)
        await run("pq.addAsNewQuery", s)
        XCTAssertEqual(s.queries.map(\.name), ["T", "B"])
        XCTAssertEqual(s.selectedQuery?.name, "B")
        XCTAssertEqual(names(s), ["Source", "B"])
        XCTAssertEqual(s.preview?.valueKind, "list")
        await run("pq.toTable", s)
        XCTAssertEqual(s.preview?.valueKind, "table")
        XCTAssertEqual(s.preview?.table.rowCount, 3)
    }

    func testCombineFilesFromAFolderListing() async throws {
        let folder = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("k;v\n1;x\n".utf8).write(to: folder.appendingPathComponent("a.csv"))
        try Data("k;v\n2;y\n".utf8).write(to: folder.appendingPathComponent("b.csv"))
        let script = MScript.script(from: [MStep(name: "Source", expression: "Folder.Files(\(MSyntax.text(folder.path)))")])
        let s = await session([QueryDefinition(name: "Files", mScript: script)])
        await run("pq.combineFiles", s)
        await s.waitForPreview()
        XCTAssertEqual(names(s), ["Source", "Filtered Files", "Combined Files"])
        XCTAssertEqual(s.preview?.table.columnNames, ["k", "v", "Source.Name"])
        XCTAssertEqual(Set(s.preview?.table.column("v")?.values ?? []), [.string("x"), .string("y")])
    }

    // MARK: Queries

    func testRenamingAQueryRewritesItsReferences() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table), QueryDefinition(name: "U", mScript: "let\n    Source = T\nin\n    Source")])
        XCTAssertNil(s.renameQuery(s.queries[0].id, to: "Base Data"))
        XCTAssertEqual(s.queries[1].mScript, "let\n    Source = #\"Base Data\"\nin\n    Source")
        XCTAssertNotNil(s.renameQuery(s.queries[1].id, to: "base data"))
        XCTAssertEqual(s.queries[1].name, "U")
    }

    func testDeletingAReferencedQueryIsRefused() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table), QueryDefinition(name: "U", mScript: "let\n    Source = T\nin\n    Source")])
        let t = s.queries[0].id, u = s.queries[1].id
        XCTAssertEqual(s.deleteQueries([t]), "“T” can't be deleted because “U” refers to it.")
        XCTAssertEqual(s.queries.count, 2)
        XCTAssertNil(s.deleteQueries([t, u]))
        XCTAssertTrue(s.queries.isEmpty)
    }

    func testDuplicateReferenceAndGroups() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        let t = s.queries[0].id
        s.duplicateQuery(t)
        s.referenceQuery(t)
        XCTAssertEqual(s.queries.map(\.name), ["T", "T (2)", "T (3)"])
        XCTAssertEqual(s.queries[1].mScript, Self.table)
        XCTAssertEqual(s.queries[2].mScript, "let\n    Source = T\nin\n    Source")
        s.newGroup("Staging")
        XCTAssertEqual(s.groups, ["Staging"])
        s.moveQueries([t], toGroup: "Staging")
        XCTAssertEqual(s.queries[0].group, "Staging")
        s.renameGroup("Staging", to: "Raw")
        XCTAssertEqual(s.queries[0].group, "Raw")
        s.ungroup("Raw")
        XCTAssertEqual(s.groups, [])
        s.setLoadEnabled(t, false)
        XCTAssertFalse(s.queries[0].includeInRefresh, "a connection-only query is not refreshed")
    }

    // MARK: Parameters

    func testParametersFeedQueriesAndBecomeFunctions() async throws {
        let filtered = "let\n    Source = #table({\"Y\"}, {{2023}, {2024}}),\n    Filtered = Table.SelectRows(Source, each [Y] = Year)\nin\n    Filtered"
        let s = await session([QueryDefinition(name: "Sales", mScript: filtered)])
        var p = QueryParameter(); p.type = .integer; p.currentValue = .int(2024)
        XCTAssertNil(s.saveParameter(id: nil, name: "Year", description: "Fiscal year", parameter: p))
        let year = try XCTUnwrap(s.query(named: "Year"))
        XCTAssertEqual(year.kind, .parameter)
        XCTAssertEqual(year.mScript, "2024 meta [IsParameterQuery=true, Type=\"Number\", IsParameterQueryRequired=true]")
        XCTAssertFalse(year.loadEnabled)
        s.selectedQueryID = s.query(named: "Sales")?.id
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.rowCount, 1)
        XCTAssertNil(s.createFunction(from: try XCTUnwrap(s.selectedQueryID), named: "fxSales"))
        let fx = try XCTUnwrap(s.query(named: "fxSales"))
        XCTAssertEqual(fx.kind, .function)
        XCTAssertTrue(fx.mScript.hasPrefix("(Year as number) =>\n"))
        p.currentValue = .int(2023)
        XCTAssertNil(s.saveParameter(id: year.id, name: "FiscalYear", description: "", parameter: p))
        XCTAssertTrue(s.query(named: "Sales")?.mScript.contains("[Y] = FiscalYear") ?? false, "renaming a parameter rewrites its uses")
    }

    func testAFunctionQueryIsShownAsAFunctionAndInvoked() async throws {
        let s = await session([QueryDefinition(name: "fxDouble", mScript: "(x as number) => x * 2")])
        XCTAssertEqual(s.preview?.valueKind, "function")
        XCTAssertEqual(s.queries[0].kind, .function, "the editor learns the query is a function")
        XCTAssertEqual(FunctionInvokePanel.call("fxDouble", ["21"]), "fxDouble(21)")
        XCTAssertEqual(FunctionInvokePanel.call("fx Name", ["a", ""]), "#\"fx Name\"(\"a\", null)")
        let invoked = QueryDefinition(name: "Invoked Function", mScript: MScript.script(from: [MStep(name: "Source", expression: FunctionInvokePanel.call("fxDouble", ["21"]))]))
        s.addQuery(invoked, name: "Invoke Function")
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.columns.first?.values.first?.asDouble, 42)
    }

    func testConvertingBetweenQueryAndParameter() async throws {
        let s = await session([QueryDefinition(name: "Rate", mScript: "let\n    Source = 0.25\nin\n    Source")])
        let id = s.queries[0].id
        await s.convertToParameter(id)
        XCTAssertEqual(s.queries[0].kind, .parameter)
        XCTAssertEqual(s.queries[0].parameter?.currentValue.asDouble, 0.25)
        s.convertToQuery(id)
        XCTAssertEqual(s.queries[0].kind, .table)
        XCTAssertEqual(s.queries[0].mScript, "let\n    Source = 0.25\nin\n    Source")
        let table = await session([QueryDefinition(name: "T", mScript: Self.table)])
        await table.convertToParameter(table.queries[0].id)
        XCTAssertEqual(table.queries[0].kind, .table)
        XCTAssertEqual(table.message?.text, "Only a query that returns a single value can become a parameter.")
    }

    // MARK: Apply, discard, synchronisation

    func testApplyRenamesTablesRemovesConnectionOnlyQueriesAndLoadsNewOnes() async throws {
        var doc = FacetDocument()
        var t = QueryDefinition(name: "T", mScript: Self.table)
        t.loadEnabled = true
        let staging = QueryDefinition(name: "Staging", mScript: Self.table)
        doc.queries = [t, staging]
        for name in ["T", "Staging"] {
            doc.data[name] = DataTable(columnNames: ["A", "B"], rows: [[.int(1), .string("x")]], types: [.integer, .text])
            var m = ModelTable(name: name, columns: [ModelColumn(name: "A", dataType: .integer), ModelColumn(name: "B", dataType: .text)])
            m.sourceQuery = name
            doc.model.tables.append(m)
        }
        let store = DocumentStore(document: doc, services: .live())
        let s = QueryEditorSession(store: store, security: QuerySecurity(defaults: defaults))
        XCTAssertEqual(s.refreshPlan(), QueryEditorPlans.ApplyPlan())
        XCTAssertNotNil(EditorCommands.command("pq.apply")?.blocker(s), "nothing to apply")
        s.renameQuery(s.queries[0].id, to: "Facts")
        s.setLoadEnabled(s.queries[1].id, false)
        s.addQuery(QueryDefinition(name: "Extra", mScript: "let\n    Source = #table({\"K\"}, {{7}})\nin\n    Source"), name: "New")
        s.applyChanges()
        XCTAssertFalse(s.hasPendingChanges)
        XCTAssertEqual(store.doc.queries.map(\.name), ["Facts", "Staging", "Extra"])
        XCTAssertEqual(store.doc.model.tables.map(\.name).sorted(), ["Facts"])
        XCTAssertNotNil(store.doc.data["Facts"])
        XCTAssertNil(store.doc.data["Staging"])
        for _ in 0..<200 where store.doc.data["Extra"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.doc.data["Extra"]?.column("K")?.values, [.int(7)])
        XCTAssertEqual(store.doc.model.tables.first { $0.name == "Extra" }?.sourceQuery, "Extra")
    }

    func testDiscardForgetsPendingChanges() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.apply(.reverseRows)
        s.newBlankQuery()
        XCTAssertTrue(s.hasPendingChanges)
        s.discardChanges()
        XCTAssertEqual(s.queries, s.store.doc.queries)
        XCTAssertNil(s.undoName)
    }

    func testDocumentChangesReachAnOpenEditor() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table), QueryDefinition(name: "U", mScript: Self.table)])
        s.apply(.reverseRows)
        let edited = s.queries[0].mScript
        s.store.mutate("Get Data") { d in
            d.queries[1].description = "changed in the document"
            d.queries.append(QueryDefinition(name: "New", mScript: Self.table))
        }
        XCTAssertEqual(s.queries.map(\.name), ["T", "U", "New"])
        XCTAssertEqual(s.queries[0].mScript, edited, "the editor's edit is kept")
        XCTAssertEqual(s.queries[1].description, "changed in the document")
        XCTAssertEqual(s.baseline, s.store.doc.queries)
        // Get Data ▸ Transform Data routes its query to the editor.
        QueryEditorRouting.select("New", in: s.store)
        s.takeRoutedSelection()
        XCTAssertEqual(s.selectedQuery?.name, "New")
    }

    // MARK: Folding and diagnostics

    func testFoldingIndicatorsForADatabaseQuery() async throws {
        let path = dir.appendingPathComponent("shop.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("could not create the test database") }
        sqlite3_exec(db, "create table orders (id integer, item text); insert into orders values (1, 'Pen'), (2, 'Ink'), (3, 'Cap');", nil, nil, nil)
        sqlite3_close(db)
        let get = GetDataSession(store: DocumentStore(services: .live()), security: QuerySecurity(defaults: defaults))
        get.choose(try XCTUnwrap(DataConnector.connector("sqlite")), location: path)
        await get.connect()
        _ = await get.finish(.transform)
        let s = QueryEditorSession(store: get.store, security: get.security)
        XCTAssertEqual(s.selectedQuery?.name, "orders", "Transform Data selects the new query")
        s.apply(.filterRows(.compare(column: "id", .greaterThan, .int(1), type: .integer)))
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.rowCount, 2)
        XCTAssertEqual(s.folding["Filtered Rows"]?.indicator, .folded)
        XCTAssertNotNil(s.folding["Filtered Rows"]?.nativeQuery)
        XCTAssertNil(EditorCommands.command("pq.tools.nativeQuery")?.blocker(s))
        s.apply(.addIndexColumn(name: "Index", start: 0, increment: 1))
        await s.waitForPreview()
        XCTAssertEqual(s.folding["Added Index"]?.indicator, .notFolded)
    }

    /// A native query typed in the editor waits for Edit Permission ▸ Run, then evaluates; the approval is kept.
    func testANativeQueryInTheEditorAsksForPermission() async throws {
        let path = dir.appendingPathComponent("perm.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("could not create the test database") }
        sqlite3_exec(db, "create table t (n integer); insert into t values (1), (2), (3);", nil, nil, nil)
        sqlite3_close(db)
        let sql = "select n from t where n > 1"
        let script = "let\n    Source = Value.NativeQuery(Sqlite.Database(\(MSyntax.text(path))), \(MSyntax.text(sql)))\nin\n    Source"
        let s = await session([QueryDefinition(name: "Q", mScript: script)])
        XCTAssertNotNil(s.previewError)
        let request = try XCTUnwrap(s.permissionRequest)
        XCTAssertEqual(request.query, sql)
        XCTAssertEqual(request.sourceLocation, path)
        XCTAssertNotNil(s.queryErrors[try XCTUnwrap(s.selectedQueryID)], "the Queries pane marks the query")
        s.approvePermissionRequest()
        await s.waitForPreview()
        XCTAssertNil(s.previewError)
        XCTAssertNil(s.permissionRequest)
        XCTAssertEqual(s.preview?.table.column("n")?.values, [.int(2), .int(3)])
        XCTAssertTrue(s.queryErrors.isEmpty)
        XCTAssertTrue(s.security.isApproved(query: sql, kind: request.sourceKind, location: path))
    }

    /// Refresh All marks every failing query; fixing one clears its mark when its preview evaluates.
    func testFailingQueriesAreMarkedUntilTheyEvaluate() async throws {
        let s = await session([QueryDefinition(name: "Good", mScript: Self.table),
                               QueryDefinition(name: "Bad", mScript: "let\n    Source = error \"broken\"\nin\n    Source")])
        s.refreshAllPreviews()
        let marked = await Smoke.wait { !s.queryErrors.isEmpty }
        XCTAssertTrue(marked)
        let bad = try XCTUnwrap(s.query(named: "Bad")?.id)
        XCTAssertEqual(Array(s.queryErrors.keys), [bad])
        XCTAssertEqual(s.queryErrors[bad], "Expression.Error: broken")
        s.selectedQueryID = bad
        XCTAssertNil(s.setScript(Self.table))
        await s.waitForPreview()
        XCTAssertNil(s.queryErrors[bad])
    }

    /// The View tab starts as Settings ▸ Data ▸ Power Query Editor sets it.
    func testViewOptionsStartFromSettings() async throws {
        let options = try XCTUnwrap(UserDefaults(suiteName: suite + "-options"))
        defer { options.removePersistentDomain(forName: suite + "-options") }
        let store = DocumentStore(services: .live())
        let initial = QueryEditorSession(store: store, security: QuerySecurity(defaults: defaults), options: options)
        XCTAssertTrue(initial.showFormulaBar)
        XCTAssertTrue(initial.showQuality, "column quality is on by default")
        XCTAssertFalse(initial.showDistribution)
        XCTAssertFalse(initial.profileWholeDataset)
        for key in [AppSettings.Key.pqColumnDistribution, .pqColumnProfile, .pqProfilingWholeDataset, .pqMonospaced] { options.set(true, forKey: key.rawValue) }
        options.set(false, forKey: AppSettings.Key.pqFormulaBar.rawValue)
        options.set(false, forKey: AppSettings.Key.pqColumnQuality.rawValue)
        let chosen = QueryEditorSession(store: store, security: QuerySecurity(defaults: defaults), options: options)
        XCTAssertFalse(chosen.showFormulaBar)
        XCTAssertFalse(chosen.showQuality)
        XCTAssertTrue(chosen.showDistribution)
        XCTAssertTrue(chosen.showProfile)
        XCTAssertTrue(chosen.profileWholeDataset)
        XCTAssertTrue(chosen.monospaced)
    }

    /// The new editor's views switch the centre and show the diagram; with the preview feature off they are refused.
    func testNewEditorViewsFollowThePreviewSetting() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        await run("pq.view.schema", s)
        XCTAssertEqual(s.centreView, .schema)
        XCTAssertEqual(EditorCommands.command("pq.view.schema")?.isOn?(s), true)
        await run("pq.view.script", s)
        XCTAssertEqual(s.centreView, .script)
        await run("pq.view.diagram", s)
        XCTAssertTrue(s.showDiagram)
        await run("pq.view.data", s)
        XCTAssertEqual(s.centreView, .data)

        let options = try XCTUnwrap(UserDefaults(suiteName: suite + "-views"))
        defer { options.removePersistentDomain(forName: suite + "-views") }
        options.set(false, forKey: AppSettings.Key.previewNewQueryEditor.rawValue)
        let off = QueryEditorSession(store: s.store, security: s.security, options: options)
        XCTAssertFalse(off.newEditorViews)
        for id in ["pq.view.schema", "pq.view.script", "pq.view.diagram"] {
            XCTAssertEqual(EditorCommands.command(id)?.blocker(off), "Turn on “Diagram, schema and script views in the Power Query Editor” in Settings ▸ Preview features.", id)
        }
        XCTAssertNil(EditorCommands.command("pq.view.data")?.blocker(off))
    }

    /// The diagram puts each query after the queries it reads, lists its steps, and links them; sources are left out.
    func testDiagramCardsFollowTheDependencies() {
        let base = QueryDefinition(name: "Base", mScript: "let\n    Source = Csv.Document(File.Contents(\"/tmp/a.csv\")),\n    #\"Promoted Headers\" = Table.PromoteHeaders(Source)\nin\n    #\"Promoted Headers\"")
        let top = QueryDefinition(name: "Top", mScript: "let\n    Source = Base,\n    #\"Kept First Rows\" = Table.FirstN(Source, 2)\nin\n    #\"Kept First Rows\"")
        let alone = QueryDefinition(name: "Alone", mScript: Self.table)
        let (cards, edges) = QueryDiagramView.cards([base, top, alone])
        let byTitle = Dictionary(uniqueKeysWithValues: cards.map { ($0.node.title, $0) })
        XCTAssertEqual(byTitle["Base"]?.node.column, 0, "the file source is not a card")
        XCTAssertEqual(byTitle["Top"]?.node.column, 1)
        XCTAssertEqual(byTitle["Alone"]?.node.column, 0)
        XCTAssertEqual(byTitle["Base"]?.steps, ["Source", "Promoted Headers"])
        XCTAssertEqual(byTitle["Top"]?.steps, ["Source", "Kept First Rows"])
        XCTAssertEqual(edges, [DependencyLayout.Edge(from: "query:Base", to: "query:Top")])
        // 30 header + 2 steps × 19 + 6.
        XCTAssertEqual(byTitle["Top"].map(QueryDiagramView.height), 74)
    }

    func testDiagnosticsRecordWhatTheEngineEvaluated() async throws {
        let s = await session([QueryDefinition(name: "T", mScript: Self.table)])
        s.startDiagnostics()
        s.apply(.keepTopRows(2))
        await s.waitForPreview()
        s.stopDiagnostics()
        guard case .diagnostics(let events, _)? = s.dialog else { return XCTFail("diagnostics are shown") }
        XCTAssertTrue(events.contains { $0.query == "T" && $0.step == "Kept First Rows" && $0.rowCount == 2 })
        // The recorded events can be explored as a query.
        let engine = QueryEngine(queries: [QueryDefinition(name: "D", mScript: DiagnosticsDialog.script(for: events))], environment: QueryEnvironment())
        let table = try await engine.evaluate("D")
        XCTAssertEqual(table.columnNames, ["Query", "Step", "Duration (ms)", "Exclusive (ms)", "Rows", "Folding", "Native Query", "Error"])
        XCTAssertEqual(table.rowCount, events.count)
    }
}
