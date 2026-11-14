import Foundation
import FacetCore
import FacetVisuals

/// One collapsible Format pane card: the properties of one format-bag card, or one of the two
/// General-tab cards that edit the visual itself rather than its format bag.
struct FormatCardModel: Identifiable, Hashable {
    enum Role: Hashable {
        /// Rows write `format[card][key]`.
        case format
        /// Position, size and rotation: rows write the visual's frame.
        case position
        /// The visual's alt text.
        case altText
        /// The report page shown as this visual's tooltip.
        case tooltip
        /// The style presets the visual type offers.
        case presets
        /// Conditional formatting (fx): one row per target the visual type supports.
        case conditional
    }

    /// The format-bag card, e.g. "columnHeaders" ("position" / "altText" for the other roles).
    let card: String
    let label: String
    /// The rows shown (narrowed by a search).
    let properties: [FormatProperty]
    /// Every key of the whole card, so reset clears the card even while a search hides rows.
    let resetKeys: [String]
    let role: Role
    var id: String { card }

    init(card: String, label: String, properties: [FormatProperty], resetKeys: [String]? = nil, role: Role = .format) {
        self.card = card; self.label = label; self.properties = properties
        self.resetKeys = resetKeys ?? properties.map(\.key); self.role = role
    }

    /// The same card showing only `rows`; reset still covers the whole card.
    func narrowed(to rows: [FormatProperty]) -> FormatCardModel {
        FormatCardModel(card: card, label: label, properties: rows, resetKeys: resetKeys, role: role)
    }
}

/// What a row shows for a selection: one value, or "mixed" when the selected visuals differ.
enum FormatValue<T: Equatable>: Equatable {
    case same(T)
    case mixed

    init?(_ values: [T]) {
        guard let first = values.first else { return nil }
        self = values.allSatisfy { $0 == first } ? .same(first) : .mixed
    }
    var isMixed: Bool { self == .mixed }
    var value: T? { if case .same(let v) = self { return v }; return nil }
}

/// The outcome of committing a number field.
enum FormatNumberInput: Equatable {
    /// The field was emptied: back to the default.
    case clear
    /// A number, already clamped to the property's bounds.
    case value(Double)
    case invalid(String)
}

/// Builds the Format pane's cards from the FacetVisuals format catalogs, and the view-free logic
/// behind search, reset, multi-selection and input validation. All writes stay in the pane.
enum FormatCatalog {
    enum Tab: Hashable { case visual, general }

    // MARK: - Cards

    /// Visual tab: every type-specific card the renderer of `type` honours, from
    /// `ComponentFormatCatalog` (components) or `ChartFormatCatalog` (charts).
    static func visualCards(for type: VisualType) -> [FormatCardModel] {
        group(VisualFormatCatalog.properties(for: type))
    }

    /// General tab: Properties (position and size), the container chrome every visual shares
    /// (`VisualView` draws it) and Alt text. Defaults repeat `VisualView`'s fallbacks.
    static func generalCards(for type: VisualType) -> [FormatCardModel] {
        let element = type.isPageElement
        let title = FormatCardBuilder("title", "Title"), subtitle = FormatCardBuilder("subtitle", "Subtitle")
        let divider = FormatCardBuilder("divider", "Divider"), background = FormatCardBuilder("background", "Background")
        let border = FormatCardBuilder("border", "Border")
        var titleRows = [title.bool("show", "Show title", !element),
                         title.string("text", "Text"),
                         title.options("alignment", "Alignment", ["left", "center", "right"], "left"),
                         title.number("size", "Font size", nil, 6...96),
                         title.bool("bold", "Bold", true),
                         title.color("color", "Text colour", .foreground)]
        if element { titleRows.removeAll { $0.key == "bold" || $0.key == "alignment" } }
        // Page elements show no data, so they have no tooltip to replace and no visual header.
        let closing = element ? [altTextCard] : [tooltipCard, altTextCard]
        let header = FormatCardBuilder(VisualHeaderOptions.card, "Header icons")
        let headerRows = element ? [] : [header.bool("show", "Show visual header", true),
                                         header.string("helpText", "Help text", "")]
        return [positionCard] + group(
            titleRows + [
                subtitle.bool("show", "Show subtitle", false),
                subtitle.string("text", "Text", ""),
                subtitle.number("size", "Font size", nil, 6...96),
                subtitle.color("color", "Text colour", .secondaryForeground),
                divider.bool("show", "Show divider", false),
                divider.color("color", "Line colour", .gridline),
                background.bool("show", "Show background", !element),
                background.color("color", "Colour", .cardBackground),
                background.number("transparency", "Transparency %", 0, 0...100),
                border.bool("show", "Show border", false),
                border.color("color", "Colour", .gridline),
                border.number("width", "Width", 1, 0...20),
                border.number("radius", "Corner radius", nil, 0...200),
                FormatCardBuilder("shadow", "Shadow").bool("show", "Show shadow", false),
                FormatCardBuilder("padding", "Padding").number("all", "All sides", nil, 0...200),
            ] + headerRows) + closing
    }

    /// Position, size and rotation. Not format keys: the pane writes them to the frame.
    static let positionCard: FormatCardModel = {
        let c = FormatCardBuilder("position", "Properties")
        return FormatCardModel(card: "position", label: "Properties", properties: [
            c.number("x", "X", nil, 0...4_000), c.number("y", "Y", nil, 0...4_000),
            c.number("width", "Width", nil, 20...4_000), c.number("height", "Height", nil, 20...4_000),
            c.number("rotation", "Rotation", 0, -360...360),
        ], role: .position)
    }()

    static let altTextCard = FormatCardModel(card: "altText", label: "Alt text", properties: [
        FormatCardBuilder("altText", "Alt text").string("text", "Alt text description", ""),
    ], role: .altText)

    static let tooltipCard = FormatCardModel(card: "tooltip", label: "Tooltip", properties: [
        FormatCardBuilder("tooltip", "Tooltip").string("page", "Tooltip page"),
    ], role: .tooltip)

    /// Cards whose keys are the visual's own fields rather than fixed properties (table and
    /// matrix): a fixed width per column, image columns, and the subtotal aggregate per value.
    /// Keys are field captions, which is what the table renderers look up. Sparklines are set up
    /// from the Build pane (they need an axis field as well as a type).
    static func perFieldCards(for spec: VisualSpec) -> [FormatCardModel] {
        func captions(_ fields: [FieldRef]) -> [String] {
            var seen: Set<String> = []
            return fields.filter { !$0.isHidden }.map(\.caption).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return ComponentStylePresets.perFieldCards(for: spec.type).compactMap { entry in
            let c = FormatCardBuilder(entry.card, entry.label)
            let rows: [FormatProperty]
            switch entry.card {
            case "columnWidths":
                let fields = spec.type == .matrix ? spec.fields(.rows) + spec.fields(.values) : spec.allFields
                rows = captions(fields).map { c.number($0, $0, nil, 28...2_000) }
            case "imageColumns":
                rows = captions(spec.allFields.filter { !$0.isAggregate }).map { c.bool($0, $0, false) }
            case "totals":
                guard case .enumeration(let options) = entry.kind else { return nil }
                rows = captions(spec.fields(.values)).map { c.options($0, $0, options, "sum") }
            default:
                return nil
            }
            return rows.isEmpty ? nil : FormatCardModel(card: entry.card, label: entry.label, properties: rows)
        }
    }

    /// Cards for the selected visuals: the cards of their types, plus, for a single table or
    /// matrix, the per-field cards built from its fields.
    static func cards(for specs: [VisualSpec], tab: Tab) -> [FormatCardModel] {
        var list = cards(for: specs.map(\.type), tab: tab)
        guard tab == .visual, specs.count == 1, let spec = specs.first else { return list }
        let at = list.firstIndex { $0.role == .conditional } ?? list.endIndex
        list.insert(contentsOf: perFieldCards(for: spec), at: at)
        return list
    }

    /// Field captions every one of `specs` has, in the first visual's order (for field pickers).
    static func fieldCaptions(in specs: [VisualSpec]) -> [String] {
        guard let first = specs.first else { return [] }
        let others = specs.dropFirst().map { Set($0.allFields.map(\.caption)) }
        var seen: Set<String> = []
        return first.allFields.map(\.caption).filter { c in !c.isEmpty && seen.insert(c).inserted && others.allSatisfy { $0.contains(c) } }
    }

    static func cards(for type: VisualType, tab: Tab) -> [FormatCardModel] {
        tab == .visual ? visualCards(for: type) : generalCards(for: type)
    }

    /// Style presets, for types that offer any (cards, slicers, tables, matrices, buttons…).
    static func presetsCard(for type: VisualType) -> FormatCardModel? {
        guard !ComponentStylePresets.presets(for: type).isEmpty else { return nil }
        return FormatCardModel(card: "stylePresets", label: "Style presets", properties: [
            FormatCardBuilder("stylePresets", "Style presets").string("preset", "Style preset"),
        ], role: .presets)
    }

    /// Conditional formatting entry points: one row per target `type` supports. The dynamic title
    /// has its fx button on the Title card instead.
    static func conditionalTargets(for type: VisualType) -> [ConditionalFormat.Target] {
        BuildLogic.conditionalTargets(for: type).filter { $0 != .title }
    }

    static func conditionalCard(for type: VisualType) -> FormatCardModel? {
        let targets = conditionalTargets(for: type)
        guard !targets.isEmpty else { return nil }
        let c = FormatCardBuilder("conditionalFormatting", "Conditional formatting")
        return FormatCardModel(card: "conditionalFormatting", label: "Conditional formatting",
                               properties: targets.map { c.string($0.rawValue, BuildLogic.title($0)) }, role: .conditional)
    }

    /// The conditional-formatting target a format row offers through an fx button, if any.
    static func fxTarget(of property: FormatProperty, type: VisualType) -> ConditionalFormat.Target? {
        property.id == "title.text" && BuildLogic.conditionalTargets(for: type).contains(.title) ? .title : nil
    }

    /// Cards for a selection. One visual gets all of its cards: on the Visual tab its style
    /// presets, format cards and conditional formatting; on the General tab Properties, the
    /// container chrome and Alt text. Several visuals get the format cards and properties every
    /// one of them has (same id and control), plus style presets when they are all of one type.
    static func cards(for types: [VisualType], tab: Tab) -> [FormatCardModel] {
        guard let first = types.first else { return [] }
        let base = cards(for: first, tab: tab)
        let sameType = Set(types).count == 1
        let presets = tab == .visual && sameType ? [presetsCard(for: first)].compactMap { $0 } : []
        guard types.count > 1 else {
            return presets + base + (tab == .visual ? [conditionalCard(for: first)].compactMap { $0 } : [])
        }
        let others = Set(types.dropFirst()).map { type in
            Dictionary(cards(for: type, tab: tab).flatMap(\.properties).map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        }
        return presets + base.filter { $0.role == .format }.compactMap { card in
            let shared = card.properties.filter { p in others.allSatisfy { $0[p.id] == p.kind } }
            return shared.isEmpty ? nil : FormatCardModel(card: card.card, label: card.label, properties: shared)
        }
    }

    /// One element of a visual that on-object formatting lists: a format card, the tab it lives
    /// on, and its show / hide switch when it has one.
    struct Element: Identifiable, Hashable {
        let card: FormatCardModel
        let tab: Tab
        let toggle: FormatProperty?
        var id: String { card.id }
    }

    /// The elements of a visual of `type`, type-specific ones first.
    static func elements(for type: VisualType) -> [Element] {
        func list(_ tab: Tab) -> [Element] {
            cards(for: type, tab: tab).filter { $0.role == .format }.map { card in
                Element(card: card, tab: tab, toggle: card.properties.first { $0.key == "show" && $0.kind == .bool })
            }
        }
        return list(.visual) + list(.general)
    }

    private static func group(_ properties: [FormatProperty]) -> [FormatCardModel] {
        var order: [String] = []
        var byCard: [String: [FormatProperty]] = [:]
        for p in properties {
            if byCard[p.card] == nil { order.append(p.card) }
            byCard[p.card, default: []].append(p)
        }
        return order.compactMap { card in
            guard let rows = byCard[card], let first = rows.first else { return nil }
            return FormatCardModel(card: card, label: first.cardLabel, properties: rows)
        }
    }

    // MARK: - Search

    /// Cards narrowed to what matches `query`: a card whose name matches is kept whole, otherwise
    /// only its matching rows. An empty query returns everything.
    static func filter(_ cards: [FormatCardModel], query: String) -> [FormatCardModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cards }
        return cards.compactMap { card in
            if card.label.localizedCaseInsensitiveContains(q) { return card }
            let matches = card.properties.filter { $0.label.localizedCaseInsensitiveContains(q) }
            return matches.isEmpty ? nil : card.narrowed(to: matches)
        }
    }

    // MARK: - Reset

    /// True when at least one key of the whole card carries an override, so reset is meaningful.
    static func isOverridden(_ card: FormatCardModel, in spec: VisualSpec) -> Bool {
        switch card.role {
        case .format: return card.resetKeys.contains { spec.fmt(card.card, $0) != nil }
        case .altText: return !spec.altText.isEmpty
        case .tooltip: return spec.tooltipPageID != nil
        case .position, .presets, .conditional: return false
        }
    }

    // MARK: - Values

    /// The catalog's own entry of `property` for a visual of `type`: the same key can have another
    /// default on another type (a donut's inner radius is 64, a pie's 0).
    static func own(_ property: FormatProperty, for type: VisualType) -> FormatProperty {
        index[type]?[property.id] ?? property
    }

    private static let index: [VisualType: [String: FormatProperty]] = Dictionary(
        uniqueKeysWithValues: VisualType.allCases.map { type in
            let all = (visualCards(for: type) + generalCards(for: type)).filter { $0.role == .format }.flatMap(\.properties)
            return (type, Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        })

    /// The value in effect on each visual (override, theme defaults, catalog default), merged.
    static func value(of property: FormatProperty, in specs: [VisualSpec], theme: ThemeSpec) -> FormatValue<JSONValue?>? {
        FormatValue(specs.map { own(property, for: $0.type).value(in: ResolvedFormat(spec: $0, theme: theme)) })
    }

    /// The on/off state each visual renders with, including automatic defaults, merged.
    static func isOn(_ property: FormatProperty, in specs: [VisualSpec], theme: ThemeSpec) -> FormatValue<Bool>? {
        FormatValue(specs.map { own(property, for: $0.type).isOn(in: ResolvedFormat(spec: $0, theme: theme)) })
    }

    /// The colour the well previews while the property has no override: the renderer's fallback.
    static func defaultColor(of property: FormatProperty, theme: ThemeSpec) -> String {
        if let hex = property.defaultColorHex(in: theme) { return hex }
        // Component entries name no theme colour; these are the fallbacks their renderers use.
        switch (property.card, property.key) {
        case ("grid", "color"): return theme.gridline
        case ("gauge", "fillColor"), ("path", "color"): return theme.dataColors.first ?? theme.accent
        default: break
        }
        switch property.key {
        case "selectedColor": return theme.accent
        case "goodColor": return theme.good
        case "badColor": return theme.bad
        case "neutralColor": return theme.neutral
        case "background", "alternateBackground": return theme.cardBackground
        default: return theme.foreground
        }
    }

    // MARK: - Input

    /// What a committed number field means for a property with `bounds`.
    static func numberInput(_ text: String, bounds: ClosedRange<Double>, allowsEmpty: Bool = true) -> FormatNumberInput {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return allowsEmpty ? .clear : .invalid("Enter a number") }
        guard let parsed = DataTable.parseNumber(t), let v = FormatNumber.clamped(parsed, to: bounds) else {
            return .invalid("Enter a number from \(numberText(bounds.lowerBound)) to \(numberText(bounds.upperBound))")
        }
        return .value(v)
    }

    static func numberText(_ v: Double) -> String {
        abs(v) >= 1e9 ? String(format: "%.0e", v) : Value.double(v).asString
    }

    /// The value to store for `property`, or nil to remove the override. Numbers are clamped to
    /// the property's bounds and non-finite ones dropped; an empty string removes the override
    /// (a cleared title goes back to the automatic one); values of the wrong kind are dropped.
    static func stored(_ value: JSONValue?, for property: FormatProperty) -> JSONValue? {
        guard let value else { return nil }
        switch (property.kind, value) {
        case (.bool, .bool): return value
        case (.number, .number(let d)): return FormatNumber.clamped(d, to: property.bounds).map(JSONValue.number)
        case (.string, .string(let s)), (.color, .string(let s)), (.field, .string(let s)): return s.isEmpty ? nil : value
        case (.options(let options), .string(let s)): return options.contains(s) ? value : nil
        default: return nil
        }
    }

    /// "insideEnd" → "Inside end": camel-case option values as menu wording.
    static func sentenceCase(_ value: String) -> String {
        var out = ""
        for ch in value {
            if ch.isUppercase, !out.isEmpty { out.append(" "); out.append(contentsOf: ch.lowercased()) }
            else { out.append(ch) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// The frame after setting one Properties row; nil for an unknown key or a non-finite value.
    /// An emptied rotation means none.
    static func frame(_ frame: Frame, setting key: String, to value: Double?) -> Frame? {
        guard let p = positionCard.properties.first(where: { $0.key == key }) else { return nil }
        var f = frame
        if key == "rotation", value == nil { f.rotation = 0; return f }
        guard let v = FormatNumber.clamped(value, to: p.bounds) else { return nil }
        switch key {
        case "x": f.x = v
        case "y": f.y = v
        case "width": f.width = v
        case "height": f.height = v
        case "rotation": f.rotation = v
        default: return nil
        }
        return f
    }
}

/// Terse builder for the General-tab entries of one card.
private struct FormatCardBuilder {
    let card: String, label: String
    init(_ card: String, _ label: String) { self.card = card; self.label = label }

    func bool(_ key: String, _ l: String, _ d: Bool) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .bool, defaultValue: .bool(d))
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
    func options(_ key: String, _ l: String, _ o: [String], _ d: String) -> FormatProperty {
        FormatProperty(card: card, cardLabel: label, key: key, label: l, kind: .options(o), defaultValue: .string(d))
    }
}
