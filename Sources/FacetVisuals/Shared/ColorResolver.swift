import SwiftUI
import FacetCore
import FacetDesign

/// Evaluates `ConditionalFormat` rules for a value. Shared by charts (data point colour) and
/// tables (cell background, font colour, icons, data bars).
public enum ConditionalFormatEvaluator {
    /// Numeric extent of a column, computed once and reused for every cell.
    public struct Range: Sendable {
        public var min: Double, max: Double
        public init(min: Double, max: Double) { self.min = min; self.max = max }
        public init(_ values: [Value]) {
            var lo = Double.infinity, hi = -Double.infinity
            for v in values { if let d = v.asDouble, d.isFinite, !isText(v) { lo = Swift.min(lo, d); hi = Swift.max(hi, d) } }
            if lo > hi { lo = 0; hi = 0 }
            self.min = lo; self.max = hi
        }
    }

    private static func isText(_ v: Value) -> Bool { if case .string = v { return true }; return false }

    /// Colour for `value` given the other values in its column. Nil when the format produces no colour
    /// (blank value, no matching rule, unparseable field value).
    public static func color(for value: Value, in values: [Value], format: ConditionalFormat) -> Color? {
        color(for: value, range: Range(values), format: format)
    }
    public static func color(for value: Value, range: Range, format: ConditionalFormat) -> Color? {
        hex(for: value, range: range, format: format).map { Color(hex: $0) }
    }

    /// Hex colour ("#RRGGBB") for `value`; see `color(for:in:format:)`.
    public static func hex(for value: Value, range: Range, format: ConditionalFormat) -> String? {
        switch format.mode {
        case .fieldValue:
            return colorString(value.asString)
        case .gradient:
            guard !isText(value), let v = value.asDouble, v.isFinite else { return nil }
            let lo = format.minValue ?? range.min, hi = format.maxValue ?? range.max
            guard hi > lo else { return format.maxColor }
            if let midColor = format.midColor {
                let mid = format.midValue ?? (lo + hi) / 2
                if v <= mid { return HexColor.lerp(format.minColor, midColor, mid > lo ? (v - lo) / (mid - lo) : 1) }
                return HexColor.lerp(midColor, format.maxColor, hi > mid ? (v - mid) / (hi - mid) : 1)
            }
            return HexColor.lerp(format.minColor, format.maxColor, (v - lo) / (hi - lo))
        case .rules:
            return matchingRule(value, range: range, format: format)?.color
        }
    }

    /// SF Symbol name (or literal glyph) of the first matching rule that carries an icon.
    public static func icon(for value: Value, in values: [Value], format: ConditionalFormat) -> String? {
        icon(for: value, range: Range(values), format: format)
    }
    public static func icon(for value: Value, range: Range, format: ConditionalFormat) -> String? {
        if format.mode == .rules { return matchingRule(value, range: range, format: format)?.icon }
        // Gradient mode: a three-step traffic light across the range.
        guard let v = value.asDouble, range.max > range.min else { return nil }
        let t = (v - (format.minValue ?? range.min)) / ((format.maxValue ?? range.max) - (format.minValue ?? range.min))
        return t < 1.0 / 3 ? "arrowtriangle.down.fill" : (t < 2.0 / 3 ? "minus" : "arrowtriangle.up.fill")
    }

    /// Signed bar length for data bars: 0…1 for positive values (relative to the maximum), −1…0 for
    /// negative values (relative to the minimum). Nil for blanks.
    public static func dataBarFraction(for value: Value, in values: [Value], format: ConditionalFormat) -> Double? {
        dataBarFraction(for: value, range: Range(values), format: format)
    }
    public static func dataBarFraction(for value: Value, range: Range, format: ConditionalFormat) -> Double? {
        guard !isText(value), let v = value.asDouble, v.isFinite else { return nil }
        let lo = format.minValue ?? Swift.min(range.min, 0), hi = format.maxValue ?? Swift.max(range.max, 0)
        if v >= 0 {
            let base = Swift.max(lo, 0)
            return hi > base ? Swift.max(0, Swift.min(1, (v - base) / (hi - base))) : 0
        }
        return lo < 0 ? -Swift.max(0, Swift.min(1, v / lo)) : 0
    }

    /// The first rule of `format` that `value` meets (percent thresholds are relative to `range`).
    public static func matchingRule(_ value: Value, range: Range, format: ConditionalFormat) -> ConditionalFormat.Rule? {
        let v = isText(value) ? nil : value.asDouble
        func threshold(_ x: Double, _ r: ConditionalFormat.Rule) -> Double {
            r.isPercent ? range.min + x / 100 * (range.max - range.min) : x
        }
        func test(_ op: FilterOperator, _ x: Double) -> Bool {
            switch op {
            case .isBlank, .isEmpty: return value.isNull
            case .isNotBlank, .isNotEmpty: return !value.isNull
            default: break
            }
            guard let v else { return false }
            switch op {
            case .equals: return v == x
            case .notEquals: return v != x
            case .greaterThan: return v > x
            case .greaterOrEqual: return v >= x
            case .lessThan: return v < x
            case .lessOrEqual: return v <= x
            default: return false
            }
        }
        for r in format.rules {
            guard test(r.op, threshold(r.value, r)) else { continue }
            if let uop = r.upperOp, let uv = r.upperValue, !test(uop, threshold(uv, r)) { continue }
            return r
        }
        return nil
    }

    /// Accepts "#RGB", "#RRGGBB", "#RRGGBBAA" and common CSS colour names.
    public static func colorString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if HexColor.rgb(t) != nil, t.hasPrefix("#") || t.count == 6 { return t.hasPrefix("#") ? t : "#" + t }
        return named[t.lowercased()]
    }
    private static let named: [String: String] = [
        "red": "#FF453A", "green": "#34C759", "blue": "#0A84FF", "yellow": "#FFD60A", "orange": "#FF9F0A",
        "purple": "#BF5AF2", "pink": "#FF375F", "teal": "#30B0C7", "cyan": "#64D2FF", "indigo": "#5E5CE6",
        "brown": "#AC8E68", "gray": "#8E8E93", "grey": "#8E8E93", "black": "#000000", "white": "#FFFFFF",
    ]
}

/// Resolves the colour of every series and data point: theme palette → explicit per-series /
/// per-category overrides in `format["dataColors"]` → conditional formatting (`.dataPointColor`).
public struct ColorResolver {
    public let theme: ThemeSpec
    let overrides: [String: JSONValue]
    let conditional: ConditionalFormat?
    let driverColumn: Int?
    let range: ConditionalFormatEvaluator.Range
    let table: DataTable

    public init(spec: VisualSpec, data: VisualData, theme: ThemeSpec) {
        self.theme = theme
        self.table = data.table
        overrides = spec.format["dataColors"] ?? theme.visualDefaults[spec.type.rawValue]?["dataColors"] ?? [:]
        conditional = spec.conditionalFormats.first { $0.target == .dataPointColor }
        var col: Int?
        if let cf = conditional {
            func find(_ key: String?) -> Int? {
                guard let key else { return nil }
                return data.fields.firstIndex { $0?.key == key }.flatMap { $0 < data.table.columnCount ? $0 : nil }
            }
            col = find(cf.basedOn?.key) ?? find(cf.appliesToKey)
                ?? [Well.values, .y, .size, .x].lazy.compactMap { data.indices($0).first }.first
        }
        driverColumn = col.flatMap { $0 < data.table.columnCount ? $0 : nil }
        range = ConditionalFormatEvaluator.Range(driverColumn.map { data.table.columns[$0].values } ?? [])
    }

    /// True when a `.dataPointColor` conditional format is active (charts then colour per point and
    /// usually hide the legend swatches' meaning).
    public var hasConditionalColor: Bool { conditional != nil }

    /// Colour of series `index` named `name`: explicit override, else the theme palette.
    public func seriesColor(_ index: Int, name: String) -> Color {
        if let hex = overrides[name]?.stringValue, HexColor.rgb(hex) != nil { return Color(hex: hex) }
        return theme.dataColor(index)
    }

    /// Colour of one data point. Conditional formatting wins, then a per-category override, then the series colour.
    /// - Parameters:
    ///   - row: source row in the visual's table (drives conditional formats based on another field).
    ///   - value: the plotted value, used when `row` is unknown.
    public func pointColor(series index: Int, seriesName: String, category: String? = nil, row: Int? = nil, value: Double? = nil) -> Color {
        if let cf = conditional {
            let v: Value
            if let row, let c = driverColumn, row < table.rowCount { v = table[row, c] }
            else { v = value.map(Value.double) ?? .null }
            if let c = ConditionalFormatEvaluator.color(for: v, range: range, format: cf) { return c }
        }
        if let category, let hex = overrides[category]?.stringValue, HexColor.rgb(hex) != nil { return Color(hex: hex) }
        return seriesColor(index, name: seriesName)
    }

    /// Sequential colour for heat-style charts: theme minimum → (center) → maximum, `t` in 0…1.
    public func sequential(_ t: Double, threeStop: Bool = false) -> Color {
        let k = max(0, min(1, t))
        if threeStop {
            return Color(hex: k < 0.5 ? HexColor.lerp(theme.minimum, theme.center, k * 2) : HexColor.lerp(theme.center, theme.maximum, (k - 0.5) * 2))
        }
        return Color(hex: HexColor.lerp(theme.minimum, theme.maximum, k))
    }
}

public extension Color {
    /// Relative luminance (0 = black, 1 = white) for choosing legible label colours on fills.
    var luminance: Double {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(Double(ns.redComponent)) + 0.7152 * lin(Double(ns.greenComponent)) + 0.0722 * lin(Double(ns.blueComponent))
    }
    /// White or near-black, whichever reads better on top of this colour.
    var contrastingLabel: Color { luminance > 0.45 ? Color(hex: "#1D1D1F") : .white }
}
