import Foundation
import FacetCore

/// One formatting property a visual honours, for generating the Format pane. Chart families
/// declare these beside their renderers (`formatProperties(for:)`); component entries
/// (`CmpFormatProperty`) convert into the same type, so the pane works with one model.
public struct FormatProperty: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bool, number, string, color
        case options([String])
        /// The caption of one of the visual's own fields (empty = none).
        case field
    }

    /// What a bool with no fixed default (`defaultValue == .null`) follows.
    public enum AutomaticBool: Hashable, Sendable {
        /// On when the visual draws more than one series (the legend).
        case multipleSeries
        /// On in high-contrast themes (accessibility patterns).
        case highContrast
    }

    /// The theme colour a colour property falls back to while it has no override.
    public enum ThemeColor: String, Hashable, Sendable {
        case foreground, secondaryForeground, cardBackground, gridline, accent
        case good, bad, neutral, minimum, center, maximum, firstDataColor

        public func hex(in theme: ThemeSpec) -> String {
            switch self {
            case .foreground: return theme.foreground
            case .secondaryForeground: return theme.secondaryForeground
            case .cardBackground: return theme.cardBackground
            case .gridline: return theme.gridline
            case .accent: return theme.accent
            case .good: return theme.good
            case .bad: return theme.bad
            case .neutral: return theme.neutral
            case .minimum: return theme.minimum
            case .center: return theme.center
            case .maximum: return theme.maximum
            case .firstDataColor: return theme.dataColors.first ?? theme.accent
            }
        }
    }

    /// Card in the format bag, e.g. "legend".
    public var card: String
    /// Human-readable card (section) name, e.g. "Legend".
    public var cardLabel: String
    /// Key within the card, e.g. "position".
    public var key: String
    /// Human-readable label for the Format pane.
    public var label: String
    public var kind: Kind
    /// Value the renderer uses when the key is absent (`.null` = automatic: derived from the
    /// theme or the data; see `automatic` and `themeColor`).
    public var defaultValue: JSONValue
    /// Accepted values of a number property; nil falls back to `FormatNumber.defaultBounds`.
    public var range: ClosedRange<Double>?
    public var automatic: AutomaticBool?
    public var themeColor: ThemeColor?

    public var id: String { card + "." + key }

    public init(card: String, cardLabel: String, key: String, label: String, kind: Kind,
                defaultValue: JSONValue = .null, range: ClosedRange<Double>? = nil,
                automatic: AutomaticBool? = nil, themeColor: ThemeColor? = nil) {
        self.card = card; self.cardLabel = cardLabel; self.key = key; self.label = label
        self.kind = kind; self.defaultValue = defaultValue
        self.range = range; self.automatic = automatic; self.themeColor = themeColor
    }

    /// A component catalog entry as a pane property.
    public init(_ p: CmpFormatProperty) {
        let kind: Kind
        switch p.kind {
        case .bool: kind = .bool
        case .number: kind = .number
        case .string: kind = .string
        case .color: kind = .color
        case .enumeration(let options): kind = .options(options)
        }
        self.init(card: p.card, cardLabel: p.cardLabel, key: p.key, label: p.label, kind: kind, defaultValue: p.defaultValue)
    }

    /// The values a number property accepts: its declared range, or a bound derived from the key.
    public var bounds: ClosedRange<Double> { range ?? FormatNumber.defaultBounds(key: key) }

    /// The value in effect, resolved the way the renderers resolve it: the visual's override,
    /// then the theme's defaults for the type, then the theme's "*" defaults, then the declared
    /// default. nil = automatic.
    public func value(in format: ResolvedFormat) -> JSONValue? {
        format.value(card, key) ?? (defaultValue == .null ? nil : defaultValue)
    }

    /// The on/off state a bool property renders with, including automatic defaults.
    public func isOn(in format: ResolvedFormat) -> Bool {
        if let b = value(in: format)?.boolValue { return b }
        switch automatic {
        case .highContrast: return format.theme.isHighContrast
        case .multipleSeries: return ChartFormatCatalog.drawsMultipleSeries(format.spec)
        case nil: return false
        }
    }

    /// The colour a colour property renders with while it has no override, when known.
    public func defaultColorHex(in theme: ThemeSpec) -> String? {
        themeColor?.hex(in: theme) ?? defaultValue.stringValue
    }
}

/// Safe conversions for numbers read from a format bag. A document or theme file can carry any
/// number, so renderers never convert one to `Int` without clamping it first.
public enum FormatNumber {
    /// `value` clamped to `range`; nil when it is absent or not finite.
    public static func clamped(_ value: Double?, to range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// `value` truncated to an integer inside `range`; nil when it is absent or not finite.
    public static func int(_ value: Double?, in range: ClosedRange<Int>) -> Int? {
        guard let d = clamped(value, to: Double(range.lowerBound)...Double(range.upperBound)) else { return nil }
        return Swift.min(Swift.max(Int(d.rounded(.towardZero)), range.lowerBound), range.upperBound)
    }

    /// Bounds for number properties that declare none, from what the key measures.
    public static func defaultBounds(key: String) -> ClosedRange<Double> {
        let k = key.lowercased()
        if k.contains("decimals") { return 0...10 }
        if k.contains("transparency") || k.contains("opacity") { return 0...100 }
        if k == "columns" || k == "rows" || k.contains("lines") { return 0...100 }
        if k == "min" || k == "max" || k == "target" { return -1e15...1e15 }
        if k.contains("size") { return 1...400 }
        if k == "zoom" || k == "intensity" || k == "thickness" { return 0...100 }
        for part in ["radius", "padding", "width", "height", "spacing", "gap", "indent"] where k.contains(part) {
            return 0...4_000
        }
        return -1e9...1e9
    }
}

extension ResolvedFormat {
    /// Integer format value, clamped to `range`; `fallback` when absent or not finite.
    public func int(_ card: String, _ key: String, _ fallback: Int, in range: ClosedRange<Int>) -> Int {
        FormatNumber.int(value(card, key)?.doubleValue, in: range) ?? fallback
    }

    /// Fixed decimal places (0…10) for a label card, or nil when the key is absent.
    public func decimals(_ card: String) -> Int? {
        FormatNumber.int(value(card, "decimals")?.doubleValue, in: 0...10)
    }
}

/// Machine-readable list of the format properties each chart honours (drives the Format pane).
public enum ChartFormatCatalog {
    /// Every `format[card][key]` the renderer of `type` reads, in the order the pane shows them.
    /// Empty for types the chart renderers do not draw.
    public static func properties(for type: VisualType) -> [FormatProperty] {
        guard ChartVisuals.supportedTypes.contains(type) else { return [] }
        if let kind = CartesianKind(type) { return CartesianOptions.formatProperties(for: kind) }
        return CoreCharts.formatProperties(for: type) + FlowCharts.formatProperties(for: type)
            + StatCharts.formatProperties(for: type)
    }

    /// Whether `spec` draws more than one series, which is when `ChartScaffold` shows the legend
    /// by default: a legend field, or more than one value field.
    public static func drawsMultipleSeries(_ spec: VisualSpec) -> Bool {
        if !spec.fields(.legend).isEmpty { return true }
        let values = [Well.values, .lineValues].flatMap { spec.fields($0) }.filter { !$0.isHidden }
        return values.count > 1
    }
}

/// Format properties of any visual type, chart or component, as one model.
public enum VisualFormatCatalog {
    public static func properties(for type: VisualType) -> [FormatProperty] {
        let component = ComponentFormatCatalog.properties(for: type)
        return component.isEmpty ? ChartFormatCatalog.properties(for: type) : component.map(FormatProperty.init)
    }
}

/// Terse builder for the catalog entries of one card.
struct FormatCard {
    let card: String, label: String
    init(_ card: String, _ label: String) { self.card = card; self.label = label }

    func bool(_ key: String, _ l: String, _ d: Bool) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .bool, defaultValue: .bool(d))
    }
    /// A bool whose default follows the data or the theme.
    func automatic(_ key: String, _ l: String, _ a: FormatProperty.AutomaticBool) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .bool, automatic: a)
    }
    func number(_ key: String, _ l: String, _ d: Double?, _ range: ClosedRange<Double>) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .number,
                       defaultValue: d.map(JSONValue.number) ?? .null, range: range)
    }
    func string(_ key: String, _ l: String, _ d: String? = nil) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .string,
                       defaultValue: d.map(JSONValue.string) ?? .null)
    }
    func color(_ key: String, _ l: String, _ theme: FormatProperty.ThemeColor) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .color, themeColor: theme)
    }
    /// One of the visual's fields, chosen by caption.
    func field(_ key: String, _ l: String) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .field)
    }
    /// `d == nil` means the renderer decides (the pane offers "Automatic").
    func options(_ key: String, _ l: String, _ o: [String], _ d: String?) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .options(o),
                       defaultValue: d.map(JSONValue.string) ?? .null)
    }
}

/// Cards several chart families share. Each lists what the shared code path reads:
/// `ChartScaffold` (legend), `ChartStyle` (label sizes, patterns), `StatPlot` (axes, plot area).
enum SharedFormatCards {
    static let displayUnits = DisplayUnits.allCases.map(\.rawValue)
    /// Font sizes in points.
    static let fontSizes: ClosedRange<Double> = 6...72

    /// `ChartScaffold`: `showDefault` nil = shown when there is more than one legend item.
    static func legend(showDefault: Bool? = nil) -> [FormatProperty] {
        let c = FormatCard("legend", "Legend")
        return [showDefault.map { c.bool("show", "Show legend", $0) } ?? c.automatic("show", "Show legend", .multipleSeries),
                c.options("position", "Position", LegendPosition.allCases.map(\.rawValue), "top"),
                c.string("title", "Title", ""),
                c.number("size", "Font size", nil, fontSizes)]
    }

    /// Data labels. `position` and `detail` (a field shown instead of the value) are honoured by
    /// the cartesian charts only; `values` adds the display units and decimals of the value text.
    static func dataLabels(show: Bool, position: Bool = false, values: Bool = true, toggle: Bool = true,
                           detail: Bool = false) -> [FormatProperty] {
        let c = FormatCard("dataLabels", "Data labels")
        var out: [FormatProperty] = []
        if toggle { out.append(c.bool("show", "Show data labels", show)) }
        if position { out.append(c.options("position", "Position", DataLabelPosition.allCases.map(\.rawValue), "auto")) }
        if values {
            out += [c.options("displayUnits", "Display units", displayUnits, "auto"),
                    c.number("decimals", "Decimal places", nil, 0...10)]
        }
        if detail { out.append(c.field("detailField", "Show field instead")) }
        out.append(c.number("size", "Font size", nil, fontSizes))
        if toggle { out.append(c.color("color", "Text colour", .foreground)) }
        return out
    }

    /// `ChartStyle.usesPatterns`.
    static func accessibility() -> [FormatProperty] {
        [FormatCard("accessibility", "Accessibility").automatic("patterns", "Distinguish series with patterns", .highContrast)]
    }

    /// The `xAxis` / `yAxis` cards `StatPlot` reads through `StatAxisOptions`.
    static func statAxes() -> [FormatProperty] {
        let x = FormatCard("xAxis", "X axis"), y = FormatCard("yAxis", "Y axis")
        return [x.bool("show", "Show axis", true),
                x.bool("showTitle", "Show title", false),
                x.string("title", "Title", ""),
                x.bool("gridlines", "Gridlines", false),
                x.number("size", "Font size", nil, fontSizes),
                y.bool("show", "Show axis", true),
                y.bool("showTitle", "Show title", false),
                y.string("title", "Title", ""),
                y.number("min", "Minimum", nil, -1e15...1e15),
                y.number("max", "Maximum", nil, -1e15...1e15),
                y.options("displayUnits", "Display units", displayUnits, "auto"),
                y.number("decimals", "Decimal places", nil, 0...10),
                y.bool("gridlines", "Gridlines", true),
                y.number("size", "Font size", nil, fontSizes)]
    }

    /// Plot background. `transparency` is read by the cartesian charts only.
    static func plotArea(transparency: Bool = false) -> [FormatProperty] {
        let c = FormatCard("plotArea", "Plot area")
        var out = [c.color("background", "Background colour", .cardBackground)]
        if transparency { out.append(c.number("transparency", "Transparency %", 0, 0...100)) }
        return out
    }
}
