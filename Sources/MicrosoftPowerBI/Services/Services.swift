import Foundation
import FacetCore

// The app talks to the engines through these small protocols. `Bridge/` supplies the
// live implementations (FacetDAX, FacetQuery, FacetAnalytics…); keeping the seam narrow
// keeps the UI honest about what it needs.

/// Everything a visual query needs beyond the visual itself.
struct VisualRequest {
    struct Slicer {
        var fields: [FieldRef]; var state: SlicerState; var type: VisualType
        /// An input slicer's operator (`format["slicer"]["operator"]`): how its terms match values.
        var matchOperator = "contains"
    }
    var filters: [FilterSpec] = []
    var slicers: [Slicer] = []
    var crossFilters: [[DataPointSelection]] = []
    var highlights: [[DataPointSelection]] = []
    var rowLimit = 30_000
}

enum ExpressionKind { case measure, calculatedColumn, calculatedTable, query, rowFilter, visualCalculation }

struct ExpressionIssue: Identifiable, Hashable {
    var id = UUID()
    var message: String
    /// Character range in the expression, when known.
    var range: Range<Int>?
    var isWarning = false
}

/// The calculation engine (DAX) loaded with one model + its data. Not thread-safe:
/// `DocumentStore` confines every call to its calculation queue.
protocol CalculationService: AnyObject {
    /// Load the model and compute calculated tables/columns. Returns object name → error message.
    func load(model: SemanticModel, data: DataStore, roles: [String], userName: String) -> [String: String]
    /// Source data plus computed objects.
    var data: DataStore { get }
    func visualData(spec: VisualSpec, request: VisualRequest) -> VisualData
    func distinctValues(field: FieldRef, filters: [FilterSpec], limit: Int) -> [Value]
    func query(_ dax: String) throws -> [DataTable]
    func scalar(_ expression: String, filters: [FilterSpec]) throws -> Value
    func check(_ expression: String, kind: ExpressionKind, homeTable: String?) -> [ExpressionIssue]
    /// The rows of a model table that a visual's filters, slicers and cross-filters leave, for
    /// visuals that analyse rows rather than a grouped query (Key influencers).
    func rows(of table: String, request: VisualRequest) throws -> DataTable
}

extension CalculationService {
    func rows(of table: String, request: VisualRequest) throws -> DataTable {
        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This calculation engine can't list a table's filtered rows."])
    }
}

/// Analytics-pane computations layered on a visual's query result.
protocol AnalyticsService: AnyObject {
    func overlays(spec: VisualSpec, data: VisualData) -> AnalyticsOverlays
}

struct RefreshProgress { var query: String; var message: String; var fraction: Double }

/// Power Query: evaluates the document's queries into tables.
protocol QueryService: AnyObject {
    func refresh(queries: [QueryDefinition], only: [String]?, baseDirectory: URL?,
                 progress: @escaping (RefreshProgress) -> Void) async -> [String: Result<DataTable, Error>]
}

/// The set of services a document uses. Created by `Bridge/LiveServices.swift`.
struct Services {
    var makeCalculation: () -> CalculationService
    var analytics: AnalyticsService
    var query: QueryService
}
