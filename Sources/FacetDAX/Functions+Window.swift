import Foundation
import FacetCore

extension DAXEngine {
    // MARK: Window functions (OFFSET, INDEX, WINDOW, RANK, ROWNUMBER)

    static let windowFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        for name in ["ORDERBY", "PARTITIONBY", "MATCHBY"] {
            d[name] = { _, _, _, _ in throw DAXError("\(name) can only be used inside a window function.") }
        }
        d["OFFSET"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n, from: 1)
            let delta = Int(try DAXOps.number(e.scalar(a[0], c)))
            var picked: [Int] = []
            for current in try w.requireCurrent("OFFSET", n) {
                let rows = w.partition(of: current)
                guard let at = rows.firstIndex(of: current), rows.indices.contains(at + delta) else { continue }
                picked.append(rows[at + delta])
            }
            return .table(w.output(picked))
        }
        d["INDEX"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n, from: 1)
            let position = Int(try DAXOps.number(e.scalar(a[0], c)))
            var picked: [Int] = []
            for rows in w.partitionsInScope() {
                // Positive positions count from the first row, negative ones from the last.
                let at = position > 0 ? position - 1 : rows.count + position
                if position != 0, rows.indices.contains(at) { picked.append(rows[at]) }
            }
            return .table(w.output(picked))
        }
        d["WINDOW"] = { e, a, c, n in
            // WINDOW(from[, from_type], to[, to_type], relation, …): the types default to REL.
            func boundType(_ i: Int) -> String? {
                guard let node = e.arg(a, i), case .ident(let s) = node.kind, c.vars?.lookup(s.daxKey) == nil else { return nil }
                let u = s.uppercased()
                return u == "ABS" || u == "REL" ? u : nil
            }
            guard a.count >= 2 else { throw DAXError("WINDOW needs a start and an end position.", range: n.range) }
            var i = 0
            let from = Int(try DAXOps.number(e.scalar(a[i], c))); i += 1
            let fromType = boundType(i) ?? "REL"
            if boundType(i) != nil { i += 1 }
            guard i < a.count else { throw DAXError("WINDOW needs an end position.", range: n.range) }
            let to = Int(try DAXOps.number(e.scalar(a[i], c))); i += 1
            let toType = boundType(i) ?? "REL"
            if boundType(i) != nil { i += 1 }
            let w = try e.windowSpec(a, ctx: c, node: n, from: i)
            var picked: [Int] = []
            for current in try w.requireCurrent("WINDOW", n) {
                let rows = w.partition(of: current)
                guard let at = rows.firstIndex(of: current) else { continue }
                // Absolute positions are 1-based from the start, or negative from the end (-1 = last row).
                func position(_ value: Int, _ type: String) -> Int {
                    if type == "ABS" { return value > 0 ? value - 1 : rows.count + value }
                    return at + value
                }
                let lo = max(0, position(from, fromType)), hi = min(rows.count - 1, position(to, toType))
                if lo <= hi { picked.append(contentsOf: rows[lo...hi]) }
            }
            return .table(w.output(picked))
        }
        d["RANK"] = { e, a, c, n in
            var dense = false
            if let first = e.arg(a, 0), case .ident(let s) = first.kind, c.vars?.lookup(s.daxKey) == nil {
                switch s.uppercased() {
                case "DENSE": dense = true
                case "SKIP": dense = false
                default: break
                }
            }
            let w = try e.windowSpec(a, ctx: c, node: n, from: 0, tieBreak: false)
            guard let current = try w.singleCurrent("RANK", n) else { return .scalar(.null) }
            let currentKey = w.orderKey(of: current)
            var better = 0, distinct = Set<[Value]>()
            for r in w.partition(of: current) {
                let key = w.orderKey(of: r)
                if w.compare(key, currentKey) < 0 { better += 1; distinct.insert(key) }
            }
            return .scalar(.int(Int64((dense ? distinct.count : better) + 1)))
        }
        d["ROWNUMBER"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n, from: 0)
            guard let current = try w.singleCurrent("ROWNUMBER", n),
                  let at = w.partition(of: current).firstIndex(of: current) else { return .scalar(.null) }
            return .scalar(.int(Int64(at + 1)))
        }
        return d
    }()

    /// One resolved window: the relation, its order, partitions and the current row(s).
    struct WindowSpec {
        /// The relation, materialised; computed ORDERBY expressions are appended after `width` columns.
        let relation: TableValue
        /// The relation's own columns (what window functions return).
        let columns: Columns
        let width: Int
        /// ORDERBY keys: (column index, descending).
        let order: [(Int, Bool)]
        /// Partition key → row indices in window order.
        let partitions: [[Value]: [Int]]
        let partitionColumns: [Int]
        /// Every row in window order (the only partition when there is no PARTITIONBY).
        let all: [Int]
        /// Rows of the relation matching the outer row and filter context; nil when the context
        /// pins none of the relation's columns.
        let current: [Int]?

        private func key(of row: Int) -> [Value] {
            partitionColumns.map { relation.data[safe: row]?[safe: $0] ?? .null }
        }
        func partition(of row: Int) -> [Int] {
            partitionColumns.isEmpty ? all : (partitions[key(of: row)] ?? [])
        }
        /// The partitions the context selects: those of the current rows, or all of them when
        /// the context does not pin a current row.
        func partitionsInScope() -> [[Int]] {
            guard !partitionColumns.isEmpty else { return [all] }
            var seen = Set<[Value]>()
            var out: [[Int]] = []
            for row in current ?? all where seen.insert(key(of: row)).inserted { out.append(partition(of: row)) }
            return out
        }
        func orderKey(of row: Int) -> [Value] {
            order.map { relation.data[safe: row]?[safe: $0.0] ?? .null }
        }
        func compare(_ a: [Value], _ b: [Value]) -> Int {
            for (i, x) in a.enumerated() {
                let c = DAXOps.sortCompare(x, b[safe: i] ?? .null)
                if c != 0 { return order[safe: i]?.1 == true ? -c : c }
            }
            return 0
        }
        /// The current rows, or an error when the context does not identify any column of the relation.
        func requireCurrent(_ fn: String, _ node: Node) throws -> [Int] {
            guard let current else {
                throw DAXError("\(fn) cannot determine the current row: no column of its relation has a value in the row or filter context.", range: node.range)
            }
            return current
        }
        /// The one current row; nil when the context's row is not in the relation.
        func singleCurrent(_ fn: String, _ node: Node) throws -> Int? {
            let rows = try requireCurrent(fn, node)
            guard rows.count <= 1 else {
                throw DAXError("\(fn) cannot determine a single current row: \(rows.count) rows of its relation match the context.", range: node.range)
            }
            return rows.first
        }
        /// The picked rows without duplicates, in window order, with the relation's own columns.
        func output(_ picked: [Int]) -> TableValue {
            let wanted = Set(picked)
            let ordered: [Int]
            if partitionColumns.isEmpty { ordered = all.filter(wanted.contains) }
            else {
                var seen = Set<Int>()
                ordered = picked.filter { seen.insert($0).inserted }
            }
            return TableValue(cols: columns, rows: ordered.map { Array(relation.data[$0].prefix(width)) })
        }
    }

    /// Resolves the relation, ORDERBY, PARTITIONBY and the current row of a window function.
    /// `skip` is the index of the first argument after the leading scalars (OFFSET's delta,
    /// INDEX's position, WINDOW's bounds). `tieBreak` appends the relation's remaining columns to
    /// the order so that every row has one position (all functions except RANK).
    func windowSpec(_ args: [Node], ctx: Ctx, node: Node, from skip: Int, tieBreak: Bool = true) throws -> WindowSpec {
        let fn = node.callName ?? "The window function"
        var relationNode: Node?
        var orderNodes: [(Node, Bool)] = []
        var partitionNodes: [Node] = []
        for i in skip..<max(skip, args.count) where !args[i].isMissing {
            let (n, ac) = deref(args[i], ctx)
            if case .call(let name, let inner) = n.kind {
                if name == "ORDERBY" {
                    orderNodes += try orderPairs(inner, from: 0, ac, defaultDescending: false)
                    continue
                }
                if name == "PARTITIONBY" || name == "MATCHBY" {
                    partitionNodes += inner
                    continue
                }
            }
            if relationNode == nil, isTableNode(args[i], ctx) { relationNode = args[i] }
        }

        // The relation: explicit, the visual's own grid, or ALLSELECTED over the ORDERBY and
        // PARTITIONBY columns (which must then be columns of one table).
        let visual = relationNode == nil ? ctx.visual : nil
        let rel: TableValue
        if let relationNode { rel = try table(relationNode, ctx).materialized(db) }
        else if let visual { rel = visual.grid }
        else {
            guard !orderNodes.isEmpty else {
                throw DAXError("\(fn) needs a relation or an ORDERBY to derive one from.", range: node.range)
            }
            var columns: [Node] = []
            var seen = Set<ColumnID>(), tables = Set<Int>()
            for expr in orderNodes.map(\.0) + partitionNodes {
                guard case .column(let t, _, _) = expr.kind, t != nil, let cid = try? modelColumn(expr, ctx) else {
                    throw DAXError("\(fn) without a relation needs fully qualified columns in ORDERBY and PARTITIONBY.", range: expr.range)
                }
                tables.insert(cid.table)
                if seen.insert(cid).inserted { columns.append(expr) }
            }
            guard tables.count == 1 else {
                throw DAXError("\(fn) without a relation needs ORDERBY and PARTITIONBY columns from a single table.", range: node.range)
            }
            rel = try table(Node(.call("ALLSELECTED", columns), node.range), ctx).materialized(db)
        }
        let width = rel.cols.count

        /// The relation column an ORDERBY / PARTITIONBY expression names, if it is a column of the relation.
        func relationColumn(_ expr: Node) -> Int? {
            if case .column(let t, let name, _) = expr.kind {
                if t == nil, let k = rel.cols.byName[name.daxKey] { return k }
                if let t, let k = rel.cols.index(table: t, name: name) { return k }
            }
            if let cid = try? modelColumn(expr, ctx) { return rel.cols.byLineage[cid] }
            return nil
        }

        // Order: named relation columns, or expressions evaluated per row and appended to the relation.
        var order: [(Int, Bool)] = []
        var computed: [Node] = []
        if orderNodes.isEmpty, let visual {
            order = visual.rowAxis.map { ($0, false) }
        } else {
            for (expr, descending) in orderNodes {
                if let k = relationColumn(expr) { order.append((k, descending)) }
                else { order.append((width + computed.count, descending)); computed.append(expr) }
            }
        }
        var rows = rel.data
        if !computed.isEmpty {
            var r = 0
            try forEachRow(rel, ctx) { rc, _ in
                rows[r].append(contentsOf: try computed.map { try scalar($0, rc) })
                r += 1
            }
        }
        let extended = TableValue(cols: Columns(rel.cols.infos + computed.indices.map { ColInfo(name: "__order\($0)") }), rows: rows)

        var partitionColumns: [Int] = []
        for p in partitionNodes {
            guard let k = relationColumn(p) else {
                throw DAXError("\(fn): PARTITIONBY expects columns of the relation.", range: p.range)
            }
            partitionColumns.append(k)
        }

        // Window order: ORDERBY, then (to give every row one position) the remaining columns ascending.
        var sortOrder = order
        if tieBreak, visual == nil {
            let used = Set(order.map(\.0) + partitionColumns)
            sortOrder += (0..<width).filter { !used.contains($0) }.map { ($0, false) }
        }
        func sorted(_ indices: [Int]) -> [Int] {
            indices.enumerated().sorted { x, y in
                for (col, descending) in sortOrder {
                    let c = DAXOps.sortCompare(rows[x.element][safe: col] ?? .null, rows[y.element][safe: col] ?? .null)
                    if c != 0 { return descending ? c > 0 : c < 0 }
                }
                return x.offset < y.offset
            }.map(\.element)
        }
        let all = sorted(Array(rows.indices))
        var partitions: [[Value]: [Int]] = [:]
        if !partitionColumns.isEmpty {
            for r in all {
                partitions[partitionColumns.map { rows[r][safe: $0] ?? .null }, default: []].append(r)
            }
        }

        var current: [Int]?
        if let visual { current = [visual.row] }
        else {
            let pinned = rel.cols.infos.enumerated().compactMap { k, info in outerValue(of: info, ctx).map { (k, $0) } }
            if !pinned.isEmpty {
                current = all.filter { r in pinned.allSatisfy { DAXOps.strictEquals(rows[r][safe: $0.0] ?? .null, $0.1) } }
            }
        }
        return WindowSpec(relation: extended, columns: rel.cols, width: width, order: order, partitions: partitions,
                          partitionColumns: partitionColumns, all: all, current: current)
    }

    /// The value the outer context gives a relation column: from the innermost row context that
    /// has the column, else the single value the filter context leaves visible.
    private func outerValue(of info: ColInfo, _ ctx: Ctx) -> Value? {
        for frame in ctx.frames.reversed() {
            switch frame {
            case .base(let t, let r):
                if let cid = info.lineage, cid.table == t { return cell(cid, r) }
            case .row(let cols, let vals):
                if let cid = info.lineage {
                    if let k = cols.byLineage[cid] { return vals[safe: k] }
                } else if let k = cols.byName[info.name.daxKey], cols.infos[k].lineage == nil {
                    return vals[safe: k]
                }
            }
        }
        guard let cid = info.lineage, ctx.fc.isCrossFiltered(cid.table) else { return nil }
        let visible = distinctValues(cid, ctx.fc, blankRow: true)
        return visible.count == 1 ? visible[0] : nil
    }
}
