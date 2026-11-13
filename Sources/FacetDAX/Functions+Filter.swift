import Foundation
import FacetCore

final class FilterBox {
    let filter: CtxFilter?
    let gen: Int
    init(_ f: CtxFilter?, gen: Int) { filter = f; self.gen = gen }
}

extension DAXEngine {
    /// Tables whose columns belong to the expanded table of `t` (itself plus everything reachable many→one).
    func expandedTables(_ t: Int, _ rel: RelState) -> Set<Int> {
        var out: Set<Int> = [t]
        for other in db.tables.indices where other != t {
            if db.relatedPath(from: t, to: other, rel: rel) != nil { out.insert(other) }
        }
        return out
    }

    /// True when filtering this column should clear all other filters on its table (date table semantics).
    func isDateKeyColumn(_ c: ColumnID) -> Bool {
        let t = db.tables[c.table]
        let col = t.columns[c.col]
        if let dc = t.model?.dateColumn, dc.daxKey == col.name.daxKey { return true }
        if autoDateTables.contains(c.table), col.name == "Date" { return true }
        return false
    }

    /// Converts a table value into context filters (using data lineage).
    func filters(from t: TableValue) -> [CtxFilter] {
        if let b = t.base {
            let n = db.tables[b.table].rowCount
            let rows = b.rows.filter { $0 >= 0 }
            return [CtxFilter(.rows(b.table, RowSel(n: n, rows: rows.count == n ? nil : rows, blank: rows.count != b.rows.count)))]
        }
        var idx: [Int] = [], cols: [ColumnID] = []
        for (i, info) in t.cols.infos.enumerated() {
            if let l = info.lineage, !cols.contains(l) { idx.append(i); cols.append(l) }
        }
        if cols.isEmpty { return [] }
        if cols.count == 1 {
            let k = idx[0]
            return [CtxFilter(.values(cols[0], Set(t.data.map { $0[k] })))]
        }
        if t.data.count == 1 {
            return zip(cols, idx).map { CtxFilter.single($0, t.data[0][$1]) }
        }
        return [CtxFilter(.tuples(cols, Set(t.data.map { row in idx.map { row[$0] } })))]
    }

    private static let predicateTransparent: Set<String> = ["IF", "IF.EAGER", "SWITCH", "COALESCE", "IFERROR", "ISERROR", "__TUPLE", "CONVERT"]

    /// Row-level column references of a boolean filter predicate (not those consumed by aggregations).
    private func predicateColumns(_ n: Node, _ ctx: Ctx, into out: inout [ColumnID]) throws {
        switch n.kind {
        case .column(let t, _, _):
            if t != nil, let c = try modelColumn(n, ctx), !out.contains(c) { out.append(c) }
        case .binary(_, let l, let r):
            try predicateColumns(l, ctx, into: &out)
            if case .tableCtor = r.kind {} else { try predicateColumns(r, ctx, into: &out) }
        case .unary(_, let e): try predicateColumns(e, ctx, into: &out)
        case .call(let name, let args):
            let scalarMinMax = (name == "MIN" || name == "MAX") && args.count == 2
            if DAXEngine.pureFns[name] != nil || DAXEngine.predicateTransparent.contains(name) || scalarMinMax {
                for a in args { try predicateColumns(a, ctx, into: &out) }
            }
        case .vars(let vs, let body):
            for v in vs { try predicateColumns(v.expr, ctx, into: &out) }
            try predicateColumns(body, ctx, into: &out)
        default: break
        }
    }

    /// True when a predicate depends on nothing but its own columns and constants, so its filter can be cached on the node.
    private func isContextFree(_ n: Node) -> Bool {
        var ok = true
        n.walk { x in
            switch x.kind {
            case .ident, .vars: ok = false
            case .column(let t, _, _): if t == nil { ok = false }
            case .call(let name, _):
                if DAXEngine.pureFns[name] == nil && !DAXEngine.predicateTransparent.contains(name) { ok = false }
                if ["RAND", "RANDBETWEEN", "NOW", "TODAY", "UTCNOW", "UTCTODAY"].contains(name) { ok = false }
            default: break
            }
        }
        return ok
    }

    /// Builds the filter for a boolean CALCULATE argument: FILTER(ALL(columns), predicate).
    func predicateFilter(_ n: Node, _ ctx: Ctx) throws -> CtxFilter {
        if let b = n.cache2 as? FilterBox, b.gen == db.generation, let f = b.filter { return f }
        var cols: [ColumnID] = []
        try predicateColumns(n, ctx, into: &cols)
        guard !cols.isEmpty else {
            throw DAXError("A True/False filter expression must compare a column, for example Product[Color] = \"Red\". Use FILTER() for more complex conditions.", range: n.range)
        }
        guard Set(cols.map { $0.table }).count == 1 else {
            throw DAXError("A True/False filter expression can only refer to columns of one table. Use FILTER() over a table instead.", range: n.range)
        }
        let infos = Columns(cols.map(colInfo))
        var c = ctx
        c.frames.append(.row(infos, []))
        let last = c.frames.count - 1
        let filter: CtxFilter
        if cols.count == 1 {
            var vals = db.column(cols[0]).dict
            if db.hasBlankRow(cols[0].table), !vals.contains(where: { $0.isNull }) { vals.append(.null) }
            var set = Set<Value>()
            for v in vals {
                c.frames[last] = .row(infos, [v])
                if try DAXOps.truthy(scalar(n, c)) { set.insert(v) }
            }
            filter = CtxFilter(.values(cols[0], set))
        } else {
            let stores = cols.map { db.column($0).values }
            let rowCount = db.tables[cols[0].table].rowCount
            var seen = Set<[Value]>(), set = Set<[Value]>()
            for r in 0..<rowCount {
                let key = stores.map { $0[r] }
                guard seen.insert(key).inserted else { continue }
                c.frames[last] = .row(infos, key)
                if try DAXOps.truthy(scalar(n, c)) { set.insert(key) }
            }
            filter = CtxFilter(.tuples(cols, set))
        }
        if ctx.frames.isEmpty, isContextFree(n) { n.cache2 = FilterBox(filter, gen: db.generation) }
        return filter
    }

    static let tableFunctionNames: Set<String> = Set(DAXCatalog.functions.filter { $0.returnsTable }.map { $0.name })

    /// Static check: does this node produce a table?
    func isTableNode(_ node: Node, _ ctx: Ctx) -> Bool {
        let (n, c) = deref(node, ctx)
        switch n.kind {
        case .tableCtor: return true
        case .ident(let name):
            let k = name.daxKey
            if let v = c.vars?.lookup(k) { if case .table = v { return true }; return false }
            return queryTables[k] != nil || db.tableIndex[k] != nil
        case .call(let name, let args):
            if let f = queryFunctions[name.daxKey] ?? functionDefs[name.daxKey] { return isTableNode(f.body, Ctx(fc: c.fc)) }
            if name == "IF" || name == "IF.EAGER" { return args.count > 1 && isTableNode(args[1], c) }
            return DAXEngine.tableFunctionNames.contains(name)
        case .vars(let vs, let body):
            // A VAR block is a table when its body is; table-valued variables are detected by name.
            if case .ident(let bn) = body.kind, let v = vs.last(where: { $0.name.daxKey == bn.daxKey }) { return isTableNode(v.expr, c) }
            return isTableNode(body, c)
        default: return false
        }
    }

    /// Applies CALCULATE filter arguments and context transition, returning the context for the inner expression.
    func calculateContext(_ filterArgs: ArraySlice<Node>, _ ctx: Ctx) throws -> Ctx {        var removeCols = Set<ColumnID>(), removeTables = Set<Int>(), removeRowTables = Set<Int>()
        var removeAll = false
        var restore: [CtxFilter] = []
        var replaceAdds: [CtxFilter] = [], keepAdds: [CtxFilter] = []
        var active = ctx.fc.rel.active, dir = ctx.fc.rel.dir
        var relChanged = false

        func removal(_ args: [Node], _ c: Ctx, _ name: String) throws {
            if args.isEmpty { removeAll = true; return }
            for a in args {
                let (n, ac) = deref(a, c)
                if case .ident(let tn) = n.kind, let ti = db.tableIndex[tn.daxKey] {
                    try checkTableAccess(ti, n)
                    removeTables.formUnion(expandedTables(ti, ctx.fc.rel))
                } else {
                    removeCols.insert(try columnArg(n, ac, name))
                }
            }
        }
        func collect(_ node: Node, _ c0: Ctx, keep: Bool) throws {
            let (n, c) = deref(node, c0)
            if case .call(let name, let args) = n.kind {
                switch name {
                case "KEEPFILTERS":
                    guard let inner = args.first else { throw DAXError("KEEPFILTERS needs an argument.") }
                    return try collect(inner, c, keep: true)
                case "ALL", "REMOVEFILTERS", "ALLNOBLANKROW":
                    return try removal(args, c, name)
                case "ALLEXCEPT":
                    guard let first = args.first, case .ident(let tn) = deref(first, c).0.kind, let ti = db.tableIndex[tn.daxKey] else {
                        throw DAXError("ALLEXCEPT expects a table followed by the columns to keep.")
                    }
                    let exceptCols = Set(try args.dropFirst().map { try columnArg($0, c, name) })
                    let tabs = expandedTables(ti, ctx.fc.rel)
                    for t in tabs {
                        removeRowTables.insert(t)
                        for ci in db.tables[t].columns.indices {
                            let id = ColumnID(table: t, col: ci)
                            if !exceptCols.contains(id) { removeCols.insert(id) }
                        }
                    }
                    return
                case "ALLSELECTED":
                    let sel = ctx.selected
                    if args.isEmpty {
                        removeAll = true
                        restore.append(contentsOf: sel?.filters ?? [])
                        return
                    }
                    for a in args {
                        let (an, ac) = deref(a, c)
                        if case .ident(let tn) = an.kind, let ti = db.tableIndex[tn.daxKey] {
                            let tabs = expandedTables(ti, ctx.fc.rel)
                            removeTables.formUnion(tabs)
                            restore.append(contentsOf: (sel?.filters ?? []).filter { !$0.tables.isDisjoint(with: tabs) })
                        } else {
                            let cid = try columnArg(an, ac, name)
                            removeCols.insert(cid)
                            restore.append(contentsOf: (sel?.filters ?? []).compactMap { f in
                                f.columns.contains(cid) ? f.projectingOut { $0 != cid } : nil
                            })
                        }
                    }
                    return
                case "USERELATIONSHIP":
                    guard args.count == 2 else { throw DAXError("USERELATIONSHIP expects two columns.") }
                    let a = try columnArg(args[0], c, name), b = try columnArg(args[1], c, name)
                    guard let r = db.findRel(a, b) else {
                        throw DAXError("USERELATIONSHIP: there is no relationship between \(db.name(a)) and \(db.name(b)).")
                    }
                    for other in db.rels where other.idx != r.idx {
                        let samePair = (other.oneT == r.oneT && other.manyT == r.manyT) || (other.oneT == r.manyT && other.manyT == r.oneT)
                        if samePair { active[other.idx] = false }
                    }
                    active[r.idx] = true
                    relChanged = true
                    return
                case "CROSSFILTER":
                    guard args.count == 3 else { throw DAXError("CROSSFILTER expects two columns and a direction.") }
                    let a = try columnArg(args[0], c, name), b = try columnArg(args[1], c, name)
                    guard let r = db.findRel(a, b) else {
                        throw DAXError("CROSSFILTER: there is no relationship between \(db.name(a)) and \(db.name(b)).")
                    }
                    let aIsOne = r.oneT == a.table && r.oneC == a.col
                    switch try keywordArg(args, 2, c) ?? "" {
                    case "NONE": dir[r.idx] = 0
                    case "ONEWAY": dir[r.idx] = 1
                    case "BOTH": dir[r.idx] = 2
                    case "ONEWAY_LEFTFILTERSRIGHT": dir[r.idx] = aIsOne ? 1 : 3
                    case "ONEWAY_RIGHTFILTERSLEFT": dir[r.idx] = aIsOne ? 3 : 1
                    case let other: throw DAXError("CROSSFILTER: unknown direction '\(other)'. Use NONE, ONEWAY, BOTH, ONEWAY_LEFTFILTERSRIGHT or ONEWAY_RIGHTFILTERSLEFT.")
                    }
                    relChanged = true
                    return
                default: break
                }
            }
            var fs: [CtxFilter]
            if isTableNode(n, c) {
                fs = filters(from: try table(n, c))
            } else {
                fs = [try predicateFilter(n, c)]
            }
            if !keep {
                for f in fs {
                    if case .values(let cid, _) = f.kind, isDateKeyColumn(cid) { removeTables.insert(cid.table) }
                }
            }
            if keep { keepAdds.append(contentsOf: fs) } else { replaceAdds.append(contentsOf: fs) }
        }

        for a in filterArgs where !a.isMissing { try collect(a, ctx, keep: false) }

        var fc = transition(ctx)
        if relChanged { fc = fc.with(rel: db.relState(active: active, dir: dir)) }
        if removeAll { fc = fc.removingAll() }
        else { fc = fc.removing(columns: removeCols, tables: removeTables, rowTables: removeRowTables) }
        if !restore.isEmpty { fc = fc.adding(restore, keep: true) }
        fc = fc.adding(replaceAdds, keep: false).adding(keepAdds, keep: true)
        var out = ctx
        out.fc = fc
        out.frames = []
        return out
    }

    /// CALCULATE with additional filter tables (time intelligence's dates table) and tables whose
    /// own filters clear, as a filter on a date column does.
    func calculateContext(_ filterArgs: ArraySlice<Node>, _ ctx: Ctx, tables: [TableValue], clearTables: [Int]) throws -> Ctx {
        var out = try calculateContext(filterArgs, ctx)
        if !clearTables.isEmpty { out.fc = out.fc.removing(tables: Set(clearTables)) }
        if !tables.isEmpty {
            var adds: [CtxFilter] = []
            for t in tables { adds += filters(from: t) }
            out.fc = out.fc.adding(adds, keep: true)
        }
        return out
    }

    func allTable(_ args: [Node], _ ctx: Ctx, blankRow: Bool, name: String) throws -> TableValue {        guard !args.isEmpty else { throw DAXError("\(name)() without arguments can only be used as a CALCULATE filter.") }
        var c = ctx
        c.fc = ctx.fc.removingAll()
        let (n, ac) = deref(args[0], ctx)
        if args.count == 1, case .ident(let tn) = n.kind, ac.vars?.lookup(tn.daxKey) == nil, let ti = db.tableIndex[tn.daxKey] {
            try checkTableAccess(ti, n)
            let sel = c.fc.rows(ti)
            var rows = sel.indices
            if blankRow, db.hasBlankRow(ti) { rows.append(-1) }
            return TableValue(table: ti, rows: rows, db: db)
        }
        let cols = try args.map { try columnArg($0, ctx, name) }
        return try distinctColumns(cols, c.fc, blankRow: blankRow)
    }

    /// Distinct combinations of columns of one table in a filter context.
    func distinctColumns(_ cols: [ColumnID], _ fc: FilterContext, blankRow: Bool) throws -> TableValue {
        if cols.count == 1 { return singleColumn(cols[0], distinctValues(cols[0], fc, blankRow: blankRow)) }
        guard Set(cols.map { $0.table }).count == 1 else {
            throw DAXError("All columns must belong to the same table.")
        }
        let t = cols[0].table
        let sel = fc.rows(t)
        let codes = cols.map { db.column($0).codes }
        let dicts = cols.map { db.column($0).dict }
        var seen = Set<[Int32]>()
        var out: [[Value]] = []
        for r in sel.indices {
            let key = codes.map { $0[Int(r)] }
            if seen.insert(key).inserted { out.append(key.enumerated().map { dicts[$0][Int($1)] }) }
        }
        if blankRow, sel.blank, db.hasBlankRow(t) { out.append([Value](repeating: .null, count: cols.count)) }
        return TableValue(cols: Columns(cols.map(colInfo)), rows: out)
    }

    func distinctRows(_ t: TableValue) -> TableValue {
        var seen = Set<[Value]>()
        var out: [[Value]] = []
        for r in t.rows(db) where seen.insert(r).inserted { out.append(r) }
        return TableValue(cols: t.cols, rows: out)
    }

    func valuesFn(_ args: [Node], _ ctx: Ctx, blankRow: Bool, name: String) throws -> TableValue {
        let (n, c) = deref(args[0], ctx)
        if let vals = visualColumnValues(n, c), case .column(_, let cn, _) = n.kind {
            var seen = Set<Value>()
            return TableValue(cols: Columns([ColInfo(name: cn)]), rows: vals.filter { seen.insert($0).inserted }.map { [$0] })
        }
        if let cid = try modelColumn(n, c) {
            return singleColumn(cid, distinctValues(cid, c.fc, blankRow: blankRow))
        }
        if case .column(let t, let cn, _) = n.kind {
            throw DAXError("\(name): cannot find column \(t.map { "'\($0)'" } ?? "")[\(cn)].", range: n.range)
        }
        let t = try table(n, c)
        if name == "DISTINCT" {
            if let b = t.base { return TableValue(table: b.table, rows: b.rows.filter { $0 >= 0 }, db: db) }
            return distinctRows(t)
        }
        return t
    }

    static let filterFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        d["CALCULATE"] = { e, a, c, _ in
            let inner = try e.calculateContext(a.dropFirst(), c)
            return .scalar(try e.scalar(a[0], inner))
        }
        d["CALCULATETABLE"] = { e, a, c, _ in
            let inner = try e.calculateContext(a.dropFirst(), c)
            return .table(try e.table(a[0], inner))
        }
        d["FILTER"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            if let b = t.base {
                var keep: [Int32] = []
                try e.forEachRow(t, c) { rc, i in if try DAXOps.truthy(e.scalar(a[1], rc)) { keep.append(b.rows[i]) } }
                return .table(TableValue(table: b.table, rows: keep, db: e.db))
            }
            var keep: [[Value]] = []
            try e.forEachRow(t, c) { rc, i in if try DAXOps.truthy(e.scalar(a[1], rc)) { keep.append(t.data[i]) } }
            return .table(TableValue(cols: t.cols, rows: keep))
        }
        d["ALL"] = { e, a, c, _ in .table(try e.allTable(a, c, blankRow: true, name: "ALL")) }
        d["REMOVEFILTERS"] = { _, _, _, _ in throw DAXError("REMOVEFILTERS can only be used as a CALCULATE filter argument.") }
        d["ALLNOBLANKROW"] = { e, a, c, _ in .table(try e.allTable(a, c, blankRow: false, name: "ALLNOBLANKROW")) }
        d["ALLEXCEPT"] = { e, a, c, n in
            let inner = try e.calculateContext([n][...], c)
            return .table(try e.table(a[0], inner))
        }
        d["ALLSELECTED"] = { e, a, c, n in
            guard !a.isEmpty else { throw DAXError("ALLSELECTED() without arguments can only be used as a CALCULATE filter.") }
            var inner = c
            inner.frames = []
            inner.fc = c.selected ?? c.fc.removingAll()
            if a.count == 1, e.isTableNode(a[0], c) { return .table(try e.table(a[0], inner)) }
            let cols = try a.map { try e.columnArg($0, c, "ALLSELECTED") }
            return .table(try e.distinctColumns(cols, inner.fc, blankRow: true))
        }
        d["VALUES"] = { e, a, c, _ in .table(try e.valuesFn(a, c, blankRow: true, name: "VALUES")) }
        d["DISTINCT"] = { e, a, c, _ in .table(try e.valuesFn(a, c, blankRow: false, name: "DISTINCT")) }
        d["KEEPFILTERS"] = { e, a, c, _ in try e.eval(a[0], c) }
        d["SELECTEDVALUE"] = { e, a, c, _ in
            let vals: [Value]
            if let v = e.visualColumnValues(a[0], c) { vals = Array(Set(v)) }
            else { vals = e.distinctValues(try e.columnArg(a[0], c, "SELECTEDVALUE"), c.fc, blankRow: true) }
            if vals.count == 1 { return .scalar(vals[0]) }
            return .scalar(try e.scalarArg(a, 1, c))
        }
        d["HASONEVALUE"] = { e, a, c, _ in
            .scalar(.bool(e.distinctValues(try e.columnArg(a[0], c, "HASONEVALUE"), c.fc, blankRow: true).count == 1))
        }
        d["HASONEFILTER"] = { e, a, c, _ in
            let cid = try e.columnArg(a[0], c, "HASONEFILTER")
            var set: Set<Value>?
            for f in c.fc.filters {
                if case .values(let fc, let s) = f.kind, fc == cid { set = set.map { $0.intersection(s) } ?? s }
            }
            return .scalar(.bool(set?.count == 1))
        }
        d["FILTERS"] = { e, a, c, _ in
            let cid = try e.columnArg(a[0], c, "FILTERS")
            var set: Set<Value>?
            for f in c.fc.filters {
                if case .values(let fc, let s) = f.kind, fc == cid { set = set.map { $0.intersection(s) } ?? s }
            }
            if let s = set { return .table(e.singleColumn(cid, e.db.column(cid).dict.filter { s.contains($0) })) }
            return .table(e.singleColumn(cid, e.distinctValues(cid, c.fc.removingAll(), blankRow: true)))
        }
        d["ISFILTERED"] = { e, a, c, _ in
            let (n, ac) = e.deref(a[0], c)
            if case .ident(let tn) = n.kind, let ti = e.db.tableIndex[tn.daxKey] {
                return .scalar(.bool(c.fc.filters.contains { $0.tables.contains(ti) }))
            }
            return .scalar(.bool(c.fc.isFiltered(try e.columnArg(n, ac, "ISFILTERED"))))
        }
        d["ISCROSSFILTERED"] = { e, a, c, _ in
            let (n, ac) = e.deref(a[0], c)
            if case .ident(let tn) = n.kind, let ti = e.db.tableIndex[tn.daxKey] { return .scalar(.bool(c.fc.isCrossFiltered(ti))) }
            return .scalar(.bool(c.fc.isCrossFiltered(try e.columnArg(n, ac, "ISCROSSFILTERED").table)))
        }
        d["ISINSCOPE"] = { e, a, c, _ in
            if let vc = c.visual, case .column(nil, let name, _) = a[0].kind {
                return .scalar(.bool(vc.grid.cols.byName[name.daxKey] != nil))
            }
            let cid = try e.columnArg(a[0], c, "ISINSCOPE")
            return .scalar(.bool(c.fc.filters.contains { $0.isGroup && $0.columns.contains(cid) }))
        }
        d["EARLIER"] = { e, a, c, n in
            let cid = try e.columnArg(a[0], c, "EARLIER")
            let steps = try e.arg(a, 1).map { Int(try DAXOps.number(e.scalar($0, c))) } ?? 1
            return .scalar(try e.earlier(cid, c, skip: steps, n))
        }
        d["EARLIEST"] = { e, a, c, n in
            let cid = try e.columnArg(a[0], c, "EARLIEST")
            return .scalar(try e.earlier(cid, c, skip: -1, n))
        }
        d["RELATED"] = { e, a, c, n in
            .scalar(try e.relatedValue(try e.columnArg(a[0], c, "RELATED"), c, n))
        }
        d["RELATEDTABLE"] = { e, a, c, _ in
            var inner = c
            inner.fc = e.transition(c)
            inner.frames = []
            return .table(try e.table(a[0], inner))
        }
        d["USERELATIONSHIP"] = { _, _, _, _ in throw DAXError("USERELATIONSHIP can only be used as a CALCULATE filter argument.") }
        d["CROSSFILTER"] = { _, _, _, _ in throw DAXError("CROSSFILTER can only be used as a CALCULATE filter argument.") }
        d["TREATAS"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            let cols = try a.dropFirst().map { try e.columnArg($0, c, "TREATAS") }
            guard cols.count == t.cols.count else {
                throw DAXError("TREATAS: the table has \(t.cols.count) column(s) but \(cols.count) target column(s) were given.")
            }
            return .table(TableValue(cols: Columns(cols.map(e.colInfo)), rows: t.rows(e.db)))
        }
        d["LOOKUPVALUE"] = { e, a, c, _ in
            let result = try e.columnArg(a[0], c, "LOOKUPVALUE")
            var pairs: [(ColumnID, Value)] = []
            var i = 1
            while i + 1 < a.count {
                pairs.append((try e.columnArg(a[i], c, "LOOKUPVALUE"), try e.scalar(a[i + 1], c)))
                i += 2
            }
            let alternate = i < a.count ? a[i] : nil
            guard let first = pairs.first else { throw DAXError("LOOKUPVALUE needs at least one search column and value.") }
            let resultStore = e.db.column(result).values
            // Candidate rows of the search table from the first pair, narrowed by the others.
            var candidates: [Int32]
            let col0 = e.db.column(first.0)
            if let code = col0.code(of: first.1) { candidates = col0.postings[Int(code)] }
            else { candidates = col0.values.indices.filter { DAXOps.strictEquals(col0.values[$0], first.1) }.map { Int32($0) } }
            for p in pairs.dropFirst() {
                guard p.0.table == first.0.table else { throw DAXError("LOOKUPVALUE: all search columns must belong to the same table.") }
                let vals = e.db.column(p.0).values
                candidates = candidates.filter { DAXOps.strictEquals(vals[Int($0)], p.1) }
            }
            var found = Set<Value>()
            if result.table == first.0.table {
                for r in candidates { found.insert(resultStore[Int(r)]) }
            } else if let map = e.db.relatedRows(from: first.0.table, to: result.table, rel: c.fc.rel) {
                for r in candidates { let rr = map[Int(r)]; if rr >= 0 { found.insert(resultStore[Int(rr)]) } }
            } else {
                throw DAXError("LOOKUPVALUE: the result column must be in the search table or a related table.")
            }
            if found.count == 1 { return .scalar(found.first!) }
            if let alt = alternate { return .scalar(try e.scalar(alt, c)) }
            if found.isEmpty { return .scalar(.null) }
            throw DAXError("LOOKUPVALUE: a table of multiple values was supplied where a single value was expected.")
        }
        return d
    }()

    func earlier(_ cid: ColumnID, _ ctx: Ctx, skip: Int, _ n: Node) throws -> Value {
        var hits: [Value] = []
        for f in ctx.frames.reversed() {
            switch f {
            case .base(let t, let r): if t == cid.table { hits.append(cell(cid, r)) }
            case .row(let cols, let vals): if let k = cols.byLineage[cid] { hits.append(vals[k]) }
            }
        }
        if skip < 0, let v = hits.last { return v }
        guard skip >= 0, skip < hits.count else {
            throw DAXError("EARLIER/EARLIEST refers to an earlier row context which doesn't exist.", range: n.range)
        }
        return hits[skip]
    }
}

extension FilterContext {
    /// ALL / ALLEXCEPT removal: `tables` drops every filter on those tables; `rowTables` only drops row filters.
    func removing(columns: Set<ColumnID>, tables: Set<Int>, rowTables: Set<Int>) -> FilterContext {
        if columns.isEmpty && tables.isEmpty && rowTables.isEmpty { return self }
        let base: [CtxFilter] = filters.compactMap { f in
            if case .rows(let t, _) = f.kind { return tables.contains(t) || rowTables.contains(t) ? nil : f }
            return f.projectingOut { columns.contains($0) || tables.contains($0.table) }
        }
        if base.count == filters.count, zip(base, filters).allSatisfy({ $0 === $1 }) { return self }
        return with(filters: base)
    }
}
