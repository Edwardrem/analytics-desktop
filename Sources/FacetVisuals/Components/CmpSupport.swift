import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// Shared, module-internal helpers for the component renderers (tables, cards, slicers, maps, page
// elements). Everything here is prefixed `Cmp` so it never collides with the chart author's helpers.

// MARK: - Environment

/// Everything a component renderer needs, bundled: spec, data, host context and resolved format.
struct CmpEnv {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let f: ResolvedFormat

    init(spec: VisualSpec, data: VisualData, context: VisualContext) {
        self.spec = spec; self.data = data; self.context = context
        self.f = ResolvedFormat(spec: spec, theme: context.theme)
    }

    var theme: ThemeSpec { context.theme }
    var fg: Color { theme.foregroundColor }
    var secondary: Color { theme.secondaryColor }
    var grid: Color { theme.gridlineColor }
    var accent: Color { theme.accentColor }
    var card: Color { theme.cardColor }
    /// Quiet fill for hover / zebra rows that works on both light and dark cards.
    var subtleFill: Color { theme.foregroundColor.opacity(theme.isDark ? 0.07 : 0.045) }
    /// Selection fill.
    var selectionFill: Color { theme.accentColor.opacity(theme.isHighContrast ? 0.45 : 0.16) }
    var isInteractive: Bool { context.isInteractive }

    /// Theme-family font at an explicit size.
    func font(_ size: Double, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let family = theme.label.fontFamily
        return family.isEmpty ? .system(size: size, weight: weight, design: design) : .custom(family, size: size).weight(weight)
    }
    func nsFont(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
        let family = theme.label.fontFamily
        if !family.isEmpty, let f = NSFont(name: family, size: size) { return f }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// Caption of a data column: the field caption when known, else the column name.
    func caption(_ col: Int) -> String {
        if let f = data.fields[safe: col] ?? nil { return f.caption }
        return data.table.columns[safe: col]?.name ?? ""
    }

    /// Mutate a copy of the spec and hand it to the host for persistence.
    func update(_ mutate: (inout VisualSpec) -> Void) {
        var s = spec
        mutate(&s)
        context.onSpecChange(s)
    }

    /// Third level of the format bag: `format[card][key][sub]`.
    func nested(_ card: String, _ key: String, _ sub: String) -> JSONValue? { f.value(card, key)?[sub] }
}

// MARK: - Colour

enum CmpColor {
    static func ns(_ hex: String) -> NSColor {
        guard let c = HexColor.rgb(hex) else { return .clear }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
    /// Relative luminance (0 dark … 1 light).
    static func luminance(_ hex: String) -> Double {
        guard let c = HexColor.rgb(hex) else { return 1 }
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    /// A legible text colour (hex) for content drawn on `hex`.
    static func readableText(on hex: String) -> String { luminance(hex) > 0.45 ? "#1D1D1F" : "#FFFFFF" }
    /// Two- or three-stop gradient; `t` in 0…1.
    static func gradient(_ t: Double, min: String, mid: String?, max: String) -> String {
        let k = Swift.max(0, Swift.min(1, t))
        guard let mid else { return HexColor.lerp(min, max, k) }
        return k < 0.5 ? HexColor.lerp(min, mid, k * 2) : HexColor.lerp(mid, max, (k - 0.5) * 2)
    }
}

// MARK: - Numbers

enum CmpNumber {
    /// Callout text with display units. `units`: "auto" | "none" | "thousands" | "millions" | "billions" | "trillions".
    /// `decimals` nil = automatic. Non-numeric values and percentages use the column format unchanged.
    static func callout(_ v: Value, format: String = "", units: String = "auto", decimals: Int? = nil) -> String {
        guard v.isNumber, let d = v.asDouble, d.isFinite else { return ValueFormatter.format(v, format) }
        if format.contains("%") || format.lowercased() == "percent" || ValueFormatterIsDate(format) {
            return ValueFormatter.format(v, format)
        }
        let symbol = currencySymbol(format)
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let x = d / divisor
            var s = String(format: "%.\(decimals ?? 2)f", abs(x))
            if decimals == nil, s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return (x < 0 ? "-" : "") + symbol + s + suffix
        }
        switch units {
        case "thousands": return scaled(1e3, "K")
        case "millions": return scaled(1e6, "M")
        case "billions": return scaled(1e9, "bn")
        case "trillions": return scaled(1e12, "T")
        case "none":
            if let decimals { return (d < 0 ? "-" : "") + symbol + grouped(abs(d), decimals) }
            return ValueFormatter.format(v, format)
        default:
            let a = abs(d)
            if a >= 1e12 { return scaled(1e12, "T") }
            if a >= 1e9 { return scaled(1e9, "bn") }
            if a >= 1e6 { return scaled(1e6, "M") }
            if a >= 1e4 { return scaled(1e3, "K") }
            if let decimals { return (d < 0 ? "-" : "") + symbol + grouped(a, decimals) }
            return ValueFormatter.format(v, format)
        }
    }
    static func currencySymbol(_ format: String) -> String {
        if format.lowercased() == "currency" { return "$" }
        for s in ["$", "€", "£", "¥", "R"] where format.hasPrefix(s) { return s }
        return ""
    }
    private static func grouped(_ d: Double, _ decimals: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal; nf.locale = Locale(identifier: "en_US")
        nf.minimumFractionDigits = decimals; nf.maximumFractionDigits = decimals
        return nf.string(from: NSNumber(value: d)) ?? String(d)
    }
    private static func ValueFormatterIsDate(_ fmt: String) -> Bool {
        let l = fmt.lowercased()
        if l.isEmpty || l.contains("0") || l.contains("#") { return false }
        return l.contains("yy") || l.contains("mm") || l.contains("dd") || l.contains("hh") || l.hasSuffix("date") || l.hasSuffix("time")
    }
    /// "+12.4%" style signed percentage for a ratio (0.124 → "+12.4%").
    static func signedPercent(_ ratio: Double, decimals: Int = 1) -> String {
        guard ratio.isFinite else { return "—" }
        return String(format: "%@%.\(decimals)f%%", ratio > 0 ? "+" : (ratio < 0 ? "−" : ""), abs(ratio * 100))
    }
}

// MARK: - Text fitting

enum CmpFit {
    /// Largest font size ≤ `maxSize` (and ≥ `minSize`) at which `text` fits on one line in `width` × `height`.
    static func fontSize(_ text: String, maxSize: CGFloat, minSize: CGFloat = 8, width: CGFloat, height: CGFloat,
                         weight: NSFont.Weight = .semibold) -> CGFloat {
        guard width > 0, height > 0, !text.isEmpty else { return minSize }
        let probe: CGFloat = 100
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: probe, weight: weight)])
        guard size.width > 0, size.height > 0 else { return minSize }
        let byWidth = probe * width / size.width
        let byHeight = probe * height / size.height
        return max(minSize, min(maxSize, floor(min(byWidth, byHeight) * 0.98)))
    }
    static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// One-line text that truncates and shows its full content as a tooltip on hover.
struct CmpTruncatingText: View {
    let text: String
    var body: some View { Text(text).lineLimit(1).truncationMode(.tail).help(text) }
}

// MARK: - Selection

enum CmpSelection {
    /// Columns that identify a data point: grouping fields (non-aggregates with a known field).
    static func groupingColumns(_ data: VisualData) -> [Int] {
        data.fields.indices.filter { i in
            guard let f = data.fields[i] else { return false }
            return !f.isAggregate
        }
    }
    /// Selection for one table row over the given columns (skips columns without a field).
    static func point(_ data: VisualData, row: Int, columns: [Int]) -> DataPointSelection? {
        var fields: [FieldRef] = [], values: [Value] = []
        for c in columns {
            guard let f = data.fields[safe: c] ?? nil, row < data.table.rowCount else { continue }
            fields.append(f); values.append(data.table[row, c])
        }
        return fields.isEmpty ? nil : DataPointSelection(fields: fields, values: values)
    }
}

enum CmpPasteboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Conditional formatting

/// Named SF Symbol icon sets for the `icons` conditional-format target, ordered low → high.
enum CmpIconSet {
    static let sets: [String: [(symbol: String, color: String)]] = [
        "arrows": [("arrow.down", "#FF453A"), ("arrow.right", "#FF9F0A"), ("arrow.up", "#34C759")],
        "triangles": [("arrowtriangle.down.fill", "#FF453A"), ("minus", "#FF9F0A"), ("arrowtriangle.up.fill", "#34C759")],
        "trafficLights": [("circle.fill", "#FF453A"), ("circle.fill", "#FF9F0A"), ("circle.fill", "#34C759")],
        "flags": [("flag.fill", "#FF453A"), ("flag.fill", "#FF9F0A"), ("flag.fill", "#34C759")],
        "stars": [("star", "#FF9F0A"), ("star.leadinghalf.filled", "#FF9F0A"), ("star.fill", "#FF9F0A")],
        "checks": [("xmark.circle.fill", "#FF453A"), ("exclamationmark.circle.fill", "#FF9F0A"), ("checkmark.circle.fill", "#34C759")],
        "signal": [("cellularbars", "#FF453A"), ("cellularbars", "#FF9F0A"), ("cellularbars", "#34C759")],
    ]
    /// Resolves a rule icon: an SF Symbol name, or "set:index" (e.g. "arrows:2").
    static func resolve(_ icon: String, fallbackColor: String) -> (symbol: String, color: String) {
        let parts = icon.split(separator: ":")
        if parts.count == 2, let set = sets[String(parts[0])], let i = Int(parts[1]), let e = set[safe: i] { return e }
        return (icon, fallbackColor)
    }
}

struct CmpDataBar {
    /// Bar start and end as fractions (0…1) of the cell width; the axis sits at `axis`.
    var start: Double, end: Double, axis: Double
    var colorHex: String
    var isNegative: Bool
}

/// Evaluates `VisualSpec.conditionalFormats` against values. Value-based so both the table (per row)
/// and the matrix (pivoted cells) can use it.
struct CmpConditionalFormat {
    let formats: [ConditionalFormat]
    let iconSetName: String

    init(spec: VisualSpec, iconSet: String = "arrows") {
        self.formats = spec.conditionalFormats; self.iconSetName = iconSet
    }

    /// The rule for `target` that applies to `field` (rules with `appliesToKey == nil` apply to every
    /// aggregate field for colour/bar/icon targets).
    func rule(_ target: ConditionalFormat.Target, field: FieldRef?) -> ConditionalFormat? {
        if let key = field?.key, let exact = formats.first(where: { $0.target == target && $0.appliesToKey == key }) { return exact }
        guard field?.isAggregate ?? true else { return nil }
        return formats.first { $0.target == target && $0.appliesToKey == nil }
    }

    /// Column whose values drive the rule for a formatted column: `basedOn` when present in the data, else itself.
    func driverColumn(_ cf: ConditionalFormat, column: Int, data: VisualData) -> Int {
        guard let b = cf.basedOn else { return column }
        return data.fields.firstIndex { $0?.key == b.key } ?? column
    }

    /// Numeric range of a column (ignores nulls); nil when the column has no numbers.
    static func range(_ values: [Value]) -> (min: Double, max: Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for v in values { if let d = v.asDouble, v.isNumber, d.isFinite { lo = Swift.min(lo, d); hi = Swift.max(hi, d) } }
        return lo <= hi ? (lo, hi) : nil
    }

    private func matches(_ rule: ConditionalFormat.Rule, _ v: Double, _ range: (min: Double, max: Double)) -> Bool {
        let x: Double = rule.isPercent ? (range.max > range.min ? (v - range.min) / (range.max - range.min) * 100 : 0) : v
        func test(_ op: FilterOperator, _ rhs: Double) -> Bool {
            switch op {
            case .equals: return x == rhs
            case .notEquals: return x != rhs
            case .greaterThan: return x > rhs
            case .greaterOrEqual: return x >= rhs
            case .lessThan: return x < rhs
            case .lessOrEqual: return x <= rhs
            default: return true
            }
        }
        guard test(rule.op, rule.value) else { return false }
        if let up = rule.upperOp, let uv = rule.upperValue { return test(up, uv) }
        return true
    }

    /// Colour (hex) for background / font colour / data-point targets, or nil when the rule yields none.
    func colorHex(_ cf: ConditionalFormat, value: Value, range: (min: Double, max: Double)?) -> String? {
        switch cf.mode {
        case .fieldValue:
            let s = value.asString
            return HexColor.rgb(s) != nil ? s : nil
        case .rules:
            guard let d = value.asDouble, let range else { return nil }
            return cf.rules.first { matches($0, d, range) }?.color
        case .gradient:
            guard value.isNumber, let d = value.asDouble, let range else { return nil }
            let lo = cf.minValue ?? range.min, hi = cf.maxValue ?? range.max
            guard hi > lo else { return cf.maxColor }
            if let midColor = cf.midColor {
                let mid = cf.midValue ?? (lo + hi) / 2
                if d <= mid { return HexColor.lerp(cf.minColor, midColor, mid > lo ? (d - lo) / (mid - lo) : 1) }
                return HexColor.lerp(midColor, cf.maxColor, hi > mid ? (d - mid) / (hi - mid) : 1)
            }
            return HexColor.lerp(cf.minColor, cf.maxColor, (d - lo) / (hi - lo))
        }
    }

    /// Data bar geometry. Positive bars grow right from the axis in `maxColor`, negative bars left in `negativeColor`.
    func dataBar(_ cf: ConditionalFormat, value: Value, range: (min: Double, max: Double)?) -> CmpDataBar? {
        guard value.isNumber, let d = value.asDouble, let range else { return nil }
        let lo = Swift.min(cf.minValue ?? range.min, 0), hi = Swift.max(cf.maxValue ?? range.max, 0)
        guard hi > lo else { return nil }
        let axis = (0 - lo) / (hi - lo)
        let pos = (Swift.max(lo, Swift.min(hi, d)) - lo) / (hi - lo)
        return CmpDataBar(start: Swift.min(axis, pos), end: Swift.max(axis, pos), axis: axis,
                          colorHex: d < 0 ? cf.negativeColor : cf.maxColor, isNegative: d < 0)
    }

    /// Icon for the `icons` target: first matching rule's icon, or — without rules — terciles of the active icon set.
    func icon(_ cf: ConditionalFormat, value: Value, range: (min: Double, max: Double)?) -> (symbol: String, color: String)? {
        if cf.mode == .fieldValue {
            let s = value.asString
            return s.isEmpty ? nil : CmpIconSet.resolve(s, fallbackColor: "#8E8E93")
        }
        guard value.isNumber, let d = value.asDouble, let range else { return nil }
        if !cf.rules.isEmpty {
            guard let r = cf.rules.first(where: { matches($0, d, range) }), let icon = r.icon else { return nil }
            return CmpIconSet.resolve(icon, fallbackColor: r.color)
        }
        let set = CmpIconSet.sets[iconSetName] ?? CmpIconSet.sets["arrows"] ?? []
        guard set.count == 3 else { return nil }
        let t = range.max > range.min ? (d - range.min) / (range.max - range.min) : 1
        return set[t < 1.0 / 3 ? 0 : (t < 2.0 / 3 ? 1 : 2)]
    }
}

// MARK: - Format catalog model

/// One formatting property a component honours, so the Format pane can be generated.
public struct CmpFormatProperty: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bool, number, string, color
        case enumeration(options: [String])
    }
    /// `format[card][key]`.
    public var card: String
    public var key: String
    /// Human-readable property label, e.g. "Row padding".
    public var label: String
    /// Human-readable card (section) label, e.g. "Grid".
    public var cardLabel: String
    public var kind: Kind
    /// Renderer default when the key is absent (`.null` = follows the theme).
    public var defaultValue: JSONValue
    public var id: String { card + "." + key }

    public init(card: String, key: String, label: String, cardLabel: String, kind: Kind, defaultValue: JSONValue) {
        self.card = card; self.key = key; self.label = label; self.cardLabel = cardLabel
        self.kind = kind; self.defaultValue = defaultValue
    }
}

/// Terse builder for catalog entries of one card.
struct CmpCard {
    let card: String, label: String
    init(_ card: String, _ label: String) { self.card = card; self.label = label }
    func bool(_ key: String, _ l: String, _ d: Bool) -> CmpFormatProperty {
        .init(card: card, key: key, label: l, cardLabel: label, kind: .bool, defaultValue: .bool(d))
    }
    func number(_ key: String, _ l: String, _ d: Double?) -> CmpFormatProperty {
        .init(card: card, key: key, label: l, cardLabel: label, kind: .number, defaultValue: d.map(JSONValue.number) ?? .null)
    }
    func string(_ key: String, _ l: String, _ d: String = "") -> CmpFormatProperty {
        .init(card: card, key: key, label: l, cardLabel: label, kind: .string, defaultValue: .string(d))
    }
    func color(_ key: String, _ l: String, _ d: String? = nil) -> CmpFormatProperty {
        .init(card: card, key: key, label: l, cardLabel: label, kind: .color, defaultValue: d.map(JSONValue.string) ?? .null)
    }
    func options(_ key: String, _ l: String, _ o: [String], _ d: String) -> CmpFormatProperty {
        .init(card: card, key: key, label: l, cardLabel: label, kind: .enumeration(options: o), defaultValue: .string(d))
    }
}

// MARK: - Placeholder

/// Calm, size-adaptive placeholder (icon, title, message) that stays tidy down to 120×60.
struct CmpPlaceholder: View {
    let systemImage: String
    let title: String
    var message: String = ""
    var theme: ThemeSpec = .facet
    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 110 || geo.size.width < 170
            let tiny = geo.size.height < 56
            Group {
                if compact {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage).font(.system(size: 13, weight: .light))
                        if !tiny || geo.size.width > 90 { Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1) }
                    }
                    .foregroundStyle(theme.secondaryColor)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: systemImage).font(.system(size: 26, weight: .light))
                            .foregroundStyle(theme.secondaryColor.opacity(0.7))
                        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.secondaryColor)
                        if !message.isEmpty, geo.size.height > 150 {
                            Text(message).font(.system(size: 11)).foregroundStyle(theme.secondaryColor.opacity(0.75))
                                .multilineTextAlignment(.center).frame(maxWidth: 300)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .help(message.isEmpty ? title : message)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.isEmpty ? title : "\(title). \(message)")
    }
}

// MARK: - Gallery sample builder

/// Column descriptor for building gallery sample data.
struct CmpCol {
    var name: String
    var well: Well
    var isMeasure: Bool
    var format: String
    init(_ name: String, _ well: Well, measure: Bool = false, format: String = "") {
        self.name = name; self.well = well; self.isMeasure = measure; self.format = format
    }
}

enum CmpSample {
    /// Builds a spec + matching `VisualData`: creates a `FieldRef` per column, fills the wells and roles,
    /// and (optionally) sums measure columns into `totals`.
    static func make(_ type: VisualType, name: String, size: (w: Double, h: Double), columns: [CmpCol] = [],
                     rows: [[Value]] = [], totals: Bool = false,
                     configure: (inout VisualSpec) -> Void = { _ in }) -> (spec: VisualSpec, data: VisualData) {
        var spec = VisualSpec(type: type, frame: Frame(x: 0, y: 0, width: size.w, height: size.h), name: name)
        var roles: [String: [Int]] = [:]
        var fields: [FieldRef?] = []
        for (i, c) in columns.enumerated() {
            let f = c.isMeasure ? FieldRef.measure("Sales", c.name) : FieldRef.column("Sales", c.name)
            fields.append(f)
            roles[c.well.rawValue, default: []].append(i)
            spec.wells[c.well.rawValue, default: []].append(f)
        }
        let table = DataTable(name: name, columnNames: columns.map(\.name), rows: rows)
        var tot: [Value] = []
        if totals {
            tot = columns.indices.map { i in
                guard columns[i].isMeasure else { return .null }
                let nums = table.columns[i].values.compactMap { $0.isNumber ? $0.asDouble : nil }
                return nums.isEmpty ? .null : .double(nums.reduce(0, +))
            }
        }
        configure(&spec)
        let data = VisualData(table: table, roles: roles, fields: fields, formats: columns.map(\.format), totals: tot)
        return (spec, data)
    }
}
