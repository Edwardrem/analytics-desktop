import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Funnel

/// Funnel: one centred bar per category, widths proportional to the value, with soft connectors
/// and conversion percentages.
struct FunnelChart: View {
    let env: FlowEnv

    private struct Stage {
        let cat: Int
        let name: String
        let value: Double
        let highlight: Double?
        let row: Int?
        let color: Color
        var bar: CGRect = .zero
        var hi: CGRect = .zero
    }
    private struct Layout {
        var stages: [Stage] = []
        var labelWidth: CGFloat = 0
        var percentWidth: CGFloat = 0
        var format = ""
        var caption = ""
    }

    var body: some View {
        let model = SeriesModel(spec: env.spec, data: env.data, legendWell: nil)
        GeometryReader { geo in
            let L = layout(model, size: geo.size)
            let first = L.stages.first?.value ?? 0
            let hits = L.stages.enumerated().map { i, s in
                ChartHit(id: i, rect: s.bar.insetBy(dx: s.bar.width < 6 ? -3 : 0, dy: 0), selection: model.selection(category: s.cat),
                         tooltip: {
                             var rows: [TooltipContent.Row] = [.init(color: s.color, label: L.caption, value: env.full(s.value, format: L.format), isEmphasized: true)]
                             if let h = s.highlight { rows.append(.init(label: "Highlighted", value: env.full(h, format: L.format))) }
                             if first > 0 { rows.append(.init(label: "Of first", value: env.percent(s.value / first))) }
                             if i > 0, L.stages[i - 1].value > 0 { rows.append(.init(label: "Of previous", value: env.percent(s.value / L.stages[i - 1].value))) }
                             return TooltipContent(title: s.name, rows: rows + env.tooltipRows(row: s.row))
                         }(),
                         copyText: env.full(s.value, format: L.format))
            }
            var h = Hasher()
            let _ = L.stages.forEach { h.combine($0.value); h.combine($0.highlight) }
            FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, size in draw(ctx, L, model, size: size) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary(model))
    }

    private func summary(_ model: SeriesModel) -> String {
        guard let s = model.series.first else { return "Funnel" }
        let vals = s.values.enumerated().compactMap { i, v in v.map { (i, $0) } }
        guard let a = vals.first, let b = vals.last else { return "Funnel" }
        return "Funnel, \(vals.count) stages, from \(model.categories[a.0].label) \(model.formatted(a.1, series: 0)) to \(model.categories[b.0].label) \(model.formatted(b.1, series: 0))."
    }

    private func layout(_ model: SeriesModel, size: CGSize) -> Layout {
        var L = Layout()
        guard let s = model.series.first else { return L }
        L.format = s.format; L.caption = s.name
        let fs = env.style.labelSize
        for (c, cat) in model.categories.enumerated() {
            let total = (model.hasBaseline ? s.baseline[c] : nil) ?? s.values[c]
            guard let v = total, v > 0 else { continue }
            L.stages.append(Stage(cat: c, name: cat.label.isEmpty ? s.name : cat.label, value: v,
                                  highlight: model.hasBaseline ? max(0, min(v, s.values[c] ?? 0)) : nil, row: s.rows[c],
                                  color: env.colors.pointColor(series: 0, seriesName: s.name, category: cat.label, row: s.rows[c], value: v)))
        }
        let n = L.stages.count
        guard n > 0 else { return L }
        let showNames = size.width >= 200 && env.f.bool("funnel", "showCategoryLabels", true)
        L.labelWidth = showNames ? min(size.width * 0.3, (L.stages.map { ChartText.size($0.name, fontSize: fs).width }.max() ?? 0)) + 10 : 0
        L.percentWidth = env.f.bool("funnel", "showPercent", true) && size.width >= 260 ? ChartText.size("100.0%", fontSize: fs).width + 10 : 0
        let gap = CGFloat(env.f.double("funnel", "gap", 6))
        let rowH = max(4, min(64, (size.height - gap * CGFloat(n - 1)) / CGFloat(n)))
        let top = (size.height - rowH * CGFloat(n) - gap * CGFloat(n - 1)) / 2
        let area = CGRect(x: L.labelWidth, y: 0, width: max(10, size.width - L.labelWidth - L.percentWidth), height: size.height)
        let maxV = L.stages.map(\.value).max() ?? 1
        for i in 0..<n {
            let w = max(2, area.width * CGFloat(L.stages[i].value / maxV))
            let y = top + CGFloat(i) * (rowH + gap)
            L.stages[i].bar = CGRect(x: area.midX - w / 2, y: y, width: w, height: rowH)
            if let h = L.stages[i].highlight {
                let hw = area.width * CGFloat(h / maxV)
                L.stages[i].hi = CGRect(x: area.midX - hw / 2, y: y, width: hw, height: rowH)
            }
        }
        return L
    }

    private func draw(_ ctx: GraphicsContext, _ L: Layout, _ model: SeriesModel, size: CGSize) {
        let fs = env.style.labelSize, dfs = env.labelSize
        let radius = CGFloat(env.f.double("funnel", "cornerRadius", 3))
        let first = L.stages.first?.value ?? 0
        let percentOfPrevious = env.f.string("funnel", "percentOf", "first") == "previous"
        for (i, s) in L.stages.enumerated() {
            let e = env.matcher.emphasis(model.selection(category: s.cat))
            if i + 1 < L.stages.count, env.f.bool("funnel", "showConnectors", true) {
                let n = L.stages[i + 1].bar
                var p = Path()
                p.move(to: CGPoint(x: s.bar.minX, y: s.bar.maxY)); p.addLine(to: CGPoint(x: s.bar.maxX, y: s.bar.maxY))
                p.addLine(to: CGPoint(x: n.maxX, y: n.minY)); p.addLine(to: CGPoint(x: n.minX, y: n.minY)); p.closeSubpath()
                ctx.fill(p, with: .color(s.color.opacity(0.14)))
            }
            let r = min(radius, s.bar.height / 2, s.bar.width / 2)
            let path = Path(roundedRect: s.bar, cornerRadius: r, style: .continuous)
            if s.highlight != nil {
                ctx.fill(path, with: .color(s.color.opacity(0.3 * e)))
                if s.hi.width > 0.5 { ctx.fill(Path(roundedRect: s.hi, cornerRadius: min(r, s.hi.width / 2), style: .continuous), with: .color(s.color.opacity(e))) }
            } else {
                ctx.fill(path, with: .color(s.color.opacity(e)))
            }
            if env.style.theme.isHighContrast { ctx.stroke(path, with: .color(env.style.foreground), lineWidth: 1) }
            guard s.bar.height >= fs + 2 else { continue }
            if L.labelWidth > 0 {
                ctx.flowText(ChartText.truncated(s.name, fontSize: fs, width: L.labelWidth - 10), at: CGPoint(x: 0, y: s.bar.midY), anchor: .leading,
                             size: fs, color: env.style.secondary.opacity(e))
            }
            if env.f.bool("dataLabels", "show", true), s.bar.height >= dfs + 2 {
                let text = env.valueLabel(s.value, format: L.format)
                let tw = ChartText.size(text, fontSize: dfs, weight: .medium).width
                if tw + 12 <= s.bar.width {
                    let ink = env.labelColor ?? (s.highlight != nil ? env.style.foreground : s.color.contrastingLabel)
                    ctx.flowText(text, at: CGPoint(x: s.bar.midX, y: s.bar.midY), size: dfs, weight: .medium, color: ink.opacity(e))
                } else if s.bar.maxX + 6 + tw <= size.width - L.percentWidth {
                    ctx.flowText(text, at: CGPoint(x: s.bar.maxX + 6, y: s.bar.midY), anchor: .leading, size: dfs, weight: .medium,
                                 color: (env.labelColor ?? env.style.foreground).opacity(e))
                }
            }
            if L.percentWidth > 0 {
                let base = percentOfPrevious ? (i > 0 ? L.stages[i - 1].value : s.value) : first
                if base > 0 {
                    ctx.flowText(env.percent(s.value / base), at: CGPoint(x: size.width, y: s.bar.midY), anchor: .trailing, size: fs,
                                 color: env.style.secondary.opacity(e))
                }
            }
        }
    }
}

// MARK: - Radar

/// Radar (spider) chart: one spoke per category, one polygon per series.
struct RadarChart: View {
    let env: FlowEnv

    var body: some View {
        let model = SeriesModel(spec: env.spec, data: env.data)
        let items = model.series.map { s in
            LegendItem(id: s.index, name: s.name, color: env.colors.seriesColor(s.index, name: s.name),
                       marker: env.style.usesPatterns ? .forSeries(s.index) : .circle, selection: model.seriesSelection(s.index))
        }
        ChartScaffold(spec: env.spec, context: env.context, items: items) { highlighted in
            GeometryReader { geo in
                let G = geometry(model, size: geo.size)
                var h = Hasher()
                let _ = model.series.forEach { h.combine($0.values); h.combine($0.baseline) }
                FlowCanvas(env: env, hits: hits(model, G), snap: 16, signature: h.finalize()) { ctx, _ in
                    draw(ctx, model, G, highlighted: highlighted)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radar chart, \(model.categories.count) categories, \(model.series.count) series.")
    }

    private struct Geometry {
        var c: CGPoint = .zero
        var R: CGFloat = 0
        var scale = AxisScale(lower: 0, upper: 1, ticks: [0, 1])
        var showLabels = false
        func angle(_ i: Int, _ n: Int) -> Double { -Double.pi / 2 + Double(i) / Double(max(n, 1)) * 2 * .pi }
        func point(_ i: Int, _ n: Int, _ v: Double) -> CGPoint {
            let t = scale.span > 0 ? CGFloat(max(0, min(1, (v - scale.lower) / scale.span))) : 0
            let a = angle(i, n)
            return CGPoint(x: c.x + R * t * CGFloat(cos(a)), y: c.y + R * t * CGFloat(sin(a)))
        }
    }

    private func geometry(_ model: SeriesModel, size: CGSize) -> Geometry {
        var G = Geometry()
        let fs = env.style.labelSize
        G.showLabels = size.width >= 170 && size.height >= 130 && env.f.bool("radar", "showCategoryLabels", true)
        let maxLabel = G.showLabels ? min(84, model.categories.map { ChartText.size($0.label, fontSize: fs).width }.max() ?? 0) : 0
        let mx = G.showLabels ? maxLabel + 8 : 4, my = G.showLabels ? fs + 8 : 4
        G.R = max(8, min(size.width / 2 - mx, size.height / 2 - my))
        G.c = CGPoint(x: size.width / 2, y: size.height / 2)
        let all = model.series.flatMap { $0.values.compactMap { $0 } + $0.baseline.compactMap { $0 } }
        G.scale = AxisFormatter.niceScale(dataMin: min(0, all.min() ?? 0), dataMax: all.max() ?? 1, includeZero: true,
                                          fixedMin: env.f.value("radar", "min")?.doubleValue, fixedMax: env.f.value("radar", "max")?.doubleValue,
                                          targetTicks: G.R > 90 ? 4 : 2)
        return G
    }

    private func hits(_ model: SeriesModel, _ G: Geometry) -> [ChartHit] {
        let n = model.categories.count
        var out: [ChartHit] = []
        for s in model.series {
            for c in 0..<n {
                guard let v = s.values[c] else { continue }
                let p = G.point(c, n, v)
                out.append(ChartHit(id: s.index * 100_000 + c, path: Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                                    selection: model.selection(category: c, series: s.index),
                                    tooltip: TooltipContent(title: model.categories[c].label, rows: model.series.compactMap { o in
                                        (o.values[c]).map { .init(color: env.colors.seriesColor(o.index, name: o.name), label: o.name,
                                                                  value: model.formatted($0, series: o.index), isEmphasized: o.index == s.index) }
                                    } + env.tooltipRows(row: s.rows[c])),
                                    copyText: model.formatted(v, series: s.index)))
            }
        }
        return out
    }

    private func draw(_ ctx: GraphicsContext, _ model: SeriesModel, _ G: Geometry, highlighted: Set<Int>) {
        let n = model.categories.count
        guard n > 0 else { return }
        let fs = env.style.labelSize
        let st = env.style
        // Grid: concentric polygons and spokes.
        if env.f.bool("radar", "gridlines", true) {
            for t in G.scale.ticks where t > G.scale.lower {
                var p = Path()
                for i in 0..<n { let pt = G.point(i, n, t); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
                p.closeSubpath()
                ctx.stroke(p, with: .color(st.grid), lineWidth: st.gridWidth)
            }
            var spokes = Path()
            for i in 0..<n { spokes.move(to: G.c); spokes.addLine(to: G.point(i, n, G.scale.upper)) }
            ctx.stroke(spokes, with: .color(st.grid), lineWidth: st.gridWidth)
        }
        let fill = env.f.bool("radar", "fill", true)
        let lineWidth = CGFloat(env.f.double("lines", "width", 2))
        let markers = env.f.bool("lines", "showMarkers", true) && G.R > 56
        func polygon(_ vals: [Double?]) -> Path {
            var p = Path()
            for i in 0..<n { let pt = G.point(i, n, vals[i] ?? G.scale.lower); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
            p.closeSubpath()
            return p
        }
        for s in model.series {
            let color = env.colors.seriesColor(s.index, name: s.name)
            var o = highlighted.isEmpty || highlighted.contains(s.index) ? 1.0 : 0.2
            if env.matcher.isActive, let sel = model.seriesSelection(s.index), !env.matcher.isSelected(sel),
               !(0..<n).contains(where: { env.matcher.isSelected(model.selection(category: $0, series: s.index)) }) { o *= 0.3 }
            if model.hasBaseline {
                ctx.stroke(polygon(s.baseline), with: .color(color.opacity(0.3 * o)), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            }
            let p = polygon(s.values)
            if fill { ctx.fill(p, with: .color(color.opacity(0.14 * o))) }
            let dash: [CGFloat] = st.usesPatterns ? [[], [7, 3], [2, 3.5], [9, 3, 2, 3]][s.index % 4] : []
            ctx.stroke(p, with: .color(color.opacity(o)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash))
            if markers {
                let shape: MarkerShape = st.usesPatterns ? .forSeries(s.index) : .circle
                for i in 0..<n {
                    guard let v = s.values[i] else { continue }
                    let e = env.matcher.emphasis(model.selection(category: i, series: s.index))
                    let pt = G.point(i, n, v)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(st.card))
                    shape.draw(in: ctx, center: pt, size: 5.5, color: color.opacity(o * e))
                }
            }
        }
        // Ring values along the first spoke.
        if env.f.bool("radar", "showAxisLabels", true), G.R > 80 {
            let fmt = model.series.first?.format ?? ""
            for t in G.scale.ticks where t > G.scale.lower {
                let pt = G.point(0, n, t)
                let text = AxisFormatter.label(t, format: fmt)
                let sz = ChartText.size(text, fontSize: fs - 1)
                ctx.fill(Path(roundedRect: CGRect(x: pt.x + 3, y: pt.y - sz.height / 2, width: sz.width + 4, height: sz.height), cornerRadius: 2),
                         with: .color(st.card.opacity(0.75)))
                ctx.flowText(text, at: CGPoint(x: pt.x + 5, y: pt.y), anchor: .leading, size: fs - 1, color: st.secondary)
            }
        }
        if G.showLabels {
            let stepEvery = max(1, Int((CGFloat(n) * (fs + 4) / (2 * .pi * G.R)).rounded(.up)))
            for i in stride(from: 0, to: n, by: stepEvery) {
                let a = G.angle(i, n)
                let pt = CGPoint(x: G.c.x + (G.R + 6) * CGFloat(cos(a)), y: G.c.y + (G.R + 6) * CGFloat(sin(a)))
                let cx = cos(a), sy = sin(a)
                let anchor = UnitPoint(x: abs(cx) < 0.2 ? 0.5 : (cx > 0 ? 0 : 1), y: abs(sy) < 0.2 ? 0.5 : (sy > 0 ? 0 : 1))
                let e = env.matcher.isActive ? env.matcher.emphasis(model.selection(category: i)) : 1
                ctx.flowText(ChartText.truncated(model.categories[i].label, fontSize: fs, width: 84), at: pt, anchor: anchor, size: fs,
                             color: st.secondary.opacity(max(e, 0.5)))
            }
        }
    }
}
