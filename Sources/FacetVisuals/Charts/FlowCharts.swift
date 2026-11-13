import SwiftUI
import FacetCore

/// Canvas-drawn charts: ribbon, treemap, sunburst, funnel, sankey, radar, word cloud.
enum FlowCharts {
    static func view(spec: VisualSpec, data: VisualData, context: VisualContext) -> AnyView? {
        let env = FlowEnv(spec: spec, data: data, context: context)
        switch spec.type {
        case .funnel: return AnyView(FunnelChart(env: env))
        case .radar: return AnyView(RadarChart(env: env))
        case .treemap: return AnyView(TreemapChart(env: env))
        case .sunburst: return AnyView(SunburstChart(env: env))
        case .ribbon: return AnyView(RibbonChart(env: env))
        case .sankey: return AnyView(SankeyChart(env: env))
        case .wordCloud: return AnyView(WordCloudChart(env: env))
        default: return nil
        }
    }

    /// Format-pane properties honoured by this family for `type` (beyond the shared container cards).
    static func formatProperties(for type: VisualType) -> [FormatProperty] { [] }
}

extension ChartGallery {
    static func flowSamples() -> [Sample] { [] }
}
