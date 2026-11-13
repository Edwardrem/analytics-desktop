import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// The modeling dialogs' commands: registered, reachable from the ribbon and the Data pane, and acting on the right target.
@MainActor
final class ModelDialogCommandsTests: XCTestCase {
    /// Commands that open a dialog on a model with tables.
    private let dialogIDs = [
        "model.relationships", "model.newParameter", "model.newFieldParameter", "model.roles", "model.viewAs",
        "model.newHierarchy", "model.hierarchies", "model.markDateTable", "model.calendars",
        "model.calculationGroups", "model.functions", "model.incrementalRefresh", "model.aggregations",
        "model.perspectives", "model.translations", "model.synonyms", "model.prepForAI",
    ]
    /// Command ids the Data pane's context menus run (`Panes/FieldPanes/DataPaneMenus.swift`, `BuildPane.swift`).
    private let dataPaneIDs = [
        "model.newMeasure", "model.newColumn", "model.quickMeasure", "model.newTable", "model.markDateTable",
        "model.incrementalRefresh", "model.newHierarchy", "model.newGroup", "model.editMeasure",
    ]

    override func setUp() {
        super.setUp()
        Features.registerAll()
        FieldPaneContext.table = nil
        FieldPaneContext.field = nil
    }

    private func makeStore() -> DocumentStore {
        var doc = FacetDocument()
        doc.model = DialogFixture.model()
        doc.data = DialogFixture.data()
        return DocumentStore(document: doc, services: .live())
    }

    func testEveryDialogCommandIsRegistered() {
        for id in dialogIDs + dataPaneIDs + ["model.autodetectRelationships", "model.newGroup"] {
            XCTAssertNotNil(AppCommands.command(id), "\(id) is not registered")
        }
        // Each id is registered once: the dialogs replaced the earlier relationship, role and parameter sheets.
        let ids = AppCommands.all.map(\.id).filter { $0.hasPrefix("model.") }
        XCTAssertEqual(ids.count, Set(ids).count, "a model command is registered twice")
    }

    /// Sort by column was the last one missing; `ModelingToolCommands` registers it with the column tools.
    func testEveryModelCommandOnTheRibbonIsRegistered() {
        let registered = Set(AppCommands.all.map(\.id))
        let missing = RibbonLayout.unregisteredIDs(in: registered).filter { $0.hasPrefix("model.") }
        XCTAssertEqual(missing, [])
    }

    func testDialogCommandsPresentASheet() {
        let store = makeStore()
        for id in dialogIDs {
            store.dismissSheet()
            XCTAssertEqual(AppCommands.command(id)?.isEnabled(store), true, "\(id) is disabled on a model with tables")
            AppCommands.run(id, store)
            XCTAssertNotNil(store.sheet, "\(id) did not open its dialog")
        }
        store.dismissSheet()
    }

    func testDialogCommandsAreQuietOnAnEmptyModel() {
        let store = DocumentStore(services: .live())
        for id in dialogIDs where id != "model.newParameter" && id != "model.functions" {
            AppCommands.run(id, store)
            XCTAssertNil(store.sheet, "\(id) opened on a model with no tables")
        }
    }

    func testDataPaneCommandsActOnTheRightClickedObject() {
        let store = makeStore()
        store.modeling.select(.table("Product"))
        XCTAssertEqual(DialogTarget.table(store), "Product")
        // Groups need a column: nothing is selected, so the ribbon button is off…
        XCTAssertEqual(AppCommands.command("model.newGroup")?.isEnabled(store), false)
        AppCommands.run("model.newGroup", store)
        XCTAssertNil(store.sheet)
        // …but from the Data pane the right-clicked column is the target, whatever is selected elsewhere.
        FieldPaneContext.run("model.newGroup", table: "Sales", field: .column("Sales", "Region"), store)
        XCTAssertNotNil(store.sheet)
        XCTAssertNil(FieldPaneContext.table, "the Data pane's target must not leak into later commands")
        XCTAssertNil(FieldPaneContext.field)
        XCTAssertEqual(DialogTarget.table(store), "Product")

        FieldPaneContext.table = "Sales"
        XCTAssertEqual(DialogTarget.table(store), "Sales")
        XCTAssertNil(DialogTarget.column(store))
        FieldPaneContext.field = .measure("Sales", "Total")
        XCTAssertEqual(DialogTarget.measure(store)?.name, "Total")
        XCTAssertNil(DialogTarget.column(store), "a measure is not a column to group")
        FieldPaneContext.table = nil; FieldPaneContext.field = nil

        for id in dataPaneIDs where id != "model.newGroup" && id != "model.editMeasure" {
            store.dismissSheet()
            store.modeling.formula = nil
            FieldPaneContext.run(id, table: "Sales", field: nil, store)
            XCTAssertTrue(store.sheet != nil || store.modeling.formula != nil, "\(id) did nothing from the Data pane")
        }
        store.dismissSheet()
        FieldPaneContext.run("model.editMeasure", table: "Sales", field: .measure("Sales", "Total"), store)
        XCTAssertNotNil(store.sheet, "editing a measure opens the formula sheet")
    }

    func testGroupTargetEditsAnExistingGroupColumn() throws {
        let store = makeStore()
        var d = GroupingLogic.draft(source: try XCTUnwrap(store.model.table("Sales")?.column("Region")), table: store.model.tables[0])
        GroupingLogic.group([.string("East"), .string("West")], in: &d)
        store.mutate("New Group", invalidates: .model) { $0.model.tables[0].columns.append(GroupingLogic.column(from: d, sourceType: .text)) }
        store.modeling.select(.column(table: "Sales", name: "Region (groups)"))
        let target = try XCTUnwrap(ModelingDialogsFeature.groupTarget(store))
        XCTAssertEqual(target.source.name, "Region")
        XCTAssertEqual(target.existing?.name, "Region (groups)")
        store.modeling.select(.column(table: "Sales", name: "Region"))
        XCTAssertNil(try XCTUnwrap(ModelingDialogsFeature.groupTarget(store)).existing)
    }

    func testViewAsIsShownAsOnWhilePreviewing() {
        let store = makeStore()
        store.mutate("Manage Roles", invalidates: .model) { $0.model.roles = [SecurityRole(name: "West")] }
        XCTAssertEqual(AppCommands.command("model.viewAs")?.isOn?(store), false)
        store.viewAsRoles = ["West"]
        XCTAssertEqual(AppCommands.command("model.viewAs")?.isOn?(store), true)
    }

    func testDialogWritesAreUndoable() {
        let store = makeStore()
        let p = WhatIfParameter(name: "Discount", minimum: 0, maximum: 10, increment: 1, defaultValue: 0)
        store.mutate("New Parameter", invalidates: .model) { ParameterLogic.install(p, into: &$0.model) }
        XCTAssertNotNil(store.model.table("Discount"))
        XCTAssertEqual(store.undoName, "New Parameter")
        store.undo()
        XCTAssertNil(store.model.table("Discount"))
        XCTAssertEqual(store.model.whatIfParameters.count, 0)
    }

    func testCaptionsAndSynonymsFollowARename() {
        let store = makeStore()
        store.mutate("Setup", invalidates: .model) { d in
            var fr = Translation(culture: "fr-FR")
            fr.captions = ["Sales": "Ventes", "Sales[Total]": "Total des ventes", "Sales[Amount]": "Montant"]
            d.model.translations = [fr]
            d.model.qnaSynonyms = ["Sales[Total]": ["revenue"]]
        }
        XCTAssertTrue(ModelOps.renameMeasure(store, table: "Sales", "Total", to: "Revenue"))
        XCTAssertEqual(store.model.qnaSynonyms, ["Sales[Revenue]": ["revenue"]])
        XCTAssertEqual(store.model.translations[0].captions["Sales[Revenue]"], "Total des ventes")
        XCTAssertTrue(ModelOps.renameColumn(store, table: "Sales", "Amount", to: "Net"))
        XCTAssertEqual(store.model.translations[0].captions["Sales[Net]"], "Montant")
        XCTAssertTrue(ModelOps.renameTable(store, "Sales", to: "Orders"))
        XCTAssertEqual(store.model.translations[0].captions, ["Orders": "Ventes", "Orders[Revenue]": "Total des ventes", "Orders[Net]": "Montant"])
        XCTAssertEqual(store.model.qnaSynonyms, ["Orders[Revenue]": ["revenue"]])
    }
}
