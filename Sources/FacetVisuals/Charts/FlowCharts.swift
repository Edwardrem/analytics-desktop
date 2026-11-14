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
    /// Each default repeats the fallback at the renderer's read (the `Flow*` chart files).
    static func formatProperties(for type: VisualType) -> [FormatProperty] {
        switch type {
        case .funnel:
            let c = FormatCard("funnel", "Funnel")
            return [c.bool("showCategoryLabels", "Show stage labels", true),
                    c.bool("showPercent", "Show percentages", true),
                    c.options("percentOf", "Percent of", ["first", "previous"], "first"),
                    c.number("gap", "Stage gap", 6, 0...100),
                    c.number("cornerRadius", "Corner radius", 3, 0...100),
                    c.bool("showConnectors", "Show connectors", true)]
                + SharedFormatCards.dataLabels(show: true)
        case .radar:
            let c = FormatCard("radar", "Radar"), lines = FormatCard("lines", "Lines")
            return SharedFormatCards.legend()
                + [c.bool("showCategoryLabels", "Show spoke labels", true),
                   c.bool("showAxisLabels", "Show value labels", true),
                   c.bool("gridlines", "Gridlines", true),
                   c.bool("fill", "Fill shape", true),
                   c.number("min", "Minimum", nil, -1e15...1e15),
                   c.number("max", "Maximum", nil, -1e15...1e15),
                   lines.number("width", "Line width", 2, 0.25...20),
                   lines.bool("showMarkers", "Show markers", true)]
                + SharedFormatCards.accessibility()
        case .treemap:
            let c = FormatCard("treemap", "Treemap")
            return [c.number("padding", "Tile padding", 2, 0...40),
                    c.number("cornerRadius", "Corner radius", 3, 0...100),
                    c.bool("showGroupLabels", "Show group labels", true),
                    c.bool("showValues", "Show values", true)]
                + SharedFormatCards.dataLabels(show: true) + SharedFormatCards.accessibility()
        case .sunburst:
            let c = FormatCard("slices", "Rings")
            return [c.number("innerRadius", "Inner radius %", 30, 0...80),
                    c.bool("showCenter", "Show centre total", true)]
                + SharedFormatCards.dataLabels(show: true) + SharedFormatCards.accessibility()
        case .ribbon:
            return SharedFormatCards.legend()
        case .wordCloud:
            let c = FormatCard("wordCloud", "Words")
            return [c.number("maxWords", "Maximum words (0 = all)", 0, 0...Double(WordCloudChart.maxWords)),
                    c.number("minFontSize", "Smallest font size", 10, WordCloudChart.fontSizes),
                    c.number("maxFontSize", "Largest font size", 44, WordCloudChart.fontSizes)]
        case .sankey:
            // Node names are drawn at the data-label size; there is nothing to switch off.
            return SharedFormatCards.dataLabels(show: true, values: false, toggle: false)
        default:
            return []
        }
    }
}
