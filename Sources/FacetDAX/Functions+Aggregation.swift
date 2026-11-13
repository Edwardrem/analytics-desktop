import Foundation
import FacetCore

/// Statistical helpers over plain number arrays.
enum Stats {
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
    static func variance(_ xs: [Double], sample: Bool) -> Double? {
        let n = Double(xs.count)
        guard xs.count >= (sample ? 2 : 1) else { return nil }
        let mean = xs.reduce(0, +) / n
        let ss = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return ss / (sample ? n - 1 : n)
    }
    static func percentile(_ xs: [Double], _ k: Double, inclusive: Bool) throws -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = Double(s.count)
        if inclusive {
            guard k >= 0, k <= 1 else { throw DAXError("The percentile value must be between 0 and 1.") }
            let pos = k * (n - 1)
            let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
            return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
        }
        guard k > 0, k < 1 else { throw DAXError("The percentile value must be between 0 and 1 (exclusive).") }
        let pos = k * (n + 1)
        guard pos >= 1, pos <= n else { throw DAXError("PERCENTILE.EXC cannot interpolate for k = \(k) with \(s.count) values.") }
        let lo = Int(pos.rounded(.down))
        let frac = pos - Double(lo)
        return lo >= s.count ? s[s.count - 1] : s[lo - 1] + (s[lo] - s[lo - 1]) * frac
    }
}

extension DAXEngine {
    /// Evaluates an aggregation over already-collected values.
    func aggregate(_ fn: String, _ values: [Value], intResult: Bool, dateResult: Bool = false) throws -> Value {
        func numbers() -> [Double] {
            values.compactMap { v -> Double? in
                switch v {
                case .int(let i): return Double(i)
                case .double(let d): return d
                case .date(let d): return Value.serial(from: d)
                case .bool(let b): return fn.hasSuffix("X") || fn.hasSuffix("A") ? (b ? 1 : 0) : nil
                default: return nil
                }
            }
        }
        func out(_ d: Double?) -> Value {
            guard let d = d else { return .null }
            if dateResult { return .date(Value.date(fromSerial: d)) }
            if intResult, d == d.rounded(), abs(d) < 9e15 { return .int(Int64(d)) }
            return .double(d)
        }
        switch fn {
        case "SUM":
            let xs = numbers()
            return xs.isEmpty ? .null : out(xs.reduce(0, +))
        case "AVERAGE":
            let xs = numbers()
            return xs.isEmpty ? .null : .double(xs.reduce(0, +) / Double(xs.count))
        case "MIN", "MAX":
            var best: Value = .null
            for v in values where !v.isNull {
                if best.isNull { best = v; continue }
                let c = DAXOps.sortCompare(v, best)
                if fn == "MIN" ? c < 0 : c > 0 { best = v }
            }
            return best
        case "COUNT":
            let n = values.reduce(0) { acc, v in
                switch v { case .int, .double, .date: return acc + 1; default: return acc }
            }
            return n == 0 ? .null : .int(Int64(n))
        case "COUNTA":
            let n = values.reduce(0) { $1.isNull ? $0 : $0 + 1 }
            return n == 0 ? .null : .int(Int64(n))
        case "COUNTBLANK":
            let n = values.reduce(0) { acc, v in
                if v.isNull { return acc + 1 }
                if case .string(let s) = v, s.isEmpty { return acc + 1 }
                return acc
            }
            return n == 0 ? .null : .int(Int64(n))
        case "DISTINCTCOUNT":
            let n = Set(values).count
            return n == 0 ? .null : .int(Int64(n))
        case "DISTINCTCOUNTNOBLANK":
            let n = Set(values.filter { !$0.isNull }).count
            return n == 0 ? .null : .int(Int64(n))
        case "MEDIAN": return Stats.median(numbers()).map(Value.double) ?? .null
        case "PRODUCT":
            let xs = numbers()
            return xs.isEmpty ? .null : out(xs.reduce(1, *))
        case "GEOMEAN":
            let xs = numbers()
            guard !xs.isEmpty else { return .null }
            guard xs.allSatisfy({ $0 > 0 }) else { throw DAXError("GEOMEAN requires positive numbers.") }
            return .double(exp(xs.reduce(0) { $0 + log($1) } / Double(xs.count)))
        case "STDEV.S": return Stats.variance(numbers(), sample: true).map { .double($0.squareRoot()) } ?? .null
        case "STDEV.P": return Stats.variance(numbers(), sample: false).map { .double($0.squareRoot()) } ?? .null
        case "VAR.S": return Stats.variance(numbers(), sample: true).map(Value.double) ?? .null
        case "VAR.P": return Stats.variance(numbers(), sample: false).map(Value.double) ?? .null
        default: throw DAXError("Unsupported aggregation \(fn).")
        }
    }

    /// Values of a visual column over the rows a visual calculation aggregates (nil when not a visual column).
    func visualColumnValues(_ node: Node, _ ctx: Ctx) -> [Value]? {
        guard let vc = ctx.visual, case .column(nil, let name, _) = node.kind, let k = vc.grid.cols.byName[name.daxKey] else { return nil }
        let rows = vc.grid.data
        return (vc.aggRows ?? [vc.row]).compactMap { rows[safe: $0]?[k] }
    }

    /// Column values visible in the filter context.
    func visibleValues(_ c: ColumnID, _ fc: FilterContext) -> [Value] {
        let vals = db.column(c).values
        let sel = fc.rows(c.table)
        guard let rows = sel.rows else { return vals }
        return rows.map { vals[Int($0)] }
    }

    func aggregateColumn(_ fn: String, _ args: [Node], _ ctx: Ctx, _ n: Node) throws -> Value {
        guard let a = args.first else { throw DAXError("\(fn) needs a column.") }
        if (fn == "MIN" || fn == "MAX"), args.count == 2 {
            let x = try scalar(args[0], ctx), y = try scalar(args[1], ctx)
            if x.isNull && y.isNull { return .null }
            let c = DAXOps.compare(x, y)
            let pickX = fn == "MIN" ? c <= 0 : c >= 0
            let r = pickX ? x : y
            return r.isNull ? .int(0) : r
        }
        if let vals = visualColumnValues(a, ctx) {
            return try aggregate(fn, vals, intResult: vals.allSatisfy { DAXOps.isIntLike($0) || $0.isNull })
        }
        let cid = try columnArg(a, ctx, fn)
        if !aggregationMappings.isEmpty, let v = try aggregationHit(fn, cid, ctx) { return v }
        let col = db.column(cid)
        let sel = ctx.fc.rows(cid.table)
        // Fast numeric paths.
        if !col.hasText {
            let d = col.doubles
            switch fn {
            case "SUM", "AVERAGE":
                var s = 0.0, k = 0
                if let rows = sel.rows { for r in rows { let x = d[Int(r)]; if !x.isNaN { s += x; k += 1 } } }
                else { for x in d where !x.isNaN { s += x; k += 1 } }
                if k == 0 { return .null }
                if fn == "AVERAGE" { return .double(s / Double(k)) }
                return col.allInt && abs(s) < 9e15 ? .int(Int64(s)) : .double(s)
            case "MIN", "MAX":
                var best = Double.nan
                let isMin = fn == "MIN"
                func take(_ x: Double) { if !x.isNaN, best.isNaN || (isMin ? x < best : x > best) { best = x } }
                if let rows = sel.rows { for r in rows { take(d[Int(r)]) } } else { for x in d { take(x) } }
                if best.isNaN { return .null }
                if col.isDateLike { return .date(Value.date(fromSerial: best)) }
                if col.type == .boolean { return .bool(best != 0) }
                return col.allInt ? .int(Int64(best)) : .double(best)
            default: break
            }
        }
        if fn == "DISTINCTCOUNT" || fn == "DISTINCTCOUNTNOBLANK" {
            let vals = distinctValues(cid, ctx.fc, blankRow: fn == "DISTINCTCOUNT")
            let k = fn == "DISTINCTCOUNT" ? vals.count : vals.filter { !$0.isNull }.count
            return k == 0 ? .null : .int(Int64(k))
        }
        return try aggregate(fn, visibleValues(cid, ctx.fc), intResult: col.allInt, dateResult: false)
    }

    func countRows(_ args: [Node], _ ctx: Ctx) throws -> Value {
        guard let a = arg(args, 0) else {
            if let vc = ctx.visual { return .int(Int64((vc.aggRows ?? [vc.row]).count)) }
            throw DAXError("COUNTROWS needs a table.")
        }
        let (n, c) = deref(a, ctx)
        if case .ident(let name) = n.kind, c.vars?.lookup(name.daxKey) == nil, queryTables[name.daxKey] == nil,
           let ti = db.tableIndex[name.daxKey] {
            try checkTableAccess(ti, n)
            if !aggregationMappings.isEmpty, let v = try aggregationCountHit(ti, c) { return v }
            let sel = c.fc.rows(ti)
            let k = sel.count + (sel.blank && db.hasBlankRow(ti) ? 1 : 0)
            return k == 0 ? .null : .int(Int64(k))
        }
        let k = try table(n, c).count
        return k == 0 ? .null : .int(Int64(k))
    }

    /// Evaluates `expr` for each row of the table argument.
    func iterate(_ tableNode: Node, _ expr: Node, _ ctx: Ctx) throws -> [Value] {
        let t = try table(tableNode, ctx)
        var out: [Value] = []
        out.reserveCapacity(t.count)
        try forEachRow(t, ctx) { c, _ in out.append(try scalar(expr, c)) }
        return out
    }

    static let aggregationFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        for name in ["SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "COUNTBLANK", "DISTINCTCOUNT", "DISTINCTCOUNTNOBLANK",
                     "MEDIAN", "PRODUCT", "GEOMEAN", "STDEV.S", "STDEV.P", "VAR.S", "VAR.P"] {
            d[name] = { e, a, c, n in .scalar(try e.aggregateColumn(name, a, c, n)) }
        }
        d["APPROXIMATEDISTINCTCOUNT"] = { e, a, c, n in .scalar(try e.aggregateColumn("DISTINCTCOUNT", a, c, n)) }
        d["AVERAGEA"] = { e, a, c, n in .scalar(try e.aggregateColumn("AVERAGE", a, c, n)) }
        d["MINA"] = { e, a, c, n in .scalar(try e.aggregateColumn("MIN", a, c, n)) }
        d["MAXA"] = { e, a, c, n in .scalar(try e.aggregateColumn("MAX", a, c, n)) }
        d["COUNTROWS"] = { e, a, c, _ in .scalar(try e.countRows(a, c)) }
        for (name, inclusive) in [("PERCENTILE.INC", true), ("PERCENTILE.EXC", false)] {
            d[name] = { e, a, c, _ in
                let k = try DAXOps.number(e.scalar(a[1], c))
                let vals: [Value]
                if let v = e.visualColumnValues(a[0], c) { vals = v } else { vals = e.visibleValues(try e.columnArg(a[0], c, name), c.fc) }
                return .scalar(try Stats.percentile(vals.compactMap { $0.isNumber ? $0.asDouble : nil }, k, inclusive: inclusive).map(Value.double) ?? .null)
            }
        }
        return d
    }()

    static let iteratorFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        let map = ["SUMX": "SUM", "AVERAGEX": "AVERAGE", "MINX": "MIN", "MAXX": "MAX", "COUNTX": "COUNT", "COUNTAX": "COUNTA",
                   "MEDIANX": "MEDIAN", "PRODUCTX": "PRODUCT", "GEOMEANX": "GEOMEAN", "STDEVX.S": "STDEV.S", "STDEVX.P": "STDEV.P",
                   "VARX.S": "VAR.S", "VARX.P": "VAR.P"]
        for (x, base) in map {
            d[x] = { e, a, c, _ in
                let vals = try e.iterate(a[0], a[1], c)
                return .scalar(try e.aggregate(base, vals, intResult: vals.allSatisfy { DAXOps.isIntLike($0) || $0.isNull }))
            }
        }
        for (name, inclusive) in [("PERCENTILEX.INC", true), ("PERCENTILEX.EXC", false)] {
            d[name] = { e, a, c, _ in
                let k = try DAXOps.number(e.scalar(a[2], c))
                let vals = try e.iterate(a[0], a[1], c).compactMap { $0.isNumber ? $0.asDouble : nil }
                return .scalar(try Stats.percentile(vals, k, inclusive: inclusive).map(Value.double) ?? .null)
            }
        }
        d["CONCATENATEX"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            let delim = try e.scalarArg(a, 2, c).asString
            var orderNodes: [(Node, Bool)] = []
            var i = 3
            while i < a.count {
                if a[i].isMissing { i += 1; continue }
                let desc = (try e.orderDescending(a, i + 1, c)) ?? false
                orderNodes.append((a[i], desc)); i += 2
            }
            var items: [(String, [Value])] = []
            try e.forEachRow(t, c) { rc, _ in
                let s = try e.scalar(a[1], rc)
                items.append((s.asString, try orderNodes.map { try e.scalar($0.0, rc) }))
            }
            if !orderNodes.isEmpty {
                let idx = items.indices.sorted { x, y in
                    for (k, o) in orderNodes.enumerated() {
                        let cmp = DAXOps.sortCompare(items[x].1[k], items[y].1[k])
                        if cmp != 0 { return o.1 ? cmp > 0 : cmp < 0 }
                    }
                    return x < y
                }
                items = idx.map { items[$0] }
            }
            return .scalar(items.isEmpty ? .null : .string(items.map(\.0).joined(separator: delim)))
        }
        d["RANKX"] = { e, a, c, _ in
            let vals = try e.iterate(a[0], a[1], c)
            let v: Value
            if let va = e.arg(a, 2) { v = try e.scalar(va, c) } else { v = try e.scalar(a[1], c) }
            let asc = !((try e.orderDescending(a, 3, c)) ?? true)
            let dense = (try e.keywordArg(a, 4, c)) == "DENSE"
            var better = 0
            var distinct = Set<Value>()
            for x in vals {
                let cmp = DAXOps.compare(x, v)
                if asc ? cmp < 0 : cmp > 0 { better += 1; distinct.insert(x.isNull ? .int(0) : x) }
            }
            return .scalar(.int(Int64((dense ? distinct.count : better) + 1)))
        }
        for (name, last, wantValue) in [("FIRSTNONBLANK", false, false), ("LASTNONBLANK", true, false),
                                        ("FIRSTNONBLANKVALUE", false, true), ("LASTNONBLANKVALUE", true, true)] {
            d[name] = { e, a, c, _ in
                let cid = try e.columnArg(a[0], c, name)
                var vals = e.distinctValues(cid, c.fc, blankRow: false).filter { !$0.isNull }
                vals.sort { last ? $1 < $0 : $0 < $1 }
                if !wantValue, case .const(let k) = a[1].kind { return .scalar(k.isNull ? .null : (vals.first ?? .null)) }
                let cols = Columns([e.colInfo(cid)])
                var rc = c
                rc.frames.append(.row(cols, [.null]))
                for v in vals {
                    rc.frames[rc.frames.count - 1] = .row(cols, [v])
                    let x = try e.scalar(a[1], rc)
                    if !x.isNull { return .scalar(wantValue ? x : v) }
                }
                return .scalar(.null)
            }
        }
        d["XNPV"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            var values: [Double] = [], dates: [Date] = []
            try e.forEachRow(t, c) { rc, _ in
                let v = try e.scalar(a[1], rc), dt = try e.scalar(a[2], rc)
                guard let x = try DAXOps.num(v), let when = dt.asDate else { return }
                values.append(x); dates.append(when)
            }
            guard !values.isEmpty else { return .scalar(.null) }
            return .scalar(.double(PureFinancial.xnpv(rate: try DAXOps.number(e.scalar(a[3], c)), values: values, dates: dates)))
        }
        d["XIRR"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            var values: [Double] = [], dates: [Date] = []
            try e.forEachRow(t, c) { rc, _ in
                let v = try e.scalar(a[1], rc), dt = try e.scalar(a[2], rc)
                guard let x = try DAXOps.num(v), let when = dt.asDate else { return }
                values.append(x); dates.append(when)
            }
            let guess = try e.arg(a, 3).map { try DAXOps.number(e.scalar($0, c)) } ?? 0.1
            do { return .scalar(.double(try PureFinancial.xirr(values: values, dates: dates, guess: guess))) } catch {
                if let alt = e.arg(a, 4) { return .scalar(try e.scalar(alt, c)) }
                throw error
            }
        }
        return d
    }()

    /// Reads an order argument: ASC / DESC keyword, or 0/FALSE (descending) and 1/TRUE (ascending). Returns nil when omitted.
    func orderDescending(_ args: [Node], _ i: Int, _ ctx: Ctx) throws -> Bool? {
        guard let a = arg(args, i) else { return nil }
        if case .ident(let s) = a.kind, ctx.vars?.lookup(s.daxKey) == nil {
            let u = s.uppercased()
            if u.hasPrefix("DESC") { return true }
            if u.hasPrefix("ASC") { return false }
        }
        let v = try scalar(a, ctx)
        if case .string(let s) = v { return s.uppercased().hasPrefix("DESC") }
        return !(try DAXOps.truthy(v))
    }

    static let statFns: [String: Fn] = [:]
}
