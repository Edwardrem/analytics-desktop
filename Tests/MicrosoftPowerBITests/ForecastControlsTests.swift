import XCTest
import FacetCore
import FacetAnalytics
@testable import MicrosoftPowerBI

/// The forecast card's controls — seasonality, ignore the last N points, confidence interval —
/// and how they reach the forecaster.
///
/// The series is 16 months from January 2024 repeating 10, 20, 30, 20: a season of four points with
/// no trend and no noise. A seasonal model fits it exactly (its initial level is the season mean 20
/// and its seasonal states −10, 0, +10, 0), so it forecasts the pattern again; a model without
/// seasonality can only forecast a level or a straight or damped trend, which never rises and falls.
@MainActor
final class ForecastControlsTests: XCTestCase {
    private let pattern: [Double] = [10, 20, 30, 20]

    private func month(_ i: Int) -> Value {
        var c = DateComponents(); c.year = 2024; c.month = 1 + i; c.day = 1
        return .date(Calendar.utc.date(from: c) ?? Date())
    }

    /// A line chart's result over the series; `rows` reorders the result rows as a query might return them.
    private func data(_ values: [Double], rows: [Int]? = nil) -> VisualData {
        let order = rows ?? Array(values.indices)
        let table = DataTable(name: "q", columns: [
            DataColumn(name: "Month", type: .date, values: order.map { month($0) }),
            DataColumn(name: "Units", type: .decimal, values: order.map { .double(values[$0]) }),
        ])
        return VisualData(table: table, roles: ["category": [0], "values": [1]],
                          fields: [.column("Sales", "Month"), .measure("Sales", "Units")], formats: ["", ""])
    }

    private func chart(_ item: AnalyticsItem) -> VisualSpec {
        var spec = VisualSpec(type: .line, frame: Frame(x: 0, y: 0, width: 400, height: 240))
        spec.setFields(.category, [.column("Sales", "Month")])
        spec.setFields(.values, [.measure("Sales", "Units")])
        spec.analytics = [item]
        return spec
    }

    private func overlays(length: Double = 4, seasonality: Int? = nil, ignoreLast: Int? = nil, confidence: Double = 95,
                          values: [Double]? = nil, rows: [Int]? = nil) -> AnalyticsOverlays {
        var item = BuildLogic.newItem(.forecast)
        item.value = length; item.seasonality = seasonality; item.ignoreLast = ignoreLast; item.secondaryValue = confidence
        let series = values ?? Array((0..<4).flatMap { _ in pattern })
        return LiveAnalytics().overlays(spec: chart(item), data: data(series, rows: rows))
    }

    private func forecast(length: Double = 4, seasonality: Int? = nil, ignoreLast: Int? = nil, confidence: Double = 95,
                          values: [Double]? = nil, rows: [Int]? = nil) throws -> AnalyticsOverlays.Forecast {
        try XCTUnwrap(overlays(length: length, seasonality: seasonality, ignoreLast: ignoreLast, confidence: confidence,
                               values: values, rows: rows).forecasts.first)
    }

    func testAutomaticSeasonalityFindsTheFourPointSeason() throws {
        let fc = try forecast()
        for (v, e) in zip(fc.values, pattern) { XCTAssertEqual(v, e, accuracy: 1e-6) }
        XCTAssertEqual(fc.labels, (16..<20).map(month), "May to August 2025")
        XCTAssertTrue(fc.ignoredRows.isEmpty)
        XCTAssertEqual(fc.anchorRow, 15)
    }

    func testAGivenSeasonalityIsUsedAndOneTurnsItOff() throws {
        let seasonal = try forecast(seasonality: 4)
        for (v, e) in zip(seasonal.values, pattern) { XCTAssertEqual(v, e, accuracy: 1e-6) }
        let flat = try forecast(seasonality: 1)
        let rises = zip(flat.values, flat.values.dropFirst()).contains { $1 > $0 + 1e-9 }
        let falls = zip(flat.values, flat.values.dropFirst()).contains { $1 < $0 - 1e-9 }
        XCTAssertFalse(rises && falls, "without seasonality the forecast is a level or a trend: \(flat.values)")
        XCTAssertEqual(AnalyticsSeries.seasonality(BuildLogic.newItem(.forecast)), nil, "a new card detects the season")
    }

    func testIgnoringTheLastPointsReForecastsThemFromTheFitBeforeThem() throws {
        // Fitted to the first 12 months (three seasons), the ignored 4 months get the pattern again,
        // then 2 future months follow. The table comes back newest first, as a query may return it.
        let fc = try forecast(length: 2, ignoreLast: 4, rows: Array((0..<16).reversed()))
        XCTAssertEqual(fc.values.count, 6)
        for (v, e) in zip(fc.values, pattern + pattern.prefix(2)) { XCTAssertEqual(v, e, accuracy: 1e-6) }
        // In the reversed table, month k is row 15 − k: the fit ends at month 11 (row 4) and the
        // ignored months 12…15 are rows 3, 2, 1, 0.
        XCTAssertEqual(fc.anchorRow, 4)
        XCTAssertEqual(fc.ignoredRows, [3, 2, 1, 0])
        XCTAssertEqual(fc.labels, (12..<18).map(month))
        XCTAssertEqual(fc.futureLabels, [month(16), month(17)])
    }

    func testTheConfidenceIntervalScalesTheBandByItsNormalQuantile() throws {
        // A noisy series, so the band has width: the half widths at 95 % and 80 % differ by
        // z(0.975) / z(0.90) = 1.959964 / 1.281552 = 1.529372, step by step.
        let noisy: [Double] = [12, 19, 33, 18, 9, 22, 28, 21, 11, 18, 31, 19, 10, 21, 29, 22]
        let wide = try forecast(confidence: 95, values: noisy)
        let narrow = try forecast(confidence: 80, values: noisy)
        XCTAssertEqual(wide.values, narrow.values)
        for k in wide.values.indices {
            let ratio = (wide.upper[k] - wide.values[k]) / (narrow.upper[k] - narrow.values[k])
            XCTAssertEqual(ratio, 1.959964 / 1.281552, accuracy: 1e-4)
        }
        XCTAssertEqual(ForecastCard.confidenceLevels, [75, 80, 85, 90, 95, 99])
    }

    func testDocumentNumbersAreClampedRatherThanTrusted() throws {
        XCTAssertEqual(try forecast(length: .infinity).values.count, 10, "an unusable length falls back to 10")
        XCTAssertEqual(try forecast(length: 5000).values.count, 1000)
        // Ignoring 13 of 16 points leaves three to fit, the least a forecast needs; ignoring 99 leaves none.
        XCTAssertEqual(try forecast(length: 2, ignoreLast: 13).values.count, 13 + 2)
        XCTAssertTrue(overlays(length: 2, ignoreLast: 99).forecasts.isEmpty)
    }

    func testCardChoicesAndOldDocuments() throws {
        XCTAssertEqual(ForecastCard.seasonalityHint(nil), "Detected")
        XCTAssertEqual(ForecastCard.seasonalityHint(1), "None")
        XCTAssertEqual(ForecastCard.seasonalityHint(12), "points per season")
        // A forecast saved before these settings existed reads back with them unset.
        let old = #"{"id":"6F0D1E9B-6C76-4C8B-9C2E-0E7A1C2B3D4E","kind":"forecast","name":"","value":10,"secondaryValue":95,"style":"dashed","showLabel":true}"#
        let item = try JSONDecoder().decode(AnalyticsItem.self, from: Data(old.utf8))
        XCTAssertNil(item.seasonality)
        XCTAssertNil(item.ignoreLast)
    }

    func testForecastsAndAnomaliesNeedOneSeries() {
        var model = SemanticModel()
        model.tables = [ModelTable(name: "Sales", columns: [ModelColumn(name: "Month", dataType: .date),
                                                            ModelColumn(name: "Region", dataType: .text)])]
        var spec = chart(BuildLogic.newItem(.forecast))
        XCTAssertTrue(BuildLogic.analyticsKinds(for: spec, model: model).contains(.forecast))
        XCTAssertTrue(BuildLogic.analyticsKinds(for: spec, model: model).contains(.anomalies))
        spec.setFields(.legend, [.column("Sales", "Region")])
        XCTAssertFalse(BuildLogic.analyticsKinds(for: spec, model: model).contains(.anomalies))
        XCTAssertFalse(BuildLogic.analyticsKinds(for: spec, model: model).contains(.forecast))
        // A result with a legend holds several series, so the chart gets no forecast from it.
        var legend = data(Array((0..<4).flatMap { _ in pattern }))
        legend.roles["legend"] = [0]
        XCTAssertTrue(LiveAnalytics().overlays(spec: spec, data: legend).forecasts.isEmpty)
    }
}
