import Foundation
import FacetCore

/// What a column of nested values holds, for the Expand and Aggregate dialogs of the Power Query Editor.
public struct StructuredColumnInfo: Sendable, Equatable {
    /// "Table", "Record" or "List": the kind most of the sampled cells have.
    public var kind: String
    /// Column names (tables) or field names (records) across the sampled cells of that kind, in first-seen order;
    /// empty for lists.
    public var fields: [String]
    public init(kind: String, fields: [String]) { self.kind = kind; self.fields = fields }
}

public extension QueryEngine {
    /// The nested values of `column` in a query (or step `upToStep`), sampled over its first `sampleRows` cells that
    /// are not null (error cells are skipped). Nil when the sample holds no table, record or list. Throws when the
    /// step is not a table or has no such column.
    func structuredColumn(_ column: String, of query: String, upToStep: Int? = nil, sampleRows: Int = 1000) async throws -> StructuredColumnInfo? {
        try await onWorker {
            let session = self.makeSession(overrides: [:])
            let value = try session.value(of: query, upToStep: upToStep)
            guard case .table(let table) = value else { throw QueryEngineError.notATable(query, value.typeName) }
            let index = try table.requireColumn(column)
            // A lazy (folded) table is read only as far as the sample; in-memory tables are scanned until it is full.
            let cells = table.isLazy ? (try table.columns(limit: sampleRows))[safe: index] ?? [] : (try table.columns)[index]
            return QueryEngine.structuredInfo(cells, sampleRows: sampleRows)
        }
    }

    static func structuredInfo(_ cells: [MValue], sampleRows: Int) -> StructuredColumnInfo? {
        var sampled = 0
        var counts: [String: Int] = [:], order: [String] = []
        var fields: [String: [String]] = [:], seen: [String: Set<String>] = [:]
        for raw in cells {
            guard sampled < max(1, sampleRows) else { break }
            let cell = raw.forcedCell()
            if cell.isNull || cell.isError { continue }
            sampled += 1
            let kind: String, names: [String]
            switch cell {
            case .table(let t): kind = "Table"; names = t.columnNames
            case .record(let r): kind = "Record"; names = r.names
            case .list: kind = "List"; names = []
            default: continue
            }
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
            for n in names where seen[kind, default: []].insert(n).inserted { fields[kind, default: []].append(n) }
        }
        guard let top = counts.values.max(), let kind = order.first(where: { counts[$0] == top }) else { return nil }
        return StructuredColumnInfo(kind: kind, fields: fields[kind] ?? [])
    }
}
