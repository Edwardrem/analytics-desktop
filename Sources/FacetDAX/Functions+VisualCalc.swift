import Foundation
import FacetCore

extension DAXEngine {
    // MARK: Visual calculations (RUNNINGSUM, MOVINGAVERAGE, COLLAPSE, EXPAND, …)

    static let visualCalcFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        d["RUNNINGSUM"] = { e, a, c, n in
            let (vc, k) = try e.visualColumn(a[0], c, "RUNNINGSUM")
            let axis = try e.visualAxis(a, from: 1, vc, c, "RUNNINGSUM")
            guard let at = axis.at else { return .scalar(.null) }
            return .scalar(VisualLevels.sum(axis.rows[...at].map { vc.grid.data[$0][safe: k] ?? .null }))
        }
        d["MOVINGAVERAGE"] = { e, a, c, n in
            let (vc, k) = try e.visualColumn(a[0], c, "MOVINGAVERAGE")
            guard let sizeNode = e.arg(a, 1) else { throw DAXError("MOVINGAVERAGE needs a window size.", range: n.range) }
            let window = Int(try DAXOps.number(e.scalar(sizeNode, c)))
            guard window > 0 else { throw DAXError("MOVINGAVERAGE: the window size must be at least 1.", range: sizeNode.range) }
            let (includeCurrent, next) = try e.includeCurrentArg(a, 2, c)
            let axis = try e.visualAxis(a, from: next, vc, c, "MOVINGAVERAGE")
            guard let at = axis.at else { return .scalar(.null) }
            let end = includeCurrent ? at : at - 1
            let start = max(0, end - window + 1)
            guard end >= start else { return .scalar(.null) }
            let numbers = axis.rows[start...end].compactMap { r -> Double? in
                let v = vc.grid.data[r][safe: k] ?? .null
                return v.isNumber ? v.asDouble : nil
            }
            return .scalar(numbers.isEmpty ? .null : .double(numbers.reduce(0, +) / Double(numbers.count)))
        }
        for (name, direction) in [("PREVIOUS", -1), ("NEXT", 1)] {
            d[name] = { e, a, c, n in
                let (vc, k) = try e.visualColumn(a[0], c, name)
                // The optional second argument is the number of steps, unless it already is an axis argument.
                var steps = 1, next = 1
                if a.count > 1, !e.isVisualAxisArgument(a[1], vc, c) {
                    if !a[1].isMissing { steps = Int(try DAXOps.number(e.scalar(a[1], c))) }
                    next = 2
                }
                let axis = try e.visualAxis(a, from: next, vc, c, name)
                guard let at = axis.at, axis.rows.indices.contains(at + direction * steps) else { return .scalar(.null) }
                return .scalar(vc.grid.data[axis.rows[at + direction * steps]][safe: k] ?? .null)
            }
        }
        for (name, first) in [("FIRST", true), ("LAST", false)] {
            d[name] = { e, a, c, n in
                let (vc, k) = try e.visualColumn(a[0], c, name)
                let axis = try e.visualAxis(a, from: 1, vc, c, name)
                guard let r = first ? axis.rows.first : axis.rows.last else { return .scalar(.null) }
                return .scalar(vc.grid.data[r][safe: k] ?? .null)
            }
        }
        d["RANGE"] = { e, a, c, n in
            guard let vc = c.visual else { throw DAXError("RANGE can only be used in a visual calculation.") }
            let step = Int(try DAXOps.number(e.scalar(a[0], c)))
            let (includeCurrent, next) = try e.includeCurrentArg(a, 1, c)
            let axis = try e.visualAxis(a, from: next, vc, c, "RANGE")
            guard let at = axis.at else { return .table(TableValue(cols: vc.grid.cols, rows: [])) }
            let lo = max(0, min(at, at + step)), hi = min(axis.rows.count - 1, max(at, at + step))
            let picked = (lo...max(lo, hi)).filter { $0 <= hi && (includeCurrent || $0 != at) }
            return .table(TableValue(cols: vc.grid.cols, rows: picked.map { vc.grid.data[axis.rows[$0]] }))
        }
        d["COLLAPSE"] = { e, a, c, n in try e.collapse(a, c, all: false, fn: "COLLAPSE") }
        d["COLLAPSEALL"] = { e, a, c, n in try e.collapse(a, c, all: true, fn: "COLLAPSEALL") }
        d["EXPAND"] = { e, a, c, n in try e.expand(a, c, all: false, fn: "EXPAND") }
        d["EXPANDALL"] = { e, a, c, n in try e.expand(a, c, all: true, fn: "EXPANDALL") }
        d["LOOKUP"] = { e, a, c, n in try e.lookup(a, c, totals: false) }
        d["LOOKUPWITHTOTALS"] = { e, a, c, n in try e.lookup(a, c, totals: true) }
        d["ISATLEVEL"] = { e, a, c, n in
            guard let vc = c.visual else { throw DAXError("ISATLEVEL can only be used in a visual calculation.") }
            guard case .column(nil, let name, _) = a[0].kind, let k = vc.grid.cols.byName[name.daxKey] else { return .scalar(.bool(false)) }
            return .scalar(.bool(vc.rowAxis.contains(k) || vc.colAxis.contains(k)))
        }
        return d
    }()

    // MARK: Arguments

    /// The visual column a node refers to: (context, column index).
    private func visualColumn(_ node: Node, _ ctx: Ctx, _ fn: String) throws -> (VisualCalcContext, Int) {
        guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
        let (n, _) = deref(node, ctx)
        guard case .column(nil, let name, _) = n.kind, let k = vc.grid.cols.byName[name.daxKey] else {
            throw DAXError("\(fn) expects a visual column such as [\(vc.grid.cols.infos.first?.name ?? "Amount")].", range: node.range)
        }
        return (vc, k)
    }

    private static let axisKeywords: Set<String> = ["ROWS", "COLUMNS"]
    private static let resetKeywords: Set<String> = ["NONE", "LOWESTPARENT", "HIGHESTPARENT"]
    private static let blanksKeywords: Set<String> = ["DEFAULT", "KEEP"]

    private func keyword(_ node: Node, _ ctx: Ctx) -> String? {
        guard case .ident(let s) = node.kind, ctx.vars?.lookup(s.daxKey) == nil else { return nil }
        return s.uppercased()
    }

    /// True when the node is one of the trailing axis arguments (axis, ORDERBY, blanks, reset keyword or column).
    private func isVisualAxisArgument(_ node: Node, _ vc: VisualCalcContext, _ ctx: Ctx) -> Bool {
        if let k = keyword(node, ctx) {
            return DAXEngine.axisKeywords.contains(k) || DAXEngine.resetKeywords.contains(k) || DAXEngine.blanksKeywords.contains(k)
        }
        if node.callName == "ORDERBY" { return true }
        if case .column(nil, let name, _) = node.kind { return vc.grid.cols.byName[name.daxKey] != nil }
        return false
    }

    /// The optional `includeCurrent` argument at index `i`: its value and the index of the next argument.
    private func includeCurrentArg(_ args: [Node], _ i: Int, _ ctx: Ctx) throws -> (Bool, Int) {
        guard i < args.count else { return (true, i) }
        let node = args[i]
        if node.isMissing { return (true, i + 1) }
        if case .const(.bool(let b)) = node.kind { return (b, i + 1) }
        if case .call(let name, let inner) = node.kind, inner.isEmpty, name == "TRUE" || name == "FALSE" { return (name == "TRUE", i + 1) }
        if let k = keyword(node, ctx), k == "TRUE" || k == "FALSE" { return (k == "TRUE", i + 1) }
        return (true, i)
    }

    /// The rows a visual calculation walks, in order, and the current row's position among them.
    struct VisualAxis {
        let rows: [Int]
        let at: Int?
    }

    /// Resolves the trailing `[axis][, orderBy][, blanks][, reset]` arguments.
    ///
    /// The calculation walks the rows axis by default (`ROWS`), separately for each combination of
    /// column-axis values; `COLUMNS` walks the column axis within each row. `reset` restarts the
    /// walk whenever a parent level changes: `HIGHESTPARENT`, `LOWESTPARENT`, a number of levels
    /// (positive from the top, negative from the bottom) or a column of the axis.
    private func visualAxis(_ args: [Node], from start: Int, _ vc: VisualCalcContext, _ ctx: Ctx, _ fn: String) throws -> VisualAxis {
        enum Reset { case none, highest, lowest, levels(Int), column(Int) }
        var alongColumns = false
        var reset = Reset.none
        var order: [(Int, Bool)] = []
        for i in start..<max(start, args.count) where !args[i].isMissing {
            let node = args[i]
            if let k = keyword(node, ctx) {
                switch k {
                case "ROWS": alongColumns = false
                case "COLUMNS": alongColumns = true
                case "NONE": reset = .none
                case "HIGHESTPARENT": reset = .highest
                case "LOWESTPARENT": reset = .lowest
                case "DEFAULT", "KEEP": break
                default: throw DAXError("\(fn): unknown argument '\(k)'. Use ROWS or COLUMNS, ORDERBY(…), and NONE, LOWESTPARENT, HIGHESTPARENT, a level number or a column to reset.", range: node.range)
                }
            } else if case .call("ORDERBY", let inner) = node.kind {
                for (expr, descending) in try orderPairs(inner, from: 0, ctx, defaultDescending: false) {
                    guard case .column(nil, let name, _) = expr.kind, let k = vc.grid.cols.byName[name.daxKey] else {
                        throw DAXError("\(fn): ORDERBY expects columns of the visual.", range: expr.range)
                    }
                    order.append((k, descending))
                }
            } else if case .column(nil, let name, _) = node.kind, let k = vc.grid.cols.byName[name.daxKey] {
                reset = .column(k)
            } else {
                reset = .levels(Int(try DAXOps.number(scalar(node, ctx))))
            }
        }
        let axis = alongColumns ? vc.colAxis : vc.rowAxis
        let fixed = alongColumns ? vc.rowAxis : vc.colAxis
        let parents: Int
        switch reset {
        case .none: parents = 0
        case .highest: parents = axis.count >= 2 ? 1 : 0
        case .lowest: parents = max(0, axis.count - 1)
        case .levels(let n): parents = n > 0 ? min(n, max(0, axis.count - 1)) : (n < 0 ? max(0, axis.count + n) : 0)
        case .column(let k):
            guard let i = axis.firstIndex(of: k) else {
                throw DAXError("\(fn): the reset column must be a column of the \(alongColumns ? "columns" : "rows") axis.")
            }
            parents = i + 1
        }
        let keyColumns = fixed + axis.prefix(parents)
        let data = vc.grid.data
        guard let current = data[safe: vc.row] else { return VisualAxis(rows: [], at: nil) }
        let key = keyColumns.map { current[safe: $0] ?? .null }
        var rows = data.indices.filter { r in keyColumns.enumerated().allSatisfy { DAXOps.strictEquals(data[r][safe: $0.element] ?? .null, key[$0.offset]) } }
        let sortBy = order.isEmpty && alongColumns ? axis.map { ($0, false) } : order
        if !sortBy.isEmpty {
            rows = rows.enumerated().sorted { x, y in
                for (col, descending) in sortBy {
                    let cmp = DAXOps.sortCompare(data[x.element][safe: col] ?? .null, data[y.element][safe: col] ?? .null)
                    if cmp != 0 { return descending ? cmp > 0 : cmp < 0 }
                }
                return x.offset < y.offset
            }.map(\.element)
        }
        return VisualAxis(rows: rows, at: rows.firstIndex(of: vc.row))
    }

    // MARK: Levels

    /// The row that stands for the current position: the current row, or the first aggregated row.
    private func anchorRow(_ vc: VisualCalcContext) -> [Value]? {
        vc.grid.data[safe: vc.row >= 0 ? vc.row : (vc.aggRows?.first ?? -1)]
    }

    private func levelGrid(_ vc: VisualCalcContext, _ kept: [Int], _ fn: String) throws -> TableValue {
        guard let build = vc.levelGrid else { throw DAXError("\(fn) needs a visual with hierarchy levels.") }
        return try build(kept)
    }

    /// The axis keyword, level count and named columns of COLLAPSE / EXPAND arguments.
    private func levelArgs(_ args: [Node], _ ctx: Ctx, _ vc: VisualCalcContext, _ fn: String) throws -> (columns: Bool, levels: Int, named: [Int]) {
        var alongColumns = false, levels = 1
        var named: [Int] = []
        for node in args.dropFirst() where !node.isMissing {
            if let k = keyword(node, ctx) {
                guard DAXEngine.axisKeywords.contains(k) else {
                    throw DAXError("\(fn): unknown axis '\(k)'. Use ROWS or COLUMNS.", range: node.range)
                }
                alongColumns = k == "COLUMNS"
            } else if case .column(nil, let name, _) = node.kind, let k = vc.grid.cols.byName[name.daxKey] {
                named.append(k)
            } else {
                levels = max(1, Int(try DAXOps.number(scalar(node, ctx))))
            }
        }
        return (alongColumns, levels, named)
    }

    /// COLLAPSE / COLLAPSEALL: evaluates the expression at a higher level of the axis.
    func collapse(_ args: [Node], _ ctx: Ctx, all: Bool, fn: String) throws -> DAXResult {
        guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
        let (alongColumns, levels, named) = try levelArgs(args, ctx, vc, fn)
        var rows = vc.rowAxis, cols = vc.colAxis
        if !named.isEmpty {
            // Collapsing a column removes it and every level below it on its axis.
            for k in named {
                if let i = rows.firstIndex(of: k) { rows = Array(rows.prefix(i)) }
                else if let i = cols.firstIndex(of: k) { cols = Array(cols.prefix(i)) }
                else if !vc.fullRowAxis.contains(k), !vc.fullColAxis.contains(k) {
                    throw DAXError("\(fn): [\(vc.grid.cols.infos[k].name)] is not a column of an axis of the visual.")
                }
            }
        } else if alongColumns {
            cols = all ? [] : Array(cols.dropLast(levels))
        } else {
            rows = all ? [] : Array(rows.dropLast(levels))
        }
        let grid = try levelGrid(vc, rows + cols, fn)
        let anchor = anchorRow(vc) ?? []
        let kept = rows + cols
        let row = grid.data.firstIndex { candidate in
            kept.allSatisfy { DAXOps.strictEquals(candidate[safe: $0] ?? .null, anchor[safe: $0] ?? .null) }
        } ?? -1
        var c2 = ctx
        c2.visual = vc.at(grid: grid, rowAxis: rows, colAxis: cols, row: row, aggRows: nil)
        return .scalar(try scalar(args[0], c2))
    }

    /// EXPAND / EXPANDALL: evaluates the expression over the rows one or more levels below the
    /// current one (at the deepest level there is nothing below, and the level stays the same).
    func expand(_ args: [Node], _ ctx: Ctx, all: Bool, fn: String) throws -> DAXResult {
        guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
        let (alongColumns, levels, named) = try levelArgs(args, ctx, vc, fn)
        var rows = vc.rowAxis, cols = vc.colAxis
        func deepen(_ current: [Int], _ full: [Int], to count: Int) -> [Int] { Array(full.prefix(max(current.count, min(full.count, count)))) }
        if !named.isEmpty {
            // Expanding to a column brings in every level down to it on its axis.
            for k in named {
                if let i = vc.fullRowAxis.firstIndex(of: k) { rows = deepen(rows, vc.fullRowAxis, to: i + 1) }
                else if let i = vc.fullColAxis.firstIndex(of: k) { cols = deepen(cols, vc.fullColAxis, to: i + 1) }
                else { throw DAXError("\(fn): [\(vc.grid.cols.infos[k].name)] is not a column of an axis of the visual.") }
            }
        } else if alongColumns {
            cols = deepen(cols, vc.fullColAxis, to: all ? Int.max : cols.count + levels)
        } else {
            rows = deepen(rows, vc.fullRowAxis, to: all ? Int.max : rows.count + levels)
        }
        guard rows.count != vc.rowAxis.count || cols.count != vc.colAxis.count else { return .scalar(try scalar(args[0], ctx)) }
        let grid = try levelGrid(vc, rows + cols, fn)
        let anchor = anchorRow(vc) ?? []
        let parentKeys = vc.rowAxis + vc.colAxis
        let children = grid.data.indices.filter { r in
            parentKeys.allSatisfy { DAXOps.strictEquals(grid.data[r][safe: $0] ?? .null, anchor[safe: $0] ?? .null) }
        }
        var c2 = ctx
        c2.visual = vc.at(grid: grid, rowAxis: rows, colAxis: cols, row: children.count == 1 ? children[0] : -1, aggRows: children)
        return .scalar(try scalar(args[0], c2))
    }

    /// LOOKUP / LOOKUPWITHTOTALS: evaluates the expression in the row of the visual with the given
    /// column values. Axis columns that are not given keep the current row's values (LOOKUP) or
    /// refer to their total (LOOKUPWITHTOTALS).
    func lookup(_ args: [Node], _ ctx: Ctx, totals: Bool) throws -> DAXResult {
        let fn = totals ? "LOOKUPWITHTOTALS" : "LOOKUP"
        guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
        var pairs: [(Int, Value)] = []
        var i = 1
        while i + 1 < args.count {
            guard case .column(nil, let name, _) = args[i].kind, let k = vc.grid.cols.byName[name.daxKey] else {
                throw DAXError("\(fn) expects pairs of a visual column and a value.", range: args[i].range)
            }
            pairs.append((k, try scalar(args[i + 1], ctx)))
            i += 2
        }
        guard !pairs.isEmpty, i == args.count else { throw DAXError("\(fn) needs an expression followed by pairs of a column and a value.") }
        func matches(_ row: [Value], _ wanted: [(Int, Value)]) -> Bool {
            wanted.allSatisfy { DAXOps.compare(row[safe: $0.0] ?? .null, $0.1) == 0 && (row[safe: $0.0] ?? .null).isNull == $0.1.isNull }
        }
        var c2 = ctx
        if totals {
            let given = Set(pairs.map(\.0))
            let rows = vc.fullRowAxis.filter(given.contains), cols = vc.fullColAxis.filter(given.contains)
            guard rows.count + cols.count == given.count else {
                throw DAXError("\(fn): the columns must be columns of an axis of the visual.")
            }
            let grid = try levelGrid(vc, rows + cols, fn)
            guard let row = grid.data.firstIndex(where: { matches($0, pairs) }) else { return .scalar(.null) }
            c2.visual = vc.at(grid: grid, rowAxis: rows, colAxis: cols, row: row, aggRows: nil)
        } else {
            let given = Set(pairs.map(\.0))
            let anchor = anchorRow(vc) ?? []
            let inferred = (vc.rowAxis + vc.colAxis).filter { !given.contains($0) }.map { ($0, anchor[safe: $0] ?? .null) }
            guard let row = vc.grid.data.firstIndex(where: { matches($0, pairs) && matches($0, inferred) }) else { return .scalar(.null) }
            c2.visual = vc.moved(to: row)
        }
        return .scalar(try scalar(args[0], c2))
    }
}
