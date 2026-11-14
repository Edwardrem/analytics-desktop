import Foundation
import FacetCore
import FacetQuery

/// Pure decisions behind the Power Query Editor: reconciling the editor's pending queries with the document,
/// what Close & Apply changes in the model, query and column naming, and column reordering.
enum QueryEditorPlans {
    // MARK: Reconciling with the document

    /// Three-way merge of the editor's pending queries (`local`) with the document's (`remote`), both descended
    /// from `base` (the document's queries when the editor last synchronised). Queries are matched by id.
    /// A query edited only in the document takes the document's version; one edited in the editor keeps the
    /// editor's; queries added on either side are kept; a query deleted on one side and unchanged on the other is
    /// deleted. Order: the editor's, then queries the document added.
    static func merge(base: [QueryDefinition], local: [QueryDefinition], remote: [QueryDefinition]) -> [QueryDefinition] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localIDs = Set(local.map(\.id))
        var out: [QueryDefinition] = []
        for q in local {
            guard let b = baseByID[q.id] else { out.append(q); continue }
            if let r = remoteByID[q.id] {
                out.append(q == b && r != b ? r : q)
            } else if q != b {
                out.append(q)
            }
        }
        for r in remote where !localIDs.contains(r.id) && baseByID[r.id] == nil { out.append(r) }
        return out
    }

    // MARK: Close & Apply

    /// What applying the editor's queries does to the document.
    struct ApplyPlan: Equatable {
        /// Model tables to rename because their query was renamed (old → new), in order.
        var renames: [Rename] = []
        /// Model tables to delete: their query was deleted, its load disabled, or it is no longer a table query.
        var removedTables: [String] = []
        /// Queries to refresh into the model afterwards (by their new names).
        var refresh: [String] = []
        struct Rename: Equatable { var from: String; var to: String }
    }

    /// `loadedTables`: model tables that come from a query (table name → source query name). The model table
    /// of a renamed query is renamed only when it carries the query's name (a table renamed in the model keeps its name).
    static func applyPlan(before: [QueryDefinition], after: [QueryDefinition], loadedTables: [String: String]) -> ApplyPlan {
        var plan = ApplyPlan()
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// The model table loaded from a query, by the query's name.
        func table(of query: String) -> String? {
            loadedTables.filter { $0.value == query }.keys.min()
        }
        func loads(_ q: QueryDefinition) -> Bool { q.loadEnabled && q.kind == .table }

        for old in before {
            guard let tableName = table(of: old.name) else { continue }
            guard let new = afterByID[old.id], loads(new) else { plan.removedTables.append(tableName); continue }
            if new.name != old.name, tableName == old.name { plan.renames.append(.init(from: old.name, to: new.name)) }
        }
        // Changed queries (script, kind or parameter value) and everything that depends on them.
        var changed = Set<String>()
        for q in after {
            guard let old = beforeByID[q.id] else { changed.insert(q.name); continue }
            if old.mScript != q.mScript || old.kind != q.kind || old.parameter != q.parameter || (!old.loadEnabled && q.loadEnabled) {
                changed.insert(q.name)
            }
        }
        let graph = QueryDependencyGraph(queries: after)
        let removed = Set(plan.removedTables)
        for q in after where loads(q) {
            let hasTable = table(of: beforeByID[q.id]?.name ?? q.name).map { !removed.contains($0) } ?? false
            let affected = changed.contains(q.name) || !graph.transitiveDependencies(of: q.name).isDisjoint(with: changed)
            if affected || !hasTable { plan.refresh.append(q.name) }
        }
        return plan
    }

    // MARK: Names

    /// "Query1", "Query2", … — the first name Power Query would give a new query.
    static func newQueryName(_ base: String = "Query", taken: Set<String>) -> String {
        var k = 1
        while taken.contains("\(base)\(k)") { k += 1 }
        return "\(base)\(k)"
    }

    /// A column name not in `taken`: `base`, then `base.1`, `base.2`, … (Power Query's suffixing for new columns).
    static func uniqueColumnName(_ base: String, taken: [String]) -> String {
        let set = Set(taken)
        if !set.contains(base) { return base }
        var k = 1
        while set.contains("\(base).\(k)") { k += 1 }
        return "\(base).\(k)"
    }

    /// Why a query cannot take a name (nil when it can): empty, used by another query, or used by a model table
    /// that does not belong to this query.
    static func queryNameProblem(_ name: String, for id: UUID, queries: [QueryDefinition], modelTables: [String: String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A query needs a name." }
        let current = queries.first { $0.id == id }?.name
        if queries.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A query named “\(trimmed)” already exists."
        }
        if let owner = modelTables.first(where: { $0.key.caseInsensitiveCompare(trimmed) == .orderedSame }), owner.value != current {
            return "The model already has a table named “\(owner.key)”."
        }
        return nil
    }

    /// Queries (other than `name` itself) whose scripts reference `name`.
    static func dependents(of name: String, in queries: [QueryDefinition]) -> [String] {
        QueryDependencyGraph(queries: queries).dependents[name] ?? []
    }

    // MARK: Columns

    enum Move { case left, right, toBeginning, toEnd }

    /// The column order after moving the selected columns (kept in their current relative order).
    static func movedColumns(_ all: [String], selected: [String], _ move: Move) -> [String] {
        let chosen = Set(selected)
        let picked = all.filter(chosen.contains)
        guard !picked.isEmpty else { return all }
        let rest = all.filter { !chosen.contains($0) }
        switch move {
        case .toBeginning: return picked + rest
        case .toEnd: return rest + picked
        case .left, .right:
            guard let first = all.firstIndex(where: chosen.contains) else { return all }
            // The block moves past one unselected neighbour.
            let before = all[..<first].filter { !chosen.contains($0) }.count
            let target = move == .left ? max(0, before - 1) : min(rest.count, before + 1)
            var out = rest
            out.insert(contentsOf: picked, at: target)
            return out
        }
    }

    /// The selection after a click on a column header: plain click selects one column, ⌘ toggles one,
    /// ⇧ extends from the last selected column to the clicked one.
    static func select(_ column: String, in all: [String], current: [String], toggle: Bool, range: Bool) -> [String] {
        if range, let anchor = current.last, let a = all.firstIndex(of: anchor), let b = all.firstIndex(of: column) {
            let span = Array(all[min(a, b)...max(a, b)])
            return current.filter { !span.contains($0) } + span
        }
        if toggle {
            return current.contains(column) ? current.filter { $0 != column } : current + [column]
        }
        return [column]
    }
}
