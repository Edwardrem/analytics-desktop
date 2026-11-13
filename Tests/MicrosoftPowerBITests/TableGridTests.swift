import XCTest
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
}
