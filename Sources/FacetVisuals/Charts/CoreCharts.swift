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
    static func formatProperties(for type: VisualType) -> [FormatProperty] { [] }
}

extension ChartGallery {
    static func partToWholeSamples() -> [Sample] { [] }
    static func scatterSamples() -> [Sample] { [] }
}
