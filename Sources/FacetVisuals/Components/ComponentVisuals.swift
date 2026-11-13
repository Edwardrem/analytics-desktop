import SwiftUI
import FacetCore
import FacetDesign

/// Entry point for non-chart visuals (tables, cards, slicers, maps, gantt, page elements, embeds).
/// Returns nil for types this family doesn't draw (charts, and the AI visuals the app supplies
/// through `VisualContext.extensionView`).
public enum ComponentVisuals {
    public static func view(spec: VisualSpec, data: VisualData, context: VisualContext) -> AnyView? {
        let env = CmpEnv(spec: spec, data: data, context: context)
        switch spec.type {
        case .table, .matrix:
            return CmpTableFamily.view(env)
        case .card, .cardLegacy, .multiRowCard, .kpi, .gauge:
            return CmpCardFamily.view(env)
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer:
            return CmpSlicerFamily.view(env)
        case .map, .azureMap, .filledMap, .shapeMap, .gantt:
            return CmpMapFamily.view(env)
        case .textBox, .image, .shape, .button, .pageNavigator, .bookmarkNavigator,
             .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics:
            return CmpPageFamily.view(env)
        default:
            return nil
        }
    }

    /// Every `VisualType` this family renders.
    public static let supportedTypes: [VisualType] = [
        .table, .matrix, .card, .cardLegacy, .multiRowCard, .kpi, .gauge,
        .slicer, .buttonSlicer, .listSlicer, .inputSlicer,
        .map, .azureMap, .filledMap, .shapeMap, .gantt,
        .textBox, .image, .shape, .button, .pageNavigator, .bookmarkNavigator,
        .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics,
    ]
}

/// Machine-readable list of the format properties each component honours (drives the Format pane).
public enum ComponentFormatCatalog {
    public static func properties(for type: VisualType) -> [CmpFormatProperty] {
        CmpTableFamily.properties(for: type) + CmpCardFamily.properties(for: type)
            + CmpSlicerFamily.properties(for: type) + CmpMapFamily.properties(for: type)
            + CmpPageFamily.properties(for: type)
    }
}

/// Named style presets (partial format bags to merge into `VisualSpec.format`).
public enum ComponentStylePresets {
    public static func presets(for type: VisualType) -> [(name: String, format: FormatBag)] {
        CmpTableFamily.presets(for: type) + CmpCardFamily.presets(for: type)
            + CmpSlicerFamily.presets(for: type) + CmpMapFamily.presets(for: type)
            + CmpPageFamily.presets(for: type)
    }
    /// Presets with colours derived from `theme` (use this for dark / high-contrast themes; the
    /// theme-less variant uses the default Facet theme for table and matrix colours).
    public static func presets(for type: VisualType, theme: ThemeSpec) -> [(name: String, format: FormatBag)] {
        CmpTableFamily.presets(for: type, theme: theme) + CmpCardFamily.presets(for: type)
            + CmpSlicerFamily.presets(for: type) + CmpMapFamily.presets(for: type)
            + CmpPageFamily.presets(for: type)
    }
    /// Format cards whose keys are column / value names rather than fixed properties
    /// (table & matrix: `columnWidths`, `imageColumns`, `sparklines`, `totals`), with the kind of each value.
    public static func perFieldCards(for type: VisualType) -> [(card: String, label: String, kind: CmpFormatProperty.Kind)] {
        CmpTableFamily.perFieldCards(for: type)
    }
    /// Merges a preset into a spec's format bag (preset keys win; other keys are kept).
    public static func apply(_ preset: FormatBag, to spec: inout VisualSpec) {
        for (card, props) in preset { for (k, v) in props { spec.setFmt(card, k, v) } }
    }
}
