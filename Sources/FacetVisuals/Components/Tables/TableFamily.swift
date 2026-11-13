import SwiftUI
import FacetCore
import FacetDesign

/// Family entry point for `table` and `matrix`.
enum CmpTableFamily {
    static func view(_ env: CmpEnv) -> AnyView? {
        switch env.spec.type {
        case .table:
            let hasColumns = env.data.table.columnCount > 0
            guard hasColumns else {
                return AnyView(CmpPlaceholder(systemImage: "tablecells", title: "Table",
                                              message: "Add fields to Values to build this table.", theme: env.theme))
            }
            return AnyView(CmpTblGridRepresentable(env: env) { CmpTblTableSource(env: $0, previous: $1) })
        case .matrix:
            let any = !(env.data.indices(.rows) + env.data.indices(.columns) + env.data.indices(.values)).isEmpty
            guard any, env.data.table.columnCount > 0 else {
                return AnyView(CmpPlaceholder(systemImage: "rectangle.split.3x3", title: "Matrix",
                                              message: "Add fields to Rows, Columns and Values to build this matrix.", theme: env.theme))
            }
            return AnyView(CmpTblGridRepresentable(env: env) { CmpMxSource(env: $0, previous: $1) })
        default:
            return nil
        }
    }

    // MARK: Format catalog

    static func properties(for type: VisualType) -> [CmpFormatProperty] {
        guard type == .table || type == .matrix else { return [] }
        let headers = CmpCard("columnHeaders", "Column headers")
        let values = CmpCard("values", "Values")
        let grid = CmpCard("grid", "Grid")
        let total = CmpCard("total", type == .table ? "Totals row" : "Totals style")
        let icons = CmpCard("conditionalIcons", "Conditional icons")
        var out: [CmpFormatProperty] = [
            headers.bool("show", "Show headers", true),
            headers.number("fontSize", "Font size", nil),
            headers.bool("bold", "Bold", true),
            headers.color("color", "Text colour"),
            headers.color("background", "Background"),
            headers.bool("uppercase", "Uppercase", false),
            values.number("fontSize", "Font size", nil),
            values.color("color", "Text colour"),
            values.color("background", "Background"),
            values.bool("alternating", "Alternating rows", false),
            values.color("alternateBackground", "Alternate row colour"),
            grid.bool("horizontal", "Horizontal lines", true),
            grid.bool("vertical", "Vertical lines", false),
            grid.color("color", "Line colour"),
            grid.number("rowPadding", "Row padding", 5),
            grid.bool("fillWidth", "Stretch columns to fill", type == .table),
            total.color("color", "Text colour"),
            total.color("background", "Background"),
            icons.options("set", "Icon set", CmpIconSet.sets.keys.sorted(), "arrows"),
        ]
        if type == .table {
            let bars = CmpCard("dataBars", "Data bars")
            out += [
                values.bool("wordWrap", "Word wrap", false),
                values.number("maxWrapLines", "Maximum wrapped lines", 3),
                values.options("alignment", "Alignment", ["auto", "left", "center", "right"], "auto"),
                values.bool("detectURLs", "Show web addresses as links", true),
                values.number("imageHeight", "Image height", 32),
                total.bool("show", "Show totals row", true),
                total.string("label", "Label", "Total"),
                total.bool("bold", "Bold", true),
                bars.bool("barOnly", "Show bar only", false),
                icons.options("position", "Icon position", ["left", "right"], "left"),
                icons.bool("iconOnly", "Show icon only", false),
            ]
        } else {
            let layout = CmpCard("layout", "Layout")
            let sub = CmpCard("subtotals", "Subtotals")
            let exp = CmpCard("expandButtons", "+/− buttons")
            out += [
                values.bool("heatmap", "Heat-map background", false),
                layout.bool("stepped", "Stepped layout", true),
                layout.number("indent", "Stepped indent", 14),
                layout.bool("valuesOnRows", "Show values on rows", false),
                sub.bool("rows", "Row subtotals", true),
                sub.bool("columns", "Column subtotals", true),
                sub.bool("rowGrandTotal", "Row grand total", true),
                sub.bool("columnGrandTotal", "Column grand total", true),
                sub.string("label", "Total label", "Total"),
                exp.bool("show", "Show +/− buttons", true),
            ]
        }
        return out
    }

    /// Per-field cards whose keys are column / value names rather than fixed properties.
    /// (Documented in API.md; listed here so the Format pane can build per-field editors.)
    static func perFieldCards(for type: VisualType) -> [(card: String, label: String, kind: CmpFormatProperty.Kind)] {
        switch type {
        case .table:
            return [("columnWidths", "Column width", .number), ("imageColumns", "Show as image", .bool),
                    ("sparklines", "Sparkline", .enumeration(options: ["line", "column"]))]
        case .matrix:
            return [("columnWidths", "Column width", .number),
                    ("totals", "Subtotal aggregate", .enumeration(options: CmpMxAggregate.allCases.map(\.rawValue)))]
        default: return []
        }
    }

    // MARK: Style presets

    static func presets(for type: VisualType) -> [(name: String, format: FormatBag)] { presets(for: type, theme: .facet) }

    /// Theme-aware variant: preset colours are derived from the theme so they also suit dark themes.
    /// `.null` entries reset a key to "follow the theme" when a preset is applied over another.
    static func presets(for type: VisualType, theme t: ThemeSpec) -> [(name: String, format: FormatBag)] {
        guard type == .table || type == .matrix else { return [] }
        let reset: FormatBag = [
            "columnHeaders": ["bold": .bool(true), "uppercase": .bool(false), "background": .null, "color": .null, "fontSize": .null],
            "values": ["alternating": .bool(false), "alternateBackground": .null, "background": .null, "color": .null,
                       "fontSize": .null, "heatmap": .bool(false)],
            "grid": ["horizontal": .bool(true), "vertical": .bool(false), "rowPadding": .number(5), "color": .null],
            "total": ["background": .null, "color": .null],
        ]
        func preset(_ overrides: FormatBag) -> FormatBag {
            var bag = reset
            for (card, props) in overrides { for (k, v) in props { bag[card, default: [:]][k] = v } }
            return bag
        }
        let fg = t.foreground, card = t.cardBackground
        let soft = HexColor.lerp(card, fg, 0.07)
        let accentSoft = HexColor.lerp(card, t.accent, 0.16)
        var out: [(name: String, format: FormatBag)] = [
            ("Default", preset([:])),
            ("Minimal", preset(["grid": ["horizontal": .bool(false)], "columnHeaders": ["bold": .bool(false)]])),
            ("Bold header", preset(["columnHeaders": ["background": .string(fg), "color": .string(card)],
                                    "total": ["background": .string(soft), "color": .string(fg)]])),
            ("Alternating rows", preset(["values": ["alternating": .bool(true)], "grid": ["horizontal": .bool(false)]])),
            ("Contrast", preset(["columnHeaders": ["background": .string(fg), "color": .string(card), "uppercase": .bool(true)],
                                 "values": ["alternating": .bool(true), "alternateBackground": .string(HexColor.lerp(card, fg, 0.12))],
                                 "grid": ["vertical": .bool(true), "color": .string(HexColor.lerp(card, fg, 0.45))],
                                 "total": ["background": .string(fg), "color": .string(card)]])),
            ("Condensed", preset(["grid": ["rowPadding": .number(2)], "values": ["fontSize": .number(11)],
                                  "columnHeaders": ["fontSize": .number(11)]])),
            ("Flashy rows", preset(["columnHeaders": ["background": .string(t.accent), "color": .string(CmpColor.readableText(on: t.accent))],
                                    "values": ["alternating": .bool(true), "alternateBackground": .string(accentSoft)],
                                    "grid": ["horizontal": .bool(false)],
                                    "total": ["background": .string(t.accent), "color": .string(CmpColor.readableText(on: t.accent))]])),
        ]
        if type == .matrix {
            out.append(("Heat map", preset(["values": ["heatmap": .bool(true)], "grid": ["horizontal": .bool(false)]])))
        }
        return out
    }

    static func samples() -> [(spec: VisualSpec, data: VisualData)] { CmpTblGallery.samples() }
}
