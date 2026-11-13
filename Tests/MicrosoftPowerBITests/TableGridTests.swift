import XCTest
import SwiftUI
import FacetCore
@testable import MicrosoftPowerBI

/// Pure Table-view logic: grid column planning, change tokens, the visible row order and copy
/// text.
final class TableGridTests: XCTestCase {
    private func fixture() -> (ModelTable, DataTable) {
        let product = ModelColumn(name: "Product", dataType: .text)
        var amount = ModelColumn(name: "Amount", dataType: .currency)
        amount.formatString = "$#,0.00"
        let qty = ModelColumn(name: "Qty", dataType: .integer)
        var key = ModelColumn(name: "Product Key", dataType: .integer)
        key.isKey = true
        let calc = ModelColumn(name: "Double", dataType: .decimal, expression: "[Amount] * 2")
        var bucket = ModelColumn(name: "Bucket", dataType: .text)
        bucket.grouping = ColumnGrouping(kind: .list, sourceColumn: "Product")
        let table = ModelTable(name: "Sales", columns: [product, amount, qty, key, calc, bucket])
        let data = DataTable(name: "Sales",
                             columnNames: ["Product", "Amount", "Qty", "Product Key", "Double", "Bucket"],
                             rows: [["Apple", 2.5, 4, 1, 5.0, "A"],
                                    ["Banana", 1.0, 2, 2, 2.0, "B"],
                                    ["Apple", 0.5, 1, 3, 1.0, "A"]],
                             types: [.text, .currency, .integer, .integer, .decimal, .text])
        return (table, data)
    }

    func testPlanMapsModelColumnsToData() throws {
        let (table, data) = fixture()
        var filter = GridColumnFilter()
        filter.conditions = [FilterCondition(op: .greaterThan, value: Value.int(1))]
        let plan = TableGrid.plan(for: table, data: data, filters: ["Qty": filter])

        XCTAssertEqual(plan.columns.map(\.name), ["Product", "Amount", "Qty", "Product Key", "Double", "Bucket"])
        XCTAssertEqual(try XCTUnwrap(plan.columns.first { $0.name == "Product" }).dataIndex, 0)
        XCTAssertEqual(try XCTUnwrap(plan.columns.first { $0.name == "Amount" }).format, "$#,0.00")
        XCTAssertTrue(try XCTUnwrap(plan.columns.first { $0.name == "Product Key" }).isKey)
        XCTAssertTrue(try XCTUnwrap(plan.columns.first { $0.name == "Double" }).isCalculated)
        XCTAssertTrue(try XCTUnwrap(plan.columns.first { $0.name == "Bucket" }).isCalculated, "a grouping column shows as calculated")
        XCTAssertTrue(try XCTUnwrap(plan.columns.first { $0.name == "Qty" }).isFiltered)
        XCTAssertFalse(try XCTUnwrap(plan.columns.first { $0.name == "Product" }).isFiltered)
        XCTAssertEqual(plan.dataToken, TableGrid.dataToken(data))
    }

    func testPlanFallsBackToDataColumnTypeForAny() throws {
        var table = ModelTable(name: "T", columns: [ModelColumn(name: "A", dataType: .any)])
        table.columns[0].dataType = .any
        let data = DataTable(name: "T", columnNames: ["A"], rows: [["x"]], types: [.text])
        let plan = TableGrid.plan(for: table, data: data, filters: [:])
        XCTAssertEqual(try XCTUnwrap(plan.columns.first)?.type, .text)
        // A model type other than .any is kept as is.
        let typed = ModelTable(name: "T2", columns: [ModelColumn(name: "A", dataType: .integer)])
        let typedPlan = TableGrid.plan(for: typed, data: data, filters: [:])
        XCTAssertEqual(try XCTUnwrap(typedPlan.columns.first)?.type, .integer)
    }

    func testPlanWithoutDataHasNoIndexes() {
        let (table, _) = fixture()
        let plan = TableGrid.plan(for: table, data: nil, filters: [:])
        XCTAssertEqual(plan.columns.count, 6)
        XCTAssertTrue(plan.columns.allSatisfy { $0.dataIndex == nil })
        XCTAssertEqual(plan.dataToken, 0)
    }

    func testDataTokenChangesWithShape() {
        let (_, data) = fixture()
        var bigger = data
        bigger.appendRow(["Pear", 3.0, 7, 4, 6.0, "C"])
        XCTAssertNotEqual(TableGrid.dataToken(bigger), TableGrid.dataToken(data), "added rows change the token")
        var wider = data
        wider.columns.append(DataColumn(name: "Extra", type: .text, values: ["1", "2", "3"]))
        XCTAssertNotEqual(TableGrid.dataToken(wider), TableGrid.dataToken(data), "added columns change the token")
        XCTAssertEqual(TableGrid.dataToken(nil), 0)
    }

    func testRowsSortAscendingAndDescending() {
        let (_, data) = fixture()
        var state = GridViewState()
        state.sortColumn = "Amount"
        state.ascending = true
        XCTAssertEqual(TableGrid.rows(for: data, state: state), [2, 1, 0], "0.5, 1.0, 2.5")
        state.ascending = false
        XCTAssertEqual(TableGrid.rows(for: data, state: state), [0, 1, 2])
    }

    func testRowsFilterByValuesAndConditions() {
        let (_, data) = fixture()
        var byValues = GridViewState()
        byValues.filters["Product"] = GridColumnFilter(selected: Set([Value.string("Apple")]))
        XCTAssertEqual(TableGrid.rows(for: data, state: byValues), [0, 2], "stored order, both Apples")
        // Value equality on text is case-insensitive, like the grid's conditions.
        var byCondition = GridViewState()
        byCondition.filters["Qty"] = GridColumnFilter(conditions: [FilterCondition(op: .greaterThan, value: Value.int(1))])
        XCTAssertEqual(TableGrid.rows(for: data, state: byCondition), [0, 1])
        var combined = GridViewState()
        combined.sortColumn = "Amount"
        combined.ascending = true
        combined.filters["Product"] = GridColumnFilter(selected: Set([Value.string("Apple")]))
        XCTAssertEqual(TableGrid.rows(for: data, state: combined), [2, 0], "filtered, then sorted")
        XCTAssertEqual(TableGrid.rows(for: data, state: GridViewState()), nil, "identity shows the table as stored")
        XCTAssertEqual(TableGrid.rows(for: nil, state: combined), nil)
    }

    func testTsvCopiesTheShownRowsWithHeaders() throws {
        let (table, data) = fixture()
        var state = GridViewState()
        state.sortColumn = "Amount"
        state.ascending = false
        let rows = try XCTUnwrap(TableGrid.rows(for: data, state: state))
        let plan = TableGrid.plan(for: table, data: data, filters: [:])
        let text = TableGrid.tsv(data: data, columns: plan.columns, rowIndex: rows, headers: true)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "Product\tAmount\tQty\tProduct Key\tDouble\tBucket")
        XCTAssertTrue(lines[1].hasPrefix("Apple\t"), "2.5 first in descending order")
        XCTAssertTrue(lines[2].hasPrefix("Banana\t"))
        XCTAssertTrue(lines[3].hasPrefix("Apple\t"))
        XCTAssertFalse(lines[1].hasSuffix("\t"), "every column has a data cell")
    }

    func testTsvFormatsValuesAndRendersBlankForMissingData() throws {
        let product = ModelColumn(name: "Product", dataType: .text)
        let amount = ModelColumn(name: "Amount", dataType: .decimal)
        let ghost = ModelColumn(name: "Ghost", dataType: .text)
        let table = ModelTable(name: "T", columns: [product, amount, ghost])
        let data = DataTable(name: "T", columnNames: ["Product", "Amount"],
                             rows: [["Apple", 2.5], ["Banana", 1.0]], types: [.text, .decimal])
        let plan = TableGrid.plan(for: table, data: data, filters: [:])
        XCTAssertTrue(try XCTUnwrap(plan.columns.first { $0.name == "Ghost" }).dataIndex == nil, "no data column")
        let text = TableGrid.tsv(data: data, columns: plan.columns, rowIndex: nil, headers: true)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "Apple\t2.50\t", "unformatted decimals show two places, missing data is blank")
        XCTAssertEqual(lines[2], "Banana\t1\t", "whole numbers lose the decimal point")
    }

    func testSortByCandidatesExcludesTheColumnItself() throws {
        let (table, _) = fixture()
        let product = try XCTUnwrap(table.column("Product"))
        let candidates = TableGrid.sortByCandidates(for: product, in: table)
        XCTAssertEqual(candidates.count, 5)
        XCTAssertFalse(candidates.contains { ModelDAX.same($0.name, "Product") })
    }

    // MARK: Review fixes

    /// A refresh can return the same shape with new values: the token follows the data revision.
    func testDataTokenChangesWithRevisionForTheSameShape() {
        let (table, data) = fixture()
        var refreshed = data
        refreshed.columns[1].values[0] = 99.0
        XCTAssertEqual(TableGrid.dataToken(refreshed), TableGrid.dataToken(data), "same shape, same revision: the token alone can't tell")
        XCTAssertNotEqual(TableGrid.dataToken(refreshed, revision: 1), TableGrid.dataToken(data, revision: 0))
        XCTAssertEqual(TableGrid.dataToken(data, revision: 3), TableGrid.dataToken(data, revision: 3))
        XCTAssertNotEqual(TableGrid.plan(for: table, data: data, filters: [:], revision: 1).dataToken,
                          TableGrid.plan(for: table, data: data, filters: [:], revision: 2).dataToken)
    }

    /// The grid reloads when its index token changes; an off-thread index arriving must change it.
    func testIndexTokenChangesWhenAnAsyncIndexArrives() {
        XCTAssertNotEqual(TableGrid.indexToken(gridRevision: 4, arrivals: 0), TableGrid.indexToken(gridRevision: 4, arrivals: 1))
        XCTAssertNotEqual(TableGrid.indexToken(gridRevision: 4, arrivals: 1), TableGrid.indexToken(gridRevision: 5, arrivals: 1))
        XCTAssertEqual(TableGrid.indexToken(gridRevision: 4, arrivals: 1), TableGrid.indexToken(gridRevision: 4, arrivals: 1))
    }

    func testRowIndexCacheComputesOncePerKey() {
        let (_, data) = fixture()
        var state = GridViewState()
        state.sortColumn = "Amount"
        let cache = RowIndexCache()
        let key = RowsKey(table: "Sales", dataToken: 7, gridRevision: 1)
        XCTAssertFalse(cache.lookup(key).hit)
        for _ in 0..<5 {
            XCTAssertEqual(cache.rows(for: key) { TableGrid.rows(for: data, state: state) }, [2, 1, 0])
        }
        XCTAssertEqual(cache.computations, 1, "five renders, one sort")
        XCTAssertTrue(cache.lookup(key).hit)

        // A new view state, new data or another table is a new key.
        state.ascending = false
        let next = RowsKey(table: "Sales", dataToken: 7, gridRevision: 2)
        XCTAssertFalse(cache.lookup(next).hit)
        XCTAssertEqual(cache.rows(for: next) { TableGrid.rows(for: data, state: state) }, [0, 1, 2])
        XCTAssertEqual(cache.computations, 2)
        XCTAssertFalse(cache.lookup(RowsKey(table: "Sales", dataToken: 8, gridRevision: 2)).hit)
        XCTAssertFalse(cache.lookup(RowsKey(table: "Other", dataToken: 7, gridRevision: 2)).hit)

        // What the off-thread path does: store under the key it was computed for. A nil order
        // (table as stored) is still a hit.
        let big = RowsKey(table: "Big", dataToken: 1, gridRevision: 9)
        cache.store(nil, for: big)
        XCTAssertTrue(cache.lookup(big).hit)
        XCTAssertNil(cache.lookup(big).rows)
        XCTAssertFalse(cache.lookup(next).hit, "one entry: the previous key is gone")
    }

    func testTsvKeepsTrailingBlankRows() {
        let table = ModelTable(name: "T", columns: [ModelColumn(name: "A", dataType: .text)])
        let data = DataTable(name: "T", columnNames: ["A"], rows: [["a"], [Value.null], [Value.null]], types: [.text])
        let plan = TableGrid.plan(for: table, data: data, filters: [:])
        XCTAssertEqual(TableGrid.tsv(data: data, columns: plan.columns, rowIndex: nil, headers: true), "A\na\n\n",
                       "header, a, and two blank rows: three line breaks, nothing trimmed")
        XCTAssertEqual(TableGrid.tsv(data: data, columns: plan.columns, rowIndex: nil, headers: false), "a\n\n")
        XCTAssertEqual(TableGrid.tsv(data: data, columns: plan.columns, rowIndex: [], headers: true), "A", "headers only")
        XCTAssertEqual(TableGrid.tsv(data: data, columns: plan.columns, rowIndex: [0, 7], headers: false), "a\n",
                       "a row outside the data is blank, not a crash")
    }

    func testTsvFlattensTabsAndLineBreaksInsideValues() {
        let table = ModelTable(name: "T", columns: [ModelColumn(name: "A", dataType: .text), ModelColumn(name: "B", dataType: .text)])
        let data = DataTable(name: "T", columnNames: ["A", "B"], rows: [["x\ty", "l1\nl2"]], types: [.text, .text])
        let plan = TableGrid.plan(for: table, data: data, filters: [:])
        XCTAssertEqual(TableGrid.tsv(data: data, columns: plan.columns, rowIndex: nil, headers: false), "x y\tl1 l2")
    }

    /// The grid's own copies go through the same builder as the workspace's.
    @MainActor
    func testGridCopyUsesTheSharedBuilder() {
        let (table, data) = fixture()
        var state = GridViewState()
        state.sortColumn = "Amount"
        state.ascending = true
        let rows = TableGrid.rows(for: data, state: state)
        let plan = TableGrid.plan(for: table, data: data, filters: [:])
        let grid = DataGrid(table: data, dataToken: plan.dataToken, columns: plan.columns, rowIndex: rows, indexToken: 0,
                            onSelectColumn: { _ in }, headerMenu: { _ in [] },
                            filterEditor: { _, _ in AnyView(EmptyView()) })
        let coordinator = DataGrid.Coordinator(grid)
        let view = GridTableView()
        coordinator.tableView = view
        coordinator.apply(grid, force: true)
        // Visible rows 0...1 are data rows 2 and 1 (amounts 0.5 and 1.0); columns 0...2.
        let text = coordinator.tsv(GridCellRange(rows: 0...1, columns: 0...2), headers: true)
        XCTAssertEqual(text, "Product\tAmount\tQty\nApple\t$0.50\t1\nBanana\t$1.00\t2")
        XCTAssertEqual(text, TableGrid.tsv(data: data, columns: Array(plan.columns[0...2]), rowIndex: [2, 1], headers: true))
        // A range past the end is clipped, not a crash.
        XCTAssertEqual(coordinator.tsv(GridCellRange(rows: 2...9, columns: 0...0), headers: false), "Apple")
    }

    func testCopyReportsTheRowsActuallyCopied() {
        let (_, data) = fixture()
        var state = GridViewState()
        state.filters["Product"] = GridColumnFilter(selected: Set([Value.string("Apple")]))
        let rows = TableGrid.rows(for: data, state: state)
        XCTAssertEqual(TableGrid.copiedRowCount(data: data, rowIndex: rows), 2, "two Apples of three rows")
        XCTAssertEqual(TableGrid.copiedRowCount(data: data, rowIndex: nil), 3)
        XCTAssertEqual(TableGrid.copiedRowCount(data: nil, rowIndex: nil), 0)
        XCTAssertEqual(TableGrid.copyMessage(rows: 2, of: "Sales"), "Copied 2 rows of Sales.")
        XCTAssertEqual(TableGrid.copyMessage(rows: 1, of: "Sales"), "Copied 1 row of Sales.")
    }

    func testViewStateCaptionSaysWhatIsApplied() {
        var state = GridViewState()
        XCTAssertEqual(TableGrid.viewStateCaption(state), "")
        state.sortColumn = "Qty"
        XCTAssertEqual(TableGrid.viewStateCaption(state), "sorted")
        state.filters["Qty"] = GridColumnFilter(selected: Set([Value.int(1)]))
        XCTAssertEqual(TableGrid.viewStateCaption(state), "sorted & filtered")
        state.sortColumn = nil
        XCTAssertEqual(TableGrid.viewStateCaption(state), "filtered")
        state.filters["Qty"] = GridColumnFilter()
        XCTAssertEqual(TableGrid.viewStateCaption(state), "", "an inactive filter is no filter")
    }

    func testSortByCandidatesExcludeColumnsWhoseChainReachesTheColumn() throws {
        // Month sorts by MonthNo; MonthNo sorts by Order. Order may not sort by Month or MonthNo.
        var month = ModelColumn(name: "Month", dataType: .text)
        month.sortByColumn = "MonthNo"
        var monthNo = ModelColumn(name: "MonthNo", dataType: .integer)
        monthNo.sortByColumn = "order"
        let order = ModelColumn(name: "Order", dataType: .integer)
        let year = ModelColumn(name: "Year", dataType: .integer)
        let table = ModelTable(name: "Date", columns: [month, monthNo, order, year])

        XCTAssertTrue(TableGrid.sortChain(from: "Month", reaches: "Order", in: table), "Month → MonthNo → Order")
        XCTAssertTrue(TableGrid.sortChain(from: "Order", reaches: "Order", in: table))
        XCTAssertFalse(TableGrid.sortChain(from: "Order", reaches: "Month", in: table))
        XCTAssertEqual(TableGrid.sortByCandidates(for: order, in: table).map(\.name), ["Year"])
        XCTAssertEqual(TableGrid.sortByCandidates(for: monthNo, in: table).map(\.name), ["Order", "Year"])
        XCTAssertEqual(TableGrid.sortByCandidates(for: month, in: table).map(\.name), ["MonthNo", "Order", "Year"])
        XCTAssertEqual(TableGrid.sortByCandidates(for: year, in: table).map(\.name), ["Month", "MonthNo", "Order"])

        // A cycle already stored in a document ends the walk instead of looping.
        var a = ModelColumn(name: "A", dataType: .text); a.sortByColumn = "B"
        var b = ModelColumn(name: "B", dataType: .text); b.sortByColumn = "A"
        let cyclic = ModelTable(name: "T", columns: [a, b, ModelColumn(name: "C", dataType: .text)])
        XCTAssertFalse(TableGrid.sortChain(from: "A", reaches: "C", in: cyclic))
    }

    func testSortByProblemRefusesCyclesAndAmbiguousOrder() {
        var month = ModelColumn(name: "Month", dataType: .text)
        month.sortByColumn = "MonthNo"
        let table = ModelTable(name: "Date", columns: [month, ModelColumn(name: "MonthNo", dataType: .integer),
                                                       ModelColumn(name: "Day", dataType: .integer)])
        XCTAssertNil(TableGrid.sortByProblem(column: "Month", by: "MonthNo", in: table, data: nil))
        XCTAssertNotNil(TableGrid.sortByProblem(column: "MonthNo", by: "Month", in: table, data: nil), "Month already sorts by MonthNo")
        XCTAssertNotNil(TableGrid.sortByProblem(column: "Month", by: "month", in: table, data: nil), "itself")
        XCTAssertNotNil(TableGrid.sortByProblem(column: "Month", by: "Missing", in: table, data: nil))
        XCTAssertNotNil(TableGrid.sortByProblem(column: "Missing", by: "Month", in: table, data: nil))

        // Jan ↔ 1 and Feb ↔ 2 on every row: fine. Day differs within Jan: not a sort order.
        let data = DataTable(name: "Date", columnNames: ["Month", "MonthNo", "Day"],
                             rows: [["Jan", 1, 1], ["Jan", 1, 2], ["Feb", 2, 1]], types: [.text, .integer, .integer])
        XCTAssertNil(TableGrid.sortByProblem(column: "Month", by: "MonthNo", in: table, data: data))
        XCTAssertNotNil(TableGrid.sortByProblem(column: "Month", by: "Day", in: table, data: data))
        // The other way round each Day value has one Month only on these rows? Day 1 → Jan and Feb: refused.
        XCTAssertNotNil(TableGrid.sortByProblem(column: "Day", by: "Month", in: table, data: data))
    }

    func testToolsFallBackToTheShownTableWhenTheSelectionIsGone() {
        var model = SemanticModel()
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal)])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        model.tables = [sales, ModelTable(name: "Product", columns: [ModelColumn(name: "Name", dataType: .text)])]

        XCTAssertEqual(TableGrid.toolsTarget(primary: .column(table: "sales", name: "amount"), shown: "Sales", model: model),
                       .column(table: "Sales", name: "Amount"), "resolved, with the model's spelling")
        XCTAssertEqual(TableGrid.toolsTarget(primary: .measure(table: "Sales", name: "Total"), shown: "Product", model: model),
                       .measure(table: "Sales", name: "Total"))
        // Undone or renamed away: the tools stay, on the shown table.
        XCTAssertEqual(TableGrid.toolsTarget(primary: .column(table: "Sales", name: "Gone"), shown: "Sales", model: model), .table("Sales"))
        XCTAssertEqual(TableGrid.toolsTarget(primary: .measure(table: "Old", name: "Total"), shown: "Product", model: model), .table("Product"))
        XCTAssertEqual(TableGrid.toolsTarget(primary: .table("Old"), shown: "Product", model: model), .table("Product"))
        XCTAssertEqual(TableGrid.toolsTarget(primary: .relationship(UUID()), shown: "Sales", model: model), .table("Sales"))
        XCTAssertEqual(TableGrid.toolsTarget(primary: nil, shown: "Sales", model: model), .table("Sales"))
    }
}
