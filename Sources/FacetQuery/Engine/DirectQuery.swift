import Foundation
import FacetCore

/// `DirectQuerySource` backed by a `QueryEngine`: every fetch re-evaluates the query; view-time transforms are
/// appended as steps so they fold whenever the query is still folded at its last step.
final class EngineDirectQuery: DirectQuerySource, @unchecked Sendable {
    let queryName: String
    private let base: QueryEngine

    init(engine: QueryEngine, queryName: String) { self.base = engine; self.queryName = queryName }

    private func engine(applying transforms: [Transform]) -> QueryEngine {
        let queries = base.queries.map { q -> QueryDefinition in
            guard q.name == queryName, !transforms.isEmpty else { return q }
            var copy = q
            copy.mScript = transforms.reduce(q.mScript) { MScript.appending($1, to: $0) }
            return copy
        }
        let e = QueryEngine(queries: queries, environment: base.environment)
        e.parameterOverrides = base.parameterOverrides
        return e
    }
    func nativeQuery() async throws -> String? { try await base.nativeQuery(for: queryName) }
    func fetch(rowLimit: Int?) async throws -> DataTable { try await base.evaluate(queryName, rowLimit: rowLimit) }
    func fetch(applying transforms: [Transform], rowLimit: Int?) async throws -> DataTable {
        try await engine(applying: transforms).evaluate(queryName, rowLimit: rowLimit)
    }
    func nativeQuery(applying transforms: [Transform]) async throws -> String? {
        try await engine(applying: transforms).nativeQuery(for: queryName)
    }
}

public extension QueryEngine {
    /// A DirectQuery handle for a query (nothing is cached; see `DirectQuerySource`).
    func directQuery(_ name: String) throws -> DirectQuerySource {
        guard queries.contains(where: { $0.name == name }) else { throw QueryEngineError.unknownQuery(name) }
        return EngineDirectQuery(engine: self, queryName: name)
    }
}
