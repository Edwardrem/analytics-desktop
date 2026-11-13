import SwiftUI
import FacetCore
import FacetDesign

/// Single-value visuals: card (new), card (classic), multi-row card, KPI, gauge.
enum CmpCardFamily {
    static func view(_ env: CmpEnv) -> AnyView? {
        let type = env.spec.type
        guard [.card, .cardLegacy, .multiRowCard, .kpi, .gauge].contains(type) else { return nil }
        if env.data.table.columnCount == 0 {
            let (icon, hint): (String, String) = {
                switch type {
                case .kpi: return ("chart.line.uptrend.xyaxis", "Add a value, a trend axis and a target.")
                case .gauge: return ("gauge.with.needle", "Add a value, and optionally minimum, maximum and target.")
                case .multiRowCard: return ("rectangle.grid.1x2", "Add fields to show one card row per item.")
                default: return ("textformat.123", "Add a value to show it as a card.")
                }
            }()
            return AnyView(CmpPlaceholder(systemImage: icon, title: type.displayName, message: hint, theme: env.theme))
        }
        switch type {
        case .card: return AnyView(CmpCardView(env: env))
        case .cardLegacy: return AnyView(CmpCardLegacyView(env: env))
        case .multiRowCard: return AnyView(CmpMultiRowCardView(env: env))
        case .kpi: return AnyView(CmpKPIView(env: env))
        default: return AnyView(CmpGaugeView(env: env))
        }
    }

    // MARK: Catalog

    static func properties(for type: VisualType) -> [CmpFormatProperty] {
        let callout = CmpCard("callout", "Callout value")
        let label = CmpCard("label", "Label")
        let units = ["auto", "none", "thousands", "millions", "billions", "trillions"]
        func common(alignment: String, size: Double?) -> [CmpFormatProperty] {
            [
                callout.number("size", "Font size", size),
                callout.color("color", "Colour"),
                callout.bool("bold", "Bold", true),
                callout.options("displayUnits", "Display units", units, "auto"),
                callout.number("decimals", "Decimal places", nil),
                callout.options("alignment", "Alignment", ["left", "center", "right"], alignment),
                label.bool("show", "Show label", true),
                label.number("size", "Font size", nil),
                label.color("color", "Colour"),
            ]
        }
        let layout = CmpCard("layout", "Layout")
        let bar = CmpCard("accentBar", "Accent bar")
        switch type {
        case .card:
            let ref = CmpCard("referenceLabels", "Reference labels")
            let image = CmpCard("image", "Image")
            let cards = CmpCard("cards", "Cards (small multiples)")
            return common(alignment: "left", size: nil) + [
                label.options("position", "Position", ["below", "above"], "below"),
                layout.options("orientation", "Arrangement", ["auto", "horizontal", "vertical"], "auto"),
                layout.number("columns", "Columns (small multiples)", nil),
                layout.number("spacing", "Spacing", 16),
                layout.bool("dividers", "Dividers", true),
                bar.bool("show", "Show", false), bar.color("color", "Colour"), bar.number("width", "Width", 3),
                ref.bool("show", "Show", true), ref.bool("showDifference", "Show % difference", true),
                ref.bool("higherIsBetter", "Higher is better", true),
                image.bool("show", "Show", false), image.string("url", "Image URL"), image.number("size", "Size", 36),
                image.number("radius", "Corner radius", 6),
                cards.bool("background", "Tile background", true), cards.bool("border", "Tile border", false),
                cards.number("radius", "Tile corner radius", 8),
            ]
        case .cardLegacy:
            return common(alignment: "center", size: nil) + [label.options("position", "Position", ["below", "above"], "below")]
        case .multiRowCard:
            let title = CmpCard("categoryTitle", "Card title")
            return common(alignment: "left", size: 17).filter { $0.key != "alignment" } + [
                title.number("size", "Font size", 13), title.color("color", "Colour"),
                bar.bool("show", "Show", true), bar.color("color", "Colour"), bar.number("width", "Width", 3),
                layout.bool("dividers", "Dividers", true),
            ]
        case .kpi:
            let trend = CmpCard("trend", "Trend"), goal = CmpCard("goal", "Goal"), date = CmpCard("date", "Date")
            let indicator = CmpCard("indicator", "Indicator")
            return common(alignment: "center", size: nil) + [
                indicator.bool("colorByStatus", "Colour by status", false),
                trend.bool("show", "Show trend", true),
                trend.options("direction", "Direction", ["highIsGood", "lowIsGood"], "highIsGood"),
                trend.color("goodColor", "Good colour"), trend.color("badColor", "Bad colour"),
                trend.color("neutralColor", "Neutral colour"),
                goal.bool("show", "Show goal", true), goal.bool("showDistance", "Show distance", true),
                goal.string("label", "Label", "Goal"),
                date.bool("show", "Show latest date", true),
            ]
        case .gauge:
            let g = CmpCard("gauge", "Gauge")
            return common(alignment: "center", size: nil).filter { $0.key != "alignment" && !($0.card == "label" && $0.key == "show") } + [
                g.number("min", "Minimum", nil), g.number("max", "Maximum", nil), g.number("target", "Target", nil),
                g.color("fillColor", "Fill colour"), g.color("trackColor", "Track colour"), g.color("targetColor", "Target colour"),
                g.number("thickness", "Thickness (fraction of radius)", 0.2),
                g.bool("showLabels", "Show min / max labels", true), g.bool("showTarget", "Show target", true),
                g.bool("showCallout", "Show callout value", true),
            ]
        default: return []
        }
    }

    static func presets(for type: VisualType) -> [(name: String, format: FormatBag)] {
        switch type {
        case .card:
            return [
                ("Minimal", ["accentBar": ["show": .bool(false)], "layout": ["dividers": .bool(false)], "callout": ["bold": .bool(false)]]),
                ("Accent bar", ["accentBar": ["show": .bool(true), "width": .number(3)], "layout": ["dividers": .bool(false)]]),
                ("Centered", ["callout": ["alignment": .string("center")], "layout": ["dividers": .bool(true)]]),
                ("Condensed", ["callout": ["size": .number(22)], "label": ["size": .number(10)], "layout": ["spacing": .number(10)]]),
                ("Contrast", ["background": ["color": .string("#1D1D1F")], "callout": ["color": .string("#FFFFFF")],
                              "label": ["color": .string("#AEAEB2")], "title": ["color": .string("#FFFFFF")]]),
                ("Outlined tiles", ["cards": ["background": .bool(false), "border": .bool(true)], "accentBar": ["show": .bool(false)]]),
            ]
        case .cardLegacy:
            return [
                ("Minimal", ["callout": ["bold": .bool(false)], "label": ["show": .bool(false)]]),
                ("Label above", ["label": ["position": .string("above")]]),
                ("Contrast", ["background": ["color": .string("#1D1D1F")], "callout": ["color": .string("#FFFFFF")],
                              "label": ["color": .string("#AEAEB2")]]),
            ]
        case .multiRowCard:
            return [
                ("Minimal", ["accentBar": ["show": .bool(false)], "layout": ["dividers": .bool(true)]]),
                ("Accent bar", ["accentBar": ["show": .bool(true)], "layout": ["dividers": .bool(false)]]),
                ("Condensed", ["callout": ["size": .number(14)], "label": ["size": .number(10)], "categoryTitle": ["size": .number(12)]]),
            ]
        case .kpi:
            return [
                ("Minimal", ["trend": ["show": .bool(false)]]),
                ("Status colour", ["indicator": ["colorByStatus": .bool(true)]]),
            ]
        default: return []
        }
    }

    // MARK: Samples

    static func samples() -> [(spec: VisualSpec, data: VisualData)] {
        var out: [(spec: VisualSpec, data: VisualData)] = []
        // New card: three callouts, reference labels from targets, accent bar.
        out.append(CmpSample.make(.card, name: "Card callouts", size: (560, 150), columns: [
            CmpCol("Revenue", .values, measure: true, format: "$#,0"),
            CmpCol("Orders", .values, measure: true, format: "#,0"),
            CmpCol("Margin", .values, measure: true, format: "0.0%"),
            CmpCol("Revenue target", .target, measure: true, format: "$#,0"),
            CmpCol("Orders last year", .target, measure: true, format: "#,0"),
            CmpCol("Margin target", .target, measure: true, format: "0.0%"),
        ], rows: [[.double(4_862_300), .int(18_432), .double(0.342), .double(4_500_000), .int(19_870), .double(0.33)]]) { s in
            s.setFmt("title", "text", .string("This quarter"))
            s.setFmt("accentBar", "show", .bool(true))
        })
        // New card with a category → small multiples of cards.
        out.append(CmpSample.make(.card, name: "Card small multiples", size: (620, 260), columns: [
            CmpCol("Region", .category),
            CmpCol("Revenue", .values, measure: true, format: "$#,0"),
            CmpCol("Target", .target, measure: true, format: "$#,0"),
        ], rows: [
            ["North America", .double(2_140_000), .double(2_000_000)], ["Europe", .double(1_310_500), .double(1_400_000)],
            ["Asia Pacific", .double(986_200), .double(900_000)], ["Latin America", .double(312_900), .double(350_000)],
            ["Middle East", .double(98_400), .double(90_000)], ["Africa", .double(14_300), .double(20_000)],
        ]))
        out.append(CmpSample.make(.card, name: "Card stacked", size: (200, 260), columns: [
            CmpCol("Active customers", .values, measure: true, format: "#,0"),
            CmpCol("Churn rate", .values, measure: true, format: "0.0%"),
            CmpCol("NPS", .values, measure: true, format: "0"),
        ], rows: [[.int(128_640), .double(0.021), .int(62)]]) { s in
            s.setFmt("layout", "orientation", .string("vertical"))
            s.setFmt("title", "show", .bool(false))
        })
        out.append(CmpSample.make(.cardLegacy, name: "CardLegacy", size: (260, 150), columns: [
            CmpCol("Total Sales", .values, measure: true, format: "$#,0.00"),
        ], rows: [[.double(12_483_902.55)]]) { s in s.setFmt("title", "show", .bool(false)) })
        out.append(CmpSample.make(.multiRowCard, name: "MultiRowCard", size: (460, 280), columns: [
            CmpCol("Product", .values),
            CmpCol("Revenue", .values, measure: true, format: "$#,0"),
            CmpCol("Units", .values, measure: true, format: "#,0"),
            CmpCol("Margin", .values, measure: true, format: "0.0%"),
            CmpCol("Return rate", .values, measure: true, format: "0.0%"),
        ], rows: [
            ["Aurora Laptop 14", .double(1_820_400), .int(1_412), .double(0.31), .double(0.012)],
            ["Halo Earbuds", .double(940_250), .int(11_870), .double(0.44), .double(0.034)],
            ["Meridian Monitor 27", .double(612_900), .int(1_960), .double(0.27), .double(0.008)],
            ["Pulse Smartwatch", .double(488_120), .int(2_304), .double(0.38), .double(0.021)],
        ]) { s in s.setFmt("title", "text", .string("Top products")) })
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let good: [Double] = [310, 322, 318, 341, 356, 349, 372, 390, 384, 412, 431, 458]
        out.append(CmpSample.make(.kpi, name: "KPI on track", size: (300, 190), columns: [
            CmpCol("Month", .trendAxis), CmpCol("Revenue", .values, measure: true, format: "$#,0"),
            CmpCol("Revenue goal", .target, measure: true, format: "$#,0"),
        ], rows: months.indices.map { [.string(months[$0] + " 2026"), .double(good[$0] * 1000), .double(420_000)] }) { s in
            s.setFmt("title", "text", .string("Revenue"))
        })
        let bad: [Double] = [4.1, 4.4, 4.2, 4.9, 5.3, 5.1, 5.8, 6.2, 5.9, 6.6, 6.9, 7.4]
        out.append(CmpSample.make(.kpi, name: "KPI behind", size: (300, 190), columns: [
            CmpCol("Month", .trendAxis), CmpCol("Churn", .values, measure: true, format: "0.0%"),
            CmpCol("Churn goal", .target, measure: true, format: "0.0%"),
        ], rows: months.indices.map { [.string(months[$0] + " 2026"), .double(bad[$0] / 100), .double(0.05)] }) { s in
            s.setFmt("title", "text", .string("Customer churn"))
            s.setFmt("trend", "direction", .string("lowIsGood"))
            s.setFmt("indicator", "colorByStatus", .bool(true))
        })
        out.append(CmpSample.make(.gauge, name: "Gauge", size: (300, 220), columns: [
            CmpCol("Revenue", .values, measure: true, format: "$#,0"),
            CmpCol("Min", .minimum, measure: true, format: "$#,0"),
            CmpCol("Max", .maximum, measure: true, format: "$#,0"),
            CmpCol("Goal", .target, measure: true, format: "$#,0"),
        ], rows: [[.double(3_420_000), .double(0), .double(5_000_000), .double(4_000_000)]]) { s in
            s.setFmt("title", "text", .string("Revenue vs goal"))
        })
        out.append(CmpSample.make(.gauge, name: "Gauge auto scale", size: (240, 170), columns: [
            CmpCol("Satisfaction", .values, measure: true, format: "0.0%"),
        ], rows: [[.double(0.874)]]) { s in
            s.setFmt("gauge", "max", .number(1)); s.setFmt("gauge", "target", .number(0.9))
            s.setFmt("title", "show", .bool(false))
        })
        out.append(CmpSample.make(.card, name: "Card empty", size: (240, 130)))
        return out
    }
}
