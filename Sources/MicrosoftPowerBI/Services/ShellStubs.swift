#if FACET_SHELL_ONLY
// Type-check-only stand-ins used while the engines are being built. Never compiled into the app.
import Foundation
import FacetCore

final class StubCalculation: CalculationService {
    var data = DataStore()
    func load(model: SemanticModel, data: DataStore, roles: [String], userName: String) -> [String: String] { self.data = data; return [:] }
    func visualData(spec: VisualSpec, request: VisualRequest) -> VisualData { VisualData() }
    func distinctValues(field: FieldRef, filters: [FilterSpec], limit: Int) -> [Value] { [] }
    func query(_ dax: String) throws -> [DataTable] { [] }
    func scalar(_ expression: String, filters: [FilterSpec]) throws -> Value { .null }
    func check(_ expression: String, kind: ExpressionKind, homeTable: String?) -> [ExpressionIssue] { [] }
}
final class StubAnalytics: AnalyticsService {
    func overlays(spec: VisualSpec, data: VisualData) -> AnalyticsOverlays { AnalyticsOverlays() }
}
final class StubQuery: QueryService {
    func refresh(queries: [QueryDefinition], only: [String]?, baseDirectory: URL?,
                 progress: @escaping (RefreshProgress) -> Void) async -> [String: Result<DataTable, Error>] { [:] }
}
extension Services {
    static func live() -> Services {
        Services(makeCalculation: { StubCalculation() }, analytics: StubAnalytics(), query: StubQuery())
    }
}
#endif
