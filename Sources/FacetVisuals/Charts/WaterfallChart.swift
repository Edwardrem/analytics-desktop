import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Waterfall chart: floating increase / decrease bars joined by hairline connectors, ending in a total.
/// With a Breakdown field, each category is a total column and the bars between two categories show
/// which breakdown values moved the total most.
struct WaterfallVisual: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    enum Kind: Int { case increase, decrease, total }
    struct Bar: Identifiable {
        let id: Int
        let label: String
        let v0: Double, v1: Double
        let kind: Kind
        let selection: DataPointSelection?
        let row: Int?
        var delta: Double { v1 - v0 }
    }

    private func bars(_ f: ResolvedFormat) -> [Bar] {
        let t = data.table
        guard let vc = data.indices(.values).first, vc < t.columnCount else { return [] }
        let catCols = data.indices(.category), brCols = data.indices(.breakdown)
        func label(_ r: Int, _ cols: [Int]) -> String { cols.map { data.formatted(row: r, col: $0) }.joined(separator: " ") }
        var out: [Bar] = []
        if brCols.isEmpty {
            var acc = 0.0
            for r in 0..<t.rowCount {
                guard let v = t[r, vc].asDouble, v.isFinite else { continue }
                out.append(Bar(id: out.count, label: label(r, catCols), v0: acc, v1: acc + v, kind: v >= 0 ? .increase : .decrease,
                               selection: SeriesModel.selection(data: data, row: r, columns: catCols), row: r))
                acc += v
            }
            if f.bool("waterfall", "showTotal", true), !out.isEmpty {
                out.append(Bar(id: out.count, label: f.string("waterfall", "totalLabel", "Total"), v0: 0, v1: acc, kind: .total, selection: nil, row: nil))
            }
            return out
        }
        // Breakdown: category totals with the top movers in between.
        var catKeys: [[Value]] = [], catRow: [Int] = [], catIndex: [[Value]: Int] = [:]
        var cells: [[[Value]: (v: Double, row: Int)]] = []
        var brLabels: [[Value]: String] = [:]
        for r in 0..<t.rowCount {
            guard let v = t[r, vc].asDouble, v.isFinite else { continue }
            let ck = catCols.map { t[r, $0] }, bk = brCols.map { t[r, $0] }
            let ci: Int
            if let i = catIndex[ck] { ci = i } else { ci = catKeys.count; catIndex[ck] = ci; catKeys.append(ck); catRow.append(r); cells.append([:]) }
            cells[ci][bk] = ((cells[ci][bk]?.v ?? 0) + v, r)
            brLabels[bk] = label(r, brCols)
        }
        let maxMovers = max(1, Int(f.double("waterfall", "maxBreakdowns", 5)))
        for ci in catKeys.indices {
            let total = cells[ci].values.reduce(0) { $0 + $1.v }
            if ci > 0 {
                let prevTotal = cells[ci - 1].values.reduce(0) { $0 + $1.v }
                var deltas: [(key: [Value], d: Double, row: Int)] = []
                for key in Set(cells[ci].keys).union(cells[ci - 1].keys) {
                    let d = (cells[ci][key]?.v ?? 0) - (cells[ci - 1][key]?.v ?? 0)
                    if d != 0 { deltas.append((key, d, cells[ci][key]?.row ?? cells[ci - 1][key]?.row ?? 0)) }
                }
                deltas.sort { abs($0.d) > abs($1.d) || (abs($0.d) == abs($1.d) && (brLabels[$0.key] ?? "") < (brLabels[$1.key] ?? "")) }
                var acc = prevTotal
                for m in deltas.prefix(maxMovers) {
                    out.append(Bar(id: out.count, label: brLabels[m.key] ?? "", v0: acc, v1: acc + m.d, kind: m.d >= 0 ? .increase : .decrease,
                                   selection: SeriesModel.selection(data: data, row: m.row, columns: brCols), row: m.row))
                    acc += m.d
                }
                let other = total - acc
                if deltas.count > maxMovers, abs(other) > 1e-9 {
                    out.append(Bar(id: out.count, label: "Other", v0: acc, v1: total, kind: other >= 0 ? .increase : .decrease, selection: nil, row: nil))
                }
            }
            out.append(Bar(id: out.count, label: label(catRow[ci], catCols), v0: 0, v1: total, kind: .total,
                           selection: SeriesModel.selection(data: data, row: catRow[ci], columns: catCols), row: nil))
        }
        return out
    }

    private func color(_ k: Kind, _ f: ResolvedFormat) -> Color {
        let theme = context.theme
        switch k {
        case .increase: return f.color("waterfall", "increaseColor", theme.good)
        case .decrease: return f.color("waterfall", "decreaseColor", theme.bad)
        case .total: return f.color("waterfall", "totalColor", theme.dataColors.first ?? theme.accent)
        }
    }

    var body: some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let f = style.format
        let bars = self.bars(f)
        let items = [LegendItem(id: 0, name: "Increase", color: color(.increase, f)), LegendItem(id: 1, name: "Decrease", color: color(.decrease, f)),
                     LegendItem(id: 2, name: "Total", color: color(.total, f))]
        ChartScaffold(spec: spec, context: context, items: items, defaultShow: true) { highlighted in
            GeometryReader { geo in chart(bars, style: style, size: geo.size, highlighted: highlighted) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waterfall chart, \(bars.count) steps." + (bars.last.map { " Ends at \(fmt($0.v1))." } ?? ""))
    }

    private var valueFormat: String { data.indices(.values).first.flatMap { data.formats[safe: $0] } ?? "" }
    private func fmt(_ v: Double) -> String { ValueFormatter.format(.double(v), valueFormat) }

    private func chart(_ bars: [Bar], style: ChartStyle, size: CGSize, highlighted: Set<Int>) -> some View {
        let f = style.format
        let sc = ChartSizeClass(size)
        let extent = bars.flatMap { [$0.v0, $0.v1] }
        let scale = AxisFormatter.niceScale(dataMin: extent.min() ?? 0, dataMax: extent.max() ?? 1, includeZero: true,
                                            fixedMin: f.value("yAxis", "min")?.doubleValue, fixedMax: f.value("yAxis", "max")?.doubleValue,
                                            targetTicks: ChartSizeClass.tickCount(size.height - 36))
        let n = max(bars.count, 1)
        let band = max(4, (size.width - 44) / CGFloat(n))
        let inner = 1 - max(0, min(0.9, f.double("bars", "innerPadding", 30) / 100))
        let fs = style.size("xAxis")
        let axis = CartesianLayout.fitLabels(bars.enumerated().map { .init(pos: Double($0.offset), label: $0.element.label, group: "") }, band: band, fontSize: fs)
        let radius = min(CGFloat(f.double("bars", "cornerRadius", 2.5)), band * inner / 2)
        let matcher = SelectionMatcher(context.selection)
        let window = -0.5...(Double(n) - 0.5)
        func opacity(_ b: Bar) -> Double {
            (b.selection.map { $0.fields.isEmpty ? 1 : matcher.emphasis($0) } ?? (matcher.isActive ? 0.3 : 1))
                * (highlighted.isEmpty || highlighted.contains(b.kind.rawValue) ? 1 : 0.25)
        }
        return Chart {
            ForEach(bars) { b in
                let x = Double(b.id)
                RectangleMark(xStart: .value("x0", x - inner / 2), xEnd: .value("x1", x + inner / 2),
                              yStart: .value("y0", min(b.v0, b.v1)), yEnd: .value("y1", max(b.v0, b.v1)))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .foregroundStyle(color(b.kind, f))
                    .opacity(opacity(b))
                    .accessibilityLabel(b.label)
                    .accessibilityValue(b.kind == .total ? fmt(b.v1) : (b.delta >= 0 ? "up " : "down ") + fmt(abs(b.delta)))
                if b.id < bars.count - 1, f.bool("waterfall", "connectors", true) {
                    RuleMark(xStart: .value("a", x + inner / 2), xEnd: .value("b", x + 1 - inner / 2), y: .value("v", b.v1))
                        .foregroundStyle(style.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: style.gridWidth * 1.5))
                        .accessibilityHidden(true)
                }
            }
            RuleMark(y: .value("zero", 0.0)).foregroundStyle(style.baseline).lineStyle(StrokeStyle(lineWidth: style.gridWidth * 1.5))
                .accessibilityHidden(true)
        }
        .chartLegend(.hidden)
        .chartXScale(domain: [window.lowerBound, window.upperBound])
        .chartYScale(domain: [scale.lower, scale.upper])
        .chartXAxis { ChartAxes.categories(axis, style: style, card: "xAxis", show: sc.showAxisLabels && f.bool("xAxis", "show", true)) }
        .chartYAxis { ChartAxes.numeric(scale, style: style, card: "yAxis", format: valueFormat, position: .leading, showLabels: sc.showAxisLabels) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let map = PlotMap(proxy: proxy, plot: geo[anchor], horizontal: false, window: window, scale: scale)
                    let rects = bars.map { map.rect(c0: Double($0.id) - inner / 2, c1: Double($0.id) + inner / 2, v0: $0.v0, v1: $0.v1) }
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, _ in
                            guard f.bool("dataLabels", "show", true), sc.showDataLabels else { return }
                            let lfs = style.size("dataLabels", style.labelSize - 1)
                            var area = map.plot.insetBy(dx: -2, dy: -2); area.origin.y -= lfs + 2; area.size.height += lfs + 2
                            var placer = DataLabelPlacer(bounds: area, fontSize: lfs)
                            let units = DisplayUnits(f.string("dataLabels", "displayUnits", "auto"))
                            let decimals = f.value("dataLabels", "decimals")?.doubleValue.map { Int($0) }
                            let custom = f.value("dataLabels", "color")?.stringValue.map { Color(hex: $0) }
                            for (b, r) in zip(bars, rects) {
                                let v = b.kind == .total ? b.v1 : b.delta
                                let text = (b.kind != .total && v > 0 ? "+" : "") + AxisFormatter.label(v, units: units, decimals: decimals, format: valueFormat)
                                let sz = ChartText.size(text, fontSize: lfs)
                                let cands = DataLabelPosition.outsideEnd.candidates(bar: r, size: sz, end: v >= 0 ? .top : .bottom)
                                    + DataLabelPosition.outsideEnd.candidates(bar: r, size: sz, end: v >= 0 ? .bottom : .top)
                                placer.place(text, color: custom ?? style.foreground.opacity(0.85), candidates: cands)
                            }
                            placer.draw(in: ctx, leaderColor: .clear)
                        }
                        .allowsHitTesting(false).accessibilityHidden(true)
                        ChartInteractionLayer(hits: zip(bars, rects).map { b, r in
                            ChartHit(id: b.id, rect: r.height < 3 ? r.insetBy(dx: 0, dy: -2) : r, selection: b.selection, tooltip: tooltip(b, f))
                        }, spec: spec, context: context, allowsLasso: true)
                    }
                }
            }
        }
        .animation(context.isInteractive ? Design.Motion.standard : nil, value: bars.map(\.v1))
    }

    private func tooltip(_ b: Bar, _ f: ResolvedFormat) -> TooltipContent {
        var rows: [TooltipContent.Row] = []
        if b.kind == .total {
            rows.append(.init(color: color(.total, f), label: "Total", value: fmt(b.v1), isEmphasized: true))
        } else {
            rows.append(.init(color: color(b.kind, f), label: b.delta >= 0 ? "Increase" : "Decrease", value: (b.delta > 0 ? "+" : "") + fmt(b.delta), isEmphasized: true))
            rows.append(.init(label: "Running total", value: fmt(b.v1)))
        }
        for t in SeriesModel.tooltipFields(data: data, row: b.row) { rows.append(.init(label: t.label, value: t.value)) }
        return TooltipContent(title: b.label, rows: rows)
    }
}
