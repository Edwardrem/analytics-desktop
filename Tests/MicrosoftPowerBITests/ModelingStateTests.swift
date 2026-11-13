import XCTest
import Combine
import FacetCore
@testable import MicrosoftPowerBI

/// Modeling state that lives outside the document: which table and field commands act on, and the
/// Table view's view-only sort and filters as the model is renamed and deleted under them.
@MainActor
final class ModelingStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func model() -> SemanticModel {
        var model = SemanticModel()
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal),
                                                        ModelColumn(name: "ProductID", dataType: .integer)])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        let product = ModelTable(name: "Product", columns: [ModelColumn(name: "ProductID", dataType: .integer),
                                                            ModelColumn(name: "Name", dataType: .text)])
        model.tables = [sales, product]
        return model
    }

    private func store() -> DocumentStore {
        let store = DocumentStore(services: .live())
        let model = model()
        store.mutate("Load", invalidates: .layout) { $0.model = model }
        return store
    }

    private func filter(_ value: Value) -> GridColumnFilter { GridColumnFilter(selected: Set([value])) }

    // MARK: Command target

    func testTableViewShowsItsOwnTableOverAStaleSelection() {
        let model = model()
        let stale: [ModelObjectRef] = [.column(table: "Product", name: "Name")]
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .table, selection: stale, shown: "Sales", external: nil), "Sales")
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .model, selection: stale, shown: "Sales", external: nil), "Product",
                       "outside Table view the selection decides")
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .report, selection: [], shown: "Sales", external: nil), "Sales")
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .report, selection: [], shown: nil, external: nil), "Sales", "first table")
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .table, selection: [], shown: "Gone", external: nil), "Sales")
        XCTAssertNil(ModelingTarget.resolveTable(model: SemanticModel(), view: .table, selection: stale, shown: "Sales", external: nil))
    }

    func testALiveDataPaneContextWins() {
        let model = model()
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .table, selection: [.table("Sales")], shown: "Sales", external: "product"),
                       "Product", "the user pointed at Product in the Data pane")
        XCTAssertEqual(ModelingTarget.resolveTable(model: model, view: .table, selection: [], shown: "Sales", external: "Deleted"), "Sales")

        let selection: [ModelObjectRef] = [.measure(table: "Sales", name: "Total"), .column(table: "Sales", name: "Amount")]
        let column = ModelingTarget.resolveField(.column, model: model, selection: selection, external: .column("Product", "Name"))
        XCTAssertEqual(column?.table, "Product")
        XCTAssertEqual(column?.name, "Name")
        let fromSelection = ModelingTarget.resolveField(.column, model: model, selection: selection, external: nil)
        XCTAssertEqual(fromSelection?.name, "Amount")
        let measure = ModelingTarget.resolveField(.measure, model: model, selection: selection, external: .column("Product", "Name"))
        XCTAssertEqual(measure?.name, "Total", "a column in context does not hide the selected measure")
        XCTAssertNil(ModelingTarget.resolveField(.measure, model: model, selection: [.measure(table: "Sales", name: "Gone")], external: nil))
        XCTAssertNil(ModelingTarget.resolveField(.column, model: model, selection: [], external: nil))
    }

    /// The Data pane's context lasts for one command in one document.
    func testDataPaneContextIsScopedToItsDocumentAndCleared() {
        let first = store(), second = store()
        first.view = .table
        second.view = .table
        ModelingSelection.select(table: "Sales", in: first)
        ModelingSelection.select(table: "Sales", in: second)

        // Right-click Product in the Data pane ▸ New measure, while Table view shows Sales.
        FieldPaneContext.run("model.newMeasure", table: "Product", first)
        XCTAssertEqual(first.modeling.formula?.table, "Product")
        XCTAssertNil(FieldPaneContext.table(for: first), "cleared when the command returns")
        XCTAssertNil(ModelingTarget.externalTable(first))

        // The next command, from the ribbon, lands in the table on screen — in either window.
        first.modeling.formula = nil
        ModelingSelection.select(table: "Sales", in: first)
        AppCommands.run("model.newMeasure", first)
        XCTAssertEqual(first.modeling.formula?.table, "Sales")
        AppCommands.run("model.newMeasure", second)
        XCTAssertEqual(second.modeling.formula?.table, "Sales")
    }

    func testContextIsInvisibleToOtherDocumentsWhileACommandRuns() {
        let first = store(), second = store()
        var seen: (own: String?, other: String?) = (nil, nil)
        let id = "test.modelingTargetProbe"
        AppCommands.register { [AppCommand(id: id, title: "Probe", menu: .modeling) { _ in
            seen = (ModelingTarget.externalTable(first), ModelingTarget.externalTable(second))
        }] }
        FieldPaneContext.run(id, table: "Product", field: .column("Product", "Name"), first)
        XCTAssertEqual(seen.own, "Product")
        XCTAssertNil(seen.other)
        XCTAssertNil(ModelingTarget.externalField(first))
    }

    // MARK: Table view sort and filters

    func testGridStateFollowsARenamedTableAndColumn() {
        var states = GridViewStates()
        var state = GridViewState()
        state.sortColumn = "Amount"
        state.filters["Amount"] = filter(.int(1))
        state.filters["ProductID"] = filter(.int(2))
        states.set(state, for: "Sales")

        XCTAssertTrue(states.renameTable("sales", to: "Orders"))
        XCTAssertEqual(states.state(for: "Orders"), state)
        XCTAssertEqual(states.state(for: "Sales"), GridViewState(), "nothing left under the old name")
        XCTAssertFalse(states.renameTable("Sales", to: "Other"), "no state to move")

        XCTAssertTrue(states.renameColumn(table: "Orders", "amount", to: "Value"))
        let moved = states.state(for: "orders")
        XCTAssertEqual(moved.sortColumn, "Value")
        XCTAssertEqual(Set(moved.filters.keys), ["Value", "ProductID"])
        XCTAssertEqual(moved.filters["Value"], filter(.int(1)))
        XCTAssertFalse(states.renameColumn(table: "Orders", "Missing", to: "X"))
        XCTAssertFalse(states.renameColumn(table: "Nowhere", "Value", to: "X"))
    }

    func testGridStateIsPrunedToTheModel() {
        var states = GridViewStates()
        var sales = GridViewState()
        sales.sortColumn = "Gone"
        sales.filters["Amount"] = filter(.int(1))
        sales.filters["Gone"] = filter(.int(2))
        states.set(sales, for: "Sales")
        var old = GridViewState()
        old.filters["X"] = filter(.int(3))
        states.set(old, for: "Deleted")

        XCTAssertTrue(states.prune(to: model()))
        XCTAssertEqual(states.state(for: "Deleted"), GridViewState(), "a table created later under this name starts clean")
        let kept = states.state(for: "Sales")
        XCTAssertNil(kept.sortColumn)
        XCTAssertEqual(Array(kept.filters.keys), ["Amount"])
        XCTAssertFalse(states.prune(to: model()), "nothing more to drop")

        // Clearing the last sort or filter leaves no entry behind.
        states.set(GridViewState(), for: "Sales")
        XCTAssertTrue(states.isEmpty)
    }

    func testRenameAndDeleteThroughModelOpsKeepGridStateInStep() {
        let store = store()
        var state = GridViewState()
        state.sortColumn = "Amount"
        state.filters["ProductID"] = filter(.int(1))
        store.modeling.setGridState(state, for: "Sales")
        var other = GridViewState()
        other.filters["Name"] = filter(.string("Apple"))
        store.modeling.setGridState(other, for: "Product")

        XCTAssertTrue(ModelOps.renameColumn(store, table: "Sales", "Amount", to: "Value"))
        XCTAssertEqual(store.modeling.gridState(for: "Sales").sortColumn, "Value")
        XCTAssertTrue(ModelOps.renameTable(store, "Sales", to: "Orders"))
        XCTAssertEqual(store.modeling.gridState(for: "Orders").sortColumn, "Value")
        XCTAssertEqual(Array(store.modeling.gridState(for: "Orders").filters.keys), ["ProductID"])
        XCTAssertTrue(store.modeling.gridState(for: "Sales").isIdentity)

        ModelOps.delete(store, [.column(table: "Orders", name: "ProductID")])
        XCTAssertTrue(store.modeling.gridState(for: "Orders").filters.isEmpty, "the filtered column is gone")
        XCTAssertEqual(store.modeling.gridState(for: "Orders").sortColumn, "Value")

        ModelOps.delete(store, [.table("Product")])
        XCTAssertTrue(store.modeling.gridState(for: "Product").isIdentity)
        // Undo brings the table back; its view state does not come back with stale filters.
        store.undo()
        XCTAssertNotNil(store.model.table("Product"))
        XCTAssertTrue(store.modeling.gridState(for: "Product").isIdentity)
    }

    /// The grid's data token follows this counter, so a refresh that returns the same shape reloads.
    func testDataRevisionMovesWhenTheEnginePublishesData() {
        let store = store()
        let state = store.modeling
        let before = state.dataRevision
        let published = expectation(description: "engine published data")
        published.assertForOverFulfill = false
        let watch = state.$dataRevision.dropFirst().sink { _ in published.fulfill() }
        store.reloadEngine()
        wait(for: [published], timeout: 10)
        watch.cancel()
        XCTAssertGreaterThan(state.dataRevision, before)
    }
}
