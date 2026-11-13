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
    static func formatProperties(for type: VisualType) -> [FormatProperty] { [] }
}

extension ChartGallery {
    static func statisticalSamples() -> [Sample] { [] }
    static func gridSamples() -> [Sample] { [] }
}
