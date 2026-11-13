import XCTest
import AppKit
import FacetCore
import FacetInterop
@testable import MicrosoftPowerBI

/// A small model with one object of every kind the TMDL tree lists.
private enum TMDLFixture {
    static func model() -> (SemanticModel, [QueryDefinition]) {
        var m = SemanticModel()
        m.name = "Contoso"
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Amount", dataType: .decimal), ModelColumn(name: "Customer Key", dataType: .integer)]
        sales.measures = [Measure(name: "Total Sales", expression: "SUM(Sales[Amount])")]
        sales.sourceQuery = "Sales"
        var customer = ModelTable(name: "Customer")
        customer.columns = [ModelColumn(name: "Customer Key", dataType: .integer), ModelColumn(name: "City", dataType: .text)]
        customer.hierarchies = [Hierarchy(name: "Geography", levels: ["City"])]
        m.tables = [sales, customer]
        m.calculationGroups = [CalculationGroup(name: "Time Intelligence")]
        m.relationships = [Relationship(fromTable: "Sales", fromColumn: "Customer Key", toTable: "Customer", toColumn: "Customer Key")]
        m.roles = [SecurityRole(name: "Sales West"), SecurityRole(name: "Everyone")]
        m.perspectives = [Perspective(name: "Executive")]
        m.translations = [Translation(culture: "fr-FR"), Translation(culture: "de-DE")]
        m.functions = [UserFunction(name: "AddTax", parameters: [FunctionParameter(name: "amount")], expression: "amount * 1.2")]
        let queries = [QueryDefinition(name: "Sales", mScript: "#table({\"Amount\"}, {{1}})"),
                       QueryDefinition(name: "BasePath", mScript: "\"/data/\"")]
        return (m, queries)
    }

    @MainActor static func store(model: SemanticModel, queries: [QueryDefinition]) -> DocumentStore {
        let store = DocumentStore(services: .live())
        store.mutate("Load", invalidates: .model) { d in
            d.model = model
            d.queries = queries
        }
        return store
    }

    @MainActor static func store() -> DocumentStore {
        let (m, q) = model()
        return store(model: m, queries: q)
    }

    /// The parser reports the unterminated name on line 2.
    static let brokenScript = "table X\n\tmeasure 'unterminated = 1\n"
}

@MainActor
final class TMDLViewSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    // MARK: Tabs

    func testTabsAddActivateRenameAndClose() {
        let session = TMDLViewSession.of(TMDLFixture.store())
        XCTAssertNil(session.activeTab)
        let a = session.addTab(), b = session.addTab(), c = session.addTab(name: "Named", text: "x")
        XCTAssertEqual(session.tabs.map(\.name), ["Script 1", "Script 2", "Named"])
        XCTAssertEqual(session.activeTab?.id, c)          // a new tab becomes the active one
        XCTAssertEqual(session.activeText, "x")

        guard let a, let b, let c else { return XCTFail("tabs were not created") }
        session.setActive(b)
        XCTAssertEqual(session.activeTab?.id, b)
        session.rename(b, to: "  Measures \n")
        session.rename(a, to: "   ")                      // a blank name is ignored
        XCTAssertEqual(session.tabs.map(\.name), ["Script 1", "Measures", "Named"])

        session.close(a)                                  // closing another tab keeps the active one
        XCTAssertEqual(session.activeTab?.id, b)
        session.close(b)                                  // closing the active tab moves to the one after it
        XCTAssertEqual(session.activeTab?.id, c)
        let d = session.addTab()
        XCTAssertEqual(session.tabs.last?.name, "Script 2")
        session.close(d ?? UUID())                        // closing the last tab moves to the one before it
        XCTAssertEqual(session.activeTab?.id, c)
        session.close(c)
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.activeTab)
        XCTAssertFalse(session.hasScript)
        session.close(UUID())                             // unknown ids are ignored
    }

    // MARK: Errors

    func testErrorsBelongToTheirTab() {
        let store = TMDLFixture.store()             // the session holds its store weakly
        let session = TMDLViewSession.of(store)
        guard let a = session.addTab(name: "A", text: TMDLFixture.brokenScript),
              let b = session.addTab(name: "B", text: "createOrReplace\n") else { return XCTFail("tabs were not created") }

        session.setActive(a)
        session.validate()
        XCTAssertEqual(session.error?.line, 2)
        // Line 2 starts after "table X\n" (8 units) and is 26 units long.
        XCTAssertEqual(session.issues.map(\.range), [8..<34])

        session.setActive(b)                              // tab B shows neither the error nor its underline
        XCTAssertNil(session.error)
        XCTAssertTrue(session.issues.isEmpty)
        session.setText("createOrReplace\n\n", for: b)    // editing B leaves A's error alone
        session.setActive(a)
        XCTAssertEqual(session.error?.line, 2)

        session.clearError()
        XCTAssertNil(session.error)
        session.validate()
        XCTAssertEqual(session.error?.line, 2)
        session.setText("table X\n", for: a)              // the line no longer lines up once A's text changes
        XCTAssertNil(session.error)

        session.report(TMDLError("Problem", line: 1), tab: b)
        XCTAssertNil(session.error)                       // reported against B while A is active
        XCTAssertEqual(session.errors[b]?.message, "Problem")
        session.close(b)
        XCTAssertNil(session.errors[b])
        session.report(TMDLError("Gone"), tab: b)         // a closed tab keeps no error
        XCTAssertTrue(session.errors.isEmpty)
    }

    func testLineRanges() {
        let text = "a\nbc\n"
        XCTAssertEqual(TMDLViewSession.range(ofLine: 1, in: text), 0..<1)
        XCTAssertEqual(TMDLViewSession.range(ofLine: 2, in: text), 2..<4)
        // The empty last line is an empty range at the end of the text, never one past it.
        XCTAssertEqual(TMDLViewSession.range(ofLine: 3, in: text), 5..<5)
        XCTAssertNil(TMDLViewSession.range(ofLine: 4, in: text))
        XCTAssertNil(TMDLViewSession.range(ofLine: 0, in: text))
        XCTAssertNil(TMDLViewSession.range(ofLine: -1, in: text))
        XCTAssertEqual(TMDLViewSession.range(ofLine: 1, in: ""), 0..<0)
        XCTAssertEqual(TMDLViewSession.range(ofLine: 2, in: "x\n\ny"), 2..<2)   // an empty line in the middle
        // Offsets are UTF-16 units, as text views count them: "é" is 1, "😀" is 2.
        XCTAssertEqual(TMDLViewSession.range(ofLine: 2, in: "é😀\nxy"), 4..<6)

        for line in 1...3 {
            guard let r = TMDLViewSession.range(ofLine: line, in: text) else { return XCTFail("line \(line)") }
            XCTAssertLessThanOrEqual(r.upperBound, (text as NSString).length)
        }
        XCTAssertEqual(TMDLViewSession.clamped(5..<5, toLength: 5), NSRange(location: 5, length: 0))
        XCTAssertEqual(TMDLViewSession.clamped(3..<10, toLength: 6), NSRange(location: 3, length: 3))
        XCTAssertEqual(TMDLViewSession.clamped(8..<9, toLength: 5), NSRange(location: 5, length: 0))
        XCTAssertEqual(TMDLViewSession.clamped(0..<1, toLength: 0), NSRange(location: 0, length: 0))
    }

    // MARK: Tree search

    private func outline(_ search: String) -> TMDLModelOutline {
        let (m, q) = TMDLFixture.model()
        return TMDLModelOutline(model: m, shared: TMDL.sharedExpressions(model: m, queries: q), search: search)
    }

    func testOutlineWithoutSearchListsEverything() {
        let o = outline("")
        XCTAssertEqual(o.visibleSections, TMDLModelOutline.Section.allCases)
        XCTAssertEqual(TMDLModelOutline.Section.allCases.map(o.count), [3, 1, 2, 1, 2, 1, 1])
        XCTAssertEqual(o.tables.map(\.name), ["Sales", "Customer"])
        XCTAssertEqual(o.members(of: o.tables[0]).map(\.ref),
                       [.measure(table: "Sales", name: "Total Sales"), .column(table: "Sales", name: "Amount"),
                        .column(table: "Sales", name: "Customer Key")])
        XCTAssertEqual(o.rows(.tables).map(\.ref), [.calculationGroup("Time Intelligence")])
        XCTAssertEqual(o.rows(.expressions).map(\.name), ["BasePath"])   // "Sales" is a table partition
        XCTAssertTrue(o.showsProperties)
        XCTAssertFalse(o.isEmpty)
    }

    func testSearchFiltersEverySectionAndItsCount() {
        // A table matches by name (all its members stay) or through a member (only that member stays);
        // a relationship matches through either end.
        let cust = outline("cust")
        XCTAssertEqual(cust.visibleSections, [.tables, .relationships])
        XCTAssertEqual(cust.tables.map(\.name), ["Sales", "Customer"])
        XCTAssertEqual(cust.members(of: cust.tables[0]).map(\.name), ["Customer Key"])
        XCTAssertEqual(cust.members(of: cust.tables[1]).map(\.name), ["Customer Key", "City", "Geography"])
        XCTAssertEqual(cust.count(.tables), 2)
        XCTAssertEqual(cust.rows(.relationships).map(\.name), ["Sales[Customer Key] → Customer[Customer Key]"])
        XCTAssertEqual(cust.count(.roles), 0)
        XCTAssertFalse(cust.showsProperties)

        XCTAssertEqual(outline("WEST").visibleSections, [.roles])                 // case-insensitive
        XCTAssertEqual(outline("west").rows(.roles).map(\.ref), [.role("Sales West")])
        XCTAssertEqual(outline("exec").visibleSections, [.perspectives])
        XCTAssertEqual(outline("fr-").rows(.cultures).map(\.ref), [.culture("fr-FR")])
        XCTAssertEqual(outline("fr-").count(.cultures), 1)
        XCTAssertEqual(outline("addt").visibleSections, [.functions])
        XCTAssertEqual(outline("basep").visibleSections, [.expressions])
        XCTAssertEqual(outline("basep").count(.expressions), 1)

        let time = outline("time")                                                 // only the calculation group
        XCTAssertEqual(time.visibleSections, [.tables])
        XCTAssertTrue(time.tables.isEmpty)
        XCTAssertEqual(time.count(.tables), 1)

        let geo = outline("geog")                                                  // a hierarchy keeps its table
        XCTAssertEqual(geo.tables.map(\.name), ["Customer"])
        XCTAssertEqual(geo.members(of: geo.tables[0]).map(\.ref), [.hierarchy(table: "Customer", name: "Geography")])

        XCTAssertTrue(outline("zzz").isEmpty)
        XCTAssertTrue(outline("zzz").visibleSections.isEmpty)
        XCTAssertFalse(outline("contoso").isEmpty)                                 // the model's own name
        XCTAssertTrue(outline("prop").showsProperties)
        XCTAssertEqual(outline("  ").visibleSections, TMDLModelOutline.Section.allCases)   // blank is no search
    }

    // MARK: Drag payload

    func testTreeDragTravelsAsItsOwnTypeNotAsText() {
        let refs: [TMDLObjectRef] = [.model, .table("Sales [2024]"), .measure(table: " T ", name: "Total [All]"),
                                     .column(table: "'Q", name: "It's"), .relationship(UUID()), .expression("Base Path")]
        for ref in refs {
            XCTAssertEqual(TMDLDragPayload.decode(TMDLDragPayload.encode(ref)), ref)
        }
        XCTAssertNil(TMDLDragPayload.decode(Data("some dragged text".utf8)))
        XCTAssertNil(TMDLDragPayload.decode(Data([0xFF, 0xFE])))

        let board = NSPasteboard(name: NSPasteboard.Name("tmdl-drag-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(TMDLDragPayload.encode(.table("Sales")), forType: TMDLDragPayload.pasteboardType)
        XCTAssertNil(board.availableType(from: [.string]))       // nothing a text view would insert
        XCTAssertEqual(board.data(forType: TMDLDragPayload.pasteboardType).flatMap(TMDLDragPayload.decode), .table("Sales"))
        XCTAssertTrue(TMDLDragPayload.itemProvider(for: .table("Sales")).registeredTypeIdentifiers == [TMDLDragPayload.typeIdentifier])
    }

    // MARK: Commands

    private func command(_ id: String) -> AppCommand? { TMDLViewFeature.commands().first { $0.id == id } }
    private func enabled(_ id: String, _ store: DocumentStore) -> Bool { command(id)?.isEnabled(store) ?? false }

    func testCommandsAreEnabledExactlyWhenTheViewShowsItsEditor() {
        XCTAssertFalse(TMDLViewSession.hasContent(model: SemanticModel(), queries: []))
        XCTAssertTrue(TMDLViewSession.hasContent(model: SemanticModel(), queries: [QueryDefinition(name: "Q", mScript: "1")]))
        XCTAssertTrue(TMDLViewSession.hasContent(model: TMDLFixture.model().0, queries: []))

        // Nothing to script: every command is off, in any view.
        let empty = TMDLFixture.store(model: SemanticModel(), queries: [])
        FieldPaneContext.table = nil; FieldPaneContext.field = nil
        for view in [WorkspaceView.report, .tmdl] {
            empty.view = view
            for c in TMDLViewFeature.commands() { XCTAssertFalse(c.isEnabled(empty), "\(c.id) in \(view)") }
        }

        // Queries only: the view shows its editor, so its commands work.
        let store = TMDLFixture.store(model: SemanticModel(), queries: [QueryDefinition(name: "Q", mScript: "1")])
        let session = TMDLViewSession.of(store)
        store.view = .report
        XCTAssertTrue(enabled("tmdl.newTab", store))            // switches to the view, so it works from any view
        XCTAssertFalse(enabled("tmdl.scriptModel", store))
        XCTAssertFalse(enabled("tmdl.validate", store))
        store.view = .tmdl
        XCTAssertTrue(enabled("tmdl.scriptModel", store))
        XCTAssertFalse(enabled("tmdl.script", store))           // nothing selected in the tree
        XCTAssertFalse(enabled("tmdl.validate", store))         // no script yet
        XCTAssertFalse(enabled("tmdl.apply", store))
        session.selectedRef = .expression("Q")
        XCTAssertTrue(enabled("tmdl.script", store))
        command("tmdl.scriptModel")?.run(store)
        XCTAssertTrue(session.activeText.hasPrefix("createOrReplace\n"))
        XCTAssertTrue(enabled("tmdl.validate", store))
        XCTAssertTrue(enabled("tmdl.apply", store))
        command("tmdl.newTab")?.run(store)                      // an empty tab has nothing to validate
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertFalse(enabled("tmdl.validate", store))
    }

    func testEveryCommandReachesTheRibbonTMDLTab() {
        let registry = TMDLViewFeature.commands().map {
            RibbonCommandInfo(id: $0.id, title: $0.title, symbol: $0.symbol, menu: $0.menu, separatorBefore: $0.separatorBefore)
        }
        let tab = RibbonLayout.visibleTabs(RibbonContext(view: .tmdl), registry: registry).first { $0.id == .tmdl }
        XCTAssertEqual(tab?.groups.map(\.title), ["Script"])
        XCTAssertEqual(tab?.groups.first?.items.map(\.control), [
            .button(RibbonCommand(id: "tmdl.script", label: "Script as TMDL", symbol: "arrow.down.doc")),
            .button(RibbonCommand(id: "tmdl.scriptModel", label: "Script Whole Model", symbol: "shippingbox")),
            .button(RibbonCommand(id: "tmdl.newTab", label: "New Script Tab", symbol: "plus.square.on.square")),
            .button(RibbonCommand(id: "tmdl.validate", label: "Validate Script", symbol: "checkmark.seal")),
            .button(RibbonCommand(id: "tmdl.apply", label: "Apply Script with Preview…", symbol: "arrow.up.doc")),
        ])
        // The tab belongs to the TMDL view only, and the registered commands are the ones under test.
        XCTAssertNil(RibbonLayout.visibleTabs(RibbonContext(view: .report), registry: registry).first { $0.id == .tmdl })
        for c in TMDLViewFeature.commands() { XCTAssertNotNil(AppCommands.command(c.id), c.id) }
    }

    func testScriptAsTMDLFromTheDataPane() {
        let store = TMDLFixture.store()
        let session = TMDLViewSession.of(store)
        store.view = .report
        session.addTab(name: "Scratch", text: "keep me")
        FieldPaneContext.table = nil; FieldPaneContext.field = nil
        XCTAssertFalse(enabled("tmdl.script", store))           // no Data pane target yet

        // What the Data pane's context menu does for a measure.
        FieldPaneContext.run("tmdl.script", table: "Sales", field: .measure("Sales", "Total Sales"), store)
        XCTAssertEqual(store.view, .tmdl)
        XCTAssertEqual(session.tabs.map(\.name), ["Scratch", "Sales"])
        XCTAssertEqual(session.tabs.first?.text, "keep me")     // the script gets a tab of its own
        // The measure under a reference to its table (its lineage tag follows).
        XCTAssertTrue(session.activeText.hasPrefix("createOrReplace\n\n\tref table Sales\n\n\t\tmeasure 'Total Sales' = SUM(Sales[Amount])\n"),
                      session.activeText)
        XCTAssertFalse(session.activeText.contains("column Amount"))
        XCTAssertEqual(session.selectedRef, .measure(table: "Sales", name: "Total Sales"))
        XCTAssertNil(FieldPaneContext.table)                    // used once
        XCTAssertNil(FieldPaneContext.field)

        // A column, then a table.
        store.view = .report
        FieldPaneContext.run("tmdl.script", table: "Customer", field: .column("Customer", "City"), store)
        XCTAssertEqual(session.selectedRef, .column(table: "Customer", name: "City"))
        XCTAssertTrue(session.activeText.hasPrefix("createOrReplace\n\n\tref table Customer\n\n\t\tcolumn City\n"))
        store.view = .table
        FieldPaneContext.run("tmdl.script", table: "Customer", field: nil, store)
        XCTAssertEqual(session.selectedRef, .table("Customer"))
        XCTAssertTrue(session.activeText.hasPrefix("createOrReplace\n\n\ttable Customer\n"))
        XCTAssertEqual(session.tabs.count, 4)

        // In the TMDL view the command scripts the tree selection into the active tab.
        XCTAssertEqual(store.view, .tmdl)
        session.selectedRef = .role("Everyone")
        AppCommands.run("tmdl.script", store)
        XCTAssertEqual(session.tabs.count, 4)
        XCTAssertTrue(session.activeText.contains("\n\n\trole Everyone\n"))

        // An object that no longer exists is reported, not scripted.
        store.view = .report
        FieldPaneContext.run("tmdl.script", table: "Gone", field: nil, store)
        XCTAssertEqual(session.tabs.count, 4)
        XCTAssertEqual(store.status?.kind, .error)
    }

    // MARK: Apply

    func testPreviewIsComputedOnceInTheBackgroundAndApplyIsUndoable() async {
        let store = TMDLFixture.store()
        let session = TMDLViewSession.of(store)
        let script = "createOrReplace\n\n\tref table Sales\n\n\t\tmeasure 'Order Count' = COUNTROWS(Sales)\n"
        guard let tab = session.addTab(text: script) else { return XCTFail("no tab") }

        let preview = TMDLApplyPreview()
        preview.start(script: script, model: store.model, queries: store.doc.queries)
        guard case .computing = preview.state else { return XCTFail("the preview must not be computed on the caller's turn") }
        await preview.finish()
        guard case .ready(let result) = preview.state else { return XCTFail("the preview did not finish") }
        XCTAssertEqual(result.summary.changes.map(\.description), ["added measure Sales[Order Count]"])
        XCTAssertNil(TMDLApplySheet.blockedReason(result))
        XCTAssertNil(store.model.table("Sales")?.measure("Order Count"))   // previewing writes nothing

        session.apply(result, tab: tab)
        XCTAssertEqual(store.model.table("Sales")?.measure("Order Count")?.expression, "COUNTROWS(Sales)")
        XCTAssertEqual(store.status?.text, "Applied: 1 added, 0 changed, 0 removed. You can undo this.")
        store.undo()
        XCTAssertNil(store.model.table("Sales")?.measure("Order Count"))
        XCTAssertEqual(store.model.table("Sales")?.measures.map(\.name), ["Total Sales"])

        // A script that matches the model has nothing to apply.
        let same = TMDLViewSession.computeApply(script: "createOrReplace\n\n\tref table Sales\n\n\t\tmeasure 'Total Sales' = SUM(Sales[Amount])\n",
                                                model: store.model, queries: store.doc.queries)
        guard case .success(let unchanged) = same else { return XCTFail("the unchanged script failed") }
        XCTAssertTrue(unchanged.summary.isEmpty)
        XCTAssertNotNil(TMDLApplySheet.blockedReason(unchanged))
    }

    func testFailedPreviewReportsTheLineOnTheTabItCameFrom() async {
        let store = TMDLFixture.store()
        let session = TMDLViewSession.of(store)
        guard let broken = session.addTab(text: TMDLFixture.brokenScript), let other = session.addTab(text: "createOrReplace\n") else {
            return XCTFail("tabs were not created")
        }
        let preview = TMDLApplyPreview()
        preview.start(script: TMDLFixture.brokenScript, model: store.model, queries: store.doc.queries) { error in
            session.report(error, tab: broken)
        }
        await preview.finish()
        guard case .failed(let error) = preview.state else { return XCTFail("the broken script was accepted") }
        XCTAssertEqual(error.line, 2)
        XCTAssertEqual(session.activeTab?.id, other)
        XCTAssertNil(session.error)                              // the active tab is the other one
        XCTAssertEqual(session.errors[broken]?.line, 2)
        XCTAssertEqual(store.status?.kind, .error)
    }
}
