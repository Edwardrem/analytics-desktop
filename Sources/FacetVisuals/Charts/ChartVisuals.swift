import SwiftUI
import FacetCore
import FacetDesign

/// Entry point for chart-type visuals. Returns nil for types this file's family doesn't draw.
public enum ChartVisuals {
    /// Every visual type drawn by the chart renderers.
    public static let supportedTypes: Set<VisualType> = [
        .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
        .line, .area, .stackedArea, .stackedArea100, .lineStackedColumn, .lineClusteredColumn,
        .ribbon, .waterfall, .pie, .donut, .treemap, .funnel, .scatter, .dotPlot,
        .heatmap, .histogram, .boxPlot, .radar, .sunburst, .sankey, .bullet, .calendarHeatmap, .wordCloud, .candlestick,
    ]

    /// The chart body for `spec` (no container chrome — `VisualView` adds title, background and padding).
    /// Shows a quiet placeholder naming the wells to fill when required fields are missing.
    public static func view(spec: VisualSpec, data: VisualData, context: VisualContext) -> AnyView? {
        guard supportedTypes.contains(spec.type) else { return nil }
        if let message = missingFieldsMessage(spec: spec, data: data) {
            return AnyView(ChartPlaceholder(systemImage: symbol(for: spec.type), title: spec.type.displayName, message: message, theme: context.theme))
        }
        if data.isEmpty {
            return AnyView(ChartPlaceholder(systemImage: symbol(for: spec.type), title: "No data", message: "No data for the current filters.", theme: context.theme))
        }
        switch spec.type {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .lineStackedColumn, .lineClusteredColumn, .dotPlot:
            return AnyView(CartesianVisual(spec: spec, data: data, context: context))
        default:
            return CoreCharts.view(spec: spec, data: data, context: context)
                ?? FlowCharts.view(spec: spec, data: data, context: context)
                ?? StatCharts.view(spec: spec, data: data, context: context)
        }
    }

    /// Wells that must hold at least one field, as alternatives: each inner array is satisfied by any one of its wells.
    static func requiredWells(_ type: VisualType) -> [[Well]] {
        switch type {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .ribbon:
            return [[.values]]
        case .lineStackedColumn, .lineClusteredColumn: return [[.values, .lineValues]]
        case .waterfall: return [[.category], [.values]]
        case .pie, .donut, .treemap, .sunburst, .funnel, .wordCloud: return [[.values]]
        case .radar, .calendarHeatmap: return [[.category], [.values]]
        case .scatter: return [[.x], [.y]]
        case .dotPlot: return [[.category], [.values]]
        case .heatmap: return [[.rows, .columns], [.values]]
        case .histogram, .boxPlot, .bullet: return [[.values]]
        case .sankey: return [[.source], [.destination], [.values]]
        case .candlestick: return [[.category], [.open], [.high], [.low], [.close]]
        default: return []
        }
    }

    /// "Add a field to Values" style hint, or nil when the visual has what it needs.
    public static func missingFieldsMessage(spec: VisualSpec, data: VisualData) -> String? {
        let missing = requiredWells(spec.type).filter { alternatives in
            !alternatives.contains { !data.indices($0).isEmpty }
        }
        guard !missing.isEmpty else { return nil }
        let names = missing.map { $0.map(\.displayName).joined(separator: " or ") }
        let list = names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "Add a field to \(list)."
    }

    static func symbol(for type: VisualType) -> String {
        switch type {
        case .line, .area, .stackedArea, .stackedArea100: return "chart.xyaxis.line"
        case .pie, .donut, .sunburst: return "chart.pie"
        case .scatter, .dotPlot: return "chart.dots.scatter"
        case .treemap, .heatmap, .calendarHeatmap: return "square.grid.2x2"
        case .funnel: return "line.3.horizontal.decrease"
        case .sankey, .ribbon: return "arrow.triangle.branch"
        case .radar: return "hexagon"
        case .wordCloud: return "textformat"
        case .candlestick, .boxPlot: return "chart.bar.xaxis"
        default: return "chart.bar"
        }
    }
}
