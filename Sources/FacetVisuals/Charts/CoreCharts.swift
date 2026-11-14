import SwiftUI
import FacetCore

/// Pie, donut, waterfall, scatter and dot plot.
enum CoreCharts {
    static func view(spec: VisualSpec, data: VisualData, context: VisualContext) -> AnyView? {
        switch spec.type {
        case .pie, .donut: return AnyView(PieVisual(spec: spec, data: data, context: context))
        case .waterfall: return AnyView(WaterfallVisual(spec: spec, data: data, context: context))
        default: return nil
        }
    }

    /// Format-pane properties honoured by this family for `type` (beyond the shared container cards).
    /// Each default repeats the fallback at the renderer's read (`PieVisual`, `WaterfallVisual`).
    static func formatProperties(for type: VisualType) -> [FormatProperty] {
        switch type {
        case .pie, .donut:
            let donut = type == .donut
            let c = FormatCard("slices", "Slices")
            var slices = [c.number("innerRadius", "Inner radius %", donut ? 64 : 0, 0...92),
                          c.options("labels", "Label content",
                                    ["categoryPercent", "category", "categoryValue", "percent", "value", "all", "none"], "categoryPercent"),
                          c.number("cornerRadius", "Corner radius", 3, 0...40)]
            if donut {
                slices += [c.bool("centerValue", "Show centre value", true),
                           c.string("centerLabel", "Centre label"),
                           c.options("centerUnits", "Centre display units", SharedFormatCards.displayUnits, "auto")]
            }
            // The pie hides its legend until asked: the labels already name the slices.
            return SharedFormatCards.legend(showDefault: false) + slices
                + SharedFormatCards.dataLabels(show: true) + SharedFormatCards.accessibility()
        case .waterfall:
            let w = FormatCard("waterfall", "Waterfall"), bars = FormatCard("bars", "Columns")
            let x = FormatCard("xAxis", "X axis"), y = FormatCard("yAxis", "Y axis")
            return [x.bool("show", "Show axis", true),
                    x.number("size", "Font size", nil, SharedFormatCards.fontSizes),
                    y.bool("show", "Show axis", true),
                    y.number("min", "Minimum", nil, -1e15...1e15),
                    y.number("max", "Maximum", nil, -1e15...1e15),
                    y.options("displayUnits", "Display units", SharedFormatCards.displayUnits, "auto"),
                    y.number("decimals", "Decimal places", nil, 0...10),
                    y.bool("gridlines", "Gridlines", true),
                    y.number("size", "Font size", nil, SharedFormatCards.fontSizes)]
                + SharedFormatCards.legend(showDefault: true)
                + [w.bool("showTotal", "Show total column", true),
                   w.string("totalLabel", "Total label", "Total"),
                   w.bool("connectors", "Show connectors", true),
                   w.number("maxBreakdowns", "Maximum breakdowns", 5, 1...100),
                   w.color("increaseColor", "Increase colour", .good),
                   w.color("decreaseColor", "Decrease colour", .bad),
                   w.color("totalColor", "Total colour", .firstDataColor),
                   bars.number("innerPadding", "Inner padding %", 30, 0...90),
                   bars.number("cornerRadius", "Corner radius", 2.5, 0...100)]
                + SharedFormatCards.dataLabels(show: true)
        default:
            return []
        }
    }
}
