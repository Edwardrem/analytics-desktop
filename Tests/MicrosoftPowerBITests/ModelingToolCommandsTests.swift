import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// The Table tools / Column tools / Measure tools commands behind the ribbon's contextual tabs.
@MainActor
final class ModelingToolCommandsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func store() -> DocumentStore {
        let store = DocumentStore(services: .live())
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal),
                                                        ModelColumn(name: "Double", dataType: .decimal, expression: "[Amount] * 2")])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        var product = ModelTable(name: "Product", columns: [ModelColumn(name: "Name", dataType: .text)])
        product.sourceQuery = "Product"
        store.mutate("Load", invalidates: .layout) { $0.model.tables = [sales, product] }
        store.view = .model
        return store
    }

    private func enabled(_ id: String, _ store: DocumentStore) -> Bool {
        AppCommands.command(id)?.isEnabled(store) ?? false
    }

    func testTheRibbonsToolGroupsHaveCommands() {
        let ids = AppCommands.all.map(\.id)
        XCTAssertEqual(ids.filter { $0.hasPrefix("model.table.") },
                       ["model.table.rename", "model.table.hide", "model.table.refresh", "model.table.editFormula", "model.table.delete"])
        XCTAssertEqual(ids.filter { $0.hasPrefix("model.column.") },
                       ["model.column.dataType", "model.column.format", "model.column.summarizeBy", "model.column.dataCategory",
                        "model.column.hide", "model.column.rename", "model.column.editFormula", "model.column.delete"])
        XCTAssertEqual(ids.filter { $0.hasPrefix("model.measure.") },
                       ["model.measure.edit", "model.measure.format", "model.measure.dynamicFormat", "model.measure.homeTable", "model.measure.hide",
                        "model.measure.rename", "model.measure.delete"])
        XCTAssertTrue(ids.contains("model.sortByColumn"), "the Column tools tab places it by this id")
        let repeated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [], "no id is registered twice (the first registration would shadow the second)")
        XCTAssertTrue(RibbonLayout.unregisteredIDs(in: Set(ids)).allSatisfy { !$0.hasPrefix("model.table.") && $0 != "model.sortByColumn" })
    }

    func testCommandsFollowTheSelection() {
        let store = store()
        // Nothing selected: table commands act on the first table; column and measure commands are off.
        XCTAssertTrue(enabled("model.table.rename", store))
        XCTAssertFalse(enabled("model.column.dataType", store))
        XCTAssertFalse(enabled("model.sortByColumn", store))
        XCTAssertFalse(enabled("model.measure.edit", store))
        XCTAssertFalse(enabled("model.table.refresh", store), "Sales is not loaded by a query")
        XCTAssertFalse(enabled("model.table.editFormula", store), "nor is it a calculated table")

        store.modeling.select(.table("Product"))
        XCTAssertTrue(enabled("model.table.refresh", store))

        store.modeling.select(.column(table: "Sales", name: "Amount"))
        XCTAssertTrue(enabled("model.column.dataType", store))
        XCTAssertTrue(enabled("model.sortByColumn", store))
        XCTAssertFalse(enabled("model.column.editFormula", store), "a source column has no formula")
        XCTAssertFalse(enabled("model.measure.edit", store))
        store.modeling.select(.column(table: "Sales", name: "Double"))
        XCTAssertTrue(enabled("model.column.editFormula", store))

        store.modeling.select(.measure(table: "Sales", name: "Total"))
        XCTAssertTrue(enabled("model.measure.edit", store))
        XCTAssertFalse(enabled("model.column.hide", store))

        // A selection that no longer exists switches the tools off instead of acting on nothing.
        store.modeling.select(.column(table: "Sales", name: "Gone"))
        XCTAssertFalse(enabled("model.column.hide", store))
    }

    func testHideCommandsToggleAndShowTheirState() throws {
        let store = store()
        store.modeling.select(.column(table: "Sales", name: "Amount"))
        let hideColumn = try XCTUnwrap(AppCommands.command("model.column.hide"))
        XCTAssertEqual(hideColumn.isOn?(store), false)
        AppCommands.run("model.column.hide", store)
        XCTAssertEqual(store.model.table("Sales")?.column("Amount")?.isHidden, true)
        XCTAssertEqual(hideColumn.isOn?(store), true)
        XCTAssertEqual(store.undoName, "Hide in Report View")
        AppCommands.run("model.column.hide", store)
        XCTAssertEqual(store.model.table("Sales")?.column("Amount")?.isHidden, false)

        store.modeling.select(.measure(table: "Sales", name: "Total"))
        AppCommands.run("model.measure.hide", store)
        XCTAssertEqual(store.model.table("Sales")?.measure("Total")?.isHidden, true)

        store.modeling.select(.table("Product"))
        AppCommands.run("model.table.hide", store)
        XCTAssertEqual(store.model.table("Product")?.isHidden, true)
        XCTAssertEqual(store.model.table("Sales")?.isHidden, false)
        XCTAssertEqual(AppCommands.command("model.table.hide")?.isOn?(store), true)
    }

    func testEditFormulaCommandsOpenTheFormula() {
        let store = store()
        store.view = .table
        ModelingSelection.select(table: "Sales", in: store)
        store.modeling.select(.measure(table: "Sales", name: "Total"))
        AppCommands.run("model.measure.edit", store)
        XCTAssertEqual(store.modeling.formula?.text, "Total = SUM(Sales[Amount])")
        XCTAssertEqual(store.modeling.formula?.original, "Total")
        store.modeling.formula = nil
        store.modeling.select(.column(table: "Sales", name: "Double"))
        AppCommands.run("model.column.editFormula", store)
        XCTAssertEqual(store.modeling.formula?.text, "Double = [Amount] * 2")
        XCTAssertEqual(store.modeling.formula?.kind, .column)

        // In Model view there is no inline formula bar: the formula opens as a sheet.
        store.modeling.formula = nil
        store.view = .model
        store.modeling.select(.measure(table: "Sales", name: "Total"))
        AppCommands.run("model.measure.edit", store)
        XCTAssertNil(store.modeling.formula)
        XCTAssertNotNil(store.sheet)
    }

    func testSortByColumnIsValidatedWhenSet() {
        let store = store()
        store.mutate("Load", invalidates: .layout) { d in
            d.model.tables[0].columns[1].sortByColumn = "Amount"   // Double sorts by Amount
        }
        // Amount by Double would close the loop: refused, with the reason in the status bar.
        let refused = expectation(description: "refused")
        refused.assertForOverFulfill = false
        let watch = store.$status.sink { if $0?.kind == .warning { refused.fulfill() } }
        ModelOps.setSortByColumn(store, table: "Sales", column: "Amount", by: "Double")
        wait(for: [refused], timeout: 10)
        watch.cancel()
        XCTAssertNil(store.model.table("Sales")?.column("Amount")?.sortByColumn)

        ModelOps.setSortByColumn(store, table: "Sales", column: "Double", by: nil)
        XCTAssertNil(store.model.table("Sales")?.column("Double")?.sortByColumn)
        XCTAssertEqual(store.undoName, "Sort by Column")
    }

    func testDecimalPlacesAndThousandsEditTheFormatString() {
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "0.00", by: 1), "0.000")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "0.00", by: -1), "0.0")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "0.0", by: -1), "0", "the last place gone: a whole number")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "0", by: 1), "0.0", "a whole number gains a place")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "0", by: -1), "0", "never below zero places")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "$#,0.00", by: 1), "$#,0.000")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "0.0%", by: -1), "0%")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "Short Date", by: 1), "Short Date", "dates have no decimal places")
        XCTAssertEqual(FormatComposer.adjustingDecimals(of: "", by: 1), "", "General is left alone")

        XCTAssertEqual(FormatComposer.togglingThousands(of: "0.00"), "#,0.00")
        XCTAssertEqual(FormatComposer.togglingThousands(of: "#,0.00"), "0.00")
        XCTAssertEqual(FormatComposer.togglingThousands(of: "yyyy-mm-dd"), "yyyy-mm-dd")
    }

    func testFormatMenuAppliesPresets() throws {
        var applied: [String] = []
        let entries = ColumnMenus.format(current: "0.000") { applied.append($0) }
        func run(_ title: String, in entries: [ModelMenuEntry]) {
            for entry in entries {
                switch entry {
                case .item(let t, _, _, _, let action) where t == title: action()
                case .submenu(_, _, let children): run(title, in: children)
                default: break
                }
            }
        }
        run("General", in: entries)
        run("Whole number", in: entries)
        run("Percentage", in: entries)
        run("€", in: entries)
        run("2026-03-14", in: entries)
        run("Fewer decimal places", in: entries)
        run("Thousands separator", in: entries)
        XCTAssertEqual(applied, ["", "0", "0.0%", "€#,0.00", "yyyy-mm-dd", "0.00", "#,0.000"],
                       "percent starts at one place; currency at two with a separator")
        // The current kind is ticked.
        let ticked = entries.compactMap { entry -> String? in
            if case .item(let title, _, _, true, _) = entry { return title }
            return nil
        }
        XCTAssertEqual(ticked, ["Decimal number"])
    }
}
