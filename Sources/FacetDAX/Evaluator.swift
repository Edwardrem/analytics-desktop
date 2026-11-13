import Foundation
import FacetCore

typealias Fn = (DAXEngine, [Node], Ctx, Node) throws -> DAXResult

final class CallBox {
    enum Kind { case fn(Fn), pure(PureFn) }
    let kind: Kind
    init(_ k: Kind) { kind = k }
}
final class ColRefBox {
    let cid: ColumnID?
    let nameKey: String
    let gen: Int
    init(cid: ColumnID?, nameKey: String, gen: Int) { self.cid = cid; self.nameKey = nameKey; self.gen = gen }
}
final class StrBox { let s: String; init(_ s: String) { self.s = s } }
final class ConstSetBox { let set: Set<Value>; init(_ s: Set<Value>) { set = s } }

extension DAXEngine {
    static let builtins: [String: Fn] = {
        var d: [String: Fn] = [:]
        for part in [aggregationFns, iteratorFns, filterFns, tableFns, summarizeFns, windowFns, timeFns, logicalFns, infoFns, visualCalcFns, statFns] {
            d.merge(part) { a, _ in a }
        }
        return d
    }()
    static let pureFns: [String: PureFn] = {
        var d: [String: PureFn] = [:]
        for part in [PureMath.functions, PureText.functions, PureDate.functions, PureFinancial.functions] { d.merge(part) { a, _ in a } }
        return d
    }()

    // MARK: Core evaluation

    func scalar(_ n: Node, _ ctx: Ctx) throws -> Value {
        switch n.kind {
        case .const(let v): return v
        case .column(let t, let name, let sub): return try columnValue(n, t, name, sub, ctx)
        case .ident(let name): return try identScalar(n, name, ctx)
        case .call: return try toScalar(call(n, ctx), n)
        case .binary(let op, let l, let r): return try binary(op, l, r, ctx, n)
        case .unary(let op, let e):
            let v = try scalar(e, ctx)
            switch op {
            case .neg: return try DAXOps.negate(v)
            case .plus: return v
            case .not: return .bool(!(try DAXOps.truthy(v)))
            }
        case .vars(let vs, let body): return try scalar(body, bind(vs, ctx))
        case .tableCtor: return try toScalar(.table(table(n, ctx)), n)
        case .missing: return .null
        }
    }

    func toScalar(_ r: DAXResult, _ n: Node) throws -> Value {
        switch r {
        case .scalar(let v): return v
        case .table(let t):
            if t.count == 0 { return .null }
            guard t.count == 1, t.cols.count == 1 else {
                throw DAXError("A table of multiple values was supplied where a single value was expected.", range: n.range)
            }
            return t.rows(db)[0][0]
        }
    }

    func bind(_ vs: [(name: String, expr: Node)], _ ctx: Ctx) throws -> Ctx {
        var c = ctx
        for v in vs {
            let value: VarValue
            switch try eval(v.expr, c) {
            case .scalar(let s): value = .scalar(s)
            case .table(let t): value = .table(t)
            }
            c.vars = VarScope(name: v.name, value: value, parent: c.vars)
        }
        return c
    }

    private func identKey(_ n: Node, _ name: String) -> String {
        if let b = n.cache as? StrBox { return b.s }
        let k = name.daxKey
        n.cache = StrBox(k)
        return k
    }

    /// Follows identifiers bound to `expr`-mode parameters to the argument expression and its scope.
    func deref(_ node: Node, _ ctx: Ctx) -> (Node, Ctx) {
        var n = node, c = ctx
        var guardCount = 0
        while case .ident(let name) = n.kind, guardCount < 64, let v = c.vars?.lookup(identKey(n, name)), case .thunk(let tn, let scope) = v {
            n = tn; c.vars = scope; guardCount += 1
        }
        return (n, c)
    }

    private func identScalar(_ n: Node, _ name: String, _ ctx: Ctx) throws -> Value {
        let key = identKey(n, name)
        if let v = ctx.vars?.lookup(key) {
            switch v {
            case .scalar(let s): return s
            case .table(let t): return try toScalar(.table(t), n)
            case .thunk(let tn, let scope): var c = ctx; c.vars = scope; return try scalar(tn, c)
            }
        }
        if queryTables[key] != nil || db.tableIndex[key] != nil { return try toScalar(.table(table(n, ctx)), n) }
        switch key {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: throw DAXError("Cannot find the name '\(name)'. It is not a variable, table or parameter.", range: n.range)
        }
    }

    func table(_ n: Node, _ ctx: Ctx) throws -> TableValue {
        switch n.kind {
        case .ident(let name):
            let key = identKey(n, name)
            if let v = ctx.vars?.lookup(key) {
                switch v {
                case .table(let t): return t
                case .thunk(let tn, let scope): var c = ctx; c.vars = scope; return try table(tn, c)
                case .scalar: throw DAXError("'\(name)' is a scalar variable but a table is expected here.", range: n.range)
                }
            }
            if let t = queryTables[key] { return t }
            guard let ti = db.tableIndex[key] else {
                throw DAXError("Cannot find table '\(name)'.", range: n.range)
            }
            try checkTableAccess(ti, n)
            return visibleTable(ti, ctx)
        case .call:
            switch try call(n, ctx) {
            case .table(let t): return t
            case .scalar:
                throw DAXError("\(n.callName ?? "The expression") returns a single value, but a table is expected here.", range: n.range)
            }
        case .tableCtor(let rows):
            let width = rows.map(\.count).max() ?? 1
            var out: [[Value]] = []
            for r in rows {
                guard r.count == width else { throw DAXError("Each row of a table constructor must have the same number of values.", range: n.range) }
                out.append(try r.map { try scalar($0, ctx) })
            }
            let infos = (0..<width).map { ColInfo(name: width == 1 ? "Value" : "Value\($0 + 1)") }
            return TableValue(cols: Columns(infos), rows: out)
        case .vars(let vs, let body):
            return try table(body, bind(vs, ctx))
        case .column(let t, let name, _):
            throw DAXError("The column \(t.map { "'\($0)'" } ?? "")[\(name)] cannot be used as a table. Wrap it in VALUES() or DISTINCT().", range: n.range)
        default:
            throw DAXError("The expression is not a table.", range: n.range)
        }
    }

    /// Rows of a model table visible in the filter context (plus the blank row when it applies).
    func visibleTable(_ ti: Int, _ ctx: Ctx) -> TableValue {
        let sel = ctx.fc.rows(ti)
        var rows = sel.indices
        if sel.blank, db.hasBlankRow(ti) { rows.append(-1) }
        return TableValue(table: ti, rows: rows, db: db)
    }

    func eval(_ n: Node, _ ctx: Ctx) throws -> DAXResult {
        switch n.kind {
        case .ident(let name):
            let key = identKey(n, name)
            if let v = ctx.vars?.lookup(key) {
                switch v {
                case .scalar(let s): return .scalar(s)
                case .table(let t): return .table(t)
                case .thunk(let tn, let scope): var c = ctx; c.vars = scope; return try eval(tn, c)
                }
            }
            if queryTables[key] != nil || db.tableIndex[key] != nil { return .table(try table(n, ctx)) }
            return .scalar(try identScalar(n, name, ctx))
        case .call: return try call(n, ctx)
        case .vars(let vs, let body): return try eval(body, bind(vs, ctx))
        case .tableCtor: return .table(try table(n, ctx))
        default: return .scalar(try scalar(n, ctx))
        }
    }

    func call(_ n: Node, _ ctx: Ctx) throws -> DAXResult {
        guard case .call(let name, let args) = n.kind else { return .scalar(.null) }
        do {
            if let box = n.cache as? CallBox {
                switch box.kind {
                case .fn(let f): return try f(self, args, ctx, n)
                case .pure(let p): return .scalar(try p(try args.map { try scalar($0, ctx) }))
                }
            }
            if let f = queryFunctions[name.daxKey] ?? functionDefs[name.daxKey] { return try callUDF(f, args, ctx, n) }
            if name == "__TUPLE" { throw DAXError("A tuple can only be used with IN or inside a table constructor.") }
            let builtin = DAXEngine.builtins[name]
            let pure = builtin == nil ? DAXEngine.pureFns[name] : nil
            guard builtin != nil || pure != nil else { throw DAXError("Unknown function '\(name)'.") }
            if let info = DAXCatalog.function(named: name) {
                if args.count < info.minArgs || (info.maxArgs.map { args.count > $0 } ?? false) {
                    throw DAXError("\(name) expects \(DAXEngine.arityText(info)) but received \(args.count). Signature: \(info.signature)")
                }
            }
            if let f = builtin {
                n.cache = CallBox(.fn(f))
                return try f(self, args, ctx, n)
            }
            n.cache = CallBox(.pure(pure!))
            return .scalar(try pure!(try args.map { try scalar($0, ctx) }))
        } catch var e as DAXError {
            if e.range == nil { e.range = n.range }
            throw e
        }
    }

    static func arityText(_ info: DAXFunctionInfo) -> String {
        if let m = info.maxArgs {
            return m == info.minArgs ? "\(m) argument\(m == 1 ? "" : "s")" : "\(info.minArgs) to \(m) arguments"
        }
        return "at least \(info.minArgs) argument\(info.minArgs == 1 ? "" : "s")"
    }

    func callUDF(_ f: FunctionDef, _ args: [Node], _ ctx: Ctx, _ n: Node) throws -> DAXResult {
        guard args.count <= f.params.count else {
            throw DAXError("Function \(f.name) takes at most \(f.params.count) argument(s) but received \(args.count).")
        }
        guard ctx.depth < 256 else { throw DAXError("Function \(f.name) recursed too deeply.") }
        var scope: VarScope?
        for (i, p) in f.params.enumerated() {
            let value: VarValue
            if i < args.count, !args[i].isMissing {
                if p.mode == "expr" {
                    let (dn, dc) = deref(args[i], ctx)
                    value = .thunk(dn, dc.vars)
                } else {
                    switch try eval(args[i], ctx) {
                    case .scalar(let s): value = .scalar(s)
                    case .table(let t): value = .table(t)
                    }
                }
            } else if let d = p.defaultExpr {
                var c = ctx; c.vars = scope
                switch try eval(d, c) {
                case .scalar(let s): value = .scalar(s)
                case .table(let t): value = .table(t)
                }
            } else {
                throw DAXError("Function \(f.name) is missing a value for parameter '\(p.name)'.")
            }
            scope = VarScope(name: p.name, value: value, parent: scope)
        }
        var c = ctx
        c.vars = scope
        c.depth += 1
        return try eval(f.body, c)
    }

    // MARK: Operators

    private func binary(_ op: BinOp, _ l: Node, _ r: Node, _ ctx: Ctx, _ n: Node) throws -> Value {
        switch op {
        case .and: return .bool(try DAXOps.truthy(scalar(l, ctx)) && DAXOps.truthy(scalar(r, ctx)))
        case .or: return .bool(try DAXOps.truthy(scalar(l, ctx)) || DAXOps.truthy(scalar(r, ctx)))
        case .in: return .bool(try inOperator(l, r, ctx))
        default: break
        }
        let a = try scalar(l, ctx), b = try scalar(r, ctx)
        switch op {
        case .add: return try DAXOps.add(a, b)
        case .sub: return try DAXOps.sub(a, b)
        case .mul: return try DAXOps.mul(a, b)
        case .div: return try DAXOps.div(a, b)
        case .pow: return try DAXOps.pow(a, b)
        case .concat: return .string(DAXOps.text(a) + DAXOps.text(b))
        case .eq: return .bool(DAXOps.equals(a, b))
        case .strictEq: return .bool(DAXOps.strictEquals(a, b))
        case .ne: return .bool(!DAXOps.equals(a, b))
        case .lt: return .bool(DAXOps.compare(a, b) < 0)
        case .le: return .bool(DAXOps.compare(a, b) <= 0)
        case .gt: return .bool(DAXOps.compare(a, b) > 0)
        case .ge: return .bool(DAXOps.compare(a, b) >= 0)
        default: return .null
        }
    }

    /// Key used for case-insensitive membership tests.
    static func normKey(_ v: Value) -> Value {
        if case .string(let s) = v { return .string(s.lowercased()) }
        return v
    }

    private func inOperator(_ l: Node, _ r: Node, _ ctx: Ctx) throws -> Bool {
        let left: [Value]
        if case .call("__TUPLE", let items) = l.kind { left = try items.map { try scalar($0, ctx) } } else { left = [try scalar(l, ctx)] }
        if left.count == 1, case .tableCtor(let rows) = r.kind {
            let set: Set<Value>
            if let b = r.cache as? ConstSetBox { set = b.set } else {
                var s = Set<Value>()
                var constant = true
                for row in rows {
                    guard row.count == 1 else { throw DAXError("The number of values on the left of IN must match the number of columns on the right.") }
                    if case .const(let v) = row[0].kind { s.insert(DAXEngine.normKey(v)) } else {
                        constant = false
                        s.insert(DAXEngine.normKey(try scalar(row[0], ctx)))
                    }
                }
                if constant { r.cache = ConstSetBox(s) }
                set = s
            }
            return set.contains(DAXEngine.normKey(left[0]))
        }
        let t = try table(r, ctx)
        guard t.cols.count == left.count else {
            throw DAXError("The number of values on the left of IN (\(left.count)) must match the number of columns on the right (\(t.cols.count)).")
        }
        for row in t.rows(db) {
            var all = true
            for i in 0..<left.count where !DAXOps.strictEquals(row[i], left[i]) { all = false; break }
            if all { return true }
        }
        return false
    }

    // MARK: Column and measure references

    func checkTableAccess(_ t: Int, _ n: Node?) throws {
        if !olsTables.isEmpty, olsTables.contains(t) {
            throw DAXError("Table '\(db.tables[t].name)' cannot be found or is not accessible in the current security role.", range: n?.range)
        }
    }
    func checkColumnAccess(_ c: ColumnID, _ n: Node?) throws {
        if olsTables.isEmpty && olsColumns.isEmpty { return }
        if olsTables.contains(c.table) || olsColumns.contains(c) {
            throw DAXError("Column \(db.name(c)) cannot be found or is not accessible in the current security role.", range: n?.range)
        }
    }

    private func colRef(_ n: Node, _ table: String?, _ name: String, _ sub: String?) throws -> ColRefBox {
        if let b = n.cache as? ColRefBox, b.gen == db.generation { return b }
        var cid: ColumnID?
        if let t = table {
            cid = db.columnID(table: t, column: name)
            if let s = sub {
                guard let c = cid, let target = autoDateColumns[c]?[s.daxKey] else {
                    throw DAXError("'\(t)'[\(name)].[\(s)] is not available. Date hierarchy levels exist only for date columns when auto date/time is on.", range: n.range)
                }
                cid = target
            }
        }
        let b = ColRefBox(cid: cid, nameKey: name.daxKey, gen: db.generation)
        n.cache = b
        return b
    }

    /// The model column a node refers to, or nil when it is not a model column reference.
    func modelColumn(_ node: Node, _ ctx: Ctx) throws -> ColumnID? {
        let (n, c) = deref(node, ctx)
        guard case .column(let t, let name, let sub) = n.kind else { return nil }
        let b = try colRef(n, t, name, sub)
        if let cid = b.cid { try checkColumnAccess(cid, n); return cid }
        if t == nil {
            // Unqualified: a column of the innermost iterated model table, unless it names a measure.
            if lookupMeasure(b.nameKey) != nil { return nil }
            for f in c.frames.reversed() {
                if case .base(let ti, _) = f, let ci = db.tables[ti].colIndex[b.nameKey] { return ColumnID(table: ti, col: ci) }
                if case .row(let cols, _) = f, let i = cols.byName[b.nameKey], let l = cols.infos[i].lineage { return l }
            }
        }
        return nil
    }

    /// A model column argument; throws a helpful error otherwise.
    func columnArg(_ node: Node, _ ctx: Ctx, _ fn: String) throws -> ColumnID {
        if let c = try modelColumn(node, ctx) { return c }
        let (n, _) = deref(node, ctx)
        if case .column(let t, let name, _) = n.kind {
            throw DAXError("\(fn): cannot find column \(t.map { "'\($0)'" } ?? "")[\(name)].", range: n.range)
        }
        throw DAXError("\(fn) expects a column reference such as Table[Column].", range: n.range)
    }

    func lookupMeasure(_ key: String) -> MeasureDef? { queryMeasures[key] ?? measureDefs[key] }

    @inline(__always)
    func cell(_ c: ColumnID, _ row: Int32) -> Value { row < 0 ? .null : db.tables[c.table].columns[c.col].values[Int(row)] }

    private func columnValue(_ n: Node, _ table: String?, _ name: String, _ sub: String?, _ ctx: Ctx) throws -> Value {
        let b = try colRef(n, table, name, sub)
        if table != nil {
            if let cid = b.cid {
                if !olsColumns.isEmpty || !olsTables.isEmpty { try checkColumnAccess(cid, n) }
                var i = ctx.frames.count - 1
                while i >= 0 {
                    switch ctx.frames[i] {
                    case .base(let t, let r):
                        if t == cid.table { return cell(cid, r) }
                    case .row(let cols, let vals):
                        if let k = cols.byLineage[cid] { return vals[k] }
                    }
                    i -= 1
                }
                if sub != nil { return try relatedValue(cid, ctx, n) }
                throw DAXError("A single value for column \(db.name(cid)) cannot be determined. Use an aggregation such as SUM, MIN or MAX, or refer to it inside a row context.", range: n.range)
            }
            for f in ctx.frames.reversed() {
                if case .row(let cols, let vals) = f, let k = cols.index(table: table, name: name) { return vals[k] }
            }
            if let m = lookupMeasure(b.nameKey) { return try evalMeasure(m, ctx) }
            if let t = table, db.tableIndex[t.daxKey] == nil, queryTables[t.daxKey] == nil, ctx.vars?.lookup(t.daxKey) == nil {
                throw DAXError("Cannot find table '\(t)'.", range: n.range)
            }
            throw DAXError("Column '\(name)' cannot be found in table '\(table ?? "")'.", range: n.range)
        }
        // Unqualified [Name]: extension column, then measure, then column of the iterated table.
        var i = ctx.frames.count - 1
        while i >= 0 {
            if case .row(let cols, let vals) = ctx.frames[i], let k = cols.byName[b.nameKey] { return vals[k] }
            i -= 1
        }
        if let m = lookupMeasure(b.nameKey) { return try evalMeasure(m, ctx) }
        i = ctx.frames.count - 1
        while i >= 0 {
            if case .base(let t, let r) = ctx.frames[i], let ci = db.tables[t].colIndex[b.nameKey] {
                return cell(ColumnID(table: t, col: ci), r)
            }
            i -= 1
        }
        throw DAXError("Cannot find measure or column [\(name)].", range: n.range)
    }

    /// Converts the row context into filters (context transition).
    func transition(_ ctx: Ctx) -> FilterContext {
        if ctx.frames.isEmpty { return ctx.fc }
        var byColumn: [ColumnID: CtxFilter] = [:]
        var byTable: [Int: CtxFilter] = [:]
        var order: [CtxFilter] = []
        for f in ctx.frames {
            switch f {
            case .base(let t, let r):
                let n = db.tables[t].rowCount
                let nf = CtxFilter(.rows(t, RowSel(n: n, rows: r >= 0 ? [r] : [], blank: r < 0)))
                if let old = byTable[t] { order.removeAll { $0 === old } }
                byTable[t] = nf; order.append(nf)
            case .row(let cols, let vals):
                for (i, info) in cols.infos.enumerated() {
                    guard let l = info.lineage else { continue }
                    let nf = CtxFilter.single(l, vals[i])
                    if let old = byColumn[l] { order.removeAll { $0 === old } }
                    byColumn[l] = nf; order.append(nf)
                }
            }
        }
        return ctx.fc.adding(order)
    }

    func evalMeasure(_ m: MeasureDef, _ ctx: Ctx) throws -> Value {
        guard ctx.depth < 200 else {
            throw DAXError("Measure [\(m.name)] has a circular dependency or is nested too deeply.")
        }
        var c = Ctx(fc: ctx.frames.isEmpty ? ctx.fc : transition(ctx))
        c.selected = ctx.selected
        c.depth = ctx.depth + 1
        if !calcGroups.isEmpty, let (item, group) = activeCalcItem(c.fc) {
            c.fc = c.fc.removing(columns: [group.column])
            c.selectedMeasure = m
            return try scalar(item.expr, c)
        }
        let key = MeasureKey(measure: ObjectIdentifier(m), selected: c.selected.map { ObjectIdentifier($0) })
        if let v = c.fc.measureCache[key] { return v }
        let v = try scalar(m.expr, c)
        c.fc.measureCache[key] = v
        return v
    }

    /// The calculation item to apply: the highest-precedence group whose column is filtered to exactly one item.
    func activeCalcItem(_ fc: FilterContext) -> (CalcItemDef, CalcGroupDef)? {
        for g in calcGroups {
            for f in fc.filters {
                if case .values(let c, let set) = f.kind, c == g.column, set.count == 1, let v = set.first,
                   let item = g.items[v.asString.daxKey] {
                    return (item, g)
                }
            }
        }
        return nil
    }

    /// The format string for a measure in a filter context (dynamic format strings and calculation items).
    func formatString(for m: MeasureDef, _ ctx: Ctx) -> String {
        var c = Ctx(fc: ctx.fc)
        c.selected = ctx.selected
        var base = m.formatString
        if let fe = m.formatExpr, let v = try? scalar(fe, c), !v.isNull { base = v.asString }
        var fc = c.fc
        var applied = Set<String>()
        while let (item, group) = activeCalcItem(fc), applied.insert(group.name).inserted {
            fc = fc.removing(columns: [group.column])
            if let fe = item.formatExpr {
                var c2 = Ctx(fc: fc)
                c2.selected = ctx.selected
                c2.selectedMeasure = m
                c2.vars = VarScope(name: "__selectedmeasureformat", value: .scalar(.string(base)), parent: nil)
                if let v = try? scalar(fe, c2), !v.isNull { base = v.asString }
            }
        }
        return base
    }

    // MARK: Shared helpers

    func arg(_ args: [Node], _ i: Int) -> Node? {
        guard i < args.count, !args[i].isMissing else { return nil }
        return args[i]
    }
    func scalarArg(_ args: [Node], _ i: Int, _ ctx: Ctx) throws -> Value {
        guard let a = arg(args, i) else { return .null }
        return try scalar(a, ctx)
    }
    /// Keyword argument (bare identifier such as ASC, DAY, ROWS) or a string with the same content, upper-cased.
    func keywordArg(_ args: [Node], _ i: Int, _ ctx: Ctx) throws -> String? {
        guard let a = arg(args, i) else { return nil }
        if case .ident(let s) = a.kind, ctx.vars?.lookup(s.daxKey) == nil { return s.uppercased() }
        if case .call(let name, let inner) = a.kind, inner.isEmpty, ["TRUE", "FALSE"].contains(name) { return name }
        let v = try scalar(a, ctx)
        switch v {
        case .string(let s): return s.uppercased()
        case .null: return nil
        default: return v.asString.uppercased()
        }
    }

    func colInfo(_ c: ColumnID) -> ColInfo {
        let t = db.tables[c.table]
        return ColInfo(name: t.columns[c.col].name, table: t.name, lineage: c, type: t.columns[c.col].type)
    }

    /// Distinct values of a column in the filter context, in first-appearance order.
    func distinctValues(_ c: ColumnID, _ fc: FilterContext, blankRow: Bool) -> [Value] {
        let col = db.column(c)
        let sel = fc.rows(c.table)
        var out: [Value]
        if let rows = sel.rows {
            let codes = col.codes, dict = col.dict
            var seen = [Bool](repeating: false, count: dict.count)
            out = []
            for r in rows {
                let k = Int(codes[Int(r)])
                if !seen[k] { seen[k] = true; out.append(dict[k]) }
            }
        } else {
            out = col.dict
        }
        if blankRow, sel.blank, db.hasBlankRow(c.table), !out.contains(where: { $0.isNull }) { out.append(.null) }
        return out
    }

    func singleColumn(_ c: ColumnID, _ values: [Value]) -> TableValue {
        TableValue(cols: Columns([colInfo(c)]), rows: values.map { [$0] })
    }

    /// Iterates a table, giving the body a context whose innermost row frame is the current row.
    func forEachRow(_ t: TableValue, _ ctx: Ctx, _ body: (Ctx, Int) throws -> Void) rethrows {
        var c = ctx
        c.frames.append(.base(0, 0))
        let last = c.frames.count - 1
        if let b = t.base {
            for (i, r) in b.rows.enumerated() { c.frames[last] = .base(b.table, r); try body(c, i) }
        } else {
            for (i, row) in t.data.enumerated() { c.frames[last] = .row(t.cols, row); try body(c, i) }
        }
    }

    /// Value of a column on the row related to the current row context (RELATED semantics).
    func relatedValue(_ cid: ColumnID, _ ctx: Ctx, _ n: Node?) throws -> Value {
        for f in ctx.frames.reversed() {
            switch f {
            case .base(let t, let r):
                if t == cid.table { return cell(cid, r) }
                if let map = db.relatedRows(from: t, to: cid.table, rel: ctx.fc.rel) {
                    return r < 0 ? .null : cell(cid, map[Int(r)])
                }
            case .row(let cols, let vals):
                if let k = cols.byLineage[cid] { return vals[k] }
            }
        }
        throw DAXError("RELATED: \(db.name(cid)) is not related to the current row. RELATED needs a row context on a table that has a many-to-one relationship to '\(db.tables[cid.table].name)'.", range: n?.range)
    }
}
