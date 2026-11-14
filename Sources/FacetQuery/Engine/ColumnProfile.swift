import Foundation
import FacetCore

/// Data profiling for one column of a preview: the numbers behind the editor's Column quality, Column distribution
/// and Column profile views. It extends what `Table.Profile` reports (min, max, average, standard deviation, count,
/// null count, distinct count) with error and empty counts, unique values and the value histogram.
///
/// Definitions (Power Query's):
/// - **error**: the cell holds an error; **empty**: the cell is null or empty text; **valid**: everything else.
/// - **distinct**: the number of different values among the cells that are not errors (null counts as a value, as in
///   `Table.Profile`); **unique**: the values among those that occur exactly once.
/// - Minimum, maximum, average and standard deviation (sample, n − 1) look at valid cells only; the numeric
///   statistics are nil unless every valid cell is a number.
public struct ColumnProfile: Sendable {
    public var column: String
    public var count: Int
    public var errorCount: Int
    public var emptyCount: Int
    /// Cells holding empty text (a subset of `emptyCount`).
    public var emptyTextCount: Int
    public var distinctCount: Int
    public var uniqueCount: Int
    public var minimum: Value
    public var maximum: Value
    public var average: Double?
    public var standardDeviation: Double?
    public var zeroCount: Int?
    public var evenCount: Int?
    public var oddCount: Int?
    public var nanCount: Int?
    /// Value histogram of the cells that are not errors: most frequent first, ties in value order.
    public var distribution: [ValueCount]

    public struct ValueCount: Sendable, Equatable {
        public var value: Value
        public var count: Int
        public init(value: Value, count: Int) { self.value = value; self.count = count }
    }

    public var validCount: Int { count - errorCount - emptyCount }
    /// Share of valid, error and empty cells (0…1; all zero for a column without rows).
    public var quality: (valid: Double, error: Double, empty: Double) {
        guard count > 0 else { return (0, 0, 0) }
        let n = Double(count)
        return (Double(validCount) / n, Double(errorCount) / n, Double(emptyCount) / n)
    }
    /// Whole percentages that add up to 100 (largest-remainder rounding), as the Column quality strip shows them.
    public var qualityPercentages: (valid: Int, error: Int, empty: Int) {
        guard count > 0 else { return (0, 0, 0) }
        let exact = [validCount, errorCount, emptyCount].map { Double($0) * 100 / Double(count) }
        var whole = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(whole[$0]), -$0) > (exact[$1] - Double(whole[$1]), -$1) }
        var missing = 100 - whole.reduce(0, +)
        for i in order where missing > 0 { whole[i] += 1; missing -= 1 }
        return (whole[0], whole[1], whole[2])
    }
}

public enum ColumnProfiler {
    /// Profiles of every column of a preview (cell errors are taken from the preview).
    public static func profile(_ preview: QueryPreview) -> [ColumnProfile] {
        profile(table: preview.table, cellErrors: preview.cellErrors)
    }

    /// Profiles of every column of a table. `cellErrors` is column index → row indexes holding an error.
    public static func profile(table: DataTable, cellErrors: [Int: [Int: String]] = [:]) -> [ColumnProfile] {
        table.columns.enumerated().map { index, column in
            profile(column: column, errorRows: Set((cellErrors[index] ?? [:]).keys))
        }
    }

    public static func profile(column: DataColumn, errorRows: Set<Int> = []) -> ColumnProfile {
        var empty = 0, emptyText = 0, errors = 0
        var counts: [Value: Int] = [:]
        var valid: [Value] = []
        for (row, value) in column.values.enumerated() {
            if errorRows.contains(row) { errors += 1; continue }
            counts[value, default: 0] += 1
            if value.isNull { empty += 1 }
            else if case .string(let s) = value, s.isEmpty { empty += 1; emptyText += 1 }
            else { valid.append(value) }
        }
        let numbers: [Double] = valid.compactMap { v in
            switch v {
            case .int(let i): return Double(i)
            case .double(let d): return d
            default: return nil
            }
        }
        let numeric = !valid.isEmpty && numbers.count == valid.count
        let finite = numbers.filter { !$0.isNaN }
        let whole = finite.filter { $0.isFinite && $0 == $0.rounded() && abs($0) < 9e15 }
        let comparable = numeric ? valid.filter { v in if case .double(let d) = v { return !d.isNaN }; return true } : valid
        let distribution = counts.map { ColumnProfile.ValueCount(value: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
        return ColumnProfile(
            column: column.name, count: column.values.count, errorCount: errors, emptyCount: empty, emptyTextCount: emptyText,
            distinctCount: counts.count, uniqueCount: counts.values.filter { $0 == 1 }.count,
            minimum: comparable.min() ?? .null, maximum: comparable.max() ?? .null,
            average: numeric && !finite.isEmpty ? finite.reduce(0, +) / Double(finite.count) : nil,
            standardDeviation: numeric ? MLib.standardDeviation(finite) : nil,
            zeroCount: numeric ? finite.filter { $0 == 0 }.count : nil,
            evenCount: numeric ? whole.filter { Int64($0) % 2 == 0 }.count : nil,
            oddCount: numeric ? whole.filter { Int64($0) % 2 != 0 }.count : nil,
            nanCount: numeric ? numbers.count - finite.count : nil,
            distribution: distribution)
    }
}

public extension QueryEngine {
    /// Column profiles of a query (or of step `upToStep`). `rowLimit` 1000 is the editor's "based on top 1000 rows";
    /// nil profiles the entire data set.
    func profile(_ name: String, upToStep: Int? = nil, rowLimit: Int? = 1000) async throws -> [ColumnProfile] {
        ColumnProfiler.profile(try await evaluatePreview(name, upToStep: upToStep, rowLimit: rowLimit))
    }
}
