import Foundation
import FacetCore

/// Builds `AnalyticsQuery` closures over a flat in-memory `DataTable`, for callers that already hold
/// the rows (table visuals, previews, tests). Fields are matched to table columns by `FieldRef.name`.
/// Supports basic (value list) and advanced (condition) filters; other filter kinds are ignored.
public enum InMemoryQuery {
    /// - Parameters:
    ///   - table: the flat source rows.
    ///   - measure: name of the column to aggregate.
    ///   - aggregation: how to aggregate it (`.count` counts non-null values; `.none` behaves as `.sum`).
    public static func make(table: DataTable, measure: String, aggregation: Aggregation = .sum) -> AnalyticsQuery {
        return { groupBy, filters in
            aggregate(table: table, groupBy: groupBy.map(\.name), measures: [(measure, aggregation)], filters: filters)
        }
    }

    /// Groups `table` by the named columns and aggregates each measure column. Output columns are the
    /// group columns followed by one column per measure; groups appear in first-seen order.
    public static func aggregate(table: DataTable, groupBy: [String], measures: [(column: String, aggregation: Aggregation)],
                                 filters: [FilterSpec] = []) -> DataTable {
        let groupIdx = groupBy.compactMap { table.columnIndex($0) }
        let measureIdx = measures.map { table.columnIndex($0.column) }
        let filterIdx: [(Int, FilterSpec)] = filters.compactMap { f in table.columnIndex(f.field.name).map { ($0, f) } }
        var order: [[Value]] = []
        var buckets: [[Value]: [[Double]]] = [:]
        for r in 0..<table.rowCount {
            var keep = true
            for (ci, f) in filterIdx where !matches(table[r, ci], f) { keep = false; break }
            if !keep { continue }
            let key = groupIdx.map { table[r, $0] }
            if buckets[key] == nil { buckets[key] = [[Double]](repeating: [], count: measures.count); order.append(key) }
            for (m, ci) in measureIdx.enumerated() {
                guard let ci else { continue }
                let v = table[r, ci]
                if measures[m].aggregation == .count || measures[m].aggregation == .distinctCount {
                    if !v.isNull { buckets[key]?[m].append(v.asDouble ?? Double(v.hashValue % 1_000_003)) }
                } else if let d = v.asDouble { buckets[key]?[m].append(d) }
            }
        }
        if groupIdx.isEmpty, order.isEmpty { order = [[]]; buckets[[]] = [[Double]](repeating: [], count: measures.count) }
        var cols = groupIdx.map { DataColumn(name: table.columns[$0].name, type: table.columns[$0].type) }
        for m in measures { cols.append(DataColumn(name: m.column, type: .decimal)) }
        for key in order {
            for (i, v) in key.enumerated() { cols[i].values.append(v) }
            for m in measures.indices {
                let xs = buckets[key]?[m] ?? []
                cols[groupIdx.count + m].values.append(reduce(xs, measures[m].aggregation))
            }
        }
        return DataTable(name: table.name, columns: cols)
    }

    static func reduce(_ xs: [Double], _ agg: Aggregation) -> Value {
        switch agg {
        case .count: return .double(Double(xs.count))
        case .distinctCount: return .double(Double(Set(xs).count))
        default: break
        }
        guard !xs.isEmpty else { return .null }
        switch agg {
        case .none, .sum: return .double(xs.reduce(0, +))
        case .average: return .double(Stats.mean(xs))
        case .min: return .double(xs.min() ?? 0)
        case .max: return .double(xs.max() ?? 0)
        case .stdDev: return .double(Stats.stdDev(xs))
        case .variance: return .double(Stats.variance(xs))
        case .median: return .double(Stats.median(xs))
        case .first: return .double(xs[0])
        case .last: return .double(xs[xs.count - 1])
        case .count, .distinctCount: return .double(Double(xs.count))
        }
    }

    /// Evaluates a basic or advanced filter against one value. Other filter kinds always match.
    public static func matches(_ v: Value, _ f: FilterSpec) -> Bool {
        switch f.kind {
        case .basic:
            if f.values.isEmpty { return true }
            return f.values.contains(v) != f.isInverted
        case .advanced:
            if f.conditions.isEmpty { return true }
            let results = f.conditions.map { test(v, $0) }
            return f.conditionsUseOr ? results.contains(true) : !results.contains(false)
        default: return true
        }
    }

    static func test(_ v: Value, _ c: FilterCondition) -> Bool {
        let s = v.asString.lowercased(), t = c.value.asString.lowercased()
        switch c.op {
        case .equals: return v == c.value || (!v.isNull && s == t)
        case .notEquals: return !(v == c.value || (!v.isNull && s == t))
        case .greaterThan: return !v.isNull && v > c.value
        case .greaterOrEqual: return !v.isNull && v >= c.value
        case .lessThan: return !v.isNull && v < c.value
        case .lessOrEqual: return !v.isNull && v <= c.value
        case .contains: return s.contains(t)
        case .notContains: return !s.contains(t)
        case .startsWith: return s.hasPrefix(t)
        case .notStartsWith: return !s.hasPrefix(t)
        case .endsWith: return s.hasSuffix(t)
        case .isBlank: return v.isNull
        case .isNotBlank: return !v.isNull
        case .isEmpty: return v.isNull || s.isEmpty
        case .isNotEmpty: return !(v.isNull || s.isEmpty)
        }
    }
}

extension DataTable {
    /// Numeric values of the last column, used as "the measure" of an `AnalyticsQuery` result.
    func measureValue(row: Int) -> Double? {
        guard columnCount > 0, row < rowCount else { return nil }
        return self[row, columnCount - 1].asDouble
    }
    /// Scalar result of an ungrouped `AnalyticsQuery`.
    var scalarMeasure: Double? { rowCount > 0 ? measureValue(row: 0) : nil }
}
