import Foundation
import FacetCore

struct ValueSpec {
    let name: String
    let expr: Node
    /// IGNORE(): the value does not keep a row alive on its own.
    var ignored = false
}

/// Rows of a table bucketed by the values of grouping columns.
struct Partition {
    var keys: [[Value]]
    var buckets: [[Int32]]
}

extension DAXEngine {
    /// Buckets `rows` of table `f` by the grouping columns (own or related many→one). Nil when a column is not reachable.
    func partition(table f: Int, rows: [Int32], groups: [ColumnID], rel: RelState) -> Partition? {
        var vecs: [[Int32]] = []
        for g in groups {
            guard let v = db.relatedCodes(table: f, column: g, rel: rel) else { return nil }
            vecs.append(v)
        }
        let dicts = groups.map { db.column($0).dict }
        let nullSlot: [Int32] = groups.enumerated().map { i, g in db.column(g).code(of: .null) ?? Int32(dicts[i].count) }
        let sizes = dicts.map { $0.count + 1 }
        var gidOfRow = [Int32](repeating: 0, count: rows.count)
        var slotsOfGid: [[Int32]] = []
        var counts: [Int] = []
        if groups.count == 1 {
            var gidOfSlot = [Int32](repeating: -1, count: sizes[0])
            let v = vecs[0], ns = nullSlot[0]
            for (i, r) in rows.enumerated() {
                let code = v[Int(r)]
                let slot = Int(code < 0 ? ns : code)
                var g = gidOfSlot[slot]
                if g < 0 { g = Int32(slotsOfGid.count); gidOfSlot[slot] = g; slotsOfGid.append([Int32(slot)]); counts.append(0) }
                gidOfRow[i] = g; counts[Int(g)] += 1
            }
        } else {
            var total = 1.0
            for s in sizes { total *= Double(s) }
            if total < 4e18 {
                var gidOfKey: [Int: Int32] = [:]
                for (i, r) in rows.enumerated() {
                    var key = 0
                    for k in 0..<vecs.count {
                        let code = vecs[k][Int(r)]
                        key = key &* sizes[k] &+ Int(code < 0 ? nullSlot[k] : code)
                    }
                    var g = gidOfKey[key] ?? -1
                    if g < 0 {
                        g = Int32(slotsOfGid.count); gidOfKey[key] = g; counts.append(0)
                        slotsOfGid.append((0..<vecs.count).map { k in let code = vecs[k][Int(r)]; return code < 0 ? nullSlot[k] : code })
                    }
                    gidOfRow[i] = g; counts[Int(g)] += 1
                }
            } else {
                var gidOfKey: [[Int32]: Int32] = [:]
                for (i, r) in rows.enumerated() {
                    let key: [Int32] = (0..<vecs.count).map { k in let code = vecs[k][Int(r)]; return code < 0 ? nullSlot[k] : code }
                    var g = gidOfKey[key] ?? -1
                    if g < 0 { g = Int32(slotsOfGid.count); gidOfKey[key] = g; counts.append(0); slotsOfGid.append(key) }
                    gidOfRow[i] = g; counts[Int(g)] += 1
                }
            }
        }
        var buckets: [[Int32]] = counts.map { var a = [Int32](); a.reserveCapacity($0); return a }
        for (i, r) in rows.enumerated() { buckets[Int(gidOfRow[i])].append(r) }
        let keys: [[Value]] = slotsOfGid.map { slots in
            slots.enumerated().map { k, s in Int(s) < dicts[k].count ? dicts[k][Int(s)] : .null }
        }
        return Partition(keys: keys, buckets: buckets)
    }

    private static let bindAggregates: Set<String> = ["SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "COUNTBLANK", "DISTINCTCOUNT",
        "DISTINCTCOUNTNOBLANK", "APPROXIMATEDISTINCTCOUNT", "MEDIAN", "PRODUCT", "GEOMEAN", "STDEV.S", "STDEV.P", "VAR.S", "VAR.P",
        "PERCENTILE.INC", "PERCENTILE.EXC"]
    private static let bindIterators: Set<String> = ["SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX", "COUNTAX", "MEDIANX", "PRODUCTX",
        "GEOMEANX", "STDEVX.S", "STDEVX.P", "VARX.S", "VARX.P", "PERCENTILEX.INC", "PERCENTILEX.EXC", "CONCATENATEX"]
    private static let bindPassThrough: Set<String> = ["ROUND", "ROUNDUP", "ROUNDDOWN", "ABS", "INT", "TRUNC"]

    /// Tables such that the expression is certainly BLANK when none of them has visible rows; nil when unknown.
    func factBinding(_ n: Node, _ env: [String: Set<Int>?], _ depth: Int) -> Set<Int>? {
        guard depth < 24 else { return nil }
        func tableOf(_ node: Node) -> Int? {
            switch node.kind {
            case .ident(let name):
                if env[name.daxKey] != nil || queryTables[name.daxKey] != nil { return nil }
                return db.tableIndex[name.daxKey]
            case .call(let name, let args):
                if name == "FILTER", let f = args.first { return tableOf(f) }
                if name == "VALUES" || name == "DISTINCT", let f = args.first {
                    if case .column(let t?, let c, nil) = f.kind { return db.columnID(table: t, column: c)?.table }
                    return tableOf(f)
                }
                return nil
            default: return nil
            }
        }
        switch n.kind {
        case .column(let t, let name, _):
            guard t == nil || db.columnID(table: t!, column: name) == nil, let m = lookupMeasure(name.daxKey) else { return nil }
            return factBinding(m.expr, [:], depth + 1)
        case .ident(let name):
            if let b = env[name.daxKey] { return b }
            return nil
        case .unary(let op, let e):
            return op == .not ? nil : factBinding(e, env, depth)
        case .binary(let op, let l, let r):
            switch op {
            case .mul: return factBinding(l, env, depth) ?? factBinding(r, env, depth)
            case .div: return factBinding(l, env, depth)
            case .add, .sub:
                guard let a = factBinding(l, env, depth), let b = factBinding(r, env, depth) else { return nil }
                return a.union(b)
            default: return nil
            }
        case .vars(let vs, let body):
            var e2 = env
            for v in vs { e2[v.name.daxKey] = .some(factBinding(v.expr, e2, depth)) }
            return factBinding(body, e2, depth)
        case .call(let name, let args):
            if userFunction(name) != nil { return nil }
            if DAXEngine.bindAggregates.contains(name), args.count == 1 || name.hasPrefix("PERCENTILE") {
                if case .column(let t?, let c, nil) = args[0].kind, let cid = db.columnID(table: t, column: c) { return [cid.table] }
                return nil
            }
            if name == "COUNTROWS", args.count == 1 { return tableOf(args[0]).map { [$0] } }
            if DAXEngine.bindIterators.contains(name), let f = args.first { return tableOf(f).map { [$0] } }
            if DAXEngine.bindPassThrough.contains(name), let f = args.first { return factBinding(f, env, depth) }
            if name == "DIVIDE", args.count == 2 { return factBinding(args[0], env, depth) }
            if name == "IF" || name == "IF.EAGER" {
                guard args.count >= 2, let a = factBinding(args[1], env, depth) else { return nil }
                if args.count == 2 { return a }
                guard let b = factBinding(args[2], env, depth) else { return nil }
                return a.union(b)
            }
            return nil
        default: return nil
        }
    }

    /// Model tables an expression touches (through measures), used to pick driving fact tables for large cross joins.
    func referencedTables(_ n: Node, into out: inout Set<Int>, depth: Int = 0) {
        guard depth < 24 else { return }
        n.walk { x in
            switch x.kind {
            case .column(let t, let name, _):
                if let t = t, let cid = db.columnID(table: t, column: name) { out.insert(cid.table) }
                else if let m = lookupMeasure(name.daxKey) { referencedTables(m.expr, into: &out, depth: depth + 1) }
            case .ident(let name):
                if let ti = db.tableIndex[name.daxKey] { out.insert(ti) }
            default: break
            }
        }
    }

    func groupFilters(_ groups: [ColumnID], _ key: [Value]) -> [CtxFilter] {
        zip(groups, key).map { db.singleFilter($0, $1, group: true) }
    }

    /// Candidate group combinations (with known fact partitions, when available) for a grouped evaluation.
    func groupCombos(groups: [ColumnID], values: [ValueSpec], ctx: Ctx) throws -> (keys: [[Value]], seeds: [(table: Int, rows: [[Value]: [Int32]])]) {
        let rel = ctx.fc.rel
        func existing(in f: Int) -> Partition? {
            partition(table: f, rows: ctx.fc.rows(f).indices, groups: groups, rel: rel)
        }
        func crossJoin() throws -> [[Value]] {
            var byTable: [(Int, [Int])] = []
            for (k, g) in groups.enumerated() {
                if let j = byTable.firstIndex(where: { $0.0 == g.table }) { byTable[j].1.append(k) } else { byTable.append((g.table, [k])) }
            }
            var combos: [[Value]] = [[]]
            var order: [Int] = []
            for (_, ks) in byTable {
                let part = try distinctColumns(ks.map { groups[$0] }, ctx.fc, blankRow: true).data
                guard combos.count * max(part.count, 1) <= 3_000_000 else {
                    throw DAXError("The query would evaluate more than 3 million combinations of grouping values. Add a filter or remove a grouping column.")
                }
                var next: [[Value]] = []
                next.reserveCapacity(combos.count * part.count)
                for x in combos { for y in part { next.append(x + y) } }
                combos = next
                order += ks
            }
            return combos.map { combo in
                var key = [Value](repeating: .null, count: groups.count)
                for (pos, k) in order.enumerated() { key[k] = combo[pos] }
                return key
            }
        }
        let groupTables = Set(groups.map { $0.table })

        if values.isEmpty {
            if groupTables.count == 1 { return (try distinctColumns(groups, ctx.fc, blankRow: true).data, []) }
            // Prefer combinations that exist in a table related to every grouping table.
            for t in db.tables where !groupTables.contains(t.index) {
                if groups.allSatisfy({ db.relatedPath(from: t.index, to: $0.table, rel: rel) != nil }), let p = existing(in: t.index) {
                    return (p.keys, [])
                }
            }
            return (try crossJoin(), [])
        }

        // Exact fast path: every value is blank unless its fact table has rows for the combination.
        if activeCalcItem(ctx.fc) == nil {
            var facts = Set<Int>()
            var bound = true
            for v in values where !v.ignored {
                guard let b = factBinding(v.expr, [:], 0), !b.isEmpty else { bound = false; break }
                facts.formUnion(b)
            }
            if bound, !facts.isEmpty {
                var parts: [(Int, Partition)] = []
                for f in facts.sorted() {
                    guard let p = existing(in: f) else { bound = false; break }
                    parts.append((f, p))
                }
                if bound {
                    var keys: [[Value]] = []
                    var seen = Set<[Value]>()
                    var seeds: [(table: Int, rows: [[Value]: [Int32]])] = []
                    for (f, p) in parts {
                        var map: [[Value]: [Int32]] = [:]
                        map.reserveCapacity(p.keys.count)
                        for (i, k) in p.keys.enumerated() {
                            map[k] = p.buckets[i]
                            if seen.insert(k).inserted { keys.append(k) }
                        }
                        seeds.append((f, map))
                    }
                    return (keys, seeds)
                }
            }
        }

        // General path: cross join of the grouping values per table; very large joins fall back to combinations
        // that exist in the fact tables the values refer to.
        var size = 1.0
        var seenTables = Set<Int>()
        for g in groups where seenTables.insert(g.table).inserted {
            size *= Double(max(1, ctx.fc.rows(g.table).count))
        }
        if size > 200_000 {
            var refs = Set<Int>()
            for v in values { referencedTables(v.expr, into: &refs) }
            var keys: [[Value]] = []
            var seen = Set<[Value]>()
            var any = false
            for f in refs.sorted() where !groupTables.contains(f) || groupTables.count == 1 {
                guard let p = partition(table: f, rows: ctx.fc.removing(columns: [], tables: groupTables, rowTables: []).rows(f).indices, groups: groups, rel: rel) else { continue }
                any = true
                for k in p.keys where seen.insert(k).inserted { keys.append(k) }
            }
            if any {
                // Keep only combinations whose grouping values are visible in the current context.
                let visible = groups.map { Set(distinctValues($0, ctx.fc, blankRow: true)) }
                return (keys.filter { k in k.indices.allSatisfy { visible[$0].contains(k[$0]) } }, [])
            }
        }
        return (try crossJoin(), [])
    }

    /// Grouped evaluation shared by SUMMARIZECOLUMNS and the visual query layer.
    /// Returns one row per surviving combination: grouping values followed by value results.
    func summarizeCore(groups: [ColumnID], values: [ValueSpec], ctx: Ctx, keepBlankRows: Bool = false) throws -> [[Value]] {
        var base = Ctx(fc: ctx.fc)
        base.selected = ctx.selected ?? ctx.fc
        base.vars = ctx.vars
        base.depth = ctx.depth
        if groups.isEmpty {
            return [try values.map { try scalar($0.expr, base) }]
        }
        let (keys, seeds) = try groupCombos(groups: groups, values: values, ctx: ctx)
        if values.isEmpty { return keys }
        var out: [[Value]] = []
        out.reserveCapacity(keys.count)
        for key in keys {
            var c = base
            c.fc = ctx.fc.adding(groupFilters(groups, key), keep: true)
            for s in seeds {
                let n = db.tables[s.table].rowCount
                if let rows = s.rows[key] { c.fc.seed(s.table, RowSel(n: n, rows: rows.count == n ? nil : rows, blank: false)) }
                else { c.fc.seed(s.table, RowSel(n: n, rows: [], blank: false)) }
            }
            var row = key
            var anyValue = false
            for v in values {
                let x = try scalar(v.expr, c)
                if !x.isNull && !v.ignored { anyValue = true }
                row.append(x)
            }
            if anyValue || keepBlankRows { out.append(row) }
        }
        return out
    }

    private struct SummarizeArgs {
        var plain: [ColumnID] = []
        /// Output layout: group column index (into `allGroups`) or rollup flag.
        var layout: [(group: Int, flagName: String?)] = []
        var allGroups: [ColumnID] = []
        var rollup: [Int] = []          // indices into allGroups, in rollup order
        var filters: [Node] = []
        var values: [ValueSpec] = []
    }

    private func parseSummarizeColumns(_ a: [Node], _ ctx: Ctx) throws -> SummarizeArgs {
        var s = SummarizeArgs()
        var i = 0
        func addGroup(_ cid: ColumnID, rollup: Bool, flag: String?) {
            s.allGroups.append(cid)
            let gi = s.allGroups.count - 1
            if rollup { s.rollup.append(gi) }
            s.layout.append((gi, nil))
            if let f = flag { s.layout.append((gi, f)) }
        }
        while i < a.count {
            let (n, c) = deref(a[i], ctx)
            if n.stringConst != nil { break }
            if case .call(let name, let args) = n.kind, name == "ROLLUPADDISSUBTOTAL" || name == "ROLLUPGROUP" || name == "ROLLUP" {
                var k = 0
                while k < args.count {
                    if case .call("ROLLUPGROUP", let inner) = args[k].kind {
                        for g in inner { addGroup(try columnArg(g, c, name), rollup: true, flag: nil) }
                        k += 1; continue
                    }
                    let cid = try columnArg(args[k], c, name)
                    if name == "ROLLUPADDISSUBTOTAL", let flag = args[safe: k + 1]?.stringConst {
                        addGroup(cid, rollup: true, flag: flag); k += 2
                    } else { addGroup(cid, rollup: true, flag: nil); k += 1 }
                }
            } else if let cid = try modelColumn(n, c) {
                addGroup(cid, rollup: false, flag: nil)
            } else if case .call("NONVISUAL", let inner) = n.kind, let f = inner.first {
                s.filters.append(f)
            } else {
                s.filters.append(n)
            }
            i += 1
        }
        while i < a.count {
            guard let name = a[i].stringConst, i + 1 < a.count else {
                throw DAXError("SUMMARIZECOLUMNS expects pairs of a name in double quotes and an expression after the grouping columns and filters.", range: a[i].range)
            }
            var expr = a[i + 1]
            var ignored = false
            if case .call("IGNORE", let inner) = expr.kind, let f = inner.first { expr = f; ignored = true }
            s.values.append(ValueSpec(name: name, expr: expr, ignored: ignored))
            i += 2
        }
        return s
    }

    static let summarizeFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        d["SUMMARIZECOLUMNS"] = { e, a, c, _ in
            let s = try e.parseSummarizeColumns(a, c)
            var inner = try e.calculateContext(s.filters[...], c)
            inner.selected = inner.fc
            let rollupSet = Set(s.rollup)
            let plainIdx = s.allGroups.indices.filter { !rollupSet.contains($0) }
            var rows: [[Value]] = []
            // One pass per rollup depth: detail first, then each subtotal level.
            for depth in stride(from: s.rollup.count, through: 0, by: -1) {
                let activeIdx = plainIdx + s.rollup.prefix(depth)
                let part = try e.summarizeCore(groups: activeIdx.map { s.allGroups[$0] }, values: s.values, ctx: inner)
                for r in part {
                    var row: [Value] = []
                    for item in s.layout {
                        let pos = activeIdx.firstIndex(of: item.group)
                        if let f = item.flagName { _ = f; row.append(.bool(pos == nil)) }
                        else { row.append(pos.map { r[$0] } ?? .null) }
                    }
                    row.append(contentsOf: r[activeIdx.count...])
                    rows.append(row)
                }
                if s.rollup.isEmpty { break }
            }
            var infos: [ColInfo] = s.layout.map { item in item.flagName.map { ColInfo(name: $0, type: .boolean) } ?? e.colInfo(s.allGroups[item.group]) }
            infos += s.values.map { ColInfo(name: $0.name) }
            return .table(TableValue(cols: Columns(infos), rows: rows))
        }
        d["SUMMARIZE"] = { e, a, c, _ in try e.summarize(a, c) }
        d["GROUPBY"] = { e, a, c, _ in
            let t = try e.table(a[0], c).materialized(e.db)
            var groupIdx: [Int] = []
            var i = 1
            while i < a.count, a[i].stringConst == nil {
                let (n, ac) = e.deref(a[i], c)
                guard case .column(let tn, let cn, _) = n.kind else { throw DAXError("GROUPBY expects grouping columns before the name/expression pairs.", range: n.range) }
                var idx = t.cols.index(table: tn, name: cn)
                if idx == nil, let cid = try e.modelColumn(n, ac) { idx = t.cols.byLineage[cid] }
                guard let k = idx else { throw DAXError("GROUPBY: column [\(cn)] is not in the table being grouped.", range: n.range) }
                groupIdx.append(k); i += 1
            }
            let pairs = try e.namedPairs(a[i...], "GROUPBY")
            var order: [[Value]] = []
            var buckets: [[Value]: [[Value]]] = [:]
            for row in t.data {
                let key = groupIdx.map { row[$0] }
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(row)
            }
            var out: [[Value]] = []
            for key in order {
                var gc = c
                gc.currentGroup = TableValue(cols: t.cols, rows: buckets[key] ?? [])
                out.append(key + (try pairs.map { try e.scalar($0.1, gc) }))
            }
            return .table(TableValue(cols: Columns(groupIdx.map { t.cols.infos[$0] } + pairs.map { ColInfo(name: $0.0) }), rows: out))
        }
        d["ISSUBTOTAL"] = { e, a, c, _ in
            let cid = try e.columnArg(a[0], c, "ISSUBTOTAL")
            if case .scalar(let v)? = c.vars?.lookup("__subtotal|\(cid.table)|\(cid.col)") { return .scalar(v) }
            return .scalar(.bool(false))
        }
        for name in ["ROLLUP", "ROLLUPGROUP", "ROLLUPADDISSUBTOTAL", "ROLLUPISSUBTOTAL", "IGNORE", "NONVISUAL"] {
            d[name] = { _, _, _, _ in throw DAXError("\(name) can only be used inside SUMMARIZE or SUMMARIZECOLUMNS.") }
        }
        return d
    }()

    func namedPairs(_ a: ArraySlice<Node>, _ fn: String) throws -> [(String, Node)] {
        var out: [(String, Node)] = []
        var i = a.startIndex
        while i < a.endIndex {
            guard let name = a[i].stringConst, i + 1 < a.endIndex else {
                throw DAXError("\(fn) expects pairs of a column name in double quotes and an expression.", range: a[i].range)
            }
            out.append((name, a[i + 1]))
            i += 2
        }
        return out
    }

    private func summarize(_ a: [Node], _ ctx: Ctx) throws -> DAXResult {
        let t = try table(a[0], ctx)
        var groupNodes: [(Node, Bool)] = []     // (column node, isRollup)
        var i = 1
        while i < a.count, a[i].stringConst == nil {
            if case .call(let name, let args) = a[i].kind, name == "ROLLUP" || name == "ROLLUPGROUP" {
                for g in args {
                    if case .call("ROLLUPGROUP", let inner) = g.kind { inner.forEach { groupNodes.append(($0, true)) } }
                    else { groupNodes.append((g, true)) }
                }
            } else { groupNodes.append((a[i], false)) }
            i += 1
        }
        let pairs = try namedPairs(a[i...], "SUMMARIZE")
        let rollupCount = groupNodes.filter { $0.1 }.count
        let plain = groupNodes.indices.filter { !groupNodes[$0].1 }
        let rolled = groupNodes.indices.filter { groupNodes[$0].1 }
        var rows: [[Value]] = []
        var infos: [ColInfo] = []

        if let b = t.base {
            let cids = try groupNodes.map { try columnArg($0.0, ctx, "SUMMARIZE") }
            for cid in cids where cid.table != b.table && db.relatedPath(from: b.table, to: cid.table, rel: ctx.fc.rel) == nil {
                throw DAXError("SUMMARIZE: column \(db.name(cid)) is not related to table '\(db.tables[b.table].name)'.")
            }
            infos = cids.map(colInfo)
            let realRows = b.rows.filter { $0 >= 0 }
            for depth in stride(from: rollupCount, through: 0, by: -1) {
                let active = plain + rolled.prefix(depth)
                guard let p = partition(table: b.table, rows: realRows, groups: active.map { cids[$0] }, rel: ctx.fc.rel) else { continue }
                var keys = p.keys, buckets = p.buckets
                if active.isEmpty, keys.isEmpty { keys = [[]]; buckets = [[]] }
                let activeInfos = Columns(active.map { infos[$0] })
                for (gi, key) in keys.enumerated() {
                    var row = [Value](repeating: .null, count: cids.count)
                    for (pos, k) in active.enumerated() { row[k] = key[pos] }
                    if !pairs.isEmpty {
                        var gc = ctx
                        let n = db.tables[b.table].rowCount
                        gc.fc = ctx.fc.adding([CtxFilter(.rows(b.table, RowSel(n: n, rows: buckets[gi], blank: false)))])
                        gc.frames.append(.row(activeInfos, key))
                        for k in rolled {
                            gc.vars = VarScope(name: "__subtotal|\(cids[k].table)|\(cids[k].col)", value: .scalar(.bool(!active.contains(k))), parent: gc.vars)
                        }
                        row += try pairs.map { try scalar($0.1, gc) }
                    }
                    rows.append(row)
                }
                if rollupCount == 0 { break }
            }
        } else {
            var idx: [Int] = []
            for (n0, _) in groupNodes {
                let (n, ac) = deref(n0, ctx)
                guard case .column(let tn, let cn, _) = n.kind else { throw DAXError("SUMMARIZE expects grouping columns after the table.", range: n.range) }
                var k = t.cols.index(table: tn, name: cn)
                if k == nil, let cid = try modelColumn(n, ac) { k = t.cols.byLineage[cid] }
                guard let found = k else { throw DAXError("SUMMARIZE: column [\(cn)] is not in the table being summarised.", range: n.range) }
                idx.append(found)
            }
            infos = idx.map { t.cols.infos[$0] }
            for depth in stride(from: rollupCount, through: 0, by: -1) {
                let active = plain + rolled.prefix(depth)
                var order: [[Value]] = []
                var buckets: [[Value]: [[Value]]] = [:]
                for r in t.data {
                    let key = active.map { r[idx[$0]] }
                    if buckets[key] == nil { order.append(key) }
                    buckets[key, default: []].append(r)
                }
                let activeInfos = Columns(active.map { infos[$0] })
                for key in order {
                    var row = [Value](repeating: .null, count: idx.count)
                    for (pos, k) in active.enumerated() { row[k] = key[pos] }
                    if !pairs.isEmpty {
                        var gc = ctx
                        var fs: [CtxFilter] = []
                        for (pos, info) in activeInfos.infos.enumerated() { if let l = info.lineage { fs.append(CtxFilter.single(l, key[pos])) } }
                        gc.fc = ctx.fc.adding(fs)
                        gc.frames.append(.row(activeInfos, key))
                        gc.currentGroup = TableValue(cols: t.cols, rows: buckets[key] ?? [])
                        row += try pairs.map { try scalar($0.1, gc) }
                    }
                    rows.append(row)
                }
                if rollupCount == 0 { break }
            }
        }
        return .table(TableValue(cols: Columns(infos + pairs.map { ColInfo(name: $0.0) }), rows: rows))
    }
}
