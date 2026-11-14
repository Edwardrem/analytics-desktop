import Foundation

/// Measure-driven formatting ("fx") for one format property of a visual: the property takes its
/// value from a field evaluated under the visual's filters instead of the static value in
/// `format`. The evaluated values travel in `VisualData.formatOverrides` and are laid over the
/// spec when the visual is drawn (`applyingFormatOverrides`); the stored format is never rewritten.
public struct FormatBinding: Codable, Identifiable, Hashable, Sendable {
    /// What the property holds, which decides how the field's value is read.
    public enum Kind: String, Codable, Sendable { case text, color, number }

    public var id = UUID()
    /// The format-bag card and key it drives ("subtitle"/"text", "background"/"color",
    /// "columnWidths"/<column caption>), or one of the visual's own texts: `altTextCard`/"text"
    /// (the alt text) and `actionCard`/"tooltip" (the action's tooltip).
    public var card: String
    public var key: String
    public var kind: Kind
    /// `.fieldValue`: the field's value is the property's value (text as formatted, a colour as a
    /// hex code or colour name, a number as it is). `.rules`: the colour or number of the first
    /// rule the value meets. `.gradient` (colours only): a scale from `minColor` at `minValue` to
    /// `maxColor` at `maxValue`.
    public var mode: ConditionalFormat.Mode = .fieldValue
    /// The field whose value, summarized under the visual's filters, drives the property.
    public var field: FieldRef?
    /// Rules mode: each rule's output is its `color` (colour properties) or `number`.
    public var rules: [ConditionalFormat.Rule] = []
    public var minColor = "#E8F1FB"
    public var maxColor = "#0A84FF"
    public var minValue: Double = 0
    public var maxValue: Double = 100

    /// Pseudo-card for `VisualSpec.altText`.
    public static let altTextCard = "altText"
    /// Pseudo-card for `VisualSpec.action?.tooltip`.
    public static let actionCard = "action"

    public init(card: String, key: String, kind: Kind) {
        self.card = card; self.key = key; self.kind = kind
    }

    /// "card.key", the id the Format pane gives the property.
    public var property: String { card + "." + key }
}

public extension VisualSpec {
    /// The binding that drives `card`.`key`, if any.
    func formatBinding(_ card: String, _ key: String) -> FormatBinding? {
        formatBindings?.first { $0.card == card && $0.key == key }
    }

    /// Adds, replaces (same card and key) or, with nil, removes the binding of `card`.`key`.
    mutating func setFormatBinding(_ card: String, _ key: String, _ binding: FormatBinding?) {
        var list = (formatBindings ?? []).filter { !($0.card == card && $0.key == key) }
        if var b = binding { b.card = card; b.key = key; list.append(b) }
        formatBindings = list.isEmpty ? nil : list
    }

    /// The evaluated values of properties this visual still binds: a value computed before the
    /// binding was removed (an undo, a requery still running) never shows.
    func boundFormatOverrides(_ overrides: FormatBag) -> FormatBag {
        guard let bindings = formatBindings, !bindings.isEmpty, !overrides.isEmpty else { return [:] }
        var out: FormatBag = [:]
        for b in bindings { if let v = overrides[b.card]?[b.key] { out[b.card, default: [:]][b.key] = v } }
        return out
    }

    /// The visual as drawn: each evaluated binding value (card → key → value) in place of the
    /// stored one. Alt text and the action tooltip are written to the visual's own properties.
    func applyingFormatOverrides(_ overrides: FormatBag) -> VisualSpec {
        guard !overrides.isEmpty else { return self }
        var out = self
        for (card, keys) in overrides {
            for (key, value) in keys {
                switch (card, key) {
                case (FormatBinding.altTextCard, "text"):
                    if let s = value.stringValue { out.altText = s }
                case (FormatBinding.actionCard, "tooltip"):
                    if let s = value.stringValue { var a = out.action ?? ActionSpec(); a.tooltip = s; out.action = a }
                default:
                    out.setFmt(card, key, value)
                }
            }
        }
        return out
    }

    /// A spec a renderer edited (column widths, text) that started from
    /// `stored.applyingFormatOverrides(overrides)`, with every overridden property the renderer
    /// left alone put back to its stored value, so evaluated values never land in the document.
    /// A property the renderer changed (a column the reader resized) keeps the new value.
    func restoringFormatOverrides(_ overrides: FormatBag, from stored: VisualSpec) -> VisualSpec {
        guard !overrides.isEmpty else { return self }
        var out = self
        for (card, keys) in overrides {
            for (key, value) in keys {
                switch (card, key) {
                case (FormatBinding.altTextCard, "text"):
                    if out.altText == value.stringValue { out.altText = stored.altText }
                case (FormatBinding.actionCard, "tooltip"):
                    guard let shown = out.action, shown.tooltip == value.stringValue else { continue }
                    if let original = stored.action {
                        out.action?.tooltip = original.tooltip
                    } else {
                        var added = ActionSpec(); added.tooltip = shown.tooltip
                        if shown == added { out.action = nil } else { out.action?.tooltip = "" }
                    }
                default:
                    if out.fmt(card, key) == value { out.setFmt(card, key, stored.fmt(card, key)) }
                }
            }
        }
        return out
    }
}
