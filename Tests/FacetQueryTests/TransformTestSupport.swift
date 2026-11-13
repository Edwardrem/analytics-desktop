import XCTest
import FacetCore
@testable import FacetQuery

/// Applies UI transforms as steps of a query and evaluates the result with the query engine.
class TransformTestCase: FixtureTestCase {
    /// Region, Product, Qty, Price — five rows used by most transform tests.
    let sales = """
    #table(type table [Region = text, Product = text, Qty = Int64.Type, Price = number], {
        {"North", "Apple", 10, 1.5}, {"South", "Pear", 5, 2}, {"North", "Pear", 7, 2}, {"East", "Apple", null, 1.5}, {"South", "Apple", 3, 1.5}})
    """

    func script(_ transforms: [Transform], on source: String) -> String {
        transforms.reduce("let\n    Source = \(source)\nin\n    Source") { MScript.appending($1, to: $0) }
    }
    func apply(_ transforms: [Transform], on source: String, others: [(String, String)] = []) async throws -> MValue {
        try await engine([("Q", script(transforms, on: source))] + others).evaluateValue("Q")
    }
    func apply(_ transform: Transform, on source: String, others: [(String, String)] = []) async throws -> MValue {
        try await apply([transform], on: source, others: others)
    }
    /// Assert the column names and rendered rows a transform produces.
    func expect(_ transform: Transform, on source: String, others: [(String, String)] = [], columns: [String]? = nil, rows: [[String]],
                file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await apply(transform, on: source, others: others)
        if let columns { XCTAssertEqual(columnNames(v), columns, file: file, line: line) }
        XCTAssertEqual(try tableRows(v), rows, file: file, line: line)
    }
    /// The single cell a one-column, one-row transform result holds.
    func cell(_ transform: Transform, on source: String, column: String? = nil) async throws -> String {
        let v = try await apply(transform, on: source)
        guard case .table(let t) = v else { return show(v) }
        let i = column.flatMap { t.columnIndex($0) } ?? (t.columnCount - 1)
        return show(try t.columns[i][0])
    }
}

/// The Power Query row filter (FacetCore has a report-filter type of the same name).
typealias QFilter = FacetQuery.FilterCondition
