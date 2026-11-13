import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Ribbon

/// Ribbon chart: like a stacked area, but each series is drawn as its own band whose vertical
/// position follows its rank within each category, so crossings show how ranks changed.
struct RibbonChart: View {
    let env: FlowEnv

    private struct Band {
        var series: Int
        /// Lower and upper edge (in value units) of the band at each category.
        var lo: [Double] = []
        var hi: [Double] = []
    }
    private struct Layout {
        var bands: [Band] = []
        var xs: [CGFloat] = []
        var slices: [(x0: CGFloat, x1: CGFloat)] = []
        var totals: [Double] = []
        var maxTotal = 0.0
        var format = ""
        var caption = ""
    }

    var body: some View {
        let model = SeriesModel(spec: env.spec, data: env.data, categoryWell: .category, valueWells: [.values], legendWell: .legend)
        GeometryReader { geo in
            let L = layout(model, size: geo.size)
            let items = model.series.enumerated().map { offset, s in
                LegendItem(id: offset, name: s.name, color: env.colors.seriesColor(offset, name: s.name))
            }
            let hits = bandHits(L, model)
            var h = Hasher()
            let _ = model.series.forEach { s in h.combine(s.values); h.combine(s.baseline) }
            ChartScaffold(spec: env.spec, context: env.context, items: items) { highlighted in
                FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, size in
                    draw(ctx, L, model, highlighted: highlighted, size: size)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(env.spec.type.displayName), \(model.categories.count) categories, \(model.series.count) series.")
    }

    private func layout(_ model: SeriesModel, size: CGSize) -> Layout {
        var L = Layout()
        let n = model.categories.count, m = model.series.count
        guard n > 0, m > 0 else { return L }
        let pad: CGFloat = 6
        let usable = max(1, size.width - pad * 2)
        let bandWidth = usable / CGFloat(n)
        for i in 0..<n {
            L.xs.append(pad + bandWidth * (CGFloat(i) + 0.5))
            L.slices.append((pad + bandWidth * CGFloat(i), pad + bandWidth * CGFloat(i + 1)))
        }
        var totals = [Double](repeating: 0, count: n)
        for s in model.series.indices {
            for c in 0..<n { totals[c] += max(0, model.series[s].values[c] ?? 0) }
        }
        L.totals = totals
        L.maxTotal = totals.max() ?? 0
        L.format = model.series.first?.format ?? ""
        L.caption = env.caption(model.series.first?.column)
        for _ in 0..<m {
            L.bands.append(Band(series: 0, lo: [Double](repeating: 0, count: n), hi: [Double](repeating: 0, count: n)))
        }
        for s in model.series.indices {
            L.bands[s].series = s
        }
        // Rank order per category: value descending, series order as tie-break.
        for c in 0..<n {
            let order = model.series.indices.sorted { a, b in
                let va = model.series[a].values[c] ?? 0, vb = model.series[b].values[c] ?? 0
                return va == vb ? a < b : va > vb
            }
            var cum = 0.0
            for s in order {
                let v = max(0, model.series[s].values[c] ?? 0)
                L.bands[s].lo[c] = cum
                L.bands[s].hi[c] = cum + v
                cum += v
            }
        }
        return L
    }

    private func draw(_ ctx: GraphicsContext, _ L: Layout, _ model: SeriesModel, highlighted: Set<Int>, size: CGSize) {
        guard !L.bands.isEmpty, L.maxTotal > 0, L.xs.count > 1 else { return }
        let plot = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 6)
        func y(_ v: Double) -> CGFloat {
            plot.maxY - CGFloat(v / L.maxTotal) * plot.height
        }
        for (offset, band) in L.bands.enumerated() {
            let s = model.series[band.series]
            let color = env.colors.seriesColor(offset, name: s.name)
            let selection = model.selection(category: model.categories.first?.index ?? 0, series: s.index)
            let dim = !highlighted.isEmpty ? !highlighted.contains(offset) : (env.matcher.isActive && !env.matcher.isSelected(selection))
            var top = Path()
            var bottom = Path()
            for (c, x) in L.xs.enumerated() {
                let p = CGPoint(x: x, y: y(band.hi[c]))
                c == 0 ? top.move(to: p) : top.addLine(to: p)
            }
            for (c, x) in L.xs.enumerated().reversed() {
                bottom.addLine(to: CGPoint(x: x, y: y(band.lo[c])))
            }
            var shape = top
            shape.addPath(bottom)
            shape.closeSubpath()
            ctx.fill(shape, with: .color(color.opacity(dim ? 0.28 : 0.82)))
            ctx.stroke(top, with: .color(color), lineWidth: 1)
        }
    }

    private func bandHits(_ L: Layout, _ model: SeriesModel) -> [ChartHit] {
        guard L.maxTotal > 0, !L.bands.isEmpty else { return [] }
        var out: [ChartHit] = []
        for (c, slice) in L.slices.enumerated() {
            let total = L.totals[c]
            for (offset, band) in L.bands.enumerated() {
                let s = model.series[band.series]
                let lo = band.lo[c], hi = band.hi[c]
                guard hi > lo else { continue }
                let selection = model.selection(category: model.categories[c].index, series: s.index)
                let top = band.hi[c] / L.maxTotal
                let bottom = band.lo[c] / L.maxTotal
                let height = 1.0
                let rect = CGRect(x: slice.x0, y: (1 - top) * height, width: slice.x1 - slice.x0,
                                  height: (top - bottom) * height)
                let value = model.series[s.index].values[c] ?? 0
                var rows: [TooltipContent.Row] = [
                    .init(color: env.colors.seriesColor(offset, name: s.name), label: L.caption,
                          value: env.full(value, format: L.format), isEmphasized: true),
                    .init(label: "Rank", value: "\(offset + 1) of \(L.bands.count)"),
                    .init(label: "Share", value: env.percent((hi - lo) / max(total, 1e-12))),
                ]
                rows += env.tooltipRows(row: s.rows[c])
                let tooltip = TooltipContent(title: s.name, rows: rows)
                out.append(ChartHit(id: out.count, path: Path(rect), selection: selection, tooltip: tooltip,
                                    copyText: env.full(value, format: L.format)))
            }
        }
        return out
    }
}

// MARK: - Sankey

/// Sankey diagram: Source → Destination flows. One node per source on the left, one per destination
/// on the right; ribbon thickness is the summed value of each flow.
struct SankeyChart: View {
    let env: FlowEnv

    private struct Node {
        let name: String
        let weight: Double
        var y: CGFloat = 0
        var height: CGFloat = 0
    }
    private struct Link {
        let source: Int, destination: Int
        let value: Double
        /// Offsets inside the source / destination nodes, in points at the rendered scale.
        var sy: CGFloat = 0, ty: CGFloat = 0
        var height: CGFloat = 0
    }
    private struct Layout {
        var nodes: [Node] = []
        var sourceCount = 0
        var links: [Link] = []
        var format = ""
    }

    var body: some View {
        GeometryReader { geo in
            let L = layout(size: geo.size)
            let hits = sankeyHits(L, size: geo.size)
            var h = Hasher()
            let _ = L.links.forEach { h.combine($0.value); h.combine($0.source); h.combine($0.destination) }
            FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, size in
                draw(ctx, L, size: size)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sankey diagram.")
    }

    private func aggregate() -> (links: [(s: String, t: String, v: Double)], format: String) {
        let t = env.data.table
        let sCols = env.data.indices(.source), dCols = env.data.indices(.destination)
        guard !sCols.isEmpty, !dCols.isEmpty, let vc = env.data.indices(.values).first, vc < t.columnCount else { return ([], "") }
        var keyOrder: [(String, String)] = []
        var linkTotals: [String: Double] = [:]
        var seen: Set<String> = []
        for r in 0..<t.rowCount {
            let s = StatSupport.label(data: env.data, row: r, columns: sCols)
            let d = StatSupport.label(data: env.data, row: r, columns: dCols)
            let v = t[r, vc].asDouble ?? 0
            guard v.isFinite, v > 0 else { continue }
            let key = "\(s)\u{1}\(d)"
            if seen.insert(key).inserted { keyOrder.append((s, d)) }
            linkTotals[key, default: 0] += v
        }
        let links = keyOrder.map { (s: $0.0, t: $0.1, v: linkTotals["\($0.0)\u{1}\($0.1)"] ?? 0) }
        return (links, env.data.formats[safe: vc] ?? "")
    }

    private func layout(size: CGSize) -> Layout {
        let (aggregated, format) = aggregate()
        var L = Layout()
        L.format = format
        guard !aggregated.isEmpty else { return L }
        var sourceOrder: [String] = [], destOrder: [String] = []
        var sourceTotals: [String: Double] = [:], destTotals: [String: Double] = [:]
        for l in aggregated {
            if sourceTotals[l.s] == nil { sourceTotals[l.s] = 0; sourceOrder.append(l.s) }
            if destTotals[l.t] == nil { destTotals[l.t] = 0; destOrder.append(l.t) }
            sourceTotals[l.s]! += l.v
            destTotals[l.t]! += l.v
        }
        L.sourceCount = sourceOrder.count
        let pad: CGFloat = 12, nodeWidth: CGFloat = 10, gap: CGFloat = 8
        let usable = max(20, size.height - pad * 2)
        let leftTotal = max(sourceTotals.values.max() ?? 0, 1e-9)
        let rightTotal = max(destTotals.values.max() ?? 0, 1e-9)
        let columnTotal = max(leftTotal, rightTotal)
        let leftScale = usable - CGFloat(max(0, sourceOrder.count - 1)) * gap
        let rightScale = usable - CGFloat(max(0, destOrder.count - 1)) * gap
        var yLeft = pad
        var nodeIndex: [String: Int] = [:]
        for s in sourceOrder {
            let weight = sourceTotals[s] ?? 0
            let height = max(2, CGFloat(weight / columnTotal) * leftScale)
            nodeIndex[s] = L.nodes.count
            L.nodes.append(Node(name: s, weight: weight, y: yLeft, height: height))
            yLeft += height + gap
        }
        var yRight = pad
        for d in destOrder {
            let weight = destTotals[d] ?? 0
            let height = max(2, CGFloat(weight / columnTotal) * rightScale)
            nodeIndex[d] = L.nodes.count
            L.nodes.append(Node(name: d, weight: weight, y: yRight, height: height))
            yRight += height + gap
        }
        // Ribbons occupy their node top to bottom in draw order.
        var usedSource: [Int: CGFloat] = [:], usedDest: [Int: CGFloat] = [:]
        for l in aggregated {
            guard let si = nodeIndex[l.s], let di = nodeIndex[l.t], si < L.sourceCount else { continue }
            let s = L.nodes[si], d = L.nodes[di]
            let height = max(1, CGFloat(l.v / max(s.weight, 1e-9)) * s.height)
            let sy = s.y + (usedSource[si] ?? 0)
            let ty = d.y + (usedDest[di] ?? 0)
            usedSource[si, default: 0] += height
            usedDest[di, default: 0] += height
            L.links.append(Link(source: si, destination: di, value: l.v, sy: sy, ty: ty, height: height))
        }
        return L
    }

    private func linkPath(_ l: Link, _ L: Layout, size: CGSize) -> Path {
        let pad: CGFloat = 12, nodeWidth: CGFloat = 10
        let x0 = pad + nodeWidth, x1 = max(x0 + 4, size.width - pad - nodeWidth)
        let midX = (x0 + x1) / 2
        let sy0 = l.sy, sy1 = l.sy + l.height
        let ty0 = l.ty, ty1 = l.ty + l.height
        var p = Path()
        p.move(to: CGPoint(x: x0, y: sy0))
        p.addCurve(to: CGPoint(x: x1, y: ty0), control1: CGPoint(x: midX, y: sy0), control2: CGPoint(x: midX, y: ty0))
        p.addLine(to: CGPoint(x: x1, y: ty1))
        p.addCurve(to: CGPoint(x: x0, y: sy1), control1: CGPoint(x: midX, y: ty1), control2: CGPoint(x: midX, y: sy1))
        p.closeSubpath()
        return p
    }

    private func draw(_ ctx: GraphicsContext, _ L: Layout, size: CGSize) {
        guard !L.nodes.isEmpty else { return }
        let pad: CGFloat = 12, nodeWidth: CGFloat = 10
        let linkColor = env.style.theme.dataColor(0)
        for l in L.links {
            let path = linkPath(l, L, size: size)
            ctx.fill(path, with: .color(linkColor.opacity(0.30)))
            ctx.stroke(path, with: .color(linkColor.opacity(0.12)), lineWidth: 0.5)
        }
        let fs = env.labelSize
        for (i, node) in L.nodes.enumerated() {
            let isSource = i < L.sourceCount
            let color = env.colors.seriesColor(isSource ? i : i - L.sourceCount, name: node.name)
            let rect = CGRect(x: isSource ? pad : size.width - pad - nodeWidth, y: node.y, width: nodeWidth, height: node.height)
            ctx.fill(Path(rect), with: .color(color))
            let x = isSource ? rect.maxX + 6 : rect.minX - 6
            let name = ChartText.truncated(node.name, fontSize: fs, width: max(40, size.width * 0.34))
            ctx.flowText(name, at: CGPoint(x: x, y: rect.minY + 6), anchor: isSource ? .topLeading : .topTrailing,
                         size: fs, color: env.style.theme.foregroundColor)
            ctx.flowText(env.full(node.weight, format: L.format), at: CGPoint(x: x, y: rect.minY + 6 + fs + 2),
                         anchor: isSource ? .topLeading : .topTrailing, size: max(9, fs - 1), color: env.style.theme.secondaryColor)
        }
    }

    private func sankeyHits(_ L: Layout, size: CGSize) -> [ChartHit] {
        guard !L.nodes.isEmpty else { return [] }
        var out: [ChartHit] = []
        for l in L.links {
            let s = L.nodes[l.source], d = L.nodes[l.destination]
            let path = linkPath(l, L, size: size)
            out.append(ChartHit(id: out.count, path: path, selection: nil,
                                tooltip: TooltipContent(title: "\(s.name) → \(d.name)", rows: [
                                    .init(label: "Flow", value: env.full(l.value, format: L.format), isEmphasized: true),
                                    .init(label: "Of \(s.name)", value: env.percent(l.value / max(s.weight, 1e-9))),
                                    .init(label: "Of \(d.name)", value: env.percent(l.value / max(d.weight, 1e-9))),
                                ])))
        }
        // Node hits sit above the links, so the pointer finds the node first.
        let pad: CGFloat = 12, nodeWidth: CGFloat = 10
        for (i, node) in L.nodes.enumerated() {
            let isSource = i < L.sourceCount
            let rect = CGRect(x: isSource ? pad : size.width - pad - nodeWidth, y: node.y, width: nodeWidth, height: node.height)
            out.append(ChartHit(id: out.count, path: Path(rect), selection: nil,
                                tooltip: TooltipContent(title: node.name, rows: [
                                    .init(label: isSource ? "Total out" : "Total in",
                                          value: env.full(node.weight, format: L.format), isEmphasized: true),
                                ])))
        }
        return out
    }
}

// MARK: - Word cloud

/// Word cloud: one word per category, sized by its value, placed greedily around the centre.
struct WordCloudChart: View {
    let env: FlowEnv

    private struct Word {
        let text: String
        let value: Double
        let row: Int
        let selection: DataPointSelection?
        var fontSize: CGFloat = 12
        var rect: CGRect = .zero
        var color: Color = .primary
    }
    private struct Layout {
        var words: [Word] = []
        var total = 0.0
        var format = ""
    }

    var body: some View {
        GeometryReader { geo in
            let L = layout(size: geo.size)
            let hits = wordHits(L)
            var h = Hasher()
            let _ = L.words.forEach { h.combine($0.text); h.combine($0.fontSize); h.combine($0.rect.minX) }
            FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, _ in
                for w in L.words {
                    let dim = w.selection.map { env.matcher.isActive && !env.matcher.isSelected($0) } ?? false
                    ctx.flowText(w.text, at: CGPoint(x: w.rect.midX, y: w.rect.midY), size: w.fontSize,
                                 color: w.color.opacity(dim ? 0.3 : 1))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Word cloud, \(wordCount) words.")
    }

    private func aggregate() -> (words: [(text: String, value: Double, row: Int)], format: String) {
        let t = env.data.table
        let catCols = env.data.indices(.category)
        guard let vc = env.data.indices(.values).first, vc < t.columnCount else { return ([], "") }
        var out: [(text: String, value: Double, row: Int)] = []
        for r in 0..<t.rowCount {
            let v = t[r, vc].asDouble ?? 0
            guard v.isFinite else { continue }
            let label = catCols.isEmpty ? t.columns[vc].name : StatSupport.label(data: env.data, row: r, columns: catCols)
            out.append((label.isEmpty ? "(Blank)" : label, v, r))
        }
        return (out, env.data.formats[safe: vc] ?? "")
    }

    private var wordCount: Int { aggregate().words.count }

    private func layout(size: CGSize) -> Layout {
        let (items, format) = aggregate()
        var L = Layout()
        L.format = format
        L.total = items.reduce(0) { $0 + $1.value }
        let catCols = env.data.indices(.category)
        let sorted = items.sorted { $0.value > $1.value }
        let maxValue = sorted.first?.value ?? 0
        let nonZero = maxValue > 0
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 6)
        var placed: [CGRect] = []
        let colors = env.colors
        for (i, w) in sorted.enumerated() {
            let t = nonZero ? (w.value / maxValue).squareRoot() : 0.4
            var fontSize = max(10, min(44, 10 + t * 34))
            var text = w.text
            var rect: CGRect?
            for _ in 0..<3 {
                let maxWidth = min(bounds.width - 8, ChartText.size(text, fontSize: fontSize).width + 12)
                text = ChartText.truncated(text, fontSize: fontSize, width: maxWidth)
                rect = spiralPlace(text: text, fontSize: fontSize, in: bounds, avoid: placed)
                if rect != nil { break }
                fontSize *= 0.82
            }
            guard let r = rect else { continue }
            placed.append(r.insetBy(dx: -3, dy: -2))
            L.words.append(Word(text: text, value: w.value, row: w.row,
                                selection: SeriesModel.selection(data: env.data, row: w.row, columns: catCols),
                                fontSize: fontSize, rect: r, color: colors.seriesColor(i, name: w.text)))
        }
        return L
    }

    private func wordHits(_ L: Layout) -> [ChartHit] {
        L.words.enumerated().map { i, w -> ChartHit in
            var rows: [TooltipContent.Row] = [
                .init(color: w.color, label: "Value", value: env.full(w.value, format: L.format), isEmphasized: true),
                .init(label: "Share", value: env.percent(w.value / max(L.total, 1e-12))),
            ]
            rows += env.tooltipRows(row: w.row)
            let tooltip = TooltipContent(title: w.text, rows: rows)
            return ChartHit(id: i, path: Path(w.rect), selection: w.selection, tooltip: tooltip,
                            copyText: env.full(w.value, format: L.format))
        }
    }

    /// Finds a spot for a word near the centre, spiralling out; nil when nowhere fits.
    private func spiralPlace(text: String, fontSize: CGFloat, in bounds: CGRect, avoid: [CGRect]) -> CGRect? {
        let sz = ChartText.size(text, fontSize: fontSize)
        let frame = CGSize(width: sz.width + 4, height: sz.height + 2)
        guard frame.width <= bounds.width, frame.height <= bounds.height else { return nil }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxR = hypot(bounds.width, bounds.height) / 2
        var r: CGFloat = 0
        while r <= maxR {
            let steps = max(8, Int(r / 6))
            for k in 0..<max(steps, 1) {
                let a = CGFloat(k) / CGFloat(max(steps, 1)) * 2 * .pi
                let p = CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r * 0.6)
                let candidate = CGRect(x: p.x - frame.width / 2, y: p.y - frame.height / 2, width: frame.width, height: frame.height)
                guard bounds.insetBy(dx: -2, dy: -2).contains(candidate) else { continue }
                if !avoid.contains(where: { $0.intersects(candidate) }) { return candidate }
            }
            r += fontSize * 0.6 + 2
        }
        return nil
    }
}
