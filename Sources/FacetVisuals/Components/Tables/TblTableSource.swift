import AppKit
import FacetCore
import FacetDesign

/// Grid source for the `table` visual: one grid row per data row, sticky header, pinned totals row.
final class CmpTblTableSource: CmpTblGridSource {
    struct Rule { var cf: ConditionalFormat; var driver: Int; var range: (min: Double, max: Double)? }
    struct Column {
        var dataIndex: Int
        var name: String
        var caption: String
        var field: FieldRef?
        var format: String
        var numeric: Bool
        var align: NSTextAlignment
        var background: Rule?
        var fontColor: Rule?
        var bars: Rule?
        var icons: Rule?
        var urlDriver: Int?
        var imageDriver: Int?
        var spark: Bool = false
        var sparkColumns = false
    }

    private(set) var spec: VisualSpec
    let data: VisualData
    private let context: VisualContext
    private let f: ResolvedFormat
    private(set) var columns: [Column] = []
    /// Display row → data row (nil = identity).
    private(set) var order: [Int]?
    private let groupCols: [Int]
    private let evaluator: CmpConditionalFormat
    private var selectedKeys: Set<String> = []
    private var lastContextKeys: Set<String> = []
    private var anchorRow: Int?
    private var wrap = false
    private var detectURLs = true
    private var barOnly = false, iconOnly = false, iconTrailing = false
    private var totalLabel = "Total"
    private var totalBold = true

    init(env: CmpEnv, previous: CmpTblGridSource?) {
        spec = env.spec; data = env.data; context = env.context; f = env.f
        groupCols = CmpSelection.groupingColumns(env.data)
        evaluator = CmpConditionalFormat(spec: env.spec, iconSet: env.f.string("conditionalIcons", "set", "arrows"))
        super.init()
        isInteractive = env.isInteractive
        accessibilityTitle = env.spec.altText.isEmpty ? env.spec.name : env.spec.altText
        let ctxKeys = Set(context.selection.map(\.key))
        if let prev = previous as? CmpTblTableSource {
            selectedKeys = ctxKeys != prev.lastContextKeys ? ctxKeys : prev.selectedKeys
            anchorRow = prev.anchorRow
        } else { selectedKeys = ctxKeys }
        lastContextKeys = ctxKeys
        build(env)
    }

    // MARK: Build

    private func build(_ env: CmpEnv) {
        style = CmpTblStyle.resolve(env)
        wrap = f.bool("values", "wordWrap", false)
        detectURLs = f.bool("values", "detectURLs", true)
        barOnly = f.bool("dataBars", "barOnly", false)
        iconOnly = f.bool("conditionalIcons", "iconOnly", false)
        iconTrailing = f.string("conditionalIcons", "position", "left") == "right"
        totalLabel = f.string("total", "label", "Total")
        totalBold = f.bool("total", "bold", true)
        fillWidth = f.bool("grid", "fillWidth", true)
        let table = data.table
        var indices = data.indices(.values)
        if indices.isEmpty { indices = Array(0..<table.columnCount) }
        let alignOverride = f.string("values", "alignment", "auto")
        let sparkCard = spec.format["sparklines"] ?? [:]
        let imageCard = spec.format["imageColumns"] ?? [:]
        columns = indices.compactMap { i -> Column? in
            guard i < table.columnCount else { return nil }
            let field = data.fields[safe: i] ?? nil
            if field?.isHidden == true { return nil }
            let col = table.columns[i]
            let numeric = col.type.isNumeric || (field?.isAggregate ?? false)
            var align: NSTextAlignment = numeric ? .right : .left
            switch alignOverride { case "left": align = .left; case "center": align = .center; case "right": align = .right; default: break }
            var c = Column(dataIndex: i, name: col.name, caption: env.caption(i), field: field,
                           format: data.formats[safe: i] ?? "", numeric: numeric, align: align)
            func rule(_ target: ConditionalFormat.Target) -> Rule? {
                guard let cf = evaluator.rule(target, field: field) else { return nil }
                if cf.appliesToKey == nil, !numeric { return nil }
                let d = evaluator.driverColumn(cf, column: i, data: data)
                return Rule(cf: cf, driver: d, range: CmpConditionalFormat.range(table.columns[d].values))
            }
            c.background = rule(.background); c.fontColor = rule(.fontColor)
            c.bars = rule(.dataBars); c.icons = rule(.icons)
            if let key = field?.key {
                if let cf = spec.conditionalFormats.first(where: { $0.target == .webURL && $0.appliesToKey == key }) {
                    c.urlDriver = evaluator.driverColumn(cf, column: i, data: data)
                }
                if let cf = spec.conditionalFormats.first(where: { $0.target == .image && $0.appliesToKey == key }) {
                    c.imageDriver = evaluator.driverColumn(cf, column: i, data: data)
                }
            }
            if imageCard[col.name]?.boolValue == true || imageCard[c.caption]?.boolValue == true { c.imageDriver = i }
            if let sp = sparkCard[col.name] ?? sparkCard[c.caption] {
                c.spark = true
                c.sparkColumns = sp["type"]?.stringValue == "column"
                c.align = .left
            }
            return c
        }
        applyLocalSort()
        bodyRows = table.rowCount
        headerRows = 1
        let hasTotals = data.totals.contains { !$0.isNull }
        footerRows = hasTotals && f.bool("total", "show", true) ? 1 : 0

        // Row height: images and wrapped text make rows taller (the totals row stays one line).
        style.footerRowHeight = style.rowHeight
        if columns.contains(where: { $0.imageDriver != nil }) {
            style.rowHeight = max(style.rowHeight, CGFloat(f.double("values", "imageHeight", 32)) + 8)
        }
        measureColumns()
        if wrap {
            let lh = CmpTblStyle.lineHeight(style.bodyFont)
            var lines: CGFloat = 1
            for (ci, c) in columns.enumerated() where !c.numeric && !c.spark && c.imageDriver == nil {
                let inner = max(20, baseWidths[ci] - style.padH * 2)
                for r in 0..<min(bodyRows, 200) {
                    let w = CmpFit.width(text(dataRow(r), c), font: style.bodyFont)
                    lines = max(lines, ceil(w * 1.12 / inner))
                }
            }
            let maxLines = CGFloat(max(1, f.double("values", "maxWrapLines", 3)))
            let pad = style.rowHeight - lh
            style.rowHeight = max(style.rowHeight, lh * min(lines, maxLines) + pad)
        }
    }

    private func measureColumns() {
        let widthCard = spec.format["columnWidths"] ?? [:]
        let sample = min(bodyRows, 300)
        baseWidths = []; fixed = []
        for c in columns {
            if let w = (widthCard[c.name] ?? widthCard[c.caption])?.doubleValue {
                baseWidths.append(max(28, CGFloat(w))); fixed.append(true); continue
            }
            var w = CmpFit.width(style.uppercaseHeader ? c.caption.uppercased() : c.caption, font: style.headerFont) + 16
            if c.spark { w = max(w, 96) }
            else if c.imageDriver != nil { w = max(w, (style.rowHeight - 8) * 1.6) }
            else {
                let ci = baseWidths.count
                for r in 0..<sample { w = max(w, CmpFit.width(bodyCell(r, ci).text, font: style.bodyFont)) }
                if footerRows > 0, let t = data.totals[safe: c.dataIndex], !t.isNull {
                    w = max(w, CmpFit.width(ValueFormatter.format(t, c.format), font: style.bodyBoldFont))
                }
                if c.icons != nil { w += 18 }
                if c.bars != nil { w = max(w, 84) }
            }
            let isLink = c.urlDriver != nil || (bodyRows > 0 && bodyCell(0, baseWidths.count).link != nil)
            let cap: CGFloat = isLink ? 160 : (wrap && !c.numeric ? 220 : 340)
            baseWidths.append(min(cap, max(44, ceil(w + style.padH * 2))))
            fixed.append(false)
        }
    }

    // MARK: Sorting

    private func sortEntry(_ c: Column) -> (index: Int, descending: Bool)? {
        guard let key = c.field?.key, let i = spec.sort.firstIndex(where: { $0.field.key == key }) else { return nil }
        return (i, spec.sort[i].descending)
    }

    /// Applies `spec.sort` locally when the data isn't already in that order (stable; no-op when the host sorted).
    private func applyLocalSort() {
        order = nil
        let keys: [(col: Int, desc: Bool)] = spec.sort.compactMap { s in
            columns.first { $0.field?.key == s.field.key }.map { ($0.dataIndex, s.descending) }
        }
        let n = data.table.rowCount
        guard !keys.isEmpty, n > 1 else { return }
        order = Self.sortedOrder(table: data.table, keys: keys)
    }

    /// Stable multi-key sort; returns nil when rows are already in order.
    static func sortedOrder(table: DataTable, keys: [(col: Int, desc: Bool)]) -> [Int]? {
        let n = table.rowCount
        // Numeric columns compare as plain doubles (nulls first); everything else through `Value`'s total order.
        let comparators: [(Int, Int) -> Int] = keys.map { key in
            let values = table.columns[key.col].values
            let sign = key.desc ? -1 : 1
            var nums = [Double](); nums.reserveCapacity(n)
            for v in values {
                if v.isNull { nums.append(-.infinity) }
                else if v.isNumber, let d = v.asDouble, !d.isNaN { nums.append(d) }
                else { return { a, b in values[a] == values[b] ? 0 : (values[a] < values[b] ? -sign : sign) } }
            }
            return { a, b in nums[a] < nums[b] ? -sign : (nums[a] > nums[b] ? sign : 0) }
        }
        func compare(_ a: Int, _ b: Int) -> Int {
            for c in comparators {
                let r = c(a, b)
                if r != 0 { return r }
            }
            return 0
        }
        var sorted = true
        for i in 1..<n where compare(i - 1, i) > 0 { sorted = false; break }
        if sorted { return nil }
        // Stable: ties keep their original order.
        return (0..<n).sorted { a, b in
            let c = compare(a, b)
            return c != 0 ? c < 0 : a < b
        }
    }

    override func headerClick(row: Int, col: Int, shift: Bool, onExpander: Bool) {
        guard let c = columns[safe: col], let field = c.field, !c.spark else { return }
        var sort = spec.sort
        if let i = sort.firstIndex(where: { $0.field.key == field.key }) {
            if shift || sort.count == 1 { sort[i].descending.toggle() }
            else { sort = [SortSpec(field: field, descending: sort[i].descending)] }
        } else {
            let entry = SortSpec(field: field, descending: c.numeric)
            if shift { sort.append(entry) } else { sort = [entry] }
        }
        spec.sort = sort
        applyLocalSort()
        context.onSpecChange(spec)
        view?.reload()
    }

    // MARK: Cells

    private func dataRow(_ row: Int) -> Int { order?[row] ?? row }

    private func text(_ r: Int, _ c: Column) -> String {
        CmpTblFormat.text(data.table[r, c.dataIndex], format: c.format, grouping: !(c.field?.isAggregate ?? false))
    }

    override func headerSpans(_ row: Int) -> [CmpTblSpan] {
        columns.enumerated().map { i, c in
            var cell = CmpTblCell(text: c.caption, align: c.align)
            if let s = sortEntry(c) {
                cell.sortGlyph = (s.descending ? "↓" : "↑") + (spec.sort.count > 1 ? "\(s.index + 1)" : "")
            }
            return CmpTblSpan(cols: i..<(i + 1), cell: cell)
        }
    }

    private func rowKey(_ r: Int) -> String {
        CmpSelection.point(data, row: r, columns: groupCols)?.key ?? "#\(r)"
    }
    override func isRowSelected(_ row: Int) -> Bool {
        !selectedKeys.isEmpty && selectedKeys.contains(rowKey(dataRow(row)))
    }

    override func bodyCell(_ row: Int, _ col: Int) -> CmpTblCell {
        guard let c = columns[safe: col], row < bodyRows else { return CmpTblCell() }
        let r = dataRow(row)
        let v = data.table[r, c.dataIndex]
        var cell = CmpTblCell(text: text(r, c), align: c.align)
        cell.wrap = wrap && !c.numeric
        cell.dimmed = !selectedKeys.isEmpty && !selectedKeys.contains(rowKey(r))
        if c.spark {
            cell.spark = CmpTblCellRenderer.parseSpark(v)
            cell.sparkColumns = c.sparkColumns
            if cell.spark != nil { return cell }
        }
        if let d = c.imageDriver {
            let ref = data.table[r, d].asString
            if !ref.isEmpty { cell.imageRef = ref; return cell }
        }
        if let d = c.urlDriver, let url = URL(string: data.table[r, d].asString), url.scheme != nil { cell.link = url }
        else if detectURLs, case .string(let s) = v, s.hasPrefix("http://") || s.hasPrefix("https://"), let url = URL(string: s) {
            cell.link = url
            if cell.text == s { cell.text = url.host.map { $0 + (url.path.count > 1 ? url.path : "") } ?? s }
        }
        if let b = c.background, let hex = evaluator.colorHex(b.cf, value: data.table[r, b.driver], range: b.range) {
            cell.background = CmpColor.ns(hex)
            cell.textColor = CmpColor.ns(CmpColor.readableText(on: hex))
        }
        if let fc = c.fontColor, let hex = evaluator.colorHex(fc.cf, value: data.table[r, fc.driver], range: fc.range) {
            cell.textColor = CmpColor.ns(hex)
        }
        if let b = c.bars {
            cell.bar = evaluator.dataBar(b.cf, value: data.table[r, b.driver], range: b.range)
            cell.barOnly = barOnly
        }
        if let ic = c.icons {
            cell.icon = evaluator.icon(ic.cf, value: data.table[r, ic.driver], range: ic.range)
            cell.iconOnly = iconOnly; cell.iconTrailing = iconTrailing
        }
        return cell
    }

    override func footerCell(_ row: Int, _ col: Int) -> CmpTblCell {
        guard let c = columns[safe: col] else { return CmpTblCell() }
        var cell = CmpTblCell(align: c.align)
        cell.bold = totalBold
        let total = data.totals[safe: c.dataIndex] ?? .null
        if !total.isNull, !c.spark { cell.text = ValueFormatter.format(total, c.format) }
        else if col == 0 { cell.text = totalLabel; cell.align = .left }
        return cell
    }

    // MARK: Selection

    private func point(_ row: Int) -> DataPointSelection? {
        CmpSelection.point(data, row: dataRow(row), columns: groupCols)
    }
    private func notify(_ points: [DataPointSelection], additive: Bool) {
        context.onSelect(points, additive)
        view?.redrawAll()
    }

    override func bodyClick(row: Int, col: Int, command: Bool, shift: Bool, onExpander: Bool) {
        if shift { selectRow(row, additive: false, extend: true) }
        else if command { selectRow(row, additive: true, extend: false) }
        else {
            let key = rowKey(dataRow(row))
            if selectedKeys == [key] { clearSelection() } else { selectRow(row, additive: false, extend: false) }
        }
    }

    override func selectRow(_ row: Int, additive: Bool, extend: Bool) {
        guard row >= 0, row < bodyRows else { return }
        if extend, let a = anchorRow {
            let range = min(a, row)...max(a, row)
            selectedKeys = Set(range.map { rowKey(dataRow($0)) })
            notify(range.compactMap(point), additive: false)
            return
        }
        anchorRow = row
        let key = rowKey(dataRow(row))
        if additive {
            if selectedKeys.contains(key) { selectedKeys.remove(key) } else { selectedKeys.insert(key) }
            notify(point(row).map { [$0] } ?? [], additive: true)
        } else {
            selectedKeys = [key]
            notify(point(row).map { [$0] } ?? [], additive: false)
        }
    }

    override func clearSelection() {
        guard !selectedKeys.isEmpty else { return }
        selectedKeys = []
        notify([], additive: false)
    }

    override func selectAll() {
        selectedKeys = Set((0..<bodyRows).map { rowKey(dataRow($0)) })
        notify((0..<bodyRows).compactMap(point), additive: false)
    }

    private func selectedRows() -> [Int] {
        selectedKeys.isEmpty ? [] : (0..<bodyRows).filter { selectedKeys.contains(rowKey(dataRow($0))) }
    }

    // MARK: Copy, menu, resize

    /// Selected rows (or every row when nothing is selected) as TSV with a header line.
    func tsv(rows: [Int]? = nil) -> String {
        let rows = rows ?? { let s = selectedRows(); return s.isEmpty ? Array(0..<bodyRows) : s }()
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = [columns.map { clean($0.caption) }.joined(separator: "\t")]
        lines.reserveCapacity(rows.count + 1)
        for row in rows {
            let r = dataRow(row)
            lines.append(columns.map { c in
                let v = data.table[r, c.dataIndex]
                return clean(c.spark ? v.asString : text(r, c))
            }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    override func copySelection() { CmpPasteboard.copy(tsv()) }

    override func menu(row: Int?, col: Int) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let row, let c = columns[safe: col] {
            let r = dataRow(row)
            menu.addItem(CmpTblMenuItem("Copy value") { [weak self] in
                guard let self else { return }
                CmpPasteboard.copy(self.text(r, c))
            })
            menu.addItem(CmpTblMenuItem(selectedKeys.isEmpty ? "Copy table" : "Copy selection") { [weak self] in self?.copySelection() })
            menu.addItem(CmpTblMenuItem("Copy row") { [weak self] in
                guard let self else { return }
                CmpPasteboard.copy(self.tsv(rows: [row]))
            })
            menu.addItem(.separator())
            let p = point(row)
            menu.addItem(CmpTblMenuItem("Drill through", enabled: p != nil) { [weak self] in
                if let p { self?.context.onDrill(.drillthrough(p, pageID: nil)) }
            })
            menu.addItem(CmpTblMenuItem("Include", enabled: p != nil) { [weak self] in self?.addFilter(row: row, exclude: false) })
            menu.addItem(CmpTblMenuItem("Exclude", enabled: p != nil) { [weak self] in self?.addFilter(row: row, exclude: true) })
        } else {
            menu.addItem(CmpTblMenuItem(selectedKeys.isEmpty ? "Copy table" : "Copy selection") { [weak self] in self?.copySelection() })
            if let c = columns[safe: col], row == nil, spec.format["columnWidths"]?[c.name] != nil {
                menu.addItem(CmpTblMenuItem("Auto-size column") { [weak self] in self?.columnResized(col: col, width: nil) })
            }
            if !spec.sort.isEmpty {
                menu.addItem(CmpTblMenuItem("Clear sort") { [weak self] in
                    guard let self else { return }
                    self.spec.sort = []; self.applyLocalSort(); self.context.onSpecChange(self.spec); self.view?.reload()
                })
            }
        }
        return menu
    }

    /// Include/Exclude: adds visual-level basic filters for the clicked row (or the selected rows).
    private func addFilter(row: Int, exclude: Bool) {
        let sel = selectedRows()
        let rows = sel.contains(row) ? sel : [row]
        let points = rows.compactMap(point)
        guard let first = points.first else { return }
        for (i, field) in first.fields.enumerated() {
            var values: [Value] = []
            for p in points { if let v = p.values[safe: i], !values.contains(v) { values.append(v) } }
            var filter = FilterSpec(field: field, kind: .basic)
            filter.values = values
            filter.isInverted = exclude
            filter.displayName = exclude ? "Excluded" : "Included"
            spec.filters.append(filter)
        }
        selectedKeys = []
        context.onSpecChange(spec)
    }

    override func columnResized(col: Int, width: CGFloat?) {
        guard let c = columns[safe: col] else { return }
        spec.setFmt("columnWidths", c.name, width.map { .number(Double($0.rounded())) })
        if width == nil {
            measureColumns()
        }
        context.onSpecChange(spec)
        view?.reload()
    }

    override func rowDescription(_ row: Int) -> String {
        let r = dataRow(row)
        return columns.map { "\($0.caption): \(text(r, $0))" }.joined(separator: ", ")
    }
}
