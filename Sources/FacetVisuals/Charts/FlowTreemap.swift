import SwiftUI
import FacetCore
import FacetDesign

/// One drawable piece of a hierarchy chart (treemap tile or sunburst sector).
private struct HierarchyPiece {
    var path: Path
    var bounds: CGRect
    var color: Color
    var name: String
    var value: Double
    var highlight: Double?
    var selection: DataPointSelection
    var row: Int
    var parent: String
    var group: Int
    var isLeaf: Bool
}

private func hierarchyHits(_ pieces: [HierarchyPiece], env: FlowEnv, H: FlowHierarchy) -> [ChartHit] {
    pieces.enumerated().map { i, p in
        ChartHit(id: i, path: p.path, selection: p.selection,
                 tooltip: {
                     var rows: [TooltipContent.Row] = [.init(color: p.color, label: H.valueCaption, value: env.full(p.value, format: H.format), isEmphasized: true)]
                     if let h = p.highlight { rows.append(.init(label: "Highlighted", value: env.full(h, format: H.format))) }
                     if H.total > 0 { rows.append(.init(label: "Share", value: env.percent(p.value / H.total))) }
                     rows += env.tooltipRows(row: p.isLeaf ? p.row : nil)
                     return TooltipContent(title: p.parent.isEmpty || p.parent == p.name ? p.name : "\(p.parent) · \(p.name)", rows: rows)
                 }(),
                 copyText: env.full(p.value, format: H.format))
    }
}

private func hierarchySummary(_ type: VisualType, _ H: FlowHierarchy, _ env: FlowEnv) -> String {
    var s = "\(type.displayName), \(H.nodes.count) categor\(H.nodes.count == 1 ? "y" : "ies")."
    if let top = H.nodes.first, H.total > 0 {
        s += " Largest: \(top.name), \(env.full(top.value, format: H.format)) (\(env.percent(top.value / H.total)))."
    }
    return s
}

// MARK: - Treemap

/// Squarified treemap: Category groups, optionally subdivided by Details.
struct TreemapChart: View {
    let env: FlowEnv

    var body: some View {
        let H = FlowHierarchy(data: env.data)
        GeometryReader { geo in
            let L = layout(H, size: geo.size)
            FlowCanvas(env: env, hits: hierarchyHits(L.pieces, env: env, H: H), signature: H.signature) { ctx, _ in
                draw(ctx, L, H)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hierarchySummary(env.spec.type, H, env))
    }

    private struct Layout {
        var pieces: [HierarchyPiece] = []
        var groups: [(rect: CGRect, name: String, color: Color, header: Bool)] = []
    }

    private func layout(_ H: FlowHierarchy, size: CGSize) -> Layout {
        var L = Layout()
        let pad = CGFloat(env.f.double("treemap", "padding", 2))
        let fs = env.labelSize
        let rects = FlowMath.squarify(H.nodes.map(\.value), in: CGRect(origin: .zero, size: size))
        let radius = CGFloat(env.f.double("treemap", "cornerRadius", 3))
        func tile(_ r: CGRect) -> (Path, CGRect) {
            let t = r.insetBy(dx: min(pad / 2, r.width / 4), dy: min(pad / 2, r.height / 4))
            return (Path(roundedRect: t, cornerRadius: min(radius, t.width / 2, t.height / 2), style: .continuous), t)
        }
        for (i, node) in H.nodes.enumerated() {
            let r = rects[i]
            let base = env.colors.pointColor(series: node.index, seriesName: node.name, category: node.name, row: node.row, value: node.value)
            if H.hasChildren, !node.children.isEmpty {
                let showHeader = env.f.bool("treemap", "showGroupLabels", true) && r.height > 46 && r.width > 54
                let inner = r.insetBy(dx: min(pad / 2, r.width / 4), dy: min(pad / 2, r.height / 4))
                let body = showHeader ? CGRect(x: inner.minX, y: inner.minY + fs + 7, width: inner.width, height: inner.height - fs - 7) : inner
                L.groups.append((inner, node.name, base, showHeader))
                let sub = FlowMath.squarify(node.children.map(\.value), in: body)
                let count = max(1, node.children.count - 1)
                for (k, leaf) in node.children.enumerated() {
                    let (path, b) = tile(sub[k])
                    let c = env.colors.hasConditionalColor
                        ? env.colors.pointColor(series: node.index, seriesName: node.name, row: leaf.row, value: leaf.value)
                        : base.mix(with: env.style.card, by: 0.42 * Double(k) / Double(count))
                    L.pieces.append(HierarchyPiece(path: path, bounds: b, color: c, name: leaf.name, value: leaf.value, highlight: leaf.highlight,
                                                   selection: leaf.selection, row: leaf.row, parent: node.name, group: node.index, isLeaf: true))
                }
            } else {
                let (path, b) = tile(r)
                L.pieces.append(HierarchyPiece(path: path, bounds: b, color: base, name: node.name, value: node.value, highlight: node.highlight,
                                               selection: node.selection, row: node.row, parent: "", group: node.index, isLeaf: !H.hasChildren))
            }
        }
        return L
    }

    private func draw(_ ctx: GraphicsContext, _ L: Layout, _ H: FlowHierarchy) {
        let fs = env.labelSize
        let showLabels = env.f.bool("dataLabels", "show", true)
        let showValues = env.f.bool("treemap", "showValues", true)
        for g in L.groups where g.header {
            ctx.flowText(ChartText.truncated(g.name, fontSize: fs, width: g.rect.width - 8, weight: .semibold),
                         at: CGPoint(x: g.rect.minX + 3, y: g.rect.minY + (fs + 7) / 2), anchor: .leading, size: fs, weight: .semibold,
                         color: env.style.foreground)
        }
        for p in L.pieces {
            let e = env.matcher.emphasis(p.selection)
            if let h = p.highlight {
                ctx.fill(p.path, with: .color(p.color.opacity(0.3 * e)))
                var c = ctx
                c.clip(to: p.path)
                let frac = p.value > 0 ? CGFloat(h / p.value) : 0
                c.fill(Path(CGRect(x: p.bounds.minX, y: p.bounds.maxY - p.bounds.height * frac, width: p.bounds.width, height: p.bounds.height * frac)),
                       with: .color(p.color.opacity(e)))
            } else {
                ctx.fill(p.path, with: .color(p.color.opacity(e)))
            }
            if env.style.usesPatterns { ChartPattern.forSeries(p.group).draw(in: ctx, clip: p.path, color: env.style.patternInk.opacity(0.6)) }
            if env.style.theme.isHighContrast { ctx.stroke(p.path, with: .color(env.style.foreground), lineWidth: 1) }
            guard showLabels, p.bounds.width >= 34, p.bounds.height >= fs + 8 else { continue }
            let ink = env.labelColor ?? (p.highlight != nil ? env.style.foreground : p.color.contrastingLabel)
            let name = ChartText.truncated(p.name, fontSize: fs, width: p.bounds.width - 12, weight: .medium)
            guard name.count > 1 else { continue }
            ctx.flowText(name, at: CGPoint(x: p.bounds.minX + 6, y: p.bounds.minY + 5), anchor: .topLeading, size: fs, weight: .medium, color: ink.opacity(e))
            if showValues, p.bounds.height >= fs * 2 + 14 {
                let v = env.valueLabel(p.value, format: H.format)
                if ChartText.size(v, fontSize: fs).width <= p.bounds.width - 12 {
                    ctx.flowText(v, at: CGPoint(x: p.bounds.minX + 6, y: p.bounds.minY + 7 + fs + 2), anchor: .topLeading, size: fs, color: ink.opacity(0.78 * e))
                }
            }
        }
    }
}

// MARK: - Sunburst

/// Sunburst: Category as the inner ring, Details as the outer ring.
struct SunburstChart: View {
    let env: FlowEnv

    var body: some View {
        let H = FlowHierarchy(data: env.data)
        GeometryReader { geo in
            let pieces = layout(H, size: geo.size)
            FlowCanvas(env: env, hits: hierarchyHits(pieces, env: env, H: H), signature: H.signature) { ctx, size in
                draw(ctx, pieces, H, size: size)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hierarchySummary(env.spec.type, H, env))
    }

    private func geometry(_ size: CGSize, _ H: FlowHierarchy) -> (c: CGPoint, r0: CGFloat, rm: CGFloat, R: CGFloat) {
        let R = max(4, min(size.width, size.height) / 2 - 2)
        let r0 = R * CGFloat(max(0, min(0.8, env.f.double("slices", "innerRadius", 30) / 100)))
        let rm = H.hasChildren ? r0 + (R - r0) * 0.52 : R
        return (CGPoint(x: size.width / 2, y: size.height / 2), r0, rm, R)
    }

    private func layout(_ H: FlowHierarchy, size: CGSize) -> [HierarchyPiece] {
        guard H.total > 0 else { return [] }
        let g = geometry(size, H)
        var out: [HierarchyPiece] = []
        var a = 0.0
        for node in H.nodes {
            let span = node.value / H.total * 2 * .pi
            let base = env.colors.pointColor(series: node.index, seriesName: node.name, category: node.name, row: node.row, value: node.value)
            let path = FlowMath.sector(center: g.c, r0: g.r0, r1: g.rm, a0: a, a1: a + span)
            out.append(HierarchyPiece(path: path, bounds: CGRect(x: a, y: Double(g.r0), width: span, height: Double(g.rm - g.r0)), color: base,
                                      name: node.name, value: node.value, highlight: node.highlight, selection: node.selection, row: node.row,
                                      parent: "", group: node.index, isLeaf: !H.hasChildren))
            if H.hasChildren {
                var b = a
                let count = max(1, node.children.count - 1)
                for (k, leaf) in node.children.enumerated() {
                    let s = leaf.value / H.total * 2 * .pi
                    let c = env.colors.hasConditionalColor
                        ? env.colors.pointColor(series: node.index, seriesName: node.name, row: leaf.row, value: leaf.value)
                        : base.mix(with: env.style.card, by: 0.2 + 0.4 * Double(k) / Double(count))
                    out.append(HierarchyPiece(path: FlowMath.sector(center: g.c, r0: g.rm, r1: g.R, a0: b, a1: b + s),
                                              bounds: CGRect(x: b, y: Double(g.rm), width: s, height: Double(g.R - g.rm)), color: c,
                                              name: leaf.name, value: leaf.value, highlight: leaf.highlight, selection: leaf.selection, row: leaf.row,
                                              parent: node.name, group: node.index, isLeaf: true))
                    b += s
                }
            }
            a += span
        }
        return out
    }

    private func draw(_ ctx: GraphicsContext, _ pieces: [HierarchyPiece], _ H: FlowHierarchy, size: CGSize) {
        let g = geometry(size, H)
        let fs = env.labelSize
        let showLabels = env.f.bool("dataLabels", "show", true) && g.R > 50
        for p in pieces {
            let e = env.matcher.emphasis(p.selection)
            // `bounds` carries polar geometry: x = start angle, width = sweep, y = inner radius, height = thickness.
            let a0 = Double(p.bounds.minX), sweep = Double(p.bounds.width), ri = p.bounds.minY, th = p.bounds.height
            if let h = p.highlight {
                ctx.fill(p.path, with: .color(p.color.opacity(0.3 * e)))
                let frac = p.value > 0 ? CGFloat(h / p.value) : 0
                ctx.fill(FlowMath.sector(center: g.c, r0: ri, r1: ri + th * frac, a0: a0, a1: a0 + sweep), with: .color(p.color.opacity(e)))
            } else {
                ctx.fill(p.path, with: .color(p.color.opacity(e)))
            }
            if env.style.usesPatterns, !p.isLeaf || !H.hasChildren {
                ChartPattern.forSeries(p.group).draw(in: ctx, clip: p.path, color: env.style.patternInk.opacity(0.6))
            }
            ctx.stroke(p.path, with: .color(env.separator), lineWidth: 1)
            guard showLabels else { continue }
            let rmid = ri + th / 2, arc = CGFloat(sweep) * rmid
            let mid = a0 + sweep / 2 - .pi / 2
            // Horizontal text: room is roughly the arc length when the sector is near top/bottom, the ring thickness at the sides.
            let horiz = abs(sin(mid)), room = max(8, (arc * horiz + th * (1 - horiz)) * 0.9 - 6)
            guard arc >= fs + 4, th >= fs + 4 else { continue }
            let text = ChartText.truncated(p.name, fontSize: fs, width: room)
            guard text.count > 2 || text == p.name else { continue }
            let ink = env.labelColor ?? (p.highlight != nil ? env.style.foreground : p.color.contrastingLabel)
            ctx.flowText(text, at: CGPoint(x: g.c.x + rmid * CGFloat(cos(mid)), y: g.c.y + rmid * CGFloat(sin(mid))), size: fs, color: ink.opacity(e))
        }
        if g.r0 >= 30, env.f.bool("slices", "showCenter", true) {
            let v = env.valueLabel(H.total, format: H.format)
            let big = min(CGFloat(env.style.theme.callout.size), g.r0 * 0.42)
            ctx.flowText(v, at: CGPoint(x: g.c.x, y: g.c.y - (g.r0 >= 44 ? fs * 0.5 : 0)), size: big, weight: .semibold, color: env.style.foreground)
            if g.r0 >= 44 {
                ctx.flowText(ChartText.truncated(H.valueCaption, fontSize: fs, width: g.r0 * 1.6),
                             at: CGPoint(x: g.c.x, y: g.c.y + big * 0.5 + 4), size: fs, color: env.style.secondary)
            }
        }
    }
}
