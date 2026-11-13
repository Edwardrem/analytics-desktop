import AppKit
import SwiftUI
import FacetCore
import FacetDesign

// The table and the matrix share one custom-drawn, virtualised grid (see `CmpTblGridContainer`).
// A `CmpTblGridSource` describes the grid: column widths, frozen columns, header/body/footer rows and
// the content of each cell. Only visible cells are ever asked for, so 100k+ rows stay smooth.

/// Everything needed to draw one grid cell.
struct CmpTblCell {
    var text = ""
    var align: NSTextAlignment = .left
    var bold = false
    var textColor: NSColor?
    var background: NSColor?
    var indent: CGFloat = 0
    var bar: CmpDataBar?
    var barOnly = false
    var icon: (symbol: String, color: String)?
    var iconOnly = false
    var iconTrailing = false
    /// Sparkline points (already parsed) and whether to draw columns instead of a line.
    var spark: [Double]?
    var sparkColumns = false
    /// Image URL / data URI to draw instead of text.
    var imageRef: String?
    var link: URL?
    /// nil = no expander; true = expanded (−); false = collapsed (+).
    var expander: Bool?
    /// Header sort indicator, e.g. "↓" or "↑2".
    var sortGlyph: String?
    var dimmed = false
    var isHeader = false
    var wrap = false
    /// Cell-level selection highlight (matrix value cells).
    var selected = false
}

/// A header cell covering one or more adjacent columns.
struct CmpTblSpan {
    var cols: Range<Int>
    var cell: CmpTblCell
}

/// Resolved fonts, colours and metrics for one grid.
struct CmpTblStyle {
    var bodyFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    var bodyBoldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    var headerFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    var text = NSColor.labelColor
    var secondaryText = NSColor.secondaryLabelColor
    var headerText = NSColor.labelColor
    var totalText = NSColor.labelColor
    var headerBackground: NSColor?
    var bodyBackground: NSColor?
    var altBackground: NSColor?
    var totalBackground: NSColor?
    var grid = NSColor.separatorColor
    var strongGrid = NSColor.separatorColor
    var selection = NSColor.selectedContentBackgroundColor
    var hover = NSColor.labelColor.withAlphaComponent(0.04)
    var accent = NSColor.controlAccentColor
    var link = NSColor.linkColor
    var horizontalLines = true
    var verticalLines = false
    var padH: CGFloat = 8
    var rowHeight: CGFloat = 26
    var headerRowHeight: CGFloat = 28
    /// Height of pinned total rows; nil = same as body rows.
    var footerRowHeight: CGFloat?
    var footerHeight: CGFloat { footerRowHeight ?? rowHeight }
    var showHeader = true
    var uppercaseHeader = false
    var highContrast = false
    /// Opacity of data bars drawn behind values.
    var barAlpha: CGFloat = 0.3

    /// Shared base style from theme + the format cards both table and matrix honour.
    static func resolve(_ env: CmpEnv) -> CmpTblStyle {
        let f = env.f, t = env.theme
        var s = CmpTblStyle()
        let size = CGFloat(f.double("values", "fontSize", max(11, t.label.size + 1)))
        let hsize = CGFloat(f.double("columnHeaders", "fontSize", t.header.size))
        s.bodyFont = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        s.bodyBoldFont = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let family = t.label.fontFamily
        if !family.isEmpty, let custom = NSFont(name: family, size: size) {
            s.bodyFont = custom
            s.bodyBoldFont = NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask)
        }
        let headerBold = f.bool("columnHeaders", "bold", t.header.weight == "bold" || t.header.weight == "semibold")
        s.headerFont = .systemFont(ofSize: hsize, weight: headerBold ? .semibold : .medium)
        s.text = CmpColor.ns(f.string("values", "color", t.foreground))
        s.secondaryText = CmpColor.ns(t.secondaryForeground)
        let headerBg = f.value("columnHeaders", "background")?.stringValue
        s.headerBackground = headerBg.map(CmpColor.ns)
        let defaultHeaderText = headerBg.map { CmpColor.readableText(on: $0) } ?? (headerBold ? t.foreground : t.secondaryForeground)
        s.headerText = CmpColor.ns(f.string("columnHeaders", "color", defaultHeaderText))
        s.bodyBackground = f.value("values", "background")?.stringValue.map(CmpColor.ns)
        let fg = CmpColor.ns(t.foreground)
        if f.bool("values", "alternating", false) {
            s.altBackground = f.value("values", "alternateBackground")?.stringValue.map(CmpColor.ns)
                ?? fg.withAlphaComponent(t.isDark ? 0.06 : 0.035)
        }
        let totalBg = f.value("total", "background")?.stringValue
        s.totalBackground = totalBg.map(CmpColor.ns)
        s.totalText = CmpColor.ns(f.string("total", "color", totalBg.map { CmpColor.readableText(on: $0) } ?? t.foreground))
        let gridHex = f.string("grid", "color", t.gridline)
        s.grid = CmpColor.ns(gridHex).withAlphaComponent(t.isHighContrast ? 0.6 : 1)
        s.strongGrid = t.isHighContrast ? fg : fg.withAlphaComponent(t.isDark ? 0.28 : 0.2)
        s.selection = CmpColor.ns(t.accent).withAlphaComponent(t.isHighContrast ? 0.45 : 0.16)
        s.hover = fg.withAlphaComponent(t.isDark ? 0.06 : 0.04)
        s.accent = CmpColor.ns(t.accent)
        s.link = CmpColor.ns(t.accent)
        s.horizontalLines = f.bool("grid", "horizontal", true)
        s.verticalLines = f.bool("grid", "vertical", false)
        s.showHeader = f.bool("columnHeaders", "show", true)
        s.uppercaseHeader = f.bool("columnHeaders", "uppercase", false)
        s.highContrast = t.isHighContrast
        s.barAlpha = t.isHighContrast ? 0.75 : (t.isDark ? 0.5 : 0.3)
        let pad = CGFloat(f.double("grid", "rowPadding", 5))
        s.rowHeight = ceil(Self.lineHeight(s.bodyFont) + pad * 2)
        s.headerRowHeight = ceil(Self.lineHeight(s.headerFont) + max(pad, 4) * 2 + 2)
        return s
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
}

/// Base class describing a grid. Subclasses: `CmpTblTableSource`, `CmpMxSource`.
class CmpTblGridSource {
    var style = CmpTblStyle()
    /// Natural widths before stretch; `fixed` marks user-sized columns that never stretch.
    var baseWidths: [CGFloat] = []
    var fixed: [Bool] = []
    var colWidths: [CGFloat] = []
    var fillWidth = true
    var frozenCols = 0
    var headerRows = 1
    var bodyRows = 0
    var footerRows = 0
    var isInteractive = true
    var accessibilityTitle = ""
    weak var view: CmpTblGridContainer?

    /// Distributes spare width over non-fixed scrollable columns.
    func fit(width: CGFloat) {
        var w = baseWidths
        let total = w.reduce(0, +)
        if fillWidth, total < width, !w.isEmpty {
            let flexible = w.indices.filter { !(fixed[safe: $0] ?? false) && $0 >= frozenCols }
            let flexTotal = flexible.reduce(CGFloat(0)) { $0 + w[$1] }
            if flexTotal > 0 {
                let extra = width - total
                for i in flexible { w[i] = floor(w[i] + extra * w[i] / flexTotal) }
            }
        }
        colWidths = w
    }

    func headerSpans(_ row: Int) -> [CmpTblSpan] { [] }
    func bodyCell(_ row: Int, _ col: Int) -> CmpTblCell { CmpTblCell() }
    func footerCell(_ row: Int, _ col: Int) -> CmpTblCell { CmpTblCell() }
    func isRowSelected(_ row: Int) -> Bool { false }
    func isRowAlternate(_ row: Int) -> Bool { row % 2 == 1 }
    func canResize(_ col: Int) -> Bool { true }

    func headerClick(row: Int, col: Int, shift: Bool, onExpander: Bool) {}
    func bodyClick(row: Int, col: Int, command: Bool, shift: Bool, onExpander: Bool) {}
    /// Keyboard selection of a whole row.
    func selectRow(_ row: Int, additive: Bool, extend: Bool) {}
    func clearSelection() {}
    func selectAll() {}
    func setExpanded(row: Int, _ expanded: Bool?) {}
    /// `width == nil` resets the column to automatic.
    func columnResized(col: Int, width: CGFloat?) {}
    func menu(row: Int?, col: Int) -> NSMenu? { nil }
    func copySelection() {}
    func rowDescription(_ row: Int) -> String {
        (0..<baseWidths.count).map { bodyCell(row, $0).text }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    func headerDescription() -> String {
        headerSpans(max(0, headerRows - 1)).map(\.cell.text).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Live-resize: set a user width and re-fit.
    func setUserWidth(col: Int, _ w: CGFloat, available: CGFloat) {
        guard baseWidths.indices.contains(col) else { return }
        baseWidths[col] = w
        if fixed.indices.contains(col) { fixed[col] = true }
        fit(width: available)
    }
}

/// Menu item that runs a closure.
final class CmpTblMenuItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.handler = handler
        self.target = self
        self.isEnabled = enabled
        if !enabled { self.action = nil }
    }
    @objc private func run() { handler?() }
}

/// SwiftUI bridge for the grid.
struct CmpTblGridRepresentable: NSViewRepresentable {
    let env: CmpEnv
    let make: (CmpEnv, CmpTblGridSource?) -> CmpTblGridSource

    func makeNSView(context: Context) -> CmpTblGridContainer {
        CmpTblGridContainer(source: CmpTblGridSource())
    }
    func updateNSView(_ view: CmpTblGridContainer, context: Context) {
        view.setSource(make(env, view.source))
    }
}

extension NSColor {
    func cmpDimmed(_ on: Bool) -> NSColor { on ? withAlphaComponent(alphaComponent * 0.42) : self }
}

enum CmpTblFormat {
    /// Cell text. Grouping (non-aggregate) whole numbers without a format string — years, IDs — are shown
    /// without thousands separators.
    static func text(_ v: Value, format: String, grouping: Bool) -> String {
        if grouping, format.isEmpty, v.isNumber, let d = v.asDouble, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return ValueFormatter.format(v, format)
    }
}
