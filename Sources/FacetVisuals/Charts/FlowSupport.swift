import SwiftUI
import FacetCore
import FacetDesign

/// Per-render environment shared by the Canvas-drawn ("flow") charts.
struct FlowEnv {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let style: ChartStyle
    let colors: ColorResolver
    let matcher: SelectionMatcher

    init(spec: VisualSpec, data: VisualData, context: VisualContext) {
        self.spec = spec; self.data = data; self.context = context
        style = ChartStyle(spec: spec, theme: context.theme)
        colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        matcher = SelectionMatcher(context.selection)
    }

    var f: ResolvedFormat { style.format }
    var labelSize: CGFloat { style.size("dataLabels") }
    var labelColor: Color? { f.value("dataLabels", "color")?.stringValue.map { Color(hex: $0) } }

    /// Compact data-label text honouring `dataLabels.displayUnits` / `dataLabels.decimals`.
    func valueLabel(_ v: Double, format: String) -> String {
        AxisFormatter.label(v, units: DisplayUnits(f.string("dataLabels", "displayUnits", "auto")),
                            decimals: f.value("dataLabels", "decimals")?.doubleValue.map { Int($0) }, format: format)
    }
    /// Full-precision value for tooltips.
    func full(_ v: Double, format: String) -> String { ValueFormatter.format(.double(v), format) }
    func percent(_ share: Double) -> String { AxisFormatter.label(share, format: abs(share) < 0.1 ? "0.0%" : "0%") }

    func caption(_ col: Int?) -> String {
        guard let col, col < data.table.columnCount else { return "" }
        return (data.fields[safe: col] ?? nil)?.caption ?? data.table.columns[col].name
    }
    func label(row: Int, col: Int) -> String {
        let v = data.table[row, col]
        return v.isNull ? "(Blank)" : ValueFormatter.format(v, data.formats[safe: col] ?? "")
    }
    func tooltipRows(row: Int?) -> [TooltipContent.Row] {
        SeriesModel.tooltipFields(data: data, row: row).map { .init(label: $0.label, value: $0.value) }
    }
    /// Stroke used to separate adjacent shapes (card colour; foreground in high contrast).
    var separator: Color { style.theme.isHighContrast ? Color.black : style.card }
}

extension GraphicsContext {
    /// Draws a single line of system-font text.
    func flowText(_ s: String, at p: CGPoint, anchor: UnitPoint = .center, size: CGFloat, weight: Font.Weight = .regular, color: Color) {
        draw(Text(s).font(.system(size: size, weight: weight)).foregroundColor(color), at: p, anchor: anchor)
    }
}

/// Canvas plus the standard interaction layer; the building block of every flow chart.
struct FlowCanvas: View {
    let env: FlowEnv
    let hits: [ChartHit]
    var allowsLasso = false
    var snap: CGFloat = 0
    var signature: Int = 0
    let draw: (GraphicsContext, CGSize) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size) }
                .accessibilityHidden(true)
                .animation(env.context.isInteractive ? Design.Motion.standard : nil, value: signature)
            ChartInteractionLayer(hits: hits, spec: env.spec, context: env.context, allowsLasso: allowsLasso,
                                  snapRadius: snap, exposesAccessibility: true)
        }
    }
}

// MARK: - Hierarchy (treemap, sunburst)

/// Two-level hierarchy built from the Category and Details wells with one value column.
struct FlowHierarchy {
    struct Leaf {
        let name: String
        let value: Double
        /// Cross-highlighted part of `value`, when highlighting is active.
        let highlight: Double?
        let row: Int
        let selection: DataPointSelection
    }
    struct Node {
        let index: Int
        let name: String
        var value: Double
        var highlight: Double?
        let row: Int
        let selection: DataPointSelection
        var children: [Leaf]
    }

    var nodes: [Node] = []
    var total = 0.0
    var format = ""
    var valueCaption = ""
    var hasBaseline = false
    var hasChildren = false

    init(data: VisualData) {
        let t = data.table
        guard let vCol = data.indices(.values).first(where: { $0 < t.columnCount }) else { return }
        var catCols = data.indices(.category).filter { $0 < t.columnCount }
        var detCols = data.indices(.details).filter { $0 < t.columnCount }
        if catCols.isEmpty { catCols = detCols; detCols = [] }
        hasChildren = !detCols.isEmpty
        format = data.formats[safe: vCol] ?? ""
        valueCaption = (data.fields[safe: vCol] ?? nil)?.caption ?? t.columns[vCol].name
        let base = data.baseline.flatMap { $0.rowCount == t.rowCount && $0.columnCount == t.columnCount ? $0 : nil }
        hasBaseline = base != nil
        func text(_ r: Int, _ cols: [Int]) -> String {
            cols.map { c in t[r, c].isNull ? "(Blank)" : ValueFormatter.format(t[r, c], data.formats[safe: c] ?? "") }.joined(separator: " ")
        }
        var index: [[Value]: Int] = [:]
        for r in 0..<t.rowCount {
            let hv = t[r, vCol].asDouble
            guard let v = base != nil ? (base?[r, vCol].asDouble ?? hv) : hv, v.isFinite, v > 0 else { continue }
            let hl: Double? = base != nil ? max(0, min(v, hv ?? 0)) : nil
            let key = catCols.map { t[r, $0] }
            let i: Int
            if !catCols.isEmpty, let existing = index[key] { i = existing } else {
                i = nodes.count
                if !catCols.isEmpty { index[key] = i }
                nodes.append(Node(index: i, name: catCols.isEmpty ? valueCaption : text(r, catCols), value: 0, highlight: hl == nil ? nil : 0,
                                  row: r, selection: SeriesModel.selection(data: data, row: r, columns: catCols), children: []))
            }
            nodes[i].value += v
            if let hl { nodes[i].highlight = (nodes[i].highlight ?? 0) + hl }
            if hasChildren {
                nodes[i].children.append(Leaf(name: text(r, detCols), value: v, highlight: hl, row: r,
                                              selection: SeriesModel.selection(data: data, row: r, columns: catCols + detCols)))
            }
            total += v
        }
        nodes.sort { $0.value > $1.value }
        for i in nodes.indices { nodes[i].children.sort { $0.value > $1.value } }
    }

    var signature: Int {
        var h = Hasher()
        for n in nodes { h.combine(n.name); h.combine(n.value); h.combine(n.highlight); h.combine(n.children.count) }
        return h.finalize()
    }
}

enum FlowMath {
    /// Squarified treemap layout. `values` must be sorted descending; returns one rect per value.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let n = values.count
        var out = [CGRect](repeating: .zero, count: n)
        let total = values.reduce(0, +)
        guard n > 0, total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var r = rect, i = 0
        while i < n {
            let side = Double(min(r.width, r.height))
            guard side > 0 else { break }
            var j = i, sum = 0.0, best = Double.infinity
            while j < n {
                let s = sum + areas[j]
                let worst = max(side * side * areas[i] / (s * s), s * s / (side * side * max(areas[j], 1e-12)))
                if worst > best { break }
                best = worst; sum = s; j += 1
            }
            let thickness = CGFloat(sum / side)
            var offset: CGFloat = 0
            for k in i..<j {
                let len = thickness > 0 ? CGFloat(areas[k]) / thickness : 0
                out[k] = r.width >= r.height
                    ? CGRect(x: r.minX, y: r.minY + offset, width: thickness, height: len)
                    : CGRect(x: r.minX + offset, y: r.minY, width: len, height: thickness)
                offset += len
            }
            r = r.width >= r.height
                ? CGRect(x: r.minX + thickness, y: r.minY, width: max(0, r.width - thickness), height: r.height)
                : CGRect(x: r.minX, y: r.minY + thickness, width: r.width, height: max(0, r.height - thickness))
            i = j
        }
        return out
    }

    /// Annular sector path (angles in radians, clockwise from 12 o'clock).
    static func sector(center c: CGPoint, r0: CGFloat, r1: CGFloat, a0: Double, a1: Double) -> Path {
        var p = Path()
        let s = Angle(radians: a0 - .pi / 2), e = Angle(radians: a1 - .pi / 2)
        p.addArc(center: c, radius: r1, startAngle: s, endAngle: e, clockwise: false)
        p.addArc(center: c, radius: r0, startAngle: e, endAngle: s, clockwise: true)
        p.closeSubpath()
        return p
    }
}
