import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Converts data coordinates of a cartesian chart into points in the chart overlay.
struct PlotMap {
    let plot: CGRect
    let horizontal: Bool
    private let proxy: ChartProxy
    private let catA: CGFloat, catK: CGFloat, catLo: Double
    private let valA: CGFloat, valK: CGFloat, valLo: Double
    private let isLog: Bool

    init(proxy: ChartProxy, plot: CGRect, horizontal: Bool, window: ClosedRange<Double>, scale: AxisScale) {
        self.proxy = proxy; self.plot = plot; self.horizontal = horizontal
        func pos(cat c: Double) -> CGFloat { (horizontal ? proxy.position(forY: c) : proxy.position(forX: c)) ?? 0 }
        func pos(val v: Double) -> CGFloat { (horizontal ? proxy.position(forX: v) : proxy.position(forY: v)) ?? 0 }
        let cSpan = max(window.upperBound - window.lowerBound, 1e-12)
        catLo = window.lowerBound
        catA = pos(cat: window.lowerBound)
        catK = (pos(cat: window.upperBound) - catA) / CGFloat(cSpan)
        valLo = scale.lower
        valA = pos(val: scale.lower)
        valK = (pos(val: scale.upper) - valA) / CGFloat(max(scale.span, 1e-12))
        isLog = scale.isLog
    }

    /// Pixel position along the category axis.
    func cat(_ c: Double) -> CGFloat { (horizontal ? plot.minY : plot.minX) + catA + CGFloat(c - catLo) * catK }
    /// Pixel position along the value axis.
    func val(_ v: Double) -> CGFloat {
        let origin = horizontal ? plot.minX : plot.minY
        if isLog { return origin + ((horizontal ? proxy.position(forX: v) : proxy.position(forY: v)) ?? 0) }
        return origin + valA + CGFloat(v - valLo) * valK
    }
    func point(_ c: Double, _ v: Double) -> CGPoint {
        horizontal ? CGPoint(x: val(v), y: cat(c)) : CGPoint(x: cat(c), y: val(v))
    }
    func rect(c0: Double, c1: Double, v0: Double, v1: Double) -> CGRect {
        let a = point(c0, v0), b = point(c1, v1)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Overlay of `CartesianPanel`: accessibility patterns, data / total / series labels, and interaction.
extension CartesianPanel {
    func overlay(proxy: ChartProxy, L: CartesianLayout, R: CartesianAnalytics.Resolved, window: ClosedRange<Double>,
                 bars: [CartesianLayout.Bar], sc: ChartSizeClass) -> some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let plot = geo[anchor]
                let map = PlotMap(proxy: proxy, plot: plot, horizontal: kind.horizontal, window: window, scale: L.valueScale)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        drawPatterns(ctx, bars: bars, map: map)
                        if sc.showDataLabels { drawLabels(ctx, L: L, bars: bars, map: map, window: window, size: geo.size) }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    if context.isInteractive {
                        ChartInteractionLayer(hits: hits(L: L, bars: bars, map: map, window: window), spec: spec, context: context,
                                              allowsLasso: true, snapRadius: kind.drawsBars ? 0 : 14,
                                              highlight: kind.drawsBars ? .outline : .none) { hit in
                            let c = hit.map { $0.id % 10_000_000 }
                            if !kind.drawsBars, c != hoverCat { hoverCat = c }
                        }
                    }
                }
            }
        }
    }

    // MARK: Hits

    private func barTooltip(_ b: CartesianLayout.Bar, _ L: CartesianLayout) -> TooltipContent {
        let s = model.series[safe: b.series]
        let c = color(series: b.series, cat: b.cat, value: b.value)
        var rows: [TooltipContent.Row] = []
        if model.hasBaseline, let hv = s?.values[safe: b.cat] ?? nil, let total = s?.baseline[safe: b.cat] ?? nil {
            rows.append(.init(color: c, label: s?.name ?? "", value: model.formatted(total, series: b.series)))
            rows.append(.init(color: c.opacity(0.0), label: "Highlighted", value: model.formatted(hv, series: b.series), isEmphasized: true))
        } else {
            rows.append(.init(color: c, label: s?.name ?? "", value: model.formatted(b.value, series: b.series), isEmphasized: true))
        }
        if kind.stacking != .none, let t = L.totals[safe: b.cat], abs(t.sum) > 0 {
            rows.append(.init(label: "Share", value: AxisFormatter.label(b.value / t.sum, format: "0.0%")))
        }
        for f in model.tooltipFields(row: s?.rows[safe: b.cat] ?? nil) { rows.append(.init(label: f.label, value: f.value)) }
        return TooltipContent(title: model.categories[safe: b.cat]?.label ?? "", rows: rows)
    }

    private func categoryTooltip(_ cat: Int, emphasize: Int?) -> TooltipContent {
        var rows: [TooltipContent.Row] = []
        for s in model.series.prefix(14) {
            guard let v = s.values[safe: cat] ?? nil else { continue }
            rows.append(.init(color: color(series: s.index, cat: nil, value: v), label: s.name, value: model.formatted(v, series: s.index),
                              isEmphasized: s.index == emphasize))
        }
        if model.series.count > 14 { rows.append(.init(label: "+\(model.series.count - 14) more", value: "")) }
        let row = (emphasize.flatMap { model.series[safe: $0] } ?? model.series.first)?.rows[safe: cat] ?? nil
        for f in model.tooltipFields(row: row) { rows.append(.init(label: f.label, value: f.value)) }
        return TooltipContent(title: model.categories[safe: cat]?.label ?? "", rows: rows)
    }

    func hits(L: CartesianLayout, bars: [CartesianLayout.Bar], map: PlotMap, window: ClosedRange<Double>) -> [ChartHit] {
        var out: [ChartHit] = []
        if kind.drawsBars {
            // One hit per (category, series) cell; with cross-highlighting the baseline bar spans the cell.
            var seen = Set<Int>()
            for b in bars where b.isBaseline || !model.hasBaseline {
                guard seen.insert(b.cat * 100_000 + b.series).inserted else { continue }
                var r = map.rect(c0: b.c0, c1: b.c1, v0: b.v0, v1: b.v1)
                if r.width < 3 { r = r.insetBy(dx: -(3 - r.width) / 2, dy: 0) }
                if r.height < 3 { r = r.insetBy(dx: 0, dy: -(3 - r.height) / 2) }
                out.append(ChartHit(id: (b.series + 1) * 10_000_000 + b.cat, rect: r,
                                    selection: model.selection(category: b.cat, series: b.series),
                                    tooltip: barTooltip(b, L),
                                    copyText: model.formatted(b.value, series: b.series)))
            }
        } else {
            // Line and area charts: a full-height column per category showing every series…
            for c in model.categories.indices {
                guard let x = L.catPos[safe: c], window.contains(x) else { continue }
                let r = map.rect(c0: x - L.halfBand, c1: x + L.halfBand, v0: L.valueScale.lower, v1: L.valueScale.upper)
                out.append(ChartHit(id: c, rect: r, anchor: CGPoint(x: r.midX, y: r.minY + 8),
                                    selection: model.selection(category: c), tooltip: categoryTooltip(c, emphasize: nil)))
            }
        }
        // …and a precise target on each line point so a single series' point can be picked.
        let dense = L.lines.reduce(0) { $0 + $1.points.count } > 4000
        if !dense, kind.drawsBars || kind.drawsDots || model.series.count > 1 {
            for line in L.lines where !line.isBaseline {
                for p in line.points where window.contains(p.x) {
                    let pt = map.point(p.x, p.y)
                    let r = CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)
                    out.append(ChartHit(id: (line.series + 1) * 10_000_000 + p.cat, path: Path(ellipseIn: r),
                                        selection: model.selection(category: p.cat, series: line.series),
                                        tooltip: categoryTooltip(p.cat, emphasize: line.series),
                                        copyText: model.formatted(p.value, series: line.series)))
                }
            }
        }
        return out
    }

    // MARK: Canvas

    private func drawPatterns(_ ctx: GraphicsContext, bars: [CartesianLayout.Bar], map: PlotMap) {
        guard style.usesPatterns else { return }
        for b in bars where !b.isBaseline {
            let pattern = ChartPattern.forSeries(b.series)
            guard pattern != .solid else { continue }
            pattern.draw(in: ctx, clip: Path(map.rect(c0: b.c0, c1: b.c1, v0: b.v0, v1: b.v1)), color: style.patternInk)
        }
    }

    private func labelText(_ value: Double, series s: Int, cat: Int, share: Double?) -> String {
        let f = style.format
        if let detail = f.value("dataLabels", "detailField")?.stringValue, !detail.isEmpty,
           let col = model.data.fields.firstIndex(where: { $0?.caption == detail || $0?.name == detail }),
           let row = model.series[safe: s]?.rows[safe: cat] ?? nil {
            return model.data.formatted(row: row, col: col)
        }
        if let share { return AxisFormatter.label(share, format: abs(share) < 0.1 ? "0.0%" : "0%") }
        return AxisFormatter.label(value, units: DisplayUnits(f.string("dataLabels", "displayUnits", "auto")),
                                   decimals: f.decimals("dataLabels"),
                                   format: model.series[safe: s]?.format ?? "")
    }

    private func drawLabels(_ ctx: GraphicsContext, L: CartesianLayout, bars: [CartesianLayout.Bar], map: PlotMap,
                            window: ClosedRange<Double>, size: CGSize) {
        let f = style.format
        let fs = style.size("dataLabels", style.labelSize - 1)
        let custom = f.value("dataLabels", "color")?.stringValue.map { Color(hex: $0) }
        let outside = custom ?? style.foreground.opacity(0.85)
        // Labels stay within the plot (plus a little headroom on the side values grow towards).
        var area = map.plot.insetBy(dx: -2, dy: -2)
        if kind.horizontal { area.size.width = size.width - area.minX } else { area.origin.y -= fs + 2; area.size.height += fs + 2 }
        var placer = DataLabelPlacer(bounds: area, fontSize: fs)
        let stacked = kind.stacking != .none

        // Total labels sit above stacks and take priority.
        if options.totalLabels, kind.stacking == .stacked, kind.drawsBars || kind.drawsArea {
            let inner = kind.drawsBars ? (1 - options.innerPadding) / 2 : 0
            var totalPlacer = DataLabelPlacer(bounds: placer.bounds, fontSize: fs, weight: .semibold)
            for (c, t) in L.totals.enumerated() {
                guard let x = L.catPos[safe: c], window.contains(x), t.pos != 0 || t.neg != 0 else { continue }
                let end = t.sum >= 0 ? t.pos : t.neg
                let r = map.rect(c0: x - inner, c1: x + inner, v0: end, v1: end)
                let text = AxisFormatter.label(t.sum, units: DisplayUnits(f.string("totalLabels", "displayUnits", "auto")),
                                               format: model.series.first?.format ?? "")
                let sz = ChartText.size(text, fontSize: fs, weight: .semibold)
                let edge: Edge = kind.horizontal ? (t.sum >= 0 ? .trailing : .leading) : (t.sum >= 0 ? .top : .bottom)
                if let placed = totalPlacer.place(text, color: f.value("totalLabels", "color")?.stringValue.map { Color(hex: $0) } ?? style.foreground,
                                                  candidates: DataLabelPosition.outsideEnd.candidates(bar: r, size: sz, end: edge)) {
                    placer.reserve(placed)
                }
            }
            totalPlacer.draw(in: ctx, leaderColor: style.secondary)
        }

        if options.dataLabels {
            let position = options.dataLabelPosition == .auto && stacked ? DataLabelPosition.insideCenter : options.dataLabelPosition
            for b in bars where !b.isBaseline {
                let r = map.rect(c0: b.c0, c1: b.c1, v0: b.v0, v1: b.v1)
                let share = kind.stacking == .percent ? abs(b.v1 - b.v0) : nil
                let text = labelText(b.value, series: b.series, cat: b.cat, share: share)
                let sz = ChartText.size(text, fontSize: fs)
                let positive = (b.v1 >= b.v0) != options.reverseValue
                let edge: Edge = kind.horizontal ? (positive ? .trailing : .leading) : (positive ? .top : .bottom)
                let cands = position.candidates(bar: r, size: sz, end: edge)
                let fill = color(series: b.series, cat: b.cat, value: b.value)
                for (i, cand) in cands.enumerated() {
                    let isOutside = (position == .auto || position == .outsideEnd) && i == 0
                    if placer.place(text, color: custom ?? (isOutside ? outside : fill.contrastingLabel), candidates: [cand]) != nil { break }
                }
            }
            if !(kind.drawsArea && stacked) {
                for line in L.lines where !line.isBaseline && line.points.count <= 120 {
                    for p in line.points where window.contains(p.x) {
                        let pt = map.point(p.x, p.y)
                        let text = labelText(p.value, series: line.series, cat: p.cat, share: nil)
                        placer.place(text, color: outside, candidates: [CGPoint(x: pt.x, y: pt.y - fs * 0.5 - 6), CGPoint(x: pt.x, y: pt.y + fs * 0.5 + 6)])
                    }
                }
            }
        }

        // Series labels at the right-hand end of each line, nudged apart with leader lines.
        if options.seriesLabels {
            var sp = DataLabelPlacer(bounds: CGRect(origin: .zero, size: size), fontSize: style.labelSize, weight: .medium)
            var ends: [(series: Int, pt: CGPoint)] = []
            for s in Set(L.lines.map(\.series)).sorted() {
                guard let last = L.lines.last(where: { $0.series == s && !$0.isBaseline })?.points.last else { continue }
                ends.append((s, map.point(last.x, last.y)))
            }
            let step = style.labelSize + 3
            for e in ends.sorted(by: { $0.pt.y < $1.pt.y }) {
                guard let name = model.series[safe: e.series]?.name else { continue }
                let text = ChartText.truncated(name, fontSize: style.labelSize, width: 96, weight: .medium)
                let x = map.plot.maxX + 8 + ChartText.size(text, fontSize: style.labelSize, weight: .medium).width / 2
                let c = color(series: e.series, cat: nil, value: nil)
                if sp.place(text, color: c, candidates: [CGPoint(x: x, y: e.pt.y)]) == nil {
                    let nudged = [1, -1, 2, -2, 3, -3, 4, -4, 5, -5].map { CGPoint(x: x + 6, y: e.pt.y + CGFloat($0) * step) }
                    sp.place(text, color: c, candidates: nudged, leaderFrom: CGPoint(x: e.pt.x + 3, y: e.pt.y))
                }
            }
            sp.draw(in: ctx, leaderColor: style.secondary.opacity(0.7))
        }
        placer.draw(in: ctx, leaderColor: style.secondary)
    }
}

