import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// One column as the grid shows it.
struct GridColumn: Equatable {
    var name: String
    var type: DataType
    var format: String
    var isCalculated = false
    var isHidden = false
    var isKey = false
    /// Index into the data table's columns; nil while a calculated column has no data yet.
    var dataIndex: Int?
    var isFiltered = false
    var glyph: String
}

/// A rectangular cell selection, in visible row/column coordinates.
struct GridCellRange: Equatable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>
    var cellCount: Int { rows.count * columns.count }
}

/// A virtualised data grid on `NSTableView`. Rows are read lazily from the columnar table, so it
/// stays smooth with hundreds of thousands of rows; nothing is formatted until it scrolls into view.
struct DataGrid: NSViewRepresentable {
    var table: DataTable?
    /// Changes whenever `table` holds different data.
    var dataToken: Int
    var columns: [GridColumn]
    /// Visible rows in order (sorted/filtered); nil shows the table as stored.
    var rowIndex: [Int]?
    var indexToken: Int
    var selectedColumn: String?
    var sortColumn: String?
    var sortAscending = true
    var onSelectColumn: (String?) -> Void
    var headerMenu: (String) -> [ModelMenuEntry]
    /// Builds the filter popover content for a column; the closure argument dismisses it.
    var filterEditor: (String, @escaping () -> Void) -> AnyView
    /// Bumped (with a column name) to open that column's filter popover.
    var filterRequest: GridFilterRequest?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = GridTableView()
        tv.coordinator = context.coordinator
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.rowHeight = 22
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.usesAlternatingRowBackgroundColors = false
        tv.backgroundColor = .clear
        tv.gridStyleMask = [.solidHorizontalGridLineMask]
        tv.gridColor = NSColor.labelColor.withAlphaComponent(0.06)
        tv.selectionHighlightStyle = .none
        tv.allowsColumnReordering = false
        tv.allowsColumnResizing = true
        tv.allowsColumnSelection = false
        tv.allowsMultipleSelection = false
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.usesAutomaticRowHeights = false
        tv.style = .plain
        tv.setAccessibilityLabel("Table data")
        let header = NSTableHeaderView()
        header.frame.size.height = 26
        let menu = NSMenu()
        menu.delegate = context.coordinator
        header.menu = menu
        tv.headerView = header
        scroll.documentView = tv
        context.coordinator.tableView = tv
        context.coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGrid
        weak var tableView: GridTableView?
        private var dataToken = Int.min
        private var indexToken = Int.min
        private var columns: [GridColumn] = []
        private var lastFilterRequest: UUID?
        private var popover: NSPopover?
        private static let cellID = NSUserInterfaceItemIdentifier("cell")

        init(_ parent: DataGrid) { self.parent = parent }

        var rowCount: Int { parent.rowIndex?.count ?? parent.table?.rowCount ?? 0 }

        func apply(_ new: DataGrid, force: Bool) {
            let old = parent
            parent = new
            guard let tv = tableView else { return }
            let namesChanged = columns.map(\.name) != new.columns.map(\.name)
            let metaChanged = columns != new.columns
            let dataChanged = dataToken != new.dataToken || indexToken != new.indexToken
            if force || namesChanged { rebuildColumns(tv) }
            else if metaChanged { columns = new.columns; refreshHeaders(tv) }
            if force || namesChanged || dataChanged {
                dataToken = new.dataToken; indexToken = new.indexToken
                tv.clampSelection(rows: rowCount, columns: new.columns.count)
                tv.reloadData()
            } else if metaChanged {
                tv.reloadData(forRowIndexes: IndexSet(tv.rows(in: tv.visibleRect).toRange() ?? 0..<0), columnIndexes: IndexSet(0..<tv.numberOfColumns))
            }
            if force || old.sortColumn != new.sortColumn || old.sortAscending != new.sortAscending || namesChanged {
                for c in tv.tableColumns {
                    let on = c.title == new.sortColumn
                    tv.setIndicatorImage(on ? NSImage(named: new.sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil, in: c)
                }
            }
            let selectedIndex = new.selectedColumn.flatMap { n in new.columns.firstIndex { $0.name == n } }
            if tv.highlightedColumn != selectedIndex {
                tv.highlightedColumn = selectedIndex
                tv.refreshRowBackgrounds()
                tv.headerView?.needsDisplay = true
            }
            if let request = new.filterRequest, request.id != lastFilterRequest {
                lastFilterRequest = request.id
                DispatchQueue.main.async { [weak self] in self?.showFilter(for: request.column) }
            }
        }

        private func rebuildColumns(_ tv: GridTableView) {
            columns = parent.columns
            for c in tv.tableColumns.reversed() { tv.removeTableColumn(c) }
            for (i, gc) in columns.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                col.title = gc.name
                col.minWidth = 48
                col.maxWidth = 1200
                col.width = estimatedWidth(gc)
                let cell = GridHeaderCell(textCell: gc.name)
                cell.column = gc
                col.headerCell = cell
                tv.addTableColumn(col)
            }
        }

        private func refreshHeaders(_ tv: GridTableView) {
            for (i, c) in tv.tableColumns.enumerated() where i < columns.count {
                (c.headerCell as? GridHeaderCell)?.column = columns[i]
            }
            tv.headerView?.needsDisplay = true
        }

        /// Width from the header and a small sample of formatted values.
        private func estimatedWidth(_ gc: GridColumn) -> CGFloat {
            let font = NSFont.systemFont(ofSize: 12)
            var widest = (gc.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 44
            if let t = parent.table, let di = gc.dataIndex {
                let values = t.columns[di].values
                for r in 0..<min(40, values.count) {
                    let s = ValueFormatter.format(values[parent.rowIndex?[safe: r] ?? r], gc.format) as NSString
                    widest = max(widest, s.size(withAttributes: [.font: font]).width + 24)
                }
            }
            return min(280, max(72, widest.rounded(.up)))
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func value(row: Int, column: Int) -> Value {
            guard let t = parent.table, column < columns.count, let di = columns[column].dataIndex, di < t.columns.count else { return .null }
            let r = parent.rowIndex?[safe: row] ?? row
            let values = t.columns[di].values
            return r < values.count ? values[r] : .null
        }
        func text(row: Int, column: Int) -> String {
            ValueFormatter.format(value(row: row, column: column), columns[column].format)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let c = Int(tableColumn.identifier.rawValue), c < columns.count else { return nil }
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? GridCellView {
                field = reused.label
                configure(reused, column: c, row: row)
                return reused
            }
            let cell = GridCellView()
            cell.identifier = Self.cellID
            field = cell.label
            _ = field
            configure(cell, column: c, row: row)
            return cell
        }

        private func configure(_ cell: GridCellView, column c: Int, row: Int) {
            let gc = columns[c]
            let v = value(row: row, column: c)
            cell.label.stringValue = ValueFormatter.format(v, gc.format)
            let numeric = gc.type.isNumeric || (gc.type == .any && v.isNumber)
            cell.label.alignment = numeric ? .right : .left
            cell.label.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            cell.label.textColor = gc.isHidden ? .secondaryLabelColor : .labelColor
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("row")
            if let v = tableView.makeView(withIdentifier: id, owner: nil) as? GridRowView { return v }
            let v = GridRowView()
            v.identifier = id
            return v
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
            guard let c = Int(tableColumn.identifier.rawValue), c < columns.count else { return }
            let name = columns[c].name
            parent.onSelectColumn(parent.selectedColumn == name ? nil : name)
        }

        // MARK: Header menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = tableView, let header = tv.headerView, let event = NSApp.currentEvent else { return }
            let p = header.convert(event.locationInWindow, from: nil)
            let c = header.column(at: p)
            guard c >= 0, c < columns.count else { return }
            let name = columns[c].name
            if parent.selectedColumn != name { parent.onSelectColumn(name) }
            ModelMenuEntry.build(parent.headerMenu(name), into: menu)
        }

        func showFilter(for column: String) {
            guard let tv = tableView, let header = tv.headerView, let c = columns.firstIndex(where: { $0.name == column }) else { return }
            popover?.close()
            let p = NSPopover()
            p.behavior = .transient
            let host = NSHostingController(rootView: parent.filterEditor(column) { [weak p] in p?.close() })
            p.contentViewController = host
            popover = p
            let rect = header.headerRect(ofColumn: c).intersection(header.visibleRect)
            p.show(relativeTo: rect.isEmpty ? header.bounds : rect, of: header, preferredEdge: .maxY)
        }

        // MARK: Copy

        /// Tab-separated text for a cell range, with a header row when it spans more than one cell.
        func tsv(_ range: GridCellRange, headers: Bool) -> String {
            var out = ""
            let cols = Array(range.columns).filter { $0 < columns.count }
            if headers { out += cols.map { columns[$0].name }.joined(separator: "\t") + "\n" }
            for r in range.rows where r < rowCount {
                out += cols.map { Self.clean(text(row: r, column: $0)) }.joined(separator: "\t")
                out += "\n"
            }
            if out.hasSuffix("\n") { out.removeLast() }
            return out
        }
        private static func clean(_ s: String) -> String {
            s.contains(where: { $0 == "\t" || $0 == "\n" }) ? s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") : s
        }
        static func write(_ s: String) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
        }

        func copySelection() {
            guard let tv = tableView, let sel = tv.cellSelection else { return }
            Self.write(tsv(sel, headers: sel.cellCount > 1))
        }
        func copyValue() {
            guard let tv = tableView, let sel = tv.cellSelection else { return }
            Self.write(text(row: sel.rows.lowerBound, column: sel.columns.lowerBound))
        }
        func copyColumn(_ name: String) {
            guard let c = columns.firstIndex(where: { $0.name == name }), rowCount > 0 else { return }
            copyLarge(GridCellRange(rows: 0...(rowCount - 1), columns: c...c))
        }
        func copyTable() {
            guard rowCount > 0, !columns.isEmpty else { return }
            copyLarge(GridCellRange(rows: 0...(rowCount - 1), columns: 0...(columns.count - 1)))
        }
        /// Whole-table copies are built off the main thread from a snapshot.
        private func copyLarge(_ range: GridCellRange) {
            guard let table = parent.table else { return }
            let cols = columns, index = parent.rowIndex
            DispatchQueue.global(qos: .userInitiated).async {
                var out = range.columns.map { cols[$0].name }.joined(separator: "\t")
                out.reserveCapacity(range.cellCount * 8)
                for r in range.rows {
                    let dr = index?[r] ?? r
                    out += "\n"
                    var first = true
                    for c in range.columns {
                        if !first { out += "\t" }
                        first = false
                        if let di = cols[c].dataIndex, di < table.columns.count, dr < table.columns[di].values.count {
                            out += Self.clean(ValueFormatter.format(table.columns[di].values[dr], cols[c].format))
                        }
                    }
                }
                DispatchQueue.main.async { Self.write(out) }
            }
        }

        func cellMenu() -> NSMenu {
            let menu = NSMenu()
            let hasSelection = tableView?.cellSelection != nil
            ModelMenuEntry.build([
                .item(title: "Copy value", enabled: hasSelection) { [weak self] in self?.copyValue() },
                .item(title: "Copy selection", enabled: hasSelection) { [weak self] in self?.copySelection() },
                .item(title: "Copy table") { [weak self] in self?.copyTable() },
            ], into: menu)
            return menu
        }
    }
}

struct GridFilterRequest: Equatable {
    var id = UUID()
    var column: String
}

private extension NSRange {
    func toRange() -> Range<Int>? { location == NSNotFound ? nil : location..<(location + length) }
}

// MARK: - AppKit views

/// A cell: one label, inset from the column edges.
final class GridCellView: NSView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Draws the selected-column tint and the cell-range selection behind a row's cells.
final class GridRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard let tv = superview as? GridTableView else { return }
        if let c = tv.highlightedColumn, c < tv.numberOfColumns {
            let r = tv.rect(ofColumn: c)
            NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
            NSRect(x: r.minX, y: 0, width: r.width, height: bounds.height).fill()
        }
        guard let sel = tv.cellSelection else { return }
        let row = tv.row(for: self)
        guard sel.rows.contains(row), sel.columns.upperBound < tv.numberOfColumns else { return }
        let a = tv.rect(ofColumn: sel.columns.lowerBound), b = tv.rect(ofColumn: sel.columns.upperBound)
        let rect = NSRect(x: a.minX, y: 0, width: b.maxX - a.minX, height: bounds.height)
        NSColor.controlAccentColor.withAlphaComponent(tv.window?.firstResponder === tv ? 0.18 : 0.10).setFill()
        rect.fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

/// Header cell: type glyph + name, tinted for calculated columns, with a filter mark.
final class GridHeaderCell: NSTableHeaderCell {
    var column: GridColumn?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let selected = ((controlView as? NSTableHeaderView)?.tableView as? GridTableView).flatMap { tv in
            tv.highlightedColumn.map { $0 < tv.tableColumns.count && tv.tableColumns[$0].headerCell === self }
        } ?? false
        NSColor.windowBackgroundColor.setFill()
        cellFrame.fill()
        if let c = column, c.isCalculated {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            cellFrame.fill()
        }
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            cellFrame.fill()
        }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: cellFrame.height - 12).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let c = column else { super.drawInterior(withFrame: cellFrame, in: controlView); return }
        var x = cellFrame.minX + 10
        let tint: NSColor = c.isCalculated ? .controlAccentColor : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        func drawSymbol(_ name: String, at x: CGFloat, color: NSColor) -> CGFloat {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return 0 }
            let tinted = image.copy() as? NSImage ?? image
            tinted.isTemplate = true
            let size = tinted.size
            let rect = NSRect(x: x, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height)
            let colored = NSImage(size: size, flipped: false) { r in
                tinted.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            colored.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return size.width
        }
        x += drawSymbol(c.glyph, at: x, color: tint) + 6
        var trailing = cellFrame.maxX - 8
        // Leave room for the sort indicator AppKit draws.
        trailing -= 14
        if c.isFiltered {
            trailing -= 12
            _ = drawSymbol("line.3.horizontal.decrease", at: trailing, color: .controlAccentColor)
            trailing -= 4
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: c.isHidden ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }(),
        ]
        let title = c.name as NSString
        let h = title.size(withAttributes: attrs).height
        title.draw(in: NSRect(x: x, y: cellFrame.midY - h / 2, width: max(0, trailing - x), height: h), withAttributes: attrs)
    }
}

/// `NSTableView` with spreadsheet-style cell range selection and copy.
final class GridTableView: NSTableView {
    weak var coordinator: DataGrid.Coordinator?
    private(set) var cellSelection: GridCellRange?
    private var anchor: (row: Int, column: Int)?
    private var cursor: (row: Int, column: Int)?
    var highlightedColumn: Int?

    override var acceptsFirstResponder: Bool { true }

    func refreshRowBackgrounds() {
        enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    func clampSelection(rows: Int, columns: Int) {
        guard let s = cellSelection else { return }
        if rows == 0 || columns == 0 || s.rows.lowerBound >= rows || s.columns.lowerBound >= columns {
            cellSelection = nil; anchor = nil; cursor = nil
        } else {
            cellSelection = GridCellRange(rows: s.rows.lowerBound...min(s.rows.upperBound, rows - 1),
                                          columns: s.columns.lowerBound...min(s.columns.upperBound, columns - 1))
        }
    }

    private func setSelection(from a: (row: Int, column: Int), to b: (row: Int, column: Int)) {
        let new = GridCellRange(rows: min(a.row, b.row)...max(a.row, b.row), columns: min(a.column, b.column)...max(a.column, b.column))
        cursor = b
        guard new != cellSelection else { return }
        cellSelection = new
        refreshRowBackgrounds()
    }

    private func cell(at point: NSPoint, clamped: Bool) -> (row: Int, column: Int)? {
        var r = row(at: point), c = column(at: point)
        if clamped {
            guard numberOfRows > 0, numberOfColumns > 0 else { return nil }
            if r < 0 { r = point.y < 0 ? 0 : numberOfRows - 1 }
            if c < 0 { c = point.x < 0 ? 0 : numberOfColumns - 1 }
        }
        return r >= 0 && c >= 0 ? (r, c) : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = cell(at: p, clamped: false) else {
            cellSelection = nil; anchor = nil; cursor = nil
            refreshRowBackgrounds()
            return
        }
        if event.modifierFlags.contains(.shift), let a = anchor { setSelection(from: a, to: hit) }
        else { anchor = hit; setSelection(from: hit, to: hit) }
        // Track the drag to extend the range, scrolling at the edges.
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            autoscroll(with: e)
            let q = convert(e.locationInWindow, from: nil)
            if let a = anchor, let c = cell(at: q, clamped: true) { setSelection(from: a, to: c) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = cell(at: p, clamped: false) {
            let inside = cellSelection.map { $0.rows.contains(hit.row) && $0.columns.contains(hit.column) } ?? false
            if !inside { anchor = hit; setSelection(from: hit, to: hit) }
        }
        return coordinator?.cellMenu()
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        guard numberOfRows > 0, numberOfColumns > 0 else { super.keyDown(with: event); return }
        var target = cursor ?? anchor ?? (0, 0)
        switch event.specialKey {
        case .upArrow: target.row = command ? 0 : target.row - 1
        case .downArrow: target.row = command ? numberOfRows - 1 : target.row + 1
        case .leftArrow: target.column = command ? 0 : target.column - 1
        case .rightArrow: target.column = command ? numberOfColumns - 1 : target.column + 1
        case .pageUp: target.row -= max(1, rows(in: visibleRect).length - 1)
        case .pageDown: target.row += max(1, rows(in: visibleRect).length - 1)
        case .home: target.row = 0
        case .end: target.row = numberOfRows - 1
        default:
            if event.keyCode == 53 { // Esc clears the selection
                cellSelection = nil; anchor = nil; cursor = nil; refreshRowBackgrounds(); return
            }
            super.keyDown(with: event); return
        }
        target.row = max(0, min(numberOfRows - 1, target.row))
        target.column = max(0, min(numberOfColumns - 1, target.column))
        if shift, let a = anchor { setSelection(from: a, to: target) }
        else { anchor = target; setSelection(from: target, to: target) }
        scrollRowToVisible(target.row)
        scrollColumnToVisible(target.column)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection([.command, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c" where cellSelection != nil: coordinator?.copySelection(); return true
        case "a" where numberOfRows > 0 && numberOfColumns > 0:
            anchor = (0, 0)
            setSelection(from: (0, 0), to: (numberOfRows - 1, numberOfColumns - 1))
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }

    override func becomeFirstResponder() -> Bool { refreshRowBackgrounds(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { refreshRowBackgrounds(); return super.resignFirstResponder() }
}
