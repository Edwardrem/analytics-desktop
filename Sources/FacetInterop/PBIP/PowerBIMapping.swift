import Foundation
import FacetCore

/// Translation tables between Facet's visual vocabulary and Power BI's (`visualType` names and data-role names).
public enum PowerBIMapping {
    /// Facet visual type → Power BI `visualType`. Types missing here have no Power BI equivalent.
    public static let visualTypeNames: [(facet: VisualType, powerBI: String)] = [
        (.stackedBar, "barChart"), (.clusteredBar, "clusteredBarChart"), (.stackedBar100, "hundredPercentStackedBarChart"),
        (.stackedColumn, "columnChart"), (.clusteredColumn, "clusteredColumnChart"), (.stackedColumn100, "hundredPercentStackedColumnChart"),
        (.line, "lineChart"), (.area, "areaChart"), (.stackedArea, "stackedAreaChart"), (.stackedArea100, "hundredPercentStackedAreaChart"),
        (.lineStackedColumn, "lineStackedColumnComboChart"), (.lineClusteredColumn, "lineClusteredColumnComboChart"),
        (.ribbon, "ribbonChart"), (.waterfall, "waterfallChart"), (.funnel, "funnel"), (.pie, "pieChart"), (.donut, "donutChart"),
        (.treemap, "treemap"), (.scatter, "scatterChart"), (.map, "map"), (.filledMap, "filledMap"), (.shapeMap, "shapeMap"),
        (.azureMap, "azureMap"), (.cardLegacy, "card"), (.card, "cardVisual"), (.multiRowCard, "multiRowCard"), (.kpi, "kpi"),
        (.gauge, "gauge"), (.table, "tableEx"), (.matrix, "pivotTable"), (.slicer, "slicer"), (.buttonSlicer, "advancedSlicerVisual"),
        (.listSlicer, "listSlicer"), (.inputSlicer, "textSlicer"), (.keyInfluencers, "keyDriversVisual"),
        (.decompositionTree, "decompositionTreeVisual"), (.qna, "qnaVisual"), (.rVisual, "scriptVisual"), (.pythonVisual, "pythonVisual"),
        (.paginatedReport, "rdlVisual"), (.metrics, "scorecard"), (.textBox, "textbox"), (.image, "image"), (.shape, "shape"),
        (.button, "actionButton"), (.pageNavigator, "pageNavigator"), (.bookmarkNavigator, "bookmarkNavigator"),
    ]
    /// Extra Power BI names accepted on import.
    static let importAliases: [String: VisualType] = ["basicShape": .shape, "esriVisual": .map, "stackedBarChart": .stackedBar,
                                                      "stackedColumnChart": .stackedColumn, "table": .table, "matrix": .matrix]

    /// Prefix of the custom `visualType` written for Facet-only visuals.
    public static let facetPrefix = "facet_"

    /// True when Power BI has a built-in visual equivalent to `type`.
    public static func hasPowerBIEquivalent(_ type: VisualType) -> Bool { visualTypeNames.contains { $0.facet == type } }

    /// The `visualType` written to PBIR: a Power BI name, or `facet_<rawValue>` for Facet-only visuals.
    public static func powerBIType(for type: VisualType) -> String {
        visualTypeNames.first { $0.facet == type }?.powerBI ?? facetPrefix + type.rawValue
    }

    /// The Facet type for a PBIR/PBIX `visualType`, or nil for unknown (custom) visuals.
    public static func facetType(forPowerBI name: String) -> VisualType? {
        if name.hasPrefix(facetPrefix) { return VisualType(rawValue: String(name.dropFirst(facetPrefix.count))) }
        if let m = visualTypeNames.first(where: { $0.powerBI == name }) { return m.facet }
        if let m = visualTypeNames.first(where: { $0.powerBI.caseInsensitiveCompare(name) == .orderedSame }) { return m.facet }
        return importAliases[name]
    }

    /// Power BI data-role names for the wells of a visual type.
    public static func roles(for type: VisualType) -> [(well: Well, role: String)] {
        let map: [Well: String]
        switch type {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .ribbon:
            map = [.category: "Category", .values: "Y", .legend: "Series", .smallMultiples: "Rows", .tooltips: "Tooltips"]
        case .lineStackedColumn, .lineClusteredColumn:
            map = [.category: "Category", .values: "Y", .lineValues: "Y2", .legend: "Series", .smallMultiples: "Rows", .tooltips: "Tooltips"]
        case .waterfall: map = [.category: "Category", .breakdown: "Breakdown", .values: "Y", .tooltips: "Tooltips"]
        case .pie, .donut: map = [.legend: "Category", .values: "Y", .details: "Series", .tooltips: "Tooltips"]
        case .treemap: map = [.category: "Group", .details: "Details", .values: "Values", .tooltips: "Tooltips"]
        case .funnel: map = [.category: "Category", .values: "Y", .tooltips: "Tooltips"]
        case .scatter: map = [.details: "Category", .x: "X", .y: "Y", .size: "Size", .legend: "Series", .playAxis: "Play", .tooltips: "Tooltips"]
        case .map, .azureMap: map = [.location: "Category", .latitude: "Y", .longitude: "X", .legend: "Series", .size: "Size", .tooltips: "Tooltips"]
        case .filledMap, .shapeMap: map = [.location: "Category", .legend: "Series", .values: "Value", .tooltips: "Tooltips"]
        case .card: map = [.values: "Data", .category: "Rows"]
        case .cardLegacy: map = [.values: "Values", .category: "Category"]
        case .multiRowCard, .table, .pythonVisual, .rVisual, .paginatedReport, .metrics: map = [.values: "Values"]
        case .kpi: map = [.values: "Indicator", .trendAxis: "TrendLine", .target: "Goal"]
        case .gauge: map = [.values: "Y", .minimum: "MinValue", .maximum: "MaxValue", .target: "TargetValue", .tooltips: "Tooltips"]
        case .matrix: map = [.rows: "Rows", .columns: "Columns", .values: "Values"]
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer: map = [.field: "Values"]
        case .keyInfluencers: map = [.analyze: "Target", .explainBy: "ExplainBy", .expandBy: "ExpandBy"]
        case .decompositionTree: map = [.analyze: "Analyze", .explainBy: "ExplainBy", .tooltips: "Tooltips"]
        default: map = [:]
        }
        return type.wells.map { ($0, map[$0] ?? defaultRole($0)) }
    }

    /// Role name used when a well has no Power BI counterpart: the well name with a leading capital.
    static func defaultRole(_ well: Well) -> String { well.rawValue.prefix(1).uppercased() + well.rawValue.dropFirst() }

    public static func roleName(for well: Well, in type: VisualType) -> String {
        roles(for: type).first { $0.well == well }?.role ?? defaultRole(well)
    }

    /// The Facet well for a Power BI role name in a visual of `type`.
    public static func well(forRole role: String, in type: VisualType) -> Well? {
        if let m = roles(for: type).first(where: { $0.role == role }) { return m.well }
        if let m = roles(for: type).first(where: { $0.role.caseInsensitiveCompare(role) == .orderedSame }) { return m.well }
        // Fall back to well names, then to common synonyms.
        if let w = Well.allCases.first(where: { defaultRole($0).caseInsensitiveCompare(role) == .orderedSame }), type.wells.contains(w) { return w }
        let generic: [String: Well] = ["category": .category, "y": .values, "values": .values, "value": .values, "series": .legend,
                                       "legend": .legend, "rows": .rows, "columns": .columns, "x": .x, "size": .size, "details": .details,
                                       "tooltips": .tooltips, "y2": .lineValues, "targetvalue": .target, "minvalue": .minimum,
                                       "maxvalue": .maximum, "goal": .target, "indicator": .values, "trendline": .trendAxis,
                                       "group": .category, "data": .values, "field": .field, "breakdown": .breakdown, "play": .playAxis]
        if let w = generic[role.lowercased()] {
            if type.wells.contains(w) { return w }
            // The nearest well of the same nature this visual does have.
            return type.wells.first { $0.isGrouping == w.isGrouping && $0 != .tooltips }
        }
        return nil
    }

    // MARK: Aggregation function codes (semantic query `Aggregation.Function`)

    static func aggregationCode(_ a: Aggregation) -> Int? {
        switch a {
        case .none: return nil
        case .sum: return 0
        case .average: return 1
        case .distinctCount: return 2
        case .min, .first: return 3
        case .max, .last: return 4
        case .count: return 5
        case .median: return 6
        case .stdDev: return 7
        case .variance: return 8
        }
    }
    static func aggregation(code: Int) -> Aggregation {
        switch code {
        case 0: return .sum
        case 1: return .average
        case 2: return .distinctCount
        case 3: return .min
        case 4: return .max
        case 5: return .count
        case 6: return .median
        case 7: return .stdDev
        case 8: return .variance
        default: return .sum
        }
    }
    static func aggregationQueryName(_ a: Aggregation) -> String {
        switch a {
        case .sum: return "Sum"
        case .average: return "Avg"
        case .distinctCount: return "Count"
        case .min, .first: return "Min"
        case .max, .last: return "Max"
        case .count: return "CountNonNull"
        case .median: return "Median"
        case .stdDev: return "StandardDeviation"
        case .variance: return "Variance"
        case .none: return ""
        }
    }
}
