import Foundation
import FacetCore

/// Identifies a model column by table and column index inside the engine's storage.
struct ColumnID: Hashable {
    let table: Int
    let col: Int
}

/// One stored column with lazily built dictionary encoding, posting lists and numeric cache.
final class ColumnStore {
    let name: String
    var type: DataType
    let values: [Value]
    var model: ModelColumn?

    init(name: String, type: DataType, values: [Value]) { self.name = name; self.type = type; self.values = values }

    private var encoded = false
    private var _codes: [Int32] = []
    private var _dict: [Value] = []
    private var _index: [Value: Int32] = [:]
    private var _postings: [[Int32]]?
    private var _doubles: [Double]?
    private var _sortRank: [Int32]?
    private var _tokenIndex: [String: [Int32]]?

    private func encode() {
        guard !encoded else { return }
        encoded = true
        _codes.reserveCapacity(values.count)
        for v in values {
            if let c = _index[v] { _codes.append(c) } else {
                let c = Int32(_dict.count)
                _index[v] = c; _dict.append(v); _codes.append(c)
            }
        }
    }
    /// Dictionary code per row.
    var codes: [Int32] { encode(); return _codes }
    /// Distinct values in order of first appearance.
    var dict: [Value] { encode(); return _dict }
    func code(of v: Value) -> Int32? { encode(); return _index[v] }
    /// Row indices per dictionary code, ascending.
    var postings: [[Int32]] {
        if let p = _postings { return p }
        encode()
        var p = [[Int32]](repeating: [], count: _dict.count)
        for (r, c) in _codes.enumerated() { p[Int(c)].append(Int32(r)) }
        _postings = p
        return p
    }
    /// Numeric view: NaN for blanks and non-numeric values.
    var doubles: [Double] {
        if let d = _doubles { return d }
        let d = values.map { v -> Double in
            switch v {
            case .int(let i): return Double(i)
            case .double(let x): return x
            case .bool(let b): return b ? 1 : 0
            case .date(let x): return Value.serial(from: x)
            default: return .nan
            }
        }
        _doubles = d
        return d
    }
    lazy var allInt: Bool = !values.contains { v in
        switch v { case .int, .null, .bool: return false; default: return true }
    }
    lazy var hasText: Bool = values.contains { if case .string = $0 { return true }; return false }
    lazy var isDateLike: Bool = type.isTemporal || values.contains { if case .date = $0 { return true }; return false }
    /// Rank of each dictionary code in ascending value order (for ordered output).
    var sortRank: [Int32] {
        if let s = _sortRank { return s }
        let d = dict
        let order = d.indices.sorted { d[$0] < d[$1] }
        var rank = [Int32](repeating: 0, count: d.count)
        for (i, o) in order.enumerated() { rank[o] = Int32(i) }
        _sortRank = rank
        return rank
    }
    /// Lower-cased word → dictionary codes whose text contains that word (for TEXTSEARCH).
    var tokenIndex: [String: [Int32]] {
        if let t = _tokenIndex { return t }
        var idx: [String: [Int32]] = [:]
        for (c, v) in dict.enumerated() {
            guard !v.isNull else { continue }
            var seen = Set<String>()
            for w in ColumnStore.words(v.asString) where seen.insert(w).inserted { idx[w, default: []].append(Int32(c)) }
        }
        _tokenIndex = idx
        return idx
    }
    static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}

final class TableStore {
    let name: String
    let index: Int
    var columns: [ColumnStore]
    var colIndex: [String: Int] = [:]
    var rowCount: Int
    var model: ModelTable?
    /// True for tables only defined inside a query (DEFINE TABLE).
    var isTransient = false
    var colsCache: Columns?

    init(name: String, index: Int, columns: [ColumnStore]) {
        self.name = name; self.index = index; self.columns = columns
        rowCount = columns.first?.values.count ?? 0
        for (i, c) in columns.enumerated() { colIndex[c.name.daxKey] = i }
    }
    func addColumn(_ c: ColumnStore) {
        colsCache = nil
        if let i = colIndex[c.name.daxKey] { columns[i] = c } else {
            colIndex[c.name.daxKey] = columns.count
            columns.append(c)
        }
        if columns.count == 1 { rowCount = c.values.count }
    }
    func removeColumn(named n: String) {
        guard let i = colIndex[n.daxKey] else { return }
        colsCache = nil
        columns.remove(at: i)
        colIndex = [:]
        for (k, c) in columns.enumerated() { colIndex[c.name.daxKey] = k }
    }
}

/// A set of rows of one table. `rows == nil` means every row. `blank` says whether the virtual
/// blank row (unmatched many-side keys) passes.
final class RowSel {
    let n: Int
    let rows: [Int32]?
    let blank: Bool
    init(n: Int, rows: [Int32]?, blank: Bool) { self.n = n; self.rows = rows; self.blank = blank }

    static func all(_ n: Int, blank: Bool = true) -> RowSel { RowSel(n: n, rows: nil, blank: blank) }
    var isAll: Bool { rows == nil }
    var count: Int { rows?.count ?? n }
    lazy var bitmap: [Bool] = {
        var b = [Bool](repeating: rows == nil, count: n)
        if let r = rows { for i in r { b[Int(i)] = true } }
        return b
    }()
    lazy var indices: [Int32] = rows ?? (0..<Int32(n)).map { $0 }

    static func intersect(_ sels: [RowSel], n: Int) -> RowSel {
        var blank = true
        var restricting: [RowSel] = []
        for s in sels {
            if !s.blank { blank = false }
            if !s.isAll { restricting.append(s) }
        }
        if restricting.isEmpty { return RowSel(n: n, rows: nil, blank: blank) }
        if restricting.count == 1 {
            let s = restricting[0]
            return s.blank == blank ? s : RowSel(n: n, rows: s.rows, blank: blank)
        }
        restricting.sort { $0.count < $1.count }
        let others = restricting.dropFirst().map { $0.bitmap }
        var out: [Int32] = []
        outer: for r in restricting[0].rows! {
            for b in others where !b[Int(r)] { continue outer }
            out.append(r)
        }
        return RowSel(n: n, rows: out, blank: blank)
    }
    static func union(_ sels: [RowSel], n: Int) -> RowSel {
        var blank = false
        var bm = [Bool](repeating: false, count: n)
        for s in sels {
            if s.blank { blank = true }
            guard let r = s.rows else { return RowSel(n: n, rows: nil, blank: blank || sels.contains { $0.blank }) }
            for i in r { bm[Int(i)] = true }
        }
        var out: [Int32] = []
        for i in 0..<n where bm[i] { out.append(Int32(i)) }
        return RowSel(n: n, rows: out.count == n ? nil : out, blank: blank)
    }
}

/// A relationship resolved against storage. `one` is the lookup/filtering side, `many` the filtered side.
final class Rel {
    let idx: Int
    let def: Relationship
    let oneT: Int, oneC: Int, manyT: Int, manyC: Int
    let one: ColumnStore, many: ColumnStore
    let isManyToMany: Bool
    let isOneToOne: Bool

    init(idx: Int, def: Relationship, oneT: Int, oneC: Int, manyT: Int, manyC: Int, one: ColumnStore, many: ColumnStore) {
        self.idx = idx; self.def = def
        self.oneT = oneT; self.oneC = oneC; self.manyT = manyT; self.manyC = manyC
        self.one = one; self.many = many
        isManyToMany = def.cardinality == .manyToMany
        isOneToOne = def.cardinality == .oneToOne
    }
    /// Default direction code: 1 = one filters many, 2 = both.
    var defaultDirection: UInt8 { (def.crossFilter == .both || isOneToOne) ? 2 : 1 }

    /// many-side dictionary code → one-side dictionary code (-1 when unmatched or blank).
    lazy var manyCodeToOneCode: [Int32] = many.dict.map { v in v.isNull ? -1 : (one.code(of: v) ?? -1) }
    lazy var oneCodeToManyCode: [Int32] = one.dict.map { v in v.isNull ? -1 : (many.code(of: v) ?? -1) }
    /// many-side codes with no partner on the one side (these rows belong to the blank row).
    lazy var unmatchedManyCodes: [Int32] = manyCodeToOneCode.enumerated().compactMap { $1 < 0 ? Int32($0) : nil }
    lazy var hasUnmatched: Bool = !unmatchedManyCodes.isEmpty && many.values.count > 0
    /// For each many-side row, the first matching one-side row (-1 when none).
    lazy var manyRowToOneRow: [Int32] = {
        let firstRow = one.postings.map { $0.first ?? -1 }
        let map = manyCodeToOneCode
        return many.codes.map { c in let oc = map[Int(c)]; return oc < 0 ? -1 : firstRow[Int(oc)] }
    }()
    /// For each one-side row, the first matching many-side row (used for one-to-one lookups).
    lazy var oneRowToManyRow: [Int32] = {
        let firstRow = many.postings.map { $0.first ?? -1 }
        let map = oneCodeToManyCode
        return one.codes.map { c in let mc = map[Int(c)]; return mc < 0 ? -1 : firstRow[Int(mc)] }
    }()
}

/// One hop of filter propagation across a relationship.
struct Step {
    let rel: Rel
    /// True when filtering flows from the one side to the many side.
    let toMany: Bool
}

enum PropMode: Int { case normal = 0, expanded = 1, security = 2 }

/// The set of active relationships and their cross-filter directions in effect (after USERELATIONSHIP / CROSSFILTER).
final class RelState {
    let id: Int
    let active: [Bool]
    /// 0 none, 1 one→many, 2 both, 3 many→one only.
    let dir: [UInt8]
    var pathCache: [Int: [Step]?] = [:]
    var relatedPathCache: [Int: [Step]?] = [:]
    init(id: Int, active: [Bool], dir: [UInt8]) { self.id = id; self.active = active; self.dir = dir }
}

/// Storage plus relationship index shared by every filter context of an engine.
final class Database {
    var tables: [TableStore] = []
    var tableIndex: [String: Int] = [:]
    var rels: [Rel] = []
    var defaultRel = RelState(id: 0, active: [], dir: [])
    private var relStates: [String: RelState] = [:]
    /// Row-level security filters, always applied.
    var securityFilters: [CtxFilter] = []
    private var blankRowCache: [Int: Bool] = [:]
    private var relatedRowsCache: [Int: [Int32]?] = [:]
    private var relatedCodesCache: [String: [Int32]?] = [:]
    var generation = 0

    func table(named n: String) -> TableStore? { tableIndex[n.daxKey].map { tables[$0] } }
    func column(_ id: ColumnID) -> ColumnStore { tables[id.table].columns[id.col] }
    func columnID(table: String, column: String) -> ColumnID? {
        guard let t = tableIndex[table.daxKey], let c = tables[t].colIndex[column.daxKey] else { return nil }
        return ColumnID(table: t, col: c)
    }
    func name(_ id: ColumnID) -> String { "'\(tables[id.table].name)'[\(tables[id.table].columns[id.col].name)]" }

    @discardableResult
    func addTable(name: String, columns: [ColumnStore], model: ModelTable?) -> TableStore {
        if let i = tableIndex[name.daxKey] {
            let t = TableStore(name: name, index: i, columns: columns)
            t.model = model
            tables[i] = t
            return t
        }
        let t = TableStore(name: name, index: tables.count, columns: columns)
        t.model = model
        tableIndex[name.daxKey] = tables.count
        tables.append(t)
        return t
    }

    /// Rebuilds the relationship index from model relationships. Unresolvable relationships are skipped and reported.
    func buildRelationships(_ defs: [Relationship]) -> [String] {
        var problems: [String] = []
        rels = []
        for d in defs {
            guard let f = columnID(table: d.fromTable, column: d.fromColumn), let t = columnID(table: d.toTable, column: d.toColumn) else {
                problems.append("Relationship \(d.fromTable)[\(d.fromColumn)] → \(d.toTable)[\(d.toColumn)] refers to a missing column.")
                continue
            }
            let fromIsOne = d.cardinality == .oneToMany
            let one = fromIsOne ? f : t, many = fromIsOne ? t : f
            rels.append(Rel(idx: rels.count, def: d, oneT: one.table, oneC: one.col, manyT: many.table, manyC: many.col,
                            one: column(one), many: column(many)))
        }
        relStates = [:]
        blankRowCache = [:]; relatedRowsCache = [:]; relatedCodesCache = [:]
        defaultRel = relState(active: rels.map { $0.def.isActive }, dir: rels.map { $0.defaultDirection })
        generation += 1
        return problems
    }

    func relState(active: [Bool], dir: [UInt8]) -> RelState {
        let key = active.map { $0 ? "1" : "0" }.joined() + "|" + dir.map { String($0) }.joined()
        if let s = relStates[key] { return s }
        let s = RelState(id: relStates.count, active: active, dir: dir)
        relStates[key] = s
        return s
    }

    func findRel(_ a: ColumnID, _ b: ColumnID) -> Rel? {
        rels.first { r in
            (r.oneT == a.table && r.oneC == a.col && r.manyT == b.table && r.manyC == b.col) ||
            (r.oneT == b.table && r.oneC == b.col && r.manyT == a.table && r.manyC == a.col)
        }
    }

    /// A filter pinning one column to one value (grouped evaluation).
    func singleFilter(_ c: ColumnID, _ v: Value, group: Bool = false) -> CtxFilter {
        CtxFilter.single(c, v, group: group)
    }

    /// True when the table has a virtual blank row: some active relationship has many-side keys with no match in it.
    func hasBlankRow(_ t: Int) -> Bool {
        if let b = blankRowCache[t] { return b }
        let b = rels.contains { $0.oneT == t && $0.def.isActive && !$0.isManyToMany && $0.hasUnmatched }
        blankRowCache[t] = b
        return b
    }

    // MARK: Paths

    /// Path along which a filter on `s` reaches `t`, or nil when it does not.
    func path(from s: Int, to t: Int, rel: RelState, mode: PropMode) -> [Step]? {
        let key = (s &* 4096 &+ t) &* 4 &+ mode.rawValue
        if let p = rel.pathCache[key] { return p }
        // BFS over (table, upOnly) states. `upOnly` is true while every hop so far went many→one (expanded-table mode).
        struct State: Hashable { let table: Int; let upOnly: Bool }
        var prev: [State: (State, Step)] = [:]
        let start = State(table: s, upOnly: true)
        var queue = [start]
        var seenTables: Set<Int> = [s]
        var found: State?
        var head = 0
        while head < queue.count, found == nil {
            let st = queue[head]; head += 1
            for r in rels where rel.active[r.idx] {
                let d = rel.dir[r.idx]
                var hops: [(Int, Step, Bool)] = []
                if r.oneT == st.table {
                    let ok: Bool
                    switch mode {
                    case .security: ok = true
                    default: ok = d == 1 || d == 2
                    }
                    if ok { hops.append((r.manyT, Step(rel: r, toMany: true), false)) }
                }
                if r.manyT == st.table {
                    let ok: Bool
                    switch mode {
                    case .normal: ok = d == 2 || d == 3
                    case .expanded: ok = d == 2 || d == 3 || (st.upOnly && !r.isManyToMany)
                    case .security: ok = d == 2 && (r.def.securityFilterBothDirections || r.isOneToOne)
                    }
                    if ok { hops.append((r.oneT, Step(rel: r, toMany: false), st.upOnly)) }
                }
                for (nt, step, up) in hops where !seenTables.contains(nt) {
                    seenTables.insert(nt)
                    let ns = State(table: nt, upOnly: up)
                    prev[ns] = (st, step)
                    if nt == t { found = ns; break }
                    queue.append(ns)
                }
                if found != nil { break }
            }
        }
        var result: [Step]?
        if var cur = found {
            var steps: [Step] = []
            while let (p, step) = prev[cur] { steps.append(step); cur = p }
            result = steps.reversed()
        }
        rel.pathCache[key] = .some(result)
        return result
    }

    /// Many→one chain from `a` to `b` (for RELATED and grouping by related columns).
    func relatedPath(from a: Int, to b: Int, rel: RelState) -> [Step]? {
        if a == b { return [] }
        let key = a &* 4096 &+ b
        if let p = rel.relatedPathCache[key] { return p }
        var prev: [Int: (Int, Step)] = [:]
        var seen: Set<Int> = [a]
        var queue = [a], head = 0
        var ok = false
        while head < queue.count, !ok {
            let cur = queue[head]; head += 1
            for r in rels where rel.active[r.idx] && !r.isManyToMany {
                var hops: [(Int, Step)] = []
                if r.manyT == cur { hops.append((r.oneT, Step(rel: r, toMany: false))) }
                if r.oneT == cur, r.isOneToOne { hops.append((r.manyT, Step(rel: r, toMany: true))) }
                for (nt, step) in hops where !seen.contains(nt) {
                    seen.insert(nt); prev[nt] = (cur, step)
                    if nt == b { ok = true; break }
                    queue.append(nt)
                }
                if ok { break }
            }
        }
        var result: [Step]?
        if ok {
            var steps: [Step] = []
            var cur = b
            while let (p, step) = prev[cur] { steps.append(step); cur = p }
            result = steps.reversed()
        }
        rel.relatedPathCache[key] = .some(result)
        return result
    }

    /// For each row of `a`, the related row of `b` (-1 when none), following many→one relationships.
    func relatedRows(from a: Int, to b: Int, rel: RelState) -> [Int32]? {
        let key = (a &* 4096 &+ b) &* 4096 &+ rel.id
        if let c = relatedRowsCache[key] { return c }
        var result: [Int32]?
        if let path = relatedPath(from: a, to: b, rel: rel) {
            var cur: [Int32] = (0..<Int32(tables[a].rowCount)).map { $0 }
            for step in path {
                let map = step.toMany ? step.rel.oneRowToManyRow : step.rel.manyRowToOneRow
                cur = cur.map { $0 < 0 ? -1 : map[Int($0)] }
            }
            result = cur
        }
        relatedRowsCache[key] = .some(result)
        return result
    }

    /// For each row of `t`, the dictionary code of `col` on the related row (-1 = no related row → blank).
    func relatedCodes(table t: Int, column c: ColumnID, rel: RelState) -> [Int32]? {
        if c.table == t { return column(c).codes }
        let key = "\(t)|\(c.table)|\(c.col)|\(rel.id)"
        if let r = relatedCodesCache[key] { return r }
        var result: [Int32]?
        if let rows = relatedRows(from: t, to: c.table, rel: rel) {
            let codes = column(c).codes
            result = rows.map { $0 < 0 ? -1 : codes[Int($0)] }
        }
        relatedCodesCache[key] = .some(result)
        return result
    }

    // MARK: Propagation

    private func collect(_ col: ColumnStore, picked: [Int32], estimate: Int, blank: Bool) -> RowSel {
        let n = col.values.count
        if estimate >= n { return RowSel(n: n, rows: nil, blank: blank) }
        let postings = col.postings
        if picked.count == 1 { return RowSel(n: n, rows: postings[Int(picked[0])], blank: blank) }
        var out: [Int32] = []
        out.reserveCapacity(estimate)
        if estimate * 6 < n {
            for c in picked { out.append(contentsOf: postings[Int(c)]) }
            out.sort()
        } else {
            var allowed = [Bool](repeating: false, count: postings.count)
            for c in picked { allowed[Int(c)] = true }
            let codes = col.codes
            for r in 0..<n where allowed[Int(codes[r])] { out.append(Int32(r)) }
        }
        return RowSel(n: n, rows: out, blank: blank)
    }

    /// Rows of `col`'s table whose value has one of the given dictionary codes.
    func select(_ col: ColumnStore, codes picked: [Int32], blank: Bool) -> RowSel {
        let postings = col.postings
        var est = 0
        for c in picked { est += postings[Int(c)].count }
        return collect(col, picked: picked, estimate: est, blank: blank)
    }

    /// Moves a selection across one relationship hop.
    func propagate(_ sel: RowSel, _ step: Step) -> RowSel {
        let r = step.rel
        if step.toMany {
            if sel.isAll && sel.blank { return .all(r.many.values.count) }
            let map = r.oneCodeToManyCode
            var seen = [Bool](repeating: false, count: r.many.dict.count)
            var picked: [Int32] = []
            let postings = r.many.postings
            var est = 0
            func add(_ mc: Int32) {
                guard mc >= 0, !seen[Int(mc)] else { return }
                seen[Int(mc)] = true; picked.append(mc); est += postings[Int(mc)].count
            }
            if let rows = sel.rows {
                let oneCodes = r.one.codes
                for row in rows { add(map[Int(oneCodes[Int(row)])]) }
            } else {
                for mc in map { add(mc) }
            }
            if sel.blank { for mc in r.unmatchedManyCodes { add(mc) } }
            return collect(r.many, picked: picked, estimate: est, blank: sel.blank)
        } else {
            guard let rows = sel.rows else { return .all(r.one.values.count, blank: sel.blank) }
            let map = r.manyCodeToOneCode
            let codes = r.many.codes
            var seen = [Bool](repeating: false, count: r.many.dict.count)
            var picked: [Int32] = []
            var est = 0
            var blank = sel.blank
            let postings = r.one.postings
            for row in rows {
                let c = Int(codes[Int(row)])
                if seen[c] { continue }
                seen[c] = true
                let oc = map[c]
                if oc >= 0 { picked.append(oc); est += postings[Int(oc)].count } else { blank = true }
            }
            return collect(r.one, picked: picked, estimate: est, blank: blank)
        }
    }
}
