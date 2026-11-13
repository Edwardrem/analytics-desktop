import Foundation
import FacetCore

extension DAXEngine {
    // MARK: Visual calculations (RUNNINGSUM, MOVINGAVERAGE, COLLAPSE, EXPAND, …)

    static let visualCalcFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        func visualContext(_ ctx: Ctx, _ fn: String) throws -> VisualCalcContext {
            guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
            return vc
        }
        /// The visual column a node refers to: (context, column index, values in grid order).
        func column(_ e: DAXEngine, _ node: Node, _ ctx: Ctx, _ fn: String) throws -> (VisualCalcContext, Int, [Value]) {
            let vc = try visualContext(ctx, fn)
            let (n, _) = e.deref(node, ctx)
            guard case .column(nil, let name, _) = n.kind, let k = vc.grid.cols.byName[name.daxKey] else {
                throw DAXError("\(fn) expects a visual column such as [\(vc.grid.cols.infos.first?.name ?? "Amount")].", range: node.range)
            }
            let values = vc.grid.data.map { $0[safe: k] ?? .null }
            return (vc, k, values)
        }

        d["RUNNINGSUM"] = { e, a, c, n in
            let (vc, _, values) = try column(e, a[0], c, "RUNNINGSUM")
            var total = 0.0
            for v in values.prefix(max(0, vc.row + 1)) {
                if let d = try? DAXOps.number(v) { total += d }
            }
            return .scalar(.double(total))
        }
        d["MOVINGAVERAGE"] = { e, a, c, n in
            let (vc, _, values) = try column(e, a[0], c, "MOVINGAVERAGE")
            let window = Int(try DAXOps.number(e.scalar(a[1], c)))
            let includeCurrent = e.arg(a, 2) != nil ? try DAXOps.truthy(e.scalar(a[2], c)) : true
            let end = includeCurrent ? vc.row : vc.row - 1
            let start = max(0, end - max(0, window - 1))
            guard end >= start, end < values.count else { return .scalar(.null) }
            var total = 0.0, count = 0
            for v in values[start...end] {
                if let x = try? DAXOps.number(v) { total += x; count += 1 }
            }
            return .scalar(count == 0 ? .null : .double(total / Double(count)))
        }
        for (name, offset) in [("PREVIOUS", -1), ("NEXT", 1)] {
            d[name] = { e, a, c, n in
                let (vc, _, values) = try column(e, a[0], c, name)
                let steps = e.arg(a, 1) != nil ? Int(try DAXOps.number(e.scalar(a[1], c))) : 1
                let target = vc.row + offset * abs(steps)
                guard target >= 0, target < values.count else { return .scalar(.null) }
                return .scalar(values[target])
            }
        }
        for (name, target) in [("FIRST", 0), ("LAST", Int.max)] {
            d[name] = { e, a, c, n in
                let (vc, _, values) = try column(e, a[0], c, name)
                let at = target == 0 ? 0 : values.count - 1
                guard values.indices.contains(at) else { return .scalar(.null) }
                return .scalar(values[at])
            }
        }
        d["COLLAPSE"] = { e, a, c, n in
            return try e.collapse(a, c, all: false, fn: "COLLAPSE")
        }
        d["COLLAPSEALL"] = { e, a, c, n in
            return try e.collapse(a, c, all: true, fn: "COLLAPSEALL")
        }
        d["EXPAND"] = { e, a, c, n in
            return try e.expand(a, c, all: false, fn: "EXPAND")
        }
        d["EXPANDALL"] = { e, a, c, n in
            return try e.expand(a, c, all: true, fn: "EXPANDALL")
        }
        d["RANGE"] = { e, a, c, n in
            let vc = try visualContext(c, "RANGE")
            let start = Int(try DAXOps.number(e.scalar(a[0], c)))
            let hasEnd = e.arg(a, 1) != nil
            let end = hasEnd ? Int(try DAXOps.number(e.scalar(a[1], c))) : vc.row + start
            let lo = min(start, end), hi = max(start, end)
            let rows = (lo...hi).compactMap { r -> [Value]? in vc.grid.data[safe: r] }
            return .table(TableValue(cols: vc.grid.cols, rows: rows))
        }
        d["LOOKUP"] = { e, a, c, n in
            return try e.lookup(a, c, totals: false)
        }
        d["LOOKUPWITHTOTALS"] = { e, a, c, n in
            return try e.lookup(a, c, totals: true)
        }
        d["ISATLEVEL"] = { e, a, c, n in
            let vc = try visualContext(c, "ISATLEVEL")
            guard case .column(nil, let name, _) = a[0].kind else { return .scalar(.bool(false)) }
            let atRow = vc.allRowFields.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                && vc.rowAxis.contains { vc.grid.cols.infos[safe: $0]?.name.caseInsensitiveCompare(name) == .orderedSame }
            let atCol = vc.allColFields.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                && vc.colAxis.contains { vc.grid.cols.infos[safe: $0]?.name.caseInsensitiveCompare(name) == .orderedSame }
            return .scalar(.bool(atRow || atCol))
        }
        return d
    }()

    /// COLLAPSE / COLLAPSEALL: evaluates the expression at a higher level of the axis.
    func collapse(_ args: [Node], _ ctx: Ctx, all: Bool, fn: String) throws -> DAXResult {
        guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
        guard let level = vc.level else { throw DAXError("\(fn) needs a visual with hierarchy levels.") }
        let (axis, levels) = try collapseArgs(args, ctx: ctx, vc: vc, fn: fn)
        let rows: Int, cols: Int
        if axis == "COLUMNS" {
            rows = vc.rowAxis.count
            cols = all ? 0 : max(0, vc.colAxis.count - levels)
        } else {
            rows = all ? 0 : max(0, vc.rowAxis.count - levels)
            cols = vc.colAxis.count
        }
        let parent = try level(rows, cols)
        // Rows of the parent grid that share the current row's grouping values.
        let current = vc.grid.data[safe: vc.row] ?? []
        let parentKeys = parent.rowAxis + parent.colAxis
        let matching: [Int]
        if all || parentKeys.isEmpty {
            matching = Array(0..<parent.grid.count)
        } else {
            var wanted: [Value] = []
            for k in parentKeys {
                let inChild = (vc.rowAxis.firstIndex(of: k) ?? vc.rowAxis.count) + (vc.colAxis.firstIndex(of: k) ?? 0)
                wanted.append(current[safe: inChild] ?? .null)
            }
            matching = parent.grid.data.enumerated().compactMap { i, row in
                parentKeys.enumerated().allSatisfy { k, pos in DAXOps.strictEquals(row[safe: pos] ?? .null, wanted[safe: k] ?? .null) } ? i : nil
            }
        }
        var c2 = ctx
        c2.visual = parent
        c2.visual?.aggRows = matching.isEmpty ? nil : matching
        return .scalar(try scalar(args[0], c2))
    }

    /// EXPAND / EXPANDALL: evaluates the expression at a lower level of the axis.
    func expand(_ args: [Node], _ ctx: Ctx, all: Bool, fn: String) throws -> DAXResult {
        guard let vc = ctx.visual else { throw DAXError("\(fn) can only be used in a visual calculation.") }
        guard let level = vc.level else { throw DAXError("\(fn) needs a visual with hierarchy levels.") }
        let (axis, levels) = try collapseArgs(args, ctx: ctx, vc: vc, fn: fn)
        let rows: Int, cols: Int
        if axis == "COLUMNS" {
            rows = vc.rowAxis.count
            cols = all ? 64 : min(64, vc.colAxis.count + levels)
        } else {
            rows = all ? 64 : min(64, vc.rowAxis.count + levels)
            cols = vc.colAxis.count
        }
        let child = try level(rows, cols)
        // Rows of the child grid whose higher-level grouping matches the current row.
        let current = vc.grid.data[safe: vc.row] ?? []
        let keyCount = axis == "COLUMNS" ? vc.colAxis.count : vc.rowAxis.count
        let matching: [Int]
        if all {
            matching = Array(0..<child.grid.count)
        } else if keyCount == 0 {
            matching = Array(0..<child.grid.count)
        } else {
            let wanted = Array(current.prefix(keyCount))
            matching = child.grid.data.enumerated().compactMap { i, row in
                row.prefix(keyCount).enumerated().allSatisfy { k, v in DAXOps.strictEquals(v, wanted[safe: k] ?? .null) } ? i : nil
            }
        }
        var c2 = ctx
        c2.visual = child
        c2.visual?.aggRows = matching.isEmpty ? nil : matching
        return .scalar(try scalar(args[0], c2))
    }

    /// The axis keyword and level count of COLLAPSE / EXPAND arguments.
    private func collapseArgs(_ args: [Node], ctx: Ctx, vc: VisualCalcContext, fn: String) throws -> (String, Int) {
        var axis = "ROWS"
        var levels = 1
        var i = 1
        while i < args.count {
            if let keyword = try keywordArg(args, i, ctx) {
                let u = keyword.uppercased()
                if u.contains("COLUMNS") && !u.contains("ROWS") { axis = "COLUMNS" }
                else if u.contains("ROWS") { axis = u }
                else if let n = Int(u) { levels = max(1, n) }
            } else if let n = arg(args, i) {
                let v = try scalar(n, ctx)
                if let k = v.asInt { levels = max(1, Int(k)) }
            }
            i += 1
        }
        return (axis, levels)
    }

    /// LOOKUP / LOOKUPWITHTOTALS: evaluates the expression in the visual row matching the given column values.
    func lookup(_ args: [Node], _ ctx: Ctx, totals: Bool) throws -> DAXResult {
        guard let vc = ctx.visual else { throw DAXError("LOOKUP can only be used in a visual calculation.") }
        var pairs: [(Int, Value)] = []
        var i = 1
        while i + 1 < args.count {
            guard case .column(nil, let name, _) = args[i].kind, let k = vc.grid.cols.byName[name.daxKey] else {
                throw DAXError("LOOKUP expects pairs of a visual column and a value.", range: args[i].range)
            }
            pairs.append((k, try scalar(args[i + 1], ctx)))
            i += 2
        }
        guard !pairs.isEmpty else { throw DAXError("LOOKUP needs at least one column and value.") }
        for (r, row) in vc.grid.data.enumerated() where pairs.allSatisfy({ DAXOps.strictEquals(row[safe: $0.0] ?? .null, $0.1) }) {
            var c2 = ctx
            c2.visual?.row = r
            return .scalar(try scalar(args[0], c2))
        }
        if totals {
            var c2 = ctx
            c2.visual?.aggRows = Array(0..<vc.grid.count)
            return .scalar(try scalar(args[0], c2))
        }
        return .scalar(.null)
    }
}
