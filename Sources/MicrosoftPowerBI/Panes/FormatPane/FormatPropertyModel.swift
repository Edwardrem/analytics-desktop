import Foundation
import FacetCore
import FacetVisuals

/// One formatting property the Format pane edits, unified from the FacetVisuals format catalogs
/// (`CmpFormatProperty` for component types, `FormatProperty` for charts) and the container cards.
/// View-free so it can move into a testable suite later.
struct FormatPropertyModel: Identifiable, Hashable {
    enum Kind: Hashable {
        case bool
        case number
        case string
        case color
        case enumeration(options: [String])
    }

    /// `format[card][key]` on `VisualSpec`.
    let card: String
    /// Human-readable card (section) name, e.g. "Grid".
    let cardLabel: String
    let key: String
    let label: String
    let kind: Kind
    /// Value used when the key is absent (`nil` = automatic, follows the theme or data).
    let defaultValue: JSONValue?

    var id: String { card + "." + key }

    init(card: String, cardLabel: String, key: String, label: String, kind: Kind, defaultValue: JSONValue?) {
        self.card = card; self.cardLabel = cardLabel; self.key = key
        self.label = label; self.kind = kind; self.defaultValue = defaultValue
    }

    /// From a component catalog entry (`ComponentFormatCatalog`).
    init(_ p: CmpFormatProperty) {
        self.init(card: p.card, cardLabel: p.cardLabel, key: p.key, label: p.label,
                  kind: Kind(p.kind), defaultValue: p.defaultValue == .null ? nil : p.defaultValue)
    }

    /// From a chart catalog entry; chart entries carry no card label, so the pane supplies one.
    init(_ p: FormatProperty, cardLabel: String) {
        self.init(card: p.card, cardLabel: cardLabel, key: p.key, label: p.label,
                  kind: Kind(p.kind), defaultValue: p.defaultValue == .null ? nil : p.defaultValue)
    }
}

extension FormatPropertyModel.Kind {
    init(_ k: CmpFormatProperty.Kind) {
        switch k {
        case .bool: self = .bool
        case .number: self = .number
        case .string: self = .string
        case .color: self = .color
        case .enumeration(let options): self = .enumeration(options: options)
        }
    }

    init(_ k: FormatProperty.Kind) {
        switch k {
        case .bool: self = .bool
        case .number: self = .number
        case .string: self = .string
        case .color: self = .color
        case .options(let options): self = .enumeration(options: options)
        }
    }
}

/// One collapsible Format pane card: properties grouped by the format-bag card they write to.
struct FormatCardModel: Identifiable, Hashable {
    /// The format-bag card, e.g. "columnHeaders".
    let card: String
    let label: String
    let properties: [FormatPropertyModel]
    var id: String { card }

    init(card: String, label: String, properties: [FormatPropertyModel]) {
        self.card = card; self.label = label; self.properties = properties
    }

    /// Groups properties by card, keeping first-appearance order and the first card label.
    init(properties: [FormatPropertyModel]) {
        self.card = properties.first?.card ?? ""
        self.label = properties.first?.cardLabel ?? ""
        self.properties = properties
    }
}

/// Builds the Format pane's cards from the FacetVisuals format catalogs, and the search and
/// reset helpers the pane needs. View-free; all writes stay in the pane.
enum FormatCatalog {
    /// Visual tab: every type-specific card the renderer of `type` honours. Component types come
    /// from `ComponentFormatCatalog`; chart types from the pane's chart entries (the chart family
    /// catalogs in FacetVisuals are internal stubs today).
    static func visualCards(for type: VisualType) -> [FormatCardModel] {
        let component = ComponentFormatCatalog.properties(for: type).map(FormatPropertyModel.init)
        if !component.isEmpty { return group(component) }
        let chart = ChartFormatProperties.properties(for: type).map {
            FormatPropertyModel($0, cardLabel: ChartFormatProperties.cardName($0.card))
        }
        return group(chart)
    }

    /// General tab: the container chrome every visual shares (`VisualView` draws these). The pane
    /// adds the Properties (position/size) and Alt text cards around these, since they are not
    /// format keys. Order follows Power BI.
    static func generalCards(for type: VisualType) -> [FormatCardModel] {
        let element = type.isPageElement
        var title = [FormatPropertyModel(card: "title", cardLabel: "Title", key: "show", label: "Show title",
                                         kind: .bool, defaultValue: .bool(!element)),
                     FormatPropertyModel(card: "title", cardLabel: "Title", key: "text", label: "Text",
                                         kind: .string, defaultValue: .string("")),
                     FormatPropertyModel(card: "title", cardLabel: "Title", key: "alignment", label: "Alignment",
                                         kind: .enumeration(options: ["left", "center", "right"]),
                                         defaultValue: .string("left")),
                     FormatPropertyModel(card: "title", cardLabel: "Title", key: "size", label: "Font size",
                                         kind: .number, defaultValue: nil),
                     FormatPropertyModel(card: "title", cardLabel: "Title", key: "bold", label: "Bold",
                                         kind: .bool, defaultValue: .bool(true)),
                     FormatPropertyModel(card: "title", cardLabel: "Title", key: "color", label: "Text colour",
                                         kind: .color, defaultValue: nil)]
        if element { title.removeAll { $0.key == "bold" || $0.key == "alignment" } }
        let cards: [FormatCardModel] = [
            FormatCardModel(properties: title),
            FormatCardModel(properties: [
                FormatPropertyModel(card: "subtitle", cardLabel: "Subtitle", key: "show", label: "Show subtitle",
                                    kind: .bool, defaultValue: .bool(false)),
                FormatPropertyModel(card: "subtitle", cardLabel: "Subtitle", key: "text", label: "Text",
                                    kind: .string, defaultValue: .string("")),
                FormatPropertyModel(card: "subtitle", cardLabel: "Subtitle", key: "size", label: "Font size",
                                    kind: .number, defaultValue: nil),
                FormatPropertyModel(card: "subtitle", cardLabel: "Subtitle", key: "color", label: "Text colour",
                                    kind: .color, defaultValue: nil),
            ]),
            FormatCardModel(properties: [
                FormatPropertyModel(card: "divider", cardLabel: "Divider", key: "show", label: "Show divider",
                                    kind: .bool, defaultValue: .bool(false)),
                FormatPropertyModel(card: "divider", cardLabel: "Divider", key: "color", label: "Line colour",
                                    kind: .color, defaultValue: nil),
            ]),
            FormatCardModel(properties: [
                FormatPropertyModel(card: "background", cardLabel: "Background", key: "show", label: "Show background",
                                    kind: .bool, defaultValue: .bool(!element)),
                FormatPropertyModel(card: "background", cardLabel: "Background", key: "color", label: "Colour",
                                    kind: .color, defaultValue: nil),
                FormatPropertyModel(card: "background", cardLabel: "Background", key: "transparency", label: "Transparency",
                                    kind: .number, defaultValue: .number(0)),
            ]),
            FormatCardModel(properties: [
                FormatPropertyModel(card: "border", cardLabel: "Border", key: "show", label: "Show border",
                                    kind: .bool, defaultValue: .bool(false)),
                FormatPropertyModel(card: "border", cardLabel: "Border", key: "color", label: "Colour",
                                    kind: .color, defaultValue: nil),
                FormatPropertyModel(card: "border", cardLabel: "Border", key: "width", label: "Width",
                                    kind: .number, defaultValue: .number(1)),
                FormatPropertyModel(card: "border", cardLabel: "Border", key: "radius", label: "Corner radius",
                                    kind: .number, defaultValue: nil),
            ]),
            FormatCardModel(properties: [
                FormatPropertyModel(card: "shadow", cardLabel: "Shadow", key: "show", label: "Show shadow",
                                    kind: .bool, defaultValue: .bool(false)),
            ]),
            FormatCardModel(properties: [
                FormatPropertyModel(card: "padding", cardLabel: "Padding", key: "all", label: "All sides",
                                    kind: .number, defaultValue: nil),
            ]),
        ]
        return cards.filter { !$0.properties.isEmpty }
    }

    /// Cards narrowed to what matches `query` (label or card name). Empty query returns all.
    static func filter(_ cards: [FormatCardModel], query: String) -> [FormatCardModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cards }
        return cards.compactMap { card in
            if card.label.localizedCaseInsensitiveContains(q) { return card }
            let matches = card.properties.filter { $0.label.localizedCaseInsensitiveContains(q) }
            return matches.isEmpty ? nil : FormatCardModel(card: card.card, label: card.label, properties: matches)
        }
    }

    /// True when at least one key of the card carries an override, so per-card reset is meaningful.
    static func isOverridden(_ card: FormatCardModel, in spec: VisualSpec) -> Bool {
        guard !card.properties.isEmpty else { return false }
        return card.properties.contains { spec.fmt(card.card, $0.key) != nil }
    }

    private static func group(_ properties: [FormatPropertyModel]) -> [FormatCardModel] {
        var order: [String] = []
        var byCard: [String: [FormatPropertyModel]] = [:]
        for p in properties {
            if byCard[p.card] == nil { order.append(p.card) }
            byCard[p.card, default: []].append(p)
        }
        return order.map { FormatCardModel(properties: byCard[$0] ?? []) }
    }
}
