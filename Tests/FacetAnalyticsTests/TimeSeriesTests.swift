import XCTest
import FacetCore
@testable import FacetAnalytics

final class TimeSeriesTests: XCTestCase {
    /// Deterministic bounded noise in ±amplitude.
    static func noise(_ n: Int, seed: UInt64, amplitude: Double) -> [Double] {
        var rng = SeededGenerator(seed: seed)
        return (0..<n).map { _ in (rng.unit() * 2 - 1) * amplitude }
    }
    static func seasonal(_ t: Int) -> Double { 100 + 2 * Double(t) + 20 * sin(2 * Double.pi * Double(t) / 12) }

    // MARK: Forecasting

    func testSeasonalForecast() throws {
        let n = 72
        let e = Self.noise(n, seed: 3, amplitude: 2)
        let y: [Double?] = (0..<n).map { Self.seasonal($0) + e[$0] }
        let r = try Forecaster.forecast(values: y, horizon: 12)
        XCTAssertEqual(r.seasonLength, 12)
        XCTAssertTrue(r.model == .holtWintersAdditive || r.model == .holtWintersMultiplicative, "\(r.model)")
        XCTAssertEqual(r.forecast.count, 12)
        XCTAssertEqual(r.fitted.count, n)
        var maxErr = 0.0
        for h in 0..<12 { maxErr = max(maxErr, abs(r.forecast[h] - Self.seasonal(n + h))) }
        XCTAssertLessThan(maxErr, 8, "forecast should track trend + season")
        XCTAssertLessThan(r.mape, 3)
        // Bands contain the point forecast, widen with horizon, and cover the truth.
        for h in 0..<12 {
            XCTAssertLessThan(r.lower[h], r.forecast[h]); XCTAssertGreaterThan(r.upper[h], r.forecast[h])
        }
        XCTAssertGreaterThan(r.upper[11] - r.lower[11], r.upper[0] - r.lower[0])
        XCTAssertNotNil(r.gamma); XCTAssertNotNil(r.beta)
        XCTAssertGreaterThan(r.alpha, 0); XCTAssertLessThan(r.alpha, 1)
    }

    func testTrendForecastAndConfidence() throws {
        let e = Self.noise(40, seed: 5, amplitude: 1)
        let y: [Double?] = (0..<40).map { 50 + 3 * Double($0) + e[$0] }
        let r = try Forecaster.forecast(values: y, horizon: 5)
        XCTAssertNil(r.seasonLength)
        XCTAssertTrue(r.model == .holt || r.model == .dampedHolt, "\(r.model)")
        for h in 0..<5 { XCTAssertEqual(r.forecast[h], 50 + 3 * Double(40 + h), accuracy: 6) }
        let narrow = try Forecaster.forecast(values: y, horizon: 5, confidence: 0.5)
        XCTAssertLessThan(narrow.upper[2] - narrow.lower[2], r.upper[2] - r.lower[2])
    }

    func testFlatSeriesMissingValuesAndIgnoreLast() throws {
        let flat = try Forecaster.forecast(values: [Double?](repeating: 10, count: 20), horizon: 3)
        XCTAssertEqual(flat.forecast[2], 10, accuracy: 1e-6)
        XCTAssertEqual(flat.mape, 0, accuracy: 1e-9)

        XCTAssertEqual(Forecaster.interpolate([nil, 1, nil, nil, 4, nil]), [1, 1, 2, 3, 4, 4])
        var y: [Double?] = (0..<30).map { Double($0) * 2 }
        y[10] = nil; y[11] = nil
        let r = try Forecaster.forecast(values: y, horizon: 2, seasonality: 0)
        XCTAssertEqual(r.cleanedValues[10], 20, accuracy: 1e-9)
        XCTAssertEqual(r.forecast[0], 60, accuracy: 1.5)

        // The last 4 points are a spike that must be ignored and re-forecast.
        var z: [Double?] = (0..<30).map { Double($0) * 2 }
        for i in 26..<30 { z[i] = 500 }
        let ig = try Forecaster.forecast(values: z, horizon: 3, seasonality: 0, ignoreLast: 4)
        XCTAssertEqual(ig.forecast.count, 7)
        XCTAssertEqual(ig.startIndex, 26)
        XCTAssertEqual(ig.forecast[0], 52, accuracy: 2)
        XCTAssertEqual(ig.forecast[6], 64, accuracy: 4)

        XCTAssertThrowsError(try Forecaster.forecast(values: [1, 2], horizon: 3)) { XCTAssertNotNil(($0 as? LocalizedError)?.errorDescription) }
        XCTAssertThrowsError(try Forecaster.forecast(values: [1, 2, 3, 4], horizon: 0))
    }

    func testSeasonDetection() {
        let weekly = (0..<70).map { Double([5, 6, 7, 8, 9, 20, 22][$0 % 7]) + Double($0) * 0.1 }
        XCTAssertEqual(Forecaster.detectSeasonLength(weekly), 7)
        let e = Self.noise(60, seed: 9, amplitude: 1)
        XCTAssertNil(Forecaster.detectSeasonLength((0..<60).map { 3 * Double($0) + e[$0] }))
    }

    func testNextLabels() throws {
        let cal = Calendar.utc
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        // Monthly
        let monthly = (1...6).map { Value.date(d(2025, $0, 1)) }
        XCTAssertEqual(Forecaster.nextLabels(after: monthly, count: 3), [.date(d(2025, 7, 1)), .date(d(2025, 8, 1)), .date(d(2025, 9, 1))])
        XCTAssertEqual(Forecaster.cadence(of: (1...6).map { d(2025, $0, 1) }), .month)
        // Month ends stay month ends.
        let ends = [Value.date(d(2024, 11, 30)), .date(d(2024, 12, 31)), .date(d(2025, 1, 31))]
        XCTAssertEqual(Forecaster.nextLabels(after: ends, count: 2), [.date(d(2025, 2, 28)), .date(d(2025, 3, 31))])
        // Daily, weekly, quarterly, yearly
        XCTAssertEqual(Forecaster.nextLabels(after: [.date(d(2025, 2, 27)), .date(d(2025, 2, 28))], count: 2), [.date(d(2025, 3, 1)), .date(d(2025, 3, 2))])
        XCTAssertEqual(Forecaster.nextLabels(after: [.date(d(2025, 1, 6)), .date(d(2025, 1, 13)), .date(d(2025, 1, 20))], count: 1), [.date(d(2025, 1, 27))])
        XCTAssertEqual(Forecaster.nextLabels(after: [.date(d(2024, 1, 1)), .date(d(2024, 4, 1)), .date(d(2024, 7, 1))], count: 2), [.date(d(2024, 10, 1)), .date(d(2025, 1, 1))])
        XCTAssertEqual(Forecaster.nextLabels(after: [.date(d(2022, 1, 1)), .date(d(2023, 1, 1)), .date(d(2024, 1, 1))], count: 1), [.date(d(2025, 1, 1))])
        // Numbers and text
        XCTAssertEqual(Forecaster.nextLabels(after: [2021, 2022, 2023], count: 2), [2024, 2025])
        XCTAssertEqual(Forecaster.nextLabels(after: [0.5, 1.0, 1.5], count: 1), [2.0])
        XCTAssertEqual(Forecaster.nextLabels(after: ["2023", "2024"], count: 1), ["2025"])
        XCTAssertEqual(Forecaster.nextLabels(after: ["a", "b"], count: 2), ["+1", "+2"])

        let overlay = try Forecaster.overlay(axis: monthly + (7...12).map { Value.date(d(2025, $0, 1)) },
                                             values: (0..<12).map { Double($0) }, seriesColumn: 1, horizon: 2)
        XCTAssertEqual(overlay.seriesColumn, 1)
        XCTAssertEqual(overlay.labels, [.date(d(2026, 1, 1)), .date(d(2026, 2, 1))])
        XCTAssertEqual(overlay.values.count, 2); XCTAssertEqual(overlay.lower.count, 2)
        XCTAssertEqual(overlay.values[0], 12, accuracy: 1)
    }

    // MARK: Anomalies

    func testAnomaliesFoundAndNoneOnCleanData() {
        let n = 96
        let e = Self.noise(n, seed: 21, amplitude: 1.5)
        var y: [Double?] = (0..<n).map { 200 + 0.5 * Double($0) + 15 * sin(2 * Double.pi * Double($0) / 12) + e[$0] }
        let clean = AnomalyDetector.detect(values: y)
        XCTAssertTrue(clean.anomalies.isEmpty, "clean data flagged: \(clean.anomalies.map(\.index))")
        XCTAssertEqual(clean.seasonLength, 12)
        XCTAssertEqual(clean.expected.count, n); XCTAssertEqual(clean.lower.count, n)

        y[30] = y[30]! + 40
        y[70] = y[70]! - 35
        let r = AnomalyDetector.detect(values: y)
        XCTAssertEqual(r.anomalies.map(\.index), [30, 70])
        XCTAssertEqual(r.anomalies[0].direction, .high)
        XCTAssertEqual(r.anomalies[1].direction, .low)
        XCTAssertEqual(r.anomalies[0].expected, y[30]! - 40, accuracy: 6)
        XCTAssertGreaterThan(r.anomalies[0].value, r.anomalies[0].upper)
        XCTAssertLessThan(r.anomalies[1].value, r.anomalies[1].lower)

        // Sensitivity is monotone: more sensitive → at least as many anomalies, narrower band.
        let low = AnomalyDetector.detect(values: y, sensitivity: 10)
        let high = AnomalyDetector.detect(values: y, sensitivity: 100)
        XCTAssertLessThanOrEqual(low.anomalies.count, r.anomalies.count)
        XCTAssertGreaterThanOrEqual(high.anomalies.count, r.anomalies.count)
        XCTAssertLessThan(high.upper[5] - high.lower[5], low.upper[5] - low.lower[5])

        var overlays = AnalyticsOverlays()
        AnomalyDetector.apply(to: &overlays, values: y, seriesColumn: 2)
        XCTAssertEqual(overlays.anomalies.map(\.row), [30, 70])
        XCTAssertEqual(overlays.expectedBands[2]?.count, n)
        XCTAssertTrue(overlays.anomalies[0].explanation.contains("above"))
    }

    func testAnomalyOnNonSeasonalAndEdgeCases() {
        var y: [Double?] = (0..<50).map { 10 + Double($0) + (($0 % 2 == 0) ? 0.4 : -0.4) }
        y[25] = 90
        y[40] = nil
        let r = AnomalyDetector.detect(values: y, seasonality: 0)
        XCTAssertEqual(r.anomalies.map(\.index), [25])
        XCTAssertTrue(AnomalyDetector.detect(values: [1, 2, 3]).anomalies.isEmpty)
        XCTAssertTrue(AnomalyDetector.detect(values: []).anomalies.isEmpty)
        XCTAssertTrue(AnomalyDetector.detect(values: [Double?](repeating: 5, count: 30)).anomalies.isEmpty)
        XCTAssertEqual(AnomalyDetector.theilSenSlope((0..<20).map { 3 * Double($0) + 1 }), 3, accuracy: 1e-9)
    }

    func testAnomalyExplanation() {
        var total: [Double?] = [Double?](repeating: 100, count: 30)
        total[15] = 160
        let r = AnomalyDetector.detect(values: total, seasonality: 0)
        XCTAssertEqual(r.anomalies.map(\.index), [15])
        let region = FieldRef.column("Sales", "Region"), channel = FieldRef.column("Sales", "Channel")
        let ex = AnomalyDetector.explain(anomalyIndex: 15, in: r, dimensions: [channel, region]) { dim, i in
            if dim.name == "Region" {
                // The whole spike comes from West.
                return [(member: "West", value: i == 15 ? 85 : 25), (member: "East", value: 25), (member: "North", value: 50)]
            }
            // Channels share the spike evenly.
            return [(member: "Web", value: i == 15 ? 80 : 50), (member: "Store", value: i == 15 ? 80 : 50)]
        }
        XCTAssertEqual(ex.count, 2)
        XCTAssertEqual(ex[0].dimension.name, "Region")
        XCTAssertEqual(ex[0].member, "West")
        XCTAssertEqual(ex[0].strength, 100, accuracy: 1)
        XCTAssertEqual(ex[1].strength, 50, accuracy: 1)
        XCTAssertTrue(ex[0].sentence.contains("West"))
        XCTAssertTrue(AnomalyDetector.explain(anomalyIndex: 99, in: r, dimensions: [region]) { _, _ in [] }.isEmpty)
    }

    // MARK: Trend and reference lines

    func testTrendLines() throws {
        let x = (1...10).map(Double.init)
        let lin = try XCTUnwrap(TrendLine.fit(x: x, y: x.map { 4 + 2.5 * $0 }, kind: .linear))
        XCTAssertEqual(lin.coefficients[0], 4, accuracy: 1e-8); XCTAssertEqual(lin.coefficients[1], 2.5, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(lin.rSquared), 1, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(lin.predict(20)), 54, accuracy: 1e-6)

        let poly = try XCTUnwrap(TrendLine.fit(x: x, y: x.map { 1 - 2 * $0 + 0.5 * $0 * $0 }, kind: .polynomial(degree: 2)))
        XCTAssertEqual(poly.coefficients[0], 1, accuracy: 1e-6)
        XCTAssertEqual(poly.coefficients[1], -2, accuracy: 1e-6)
        XCTAssertEqual(poly.coefficients[2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(poly.rSquared), 1, accuracy: 1e-9)

        let ex = try XCTUnwrap(TrendLine.fit(x: x, y: x.map { 3 * exp(0.2 * $0) }, kind: .exponential))
        XCTAssertEqual(ex.coefficients[0], 3, accuracy: 1e-8); XCTAssertEqual(ex.coefficients[1], 0.2, accuracy: 1e-8)
        let lg = try XCTUnwrap(TrendLine.fit(x: x, y: x.map { 5 + 2 * log($0) }, kind: .logarithmic))
        XCTAssertEqual(lg.coefficients[0], 5, accuracy: 1e-8); XCTAssertEqual(lg.coefficients[1], 2, accuracy: 1e-8)
        let pw = try XCTUnwrap(TrendLine.fit(x: x, y: x.map { 2 * pow($0, 1.5) }, kind: .power))
        XCTAssertEqual(pw.coefficients[1], 1.5, accuracy: 1e-8)

        let ma = try XCTUnwrap(TrendLine.fit(values: [1, 2, 3, 4, 5, 6], kind: .movingAverage(period: 3)))
        XCTAssertEqual(ma.fitted, [nil, nil, 2, 3, 4, 5])
        XCTAssertNil(ma.predict(3))

        // A noisy line has R² strictly between 0 and 1; invalid domains return nil.
        let noisy = try XCTUnwrap(TrendLine.fit(values: [1, 3, 2, 5, 4, 6, 5, 8], kind: .linear))
        let r2 = try XCTUnwrap(noisy.rSquared)
        XCTAssertGreaterThan(r2, 0.7); XCTAssertLessThan(r2, 1)
        XCTAssertEqual(noisy.fitted.count, 8)
        XCTAssertNil(TrendLine.fit(x: [1, 2, 3], y: [1, -2, 3], kind: .exponential))
        XCTAssertNil(TrendLine.fit(x: [0, 1, 2], y: [1, 2, 3], kind: .logarithmic))
        XCTAssertNil(TrendLine.fit(x: [1], y: [1], kind: .linear))
        XCTAssertTrue(lin.equation.hasPrefix("y = "))
    }

    func testReferenceLinesErrorBarsAndScatterHelpers() throws {
        let v: [Double] = [3, 1, 4, 1, 5, 9, 2, 6]
        XCTAssertEqual(ReferenceLines.value(.min, values: v), 1)
        XCTAssertEqual(ReferenceLines.value(.max, values: v), 9)
        XCTAssertEqual(ReferenceLines.value(.mean, values: v), 3.875)
        XCTAssertEqual(ReferenceLines.value(.median, values: v), 3.5)
        XCTAssertEqual(ReferenceLines.value(.percentile(90), values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])!, 9.1, accuracy: 1e-12)
        XCTAssertEqual(ReferenceLines.value(.constant(7), values: []), 7)
        XCTAssertNil(ReferenceLines.value(.mean, values: []))
        var item = AnalyticsItem(kind: .percentileLine); item.value = 50
        XCTAssertEqual(ReferenceLines.value(for: item, values: v), 3.5)
        XCTAssertNil(ReferenceLines.value(for: AnalyticsItem(kind: .forecast), values: v))

        let pct = ErrorBars.compute(values: [100, nil, 50], kind: .percentage(10))
        XCTAssertEqual(pct[0], ErrorBar(lower: 90, upper: 110)); XCTAssertNil(pct[1]); XCTAssertEqual(pct[2], ErrorBar(lower: 45, upper: 55))
        let sd = ErrorBars.compute(values: [10, 20], kind: .standardDeviation(multiplier: 2), samples: [[8, 10, 12], [20, 20, 20]])
        XCTAssertEqual(sd[0], ErrorBar(lower: 6, upper: 14)); XCTAssertEqual(sd[1], ErrorBar(lower: 20, upper: 20))
        let se = ErrorBars.compute(values: [10], kind: .standardError(multiplier: 1), samples: [[8, 10, 12, 10]])
        XCTAssertEqual(try XCTUnwrap(se[0]).upper, 10 + sqrt(8.0 / 3) / 2, accuracy: 1e-12)
        let pc = ErrorBars.compute(values: [5], kind: .percentile(lower: 25, upper: 75), samples: [[1, 2, 3, 4, 5]])
        XCTAssertEqual(pc[0], ErrorBar(lower: 2, upper: 4))
        let byField = ErrorBars.compute(values: [10, 20], kind: .byField(upper: [12, nil], lower: [7, nil], relative: false))
        XCTAssertEqual(byField[0], ErrorBar(lower: 7, upper: 12)); XCTAssertNil(byField[1])
        let rel = ErrorBars.compute(values: [10], kind: .byField(upper: [2], lower: [3], relative: true))
        XCTAssertEqual(rel[0], ErrorBar(lower: 7, upper: 12))

        let sym = ScatterAnalytics.symmetry(x: [1, 2, 3, 4], y: [2, 2, 1, 9])
        XCTAssertEqual(sym.above, [0, 3]); XCTAssertEqual(sym.below, [2]); XCTAssertEqual(sym.onLine, [1]); XCTAssertEqual(sym.lineEnd, 9)
        let ratio = try XCTUnwrap(ScatterAnalytics.ratioLine(x: [1, 2, 3], y: [2, 4, 12]))
        XCTAssertEqual(ratio.slope, 3); XCTAssertEqual(ratio.above, [2]); XCTAssertEqual(ratio.below, [0, 1])
        XCTAssertEqual(ratio.end.y, 9)
        XCTAssertNil(ScatterAnalytics.ratioLine(x: [0, 0], y: [1, 2]))
    }
}
