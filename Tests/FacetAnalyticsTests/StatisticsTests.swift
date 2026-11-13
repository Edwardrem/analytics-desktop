import XCTest
import FacetCore
@testable import FacetAnalytics

final class StatisticsTests: XCTestCase {
    // Reference values computed with SciPy 1.x.

    func testSpecialFunctions() {
        XCTAssertEqual(SpecialFunctions.lnGamma(5), log(24), accuracy: 1e-10)
        XCTAssertEqual(SpecialFunctions.lnGamma(0.5), log(sqrt(Double.pi)), accuracy: 1e-10)
        XCTAssertEqual(SpecialFunctions.gammaP(1, 2), 1 - exp(-2), accuracy: 1e-10)
        XCTAssertEqual(SpecialFunctions.gammaP(2.5, 3.0), 0.6937810815867218, accuracy: 1e-9)
        XCTAssertEqual(SpecialFunctions.gammaQ(2.5, 3.0), 1 - 0.6937810815867218, accuracy: 1e-9)
        XCTAssertEqual(SpecialFunctions.betaI(0.5, 2, 3), 0.6875, accuracy: 1e-10)
        XCTAssertEqual(SpecialFunctions.betaI(0.3, 2.5, 1.5), 0.08894372317066562, accuracy: 1e-9)
        XCTAssertEqual(SpecialFunctions.erf(1), 0.8427007929497149, accuracy: 1e-9)
        XCTAssertEqual(SpecialFunctions.erf(-0.5), -0.5204998778130465, accuracy: 1e-9)
    }

    func testDistributions() {
        XCTAssertEqual(SpecialFunctions.normalCDF(1.96), 0.9750021048517795, accuracy: 1e-8)
        XCTAssertEqual(SpecialFunctions.normalCDF(-1), 0.15865525393145707, accuracy: 1e-8)
        XCTAssertEqual(SpecialFunctions.normalQuantile(0.975), 1.959963984540054, accuracy: 1e-7)
        XCTAssertEqual(SpecialFunctions.normalQuantile(0.9), 1.2815515655446004, accuracy: 1e-7)
        XCTAssertEqual(SpecialFunctions.normalQuantile(0.001), -3.090232306167813, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.tTwoSidedP(2.0, df: 10), 0.07338803477074037, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.tTwoSidedP(1.0, df: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SpecialFunctions.tCDF(2.228138851986274, df: 10), 0.975, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.tQuantile(0.975, df: 7), 2.364624251592784, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.chiSquareSF(10, df: 4), 0.04042768199451279, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.chiSquareSF(3.841458820694124, df: 1), 0.05, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.chiSquareCDF(5.991464547107979, df: 2), 0.95, accuracy: 1e-6)
        XCTAssertEqual(SpecialFunctions.fSF(3.0, d1: 4, d2: 20), 0.04320099833421409, accuracy: 1e-6)
    }

    func testTTests() throws {
        let a = [1.0, 2, 3, 4, 5], b = [2.0, 4, 6, 8, 10]
        let welch = try XCTUnwrap(HypothesisTests.tTest(a, b))
        XCTAssertEqual(welch.statistic, -1.8973665961010275, accuracy: 1e-9)
        XCTAssertEqual(welch.degreesOfFreedom, 5.882352941176471, accuracy: 1e-9)
        XCTAssertEqual(welch.pValue, 0.10753119493062724, accuracy: 1e-5)
        let pooled = try XCTUnwrap(HypothesisTests.tTest(a, b, equalVariance: true))
        XCTAssertEqual(pooled.pValue, 0.09434977284243763, accuracy: 1e-5)
        XCTAssertEqual(pooled.degreesOfFreedom, 8)
        let one = try XCTUnwrap(HypothesisTests.tTest([5.1, 4.9, 5.6, 5.8, 6.0, 5.2], mean: 5.0))
        XCTAssertEqual(one.statistic, 2.456769074559979, accuracy: 1e-8)
        XCTAssertEqual(one.pValue, 0.05745626526913226, accuracy: 1e-5)
        XCTAssertNil(HypothesisTests.tTest([1], [2, 3]))
    }

    func testChiSquare() throws {
        let r = try XCTUnwrap(HypothesisTests.chiSquareIndependence([[10, 20], [30, 5]]))
        XCTAssertEqual(r.statistic, 18.726190476190474, accuracy: 1e-9)
        XCTAssertEqual(r.degreesOfFreedom, 1)
        XCTAssertEqual(r.pValue, 1.5089565704354247e-05, accuracy: 1e-8)
        XCTAssertEqual(r.expected[0][0], 18.46153846, accuracy: 1e-6)
        let g = try XCTUnwrap(HypothesisTests.chiSquareGoodnessOfFit(observed: [20, 30, 50], expected: [1, 1, 1]))
        XCTAssertEqual(g.statistic, 14.0, accuracy: 1e-9)
        XCTAssertEqual(g.pValue, exp(-7), accuracy: 1e-8) // df = 2 → sf = exp(-x/2)
        XCTAssertNil(HypothesisTests.chiSquareIndependence([[1, 2]]))
    }

    func testDescriptiveAndQuantiles() throws {
        let x = [2.0, 4, 4, 4, 5, 5, 7, 9]
        let d = try XCTUnwrap(Stats.describe(x))
        XCTAssertEqual(d.mean, 5)
        XCTAssertEqual(d.variance, 32.0 / 7, accuracy: 1e-12)
        XCTAssertEqual(Stats.stdDev(x, sample: false), 2, accuracy: 1e-12)
        XCTAssertEqual(d.median, 4.5)
        XCTAssertEqual(d.min, 2); XCTAssertEqual(d.max, 9); XCTAssertEqual(d.count, 8)
        XCTAssertEqual(Stats.quantile([1, 2, 3, 4, 5], 0.25), 2)
        XCTAssertEqual(Stats.quantile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(Stats.quantile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9.1, accuracy: 1e-12)
        XCTAssertEqual(Stats.mad([1, 1, 2, 2, 4, 6, 9]), 1)
        XCTAssertNil(Stats.describe([]))
        XCTAssertGreaterThan(try XCTUnwrap(Stats.describe([1, 1, 1, 1, 10])).skewness, 1)
    }

    func testHistogramAndBoxPlot() throws {
        let x = (1...100).map(Double.init)
        let h = Stats.histogram(x, rule: .sturges)
        XCTAssertEqual(h.count, 8) // ceil(log2(100)) + 1
        XCTAssertEqual(h.reduce(0) { $0 + $1.count }, 100)
        XCTAssertEqual(h.first?.lower, 1); XCTAssertEqual(h.last?.upper, 100)
        let fd = Stats.histogram(x) // IQR = 49.5, width = 2·49.5/100^(1/3) ≈ 21.33 → 5 bins
        XCTAssertEqual(fd.count, 5)
        XCTAssertEqual(Stats.histogram([3, 3, 3]).count, 1)
        XCTAssertEqual(Stats.histogram(x, rule: .fixed(4)).map(\.count), [25, 25, 25, 25])

        let b = try XCTUnwrap(Stats.boxPlot([1, 2, 3, 4, 5, 6, 7, 8, 9, 50]))
        XCTAssertEqual(b.median, 5.5)
        XCTAssertEqual(b.q1, 3.25); XCTAssertEqual(b.q3, 7.75)
        XCTAssertEqual(b.outliers, [50])
        XCTAssertEqual(b.upperWhisker, 9); XCTAssertEqual(b.lowerWhisker, 1)
    }

    func testCorrelations() throws {
        XCTAssertEqual(try XCTUnwrap(Stats.pearson([1, 2, 3, 4, 5], [2, 4, 5, 4, 5])), 0.7745966692414835, accuracy: 1e-12)
        XCTAssertEqual(Stats.correlationPValue(r: 0.7745966692414835, n: 5), 0.12402706265755456, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(Stats.spearman([1, 2, 3, 4, 5, 6], [2, 1, 4, 3, 6, 8])), 0.8857142857142858, accuracy: 1e-12)
        XCTAssertEqual(Stats.ranks([10, 20, 10, 30]), [1.5, 3, 1.5, 4])
        XCTAssertNil(Stats.pearson([1, 1, 1], [1, 2, 3]))
        XCTAssertEqual(try XCTUnwrap(Stats.pearson([1, 2, 3], [6, 4, 2])), -1, accuracy: 1e-12)
    }

    func testAutocorrelationAndKDE() {
        let s = (0..<120).map { sin(2 * Double.pi * Double($0) / 12) }
        XCTAssertGreaterThan(Stats.autocorrelation(s, lag: 12), 0.85)
        XCTAssertLessThan(Stats.autocorrelation(s, lag: 6), -0.85)
        XCTAssertEqual(Stats.acf(s, maxLag: 3)[0], 1, accuracy: 1e-12)

        var rng = SeededGenerator(seed: 7)
        let x = (0..<400).map { _ in rng.normal() }
        let k = Stats.kde(x, points: 200)
        let step = k[1].x - k[0].x
        XCTAssertEqual(k.reduce(0) { $0 + $1.density } * step, 1, accuracy: 0.01) // integrates to 1
        let peak = k.max { $0.density < $1.density }!
        XCTAssertEqual(peak.x, 0, accuracy: 0.5)
        XCTAssertTrue(Stats.kde([], points: 10).isEmpty)
    }

    func testJenksBreaks() {
        let x: [Double] = [1, 2, 3, 2, 1, 50, 51, 52, 49, 100, 101, 99, 102]
        let breaks = Stats.jenksBreaks(x, classes: 3)
        XCTAssertEqual(breaks, [1, 49, 99, 102])
        XCTAssertEqual(Stats.classIndex(of: 3, breaks: breaks), 0)
        XCTAssertEqual(Stats.classIndex(of: 51, breaks: breaks), 1)
        XCTAssertEqual(Stats.classIndex(of: 100, breaks: breaks), 2)
        XCTAssertEqual(Stats.jenksBreaks([5, 5, 5], classes: 4), [5, 5])
        XCTAssertTrue(Stats.jenksBreaks([], classes: 3).isEmpty)
    }

    func testOLS() throws {
        // Exact plane y = 2 + 3a − b.
        var x: [[Double]] = [], y: [Double] = []
        for a in 0..<6 { for b in 0..<5 { x.append([Double(a), Double(b * b)]); y.append(2 + 3 * Double(a) - Double(b * b)) } }
        let f = try XCTUnwrap(OLS.fit(x: x, y: y))
        XCTAssertEqual(f.coefficients[0], 2, accuracy: 1e-8)
        XCTAssertEqual(f.coefficients[1], 3, accuracy: 1e-8)
        XCTAssertEqual(f.coefficients[2], -1, accuracy: 1e-8)
        XCTAssertEqual(f.rSquared, 1, accuracy: 1e-10)
        XCTAssertEqual(f.predict([2, 4]), 4, accuracy: 1e-8)

        // Simple regression against SciPy linregress([1..5], [2,4,5,4,5]): slope 0.6, intercept 2.2, p 0.12402706.
        let s = try XCTUnwrap(OLS.fit(x: [1, 2, 3, 4, 5], y: [2, 4, 5, 4, 5]))
        XCTAssertEqual(s.coefficients[1], 0.6, accuracy: 1e-10)
        XCTAssertEqual(s.coefficients[0], 2.2, accuracy: 1e-10)
        XCTAssertEqual(s.rSquared, 0.6, accuracy: 1e-10)
        XCTAssertEqual(s.pValues[1], 0.12402706265755456, accuracy: 1e-6)

        // Perfectly collinear features fall back to ridge and still fit the data.
        let c = try XCTUnwrap(OLS.fit(x: (0..<10).map { [Double($0), 2 * Double($0)] }, y: (0..<10).map { 1 + 5 * Double($0) }))
        XCTAssertTrue(c.usedRidge)
        XCTAssertEqual(c.predict([4, 8]), 21, accuracy: 1e-3)
        let sol = try XCTUnwrap(LinearAlgebra.solve([[2, 1], [1, 3]], [3, 5]))
        XCTAssertEqual(sol[0], 0.8, accuracy: 1e-12); XCTAssertEqual(sol[1], 1.4, accuracy: 1e-12)
        XCTAssertNil(LinearAlgebra.solve([[1, 2], [2, 4]], [1, 2]))
    }

    func testLogisticRegression() throws {
        var rng = SeededGenerator(seed: 11)
        var x: [[Double]] = [], y: [Bool] = []
        for _ in 0..<4000 {
            let a = rng.normal(), b = rng.normal()
            let p = 1 / (1 + exp(-(-0.5 + 1.2 * a)))
            x.append([a, b]); y.append(rng.unit() < p)
        }
        let f = try XCTUnwrap(LogisticRegression.fit(x: x, y: y))
        XCTAssertTrue(f.converged)
        XCTAssertEqual(f.coefficients[0], -0.5, accuracy: 0.12)
        XCTAssertEqual(f.coefficients[1], 1.2, accuracy: 0.15)
        XCTAssertEqual(f.coefficients[2], 0, accuracy: 0.12)
        XCTAssertLessThan(f.pValues[1], 1e-6)
        XCTAssertGreaterThan(f.pValues[2], 0.01)
        XCTAssertEqual(f.probability([0, 0]), 1 / (1 + exp(0.5)), accuracy: 0.03)
        XCTAssertNil(LogisticRegression.fit(x: [[1], [2], [3]], y: [true, true, true]))
    }

    func testInMemoryQuery() {
        let t = DataTable(columnNames: ["Region", "Amount"], rows: [["N", 10], ["S", 5], ["N", 7], ["S", nil], ["E", 1]])
        let q = InMemoryQuery.make(table: t, measure: "Amount")
        let g = q([.column("T", "Region")], [])
        XCTAssertEqual(g.rows.map { $0[0].asString }, ["N", "S", "E"])
        XCTAssertEqual(g.rows.map { $0[1].asDouble }, [17, 5, 1])
        XCTAssertEqual(q([], []).scalarMeasure, 23)
        var f = FilterSpec(field: .column("T", "Region"), kind: .basic); f.values = ["N"]
        XCTAssertEqual(q([], [f]).scalarMeasure, 17)
        f.isInverted = true
        XCTAssertEqual(q([], [f]).scalarMeasure, 6)
        var adv = FilterSpec(field: .column("T", "Amount"), kind: .advanced)
        adv.conditions = [FilterCondition(op: .greaterThan, value: 5)]
        XCTAssertEqual(q([], [adv]).scalarMeasure, 17)
        let avg = InMemoryQuery.aggregate(table: t, groupBy: ["Region"], measures: [("Amount", .average), ("Amount", .count)])
        XCTAssertEqual(avg[0, 1].asDouble, 8.5); XCTAssertEqual(avg[1, 2].asDouble, 1)
    }
}
