import XCTest
import FacetCore
import FacetAnalytics
@testable import MicrosoftPowerBI

/// Explain the increase / decrease from a clicked point on a column chart of Total by Year.
///
/// | Year | Region | Product | Amount |
/// | 2023 | North  | Apple   | 10 |
/// | 2023 | South  | Apple   | 20 |
/// | 2023 | North  | Pear    |  5 |
/// | 2024 | North  | Apple   | 40 |
/// | 2024 | South  | Apple   | 15 |
/// | 2024 | North  | Pear    |  5 |
///
/// 2023 → 2024: 35 → 60, +25.
/// - By Product: Apple +25, Pear 0 — all of the change in one member: concentration 1, score 1.
/// - By Region: North +30, South −5 — movement 35, Herfindahl (30/35)² + (5/35)² = 0.7551,
///   concentration (0.7551 − ½) / ½ = 0.5102, efficiency 25/35 = 0.714, score 0.5102 × 0.857 = 0.437.
@MainActor
final class ExplainChangeTests: XCTestCase {
    private let year = FieldRef.column("Sales", "Year")
    private let region = FieldRef.column("Sales", "Region")
    private let product = FieldRef.column("Sales", "Product")
    private let total = FieldRef.measure("Sales", "Total")

    private func model() -> SemanticModel {
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "Year", dataType: .integer), ModelColumn(name: "Region", dataType: .text),
            ModelColumn(name: "Product", dataType: .text), ModelColumn(name: "Amount", dataType: .integer),
        ])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        var m = SemanticModel()
        m.tables = [sales]
        return m
    }

    private func table() -> DataTable {
        DataTable(name: "Sales", columnNames: ["Year", "Region", "Product", "Amount"], rows: [
            [.int(2023), .string("North"), .string("Apple"), .int(10)],
            [.int(2023), .string("South"), .string("Apple"), .int(20)],
            [.int(2023), .string("North"), .string("Pear"), .int(5)],
            [.int(2024), .string("North"), .string("Apple"), .int(40)],
            [.int(2024), .string("South"), .string("Apple"), .int(15)],
            [.int(2024), .string("North"), .string("Pear"), .int(5)],
        ], types: [.integer, .text, .text, .integer])
    }

    private func engine() -> CalculationService {
        let engine = Services.live().makeCalculation()
        var store = DataStore()
        store["Sales"] = table()
        _ = engine.load(model: model(), data: store, roles: [], userName: "")
        return engine
    }

    private func chart(legend: Bool = false) -> VisualSpec {
        var v = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 240), name: "Total by Year")
        v.setFields(.category, [year])
        v.setFields(.values, [total])
        if legend { v.setFields(.legend, [region]) }
        return v
    }

    private func point(_ y: Int64, region r: String? = nil) -> DataPointSelection {
        var p = DataPointSelection(fields: [year], values: [.int(y)])
        if let r { p.fields.append(region); p.values.append(.string(r)) }
        return p
    }

    func testPlanComparesTheClickedPointWithThePreviousOne() throws {
        let engine = engine()
        let spec = chart()
        let data = engine.visualData(spec: spec, request: VisualRequest())
        let plan = try XCTUnwrap(ExplainChange.plan(spec: spec, data: data, point: point(2024)))
        XCTAssertEqual(plan.points.map(\.label), ["2023", "2024"])
        XCTAssertEqual(plan.points.map(\.value), [35, 60])
        XCTAssertEqual(plan.from, 0)
        XCTAssertEqual(plan.to, 1)
        XCTAssertEqual(plan.title, "Explain the increase")
        XCTAssertEqual(plan.points[1].filters.first?.values, [.int(2024)])
        // The first point has nothing before it; other visual types are not explained.
        XCTAssertNil(ExplainChange.plan(spec: spec, data: data, point: point(2023)))
        var pie = spec
        pie.type = .pie
        XCTAssertNil(ExplainChange.plan(spec: pie, data: data, point: point(2024)))
    }

    func testCandidateFieldsAreTheModelsCategoricalColumns() throws {
        let engine = engine()
        let spec = chart()
        let plan = try XCTUnwrap(ExplainChange.plan(spec: spec, data: engine.visualData(spec: spec, request: VisualRequest()), point: point(2024)))
        XCTAssertEqual(ExplainChange.dimensions(for: plan, model: model(), data: engine.data).map(\.name), ["Region", "Product"])
    }

    func testChangeIsBrokenDownByTheMostConcentratedFieldFirst() throws {
        let engine = engine()
        let spec = chart()
        let plan = try XCTUnwrap(ExplainChange.plan(spec: spec, data: engine.visualData(spec: spec, request: VisualRequest()), point: point(2024)))
        let dims = ExplainChange.dimensions(for: plan, model: model(), data: engine.data)
        let r = try XCTUnwrap(ExplainChange.explain(plan, from: 0, to: 1, dimensions: dims, request: VisualRequest(), engine: engine))
        XCTAssertEqual(r.before, 35)
        XCTAssertEqual(r.after, 60)
        XCTAssertEqual(r.delta, 25)
        XCTAssertEqual(r.explanations.map(\.dimension.name), ["Product", "Region"])
        let byProduct = r.explanations[0]
        XCTAssertEqual(byProduct.score, 1, accuracy: 1e-9)
        XCTAssertEqual(byProduct.contributions.map(\.member), [.string("Apple"), .string("Pear")])
        XCTAssertEqual(byProduct.contributions.map(\.change), [25, 0])
        let byRegion = r.explanations[1]
        XCTAssertEqual(byRegion.score, 0.4373, accuracy: 0.001)
        XCTAssertEqual(byRegion.contributions.map(\.change), [30, -5])
        XCTAssertEqual(byRegion.contributions[0].shareOfDelta, 1.2, accuracy: 1e-9)
    }

    func testTheClickedSeriesStaysFixed() throws {
        let engine = engine()
        let spec = chart(legend: true)
        let data = engine.visualData(spec: spec, request: VisualRequest())
        let plan = try XCTUnwrap(ExplainChange.plan(spec: spec, data: data, point: point(2024, region: "North")))
        // North alone: 10 + 5 = 15 in 2023, 40 + 5 = 45 in 2024.
        XCTAssertEqual(plan.points.map(\.value), [15, 45])
        let dims = ExplainChange.dimensions(for: plan, model: model(), data: engine.data)
        XCTAssertEqual(dims.map(\.name), ["Product"])
        let r = try XCTUnwrap(ExplainChange.explain(plan, from: 0, to: 1, dimensions: dims, request: VisualRequest(), engine: engine))
        XCTAssertEqual(r.delta, 30)
        XCTAssertEqual(r.explanations.first?.contributions.first?.change, 30)
    }

    func testTheVisualsFiltersApply() throws {
        let engine = engine()
        let spec = chart()
        var request = VisualRequest()
        var apples = FilterSpec(field: product)
        apples.values = [.string("Apple")]
        request.filters = [apples]
        let plan = try XCTUnwrap(ExplainChange.plan(spec: spec, data: engine.visualData(spec: spec, request: request), point: point(2024)))
        // Apples only: 30 → 55; North +30, South −5.
        let r = try XCTUnwrap(ExplainChange.explain(plan, from: 0, to: 1, dimensions: [region], request: request, engine: engine))
        XCTAssertEqual(r.before, 30)
        XCTAssertEqual(r.after, 55)
        XCTAssertEqual(r.explanations.first?.contributions.map(\.change), [30, -5])
        // Going backwards is a decrease.
        let back = try XCTUnwrap(ExplainChange.explain(plan, from: 1, to: 0, dimensions: [region], request: request, engine: engine))
        XCTAssertFalse(back.isIncrease)
        XCTAssertFalse(plan.isIncrease(from: 1, to: 0))
    }

    func testRibbonCommandNeedsASelectedPointAfterTheFirst() async throws {
        let store = DocumentStore(services: .live())
        let m = model(), t = table(), spec = chart()
        store.mutate("Load", invalidates: .model) { d in d.model = m; d.data["Sales"] = t; d.report.pages[0].visuals = [spec] }
        for _ in 0..<200 where store.visualData[spec.id]?.isEmpty ?? true { try await Task.sleep(nanoseconds: 20_000_000) }
        store.selection = [spec.id]
        XCTAssertNil(AnalyzeFeature.explainTarget(store))
        store.selectPoints([point(2023)], in: spec.id, additive: false)
        XCTAssertNil(AnalyzeFeature.explainTarget(store))
        store.selectPoints([point(2024)], in: spec.id, additive: false)
        XCTAssertEqual(AnalyzeFeature.explainTarget(store)?.1, point(2024))
    }
}
