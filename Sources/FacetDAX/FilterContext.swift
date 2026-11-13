import Foundation
import FacetCore

/// One filter of a filter context. Immutable; caches the row selections it induces on each table.
final class CtxFilter {
    enum Kind {
        /// Allowed values of one column.
        case values(ColumnID, Set<Value>)
        /// Allowed combinations over several columns (possibly of several tables).
        case tuples([ColumnID], Set<[Value]>)
        /// An explicit set of rows of a table (table filters, context transition). Filters the expanded table.
        case rows(Int, RowSel)
        /// OR of alternatives, each an AND of filters (cross-filter selections, hierarchy slicers).
        case union([[CtxFilter]])
    }
    let kind: Kind
    var isSecurity = false
    /// Set for filters that pin a grouping column of the current summarisation (ISINSCOPE).
    var isGroup = false
    private var cache: [Int: RowSel?] = [:]
    private var subs: [CtxFilter]?

    init(_ kind: Kind) { self.kind = kind }

    static func values(_ c: ColumnID, _ s: Set<Value>) -> CtxFilter { CtxFilter(.values(c, s)) }
    static func single(_ c: ColumnID, _ v: Value, group: Bool = false) -> CtxFilter {
        let f = CtxFilter(.values(c, [v])); f.isGroup = group; return f
    }

    /// Columns this filter directly constrains (empty for row filters).
    var columns: [ColumnID] {
        switch kind {
        case .values(let c, _): return [c]
        case .tuples(let cs, _): return cs
        case .rows: return []
        case .union(let alts): return alts.flatMap { $0.flatMap { $0.columns } }
        }
    }
    /// Tables this filter is defined on.
    var tables: Set<Int> {
        switch kind {
        case .values(let c, _): return [c.table]
        case .tuples(let cs, _): return Set(cs.map { $0.table })
        case .rows(let t, _): return [t]
        case .union(let alts): return alts.reduce(into: Set<Int>()) { acc, a in a.forEach { acc.formUnion($0.tables) } }
        }
    }

    private var mode: PropMode {
        if isSecurity { return .security }
        if case .rows = kind { return .expanded }
        return .normal
    }

    /// The selection this filter induces on table `t`, or nil when it does not reach `t`.
    func selection(for t: Int, rel: RelState, db: Database) -> RowSel? {
        let key = t &* 65536 &+ rel.id
        if let c = cache[key] { return c }
        let result = compute(t, rel, db)
        cache[key] = .some(result)
        return result
    }

    private func direct(_ db: Database) -> (Int, RowSel)? {
        switch kind {
        case .values(let cid, let set):
            let col = db.column(cid)
            var picked: [Int32] = []
            if set.count <= 256 {
                for v in set { if let c = col.code(of: v) { picked.append(c) } }
            } else {
                for (i, v) in col.dict.enumerated() where set.contains(v) { picked.append(Int32(i)) }
            }
            return (cid.table, db.select(col, codes: picked, blank: set.contains(.null)))
        case .rows(let t, let sel):
            return (t, sel)
        case .tuples(let cols, let set):
            // Only called for single-table tuple filters (multi-table ones are split into `subs`).
            guard let t = cols.first?.table else { return nil }
            let stores = cols.map { db.column($0).values }
            let n = db.tables[t].rowCount
            var out: [Int32] = []
            var key = [Value](repeating: .null, count: cols.count)
            for r in 0..<n {
                for k in 0..<cols.count { key[k] = stores[k][r] }
                if set.contains(key) { out.append(Int32(r)) }
            }
            let blank = set.contains([Value](repeating: .null, count: cols.count))
            return (t, RowSel(n: n, rows: out.count == n ? nil : out, blank: blank))
        case .union:
            return nil
        }
    }

    private func along(_ path: [Step], from sel: RowSel, rel: RelState, db: Database) -> RowSel {
        var cur = sel
        for step in path {
            let target = step.toMany ? step.rel.manyT : step.rel.oneT
            let key = target &* 65536 &+ rel.id
            if let c = cache[key], let s = c { cur = s; continue }
            cur = db.propagate(cur, step)
            cache[key] = .some(cur)
        }
        return cur
    }

    private func compute(_ t: Int, _ rel: RelState, _ db: Database) -> RowSel? {
        switch kind {
        case .union(let alts):
            var parts: [RowSel] = []
            for alt in alts {
                let sels = alt.compactMap { $0.selection(for: t, rel: rel, db: db) }
                if sels.isEmpty { return nil }
                parts.append(RowSel.intersect(sels, n: db.tables[t].rowCount))
            }
            return RowSel.union(parts, n: db.tables[t].rowCount)
        case .tuples(let cols, let set) where Set(cols.map { $0.table }).count > 1:
            if subs == nil {
                var byTable: [Int: [Int]] = [:]
                for (i, c) in cols.enumerated() { byTable[c.table, default: []].append(i) }
                subs = byTable.values.map { idxs in
                    let proj = Set(set.map { tuple in idxs.map { tuple[$0] } })
                    let f = idxs.count == 1 ? CtxFilter(.values(cols[idxs[0]], Set(proj.map { $0[0] })))
                                            : CtxFilter(.tuples(idxs.map { cols[$0] }, proj))
                    f.isSecurity = isSecurity
                    return f
                }
            }
            let reaching = (subs ?? []).compactMap { $0.selection(for: t, rel: rel, db: db) }
            if reaching.isEmpty { return nil }
            if reaching.count == 1 { return reaching[0] }
            // Joint constraint: scan `t` using related column values when every column is reachable many→one.
            let n = db.tables[t].rowCount
            let codeVecs = cols.map { db.relatedCodes(table: t, column: $0, rel: rel) }
            if codeVecs.allSatisfy({ $0 != nil }) {
                let dicts = cols.map { db.column($0).dict }
                var out: [Int32] = []
                var key = [Value](repeating: .null, count: cols.count)
                for r in 0..<n {
                    for k in 0..<cols.count {
                        let c = codeVecs[k]![r]
                        key[k] = c < 0 ? .null : dicts[k][Int(c)]
                    }
                    if set.contains(key) { out.append(Int32(r)) }
                }
                return RowSel(n: n, rows: out.count == n ? nil : out, blank: reaching.allSatisfy { $0.blank })
            }
            return RowSel.intersect(reaching, n: n)
        default:
            guard let s = tables.first else { return nil }
            if s == t { return direct(db)?.1 }
            guard let path = db.path(from: s, to: t, rel: rel, mode: mode),
                  let sel = selection(for: s, rel: rel, db: db) else { return nil }
            return along(path, from: sel, rel: rel, db: db)
        }
    }

    /// The filter that remains after the given columns are overwritten; nil when nothing remains.
    func projectingOut(_ removed: (ColumnID) -> Bool) -> CtxFilter? {
        switch kind {
        case .values(let c, _): return removed(c) ? nil : self
        case .tuples(let cols, let set):
            let keep = cols.indices.filter { !removed(cols[$0]) }
            if keep.count == cols.count { return self }
            if keep.isEmpty { return nil }
            let proj = Set(set.map { t in keep.map { t[$0] } })
            let f = keep.count == 1 ? CtxFilter(.values(cols[keep[0]], Set(proj.map { $0[0] }))) : CtxFilter(.tuples(keep.map { cols[$0] }, proj))
            f.isGroup = isGroup
            return f
        case .rows: return self
        case .union:
            let cs = columns
            return !cs.isEmpty && cs.allSatisfy(removed) ? nil : self
        }
    }
}

/// An immutable filter context: a list of filters plus the relationship state. Resolves visible rows per table lazily.
final class FilterContext {
    let db: Database
    let filters: [CtxFilter]
    let rel: RelState
    /// When true, row-level security is not applied (used while computing calculated objects and the security filters themselves).
    let ignoreSecurity: Bool
    private var resolved: [Int: RowSel] = [:]
    /// Cached measure results, keyed by measure and the selected-measure context (calculation items).
    var measureCache: [MeasureKey: Value] = [:]

    init(db: Database, filters: [CtxFilter] = [], rel: RelState? = nil, ignoreSecurity: Bool = false) {
        self.db = db; self.filters = filters; self.rel = rel ?? db.defaultRel; self.ignoreSecurity = ignoreSecurity
    }

    /// Visible rows of table `t`.
    func rows(_ t: Int) -> RowSel {
        if let r = resolved[t] { return r }
        var sels: [RowSel] = []
        for f in filters { if let s = f.selection(for: t, rel: rel, db: db) { sels.append(s) } }
        if !ignoreSecurity {
            for f in db.securityFilters { if let s = f.selection(for: t, rel: rel, db: db) { sels.append(s) } }
        }
        let r = RowSel.intersect(sels, n: db.tables[t].rowCount)
        resolved[t] = r
        return r
    }
    /// Pre-seeds the visible rows of a table (used by grouped evaluation where the partition is already known).
    func seed(_ t: Int, _ sel: RowSel) { resolved[t] = sel }

    /// True when any user filter restricts table `t` (directly or through relationships).
    func isCrossFiltered(_ t: Int) -> Bool {
        filters.contains { f in
            guard let s = f.selection(for: t, rel: rel, db: db) else { return false }
            return !(s.isAll && s.blank)
        }
    }
    func isFiltered(_ c: ColumnID) -> Bool {
        filters.contains { f in
            if case .rows(let t, _) = f.kind { return t == c.table }
            return f.columns.contains(c)
        }
    }

    /// True when a filter other than a direct filter on column `c` restricts its table
    /// (another column of the same table, a row filter, or a related table).
    func isCrossFiltered(_ c: ColumnID) -> Bool {
        filters.contains { f in
            if f.columns == [c] && f.tables == [c.table] { return false }
            guard let s = f.selection(for: c.table, rel: rel, db: db) else { return false }
            return !(s.isAll && s.blank)
        }
    }

    func adding(_ new: [CtxFilter], keep: Bool = false) -> FilterContext {
        if new.isEmpty { return self }
        var base = filters
        if !keep {
            var cols = Set<ColumnID>()
            var tables = Set<Int>()
            for f in new {
                if case .rows(let t, _) = f.kind { tables.insert(t) }
                for c in f.columns { cols.insert(c) }
            }
            base = base.compactMap { f in
                if case .rows(let t, _) = f.kind { return tables.contains(t) ? nil : f }
                return f.projectingOut { cols.contains($0) || tables.contains($0.table) }
            }
        }
        return FilterContext(db: db, filters: base + new, rel: rel, ignoreSecurity: ignoreSecurity)
    }

    /// Removes filters on the given columns and whole tables (ALL / REMOVEFILTERS).
    func removing(columns: Set<ColumnID> = [], tables: Set<Int> = []) -> FilterContext {
        if columns.isEmpty && tables.isEmpty { return self }
        let base: [CtxFilter] = filters.compactMap { f in
            if case .rows(let t, _) = f.kind { return tables.contains(t) ? nil : f }
            return f.projectingOut { columns.contains($0) || tables.contains($0.table) }
        }
        if base.count == filters.count, zip(base, filters).allSatisfy({ $0 === $1 }) { return self }
        return FilterContext(db: db, filters: base, rel: rel, ignoreSecurity: ignoreSecurity)
    }
    func removingAll() -> FilterContext {
        filters.isEmpty ? self : FilterContext(db: db, filters: [], rel: rel, ignoreSecurity: ignoreSecurity)
    }
    func with(rel newRel: RelState) -> FilterContext {
        newRel === rel ? self : FilterContext(db: db, filters: filters, rel: newRel, ignoreSecurity: ignoreSecurity)
    }
    func with(filters newFilters: [CtxFilter]) -> FilterContext {
        FilterContext(db: db, filters: newFilters, rel: rel, ignoreSecurity: ignoreSecurity)
    }
    /// Filters that directly constrain a column.
    func filters(on c: ColumnID) -> [CtxFilter] { filters.filter { $0.columns.contains(c) } }
}
