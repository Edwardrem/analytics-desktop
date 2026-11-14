import XCTest
import FacetCore
import FacetAnalytics
@testable import MicrosoftPowerBI

/// Clicking an anomaly on a line chart of Total by Day lists its possible explanations.
///
/// Every day 1…12 has four rows of 5 — North/South × Apple/Pear — so Total is 20, except day 7,
/// where South Apple and South Pear are 30 each: Total 70. Week is W1 for days 1–7 and W2 after.
///
/// Detection: the series is flat at 20 but for one spike, so the running median (window 5) and
/// the expected value are 20 everywhere; the only residual is +50 on day 7. With no spread the
/// scale is 1.2533 × mean |residual| = 1.2533 × 50 / 12 = 5.222 and at sensitivity 70 the half
/// width is (9 − 8 × 0.7) × 5.222 = 17.755: day 7 is flagged, expected 20, range 2.245 – 37.755.
///
/// Explanations, from day 7 against its six nearest normal days (6, 8, 5, 9, 4, 10), gap 70 − 20 = 50:
/// - Region: South 60 against 10 on those days → (60 − 10) / 50 = 100 %; North 10 against 10 → 0.
/// - Product: Apple 35 against 10 → 25 / 50 = 50 %, Pear the same; the first in order, Apple, is listed.
/// - Week: day 7 is all W1, so the field can't split the point and isn't an explanation.
@MainActor
final class AnomalyExplanationTests: XCTestCase {
    private let day = FieldRef.column("Sales", "Day")
    private let region = FieldRef.column("Sales", "Region")
    private let product = FieldRef.column("Sales", "Product")
    private let week = FieldRef.column("Sales", "Week")
    private let total = FieldRef.measure("Sales", "Total")

    private func model() -> SemanticModel {
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "Day", dataType: .integer), ModelColumn(name: "Region", dataType: .text),
            ModelColumn(name: "Product", dataType: .text), ModelColumn(name: "Week", dataType: .text),
            ModelColumn(name: "Amount", dataType: .integer),
        ])
        var total = Measure(name: "Total", expression: "SUM(Sales[Amount])")
        total.formatString = "#,0.0"
        sales.measures = [total]
        var m = SemanticModel()
        m.tables = [sales]
        return m
    }

    private func table() -> DataTable {
        var rows: [[Value]] = []
        for d in 1...12 {
            for r in ["North", "South"] {
                for p in ["Apple", "Pear"] {
                    let amount: Int64 = d == 7 && r == "South" ? 30 : 5
                    rows.append([.int(Int64(d)), .string(r), .string(p), .string(d <= 7 ? "W1" : "W2"), .int(amount)])
                }
            }
        }
        return DataTable(name: "Sales", columnNames: ["Day", "Region", "Product", "Week", "Amount"], rows: rows,
                         types: [.integer, .text, .text, .text, .integer])
    }

    private func engine() -> CalculationService {
        let engine = Services.live().makeCalculation()
        var store = DataStore()
        store["Sales"] = table()
        _ = engine.load(model: model(), data: store, roles: [], userName: "")
        return engine
    }

    private func chart(explainBy: [FieldRef]? = nil) -> VisualSpec {
        var v = VisualSpec(type: .line, frame: Frame(x: 0, y: 0, width: 400, height: 240), name: "Total by Day")
        v.setFields(.category, [day])
        v.setFields(.values, [total])
        var item = BuildLogic.newItem(.anomalies)
        item.explainBy = explainBy
        v.analytics = [item]
        return v
    }

    /// The chart's result and its overlays, as the canvas has them, and the plan for its one anomaly.
    private func plan(_ spec: VisualSpec, engine: CalculationService, request: VisualRequest = VisualRequest())
        throws -> AnomalyExplanations.Plan {
        let data = engine.visualData(spec: spec, request: request)
        let overlays = LiveAnalytics().overlays(spec: spec, data: data)
        XCTAssertEqual(overlays.anomalies.count, 1)
        let anomaly = try XCTUnwrap(overlays.anomalies.first)
        return try XCTUnwrap(AnomalyExplanations.plan(spec: spec, data: data, anomaly: anomaly))
    }

    func testTheClickedAnomalyIsDayOfTheSpikeAgainstItsExpectedRange() throws {
        let p = try plan(chart(), engine: engine())
        XCTAssertEqual(p.index, 6)
        XCTAssertEqual(p.label, "7")
        XCTAssertEqual(p.value, 70)
        XCTAssertEqual(p.anomaly.expected, 20, accuracy: 1e-9)
        XCTAssertEqual(p.anomaly.lower, 20 - 3.4 * 1.2533 * 50 / 12, accuracy: 1e-6)
        XCTAssertEqual(p.anomaly.upper, 20 + 3.4 * 1.2533 * 50 / 12, accuracy: 1e-6)
        XCTAssertTrue(p.isHigh)
        XCTAssertEqual(p.excluded, [day.key])
    }

    func testExplanationsAreTheMembersThatAccountForTheGapWithTheirStrength() throws {
        let engine = engine()
        let p = try plan(chart(), engine: engine)
        let dims = AnomalyExplanations.dimensions(for: p, model: model(), data: engine.data)
        XCTAssertEqual(dims.map(\.key), [region.key, product.key, week.key], "text columns with 2…30 values, the axis left out")
        let found = AnomalyExplanations.explain(p, dimensions: dims, request: VisualRequest(), engine: engine)
        XCTAssertEqual(found.map(\.dimension.key), [region.key, product.key])
        XCTAssertEqual(found.map(\.member), [.string("South"), .string("Apple")])
        XCTAssertEqual(found.map(\.strength), [100, 50])
        XCTAssertEqual(found.map(\.actual), [60, 35])
        XCTAssertEqual(found.map(\.expected), [10, 10])
        // South's own line, day by day: 10 every day but 60 on day 7.
        XCTAssertEqual(found.first?.trend, [10, 10, 10, 10, 10, 10, 60, 10, 10, 10, 10, 10])
        // In the measure's own format, one decimal: 20 ± 17.755 is 2.2 – 37.8.
        XCTAssertEqual(p.measureFormat, "#,0.0")
        XCTAssertEqual(found.first.map { AnomalyExplanations.sentence($0, high: true, format: p.measureFormat) },
                       "Region South was higher than expected: 60.0 against 10.0.")
        XCTAssertEqual(AnomalyExplanations.summary(p), "70.0 is above the expected range 2.2 – 37.8 (expected 20.0).")
    }

    func testExplainByLimitsTheFieldsTried() throws {
        let engine = engine()
        let p = try plan(chart(explainBy: [product]), engine: engine)
        let dims = AnomalyExplanations.dimensions(for: p, model: model(), data: engine.data)
        XCTAssertEqual(dims.map(\.key), [product.key])
        let found = AnomalyExplanations.explain(p, dimensions: dims, request: VisualRequest(), engine: engine)
        XCTAssertEqual(found.map(\.member), [.string("Apple")])
        XCTAssertEqual(found.map(\.strength), [50])
    }

    func testTheVisualsFiltersApplyToTheBreakdowns() throws {
        // Under Product = Apple the days are 10 and day 7 is 35 (North 5, South 30): the gap is 25,
        // South is 30 against 5 → 25 / 25 = 100 %, and Product has one member left, so it explains nothing.
        let engine = engine()
        var request = VisualRequest()
        var apple = FilterSpec(field: product)
        apple.values = [.string("Apple")]
        request.filters = [apple]
        let p = try plan(chart(), engine: engine, request: request)
        XCTAssertEqual(p.value, 35)
        let found = AnomalyExplanations.explain(p, dimensions: [region, product], request: request, engine: engine)
        XCTAssertEqual(found.map(\.member), [.string("South")])
        XCTAssertEqual(found.map(\.strength), [100])
        XCTAssertEqual(found.map(\.expected), [5])
    }

    func testOnlyAFlaggedPointOfAChartWithAnomaliesHasAPlan() throws {
        let engine = engine()
        let spec = chart()
        let data = engine.visualData(spec: spec, request: VisualRequest())
        let anomaly = try XCTUnwrap(LiveAnalytics().overlays(spec: spec, data: data).anomalies.first)
        var normal = anomaly
        normal.row = (anomaly.row + 1) % data.table.rowCount
        XCTAssertNil(AnomalyExplanations.plan(spec: spec, data: data, anomaly: normal), "day 8 isn't an anomaly")
        var noCard = spec
        noCard.analytics = []
        XCTAssertNil(AnomalyExplanations.plan(spec: noCard, data: data, anomaly: anomaly))
        var outOfRange = anomaly
        outOfRange.seriesColumn = 99
        XCTAssertNil(AnomalyExplanations.plan(spec: spec, data: data, anomaly: outOfRange))
    }

    func testTheExplainByListHoldsEachColumnOnce() {
        var list = AnomalyCard.adding(region, to: nil)
        list = AnomalyCard.adding(.column("sales", "region"), to: list)
        list = AnomalyCard.adding(total, to: list)
        XCTAssertEqual(list?.map(\.key), [region.key], "a column once, whatever its case, and never a measure")
        list = AnomalyCard.adding(product, to: list)
        XCTAssertEqual(AnomalyCard.replacing(product, with: region, in: list)?.map(\.key), [region.key])
        XCTAssertEqual(AnomalyCard.replacing(product, with: week, in: list)?.map(\.key), [region.key, week.key])
        XCTAssertNil(AnomalyCard.removing(region, from: [region]), "an empty list is stored as none")
        // Renaming a column keeps the card pointing at it.
        var doc = FacetDocument()
        doc.model = model()
        var page = Page(name: "Page 1")
        page.visuals = [chart(explainBy: [product])]
        doc.report.pages = [page]
        ModelRefactor.renameColumn(&doc, table: "Sales", from: "Product", to: "Fruit")
        XCTAssertEqual(doc.report.pages.first?.visuals.first?.analytics.first?.explainBy?.map(\.name), ["Fruit"])
    }

    func testAnOldAnomaliesCardReadsBackWithoutExplainBy() throws {
        let old = #"{"id":"6F0D1E9B-6C76-4C8B-9C2E-0E7A1C2B3D4E","kind":"anomalies","name":"","value":70,"secondaryValue":95,"style":"dashed","showLabel":true}"#
        XCTAssertNil(try JSONDecoder().decode(AnalyticsItem.self, from: Data(old.utf8)).explainBy)
    }
}
