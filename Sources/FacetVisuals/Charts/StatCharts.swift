import SwiftUI
import FacetCore

/// Statistical and grid charts: heatmap, calendar heatmap, histogram, box plot, candlestick, bullet.
enum StatCharts {
    static func view(spec: VisualSpec, data: VisualData, context: VisualContext) -> AnyView? {
        switch spec.type {
        case .histogram: return AnyView(HistogramView(spec: spec, data: data, context: context))
        case .boxPlot: return AnyView(BoxPlotView(spec: spec, data: data, context: context))
        case .heatmap, .calendarHeatmap: return AnyView(HeatmapView(spec: spec, data: data, context: context))
        case .candlestick: return AnyView(CandlestickView(spec: spec, data: data, context: context))
        case .bullet: return AnyView(BulletView(spec: spec, data: data, context: context))
        case .scatter: return AnyView(ScatterChart(spec: spec, data: data, context: context))
        default: return nil
        }
    }

    /// Format-pane properties honoured by this family for `type` (beyond the shared container cards).
    /// Each default repeats the fallback at the renderer's read (`Stat*` files, `StatPlot`).
    static func formatProperties(for type: VisualType) -> [FormatProperty] {
        switch type {
        case .histogram:
            let c = FormatCard("histogram", "Histogram")
            return SharedFormatCards.statAxes() + SharedFormatCards.legend()
                + [c.number("bins", "Bin count (0 = automatic)", 0, 0...Double(HistogramModel.maxBins)),
                   c.options("showAs", "Show as", ["count", "percent"], "count"),
                   c.bool("stacked", "Stack series", true),
                   FormatCard("bars", "Columns").number("cornerRadius", "Corner radius", 2, 0...100)]
                + SharedFormatCards.dataLabels(show: false) + SharedFormatCards.plotArea() + SharedFormatCards.accessibility()
        case .boxPlot:
            let c = FormatCard("boxPlot", "Box plot")
            return SharedFormatCards.statAxes() + SharedFormatCards.legend()
                + [c.bool("showOutliers", "Show outliers", true),
                   c.bool("showMean", "Show mean", false)]
                + SharedFormatCards.dataLabels(show: false) + SharedFormatCards.plotArea() + SharedFormatCards.accessibility()
        case .heatmap, .calendarHeatmap:
            let c = FormatCard("heatmap", "Colour scale")
            return [c.color("minColor", "Minimum colour", .minimum),
                    c.color("maxColor", "Maximum colour", .maximum),
                    c.bool("threeColor", "Three-colour scale", false),
                    c.color("midColor", "Middle colour", .center),
                    c.number("min", "Minimum value", nil, -1e15...1e15),
                    c.number("max", "Maximum value", nil, -1e15...1e15),
                    c.number("radius", "Cell corner radius", 2, 0...40)]
                + SharedFormatCards.dataLabels(show: true, values: false, toggle: false)
        case .candlestick:
            let c = FormatCard("candlestick", "Candles")
            return SharedFormatCards.statAxes()
                + [c.color("upColor", "Rising colour", .good),
                   c.color("downColor", "Falling colour", .bad)]
                + SharedFormatCards.plotArea()
        case .bullet:
            let c = FormatCard("bullet", "Bullet")
            return [c.color("barColor", "Bar colour", .accent),
                    c.color("trackColor", "Track colour", .gridline)]
                + SharedFormatCards.dataLabels(show: true, values: false, toggle: false)
        case .scatter:
            let c = FormatCard("markers", "Markers")
            return SharedFormatCards.statAxes()
                + [c.number("size", "Marker size", 3.5, ScatterChart.markerSizes),
                   c.number("transparency", "Transparency %", 20, 0...100)]
                + SharedFormatCards.plotArea()
        default:
            return []
        }
    }
}

extension ChartGallery {
    static func statisticalSamples() -> [Sample] { [] }
    static func gridSamples() -> [Sample] { [] }
}
