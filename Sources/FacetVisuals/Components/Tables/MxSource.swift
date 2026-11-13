import AppKit
import FacetCore
import FacetDesign

/// Grid source for the `matrix` visual: pivots rows × columns × values, with stepped or tabular row
/// headers, expand/collapse on both axes, subtotals, grand totals and optional values-on-rows.
final class CmpMxSource: CmpTblGridSource {
    struct RowEntry {
        var node: CmpMxNode
        var isSubtotal = false
        var valueIdx: Int?
        /// First of the sub-rows for this node (always true unless values are on rows).
        var first = true
        var showValues = true
        /// Tabular layout: lowest header level whose label is drawn on this row.
        var firstLevel = 0
    }
    struct ColEntry {
        var node: CmpMxNode
        var isSubtotal = false
        var valueIdx: Int?
    }

    private(set) var spec: VisualSpec
    let data: VisualData
    private let context: VisualContext
    private let f: ResolvedFormat
    let pivot: CmpMxPivot
    private let rowCols: [Int], colCols: [Int], valueCols: [Int]
    private let rowFields: [FieldRef?], colFields: [FieldRef?]
    private(set) var rows: [RowEntry] = []
    private(set) var footer: [RowEntry] = []
    private(set) var cols: [ColEntry] = []
    private var stepped = true
    private var valuesOnRows = false
    private var indentStep: CGFloat = 14
    private var subtotalRows = true, subtotalCols = true, rowGrand = true, colGrand = true
    private var totalLabel = "Total"
    private var showExpanders = true
    private var hasValueRow = false
    private var valueLabelCol: Int?
    private let evaluator: CmpConditionalFormat
    private var heatmap: ConditionalFormat?
    private var ranges: [Int: (min: Double, max: Double)?] = [:]
    private var selectedKeys: Set<String> = []
    private var lastContextKeys: Set<String> = []

    init(env: CmpEnv, previous: CmpTblGridSource?) {
        spec = env.spec; data = env.data; context = env.context; f = env.f
        rowCols = env.data.indices(.rows)
        colCols = env.data.indices(.columns)
        valueCols = env.data.indices(.values).filter { (env.data.fields[safe: $0] ?? nil)?.isHidden != true }
        rowFields = rowCols.map { env.data.fields[safe: $0] ?? nil }
        colFields = colCols.map { env.data.fields[safe: $0] ?? nil }
        let totalsCard = env.spec.format["totals"] ?? env.theme.visualDefaults[VisualType.matrix.rawValue]?["totals"] ?? [:]
        let aggregates: [CmpMxAggregate] = valueCols.map { c in
            let name = (totalsCard[env.caption(c)] ?? totalsCard[env.data.table.columns[c].name])?.stringValue ?? "sum"
            return CmpMxAggregate(rawValue: name) ?? .sum
        }
        pivot = CmpMxPivot(data: env.data, rowCols: rowCols, colCols: colCols, valueCols: valueCols, aggregates: aggregates)
        evaluator = CmpConditionalFormat(spec: env.spec, iconSet: env.f.string("conditionalIcons", "set", "arrows"))
        super.init()
        isInteractive = env.isInteractive
        accessibilityTitle = env.spec.altText.isEmpty ? env.spec.name : env.spec.altText
        let ctxKeys = Set(context.selection.map(\.key))
        if let prev = previous as? CmpMxSource {
            selectedKeys = ctxKeys != prev.lastContextKeys ? ctxKeys : prev.selectedKeys
        } else { selectedKeys = ctxKeys }
        lastContextKeys = ctxKeys

        style = CmpTblStyle.resolve(env)
        stepped = f.bool("layout", "stepped", true)
        valuesOnRows = f.bool("layout", "valuesOnRows", false) && valueCols.count > 1
        indentStep = CGFloat(f.double("layout", "indent", 14))
        subtotalRows = f.bool("subtotals", "rows", true)
        subtotalCols = f.bool("subtotals", "columns", true)
        rowGrand = f.bool("subtotals", "rowGrandTotal", true)
        colGrand = f.bool("subtotals", "columnGrandTotal", true)
        totalLabel = f.string("subtotals", "label", "Total")
        showExpanders = f.bool("expandButtons", "show", true)
        fillWidth = f.bool("grid", "fillWidth", false)
        if f.bool("values", "heatmap", false) {
            var cf = ConditionalFormat(target: .background)
            cf.minColor = env.theme.minimum; cf.maxColor = env.theme.maximum
            heatmap = cf
        }
        rebuild()
    }

    // MARK: Expansion state

    private func key(_ axis: String, _ node: CmpMxNode) -> String { axis + "\u{1F}" + node.pathKey }
    func isExpanded(_ axis: String, _ node: CmpMxNode) -> Bool {
        !node.isLeaf && (spec.expandedAllLevels || spec.expandedPaths.contains(key(axis, node)))
    }
    private func allKeys(_ axis: String, _ node: CmpMxNode, into out: inout Set<String>) {
        for c in node.children where !c.isLeaf { out.insert(key(axis, c)); allKeys(axis, c, into: &out) }
    }
    func toggle(_ axis: String, _ node: CmpMxNode, to target: Bool? = nil) {
        guard !node.isLeaf, node.depth > 0 else { return }
        var set = Set(spec.expandedPaths)
        if spec.expandedAllLevels {
            allKeys("R", pivot.rowRoot, into: &set); allKeys("C", pivot.colRoot, into: &set)
            spec.expandedAllLevels = false
        }
        let k = key(axis, node)
        let want = target ?? !set.contains(k)
        if want == set.contains(k) { return }
        if want { set.insert(k) } else { set.remove(k) }
        spec.expandedPaths = set.sorted()
        commit()
    }
    private func commit() {
        rebuild()
        context.onSpecChange(spec)
        view?.reload()
    }

    // MARK: Layout

    private func rebuild() {
        rows = []; footer = []; cols = []; ranges = [:]
        let vc = valueCols.count
        func emit(_ node: CmpMxNode, subtotal: Bool = false, showValues: Bool = true, into out: inout [RowEntry]) {
            if valuesOnRows {
                for v in 0..<vc { out.append(RowEntry(node: node, isSubtotal: subtotal, valueIdx: v, first: v == 0, showValues: showValues)) }
            } else { out.append(RowEntry(node: node, isSubtotal: subtotal, showValues: showValues)) }
        }
        func addRows(_ node: CmpMxNode) {
            for child in node.children {
                let exp = isExpanded("R", child)
                if stepped {
                    emit(child, showValues: !exp || subtotalRows, into: &rows)
                    if exp { addRows(child) }
                } else if exp {
                    addRows(child)
                    if subtotalRows { emit(child, subtotal: true, into: &rows) }
                } else { emit(child, into: &rows) }
            }
        }
        if rowCols.isEmpty { emit(pivot.rowRoot, into: &rows) }
        else {
            addRows(pivot.rowRoot)
            if rowGrand { emit(pivot.rowRoot, subtotal: true, into: &footer) }
        }
        // Tabular: which header levels start a new group on each row.
        var prev: CmpMxNode?
        for i in rows.indices {
            let node = rows[i].node
            if !rows[i].first { rows[i].firstLevel = Int.max; continue }
            var level = 0
            if let p = prev { while level < min(p.depth, node.depth), p.path[level] == node.path[level] { level += 1 } }
            if rows[i].isSubtotal { level = node.depth }
            rows[i].firstLevel = level
            prev = rows[i].isSubtotal ? nil : node
            if rows[i].isSubtotal { prev = node }
        }

        func emitCol(_ node: CmpMxNode, subtotal: Bool = false) {
            if valuesOnRows || vc == 0 { cols.append(ColEntry(node: node, isSubtotal: subtotal)) }
            else { for v in 0..<vc { cols.append(ColEntry(node: node, isSubtotal: subtotal, valueIdx: v)) } }
        }
        func addCols(_ node: CmpMxNode) {
            for child in node.children {
                if isExpanded("C", child) {
                    addCols(child)
                    if subtotalCols { emitCol(child, subtotal: true) }
                } else { emitCol(child) }
            }
        }
        if colCols.isEmpty { emitCol(pivot.colRoot) }
        else {
            addCols(pivot.colRoot)
            if colGrand { emitCol(pivot.colRoot, subtotal: true) }
        }

        let levelCols = stepped ? 1 : max(1, rowCols.count)
        valueLabelCol = valuesOnRows ? levelCols : nil
        frozenCols = levelCols + (valuesOnRows ? 1 : 0)
        hasValueRow = !valuesOnRows && (vc > 1 || colCols.isEmpty)
        headerRows = max(1, colCols.count + (hasValueRow ? 1 : 0))
        bodyRows = rows.count
        footerRows = footer.count
        measure()
    }

    private func caption(_ dataCol: Int) -> String {
        if let fld = data.fields[safe: dataCol] ?? nil { return fld.caption }
        return data.table.columns[safe: dataCol]?.name ?? ""
    }
    private func label(_ node: CmpMxNode, axis: String) -> String {
        guard let v = node.path.last else { return totalLabel }
        let col = (axis == "R" ? rowCols : colCols)[safe: node.depth - 1]
        let s = CmpTblFormat.text(v, format: col.flatMap { data.formats[safe: $0] } ?? "", grouping: true)
        return s.isEmpty ? "(Blank)" : s
    }
    private func ancestor(_ node: CmpMxNode, depth: Int) -> CmpMxNode {
        var n = node
        while n.depth > depth, let p = n.parent { n = p }
        return n
    }
    private func widthKey(_ col: Int) -> String {
        if col == valueLabelCol { return "Values" }
        if col < frozenCols { return rowCols[safe: col].map(caption) ?? "Rows" }
        if let v = cols[safe: col - frozenCols]?.valueIdx { return caption(valueCols[v]) }
        return "Values"
    }

    private func measure() {
        let widthCard = spec.format["columnWidths"] ?? [:]
        baseWidths = []; fixed = []
        let pad = style.padH * 2
        let exp = CmpTblCellRenderer.expanderWidth
        for c in 0..<frozenCols {
            if let w = widthCard[widthKey(c)]?.doubleValue { baseWidths.append(max(28, CGFloat(w))); fixed.append(true); continue }
            var w: CGFloat = 0
            if c == valueLabelCol {
                for v in valueCols { w = max(w, CmpFit.width(caption(v), font: style.bodyFont)) }
            } else {
                w = CmpFit.width(cornerText(c), font: style.headerFont)
                for i in 0..<min(rows.count, 400) {
                    let cell = bodyCell(i, c)
                    guard !cell.text.isEmpty else { continue }
                    w = max(w, CmpFit.width(cell.text, font: cell.bold ? style.bodyBoldFont : style.bodyFont) + cell.indent + (cell.expander != nil ? exp : 0))
                }
                w = max(w, CmpFit.width(totalLabel, font: style.bodyBoldFont))
            }
            baseWidths.append(min(280, max(56, ceil(w + pad)))); fixed.append(false)
        }
        // One width per value (shared by all its columns) so the grid reads as a regular rhythm.
        var perValue: [Int: CGFloat] = [:]
        let sampleRows = Array(rows.prefix(60)) + footer
        for (ci, ce) in cols.enumerated().prefix(120) {
            let slot = ce.valueIdx ?? -1
            var w = perValue[slot] ?? 0
            if hasValueRow, let v = ce.valueIdx { w = max(w, CmpFit.width(caption(valueCols[v]), font: style.headerFont)) }
            else if ce.node.depth > 0 {
                let leaf = ce.isSubtotal ? totalLabel : label(ce.node, axis: "C")
                w = max(w, CmpFit.width(leaf, font: style.headerFont) + (ce.node.isLeaf || ce.isSubtotal ? 0 : exp))
            } else { w = max(w, CmpFit.width(totalLabel, font: style.headerFont)) }
            for (ri, entry) in sampleRows.enumerated() {
                let cell = ri < min(rows.count, 60) ? bodyCell(ri, frozenCols + ci) : valueCell(entry, ce, isFooter: true)
                if !cell.text.isEmpty { w = max(w, CmpFit.width(cell.text, font: style.bodyBoldFont) + (cell.icon != nil ? 18 : 0)) }
            }
            perValue[slot] = w
        }
        for ce in cols {
            let k = ce.valueIdx.map { caption(valueCols[$0]) } ?? "Values"
            if let w = widthCard[k]?.doubleValue { baseWidths.append(max(28, CGFloat(w))); fixed.append(true) }
            else { baseWidths.append(min(240, max(56, ceil((perValue[ce.valueIdx ?? -1] ?? 40) + pad)))); fixed.append(false) }
        }
    }

    // MARK: Header

    private func cornerText(_ col: Int) -> String {
        if col == valueLabelCol { return "Values" }
        if stepped { return rowCols.first.map(caption) ?? "" }
        return rowCols[safe: col].map(caption) ?? ""
    }

    /// Column node whose expander lives in header row `level` above grid column `col` (nil when none).
    private func headerNode(level: Int, entry e: ColEntry) -> CmpMxNode? {
        guard level < colCols.count, level < e.node.depth else { return nil }
        return ancestor(e.node, depth: level + 1)
    }

    override func headerSpans(_ row: Int) -> [CmpTblSpan] {
        var spans: [CmpTblSpan] = []
        // Corner
        if row == headerRows - 1 {
            for c in 0..<frozenCols { spans.append(CmpTblSpan(cols: c..<(c + 1), cell: CmpTblCell(text: cornerText(c)))) }
        } else if frozenCols > 0 {
            let text = colCols[safe: row].map(caption) ?? ""
            var cell = CmpTblCell(text: text, align: .right)
            cell.textColor = style.secondaryText
            spans.append(CmpTblSpan(cols: 0..<frozenCols, cell: cell))
        }
        if hasValueRow, row == headerRows - 1 {
            for (i, e) in cols.enumerated() {
                let text = e.valueIdx.map { caption(valueCols[$0]) } ?? ""
                var cell = CmpTblCell(text: text, align: .right)
                cell.bold = e.isSubtotal
                if colCols.count > 0 { cell.textColor = style.secondaryText }
                spans.append(CmpTblSpan(cols: (frozenCols + i)..<(frozenCols + i + 1), cell: cell))
            }
            return spans
        }
        var lastKey: String?
        for (i, e) in cols.enumerated() {
            let d = e.node.depth
            var k: String, cell = CmpTblCell()
            if row < d, let anc = headerNode(level: row, entry: e) {
                k = "n\(anc.id)"
                cell.text = label(anc, axis: "C")
                if !anc.isLeaf, showExpanders { cell.expander = isExpanded("C", anc) }
            } else if e.isSubtotal {
                k = "t\(e.node.id)"
                if row == d { cell.text = totalLabel }
            } else { k = "b\(e.node.id)" }
            let gridCol = frozenCols + i
            if k == lastKey, var last = spans.popLast() {
                last.cols = last.cols.lowerBound..<(gridCol + 1)
                spans.append(last)
            } else {
                spans.append(CmpTblSpan(cols: gridCol..<(gridCol + 1), cell: cell))
            }
            lastKey = k
        }
        // Single-column leaf headers sit right above right-aligned numbers.
        for i in spans.indices where spans[i].cols.lowerBound >= frozenCols {
            if spans[i].cols.count == 1, spans[i].cell.expander == nil { spans[i].cell.align = .right }
        }
        return spans
    }

    // MARK: Cells

    private func range(for v: Int) -> (min: Double, max: Double)? {
        if let r = ranges[v] { return r }
        var values: [Value] = []
        for entry in rows.prefix(400) where !entry.isSubtotal && entry.showValues && (entry.valueIdx ?? v) == v {
            if stepped, isExpanded("R", entry.node) { continue }
            for ce in cols.prefix(200) where !ce.isSubtotal && (ce.valueIdx ?? v) == v {
                values.append(pivot.value(row: entry.node, col: ce.node, v: v))
            }
        }
        let r = CmpConditionalFormat.range(values)
        ranges[v] = r
        return r
    }

    private func rowPoint(_ node: CmpMxNode) -> DataPointSelection? {
        var fields: [FieldRef] = [], values: [Value] = []
        for (i, v) in node.path.enumerated() { if let fld = rowFields[safe: i] ?? nil { fields.append(fld); values.append(v) } }
        return fields.isEmpty ? nil : DataPointSelection(fields: fields, values: values)
    }
    private func cellPoint(_ row: CmpMxNode, _ col: CmpMxNode) -> DataPointSelection? {
        var fields: [FieldRef] = [], values: [Value] = []
        for (i, v) in row.path.enumerated() { if let fld = rowFields[safe: i] ?? nil { fields.append(fld); values.append(v) } }
        for (i, v) in col.path.enumerated() { if let fld = colFields[safe: i] ?? nil { fields.append(fld); values.append(v) } }
        return fields.isEmpty ? nil : DataPointSelection(fields: fields, values: values)
    }

    /// True when the node or one of its ancestors is selected (children of a selected group stay emphasised).
    private func rowEmphasised(_ node: CmpMxNode) -> Bool {
        var n: CmpMxNode? = node
        while let cur = n, cur.depth > 0 {
            if let p = rowPoint(cur), selectedKeys.contains(p.key) { return true }
            n = cur.parent
        }
        return false
    }

    override func isRowSelected(_ row: Int) -> Bool {
        guard !selectedKeys.isEmpty, let e = rows[safe: row], !e.isSubtotal, let p = rowPoint(e.node) else { return false }
        return selectedKeys.contains(p.key)
    }
    override func isRowAlternate(_ row: Int) -> Bool {
        valuesOnRows ? (row / max(1, valueCols.count)) % 2 == 1 : row % 2 == 1
    }

    private func valueCell(_ entry: RowEntry, _ ce: ColEntry, isFooter: Bool) -> CmpTblCell {
        var cell = CmpTblCell(align: .right)
        guard let v = entry.valueIdx ?? ce.valueIdx, entry.showValues else { return cell }
        let rowTotal = isFooter || entry.isSubtotal || (stepped && isExpanded("R", entry.node))
        let isTotal = rowTotal || ce.isSubtotal
        let value = pivot.value(row: entry.node, col: ce.node, v: v)
        cell.text = ValueFormatter.format(value, data.formats[safe: valueCols[v]] ?? "")
        cell.bold = rowTotal || (ce.isSubtotal && ce.node.depth == 0)
        if !selectedKeys.isEmpty, !isFooter {
            let cellSel = cellPoint(entry.node, ce.node).map { selectedKeys.contains($0.key) } ?? false
            let rowSel = rowEmphasised(entry.node)
            cell.selected = cellSel && ce.node.depth > 0
            cell.dimmed = !cellSel && !rowSel
        }
        guard !isTotal, !value.isNull else { return cell }
        let field = data.fields[safe: valueCols[v]] ?? nil
        if let cf = evaluator.rule(.background, field: field) ?? heatmap,
           let hex = evaluator.colorHex(cf, value: value, range: range(for: v)) {
            cell.background = CmpColor.ns(hex)
            cell.textColor = CmpColor.ns(CmpColor.readableText(on: hex))
        }
        if let cf = evaluator.rule(.fontColor, field: field), let hex = evaluator.colorHex(cf, value: value, range: range(for: v)) {
            cell.textColor = CmpColor.ns(hex)
        }
        if let cf = evaluator.rule(.dataBars, field: field) { cell.bar = evaluator.dataBar(cf, value: value, range: range(for: v)) }
        if let cf = evaluator.rule(.icons, field: field) { cell.icon = evaluator.icon(cf, value: value, range: range(for: v)) }
        return cell
    }

    private func headerCell(_ entry: RowEntry, _ col: Int, isFooter: Bool) -> CmpTblCell {
        var cell = CmpTblCell()
        let node = entry.node
        if col == valueLabelCol {
            if let v = entry.valueIdx { cell.text = caption(valueCols[v]); cell.textColor = style.secondaryText }
            return cell
        }
        if isFooter || node.depth == 0 {
            if col == 0, entry.first { cell.text = totalLabel; cell.bold = true }
            return cell
        }
        guard entry.first else { return cell }
        if stepped {
            cell.text = label(node, axis: "R")
            cell.indent = CGFloat(node.depth - 1) * indentStep
            cell.bold = !node.isLeaf
            if !node.isLeaf, showExpanders { cell.expander = isExpanded("R", node) }
            else if rowCols.count > 1, showExpanders { cell.indent += CmpTblCellRenderer.expanderWidth }
        } else if entry.isSubtotal {
            if col == node.depth { cell.text = totalLabel; cell.bold = true }
            else if col == node.depth - 1, entry.firstLevel <= col { cell.text = label(node, axis: "R"); cell.bold = true }
        } else if col < node.depth, col >= entry.firstLevel {
            let anc = ancestor(node, depth: col + 1)
            cell.text = label(anc, axis: "R")
            cell.bold = !anc.isLeaf
            if !anc.isLeaf, showExpanders { cell.expander = isExpanded("R", anc) }
        }
        if !selectedKeys.isEmpty, !rowEmphasised(node) { cell.dimmed = true }
        return cell
    }

    override func bodyCell(_ row: Int, _ col: Int) -> CmpTblCell {
        guard let entry = rows[safe: row] else { return CmpTblCell() }
        if col < frozenCols { return headerCell(entry, col, isFooter: false) }
        guard let ce = cols[safe: col - frozenCols] else { return CmpTblCell() }
        return valueCell(entry, ce, isFooter: false)
    }
    override func footerCell(_ row: Int, _ col: Int) -> CmpTblCell {
        guard let entry = footer[safe: row] else { return CmpTblCell() }
        if col < frozenCols { return headerCell(entry, col, isFooter: true) }
        guard let ce = cols[safe: col - frozenCols] else { return CmpTblCell() }
        return valueCell(entry, ce, isFooter: true)
    }

    // MARK: Interaction

    override func headerClick(row: Int, col: Int, shift: Bool, onExpander: Bool) {
        guard onExpander, col >= frozenCols, let e = cols[safe: col - frozenCols],
              let node = headerNode(level: row, entry: e) else { return }
        toggle("C", node)
    }

    /// The row node a frozen header cell represents (tabular cells represent ancestors).
    private func rowNode(_ entry: RowEntry, col: Int) -> CmpMxNode {
        stepped || entry.isSubtotal || col >= entry.node.depth ? entry.node : ancestor(entry.node, depth: col + 1)
    }

    override func bodyClick(row: Int, col: Int, command: Bool, shift: Bool, onExpander: Bool) {
        guard let entry = rows[safe: row] else { return }
        if col < frozenCols {
            let node = rowNode(entry, col: col)
            if onExpander { toggle("R", node); return }
            select(rowPoint(node), additive: command)
        } else if let ce = cols[safe: col - frozenCols] {
            select(ce.node.depth > 0 && !entry.isSubtotal ? cellPoint(entry.node, ce.node) : rowPoint(entry.node), additive: command)
        }
    }

    private func select(_ point: DataPointSelection?, additive: Bool) {
        guard let p = point else { clearSelection(); return }
        if additive {
            if selectedKeys.contains(p.key) { selectedKeys.remove(p.key) } else { selectedKeys.insert(p.key) }
            context.onSelect([p], true)
        } else if selectedKeys == [p.key] {
            selectedKeys = []
            context.onSelect([], false)
        } else {
            selectedKeys = [p.key]
            context.onSelect([p], false)
        }
        view?.redrawAll()
    }

    override func selectRow(_ row: Int, additive: Bool, extend: Bool) {
        guard let entry = rows[safe: row], let p = rowPoint(entry.node) else { return }
        if additive || extend {
            if additive, selectedKeys.contains(p.key) { selectedKeys.remove(p.key) } else { selectedKeys.insert(p.key) }
            context.onSelect([p], true)
        } else {
            selectedKeys = [p.key]
            context.onSelect([p], false)
        }
        view?.redrawAll()
    }
    override func clearSelection() {
        guard !selectedKeys.isEmpty else { return }
        selectedKeys = []
        context.onSelect([], false)
        view?.redrawAll()
    }
    override func selectAll() {
        let points = rows.filter { !$0.isSubtotal && $0.first }.compactMap { rowPoint($0.node) }
        selectedKeys = Set(points.map(\.key))
        context.onSelect(points, false)
    }

    override func setExpanded(row: Int, _ expanded: Bool?) {
        guard let entry = rows[safe: row] else { return }
        let node = entry.node
        switch expanded {
        case .some(true): if !node.isLeaf { toggle("R", node, to: true) }
        case .some(false):
            if isExpanded("R", node) { toggle("R", node, to: false) }
            else if let p = node.parent, p.depth > 0 { toggle("R", p, to: false) }
        case .none: toggle("R", node)
        }
    }

    // MARK: Copy, menu, resize

    private func flatHeader(_ ce: ColEntry) -> String {
        var parts = ce.node.path.enumerated().map { i, v in
            CmpTblFormat.text(v, format: colCols[safe: i].flatMap { data.formats[safe: $0] } ?? "", grouping: true)
        }
        if ce.isSubtotal { parts.append(totalLabel) }
        if let v = ce.valueIdx, valueCols.count > 1 || parts.isEmpty { parts.append(caption(valueCols[v])) }
        return parts.joined(separator: " / ")
    }

    /// Visible rows (selected ones when a selection exists) as TSV with one flattened header line.
    func tsv() -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = [((0..<frozenCols).map(cornerText) + cols.map(flatHeader)).map(clean).joined(separator: "\t")]
        let chosen = selectedKeys.isEmpty ? [] : rows.indices.filter { isRowSelected($0) }
        let indices = chosen.isEmpty ? Array(rows.indices) : chosen
        for i in indices {
            lines.append((0..<baseWidths.count).map { c -> String in
                let cell = bodyCell(i, c)
                return clean(c < frozenCols && stepped ? String(repeating: "  ", count: max(0, rows[i].node.depth - 1)) + cell.text : cell.text)
            }.joined(separator: "\t"))
        }
        if chosen.isEmpty {
            for i in footer.indices { lines.append((0..<baseWidths.count).map { clean(footerCell(i, $0).text) }.joined(separator: "\t")) }
        }
        return lines.joined(separator: "\n")
    }
    override func copySelection() { CmpPasteboard.copy(tsv()) }

    override func menu(row: Int?, col: Int) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var point: DataPointSelection?
        if let row, let entry = rows[safe: row] {
            let text = bodyCell(row, col).text
            menu.addItem(CmpTblMenuItem("Copy value") { CmpPasteboard.copy(text) })
            if col < frozenCols { point = rowPoint(rowNode(entry, col: col)) }
            else if let ce = cols[safe: col - frozenCols] { point = cellPoint(entry.node, ce.node) }
        }
        menu.addItem(CmpTblMenuItem(selectedKeys.isEmpty ? "Copy matrix" : "Copy selection") { [weak self] in self?.copySelection() })
        menu.addItem(.separator())
        menu.addItem(CmpTblMenuItem("Expand all") { [weak self] in
            guard let self else { return }
            self.spec.expandedAllLevels = true; self.spec.expandedPaths = []; self.commit()
        })
        menu.addItem(CmpTblMenuItem("Collapse all") { [weak self] in
            guard let self else { return }
            self.spec.expandedAllLevels = false; self.spec.expandedPaths = []; self.commit()
        })
        if row != nil {
            menu.addItem(.separator())
            menu.addItem(CmpTblMenuItem("Drill through", enabled: point != nil) { [weak self] in
                if let point { self?.context.onDrill(.drillthrough(point, pageID: nil)) }
            })
            menu.addItem(CmpTblMenuItem("Include", enabled: point != nil) { [weak self] in self?.addFilter(point, exclude: false) })
            menu.addItem(CmpTblMenuItem("Exclude", enabled: point != nil) { [weak self] in self?.addFilter(point, exclude: true) })
        }
        return menu
    }

    private func addFilter(_ point: DataPointSelection?, exclude: Bool) {
        guard let point else { return }
        for (field, value) in zip(point.fields, point.values) {
            var filter = FilterSpec(field: field, kind: .basic)
            filter.values = [value]
            filter.isInverted = exclude
            filter.displayName = exclude ? "Excluded" : "Included"
            spec.filters.append(filter)
        }
        context.onSpecChange(spec)
    }

    override func columnResized(col: Int, width: CGFloat?) {
        spec.setFmt("columnWidths", widthKey(col), width.map { .number(Double($0.rounded())) })
        measure()
        context.onSpecChange(spec)
        view?.reload()
    }
}
