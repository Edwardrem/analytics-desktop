import SwiftUI
import FacetCore
import FacetDesign

/// Maps (`map`, `azureMap`, `filledMap`, `shapeMap`) and the Gantt chart.
enum CmpMapFamily {
    static let shapeHint = "Add a GeoJSON shape file for filled regions"

    static func view(_ env: CmpEnv) -> AnyView? {
        switch env.spec.type {
        case .map, .azureMap:
            return AnyView(CmpBubbleMapView(env: env))
        case .filledMap, .shapeMap:
            return AnyView(choropleth(env))
        case .gantt:
            return AnyView(CmpGanttView(env: env))
        default:
            return nil
        }
    }

    /// The shape file text: `spec.content`, else `format["shape"]["geojson"]` (a JSON string or an inline object).
    static func shapeSource(_ env: CmpEnv) -> String? {
        let content = env.spec.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty { return content }
        guard let v = env.f.value("shape", "geojson") else { return nil }
        if let s = v.stringValue { return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        if v.objectValue != nil, let data = try? JSONSerialization.data(withJSONObject: foundation(v)) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func foundation(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(foundation)
        case .object(let o): return o.mapValues(foundation)
        }
    }

    @ViewBuilder private static func choropleth(_ env: CmpEnv) -> some View {
        if env.data.indices(.location).isEmpty {
            CmpPlaceholder(systemImage: "map", title: env.spec.type.displayName,
                           message: "Add a location field, then values to colour the regions.", theme: env.theme)
        } else if let source = shapeSource(env) {
            switch CmpGeoShapeCache.shared.shapes(for: source) {
            case .success(let shapes):
                CmpChoroplethView(env: env, shapes: shapes)
            case .failure(let error):
                CmpPlaceholder(systemImage: "exclamationmark.triangle", title: "Can't read the shape file",
                               message: error.localizedDescription, theme: env.theme)
            }
        } else {
            // No shape file: honest fallback — geocoded bubbles on a MapKit base map plus a hint.
            CmpBubbleMapView(env: env, hint: shapeHint)
        }
    }

    // MARK: Format catalog

    static func properties(for type: VisualType) -> [CmpFormatProperty] {
        let legend = CmpCard("legend", "Legend")
        let tooltips = CmpCard("tooltips", "Tooltips")
        switch type {
        case .map, .azureMap:
            let map = CmpCard("map", "Map"), layers = CmpCard("layers", "Layers"), bubbles = CmpCard("bubbles", "Bubbles")
            let heat = CmpCard("heatmap", "Heat map"), path = CmpCard("path", "Path")
            return [
                map.options("style", "Map style", ["standard", "satellite", "hybrid", "muted"], "standard"),
                map.bool("autoZoom", "Auto-zoom to data", true),
                map.bool("showControls", "Zoom controls and compass", true),
                map.bool("selectionTools", "Selection tools (rectangle, lasso)", true),
                layers.bool("bubble", "Bubble layer", true),
                layers.bool("heatmap", "Heat map layer", false),
                layers.bool("path", "Path layer", false),
                bubbles.number("size", "Largest bubble radius", 22),
                bubbles.number("minSize", "Smallest bubble radius", 4),
                bubbles.number("transparency", "Transparency (%)", 25),
                bubbles.color("color", "Colour (no legend)"),
                bubbles.bool("outline", "Outline", true),
                heat.number("radius", "Radius", 28),
                heat.number("intensity", "Intensity", 1),
                heat.number("transparency", "Transparency (%)", 30),
                path.number("width", "Line width", 2),
                path.color("color", "Line colour"),
                legend.bool("show", "Show legend", true),
                legend.options("position", "Position", ["top", "bottom"], "top"),
                tooltips.bool("show", "Show tooltips", true),
            ]
        case .filledMap, .shapeMap:
            let shape = CmpCard("shape", "Shape"), fill = CmpCard("fill", "Fill colours"), bubbles = CmpCard("bubbles", "Bubbles (no shape file)")
            let map = CmpCard("map", "Map (no shape file)")
            return [
                shape.string("geojson", "Shape file (GeoJSON or TopoJSON text)"),
                shape.options("projection", "Projection", ["auto", "mercator", "equirectangular", "identity", "screen"], "auto"),
                shape.string("matchProperty", "Match locations to property"),
                shape.bool("showUnmatched", "Show regions without data", true),
                shape.bool("labels", "Region labels", false),
                shape.color("outlineColor", "Outline colour"),
                shape.number("outlineWidth", "Outline width", 0.75),
                fill.color("minColor", "Minimum"),
                fill.color("midColor", "Centre (optional)"),
                fill.color("maxColor", "Maximum"),
                fill.color("emptyColor", "No data"),
                legend.bool("show", "Show legend", true),
                legend.options("position", "Position", ["top", "bottom"], "bottom"),
                tooltips.bool("show", "Show tooltips", true),
                map.options("style", "Map style", ["standard", "satellite", "hybrid", "muted"], "standard"),
                map.bool("autoZoom", "Auto-zoom to data", true),
                map.bool("showControls", "Zoom controls and compass", true),
                map.bool("selectionTools", "Selection tools (rectangle, lasso)", true),
                bubbles.number("size", "Largest bubble radius", 18),
                bubbles.number("minSize", "Smallest bubble radius", 4),
                bubbles.number("transparency", "Transparency (%)", 25),
            ]
        case .gantt:
            let g = CmpCard("gantt", "Gantt")
            return [
                g.number("rowHeight", "Row height", 28),
                g.number("barRadius", "Bar corner radius", 4),
                g.color("barColor", "Bar colour (no legend)"),
                g.color("milestoneColor", "Milestone colour"),
                g.bool("showLabels", "Task labels", true),
                g.number("labelWidth", "Label column width (0 = automatic)", 0),
                g.bool("progressLabels", "Progress labels", false),
                g.bool("gridlines", "Gridlines", true),
                g.bool("weekends", "Shade weekends (day scale)", true),
                g.bool("todayLine", "Today line", true),
                g.color("todayColor", "Today line colour"),
                g.bool("inclusiveEnd", "Date-only end dates include that day", true),
                g.number("zoom", "Zoom (1 = fit)", 1),
                legend.bool("show", "Show legend", true),
                tooltips.bool("show", "Show tooltips", true),
            ]
        default:
            return []
        }
    }

    static func presets(for type: VisualType) -> [(name: String, format: FormatBag)] {
        switch type {
        case .map, .azureMap:
            return [
                ("Bubbles", ["layers": ["bubble": .bool(true), "heatmap": .bool(false), "path": .bool(false)], "map": ["style": .string("standard")]]),
                ("Muted", ["map": ["style": .string("muted")], "bubbles": ["transparency": .number(15)]]),
                ("Heat map", ["layers": ["bubble": .bool(false), "heatmap": .bool(true), "path": .bool(false)], "map": ["style": .string("muted")]]),
                ("Route", ["layers": ["bubble": .bool(false), "heatmap": .bool(false), "path": .bool(true)], "path": ["width": .number(3)]]),
                ("Satellite", ["map": ["style": .string("hybrid")], "bubbles": ["transparency": .number(10)]]),
            ]
        case .gantt:
            return [
                ("Standard", ["gantt": ["rowHeight": .number(28), "progressLabels": .bool(false), "gridlines": .bool(true)]]),
                ("Condensed", ["gantt": ["rowHeight": .number(20), "barRadius": .number(3)]]),
                ("Minimal", ["gantt": ["gridlines": .bool(false), "weekends": .bool(false), "barRadius": .number(6)]]),
                ("Progress", ["gantt": ["progressLabels": .bool(true), "rowHeight": .number(30)]]),
            ]
        default:
            return []
        }
    }

    static func samples() -> [(spec: VisualSpec, data: VisualData)] { CmpMapGallery.samples() }
}
