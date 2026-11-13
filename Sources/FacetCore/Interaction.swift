import Foundation

/// One selected data point in a visual: the grouping fields and their values.
/// Used for cross-filtering, cross-highlighting, drill, drillthrough and bookmarks.
public struct DataPointSelection: Codable, Hashable, Sendable {
    public var fields: [FieldRef]
    public var values: [Value]
    public init(fields: [FieldRef], values: [Value]) { self.fields = fields; self.values = values }
    /// Identity that ignores FieldRef ids.
    public var key: String { zip(fields, values).map { "\($0.key)=\($1.asString)" }.joined(separator: "\u{1F}") }
}

public enum DrillAction: Sendable {
    /// Drill into one data point (nil = "go to next level" for all).
    case down(DataPointSelection?)
    case up
    case expandAll
    case drillthrough(DataPointSelection, pageID: UUID?)
    case showAsTable
}

/// Results of Analytics-pane computations, produced by the app (FacetAnalytics) and drawn by visuals.
public struct AnalyticsOverlays: Sendable {
    public struct Forecast: Sendable {
        /// Value column the forecast extends.
        public var seriesColumn: Int
        /// Future axis labels and the predicted values with confidence band.
        public var labels: [Value]
        public var values: [Double]
        public var lower: [Double]
        public var upper: [Double]
        public init(seriesColumn: Int, labels: [Value], values: [Double], lower: [Double], upper: [Double]) {
            self.seriesColumn = seriesColumn; self.labels = labels; self.values = values; self.lower = lower; self.upper = upper
        }
    }
    public struct Anomaly: Sendable {
        public var seriesColumn: Int
        public var row: Int
        public var expected: Double
        public var lower: Double
        public var upper: Double
        public var explanation: String
        public init(seriesColumn: Int, row: Int, expected: Double, lower: Double, upper: Double, explanation: String = "") {
            self.seriesColumn = seriesColumn; self.row = row; self.expected = expected; self.lower = lower; self.upper = upper
            self.explanation = explanation
        }
    }
    public var forecasts: [Forecast] = []
    public var anomalies: [Anomaly] = []
    /// Expected-range band per row for anomaly detection: seriesColumn → (lower, upper) per row.
    public var expectedBands: [Int: [(lower: Double, upper: Double)]] = [:]
    /// Cluster index per row (scatter / table clustering), when computed.
    public var clusters: [Int]?
    public init() {}
}
