import Foundation
import FacetCore

/// Chart-ready view of a `VisualData` result: categories along one axis, one series per value
/// column (or per legend value, pivoting long → wide), numeric values with `nil` for blanks,
/// cross-highlight baselines, and the `DataPointSelection` behind every mark.
public struct SeriesModel {
    public enum AxisKind { case categorical, date, numeric }

    public struct Category {
        public let index: Int
        /// One value per category column (hierarchy levels, outermost first).
        public let values: [Value]
        /// Formatted label per level.
        public let levels: [String]
        /// Levels joined with a space ("2024 Q1").
        public let label: String
    }

    public struct Series {
        public let index: Int
        public let name: String
        /// Value column in `data.table` this series reads.
        public let column: Int
        public let field: FieldRef?
        /// The legend value this series was pivoted from, when a legend well is present.
        public let legendValue: Value?
        public let format: String
        /// True for series from the line well of combo charts.
        public let isLine: Bool
        /// Value per category (nil = blank).
        public var values: [Double?]
        /// Un-highlighted value per category when cross-highlighting is active.
        public var baseline: [Double?]
        /// Source row per category (nil when the cell has no row).
        public var rows: [Int?]
    }

    /// One small-multiples panel: its title, the rows it owns and the grouping values that define it.
    public struct Partition {
        public let title: String
        public let rows: [Int]
        public let fields: [FieldRef]
        public let values: [Value]
    }

    public let data: VisualData
    public private(set) var categories: [Category] = []
    public private(set) var series: [Series] = []
    public let categoryColumns: [Int]
    public let legendColumn: Int?
    public let partition: Partition?
    public let hasBaseline: Bool
    public let axisKind: AxisKind

    public var categoryFields: [FieldRef] { categoryColumns.compactMap { data.fields[safe: $0] ?? nil } }
    public var legendField: FieldRef? { legendColumn.flatMap { data.fields[safe: $0] ?? nil } }
    public var isEmpty: Bool { series.isEmpty || categories.isEmpty }
    /// Caption for the category axis ("Year Quarter").
    public var categoryTitle: String {
        categoryColumns.map { c in (data.fields[safe: c] ?? nil)?.caption ?? data.table.columns[c].name }.joined(separator: " ")
    }

    /// - Parameters:
    ///   - categoryWell: well whose columns form the category axis (e.g. `.category`, `.legend` for pies).
    ///   - valueWells: wells holding the numeric columns.
    ///   - lineWell: optional well whose columns become line series (combo charts).
    ///   - legendWell: optional well to pivot series by.
    ///   - partition: restrict values to one small-multiples panel. Categories and series are always
    ///     derived from the whole result so every panel shares the same axis and colours.
    public init(spec: VisualSpec, data: VisualData, categoryWell: Well = .category, valueWells: [Well] = [.values],
                lineWell: Well? = nil, legendWell: Well? = .legend, partition: Partition? = nil) {
        self.data = data
        self.partition = partition
        let t = data.table
        let nCols = t.columnCount
        let catCols = data.indices(categoryWell).filter { $0 < nCols }
        categoryColumns = catCols
        let visible: (Int) -> Bool = { c in c < nCols && !((data.fields[safe: c] ?? nil)?.isHidden ?? false) }
        let barCols = valueWells.flatMap { data.indices($0) }.filter(visible)
        let lineCols = (lineWell.map { data.indices($0) } ?? []).filter(visible)
        let legCol = legendWell.flatMap { data.indices($0).first }.flatMap { $0 < nCols ? $0 : nil }
        legendColumn = legCol
        let base = data.baseline.flatMap { $0.rowCount == t.rowCount && $0.columnCount == nCols ? $0 : nil }
        hasBaseline = base != nil

        // Axis kind
        if catCols.count == 1 {
            let col = t.columns[catCols[0]]
            let nonNull = col.values.first { !$0.isNull }
            if col.type.isTemporal || { if case .date? = nonNull { return true }; return false }() { axisKind = .date }
            else if col.type.isNumeric { axisKind = .numeric }
            else { axisKind = .categorical }
        } else { axisKind = .categorical }

        // Skeleton: categories and legend values over all rows, in order of appearance.
        var catIndex: [[Value]: Int] = [:]
        var cats: [Category] = []
        var legIndex: [Value: Int] = [:]
        var legValues: [Value] = []
        let rowCount = t.rowCount
        var rowCat = [Int](repeating: 0, count: rowCount)
        var rowLeg = [Int](repeating: 0, count: rowCount)
        if catCols.isEmpty { cats = [Category(index: 0, values: [], levels: [], label: "")] }
        for r in 0..<rowCount {
            if !catCols.isEmpty {
                let key = catCols.map { t[r, $0] }
                if let i = catIndex[key] { rowCat[r] = i } else {
                    let levels = zip(catCols, key).map { c, v in
                        v.isNull ? "(Blank)" : ValueFormatter.format(v, data.formats[safe: c] ?? "")
                    }
                    catIndex[key] = cats.count; rowCat[r] = cats.count
                    cats.append(Category(index: cats.count, values: key, levels: levels, label: levels.joined(separator: " ")))
                }
            }
            if let lc = legCol {
                let v = t[r, lc]
                if let i = legIndex[v] { rowLeg[r] = i } else { legIndex[v] = legValues.count; rowLeg[r] = legValues.count; legValues.append(v) }
            }
        }
        categories = cats

        // Series skeleton
        let n = cats.count
        func caption(_ c: Int) -> String { (data.fields[safe: c] ?? nil)?.caption ?? t.columns[c].name }
        func make(_ name: String, _ col: Int, _ leg: Value?, _ line: Bool) -> Series {
            Series(index: series.count, name: name, column: col, field: data.fields[safe: col] ?? nil, legendValue: leg,
                   format: data.formats[safe: col] ?? "", isLine: line,
                   values: Array(repeating: nil, count: n), baseline: Array(repeating: nil, count: n),
                   rows: Array(repeating: nil, count: n))
        }
        var lookup: [Int: [Int]] = [:] // legend index (or 0) → series indices
        if let lc = legCol, !barCols.isEmpty {
            for (li, lv) in legValues.enumerated() {
                let legName = lv.isNull ? "(Blank)" : ValueFormatter.format(lv, data.formats[safe: lc] ?? "")
                for col in barCols {
                    lookup[li, default: []].append(series.count)
                    series.append(make(barCols.count > 1 ? "\(legName) · \(caption(col))" : legName, col, lv, false))
                }
            }
        } else {
            for col in barCols { series.append(make(caption(col), col, nil, false)) }
        }
        let pivoted = legCol != nil && !barCols.isEmpty
        let unpivoted: [Int] = pivoted ? [] : Array(series.indices)
        var lineSeries: [Int] = []
        for col in lineCols { lineSeries.append(series.count); series.append(make(caption(col), col, nil, true)) }

        // Fill
        for r in partition?.rows ?? Array(0..<rowCount) where r < rowCount {
            let ci = rowCat[r]
            let targets = (pivoted ? (lookup[rowLeg[r]] ?? []) : unpivoted) + lineSeries
            for si in targets {
                let col = series[si].column
                if let v = t[r, col].asDouble, v.isFinite {
                    series[si].values[ci] = (series[si].values[ci] ?? 0) + v
                    if series[si].rows[ci] == nil { series[si].rows[ci] = r }
                }
                if let b = base, let v = b[r, col].asDouble, v.isFinite {
                    series[si].baseline[ci] = (series[si].baseline[ci] ?? 0) + v
                }
            }
        }
    }

    // MARK: Selections

    /// The data point behind the mark at (category, series): category fields, legend field and
    /// small-multiples fields with that mark's values.
    public func selection(category c: Int, series s: Int? = nil) -> DataPointSelection {
        var fields: [FieldRef] = [], values: [Value] = []
        if let cat = categories[safe: c] {
            for (i, col) in categoryColumns.enumerated() {
                if let f = data.fields[safe: col] ?? nil, let v = cat.values[safe: i] { fields.append(f); values.append(v) }
            }
        }
        if let s, let f = legendField, let lv = series[safe: s]?.legendValue { fields.append(f); values.append(lv) }
        if let p = partition { fields += p.fields; values += p.values }
        return DataPointSelection(fields: fields, values: values)
    }

    /// Selection for a whole series (legend click). Nil when series are measures rather than legend values.
    public func seriesSelection(_ s: Int) -> DataPointSelection? {
        guard let f = legendField, let lv = series[safe: s]?.legendValue else { return nil }
        return DataPointSelection(fields: [f], values: [lv])
    }

    // MARK: Labels

    /// The format string of a data point: its own when the measure's dynamic format string gives
    /// points different formats, otherwise the series'.
    public func format(series s: Int, category c: Int?) -> String {
        guard let one = series[safe: s] else { return "" }
        if let c, !data.pointFormats.isEmpty, let row = one.rows[safe: c] ?? nil { return data.format(row: row, col: one.column) }
        return one.format
    }

    public func formatted(_ v: Double, series s: Int, category c: Int? = nil) -> String {
        ValueFormatter.format(.double(v), format(series: s, category: c))
    }

    /// Extra (label, value) pairs from the Tooltips well for the row behind a mark.
    public func tooltipFields(row: Int?) -> [(label: String, value: String)] {
        SeriesModel.tooltipFields(data: data, row: row)
    }

    public static func tooltipFields(data: VisualData, row: Int?) -> [(label: String, value: String)] {
        guard let row, row < data.table.rowCount else { return [] }
        return data.indices(.tooltips).filter { $0 < data.table.columnCount }.map { c in
            ((data.fields[safe: c] ?? nil)?.caption ?? data.table.columns[c].name, data.formatted(row: row, col: c))
        }
    }

    /// Numeric axis position per category for continuous axes: OLE serial days for dates, the value for numbers.
    public var continuousPositions: [Double]? {
        guard axisKind != .categorical else { return nil }
        let p = categories.map { $0.values.first?.asDouble }
        guard !p.contains(where: { $0 == nil }) else { return nil }
        return p.compactMap { $0 }
    }

    // MARK: Small multiples

    /// Splits the rows by the Small multiples well. Empty when that well has no fields.
    public static func partitions(data: VisualData) -> [Partition] {
        let cols = data.indices(.smallMultiples).filter { $0 < data.table.columnCount }
        guard !cols.isEmpty else { return [] }
        let t = data.table
        var index: [[Value]: Int] = [:]
        var keys: [[Value]] = [], rows: [[Int]] = []
        for r in 0..<t.rowCount {
            let key = cols.map { t[r, $0] }
            if let i = index[key] { rows[i].append(r) } else { index[key] = keys.count; keys.append(key); rows.append([r]) }
        }
        return keys.enumerated().map { i, key in
            var fields: [FieldRef] = [], values: [Value] = []
            var parts: [String] = []
            for (c, v) in zip(cols, key) {
                parts.append(v.isNull ? "(Blank)" : ValueFormatter.format(v, data.formats[safe: c] ?? ""))
                if let f = data.fields[safe: c] ?? nil { fields.append(f); values.append(v) }
            }
            return Partition(title: parts.joined(separator: " "), rows: rows[i], fields: fields, values: values)
        }
    }

    /// Generic selection for an arbitrary row: every grouping column in `columns` with a known field.
    public static func selection(data: VisualData, row: Int, columns: [Int]) -> DataPointSelection {
        var fields: [FieldRef] = [], values: [Value] = []
        for c in columns where c < data.table.columnCount && row < data.table.rowCount {
            if let f = data.fields[safe: c] ?? nil { fields.append(f); values.append(data.table[row, c]) }
        }
        return DataPointSelection(fields: fields, values: values)
    }
}
