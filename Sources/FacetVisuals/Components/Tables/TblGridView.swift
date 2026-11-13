import AppKit
import FacetCore

/// One region of the grid. Six panes tile the container: header / body / footer × frozen / scrolling.
/// Only the scrolling body pane lives in the scroll view; the others follow its offset, which gives
/// sticky column headers, frozen row headers and a pinned totals row with synchronised scrolling.
final class CmpTblPane: NSView {
    enum Band { case header, body, footer }
    let band: Band
    let frozen: Bool
    weak var grid: CmpTblGridContainer?
    /// Content offset for panes outside the scroll view.
    var offset = CGPoint.zero { didSet { if offset != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(band: Band, frozen: Bool) {
        self.band = band; self.frozen = frozen
        super.init(frame: .zero)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    // MARK: Geometry

    struct Hit { var row: Int; var col: Int; var cellRect: CGRect; var point: CGPoint }

    private var rowHeight: CGFloat {
        guard let s = grid?.source.style else { return 24 }
        switch band { case .header: return s.headerRowHeight; case .body: return s.rowHeight; case .footer: return s.footerHeight }
    }
    private var rowCount: Int {
        guard let s = grid?.source else { return 0 }
        switch band { case .header: return s.headerRows; case .body: return s.bodyRows; case .footer: return s.footerRows }
    }

    /// Row/column under a point in view coordinates (nil outside any cell).
    func hit(_ p: CGPoint) -> Hit? {
        guard let g = grid else { return nil }
        let cx = p.x + offset.x, cy = p.y + offset.y
        let row = Int(floor(cy / rowHeight))
        guard cy >= 0, row < rowCount, let col = g.column(atX: cx, frozen: frozen) else { return nil }
        let xs = g.xs(frozen: frozen), first = g.colRange(frozen: frozen).lowerBound
        let rect = CGRect(x: xs[col - first] - offset.x, y: CGFloat(row) * rowHeight - offset.y,
                          width: xs[col - first + 1] - xs[col - first], height: rowHeight)
        return Hit(row: row, col: col, cellRect: rect, point: p)
    }

    /// Column whose right edge is within grabbing distance of `p` (header panes only).
    func resizeColumn(at p: CGPoint) -> Int? {
        guard band == .header, let g = grid else { return nil }
        let cx = p.x + offset.x
        let xs = g.xs(frozen: frozen), first = g.colRange(frozen: frozen).lowerBound
        for i in 1..<max(1, xs.count) where abs(xs[i] - cx) <= 4 {
            return g.source.canResize(first + i - 1) ? first + i - 1 : nil
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let g = grid else { return }
        let src = g.source, st = src.style
        let xs = g.xs(frozen: frozen)
        let cols = g.colRange(frozen: frozen)
        guard !cols.isEmpty else { return }
        let content = dirtyRect.offsetBy(dx: offset.x, dy: offset.y)
        let rh = rowHeight
        let totalWidth = xs.last ?? 0
        // Visible column range.
        var c0 = 0
        while c0 < cols.count - 1, xs[c0 + 1] <= content.minX { c0 += 1 }
        var c1 = c0
        while c1 < cols.count - 1, xs[c1 + 1] < content.maxX { c1 += 1 }
        let r0 = max(0, Int(floor(content.minY / rh)))
        let r1 = min(rowCount - 1, Int(floor((content.maxY - 0.01) / rh)))

        switch band {
        case .header:
            if let bg = st.headerBackground { bg.setFill(); CGRect(x: 0, y: 0, width: min(bounds.width, totalWidth - offset.x), height: bounds.height).fill() }
            guard r0 <= r1 else { break }
            for r in r0...r1 {
                for span in src.headerSpans(r) {
                    let lo = max(span.cols.lowerBound, cols.lowerBound), hi = min(span.cols.upperBound, cols.upperBound)
                    guard lo < hi else { continue }
                    let rect = CGRect(x: xs[lo - cols.lowerBound] - offset.x, y: CGFloat(r) * rh,
                                      width: xs[hi - cols.lowerBound] - xs[lo - cols.lowerBound], height: rh)
                    guard rect.intersects(dirtyRect) else { continue }
                    var cell = span.cell; cell.isHeader = true
                    // Keep group labels of wide spans in view while scrolling horizontally.
                    var drawRect = rect
                    if span.cols.count > 1, cell.align != .right {
                        let visible = rect.intersection(CGRect(x: 0, y: rect.minY, width: bounds.width, height: rh))
                        if !visible.isNull, visible.width > 40 { drawRect = visible }
                    }
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: rect).addClip()
                    CmpTblCellRenderer.draw(cell, in: drawRect, style: st, defaultText: st.headerText)
                    NSGraphicsContext.restoreGraphicsState()
                    if r < src.headerRows - 1, !cell.text.isEmpty, !frozen {
                        st.grid.setFill()
                        CGRect(x: rect.minX + 4, y: rect.maxY - 1, width: rect.width - 8, height: 1).fill()
                    }
                    if st.verticalLines { st.grid.setFill(); CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rh).fill() }
                }
            }
            st.strongGrid.setFill()
            CGRect(x: 0, y: bounds.height - 1, width: min(bounds.width, totalWidth - offset.x), height: 1).fill()
        case .body, .footer:
            guard r0 <= r1 else { break }
            let lineWidth = min(bounds.width + offset.x, totalWidth) - offset.x
            for r in r0...r1 {
                let y = CGFloat(r) * rh - offset.y
                let rowRect = CGRect(x: 0, y: y, width: lineWidth, height: rh)
                let isBody = band == .body
                if isBody {
                    if let bg = st.bodyBackground { bg.setFill(); rowRect.fill() }
                    if src.isRowAlternate(r), let alt = st.altBackground { alt.setFill(); rowRect.fill() }
                    if src.isRowSelected(r) { st.selection.setFill(); rowRect.fill() }
                    else if g.hoverRow == r { st.hover.setFill(); rowRect.fill() }
                } else if let bg = st.totalBackground { bg.setFill(); rowRect.fill() }
                for ci in c0...c1 {
                    let rect = CGRect(x: xs[ci] - offset.x, y: y, width: xs[ci + 1] - xs[ci], height: rh)
                    let col = cols.lowerBound + ci
                    let cell = isBody ? src.bodyCell(r, col) : src.footerCell(r, col)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: rect).addClip()
                    CmpTblCellRenderer.draw(cell, in: rect, style: st, defaultText: isBody ? st.text : st.totalText)
                    NSGraphicsContext.restoreGraphicsState()
                    if st.verticalLines { st.grid.setFill(); CGRect(x: rect.maxX - 1, y: y, width: 1, height: rh).fill() }
                }
                if isBody {
                    if st.horizontalLines { st.grid.setFill(); CGRect(x: 0, y: y + rh - 1, width: lineWidth, height: 1).fill() }
                    if g.focusRow == r, g.isFocused {
                        st.accent.setStroke()
                        let p = NSBezierPath(rect: rowRect.insetBy(dx: frozen || g.frozenWidth == 0 ? 0.5 : -1, dy: 0.5))
                        p.lineWidth = 1; p.stroke()
                    }
                }
            }
            if band == .footer {
                st.strongGrid.setFill()
                CGRect(x: 0, y: 0, width: lineWidth, height: 1).fill()
            }
        }
        if frozen {
            st.strongGrid.withAlphaComponent(st.strongGrid.alphaComponent * 0.7).setFill()
            CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    // MARK: Events (forwarded to the container)

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard grid?.source.isInteractive ?? false else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { grid?.paneMouseDown(self, event) }
    override func mouseDragged(with event: NSEvent) { grid?.paneMouseDragged(self, event) }
    override func mouseUp(with event: NSEvent) { grid?.paneMouseUp(self, event) }
    override func mouseMoved(with event: NSEvent) { grid?.paneMouseMoved(self, event) }
    override func mouseExited(with event: NSEvent) { grid?.paneMouseExited(self) }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.paneMenu(self, event) }
    override func scrollWheel(with event: NSEvent) {
        if let scroll = grid?.scroll, band != .body || frozen { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// The grid: lays out the panes, keeps them in step with the scroll view, and handles mouse,
/// keyboard, focus and accessibility.
final class CmpTblGridContainer: NSView {
    private(set) var source: CmpTblGridSource
    let scroll = NSScrollView()
    private let body = CmpTblPane(band: .body, frozen: false)
    private let left = CmpTblPane(band: .body, frozen: true)
    private let top = CmpTblPane(band: .header, frozen: false)
    private let corner = CmpTblPane(band: .header, frozen: true)
    private let bottom = CmpTblPane(band: .footer, frozen: false)
    private let bottomCorner = CmpTblPane(band: .footer, frozen: true)
    private var panes: [CmpTblPane] { [body, left, top, corner, bottom, bottomCorner] }

    var hoverRow: Int?
    var focusRow: Int?
    var isFocused: Bool { window?.firstResponder === self }
    private var xsFrozen: [CGFloat] = [0], xsScroll: [CGFloat] = [0]
    private(set) var frozenWidth: CGFloat = 0
    private var resizing: (col: Int, startX: CGFloat, startWidth: CGFloat, moved: Bool)?
    private var pressed: (pane: CmpTblPane, hit: CmpTblPane.Hit)?
    private var imageObserver: NSObjectProtocol?

    init(source: CmpTblGridSource) {
        self.source = source
        super.init(frame: .zero)
        source.view = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = body
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.drawsBackground = false
        clipsToBounds = true
        addSubview(scroll)
        for p in panes { p.grid = self; if p !== body { addSubview(p) } }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        imageObserver = NotificationCenter.default.addObserver(forName: CmpTblImageCache.didLoad, object: nil, queue: .main) { [weak self] _ in
            self?.redrawAll()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
    }

    override var isFlipped: Bool { true }

    func setSource(_ s: CmpTblGridSource) {
        source = s
        s.view = self
        if let f = focusRow, f >= s.bodyRows { focusRow = s.bodyRows > 0 ? s.bodyRows - 1 : nil }
        hoverRow = nil
        setAccessibilityLabel(s.accessibilityTitle)
        reload()
    }

    /// Recomputes geometry after the source's rows/columns changed.
    func reload() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        relayout()
        redrawAll()
    }
    func redrawAll() { for p in panes { p.needsDisplay = true } }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        let src = source, st = src.style
        guard bounds.width > 0, bounds.height > 0 else { return }
        src.fit(width: bounds.width)
        let w = src.colWidths
        let fz = min(src.frozenCols, w.count)
        xsFrozen = [0]; for i in 0..<fz { xsFrozen.append(xsFrozen[i] + w[i]) }
        xsScroll = [0]; for i in fz..<w.count { xsScroll.append(xsScroll[i - fz] + w[i]) }
        let scrollable = w.count > fz
        frozenWidth = scrollable ? min(xsFrozen.last ?? 0, floor(bounds.width * 0.6)) : min(xsFrozen.last ?? 0, bounds.width)
        let hh = st.showHeader ? min(CGFloat(src.headerRows) * st.headerRowHeight, floor(bounds.height * 0.6)) : 0
        var fh = CGFloat(src.footerRows) * st.footerHeight
        if bounds.height - hh - fh < st.rowHeight * 1.5 { fh = bounds.height - hh >= st.rowHeight + st.footerHeight ? min(fh, st.footerHeight) : 0 }
        // The totals row sits directly under the last row when the content is shorter than the view.
        let bodyH = min(max(0, bounds.height - hh - fh), ceil(CGFloat(src.bodyRows) * st.rowHeight))
        let scrollW = bounds.width - frozenWidth
        corner.frame = CGRect(x: 0, y: 0, width: frozenWidth, height: hh)
        top.frame = CGRect(x: frozenWidth, y: 0, width: scrollW, height: hh)
        left.frame = CGRect(x: 0, y: hh, width: frozenWidth, height: bodyH)
        scroll.frame = CGRect(x: frozenWidth, y: hh, width: scrollW, height: bodyH)
        bottomCorner.frame = CGRect(x: 0, y: hh + bodyH, width: frozenWidth, height: fh)
        bottom.frame = CGRect(x: frozenWidth, y: hh + bodyH, width: scrollW, height: fh)
        let docSize = CGSize(width: max(xsScroll.last ?? 0, 1), height: max(CGFloat(src.bodyRows) * st.rowHeight, 1))
        if body.frame.size != docSize { body.setFrameSize(docSize) }
        scrolled()
    }

    @objc private func scrolled() {
        let o = scroll.contentView.bounds.origin
        top.offset = CGPoint(x: o.x, y: 0)
        bottom.offset = CGPoint(x: o.x, y: 0)
        left.offset = CGPoint(x: 0, y: o.y)
    }

    // MARK: Geometry for panes

    func xs(frozen: Bool) -> [CGFloat] { frozen ? xsFrozen : xsScroll }
    func colRange(frozen: Bool) -> Range<Int> {
        let fz = xsFrozen.count - 1
        return frozen ? 0..<fz : fz..<(fz + xsScroll.count - 1)
    }
    func column(atX x: CGFloat, frozen: Bool) -> Int? {
        let xs = self.xs(frozen: frozen)
        guard x >= 0, let last = xs.last, x < last else { return nil }
        var lo = 0, hi = xs.count - 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid + 1] <= x { lo = mid + 1 } else { hi = mid }
        }
        return colRange(frozen: frozen).lowerBound + lo
    }

    private func redrawRow(_ row: Int?) {
        guard let row else { return }
        let rh = source.style.rowHeight
        body.setNeedsDisplay(CGRect(x: 0, y: CGFloat(row) * rh, width: body.bounds.width, height: rh))
        left.setNeedsDisplay(CGRect(x: 0, y: CGFloat(row) * rh - left.offset.y, width: left.bounds.width, height: rh))
    }

    func scrollRowToVisible(_ row: Int) {
        let rh = source.style.rowHeight
        let visible = scroll.contentView.bounds
        body.scrollToVisible(CGRect(x: visible.minX, y: CGFloat(row) * rh, width: 1, height: rh))
    }

    // MARK: Mouse

    private func onExpander(_ cell: CmpTblCell, _ hit: CmpTblPane.Hit) -> Bool {
        guard cell.expander != nil else { return false }
        let x0 = hit.cellRect.minX + source.style.padH + cell.indent
        return hit.point.x >= x0 - 4 && hit.point.x <= x0 + CmpTblCellRenderer.expanderWidth
    }
    private func headerCell(row: Int, col: Int) -> (CmpTblCell, Range<Int>)? {
        source.headerSpans(row).first { $0.cols.contains(col) }.map { ($0.cell, $0.cols) }
    }

    func paneMouseDown(_ pane: CmpTblPane, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = pane.convert(event.locationInWindow, from: nil)
        pressed = nil
        if pane.band == .header, let col = pane.resizeColumn(at: p) {
            if event.clickCount == 2 {
                source.columnResized(col: col, width: nil)
                return
            }
            resizing = (col, event.locationInWindow.x, source.colWidths[safe: col] ?? 80, false)
            return
        }
        if let hit = pane.hit(p) { pressed = (pane, hit) }
        else if pane.band == .body { source.clearSelection() }
    }

    func paneMouseDragged(_ pane: CmpTblPane, _ event: NSEvent) {
        guard var r = resizing else { return }
        let w = max(28, r.startWidth + event.locationInWindow.x - r.startX)
        r.moved = true; resizing = r
        source.setUserWidth(col: r.col, w, available: bounds.width)
        relayout(); redrawAll()
    }

    func paneMouseUp(_ pane: CmpTblPane, _ event: NSEvent) {
        if let r = resizing {
            resizing = nil
            if r.moved { source.columnResized(col: r.col, width: source.colWidths[safe: r.col]) }
            return
        }
        guard let (downPane, hit) = pressed, downPane === pane else { return }
        pressed = nil
        let p = pane.convert(event.locationInWindow, from: nil)
        guard let up = pane.hit(p), up.row == hit.row, up.col == hit.col else { return }
        let mods = event.modifierFlags
        switch pane.band {
        case .header:
            guard let (cell, _) = headerCell(row: hit.row, col: hit.col) else { return }
            // Spans are drawn from their own left edge; recompute the expander test against the span rect.
            var spanHit = hit
            if let span = source.headerSpans(hit.row).first(where: { $0.cols.contains(hit.col) }) {
                let xs = self.xs(frozen: pane.frozen), first = colRange(frozen: pane.frozen).lowerBound
                let lo = max(span.cols.lowerBound, first)
                spanHit.cellRect.origin.x = max(xs[lo - first] - pane.offset.x, span.cols.count > 1 ? 0 : -.infinity)
            }
            source.headerClick(row: hit.row, col: hit.col, shift: mods.contains(.shift), onExpander: onExpander(cell, spanHit))
        case .body:
            let cell = source.bodyCell(hit.row, hit.col)
            let exp = onExpander(cell, hit)
            if !exp, let url = cell.link, !mods.contains(.command), !mods.contains(.shift) {
                NSWorkspace.shared.open(url)
                return
            }
            let old = focusRow
            focusRow = hit.row
            redrawRow(old)
            source.bodyClick(row: hit.row, col: hit.col, command: mods.contains(.command), shift: mods.contains(.shift), onExpander: exp)
        case .footer:
            break
        }
    }

    func paneMouseMoved(_ pane: CmpTblPane, _ event: NSEvent) {
        let p = pane.convert(event.locationInWindow, from: nil)
        if pane.band == .header {
            if pane.resizeColumn(at: p) != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        let hit = pane.hit(p)
        let newHover = pane.band == .body ? hit?.row : nil
        if newHover != hoverRow {
            let old = hoverRow
            hoverRow = newHover
            redrawRow(old); redrawRow(newHover)
        }
        // Tooltip for truncated text; pointing-hand for links.
        var tip: String?
        if let hit {
            let cell: CmpTblCell?
            switch pane.band {
            case .header: cell = headerCell(row: hit.row, col: hit.col).map { var c = $0.0; c.isHeader = true; return c }
            case .body: cell = source.bodyCell(hit.row, hit.col)
            case .footer: cell = source.footerCell(hit.row, hit.col)
            }
            if let cell {
                if cell.link != nil { NSCursor.pointingHand.set() } else if pane.band == .body { NSCursor.arrow.set() }
                if CmpTblCellRenderer.isTruncated(cell, hit.cellRect, source.style) { tip = cell.text }
                else if let link = cell.link { tip = link.absoluteString }
                else if cell.spark != nil { tip = cell.text }
            }
        }
        if pane.toolTip != tip { pane.toolTip = tip }
    }

    func paneMouseExited(_ pane: CmpTblPane) {
        let old = hoverRow
        hoverRow = nil
        redrawRow(old)
        NSCursor.arrow.set()
    }

    func paneMenu(_ pane: CmpTblPane, _ event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let p = pane.convert(event.locationInWindow, from: nil)
        guard let hit = pane.hit(p) else { return source.menu(row: nil, col: 0) }
        return source.menu(row: pane.band == .body ? hit.row : nil, col: hit.col)
    }

    // MARK: Keyboard & focus

    override var acceptsFirstResponder: Bool { source.isInteractive }
    override var canBecomeKeyView: Bool { source.isInteractive }
    override var focusRingType: NSFocusRingType { get { .exterior } set {} }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    override func becomeFirstResponder() -> Bool {
        if focusRow == nil, source.bodyRows > 0 { focusRow = 0 }
        noteFocusRingMaskChanged(); redrawAll()
        return true
    }
    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged(); redrawAll()
        return true
    }

    private func moveFocus(to row: Int, extend: Bool) {
        guard source.bodyRows > 0 else { return }
        let r = max(0, min(source.bodyRows - 1, row))
        focusRow = r
        source.selectRow(r, additive: false, extend: extend)
        scrollRowToVisible(r)
        redrawAll()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        let page = max(1, Int(scroll.contentView.bounds.height / source.style.rowHeight) - 1)
        let current = focusRow ?? -1
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": source.copySelection(); return
            case "a": source.selectAll(); redrawAll(); return
            default: break
            }
        }
        switch event.keyCode {
        case 125: moveFocus(to: mods.contains(.command) ? source.bodyRows - 1 : current + 1, extend: mods.contains(.shift))
        case 126: moveFocus(to: mods.contains(.command) ? 0 : current - 1, extend: mods.contains(.shift))
        case 121: moveFocus(to: current + page, extend: mods.contains(.shift))
        case 116: moveFocus(to: current - page, extend: mods.contains(.shift))
        case 115: moveFocus(to: 0, extend: mods.contains(.shift))
        case 119: moveFocus(to: source.bodyRows - 1, extend: mods.contains(.shift))
        case 123: // left: collapse, else scroll
            if let f = focusRow { source.setExpanded(row: f, false) }
            scrollHorizontally(-60)
        case 124:
            if let f = focusRow { source.setExpanded(row: f, true) }
            scrollHorizontally(60)
        case 49: // space toggles the focused row
            if let f = focusRow { source.selectRow(f, additive: true, extend: false); redrawAll() }
        case 36, 76: // return toggles expansion
            if let f = focusRow { source.setExpanded(row: f, nil) }
        case 53: source.clearSelection(); redrawAll()
        default: super.keyDown(with: event)
        }
    }
    private func scrollHorizontally(_ dx: CGFloat) {
        let clip = scroll.contentView
        let maxX = max(0, body.frame.width - clip.bounds.width)
        let x = max(0, min(maxX, clip.bounds.origin.x + dx))
        guard x != clip.bounds.origin.x else { return }
        clip.scroll(to: CGPoint(x: x, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
    }

    @objc func copy(_ sender: Any?) { source.copySelection() }
    override func selectAll(_ sender: Any?) { source.selectAll(); redrawAll() }

    // MARK: Accessibility

    override func accessibilityRowCount() -> Int { source.bodyRows }
    override func accessibilityColumnCount() -> Int { source.colWidths.count }
    override func accessibilityValueDescription() -> String? {
        "\(source.bodyRows) rows, \(source.colWidths.count) columns. Columns: \(source.headerDescription())"
    }
    override func accessibilityChildren() -> [Any]? {
        let rh = source.style.rowHeight
        guard rh > 0, source.bodyRows > 0 else { return [] }
        let visible = scroll.contentView.bounds
        let first = max(0, Int(visible.minY / rh)), last = min(source.bodyRows - 1, Int(visible.maxY / rh))
        guard first <= last else { return [] }
        return (first...last).map { row -> NSAccessibilityElement in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.row)
            e.setAccessibilityParent(self)
            e.setAccessibilityLabel(source.rowDescription(row))
            e.setAccessibilitySelected(source.isRowSelected(row))
            e.setAccessibilityIndex(row)
            let local = CGRect(x: 0, y: scroll.frame.minY + CGFloat(row) * rh - visible.minY, width: bounds.width, height: rh)
            if let w = window { e.setAccessibilityFrame(w.convertToScreen(convert(local, to: nil))) }
            return e
        }
    }
}
