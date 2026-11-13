import XCTest
import FacetCore
@testable import FacetQuery

final class ColumnProfileTests: XCTestCase {
    /// 2, 4, null, 4, <error>, 0: four valid cells (2, 4, 4, 0), one empty, one error.
    private var numbers: ColumnProfile {
        let column = DataColumn(name: "N", type: .integer, values: [.int(2), .int(4), .null, .int(4), .int(7), .int(0)])
        return ColumnProfiler.profile(column: column, errorRows: [4])
    }

    func testQualityCountsAndPercentages() {
        let p = numbers
        XCTAssertEqual(p.count, 6)
        XCTAssertEqual(p.errorCount, 1)
        XCTAssertEqual(p.emptyCount, 1)
        XCTAssertEqual(p.validCount, 4)
        XCTAssertEqual(p.quality.valid, 4.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(p.quality.error, 1.0 / 6.0, accuracy: 1e-12)
        // 66.67 / 16.67 / 16.67 → whole percentages that still add up to 100.
        let shown = p.qualityPercentages
        XCTAssertEqual(shown.valid + shown.error + shown.empty, 100)
        XCTAssertEqual(shown.valid, 67)
        XCTAssertEqual(shown.error, 17)
        XCTAssertEqual(shown.empty, 16)
    }

    func testDistributionCountsDistinctAndUniqueWithoutErrors() {
        let p = numbers
        XCTAssertEqual(p.distinctCount, 4)      // 2, 4, null, 0 (the error cell's 7 is not a value)
        XCTAssertEqual(p.uniqueCount, 3)        // 2, null, 0 occur once
        XCTAssertEqual(p.distribution.first, ColumnProfile.ValueCount(value: .int(4), count: 2))
        XCTAssertEqual(p.distribution.map(\.count), [2, 1, 1, 1])
        XCTAssertFalse(p.distribution.contains { $0.value == .int(7) })
    }

    func testNumericStatisticsUseValidCells() throws {
        let p = numbers
        XCTAssertEqual(p.minimum, .int(0))
        XCTAssertEqual(p.maximum, .int(4))
        XCTAssertEqual(try XCTUnwrap(p.average), 2.5, accuracy: 1e-12)                 // (2 + 4 + 4 + 0) / 4
        XCTAssertEqual(try XCTUnwrap(p.standardDeviation), (11.0 / 3.0).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(p.zeroCount, 1)
        XCTAssertEqual(p.evenCount, 4)
        XCTAssertEqual(p.oddCount, 0)
        XCTAssertEqual(p.nanCount, 0)
    }

    func testTextColumnCountsEmptyTextAsEmptyAndHasNoNumericStatistics() {
        let column = DataColumn(name: "T", type: .text, values: [.string("a"), .string(""), .string("b"), .string("a"), .null])
        let p = ColumnProfiler.profile(column: column)
        XCTAssertEqual(p.emptyCount, 2)
        XCTAssertEqual(p.emptyTextCount, 1)
        XCTAssertEqual(p.validCount, 3)
        XCTAssertEqual(p.distinctCount, 4)      // a, "", b, null
        XCTAssertEqual(p.uniqueCount, 3)        // "", b, null
        XCTAssertEqual(p.minimum, .string("a"))
        XCTAssertEqual(p.maximum, .string("b"))
        XCTAssertNil(p.average)
        XCTAssertNil(p.standardDeviation)
        XCTAssertNil(p.evenCount)
        XCTAssertEqual(p.distribution.first, ColumnProfile.ValueCount(value: .string("a"), count: 2))
    }

    func testEmptyColumn() {
        let p = ColumnProfiler.profile(column: DataColumn(name: "E", values: []))
        XCTAssertEqual(p.count, 0)
        XCTAssertEqual(p.qualityPercentages.valid, 0)
        XCTAssertEqual(p.minimum, .null)
        XCTAssertTrue(p.distribution.isEmpty)
    }

    func testEngineProfilesAStepIncludingCellErrors() async throws {
        let script = """
        let
            Source = #table({"A", "B"}, {{"1", "x"}, {"oops", "x"}, {"3", null}}),
            Typed = Table.TransformColumnTypes(Source, {{"A", Int64.Type}})
        in
            Typed
        """
        let engine = QueryEngine(queries: [QueryDefinition(name: "Q", mScript: script)], environment: QueryEnvironment())
        let typed = try await engine.profile("Q")
        XCTAssertEqual(typed.map(\.column), ["A", "B"])
        XCTAssertEqual(typed[0].errorCount, 1)       // "oops" is not a number
        XCTAssertEqual(typed[0].validCount, 2)
        XCTAssertEqual(try XCTUnwrap(typed[0].average), 2, accuracy: 1e-12)
        XCTAssertEqual(typed[1].emptyCount, 1)
        XCTAssertEqual(typed[1].distinctCount, 2)    // x, null
        XCTAssertEqual(typed[1].uniqueCount, 1)      // null
        let source = try await engine.profile("Q", upToStep: 0)
        XCTAssertEqual(source[0].errorCount, 0)
        XCTAssertEqual(source[0].distinctCount, 3)
    }
}
