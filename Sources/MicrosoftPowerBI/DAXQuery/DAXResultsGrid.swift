import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// The results grid: an `NSTableView` over a `DAXResultModel`, so half a million rows scroll smoothly.
/// Header click sorts, the funnel in each header filters, dragging selects a block of cells.
struct DAXResultsGrid: NSViewRepresentable {
    @ObservedObject var model: DAXResultModel
    var onCopyAll: () -> Void
    var onExport: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let table = DAXGridTableView()
        table.grid = context.coordinator
        table.style = .plain
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        table.setAccessibilityLabel("Query results")
        let header = DAXGridHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
        header.grid = context.coordinator
        table.headerView = header
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.rebuild()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let previous = c.parent.model
        c.parent = self
        if previous !== model { c.rebuild() } else if c.shownRevision != model.revision { c.reload() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
        var parent: DAXResultsGrid
        weak var table: DAXGridTableView?
        var shownRevision = -1
        private var popover: NSPopover?
        private static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

        init(_ parent: DAXResultsGrid) { self.parent = parent }
        var model: DAXResultModel { parent.model }

        /// Recreates the columns for a new result.
        func rebuild() {
            guard let table else { return }
            popover?.close()
            for c in table.tableColumns { table.removeTableColumn(c) }
            for (i, column) in model.table.columns.enumerated() {
                let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                let cell = DAXGridHeaderCell(textCell: column.name)
                cell.glyph = DAXResultFormat.glyph(for: column.type)
                cell.typeName = column.type.displayName
                tc.headerCell = cell
                tc.minWidth = 44
                tc.maxWidth = 2000
                tc.width = min(280, max(64, fittedWidth(column: i, sample: 200)))
                tc.headerToolTip = "\(column.name) · \(column.type.displayName)"
                table.addTableColumn(tc)
            }
            reload()
            table.scroll(.zero)
        }

        func reload() {
            guard let table else { return }
            shownRevision = model.revision
            for (i, tc) in table.tableColumns.enumerated() {
                guard let cell = tc.headerCell as? DAXGridHeaderCell else { continue }
                cell.sortAscending = model.sort?.column == i ? model.sort?.ascending : nil
                cell.filtered = model.filter(i).isActive
            }
            table.reloadData()
            table.headerView?.needsDisplay = true
        }

        func fittedWidth(column: Int, sample: Int) -> CGFloat {
            let name = model.table.columns[column].name as NSString
            var width = name.size(withAttributes: [.font: Self.headerFont]).width + 68
            let rows = min(sample, model.rowCount)
            for r in 0..<rows {
                let w = (model.text(row: r, column: column) as NSString).size(withAttributes: [.font: Self.cellFont]).width + 18
                if w > width { width = w }
            }
            return ceil(width)
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn),
                  column < model.columnCount, row < model.rowCount else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { cell = reused } else {
                cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.font = Self.cellFont
                field.lineBreakMode = .byTruncatingTail
                field.cell?.usesSingleLineMode = true
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let value = model.value(row: row, column: column)
            cell.textField?.stringValue = DAXResultFormat.text(value, model.formats[column])
            cell.textField?.alignment = model.rightAligned[column] ? .right : .left
            cell.textField?.textColor = .labelColor
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("row")
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? DAXGridRowView { return reused }
            let view = DAXGridRowView()
            view.identifier = id
            return view
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let column = tableView.tableColumns.firstIndex(of: tableColumn) else { return }
            model.cycleSort(column: column)
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            min(900, max(48, fittedWidth(column: column, sample: 2000)))
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        // MARK: Filter popover

        func showFilter(column: Int) {
            guard let table, let header = table.headerView, column < model.columnCount else { return }
            popover?.close()
            let p = NSPopover()
            p.behavior = .transient
            p.delegate = self
            p.contentViewController = NSHostingController(rootView: DAXColumnFilterView(model: model, column: column))
            let rect = header.headerRect(ofColumn: column)
            p.show(relativeTo: NSRect(x: rect.maxX - 22, y: rect.minY, width: 20, height: rect.height), of: header, preferredEdge: .maxY)
            popover = p
        }
        func popoverDidClose(_ notification: Notification) { popover = nil }

        // MARK: Copy

        func copySelection(headers: Bool) {
            guard let sel = model.selection, model.rowCount > 0 else { return }
            let rows = max(0, sel.rows.lowerBound)...min(model.rowCount - 1, sel.rows.upperBound)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(model.tsv(rows: rows, columns: sel.columns, headers: headers), forType: .string)
        }

        func headerMenu(column: Int) -> NSMenu {
            let menu = NSMenu()
            func item(_ title: String, _ action: Selector, on: Bool = false) {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.target = self; i.tag = column; i.state = on ? .on : .off
                menu.addItem(i)
            }
            let sort = model.sort?.column == column ? model.sort?.ascending : nil
            item("Sort ascending", #selector(sortAscending(_:)), on: sort == true)
            item("Sort descending", #selector(sortDescending(_:)), on: sort == false)
            if sort != nil { item("Clear sort", #selector(clearSort(_:))) }
            menu.addItem(.separator())
            item("Filter…", #selector(openFilter(_:)))
            if model.filter(column).isActive { item("Clear filter", #selector(clearFilter(_:))) }
            menu.addItem(.separator())
            item("Size column to fit", #selector(fitColumn(_:)))
            return menu
        }
        @objc private func sortAscending(_ s: NSMenuItem) { model.setSort(column: s.tag, ascending: true) }
        @objc private func sortDescending(_ s: NSMenuItem) { model.setSort(column: s.tag, ascending: false) }
        @objc private func clearSort(_ s: NSMenuItem) { model.setSort(column: s.tag, ascending: nil) }
        @objc private func openFilter(_ s: NSMenuItem) { showFilter(column: s.tag) }
        @objc private func clearFilter(_ s: NSMenuItem) { model.setFilter(DAXColumnFilter(), column: s.tag) }
        @objc private func fitColumn(_ s: NSMenuItem) {
            guard let table, s.tag < table.tableColumns.count else { return }
            table.tableColumns[s.tag].width = min(900, max(48, fittedWidth(column: s.tag, sample: 2000)))
        }
    }
}

// MARK: - Table view with block selection

final class DAXGridTableView: NSTableView {
    weak var grid: DAXResultsGrid.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    private var cellSelection: DAXCellSelection? {
        get { grid?.model.selection }
        set { grid?.model.selection = newValue; refreshSelection() }
    }
    var currentSelection: DAXCellSelection? { grid?.model.selection }

    private func refreshSelection() {
        enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    private func cell(at event: NSEvent) -> (row: Int, column: Int)? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p), c = column(at: p)
        return r >= 0 && c >= 0 ? (r, c) : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let start = cell(at: event) else { cellSelection = nil; return }
        if event.modifierFlags.contains(.shift), var sel = cellSelection {
            sel.focusRow = start.row; sel.focusColumn = start.column
            cellSelection = sel
        } else {
            cellSelection = DAXCellSelection(anchorRow: start.row, anchorColumn: start.column, focusRow: start.row, focusColumn: start.column)
        }
        // Track the drag to extend the block.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            autoscroll(with: next)
            let p = convert(next.locationInWindow, from: nil)
            var r = row(at: p), c = column(at: p)
            if r < 0 { r = p.y < 0 ? 0 : numberOfRows - 1 }
            if c < 0 { c = p.x < 0 ? 0 : numberOfColumns - 1 }
            guard r >= 0, c >= 0, var sel = cellSelection, sel.focusRow != r || sel.focusColumn != c else { continue }
            sel.focusRow = r; sel.focusColumn = c
            cellSelection = sel
        }
    }

    override func keyDown(with event: NSEvent) {
        let rows = numberOfRows, cols = numberOfColumns
        guard rows > 0, cols > 0 else { super.keyDown(with: event); return }
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        if command, event.charactersIgnoringModifiers?.lowercased() == "c" { grid?.copySelection(headers: shift); return }
        if command, event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(nil); return }
        var sel = cellSelection ?? DAXCellSelection(anchorRow: 0, anchorColumn: 0, focusRow: 0, focusColumn: 0)
        let page = max(1, Int((enclosingScrollView?.contentView.bounds.height ?? 220) / (rowHeight + intercellSpacing.height)) - 1)
        var dr = 0, dc = 0
        switch event.specialKey {
        case .upArrow: dr = command ? -rows : -1
        case .downArrow: dr = command ? rows : 1
        case .leftArrow: dc = command ? -cols : -1
        case .rightArrow: dc = command ? cols : 1
        case .pageUp: dr = -page
        case .pageDown: dr = page
        case .home: dr = -rows
        case .end: dr = rows
        default: super.keyDown(with: event); return
        }
        if cellSelection != nil {
            sel.focusRow = min(rows - 1, max(0, sel.focusRow + dr))
            sel.focusColumn = min(cols - 1, max(0, sel.focusColumn + dc))
        }
        if !shift { sel.anchorRow = sel.focusRow; sel.anchorColumn = sel.focusColumn }
        cellSelection = sel
        scrollRowToVisible(sel.focusRow)
        scrollColumnToVisible(sel.focusColumn)
    }

    override func selectAll(_ sender: Any?) {
        guard numberOfRows > 0, numberOfColumns > 0 else { return }
        cellSelection = DAXCellSelection(anchorRow: 0, anchorColumn: 0, focusRow: numberOfRows - 1, focusColumn: numberOfColumns - 1)
    }

    @objc func copy(_ sender: Any?) { grid?.copySelection(headers: false) }
    @objc private func copyWithHeaders(_ sender: Any?) { grid?.copySelection(headers: true) }
    @objc private func copyAll(_ sender: Any?) { grid?.parent.onCopyAll() }
    @objc private func export(_ sender: Any?) { grid?.parent.onExport() }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let hit = cell(at: event) {
            let inside = cellSelection.map { $0.rows.contains(hit.row) && $0.columns.contains(hit.column) } ?? false
            if !inside { cellSelection = DAXCellSelection(anchorRow: hit.row, anchorColumn: hit.column, focusRow: hit.row, focusColumn: hit.column) }
        }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        menu.autoenablesItems = false
        let has = cellSelection != nil
        add("Copy", #selector(copy(_:)), enabled: has)
        add("Copy with headers", #selector(copyWithHeaders(_:)), enabled: has)
        add("Copy all", #selector(copyAll(_:)))
        menu.addItem(.separator())
        add("Export results…", #selector(export(_:)))
        for i in menu.items where i.action == nil && !i.isSeparatorItem { i.isEnabled = false }
        return menu
    }

    override func becomeFirstResponder() -> Bool { refreshSelection(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { refreshSelection(); return super.resignFirstResponder() }
}

/// Draws the selected block for its row; everything else stays transparent.
final class DAXGridRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let table = superview as? DAXGridTableView, let sel = table.currentSelection else { return }
        let row = table.row(for: self)
        guard row >= 0, sel.rows.contains(row), sel.columns.upperBound < table.numberOfColumns else { return }
        let first = table.rect(ofColumn: sel.columns.lowerBound), last = table.rect(ofColumn: sel.columns.upperBound)
        let focused = table.window?.firstResponder === table
        NSColor.controlAccentColor.withAlphaComponent(focused ? 0.2 : 0.1).setFill()
        NSRect(x: first.minX, y: 0, width: last.maxX - first.minX, height: bounds.height).fill()
    }
}

// MARK: - Header

final class DAXGridHeaderView: NSTableHeaderView {
    weak var grid: DAXResultsGrid.Coordinator?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let c = column(at: p)
        if c >= 0 {
            let rect = headerRect(ofColumn: c)
            // The funnel sits at the trailing edge, just inside the resize zone.
            if p.x >= rect.maxX - 24, p.x <= rect.maxX - 5 { grid?.showFilter(column: c); return }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let c = column(at: convert(event.locationInWindow, from: nil))
        return c >= 0 ? grid?.headerMenu(column: c) : nil
    }
}

/// A quiet header: type glyph, name, sort direction and a filter funnel. No bezel.
final class DAXGridHeaderCell: NSTableHeaderCell {
    var glyph = "textformat"
    var typeName = ""
    var sortAscending: Bool?
    var filtered = false

    private func symbol(_ name: String, size: CGFloat, color: NSColor, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
    }
    private func draw(_ image: NSImage, centeredAt point: NSPoint) {
        let s = image.size
        image.draw(in: NSRect(x: point.x - s.width / 2, y: point.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: max(0, cellFrame.height - 12)).fill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        if flag { NSColor.labelColor.withAlphaComponent(0.05).setFill(); cellFrame.fill() }
        draw(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame f: NSRect, in controlView: NSView) {
        var left = f.minX + 8
        var right = f.maxX - 6
        if let funnel = symbol("line.3.horizontal.decrease", size: 9, color: filtered ? .controlAccentColor : .tertiaryLabelColor, description: "Filter") {
            draw(funnel, centeredAt: NSPoint(x: right - 8, y: f.midY)); right -= 18
        }
        if let asc = sortAscending, let arrow = symbol(asc ? "chevron.up" : "chevron.down", size: 8, color: .secondaryLabelColor, description: asc ? "Sorted ascending" : "Sorted descending") {
            draw(arrow, centeredAt: NSPoint(x: right - 6, y: f.midY)); right -= 14
        }
        if f.width > 70, let icon = symbol(glyph, size: 9, color: .tertiaryLabelColor, description: typeName) {
            draw(icon, centeredAt: NSPoint(x: left + 6, y: f.midY)); left += 17
        }
        guard right > left else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let title = stringValue as NSString
        let h = title.size(withAttributes: attrs).height
        title.draw(in: NSRect(x: left, y: f.midY - h / 2, width: right - left, height: h), withAttributes: attrs)
    }
}

// MARK: - Filter popover

/// Filter for one column: a simple condition and a searchable list of distinct values.
struct DAXColumnFilterView: View {
    @ObservedObject var model: DAXResultModel
    let column: Int
    @State private var query = ""
    @State private var distinct: [(value: Value, count: Int)] = []
    @State private var loaded = false
    private static let listLimit = 500

    private var filter: DAXColumnFilter { model.filter(column) }
    private func update(_ change: (inout DAXColumnFilter) -> Void) {
        var f = filter
        change(&f)
        model.setFilter(f, column: column)
    }
    private func label(_ v: Value) -> String {
        v.isNull ? "(Blank)" : DAXResultFormat.text(v, model.formats[column])
    }
    private var matches: [(value: Value, count: Int)] {
        query.isEmpty ? distinct : distinct.filter { label($0.value).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let shown = matches
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(model.table.columns[column].name).font(Design.Typeface.bodyStrong).lineLimit(1)
            Picker("Condition", selection: Binding(get: { filter.op }, set: { op in update { $0.op = op } })) {
                ForEach(DAXColumnFilter.Op.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            if filter.op.needsOperand {
                TextField("Value", text: Binding(get: { filter.operand }, set: { text in update { $0.operand = text } }))
                    .textFieldStyle(.roundedBorder)
            }
            Hairline().padding(.vertical, Design.Space.xxs)
            TextField("Search values", text: $query).textFieldStyle(.roundedBorder)
            HStack(spacing: Design.Space.m) {
                Button("Select all") { update { f in for m in shown { f.excluded.remove(m.value) } } }
                Button("Clear") { update { f in for m in shown { f.excluded.insert(m.value) } } }
                Spacer()
                Text(loaded ? "\(distinct.count.formatted()) values" : "Loading…")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.link)
            .font(Design.Typeface.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.xxs) {
                    ForEach(Array(shown.prefix(Self.listLimit).enumerated()), id: \.offset) { _, item in
                        Toggle(isOn: Binding(get: { !filter.excluded.contains(item.value) },
                                             set: { on in update { f in if on { f.excluded.remove(item.value) } else { f.excluded.insert(item.value) } } })) {
                            HStack {
                                Text(label(item.value)).lineLimit(1).foregroundStyle(item.value.isNull ? .secondary : .primary)
                                Spacer()
                                Text(item.count.formatted()).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(Design.Typeface.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if shown.count > Self.listLimit {
                        Text("Showing the first \(Self.listLimit). Search to narrow the list.")
                            .font(Design.Typeface.caption).foregroundStyle(.tertiary).padding(.top, Design.Space.xs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            HStack {
                Spacer()
                Button("Clear filter") { model.setFilter(DAXColumnFilter(), column: column) }
                    .disabled(!filter.isActive)
            }
        }
        .controlSize(.small)
        .padding(Design.Space.m)
        .frame(width: 264)
        .task {
            let values = model.table.columns[column].values
            let result = await Task.detached(priority: .userInitiated) { () -> [(value: Value, count: Int)] in
                var counts: [Value: Int] = [:]
                for v in values { counts[v, default: 0] += 1 }
                return counts.map { (value: $0.key, count: $0.value) }.sorted { $0.value < $1.value }
            }.value
            distinct = result
            loaded = true
        }
    }
}
