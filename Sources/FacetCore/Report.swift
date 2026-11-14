import Foundation

// MARK: - Field references

/// A reference to a model field placed in a visual well, filter, or parameter.
public struct FieldRef: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case column, measure }
    public var id = UUID()
    public var kind: Kind
    public var table: String
    public var name: String
    /// For columns used as values: the implicit-measure aggregation. `.none` groups by the column.
    public var aggregation: Aggregation = .none
    /// Optional caption override shown in the visual.
    public var displayName: String?
    /// Hidden fields still feed visual calculations but are not drawn.
    public var isHidden = false
    /// "Show value as": "", "percentOfGrandTotal", "percentOfColumnTotal", "percentOfRowTotal".
    public var showAs: String = ""
    /// A level of the column's auto date/time hierarchy ("Year", "Quarter", "Month", "Day"); nil for the column itself.
    public var dateLevel: String?

    public init(kind: Kind, table: String, name: String, aggregation: Aggregation = .none) {
        self.kind = kind; self.table = table; self.name = name; self.aggregation = aggregation
    }
    public static func column(_ table: String, _ name: String, _ agg: Aggregation = .none) -> FieldRef {
        FieldRef(kind: .column, table: table, name: name, aggregation: agg)
    }
    public static func measure(_ table: String, _ name: String) -> FieldRef {
        FieldRef(kind: .measure, table: table, name: name)
    }
    /// A level of a date column's auto date/time hierarchy: `'Table'[Column].[Level]` in DAX.
    public static func dateLevel(_ table: String, _ column: String, _ level: String) -> FieldRef {
        var f = FieldRef(kind: .column, table: table, name: column)
        f.dateLevel = level
        return f
    }
    /// True when this field produces a number per group (a measure or an aggregated column).
    public var isAggregate: Bool { kind == .measure || aggregation != .none }
    public var caption: String {
        if let d = displayName, !d.isEmpty { return d }
        let base = dateLevel ?? name
        if kind == .column, aggregation != .none { return "\(aggregation.displayName) of \(base)" }
        return base
    }
    /// DAX-style identifier: 'Table'[Name], or 'Table'[Name].[Level] for a date hierarchy level.
    public var daxReference: String {
        if kind == .measure { return "[\(name)]" }
        return "'\(table)'[\(name)]" + (dateLevel.map { ".[\($0)]" } ?? "")
    }
    /// Identity ignoring `id` and presentation, for matching the same field across wells.
    public var key: String { "\(kind.rawValue)|\(table)|\(name)|\(aggregation.rawValue)" + (dateLevel.map { "|\($0)" } ?? "") }
}

// MARK: - Filters

public enum FilterOperator: String, Codable, CaseIterable, Sendable {
    case equals, notEquals, greaterThan, greaterOrEqual, lessThan, lessOrEqual
    case contains, notContains, startsWith, notStartsWith, endsWith, isBlank, isNotBlank, isEmpty, isNotEmpty
    public var displayName: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .greaterThan: return "is greater than"
        case .greaterOrEqual: return "is greater than or equal to"
        case .lessThan: return "is less than"
        case .lessOrEqual: return "is less than or equal to"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .startsWith: return "starts with"
        case .notStartsWith: return "does not start with"
        case .endsWith: return "ends with"
        case .isBlank: return "is blank"
        case .isNotBlank: return "is not blank"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }
    public var needsValue: Bool {
        switch self { case .isBlank, .isNotBlank, .isEmpty, .isNotEmpty: return false; default: return true }
    }
}

public struct FilterCondition: Codable, Hashable, Sendable {
    public var op: FilterOperator
    public var value: Value
    public init(op: FilterOperator, value: Value = .null) { self.op = op; self.value = value }
}

public struct RelativeDateFilter: Codable, Hashable, Sendable {
    public enum Direction: String, Codable, CaseIterable, Sendable { case last, this, next }
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case minutes, hours, days, weeks, calendarWeeks, months, calendarMonths, years, calendarYears
    }
    public var direction: Direction = .last
    public var count = 7
    public var unit: Unit = .days
    public var includeToday = true
    public init() {}
}

public struct TopNFilter: Codable, Hashable, Sendable {
    public var count = 10
    public var isBottom = false
    public var by: FieldRef?
    public init() {}
}

public struct FilterSpec: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case basic, advanced, topN, relativeDate, relativeTime }
    public enum Scope: String, Codable, Sendable { case visual, page, report, drillthrough }
    public var id = UUID()
    public var field: FieldRef
    public var kind: Kind = .basic
    /// Basic filtering: the selected values (`isInverted` = "select all except").
    public var values: [Value] = []
    public var isInverted = false
    /// Advanced filtering: one or two conditions joined by AND/OR.
    public var conditions: [FilterCondition] = []
    public var conditionsUseOr = false
    public var topN = TopNFilter()
    public var relative = RelativeDateFilter()
    // Author controls
    public var isLocked = false
    public var isHidden = false
    public var requireSingleSelection = false
    public var displayName: String?
    /// For drillthrough filters: keep-all-filters behaviour is on the page; this marks "used as category".
    public var drillthroughUsedAsCategory = true

    public init(field: FieldRef, kind: Kind = .basic) { self.field = field; self.kind = kind }

    /// True when the filter restricts nothing.
    public var isEmpty: Bool {
        switch kind {
        case .basic: return values.isEmpty
        case .advanced: return conditions.isEmpty
        case .topN: return topN.by == nil
        case .relativeDate, .relativeTime: return false
        }
    }
}

// MARK: - Visuals

public enum VisualType: String, Codable, CaseIterable, Sendable {
    // Bar and column
    case stackedBar, clusteredBar, stackedBar100, stackedColumn, clusteredColumn, stackedColumn100
    // Line and area
    case line, area, stackedArea, stackedArea100
    // Combo
    case lineStackedColumn, lineClusteredColumn
    // Ribbon and waterfall
    case ribbon, waterfall
    // Part to whole
    case pie, donut, treemap, funnel
    // Scatter
    case scatter, dotPlot
    // Maps
    case map, filledMap, shapeMap, azureMap
    // Single values
    case card, cardLegacy, multiRowCard, kpi, gauge
    // Tables
    case table, matrix
    // Slicers
    case slicer, buttonSlicer, listSlicer, inputSlicer
    // AI
    case keyInfluencers, decompositionTree, narrative, qna
    // Scheduling, scripted, embedded
    case gantt, pythonVisual, rVisual, paginatedReport, powerApps, powerAutomate, metrics
    // Page elements
    case textBox, image, shape, button, pageNavigator, bookmarkNavigator
    // Facet extras (beyond Power BI's core set)
    case heatmap, histogram, boxPlot, radar, sunburst, sankey, bullet, calendarHeatmap, wordCloud, candlestick

    public var displayName: String {
        switch self {
        case .stackedBar: return "Stacked bar chart"
        case .clusteredBar: return "Clustered bar chart"
        case .stackedBar100: return "100% stacked bar chart"
        case .stackedColumn: return "Stacked column chart"
        case .clusteredColumn: return "Clustered column chart"
        case .stackedColumn100: return "100% stacked column chart"
        case .line: return "Line chart"
        case .area: return "Area chart"
        case .stackedArea: return "Stacked area chart"
        case .stackedArea100: return "100% stacked area chart"
        case .lineStackedColumn: return "Line and stacked column chart"
        case .lineClusteredColumn: return "Line and clustered column chart"
        case .ribbon: return "Ribbon chart"
        case .waterfall: return "Waterfall chart"
        case .pie: return "Pie chart"
        case .donut: return "Donut chart"
        case .treemap: return "Treemap"
        case .funnel: return "Funnel"
        case .scatter: return "Scatter chart"
        case .dotPlot: return "Dot plot"
        case .map: return "Map"
        case .filledMap: return "Filled map"
        case .shapeMap: return "Shape map"
        case .azureMap: return "Maps"
        case .card: return "Card"
        case .cardLegacy: return "Card (classic)"
        case .multiRowCard: return "Multi-row card"
        case .kpi: return "KPI"
        case .gauge: return "Gauge"
        case .table: return "Table"
        case .matrix: return "Matrix"
        case .slicer: return "Slicer"
        case .buttonSlicer: return "Button slicer"
        case .listSlicer: return "List slicer"
        case .inputSlicer: return "Input slicer"
        case .keyInfluencers: return "Key influencers"
        case .decompositionTree: return "Decomposition tree"
        case .narrative: return "Narrative"
        case .qna: return "Q&A"
        case .gantt: return "Gantt chart"
        case .pythonVisual: return "Python visual"
        case .rVisual: return "R visual"
        case .paginatedReport: return "Paginated report"
        case .powerApps: return "Power Apps"
        case .powerAutomate: return "Power Automate"
        case .metrics: return "Metrics"
        case .textBox: return "Text box"
        case .image: return "Image"
        case .shape: return "Shape"
        case .button: return "Button"
        case .pageNavigator: return "Page navigator"
        case .bookmarkNavigator: return "Bookmark navigator"
        case .heatmap: return "Heatmap"
        case .histogram: return "Histogram"
        case .boxPlot: return "Box plot"
        case .radar: return "Radar chart"
        case .sunburst: return "Sunburst"
        case .sankey: return "Sankey diagram"
        case .bullet: return "Bullet chart"
        case .calendarHeatmap: return "Calendar heatmap"
        case .wordCloud: return "Word cloud"
        case .candlestick: return "Candlestick chart"
        }
    }

    /// True for elements that never query data.
    public var isPageElement: Bool {
        switch self { case .textBox, .image, .shape, .button, .pageNavigator, .bookmarkNavigator: return true; default: return false }
    }
    public var isSlicer: Bool {
        switch self { case .slicer, .buttonSlicer, .listSlicer, .inputSlicer: return true; default: return false }
    }

    /// Ordered field wells this visual accepts.
    public var wells: [Well] {
        switch self {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .ribbon:
            return [.category, .values, .legend, .smallMultiples, .tooltips]
        case .lineStackedColumn, .lineClusteredColumn:
            return [.category, .values, .lineValues, .legend, .smallMultiples, .tooltips]
        case .waterfall: return [.category, .breakdown, .values, .tooltips]
        case .pie, .donut: return [.legend, .values, .details, .tooltips]
        case .treemap, .sunburst: return [.category, .details, .values, .tooltips]
        case .funnel, .radar, .wordCloud: return [.category, .values, .tooltips]
        case .scatter: return [.details, .x, .y, .size, .legend, .playAxis, .tooltips]
        case .dotPlot: return [.category, .values, .legend, .size, .tooltips]
        case .map, .azureMap: return [.location, .latitude, .longitude, .legend, .size, .tooltips]
        case .filledMap, .shapeMap: return [.location, .legend, .values, .tooltips]
        case .card, .cardLegacy: return [.values, .category]
        case .multiRowCard: return [.values]
        case .kpi: return [.values, .trendAxis, .target]
        case .gauge, .bullet: return [.values, .minimum, .maximum, .target, .tooltips]
        case .table: return [.values]
        case .matrix, .heatmap: return [.rows, .columns, .values]
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer: return [.field]
        case .keyInfluencers: return [.analyze, .explainBy, .expandBy]
        case .decompositionTree: return [.analyze, .explainBy, .tooltips]
        case .narrative, .qna: return []
        case .gantt: return [.task, .start, .end, .progress, .legend, .tooltips]
        case .pythonVisual, .rVisual: return [.values]
        case .paginatedReport, .powerApps, .powerAutomate, .metrics: return [.values]
        case .textBox, .image, .shape, .button, .pageNavigator, .bookmarkNavigator: return []
        case .histogram, .boxPlot: return [.values, .category, .tooltips]
        case .sankey: return [.source, .destination, .values, .tooltips]
        case .calendarHeatmap: return [.category, .values, .tooltips]
        case .candlestick: return [.category, .open, .high, .low, .close]
        }
    }
}

/// Field-well roles. The raw value is the key used in `VisualSpec.wells` and `VisualData.roles`.
public enum Well: String, Codable, CaseIterable, Sendable {
    case category, values, lineValues, legend, smallMultiples, tooltips, breakdown, details
    case x, y, size, playAxis, location, latitude, longitude
    case trendAxis, target, minimum, maximum, rows, columns, field
    case analyze, explainBy, expandBy, task, start, end, progress, source, destination
    case open, high, low, close

    public var displayName: String {
        switch self {
        case .category: return "Axis"
        case .values: return "Values"
        case .lineValues: return "Line values"
        case .legend: return "Legend"
        case .smallMultiples: return "Small multiples"
        case .tooltips: return "Tooltips"
        case .breakdown: return "Breakdown"
        case .details: return "Details"
        case .x: return "X axis"
        case .y: return "Y axis"
        case .size: return "Size"
        case .playAxis: return "Play axis"
        case .location: return "Location"
        case .latitude: return "Latitude"
        case .longitude: return "Longitude"
        case .trendAxis: return "Trend axis"
        case .target: return "Target"
        case .minimum: return "Minimum"
        case .maximum: return "Maximum"
        case .rows: return "Rows"
        case .columns: return "Columns"
        case .field: return "Field"
        case .analyze: return "Analyze"
        case .explainBy: return "Explain by"
        case .expandBy: return "Expand by"
        case .task: return "Task"
        case .start: return "Start"
        case .end: return "End"
        case .progress: return "Progress"
        case .source: return "Source"
        case .destination: return "Destination"
        case .open: return "Open"
        case .high: return "High"
        case .low: return "Low"
        case .close: return "Close"
        }
    }
    /// Wells whose fields group the data (dimensions); the rest hold aggregated values.
    public var isGrouping: Bool {
        switch self {
        case .category, .legend, .smallMultiples, .breakdown, .details, .playAxis, .location, .trendAxis,
             .rows, .columns, .field, .explainBy, .expandBy, .task, .source, .destination:
            return true
        default: return false
        }
    }
}

public struct Frame: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var rotation: Double = 0
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var cgRect: CGRect { CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height)) }
}

public struct SortSpec: Codable, Hashable, Sendable {
    public var field: FieldRef
    public var descending: Bool
    public init(field: FieldRef, descending: Bool = true) { self.field = field; self.descending = descending }
}

/// A visual calculation: DAX evaluated over the visual's own result grid.
public struct VisualCalculation: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var expression: String
    public var formatString: String = ""
    public var isHidden = false
    public init(name: String, expression: String) { self.name = name; self.expression = expression }
}

/// A line or band added from the Analytics pane.
public struct AnalyticsItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case constantLine, minLine, maxLine, averageLine, medianLine, percentileLine
        case trendLine, forecast, errorBars, anomalies, symmetryShading, ratioLine, clusters
    }
    public var id = UUID()
    public var kind: Kind
    public var name: String = ""
    public var value: Double = 0          // constant value, percentile (0–100), forecast length, sensitivity…
    public var secondaryValue: Double = 95 // confidence %, seasonality, cluster count…
    public var color: String?
    public var style: String = "dashed"
    public var showLabel = true
    public var seriesKey: String?         // limit to one measure
    public init(kind: Kind) { self.kind = kind }
}

/// Conditional formatting rule applied to one property of one field.
public struct ConditionalFormat: Codable, Identifiable, Hashable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable {
        case background, fontColor, dataBars, icons, dataPointColor, webURL, image, title, columnWidth
    }
    public enum Mode: String, Codable, CaseIterable, Sendable { case gradient, rules, fieldValue }
    public struct Rule: Codable, Hashable, Sendable {
        public var op: FilterOperator = .greaterOrEqual
        public var value: Double = 0
        public var upperOp: FilterOperator? = .lessThan
        public var upperValue: Double?
        public var isPercent = false
        public var color: String = "#34C759"
        public var icon: String?
        public init() {}
    }
    public var id = UUID()
    public var target: Target
    public var mode: Mode = .gradient
    /// The field in the visual being formatted (matched by `FieldRef.key`); nil = all values.
    public var appliesToKey: String?
    /// The field whose value drives the format (defaults to the formatted field).
    public var basedOn: FieldRef?
    public var minColor = "#E8F1FB"
    public var midColor: String?
    public var maxColor = "#0A84FF"
    public var minValue: Double?
    public var midValue: Double?
    public var maxValue: Double?
    public var rules: [Rule] = []
    public var negativeColor = "#FF453A"
    public init(target: Target) { self.target = target }
}

public enum InteractionMode: String, Codable, CaseIterable, Sendable { case filter, highlight, none }

public struct SlicerState: Codable, Hashable, Sendable {
    public var selected: [Value] = []
    public var rangeLow: Value = .null
    public var rangeHigh: Value = .null
    public var text: String = ""
    public var relative: RelativeDateFilter?
    /// Selected path values for hierarchy slicers, each entry one level-path.
    public var hierarchyPaths: [[Value]] = []
    public init() {}
    public var isActive: Bool {
        !selected.isEmpty || !rangeLow.isNull || !rangeHigh.isNull || !text.isEmpty || relative != nil || !hierarchyPaths.isEmpty
    }
}

public struct ActionSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case none, back, bookmark, drillthrough, pageNavigation, qna, webURL, applyAllSlicers, clearAllSlicers, dataFunction
    }
    public var kind: Kind = .none
    public var bookmarkID: UUID?
    public var pageID: UUID?
    public var url: String = ""
    public var tooltip: String = ""
    /// DAX measure reference that supplies the destination/URL/tooltip dynamically.
    public var conditionalMeasure: FieldRef?
    /// For `.dataFunction`: name of the user data function / webhook to call.
    public var functionName: String = ""
    public init() {}
}

/// Formatting is a two-level property bag: card → property → value, e.g. format["title"]["text"].
/// Missing keys fall back to the theme's visual defaults, then to renderer defaults.
public typealias FormatBag = [String: [String: JSONValue]]

public struct VisualSpec: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var type: VisualType
    public var name: String
    public var frame: Frame
    public var mobileFrame: Frame?
    public var zIndex = 0
    public var isHidden = false
    public var isLocked = false
    public var groupID: UUID?
    public var tabOrder = 0
    /// Well raw value → fields.
    public var wells: [String: [FieldRef]] = [:]
    public var format: FormatBag = [:]
    public var filters: [FilterSpec] = []
    public var sort: [SortSpec] = []
    public var visualCalculations: [VisualCalculation] = []
    public var analytics: [AnalyticsItem] = []
    public var conditionalFormats: [ConditionalFormat] = []
    public var slicerState: SlicerState?
    /// Slicer sync group name; slicers sharing it stay in step across pages.
    public var syncGroup: String?
    public var action: ActionSpec?
    /// Rich text (Markdown subset) for text boxes; script source for Python/R; prompt for narrative; URL for embeds.
    public var content: String = ""
    /// Embedded image bytes (base64) for image visuals and button icons.
    public var imageData: Data?
    /// Current drill depth on the category hierarchy and the drilled-into path.
    public var drillLevel = 0
    public var drillPath: [Value] = []
    public var expandedAllLevels = false
    /// Matrix: expanded row/column header paths (joined by "\u{1F}").
    public var expandedPaths: [String] = []
    public var altText: String = ""
    /// Report page tooltip to show on hover, when set.
    public var tooltipPageID: UUID?
    /// Formatting that applies only in the phone layout, layered over `format` (card → property → value).
    public var mobileFormat: FormatBag?

    public init(type: VisualType, frame: Frame, name: String? = nil) {
        self.type = type; self.frame = frame; self.name = name ?? type.displayName
    }

    public func fields(_ well: Well) -> [FieldRef] { wells[well.rawValue] ?? [] }
    public mutating func setFields(_ well: Well, _ fields: [FieldRef]) {
        wells[well.rawValue] = fields.isEmpty ? nil : fields
    }
    public var allFields: [FieldRef] { type.wells.flatMap { fields($0) } }

    // Format accessors
    public func fmt(_ card: String, _ key: String) -> JSONValue? { format[card]?[key] }
    public func fmtBool(_ card: String, _ key: String, _ fallback: Bool) -> Bool { fmt(card, key)?.boolValue ?? fallback }
    public func fmtDouble(_ card: String, _ key: String, _ fallback: Double) -> Double { fmt(card, key)?.doubleValue ?? fallback }
    public func fmtString(_ card: String, _ key: String, _ fallback: String) -> String { fmt(card, key)?.stringValue ?? fallback }
    public mutating func setFmt(_ card: String, _ key: String, _ value: JSONValue?) {
        var c = format[card] ?? [:]
        c[key] = value
        format[card] = c.isEmpty ? nil : c
    }
}

/// Query result handed to a visual renderer: a table plus which columns play which role.
public struct VisualData: Sendable {
    public var table: DataTable
    /// Well raw value → column indices in `table`, in well order.
    public var roles: [String: [Int]]
    /// The field behind each column (nil for visual calculations).
    public var fields: [FieldRef?]
    /// Format string per column.
    public var formats: [String]
    /// Grand totals for aggregate columns (null for grouping columns), when computable.
    public var totals: [Value]
    /// Same shape as `table` but evaluated without cross-highlight selection, when highlighting is active.
    public var baseline: DataTable?
    public var error: String?
    public var queryMilliseconds: Double = 0
    /// The DAX query that produced this data (for Performance Analyzer / copy query).
    public var daxQuery: String = ""
    /// The title a measure supplies (a `.title` conditional format), evaluated under the visual's filters.
    public var dynamicTitle: String?

    public init(table: DataTable = DataTable(), roles: [String: [Int]] = [:], fields: [FieldRef?] = [],
                formats: [String] = [], totals: [Value] = [], error: String? = nil) {
        self.table = table; self.roles = roles; self.fields = fields; self.formats = formats
        self.totals = totals; self.error = error
    }
    public func indices(_ well: Well) -> [Int] { roles[well.rawValue] ?? [] }
    public func column(_ well: Well, _ n: Int = 0) -> DataColumn? {
        indices(well)[safe: n].map { table.columns[$0] }
    }
    public var isEmpty: Bool { table.rowCount == 0 }
    public func formatted(row: Int, col: Int) -> String {
        ValueFormatter.format(table[row, col], formats[safe: col] ?? "")
    }
}

// MARK: - Pages, bookmarks, report

public struct PageSize: Codable, Hashable, Sendable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static let widescreen = PageSize(width: 1280, height: 720)
    public static let standard = PageSize(width: 960, height: 720)
    public static let letter = PageSize(width: 816, height: 1056)
    public static let tooltip = PageSize(width: 320, height: 240)
    public static let phone = PageSize(width: 360, height: 640)
}

public struct BackgroundSpec: Codable, Hashable, Sendable {
    public var color: String?
    public var transparency: Double = 0
    public var imageData: Data?
    public var imageFit: String = "fit"
    public init() {}
}

public struct PageRefreshSpec: Codable, Hashable, Sendable {
    public var isEnabled = false
    public var intervalSeconds: Double = 30
    /// Change-detection measure; refresh only when its value changes.
    public var changeDetectionMeasure: FieldRef?
    public init() {}
}

public struct Page: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var size: PageSize = .widescreen
    public var background = BackgroundSpec()
    public var wallpaper = BackgroundSpec()
    public var visuals: [VisualSpec] = []
    public var filters: [FilterSpec] = []
    public var isHidden = false
    public var isTooltipPage = false
    public var isDrillthroughPage: Bool { !drillthroughFilters.isEmpty }
    public var drillthroughFilters: [FilterSpec] = []
    public var keepAllFiltersOnDrillthrough = true
    public var allowCrossReportDrillthrough = false
    public var hasMobileLayout = false
    public var autoRefresh = PageRefreshSpec()
    /// Source visual id → target visual id → interaction. Missing entries use the report default.
    public var interactions: [UUID: [UUID: InteractionMode]] = [:]
    /// Named visual groups (id → name) for the Selection pane.
    public var groups: [UUID: String] = [:]
    /// Tooltip pages: the fields this page is the tooltip for. A visual left on the automatic tooltip
    /// shows this page when it uses one of them.
    public var tooltipFields: [FieldRef]?

    public init(name: String) { self.name = name }
    public func visual(_ id: UUID) -> VisualSpec? { visuals.first { $0.id == id } }
}

public struct BookmarkState: Codable, Hashable, Sendable {
    public var slicerStates: [UUID: SlicerState] = [:]
    public var pageFilters: [FilterSpec] = []
    public var reportFilters: [FilterSpec] = []
    public var visualFilters: [UUID: [FilterSpec]] = [:]
    public var hiddenVisuals: [UUID] = []
    public var sorts: [UUID: [SortSpec]] = [:]
    public var drillLevels: [UUID: Int] = [:]
    public var drillPaths: [UUID: [Value]] = [:]
    /// Cross-filter selections at capture time: visual id → selected category keys.
    public var selections: [UUID: [[Value]]] = [:]
    public init() {}
}

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var group: String = ""
    public var pageID: UUID
    public var appliesData = true
    public var appliesDisplay = true
    public var appliesCurrentPage = true
    /// nil = all visuals; otherwise only these.
    public var selectedVisualIDs: [UUID]?
    public var state = BookmarkState()
    public init(name: String, pageID: UUID) { self.name = name; self.pageID = pageID }
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var fontFamily: String = ""
    public var size: Double
    public var weight: String = "regular"
    public var color: String?
    public init(size: Double, weight: String = "regular") { self.size = size; self.weight = weight }
}

public struct ThemeSpec: Codable, Hashable, Sendable {
    public var name: String
    public var dataColors: [String]
    public var background: String = "#FFFFFF"
    public var foreground: String = "#1D1D1F"
    public var secondaryForeground: String = "#6E6E73"
    public var cardBackground: String = "#FFFFFF"
    public var gridline: String = "#E5E5EA"
    public var accent: String = "#0A84FF"
    public var good: String = "#34C759"
    public var neutral: String = "#FF9F0A"
    public var bad: String = "#FF453A"
    public var minimum: String = "#DCEBFF"
    public var center: String = "#7AB8FF"
    public var maximum: String = "#0A84FF"
    public var title = TextStyle(size: 14, weight: "semibold")
    public var label = TextStyle(size: 11)
    public var callout = TextStyle(size: 34, weight: "semibold")
    public var header = TextStyle(size: 12, weight: "medium")
    public var cornerRadius: Double = 10
    public var visualPadding: Double = 12
    public var isDark = false
    public var isHighContrast = false
    /// Per-visual-type default format bags, keyed by `VisualType.rawValue` or "*" for all.
    public var visualDefaults: [String: FormatBag] = [:]
    public var defaultPageSize: PageSize?

    public init(name: String, dataColors: [String]) { self.name = name; self.dataColors = dataColors }

    public static let facet = ThemeSpec(name: "Facet", dataColors: [
        "#0A84FF", "#5E5CE6", "#30B0C7", "#34C759", "#FF9F0A", "#FF375F", "#AC8E68", "#64D2FF", "#BF5AF2", "#8E8E93",
    ])
    public static let graphite: ThemeSpec = {
        var t = ThemeSpec(name: "Graphite", dataColors: ["#1D1D1F", "#48484A", "#6E6E73", "#8E8E93", "#AEAEB2", "#C7C7CC", "#0A84FF", "#D1D1D6"])
        t.accent = "#1D1D1F"; t.maximum = "#1D1D1F"; t.center = "#8E8E93"; t.minimum = "#E5E5EA"
        return t
    }()
    public static let midnight: ThemeSpec = {
        var t = ThemeSpec(name: "Midnight", dataColors: ["#0A84FF", "#5E5CE6", "#64D2FF", "#30D158", "#FFD60A", "#FF375F", "#BF5AF2", "#FF9F0A", "#AC8E68", "#98989D"])
        t.background = "#1C1C1E"; t.cardBackground = "#2C2C2E"; t.foreground = "#F5F5F7"; t.secondaryForeground = "#98989D"
        t.gridline = "#3A3A3C"; t.isDark = true; t.minimum = "#12304F"
        return t
    }()
    public static let sunrise = ThemeSpec(name: "Sunrise", dataColors: ["#FF6B35", "#F7B801", "#F18701", "#7678ED", "#3D348B", "#2EC4B6", "#E71D36", "#8D99AE"])
    public static let meadow = ThemeSpec(name: "Meadow", dataColors: ["#2D6A4F", "#52B788", "#95D5B2", "#1B4332", "#D4A373", "#E9C46A", "#264653", "#B7B7A4"])
    /// Colour-blind-safe palette (Okabe–Ito).
    public static let accessible = ThemeSpec(name: "Accessible", dataColors: ["#0072B2", "#E69F00", "#009E73", "#CC79A7", "#56B4E9", "#D55E00", "#F0E442", "#000000"])
    public static let highContrast: ThemeSpec = {
        var t = ThemeSpec(name: "High contrast", dataColors: ["#FFFFFF", "#FFFF00", "#00FFFF", "#00FF00", "#FF00FF", "#FF8000", "#8080FF", "#FF4040"])
        t.background = "#000000"; t.cardBackground = "#000000"; t.foreground = "#FFFFFF"; t.secondaryForeground = "#FFFFFF"
        t.gridline = "#FFFFFF"; t.accent = "#FFFF00"; t.isDark = true; t.isHighContrast = true
        return t
    }()
    public static let builtIn: [ThemeSpec] = [.facet, .graphite, .midnight, .sunrise, .meadow, .accessible, .highContrast]
}

public struct DAXQueryTab: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var text: String
    public init(name: String, text: String = "EVALUATE\n\t") { self.name = name; self.text = text }
}

public struct ReportSettings: Codable, Hashable, Sendable {
    public var persistentFilters = true
    public var defaultInteraction: InteractionMode = .highlight
    public var allowExportData = "summarized" // "none", "summarized", "underlying"
    public var allowPersonalizeVisuals = false
    public var allowChangeFilterTypes = true
    public var modernTooltips = true
    public var crossReportDrillthrough = false
    public var hideVisualHeaders = false
    public var filterPaneApplyButton = false
    public var slicerApplyButtons = false
    public var disableCrossHighlightByDefault = false
    public var filterPaneVisibleToReaders = true
    public var sensitivityLabel: String = ""
    public var language: String = "en-US"
    public init() {}
}

public struct Report: Codable, Sendable {
    public var pages: [Page] = [Page(name: "Page 1")]
    public var theme: ThemeSpec = .facet
    public var bookmarks: [Bookmark] = []
    public var filters: [FilterSpec] = []
    public var settings = ReportSettings()
    public var landingPageID: UUID?
    public var daxQueries: [DAXQueryTab] = [DAXQueryTab(name: "Query 1")]
    public init() {}
    public func page(_ id: UUID) -> Page? { pages.first { $0.id == id } }
}

/// The whole document: what a `.facet` package stores.
public struct FacetDocument: Sendable {
    public var model = SemanticModel()
    public var report = Report()
    public var queries: [QueryDefinition] = []
    public var dataSources: [DataSourceRecord] = []
    public var data = DataStore()
    public init() {}
}
