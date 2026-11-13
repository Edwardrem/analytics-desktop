import Foundation
import FacetCore
import FacetVisuals

/// Chart format entries for the Format pane: one entry per key the chart renderers in
/// `FacetVisuals` honour through `ResolvedFormat` lookups (each verified against a renderer call
/// site). The per-family catalogs in FacetVisuals are internal stubs today, so the entries live
/// here, typed on FacetVisuals' public `FormatProperty`; card labels come from `cardName(_:)`.
enum ChartFormatProperties {
    /// Every entry for `type`, grouped by the card the pane shows them under.
    static func properties(for type: VisualType) -> [FormatProperty] {
        switch type {
        case .stackedBar, .clusteredBar, .stackedBar100:
            return cartesian(horizontal: true, withBars: true, withLines: false, totals: true, y2: false, zoom: true, small: true)
        case .stackedColumn, .clusteredColumn, .stackedColumn100:
            return cartesian(horizontal: false, withBars: true, withLines: false, totals: true, y2: false, zoom: true, small: true)
        case .line, .area, .stackedArea, .stackedArea100:
            return cartesian(horizontal: false, withBars: false, withLines: true, totals: false, y2: false, zoom: true, small: true)
        case .lineStackedColumn, .lineClusteredColumn:
            return cartesian(horizontal: false, withBars: true, withLines: true, totals: true, y2: true, zoom: true, small: true)
        case .dotPlot:
            return cartesian(horizontal: true, withBars: false, withLines: false, totals: false, y2: false, zoom: false, small: false)
        case .ribbon, .sankey:
            return legend() + [accessibility()]  // the scaffold's legend keys and patterns
        case .pie:
            return legend() + slices() + dataLabels()
        case .donut:
            return legend() + slices(donut: true) + dataLabels()
        case .treemap:
            return treemap() + dataLabels() + [accessibility()]
        case .sunburst:
            return sunburst() + dataLabels() + [accessibility()]
        case .funnel:
            return legend() + [accessibility()] + funnel() + dataLabels()
        case .radar:
            return legend() + [accessibility()] + radar() + radarLines()
        case .waterfall:
            return legend() + [accessibility()] + waterfall() + bars() + dataLabels() + axes()
        case .histogram:
            return legend() + [accessibility()] + histogram() + dataLabels() + axes()
        case .boxPlot:
            return legend() + [accessibility()] + boxPlot() + axes()
        case .heatmap, .calendarHeatmap:
            return [accessibility()] + heatmap() + axes()
        case .candlestick:
            return candlestick()
        case .bullet:
            return bullet()
        default:
            return []
        }
    }

    /// Human-readable card name for a format-bag card (chart entries carry no card label).
    static func cardName(_ card: String) -> String {
        switch card {
        case "legend": return "Legend"
        case "xAxis": return "X axis"
        case "yAxis": return "Y axis"
        case "y2Axis": return "Secondary axis"
        case "dataLabels": return "Data labels"
        case "totalLabels": return "Total labels"
        case "bars": return "Bars"
        case "lines": return "Lines"
        case "slices": return "Slices"
        case "treemap": return "Treemap"
        case "sunburst": return "Sunburst"
        case "funnel": return "Funnel"
        case "radar": return "Radar"
        case "waterfall": return "Waterfall"
        case "histogram": return "Histogram"
        case "boxPlot": return "Box plot"
        case "heatmap": return "Heat map"
        case "candlestick": return "Candlestick"
        case "bullet": return "Bullet"
        case "zoomSlider": return "Zoom slider"
        case "smallMultiples": return "Small multiples"
        case "accessibility": return "Accessibility"
        default: return card
        }
    }

    // MARK: - Families

    /// Bar, column, line, area and combo charts (`CartesianOptions` / `ChartScaffold`).
    /// Horizontal charts read their category axis from the "yAxis" card and their value axis
    /// from "xAxis"; vertical charts the other way round.
    private static func cartesian(horizontal: Bool, withBars: Bool, withLines: Bool, totals: Bool, y2: Bool, zoom: Bool, small: Bool) -> [FormatProperty] {
        var out: [FormatProperty] = legend() + [
            FormatProperty("xAxis", "show", "Show axis", .bool, .bool(true)),
            FormatProperty("yAxis", "show", "Show axis", .bool, .bool(true)),
        ]
        out += axisDetail(card: horizontal ? "yAxis" : "xAxis", isCategory: true)
        out += axisDetail(card: horizontal ? "xAxis" : "yAxis", isCategory: false)
        if withLines { out += lines() }
        if withBars { out += bars() }
        out += dataLabels()
        if totals {
            out += [FormatProperty("totalLabels", "show", "Show total labels", .bool, .bool(false)),
                    FormatProperty("totalLabels", "displayUnits", "Display units", .options(displayUnits), .string("auto")),
                    FormatProperty("totalLabels", "color", "Text colour", .color)]
        }
        if y2 {
            out += [FormatProperty("y2Axis", "show", "Show secondary axis", .bool, .bool(true)),
                    FormatProperty("y2Axis", "showTitle", "Show title", .bool, .bool(false)),
                    FormatProperty("y2Axis", "title", "Title", .string)]
        }
        if zoom { out += [FormatProperty("zoomSlider", "show", "Show zoom slider", .bool, .bool(false))] }
        if small { out += [FormatProperty("smallMultiples", "sharedYAxis", "Shared value axis", .bool, .bool(true))] }
        out += [accessibility()]
        return out
    }

    /// The keys one axis card honours. `isCategory` selects the rotation/concatenation/reverse
    /// keys the renderer applies to the category card and the range keys it applies to the value card.
    private static func axisDetail(card: String, isCategory: Bool) -> [FormatProperty] {
        let name = card == "xAxis" ? "X axis" : "Y axis"
        var out: [FormatProperty] = [
            FormatProperty(card, "showTitle", "\(name) title", .bool, .bool(false)),
            FormatProperty(card, "title", "Title", .string),
        ]
        if isCategory {
            out += [FormatProperty(card, "labelRotation", "Label rotation", .number, .number(0)),
                    FormatProperty(card, "concatenateLabels", "Concatenate labels", .bool, .bool(true)),
                    FormatProperty(card, "reverse", "Reverse order", .bool, .bool(false)),
                    FormatProperty(card, "gridlines", "Gridlines", .bool, .bool(false))]
        } else {
            out += [FormatProperty(card, "min", "Minimum", .number),
                    FormatProperty(card, "max", "Maximum", .number),
                    FormatProperty(card, "displayUnits", "Display units", .options(displayUnits), .string("auto")),
                    FormatProperty(card, "decimals", "Decimal places", .number),
                    FormatProperty(card, "reverse", "Reverse order", .bool, .bool(false)),
                    FormatProperty(card, "logScale", "Logarithmic scale", .bool, .bool(false)),
                    FormatProperty(card, "gridlines", "Gridlines", .bool, .bool(true))]
        }
        return out
    }

    private static func legend() -> [FormatProperty] {
        [FormatProperty("legend", "show", "Show legend", .bool, .null),
         FormatProperty("legend", "position", "Position", .options(["top", "bottom", "left", "right"]), .string("top")),
         FormatProperty("legend", "title", "Title", .string),
         FormatProperty("legend", "size", "Font size", .number)]
    }

    private static func bars() -> [FormatProperty] {
        [FormatProperty("bars", "innerPadding", "Inner padding %", .number),
         FormatProperty("bars", "outerPadding", "Outer padding %", .number),
         FormatProperty("bars", "cornerRadius", "Corner radius", .number, .number(2.5))]
    }

    /// The `lines` card for cartesian charts.
    private static func lines() -> [FormatProperty] {
        [FormatProperty("lines", "width", "Line width", .number, .number(2)),
         FormatProperty("lines", "style", "Line style", .options(["solid", "dashed", "dotted"]), .string("solid")),
         FormatProperty("lines", "interpolation", "Shape", .options(["smooth", "linear", "step"]), .string("smooth")),
         FormatProperty("lines", "shadeArea", "Shade area", .bool, .bool(false)),
         FormatProperty("lines", "seriesLabels", "Show series labels", .bool, .bool(false)),
         FormatProperty("lines", "showMarkers", "Show markers", .bool, .bool(false)),
         FormatProperty("lines", "markerSize", "Marker size", .number),
         FormatProperty("lines", "markerShape", "Marker shape", .options(markerShapes), .string("auto"))]
    }

    /// Radar honours line width and markers only.
    private static func radarLines() -> [FormatProperty] {
        [FormatProperty("lines", "width", "Line width", .number, .number(2)),
         FormatProperty("lines", "showMarkers", "Show markers", .bool, .bool(true))]
    }

    private static func dataLabels() -> [FormatProperty] {
        [FormatProperty("dataLabels", "show", "Show data labels", .bool, .bool(false)),
         FormatProperty("dataLabels", "position", "Position", .options(labelPositions), .string("auto")),
         FormatProperty("dataLabels", "displayUnits", "Display units", .options(displayUnits), .string("auto")),
         FormatProperty("dataLabels", "decimals", "Decimal places", .number),
         FormatProperty("dataLabels", "color", "Text colour", .color)]
    }

    /// Pie and donut (`slices` card). `showCenter` keys apply to the donut hole.
    private static func slices(donut: Bool = false) -> [FormatProperty] {
        var out = [FormatProperty("slices", "innerRadius", "Inner radius %", .number, .number(donut ? 64 : 0)),
                   FormatProperty("slices", "labels", "Label content",
                                  .options(["categoryPercent", "category", "categoryValue", "percent", "value", "all", "none"]),
                                  .string("categoryPercent")),
                   FormatProperty("slices", "cornerRadius", "Corner radius", .number, .number(3))]
        if donut {
            out += [FormatProperty("slices", "centerValue", "Show centre value", .bool, .bool(true)),
                    FormatProperty("slices", "centerLabel", "Centre label", .string),
                    FormatProperty("slices", "centerUnits", "Centre display units", .options(displayUnits), .string("auto"))]
        }
        return out
    }

    /// Treemap and sunburst rings (`slices` card keys on `FlowTreemap.swift`).
    private static func treemap() -> [FormatProperty] {
        [FormatProperty("treemap", "padding", "Tile padding", .number, .number(2)),
         FormatProperty("treemap", "cornerRadius", "Corner radius", .number, .number(3)),
         FormatProperty("treemap", "showGroupLabels", "Show group labels", .bool, .bool(true)),
         FormatProperty("treemap", "showValues", "Show values", .bool, .bool(true))]
    }

    private static func sunburst() -> [FormatProperty] {
        [FormatProperty("slices", "innerRadius", "Inner radius %", .number, .number(30)),
         FormatProperty("slices", "showCenter", "Show centre total", .bool, .bool(true))]
    }

    private static func funnel() -> [FormatProperty] {
        [FormatProperty("funnel", "showCategoryLabels", "Show stage labels", .bool, .bool(true)),
         FormatProperty("funnel", "showPercent", "Show percentages", .bool, .bool(true)),
         FormatProperty("funnel", "percentOf", "Percent of", .options(["first", "previous"]), .string("first")),
         FormatProperty("funnel", "gap", "Stage gap", .number, .number(6)),
         FormatProperty("funnel", "cornerRadius", "Corner radius", .number, .number(3)),
         FormatProperty("funnel", "showConnectors", "Show connectors", .bool, .bool(true))]
    }

    private static func radar() -> [FormatProperty] {
        [FormatProperty("radar", "showCategoryLabels", "Show spoke labels", .bool, .bool(true)),
         FormatProperty("radar", "showAxisLabels", "Show value labels", .bool, .bool(true)),
         FormatProperty("radar", "gridlines", "Gridlines", .bool, .bool(true)),
         FormatProperty("radar", "fill", "Fill shape", .bool, .bool(true)),
         FormatProperty("radar", "min", "Minimum", .number),
         FormatProperty("radar", "max", "Maximum", .number)]
    }

    private static func waterfall() -> [FormatProperty] {
        [FormatProperty("waterfall", "showTotal", "Show total bar", .bool, .bool(true)),
         FormatProperty("waterfall", "totalLabel", "Total label", .string, .string("Total")),
         FormatProperty("waterfall", "connectors", "Show connectors", .bool, .bool(true)),
         FormatProperty("waterfall", "maxBreakdowns", "Maximum breakdowns", .number, .number(5)),
         FormatProperty("waterfall", "increaseColor", "Increase colour", .color),
         FormatProperty("waterfall", "decreaseColor", "Decrease colour", .color),
         FormatProperty("waterfall", "totalColor", "Total colour", .color)]
    }

    private static func histogram() -> [FormatProperty] {
        [FormatProperty("histogram", "bins", "Bin count (0 = automatic)", .number, .number(0)),
         FormatProperty("histogram", "showAs", "Show as", .options(["count", "percent"]), .string("count")),
         FormatProperty("histogram", "stacked", "Stack series", .bool, .bool(true))]
    }

    private static func boxPlot() -> [FormatProperty] {
        [FormatProperty("boxPlot", "showOutliers", "Show outliers", .bool, .bool(true)),
         FormatProperty("boxPlot", "showMean", "Show mean", .bool, .bool(false))]
    }

    /// Heat map and calendar heat map (`heatmap` card: colour scale and cell spacing).
    private static func heatmap() -> [FormatProperty] {
        [FormatProperty("heatmap", "radius", "Cell spacing", .number, .number(2)),
         FormatProperty("heatmap", "min", "Minimum", .number),
         FormatProperty("heatmap", "max", "Maximum", .number),
         FormatProperty("heatmap", "minColor", "Minimum colour", .color),
         FormatProperty("heatmap", "maxColor", "Maximum colour", .color),
         FormatProperty("heatmap", "threeColor", "Three-colour scale", .bool, .bool(false)),
         FormatProperty("heatmap", "midColor", "Middle colour", .color)]
    }

    private static func candlestick() -> [FormatProperty] {
        [FormatProperty("candlestick", "upColor", "Rising colour", .color),
         FormatProperty("candlestick", "downColor", "Falling colour", .color)]
    }

    private static func bullet() -> [FormatProperty] {
        [FormatProperty("bullet", "trackColor", "Track colour", .color),
         FormatProperty("bullet", "barColor", "Bar colour", .color)]
    }

    /// Axis keys the simpler Swift Charts visuals read through `ChartAxes` (waterfall, histogram,
    /// box plot, heat maps).
    private static func axes() -> [FormatProperty] {
        [FormatProperty("xAxis", "show", "Show category axis", .bool, .bool(true)),
         FormatProperty("xAxis", "size", "Category label size", .number),
         FormatProperty("yAxis", "show", "Show value axis", .bool, .bool(true)),
         FormatProperty("yAxis", "displayUnits", "Display units", .options(displayUnits), .string("auto")),
         FormatProperty("yAxis", "decimals", "Decimal places", .number),
         FormatProperty("yAxis", "gridlines", "Gridlines", .bool, .bool(true)),
         FormatProperty("yAxis", "size", "Value label size", .number)]
    }

    private static func accessibility() -> FormatProperty {
        FormatProperty("accessibility", "patterns", "Distinguish series with patterns", .bool, .null)
    }

    // MARK: - Option lists

    private static let displayUnits = ["auto", "none", "thousands", "millions", "billions", "trillions"]
    private static let labelPositions = ["auto", "outsideEnd", "insideEnd", "insideCenter", "insideBase"]
    private static let markerShapes = ["auto", "circle", "square", "diamond", "triangle", "cross", "plus", "pentagon", "asterisk"]
}
