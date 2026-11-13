import Foundation
import FacetCore

/// Progress notification during `QueryEngine.refreshAll`.
public struct QueryProgress: Sendable {
    public enum Phase: Sendable {
        case started
        case finished(rows: Int, seconds: Double)
        case failed(message: String, seconds: Double)
    }
    public var query: String
    public var phase: Phase
    /// Number of queries finished so far / total to refresh.
    public var completed: Int
    public var total: Int
}

/// A data source an evaluation read: `kind` is "File", "Folder", "SQLite", "Web" or "OData"; `location` a path or `scheme://host`.
public struct QueryDataSource: Hashable, Sendable {
    public var kind: String
    public var location: String
    public init(kind: String, location: String) { self.kind = kind; self.location = location }
}

/// Whether a step is pushed down to the data source.
public enum FoldingIndicator: String, Sendable {
    /// The step is evaluated by the source (a native query exists).
    case folded
    /// The step runs locally in Facet's engine.
    case notFolded
    /// The step's value is not a table or does not come from a foldable source.
    case notApplicable
    /// The step was not evaluated (it is not needed for the result).
    case notEvaluated
}

/// One recorded event of the last evaluation: a step (let binding) of a query was evaluated.
public struct QueryDiagnosticEvent: Sendable {
    public var query: String
    public var step: String
    /// Wall-clock seconds spent evaluating the step, including the steps it forced.
    public var seconds: Double
    /// Seconds excluding time spent in other observed steps.
    public var exclusiveSeconds: Double
    /// Row count when the step produced an in-memory table (nil for folded/lazy tables and non-tables).
    public var rowCount: Int?
    public var folding: FoldingIndicator
    /// The native query for folded steps ("View native query").
    public var nativeQuery: String?
    public var error: String?
    /// M type name of the step's value ("table", "list", "number", …).
    public var valueKind: String
}

/// Folding state of one applied step.
public struct StepFoldingInfo: Sendable {
    public var step: String
    public var indicator: FoldingIndicator
    public var nativeQuery: String?
}

/// A preview of a query step: the data plus what `DataTable` cannot represent (cell errors, nested values).
public struct QueryPreview: Sendable {
    public var table: DataTable
    /// M column types (richer than `DataTable` types: `Int64.Type`, nullable, nested table types…).
    public var columnTypes: [MType]
    /// column index → row index → error message, for cells holding an error.
    public var cellErrors: [Int: [Int: String]]
    /// column index → row index → kind ("Table", "List", "Record", "Binary", "Function") for structured cells.
    public var structuredCells: [Int: [Int: String]]
    /// M type name of the step value ("table", "list", "record", "number", …) before conversion to a table.
    public var valueKind: String
    /// True when more rows exist than `rowLimit` returned (unknown for folded sources → false).
    public var isTruncated: Bool
}

/// Errors raised by the engine itself (as opposed to M evaluation errors, which are `MError`).
public enum QueryEngineError: LocalizedError {
    case unknownQuery(String)
    case cyclicReference([String])
    case incrementalRefreshNotConfigured(String)
    case notATable(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownQuery(let n): return "The query '\(n)' doesn't exist."
        case .cyclicReference(let path): return "A cyclic reference was found between queries: \(path.joined(separator: " → "))."
        case .incrementalRefreshNotConfigured(let n):
            return "Incremental refresh needs the query '\(n)' to filter its date column with the RangeStart and RangeEnd parameters "
                + "(for example Table.SelectRows(Source, each [Date] >= RangeStart and [Date] < RangeEnd))."
        case .notATable(let n, let kind): return "The query '\(n)' returns a \(kind), not a table."
        }
    }
}

/// The dependency graph between queries ("Query dependencies" view).
public struct QueryDependencyGraph: Sendable {
    /// query → queries it references (only names of existing queries; no self references).
    public let dependencies: [String: [String]]
    public let names: [String]

    public init(queries: [QueryDefinition]) {
        let all = queries.map(\.name)
        let set = Set(all)
        var deps: [String: [String]] = [:]
        for q in queries {
            deps[q.name] = MScript.referencedIdentifiers(in: q.mScript).filter { set.contains($0) && $0 != q.name }
        }
        dependencies = deps; names = all
    }

    /// query → queries that reference it.
    public var dependents: [String: [String]] {
        var out: [String: [String]] = [:]
        for n in names { out[n] = [] }
        for n in names { for d in dependencies[n] ?? [] { out[d, default: []].append(n) } }
        return out
    }
    /// Every query `name` depends on, directly or indirectly.
    public func transitiveDependencies(of name: String) -> Set<String> {
        var seen = Set<String>(), stack = dependencies[name] ?? []
        while let n = stack.popLast() { if seen.insert(n).inserted { stack.append(contentsOf: dependencies[n] ?? []) } }
        return seen
    }
    /// Groups of queries that can be evaluated in parallel; each level depends only on earlier levels.
    /// Queries on a cycle are placed in a final level (they fail at evaluation with a cyclic-reference error).
    public func levels() -> [[String]] {
        var remaining = Set(names), done = Set<String>(), out: [[String]] = []
        while !remaining.isEmpty {
            let ready = names.filter { remaining.contains($0) && (dependencies[$0] ?? []).allSatisfy(done.contains) }
            if ready.isEmpty { out.append(names.filter(remaining.contains)); break }
            out.append(ready)
            done.formUnion(ready); remaining.subtract(ready)
        }
        return out
    }
    /// A dependency-respecting evaluation order.
    public func topologicalOrder() -> [String] { levels().flatMap { $0 } }
    /// A cycle, if one exists (as a path of query names).
    public func findCycle() -> [String]? {
        var state: [String: Int] = [:], path: [String] = []
        func visit(_ n: String) -> [String]? {
            if state[n] == 1 { return Array(path[(path.firstIndex(of: n) ?? 0)...]) + [n] }
            if state[n] == 2 { return nil }
            state[n] = 1; path.append(n)
            for d in dependencies[n] ?? [] { if let c = visit(d) { return c } }
            path.removeLast(); state[n] = 2
            return nil
        }
        for n in names { if let c = visit(n) { return c } }
        return nil
    }
}

/// A DirectQuery handle for one query: nothing is cached; every fetch re-runs the query against the source.
///
/// What DirectQuery supports in Facet: any query can be fetched this way, but only steps that fold are executed by the
/// source. Folding is implemented for SQLite and the command-line SQL sources (PostgreSQL, MySQL, SQL Server, ODBC) and
/// covers `Table.SelectRows` (comparisons, and/or/not, null tests, text starts/ends/contains, IN lists, parameters),
/// `Table.SelectColumns` / `Table.RemoveColumns`, `Table.FirstN`, `Table.Skip`, `Table.Sort`, `Table.Distinct`,
/// `Table.RowCount` and `Value.NativeQuery` with `[EnableFolding = true]`. Any other step makes the remainder of the
/// query run locally on the rows the folded prefix returns. View-time filters/sorts/top-N passed to `fetch(applying:)`
/// are appended as steps, so they fold too when the query is still folded at its last step.
public protocol DirectQuerySource: AnyObject, Sendable {
    var queryName: String { get }
    /// The native query the source would receive for the unmodified query (nil when the last step is not folded).
    func nativeQuery() async throws -> String?
    /// Run the query now. `rowLimit` is pushed to the source when the query is folded.
    func fetch(rowLimit: Int?) async throws -> DataTable
    /// Run the query with extra view-time steps (filters, sorts, column selection, top N).
    func fetch(applying transforms: [Transform], rowLimit: Int?) async throws -> DataTable
    /// The native query for the query plus view-time steps.
    func nativeQuery(applying transforms: [Transform]) async throws -> String?
}
