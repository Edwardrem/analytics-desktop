import XCTest
import FacetCore
import FacetAnalytics
@testable import MicrosoftPowerBI

/// Automatically find clusters on a scatter chart of Total Sales against Total Profit by store,
/// and on a table of the same numbers.
///
/// | Store | Sales | Profit |
/// | A | 1    | 1    |
/// | B | 1.2  | 0.9  |
/// | C | 0.9  | 1.1  |
/// | D | 10   | 10   |
/// | E | 10.2 | 9.8  |
/// | F | 9.9  | 10.1 |
/// | G | 5    | —    |
///
/// A, B, C sit together near (1, 1) and D, E, F near (10, 10), far apart: two clusters separate
/// them best. Both have three stores, so the one with the smaller centre, A–C, is Cluster 1. G has
/// no profit, so it isn't a point and lands in Other. By cluster, Total Sales is
/// 1 + 1.2 + 0.9 = 3.1, 10 + 10.2 + 9.9 = 30.1, and Other 5.
@MainActor
final class ClusterFieldsTests: XCTestCase {
    private let store = FieldRef.column("Stores", "Store")
    private let sales = FieldRef.measure("Stores", "Total Sales")
    private let profit = FieldRef.measure("Stores", "Total Profit")

    private func model() -> SemanticModel {
        var t = ModelTable(name: "Stores", columns: [
            ModelColumn(name: "Store", dataType: .text), ModelColumn(name: "Sales", dataType: .decimal),
            ModelColumn(name: "Profit", dataType: .decimal),
        ])
        t.measures = [Measure(name: "Total Sales", expression: "SUM(Stores[Sales])"),
                      Measure(name: "Total Profit", expression: "SUM(Stores[Profit])")]
        var m = SemanticModel()
        m.tables = [t]
        return m
    }

    private func data() -> DataStore {
        let rows: [(String, Double, Double?)] = [("A", 1, 1), ("B", 1.2, 0.9), ("C", 0.9, 1.1), ("D", 10, 10),
                                                 ("E", 10.2, 9.8), ("F", 9.9, 10.1), ("G", 5, nil)]
        var s = DataStore()
        s["Stores"] = DataTable(name: "Stores", columnNames: ["Store", "Sales", "Profit"],
                                rows: rows.map { [.string($0.0), .double($0.1), $0.2.map(Value.double) ?? .null] },
                                types: [.text, .decimal, .decimal])
        return s
    }

    private func engine(_ m: SemanticModel? = nil) -> CalculationService {
        let engine = Services.live().makeCalculation()
        _ = engine.load(model: m ?? model(), data: data(), roles: [], userName: "")
        return engine
    }

    private func scatter() -> VisualSpec {
        var v = VisualSpec(type: .scatter, frame: Frame(x: 0, y: 0, width: 400, height: 300), name: "Stores")
        v.setFields(.details, [store]); v.setFields(.x, [sales]); v.setFields(.y, [profit])
        return v
    }

    private func table() -> VisualSpec {
        var v = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 400, height: 300), name: "Stores")
        v.setFields(.values, [store, sales, profit])
        return v
    }

    private func document(_ visual: VisualSpec) -> FacetDocument {
        var d = FacetDocument()
        d.model = model()
        var page = Page(name: "Page 1")
        page.visuals = [visual]
        d.report.pages = [page]
        return d
    }

    private func clusters(_ spec: VisualSpec, k: Int? = nil) throws -> ColumnGrouping {
        let plan = try XCTUnwrap(ClusterFields.plan(spec: spec, model: model()))
        let field = try XCTUnwrap(plan.candidates.first)
        let found = ClusterFields.points(field: field, measures: plan.measures, request: VisualRequest(), engine: engine())
        XCTAssertEqual(found.skipped, 1, "G has no profit")
        return try ClusterFields.grouping(source: field.name, members: found.members, points: found.points, clusters: k)
    }

    func testAScatterChartClustersItsDetailsOnXAndY() throws {
        let plan = try XCTUnwrap(ClusterFields.plan(spec: scatter(), model: model()))
        XCTAssertEqual(plan.candidates.map(\.key), [store.key])
        XCTAssertEqual(plan.measures.map(\.key), [sales.key, profit.key])
        let g = try clusters(scatter())
        XCTAssertEqual(g.kind, .list)
        XCTAssertEqual(g.sourceColumn, "Store")
        XCTAssertEqual(Set(g.groups.keys), ["Cluster 1", "Cluster 2"])
        XCTAssertEqual(g.groups["Cluster 1"], ["A", "B", "C"].map(Value.string))
        XCTAssertEqual(g.groups["Cluster 2"], ["D", "E", "F"].map(Value.string))
        XCTAssertEqual(g.otherGroupName, "Other")
    }

    func testAChosenNumberOfClustersIsKept() throws {
        let g = try clusters(scatter(), k: 3)
        XCTAssertEqual(g.groups.count, 3)
        XCTAssertEqual(g.groups.values.flatMap { $0 }.map(\.asString).sorted(), ["A", "B", "C", "D", "E", "F"], "every store once")
    }

    func testATableClustersOnEveryNumberColumn() throws {
        let plan = try XCTUnwrap(ClusterFields.plan(spec: table(), model: model()))
        XCTAssertEqual(plan.candidates.map(\.key), [store.key])
        XCTAssertEqual(plan.measures.map(\.key), [sales.key, profit.key])
        XCTAssertEqual(try clusters(table()).groups["Cluster 1"], ["A", "B", "C"].map(Value.string))
    }

    func testOnlyScatterChartsWithDetailsXAndYAndTablesWithANumberOffer() {
        var noDetails = scatter()
        noDetails.setFields(.details, [])
        XCTAssertNil(ClusterFields.plan(spec: noDetails, model: model()))
        var onlyText = table()
        onlyText.setFields(.values, [store])
        XCTAssertNil(ClusterFields.plan(spec: onlyText, model: model()))
        var line = scatter()
        line.type = .line
        XCTAssertNil(ClusterFields.plan(spec: line, model: model()))
    }

    func testTheFieldIsNamedAfterItsSourceAndNamesMustBeFree() {
        XCTAssertEqual(ClusterFields.defaultName(for: store, model: model()), "Store (clusters)")
        var m = model()
        m.tables[0].columns.append(ModelColumn(name: "Store (clusters)", dataType: .text))
        XCTAssertEqual(ClusterFields.defaultName(for: store, model: m), "Store (clusters) 2")
        XCTAssertEqual(ClusterFields.problems(name: "Store (clusters)", field: store, model: m),
                       ["A column named “Store (clusters)” already exists in Stores."])
        XCTAssertEqual(ClusterFields.problems(name: "  ", field: store, model: m), ["Name the clusters."])
        XCTAssertEqual(ClusterFields.problems(name: "Total Sales", field: store, model: m), ["“Total Sales” is already a measure in Stores."])
        XCTAssertTrue(ClusterFields.problems(name: "Segments", field: store, model: m).isEmpty)
    }

    func testTheClusterFieldIsAModelGroupUsableInAnyVisual() throws {
        let column = ClusterFields.column(name: "Store (clusters)", description: " Stores by sales and profit ", grouping: try clusters(scatter()))
        XCTAssertEqual(column.dataType, .text)
        XCTAssertEqual(column.description, "Stores by sales and profit")
        var d = document(scatter())
        let id = try XCTUnwrap(d.report.pages.first?.visuals.first?.id)
        ClusterFields.apply(column, table: "Stores", source: store, visualID: id, to: &d)
        XCTAssertEqual(d.model.table("Stores")?.column("Store (clusters)")?.grouping?.sourceColumn, "Store")
        XCTAssertEqual(d.report.pages.first?.visuals.first?.fields(.legend).map(\.name), ["Store (clusters)"], "the scatter chart's legend")
        // The engine computes the group column, so a column chart can total by cluster.
        let e = engine(d.model)
        var chart = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        chart.setFields(.category, [.column("Stores", "Store (clusters)")])
        chart.setFields(.values, [sales])
        let result = e.visualData(spec: chart, request: VisualRequest())
        var totals: [String: Double] = [:]
        for r in 0..<result.table.rowCount { totals[result.table[r, 0].asString] = result.table[r, 1].asDouble }
        XCTAssertEqual(totals["Cluster 1"] ?? 0, 3.1, accuracy: 1e-9)
        XCTAssertEqual(totals["Cluster 2"] ?? 0, 30.1, accuracy: 1e-9)
        XCTAssertEqual(totals["Other"], 5)
    }

    func testOnATableTheFieldFollowsItsSourceColumn() throws {
        var d = document(table())
        let id = try XCTUnwrap(d.report.pages.first?.visuals.first?.id)
        let column = ClusterFields.column(name: "Segments", description: "", grouping: try clusters(table()))
        ClusterFields.apply(column, table: "Stores", source: store, visualID: id, to: &d)
        XCTAssertEqual(d.report.pages.first?.visuals.first?.fields(.values).map(\.name), ["Store", "Segments", "Total Sales", "Total Profit"])
    }

    func testAddingTheFieldAndPlacingItIsOneUndoStep() throws {
        let doc = document(scatter())
        let id = try XCTUnwrap(doc.report.pages.first?.visuals.first?.id)
        let s = DocumentStore(document: doc, services: .live())
        let before = s.undoName
        s.addClusterField(ClusterFields.column(name: "Store (clusters)", description: "", grouping: try clusters(scatter())),
                          source: store, visualID: id)
        XCTAssertEqual(s.undoName, "Find Clusters")
        XCTAssertNotNil(s.model.table("Stores")?.column("Store (clusters)"))
        XCTAssertEqual(s.doc.report.pages.first?.visuals.first?.fields(.legend).count, 1)
        s.undo()
        XCTAssertEqual(s.undoName, before)
        XCTAssertNil(s.model.table("Stores")?.column("Store (clusters)"))
        XCTAssertEqual(s.doc.report.pages.first?.visuals.first?.fields(.legend).count, 0)
    }
}
