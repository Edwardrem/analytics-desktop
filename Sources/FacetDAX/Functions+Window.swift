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
            let w = try e.windowSpec(a, ctx: c, node: n)
            guard let current = w.current else {
                throw DAXError("OFFSET needs a current row: use it in a visual calculation or with a single-row filter context.", range: n.range)
            }
            let delta = Int(try DAXOps.number(e.scalar(a[0], c)))
            let rows = w.partition(of: current)
            guard let at = rows.firstIndex(of: current) else { return .table(TableValue(cols: w.relation.cols, rows: [])) }
            let target = at + delta
            guard rows.indices.contains(target) else { return .table(TableValue(cols: w.relation.cols, rows: [])) }
            return .table(TableValue(cols: w.relation.cols, rows: [w.relation.data[rows[target]]]))
        }
        d["INDEX"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n)
            let position = Int(try DAXOps.number(e.scalar(a[0], c)))
            let rows = w.partition(of: w.current ?? -1)
            guard position >= 1, position <= rows.count else {
                return .table(TableValue(cols: w.relation.cols, rows: []))
            }
            return .table(TableValue(cols: w.relation.cols, rows: [w.relation.data[rows[position - 1]]]))
        }
        d["WINDOW"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n, from: 1)
            guard let current = w.current else {
                throw DAXError("WINDOW needs a current row: use it in a visual calculation or with a single-row filter context.", range: n.range)
            }
            let rows = w.partition(of: current)
            guard let at = rows.firstIndex(of: current) else { return .table(TableValue(cols: w.relation.cols, rows: [])) }
            let from = Int(try DAXOps.number(e.scalar(a[0], c)))
            let fromType = (try e.keywordArg(a, 1, c)) ?? "REL"
            let to = Int(try DAXOps.number(e.scalar(a[2], c)))
            let toType = (try e.keywordArg(a, 3, c)) ?? "REL"
            let lo: Int, hi: Int
            switch (fromType, toType) {
            case ("ABS", "ABS"): lo = from - 1; hi = to - 1
            case ("ABS", _): lo = from - 1; hi = at + to
            case (_, "ABS"): lo = at + from; hi = to - 1
            default: lo = at + from; hi = at + to
            }
            let kept = rows.enumerated().filter { $0.offset >= min(lo, hi) && $0.offset <= max(lo, hi) }.map(\.element)
            return .table(TableValue(cols: w.relation.cols, rows: kept.map { w.relation.data[$0] }))
        }
        d["RANK"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n)
            guard let current = w.current else {
                throw DAXError("RANK needs a current row: use it in a visual calculation or with a single-row filter context.", range: n.range)
            }
            let dense = (try e.keywordArg(a, 0, c)) == "DENSE"
            let rows = w.partition(of: current)
            let currentKey = w.orderKey(of: current)
            var better = 0, distinct = Set<[Value]>()
            for r in rows {
                let key = w.orderKey(of: r)
                let cmp = w.compare(key, currentKey)
                if cmp < 0 { better += 1; distinct.insert(key) }
            }
            return .scalar(.int(Int64((dense ? distinct.count : better) + 1)))
        }
        d["ROWNUMBER"] = { e, a, c, n in
            let w = try e.windowSpec(a, ctx: c, node: n)
            guard let current = w.current else {
                throw DAXError("ROWNUMBER needs a current row: use it in a visual calculation or with a single-row filter context.", range: n.range)
            }
            let rows = w.partition(of: current)
            guard let at = rows.firstIndex(of: current) else { return .scalar(.null) }
            return .scalar(.int(Int64(at + 1)))
        }
        return d
    }()

    /// One resolved window: the relation, its order, partitions and the current row.
    struct WindowSpec {
        let relation: TableValue
        let order: [(Int, Bool)]              // (column index, descending)
        let partitions: [[Value]: [Int]]      // partition key → sorted row indices
        let partitionColumns: [Int]
        let current: Int?
        let all: [Int]

        func partition(of row: Int) -> [Int] {
            guard !partitions.isEmpty, row >= 0, row < relation.count else { return all }
            let key = partitionColumns.map { relation.data[safe: row]?[$0] ?? .null }
            return partitions[key] ?? all
        }
        /// The order key of one row.
        func orderKey(of row: Int) -> [Value] {
            order.map { relation.data[safe: row]?[$0.0] ?? .null }
        }
        func compare(_ a: [Value], _ b: [Value]) -> Int {
            for (i, x) in a.enumerated() {
                let c = DAXOps.sortCompare(x, b[safe: i] ?? .null)
                if c != 0 { return order[safe: i]?.1 == true ? -c : c }
            }
            return 0
        }
    }

    /// Resolves the relation, ORDER BY, PARTITION BY and the current row of a window function.
    /// `from` skips leading scalar arguments (OFFSET's delta, INDEX's position, WINDOW's bounds).
    func windowSpec(_ args: [Node], ctx: Ctx, node: Node, from skip: Int = 1) throws -> WindowSpec {
        var relation: TableValue?
        var orderNodes: [(Node, Bool)] = []
        var partitionNodes: [Node] = []
        for i in skip..<args.count {
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
            if isTableNode(args[i], ac) { relation = try table(args[i], ac) }
        }
        // The default relation: the visual's own grid, ordered by the row axis.
        let visual = ctx.visual
        let rel: TableValue
        if let relation { rel = relation.materialized(db) }
        else if let visual { rel = visual.grid }
        else {
            throw DAXError("\(node.callName ?? "The window function") needs a table relation.", range: node.range)
        }
        var order: [(Int, Bool)] = []
        var orderExprs: [Node] = []
        if orderNodes.isEmpty, let visual, relation == nil {
            // The row axis is the order; its grouping columns are the order keys.
            for k in visual.rowAxis {
                order.append((k, false))
                orderExprs.append(Node(.column(table: nil, name: rel.cols.infos[safe: k]?.name ?? "", sub: nil), 0..<0))
            }
        } else {
            for (expr, desc) in orderNodes {
                // A column reference resolves by name in the relation; anything else is evaluated per row below.
                if case .column(let t, let name, _) = expr.kind, t == nil, let k = rel.cols.byName[name.daxKey] {
                    order.append((k, desc))
                } else if let cid = try? modelColumn(expr, ctx), let k = rel.cols.byLineage[cid] ?? rel.cols.infos.firstIndex(where: { $0.lineage == cid }) {
                    order.append((k, desc))
                } else {
                    orderExprs.append(expr)
                    order.append((rel.cols.count, desc))   // computed per row, appended below
                }
            }
        }
        // Computed order columns are appended to the relation.
        var relation2 = rel
        if !orderExprs.isEmpty {
            var extra: [[Value]] = []
            extra.reserveCapacity(rel.count)
            try forEachRow(rel, ctx) { rc, _ in extra.append(try orderExprs.map { try scalar($0, rc) }) }
            var infos = rel.cols.infos
            for (k, expr) in orderExprs.enumerated() {
                infos.append(ColInfo(name: "__order\(k)", type: .any))
            }
            var rows = rel.data
            for (r, values) in extra.enumerated() where r < rows.count { rows[r].append(contentsOf: values) }
            relation2 = TableValue(cols: Columns(infos), rows: rows)
        }
        let order2: [(Int, Bool)] = order.enumerated().map { i, entry in
            entry.0 < relation2.cols.count ? entry : (relation2.cols.count - orderExprs.count + i, entry.1)
        }

        // Partitions.
        var partitionCols: [Int] = []
        for p in partitionNodes {
            if case .column(let t, let name, _) = p.kind, t == nil, let k = relation2.cols.byName[name.daxKey] {
                partitionCols.append(k)
            } else if let cid = try? modelColumn(p, ctx), let k = relation2.cols.byLineage[cid] ?? relation2.cols.infos.firstIndex(where: { $0.lineage == cid }) {
                partitionCols.append(k)
            }
        }
        var current: Int?
        if let visual, relation == nil { current = visual.row }
        else {
            // The current row is the one row of the relation whose model columns match the filter context.
            var wanted: [Value] = []
            for (k, _) in order2 {
                guard let info = relation2.cols.infos[safe: k], let cid = info.lineage else { continue }
                let col = db.column(cid)
                let sel = ctx.fc.rows(cid.table)
                guard let rows = sel.rows, rows.count == 1 else { break }
                wanted.append(col.values[Int(rows[0])])
            }
            if wanted.count == order2.count, !order2.isEmpty {
                current = relation2.data.firstIndex { row in
                    zip(order2, wanted).allSatisfy { pair in DAXOps.strictEquals(row[pair.0.0], pair.1) }
                }
            }
        }
        let all = relation2.data.isEmpty ? [] : Array(0..<relation2.data.count)
        var partitions: [[Value]: [Int]] = [:]
        if !partitionCols.isEmpty {
            for r in all {
                let key = partitionCols.map { relation2.data[safe: r]?[$0] ?? .null }
                partitions[key, default: []].append(r)
            }
            for (k, rows) in partitions {
                partitions[k] = sortWithin(rows, relation: relation2, order: order2)
            }
        }
        return WindowSpec(relation: relation2, order: order2, partitions: partitions,
                          partitionColumns: partitionCols, current: current,
                          all: sortWithin(all, relation: relation2, order: order2))
    }

    /// Sorts row indices by the order columns (stable).
    private func sortWithin(_ rows: [Int], relation: TableValue, order: [(Int, Bool)]) -> [Int] {
        rows.enumerated().sorted { x, y in
            for (col, descending) in order {
                let a = relation.data[safe: x.element]?[col] ?? .null
                let b = relation.data[safe: y.element]?[col] ?? .null
                let c = DAXOps.sortCompare(a, b)
                if c != 0 { return descending ? c > 0 : c < 0 }
            }
            return x.offset < y.offset
        }.map(\.element)
    }
}
