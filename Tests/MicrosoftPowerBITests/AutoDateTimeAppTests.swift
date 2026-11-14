import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Auto date/time and relationship detection in the app: the option for new files, the Data pane's
/// date hierarchy, visual queries over hierarchy levels, and autodetect when tables are loaded.
@MainActor
final class AutoDateTimeAppTests: XCTestCase {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let name = "AutoDateTimeAppTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        for (k, v) in values { d.set(v, forKey: k) }
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return d
    }

    func testNewFilesTakeTheGlobalOption() {
        XCTAssertTrue(DocumentStore.newDocument(defaults: defaults([AppSettings.Key.autoDateTime.rawValue: true])).model.autoDateTime)
        XCTAssertFalse(DocumentStore.newDocument(defaults: defaults([AppSettings.Key.autoDateTime.rawValue: false])).model.autoDateTime)
        // Unset: the registered default (off).
        XCTAssertFalse(DocumentStore.newDocument(defaults: defaults([:])).model.autoDateTime)
    }

    func testTheFileOverridesTheGlobalAutodetectOption() {
        var doc = FacetDocument()
        let on = defaults([AppSettings.Key.autodetectRelationships.rawValue: true])
        let off = defaults([AppSettings.Key.autodetectRelationships.rawValue: false])
        XCTAssertTrue(DataLoadOptions.autodetectRelationships(for: doc, defaults: on))
        XCTAssertFalse(DataLoadOptions.autodetectRelationships(for: doc, defaults: off))
        doc.model.autodetectRelationships = false
        XCTAssertFalse(DataLoadOptions.autodetectRelationships(for: doc, defaults: on))
        doc.model.autodetectRelationships = true
        XCTAssertTrue(DataLoadOptions.autodetectRelationships(for: doc, defaults: off))
    }

    func testDateLevelsAreWrittenAsVariationReferences() {
        let year = FieldRef.dateLevel("Sales", "Order Date", "Year")
        XCTAssertEqual(ModelDAX.reference(year), "'Sales'[Order Date].[Year]")
        XCTAssertEqual(year.caption, "Year")
        XCTAssertNotEqual(year.key, FieldRef.column("Sales", "Order Date").key)
        // As a value, a level is counted (Power BI's implicit "Count" of a column is COUNTA).
        XCTAssertEqual(ModelDAX.aggregate(year, model: SemanticModel()), "COUNTA('Sales'[Order Date].[Year])")
    }

    func testTheDateHierarchyNodeStandsForItsFourLevels() {
        let column = ModelColumn(name: "Order Date", dataType: .date)
        let node = DataNode(id: "dh|Sales|Order Date", depth: 2, kind: .dateHierarchy(column: column), table: "Sales")
        XCTAssertEqual(node.fieldRefs.map(\.daxReference), [
            "'Sales'[Order Date].[Year]", "'Sales'[Order Date].[Quarter]", "'Sales'[Order Date].[Month]", "'Sales'[Order Date].[Day]",
        ])
        XCTAssertEqual(node.name, "Date Hierarchy")
        let month = DataNode(id: "dh|Sales|Order Date|Month", depth: 3, kind: .dateLevel(column: column, level: "Month"), table: "Sales")
        XCTAssertEqual(month.fieldRef?.dateLevel, "Month")
        XCTAssertEqual(month.name, "Month")
    }

    /// Sales: 2023-05-01 10, 2024-01-15 20, 2024-02-20 30, 2024-11-30 40 → 2023: 10, 2024: 90;
    /// 2024 by month: January 20, February 30, November 40.
    func testVisualsGroupByHierarchyLevels() throws {
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Order Date", dataType: .date), ModelColumn(name: "Amount", dataType: .integer)])
        sales.columns[0].formatString = "d MMM yyyy"
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        var model = SemanticModel()
        model.tables = [sales]
        model.autoDateTime = true
        func day(_ s: String) throws -> Value { .date(try XCTUnwrap(DateParsing.parse(s))) }
        let data = DataTable(name: "Sales", columnNames: ["Order Date", "Amount"], rows: [
            [try day("2023-05-01"), 10], [try day("2024-01-15"), 20], [try day("2024-02-20"), 30], [try day("2024-11-30"), 40],
        ], types: [.date, .integer])
        let service = LiveCalculation()
        XCTAssertTrue(service.load(model: model, data: DataStore(tables: ["Sales": data]), roles: [], userName: "").isEmpty)

        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        spec.setFields(.category, [.dateLevel("Sales", "Order Date", "Year")])
        spec.setFields(.values, [.measure("Sales", "Total")])
        let byYear = service.visualData(spec: spec, request: VisualRequest())
        XCTAssertNil(byYear.error, byYear.daxQuery)
        var years: [String: Double] = [:]
        for r in 0..<byYear.table.rowCount { years[byYear.table[r, 0].asString] = byYear.table[r, 1].asDouble }
        XCTAssertEqual(years, ["2023": 10, "2024": 90])
        XCTAssertEqual(byYear.formats.first, "", "a year is not formatted with the date column's format")

        spec.setFields(.category, [.dateLevel("Sales", "Order Date", "Month")])
        var filter = FilterSpec(field: .dateLevel("Sales", "Order Date", "Year"))
        filter.values = [.int(2024)]
        var request = VisualRequest()
        request.filters = [filter]
        let byMonth = service.visualData(spec: spec, request: request)
        XCTAssertNil(byMonth.error, byMonth.daxQuery)
        var months: [String: Double] = [:]
        for r in 0..<byMonth.table.rowCount { months[byMonth.table[r, 0].asString] = byMonth.table[r, 1].asDouble }
        XCTAssertEqual(months, ["January": 20, "February": 30, "November": 40])
    }

    /// Product[ProductID] is unique; Sales[ProductID] repeats, so loading Sales relates it many-to-one.
    func testLoadingANewTableAutodetectsItsRelationshipsInOneUndoStep() async {
        let store = DocumentStore(services: .live())
        store.installTables([DataTable(name: "Product", columnNames: ["ProductID", "Name"], rows: [[1, "A"], [2, "B"]], types: [.integer, .text])])
        store.updateModel("Option") { $0.autodetectRelationships = true }
        XCTAssertTrue(store.model.relationships.isEmpty)
        store.installTables([DataTable(name: "Sales", columnNames: ["ProductID", "Qty"], rows: [[1, 5], [1, 2], [2, 7]], types: [.integer, .integer])])
        let r = store.model.relationships.first
        XCTAssertEqual(store.model.relationships.count, 1)
        XCTAssertEqual(r.map { "\($0.fromTable)[\($0.fromColumn)] → \($0.toTable)[\($0.toColumn)]" }, "Sales[ProductID] → Product[ProductID]")
        store.undo()
        XCTAssertNil(store.model.table("Sales"))
        XCTAssertTrue(store.model.relationships.isEmpty, "the relationship goes with the load it came from")

        store.updateModel("Option") { $0.autodetectRelationships = false }
        store.installTables([DataTable(name: "Sales", columnNames: ["ProductID", "Qty"], rows: [[1, 5], [1, 2], [2, 7]], types: [.integer, .integer])])
        XCTAssertNotNil(store.model.table("Sales"))
        XCTAssertTrue(store.model.relationships.isEmpty, "the file turned autodetect off")
    }
}
