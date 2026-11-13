import XCTest
import Combine
import FacetCore
@testable import MicrosoftPowerBI

/// The Model view against a real document store: edits are written through `mutate` (so they
/// undo), and pointer events drive selection, moves and relationship creation.
@MainActor
final class ModelViewStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    /// Sales (Amount, ProductID, OrderDate + Total) at (40, 40); Product (ProductID, Name) at
    /// (400, 40), on a user layout that is on screen. Sales has two rows for product 1.
    private func store() -> (DocumentStore, UUID) {
        let store = DocumentStore(services: .live())
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal),
                                                        ModelColumn(name: "ProductID", dataType: .integer),
                                                        ModelColumn(name: "OrderDate", dataType: .date)])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        let product = ModelTable(name: "Product", columns: [ModelColumn(name: "ProductID", dataType: .integer),
                                                            ModelColumn(name: "Name", dataType: .text)])
        var layout = ModelLayout(name: "Layout 1")
        layout.cards = ["Sales": ModelLayout.Card(x: 40, y: 40), "Product": ModelLayout.Card(x: 400, y: 40)]
        store.mutate("Load", invalidates: .layout) { d in
            d.model.tables = [sales, product]
            d.model.layouts.append(layout)
            d.data.tables["Sales"] = DataTable(name: "Sales", columnNames: ["Amount", "ProductID", "OrderDate"],
                                               rows: [[1.5, 1, Value.null], [2.5, 1, Value.null], [4.0, 2, Value.null]],
                                               types: [.decimal, .integer, .date])
            d.data.tables["Product"] = DataTable(name: "Product", columnNames: ["ProductID", "Name"],
                                                 rows: [[1, "Apple"], [2, "Pear"]], types: [.integer, .text])
        }
        store.view = .model
        store.modeling.layoutID = layout.id
        return (store, layout.id)
    }

    private func card(_ store: DocumentStore, _ layout: UUID, _ table: String) -> ModelLayout.Card? {
        store.model.layouts.first { $0.id == layout }?.cards[table]
    }

    func testTheModelWorkspaceIsRegistered() {
        XCTAssertNotNil(Features.workspaceBuilders[.model])
        XCTAssertNotNil(Features.workspaceBuilders[.table])
    }

    func testClicksSelectIntoTheModelingSelectionTheRibbonReads() {
        let (store, _) = store()
        let controller = ModelCanvasController(store: store)
        controller.mouseDown(at: CGPoint(x: 50, y: 97), clicks: 1, extend: false)
        controller.mouseUp()
        XCTAssertEqual(store.modeling.primary, .column(table: "Sales", name: "ProductID"))
        XCTAssertEqual(RibbonContext.current(store).modelObject, .column)

        controller.mouseDown(at: CGPoint(x: 50, y: 141), clicks: 1, extend: false)
        controller.mouseUp()
        XCTAssertEqual(store.modeling.primary, .measure(table: "Sales", name: "Total"))
        XCTAssertEqual(RibbonContext.current(store).modelObject, .measure)

        controller.mouseDown(at: CGPoint(x: 410, y: 50), clicks: 1, extend: false)
        controller.mouseUp()
        XCTAssertEqual(store.modeling.selection, [.table("Product")])
        XCTAssertEqual(RibbonContext.current(store).modelObject, .table)

        // ⌘-click adds; a click on empty canvas clears.
        controller.mouseDown(at: CGPoint(x: 50, y: 50), clicks: 1, extend: true)
        controller.mouseUp()
        XCTAssertEqual(store.modeling.selection, [.table("Product"), .table("Sales")])
        controller.mouseDown(at: CGPoint(x: 300, y: 300), clicks: 1, extend: false)
        controller.mouseUp()
        XCTAssertEqual(store.modeling.selection, [])
        XCTAssertNil(RibbonContext.current(store).modelObject)
    }

    func testDraggingAHeaderMovesTheCardInOneUndoStep() {
        let (store, layout) = store()
        let controller = ModelCanvasController(store: store)
        controller.mouseDown(at: CGPoint(x: 50, y: 50), clicks: 1, extend: false)
        controller.mouseDragged(to: CGPoint(x: 70, y: 60))
        XCTAssertEqual(card(store, layout, "Sales")?.x, 40, "nothing is written while dragging")
        XCTAssertEqual(controller.scene(store).card("Sales")?.frame.origin, CGPoint(x: 60, y: 50), "but the card follows the pointer")
        controller.mouseDragged(to: CGPoint(x: 100, y: 80))
        controller.mouseUp()
        XCTAssertEqual(card(store, layout, "Sales")?.x, 90)
        XCTAssertEqual(card(store, layout, "Sales")?.y, 70)
        XCTAssertEqual(card(store, layout, "Product")?.x, 400, "the other card stays")
        XCTAssertEqual(store.undoName, "Move Table")
        XCTAssertNil(controller.gesture)
        store.undo()
        XCTAssertEqual(card(store, layout, "Sales")?.x, 40)

        // At 50% zoom the same pointer travel moves the card twice as far in canvas points.
        store.modeling.zoom = 0.5
        controller.mouseDown(at: CGPoint(x: 25, y: 25), clicks: 1, extend: false)
        controller.mouseDragged(to: CGPoint(x: 55, y: 25))
        controller.mouseUp()
        XCTAssertEqual(card(store, layout, "Sales")?.x, 100, "40 + 30 / 0.5")

        // A click without travel writes nothing.
        let undo = store.undoName
        store.modeling.zoom = 1
        controller.mouseDown(at: CGPoint(x: 410, y: 50), clicks: 1, extend: false)
        controller.mouseDragged(to: CGPoint(x: 411, y: 51))
        controller.mouseUp()
        XCTAssertEqual(store.undoName, undo)
    }

    func testDraggingTheCornerResizesAndTheToggleCollapses() {
        let (store, layout) = store()
        let controller = ModelCanvasController(store: store)
        // Sales is 220 × 128; its corner handle is at (248…260, 156…168).
        controller.mouseDown(at: CGPoint(x: 255, y: 163), clicks: 1, extend: false)
        controller.mouseDragged(to: CGPoint(x: 295, y: 133))
        controller.mouseUp()
        XCTAssertEqual(card(store, layout, "Sales")?.width, 260)
        XCTAssertEqual(card(store, layout, "Sales")?.height, 98, "128 − 30")
        XCTAssertEqual(store.undoName, "Resize Table")
        // 98 holds (98 − 34 − 22 − 6) / 22 = 1 row; the "more" row brings the rest back.
        XCTAssertEqual(controller.scene(store).card("Sales")?.overflow, 3)
        controller.mouseDown(at: CGPoint(x: 50, y: 100), clicks: 1, extend: false)
        controller.mouseUp()
        XCTAssertEqual(controller.scene(store).card("Sales")?.overflow, 0)
        XCTAssertEqual(card(store, layout, "Sales")?.height, 128)

        controller.mouseDown(at: CGPoint(x: 290, y: 50), clicks: 1, extend: false)   // the toggle of the 260-wide card
        controller.mouseUp()
        XCTAssertEqual(card(store, layout, "Sales")?.collapsed, true)
        XCTAssertEqual(store.undoName, "Collapse Table")
        ModelLayoutOps.setAllCollapsed(store, false, layout: layout)
        XCTAssertEqual(card(store, layout, "Sales")?.collapsed, false)
    }

    func testDraggingAColumnOntoAColumnCreatesTheRelationship() {
        let (store, _) = store()
        let controller = ModelCanvasController(store: store)
        // Product[ProductID] (row 0 of the card at 400, 40) onto Sales[ProductID] (row 1 at 40, 40).
        controller.mouseDown(at: CGPoint(x: 410, y: 85), clicks: 1, extend: false)
        controller.mouseDragged(to: CGPoint(x: 300, y: 90))
        guard case .link(let table, let column, _, _, let none) = controller.gesture else { return XCTFail("not a relationship drag") }
        XCTAssertEqual([table, column], ["Product", "ProductID"])
        XCTAssertNil(none, "over empty canvas")

        // Over a column of the same table: refused; over text: refused; over the key: fine.
        controller.mouseDragged(to: CGPoint(x: 410, y: 107))
        XCTAssertEqual(target(controller)?.problem, "A relationship needs two different tables.")
        controller.mouseDragged(to: CGPoint(x: 50, y: 141))
        XCTAssertNil(target(controller), "a measure is not a drop target")
        controller.mouseDragged(to: CGPoint(x: 50, y: 119))
        XCTAssertEqual(target(controller)?.column, "OrderDate")
        XCTAssertNotNil(target(controller)?.problem, "whole number onto date")
        controller.mouseDragged(to: CGPoint(x: 50, y: 97))
        XCTAssertEqual(target(controller)?.column, "ProductID")
        XCTAssertNil(target(controller)?.problem)

        let created = expectation(description: "relationship written")
        created.assertForOverFulfill = false
        let watch = store.$doc.sink { if !$0.model.relationships.isEmpty { created.fulfill() } }
        controller.mouseUp()
        wait(for: [created], timeout: 10)
        watch.cancel()
        let r = store.model.relationships.first
        XCTAssertEqual(store.model.relationships.count, 1)
        XCTAssertEqual([r?.fromTable, r?.fromColumn, r?.toTable, r?.toColumn], ["Sales", "ProductID", "Product", "ProductID"],
                       "oriented many → one from the data, whichever way it was dragged")
        XCTAssertEqual(r?.cardinality, .manyToOne)
        XCTAssertEqual(r?.isActive, true)
        XCTAssertEqual(store.undoName, "New Relationship")
        XCTAssertEqual(controller.scene(store).edges.count, 1)
    }

    private func target(_ controller: ModelCanvasController) -> ModelCanvasController.LinkTarget? {
        guard case .link(_, _, _, _, let target) = controller.gesture else { return nil }
        return target
    }

    func testAnInvalidDropCreatesNothingAndSaysWhy() {
        let (store, _) = store()
        let controller = ModelCanvasController(store: store)
        controller.mouseDown(at: CGPoint(x: 410, y: 107), clicks: 1, extend: false)   // Product[Name], text
        controller.mouseDragged(to: CGPoint(x: 50, y: 97))                            // Sales[ProductID], whole number
        controller.mouseUp()
        XCTAssertTrue(store.model.relationships.isEmpty)
        XCTAssertEqual(store.status?.kind, .warning)
        XCTAssertEqual(store.status?.text.contains("matching data types"), true)
    }

    func testRelationshipEditsGoThroughValidationAndUndo() throws {
        let (store, _) = store()
        var first = Relationship(fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "ProductID")
        var second = Relationship(fromTable: "Sales", fromColumn: "Amount", toTable: "Product", toColumn: "ProductID")
        second.isActive = false
        store.updateModel("Load") { $0.relationships = [first, second] }

        first.crossFilter = .both
        XCTAssertNil(RelationshipOps.update(store, first))
        XCTAssertEqual(store.model.relationships.first?.crossFilter, .both)
        XCTAssertEqual(store.undoName, "Edit Relationship")
        XCTAssertNil(RelationshipOps.update(store, first), "no change, no undo step")

        second.isActive = true
        XCTAssertNotNil(RelationshipOps.update(store, second), "a second active path is refused")
        XCTAssertEqual(store.model.relationships.last?.isActive, false)

        // Sales[ProductID] repeats (two rows for product 1), so it can't be a "one" side.
        var oneToOne = first
        oneToOne.cardinality = .oneToOne
        XCTAssertEqual(RelationshipOps.update(store, oneToOne)?.contains("duplicate values"), true)
        XCTAssertEqual(store.model.relationships.first?.cardinality, .manyToOne)
        // Product[ProductID] is unique: the other way round is a valid one-to-many.
        XCTAssertNil(RelationshipOps.update(store, RelationshipLogic.swapped(first)))
        XCTAssertEqual(store.model.relationships.first?.cardinality, .oneToMany)
        XCTAssertEqual(store.model.relationships.first?.fromTable, "Product")

        store.modeling.select(.relationship(first.id))
        RelationshipOps.delete(store, first.id)
        XCTAssertEqual(store.model.relationships.map(\.id), [second.id])
        XCTAssertEqual(store.modeling.selection, [], "the selection does not keep a deleted line")
        XCTAssertEqual(RelationshipOps.update(store, first), "This relationship no longer exists.")
        store.undo()
        XCTAssertEqual(store.model.relationships.count, 2)
    }

    func testLayoutTabsArePersistedInTheDocument() {
        let (store, layout) = store()
        let created = ModelLayoutOps.addLayout(store)
        XCTAssertEqual(store.modeling.layoutID, created, "the new tab is shown")
        XCTAssertEqual(store.model.layouts.map(\.name), ["All tables", "Layout 1", "Layout 2"])
        XCTAssertTrue(store.isDirty)

        ModelLayoutOps.addTables(store, ["Product", "Missing"], layout: created)
        XCTAssertEqual(store.model.layouts.last?.cards.keys.sorted(), ["Product"])
        XCTAssertEqual(store.model.layouts.last?.cards["Product"]?.x, 40)
        ModelLayoutOps.addTables(store, ["sales"], layout: created)
        XCTAssertEqual(store.model.layouts.last?.cards["Sales"]?.x, 320, "to the right of Product: 40 + 220 + 60")
        ModelLayoutOps.removeTable(store, "Product", layout: created)
        XCTAssertEqual(store.model.layouts.last?.cards.keys.sorted(), ["Sales"])
        XCTAssertNotNil(store.model.table("Product"), "only taken off the layout")

        ModelLayoutOps.renameLayout(store, id: created, to: "Layout 1")
        XCTAssertEqual(store.model.layouts.last?.name, "Layout 2", "the name is taken")
        XCTAssertEqual(store.status?.kind, .warning)
        ModelLayoutOps.renameLayout(store, id: created, to: " Finance ")
        XCTAssertEqual(store.model.layouts.last?.name, "Finance")

        ModelLayoutOps.deleteLayout(store, id: created)
        XCTAssertEqual(store.model.layouts.count, 2)
        XCTAssertNil(store.modeling.layoutID)
        store.undo()
        XCTAssertEqual(store.model.layouts.last?.name, "Finance", "layouts undo like any other edit")
        _ = layout
    }

    func testMovingOneCardOnAllTablesStoresEveryCardWhereItIsShown() {
        let (store, _) = store()
        store.modeling.layoutID = nil
        let controller = ModelCanvasController(store: store)
        let before = controller.scene(store)
        // No relationships: a grid. Sales at (40, 40), Product at (320, 40).
        XCTAssertEqual(before.card("Product")?.frame.origin, CGPoint(x: 320, y: 40))
        controller.mouseDown(at: CGPoint(x: 50, y: 50), clicks: 1, extend: false)
        controller.mouseDragged(to: CGPoint(x: 50, y: 250))
        controller.mouseUp()
        let all = store.model.layouts.first { $0.showsAllTables }
        XCTAssertEqual(all?.cards["Sales"]?.y, 240)
        XCTAssertEqual(all?.cards["Product"]?.x, 320, "kept where it was shown, not re-flowed under Sales")
        XCTAssertEqual(all?.cards["Product"]?.y, 40)
        XCTAssertEqual(controller.scene(store).card("Product")?.frame.origin, CGPoint(x: 320, y: 40))

        ModelLayoutOps.autoArrange(store, layout: nil)
        XCTAssertEqual(store.undoName, "Auto Arrange")
        XCTAssertEqual(store.model.layouts.first { $0.showsAllTables }?.cards["Sales"]?.y, 40)
    }

    func testFitRevealAndDeleteFromTheDiagram() {
        let (store, _) = store()
        let controller = ModelCanvasController(store: store)
        controller.viewSize = CGSize(width: 1000, height: 600)
        controller.fit()
        // Bounds: x 40…620, y 40…168 → 580 × 128, centred in 1000 × 600 at 100%.
        XCTAssertEqual(store.modeling.zoom, 1)
        XCTAssertEqual(store.modeling.offset, CGSize(width: 170, height: 196), "(1000 − 580) / 2 − 40 and (600 − 128) / 2 − 40")
        controller.zoom(by: 2)
        XCTAssertEqual(store.modeling.zoom, 2)
        XCTAssertEqual(controller.viewport.toCanvas(CGPoint(x: 500, y: 300)), CGPoint(x: 330, y: 104), "the centre stays the centre")
        controller.resetZoom()
        XCTAssertEqual(store.modeling.zoom, 1)
        controller.reveal("Product")
        XCTAssertEqual(controller.viewport.toScreen(CGPoint(x: 510, y: 82)), CGPoint(x: 500, y: 300), "Product's middle is mid-view")
        controller.scroll(by: CGSize(width: -10, height: 5))
        XCTAssertEqual(controller.viewport.toScreen(CGPoint(x: 510, y: 82)), CGPoint(x: 490, y: 305))

        // Delete removes a selected relationship without asking.
        let r = Relationship(fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "ProductID")
        store.updateModel("Load") { $0.relationships = [r] }
        store.modeling.select(.relationship(r.id))
        controller.deleteSelection()
        XCTAssertTrue(store.model.relationships.isEmpty)
        XCTAssertEqual(store.undoName, "Delete Relationship")
    }

    func testDroppingATableFromTheExplorerAddsItToAUserLayout() {
        let (store, layout) = store()
        ModelLayoutOps.removeTable(store, "Product", layout: layout)
        let controller = ModelCanvasController(store: store)
        store.modeling.zoom = 0.5
        store.modeling.offset = CGSize(width: 100, height: 0)
        XCTAssertTrue(controller.dropTable("product", at: CGPoint(x: 300, y: 200)))
        XCTAssertEqual(card(store, layout, "Product")?.x, 400, "(300 − 100) / 0.5")
        XCTAssertEqual(card(store, layout, "Product")?.y, 400)
        XCTAssertEqual(store.modeling.primary, .table("Product"))
        XCTAssertFalse(controller.dropTable("Nope", at: .zero))
    }
}
