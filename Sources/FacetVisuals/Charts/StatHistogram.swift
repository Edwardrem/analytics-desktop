import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Bins a raw numeric column. An optional category column splits the bins into stacked or overlaid series.
struct HistogramModel {
    /// Largest fixed bin count the `histogram.bins` key accepts.
    static let maxBins = 200
    struct Series { let index: Int; let name: String; let value: Value?; var counts: [Double] }
    struct Bar: Identifiable { let id: Int; let series: Int; let bin: Int; let x0: Double, x1: Double; let y0: Double, y1: Double; let count: Double; let isTop: Bool }

    var edges: [Double] = []
    var series: [Series] = []
    var bars: [Bar] = []
    var total = 0.0
    var values: [Double] = []
    var format = ""
    var caption = ""
    var categoryField: FieldRef?
    var percent = false
    var maxY = 1.0

    init(spec: VisualSpec, data: VisualData, style: ChartStyle) {
        guard let col = data.indices(.values).first, col < data.table.columnCount else { return }
        let f = style.format
        format = data.formats[safe: col] ?? ""
        caption = StatSupport.caption(data, col)
        let catCol = data.indices(.category).first.flatMap { $0 < data.table.columnCount ? $0 : nil }
        categoryField = catCol.flatMap { data.fields[safe: $0] ?? nil }
        var rows: [(v: Double, s: Int)] = []
        var index: [Value: Int] = [:]
        for r in 0..<data.table.rowCount {
            guard let v = data.table[r, col].asDouble, v.isFinite else { continue }
            var si = 0
            if let c = catCol {
                let key = data.table[r, c]
                if let i = index[key] { si = i } else {
                    si = series.count; index[key] = si
                    series.append(Series(index: si, name: key.isNull ? "(Blank)" : ValueFormatter.format(key, data.formats[safe: c] ?? ""), value: key, counts: []))
                }
            }
            rows.append((v, si))
        }
        if catCol == nil { series = [Series(index: 0, name: caption, value: nil, counts: [])] }
        values = rows.map(\.v)
        guard let lo = values.min(), let hi = values.max() else { return }
        total = Double(values.count)

        // Bin count: explicit, else Freedman–Diaconis with a Sturges fallback.
        // A fixed count is capped at `HistogramModel.maxBins` so a stray value can't stall the render.
        let fixedBins = f.int("histogram", "bins", 0, in: 0...HistogramModel.maxBins)
        var bins = fixedBins
        if bins <= 0 {
            let n = Double(values.count)
            let iqr = (ChartMath.percentile(values, 75) ?? hi) - (ChartMath.percentile(values, 25) ?? lo)
            let h = 2 * iqr * pow(n, -1.0 / 3)
            let wanted = h > 0 ? ((hi - lo) / h).rounded(.up) : log2(max(n, 1)).rounded(.up) + 1
            bins = FormatNumber.int(wanted, in: 5...40) ?? 5
        }
        let step: Double
        let start: Double
        if hi > lo {
            step = fixedBins > 0 ? (hi - lo) / Double(bins) : AxisFormatter.niceStep((hi - lo) / Double(bins))
            start = fixedBins > 0 ? lo : (lo / step).rounded(.down) * step
        } else { step = 1; start = lo - 0.5 }
        let count = max(1, Int(((hi - start) / step).rounded(.down)) + 1)
        let binCount = start + Double(count - 1) * step >= hi && count > 1 && fixedBins > 0 ? count - 1 : count
        edges = (0...binCount).map { start + Double($0) * step }
        for i in series.indices { series[i].counts = Array(repeating: 0, count: binCount) }
        for row in rows {
            let b = min(binCount - 1, max(0, Int((row.v - start) / step)))
            series[row.s].counts[b] += 1
        }
        percent = f.string("histogram", "showAs", "count") == "percent"
        let stacked = f.bool("histogram", "stacked", true)
        let scale = percent ? 1 / max(total, 1) : 1
        let inset = step * 0.035
        var id = 0
        maxY = 0
        for b in 0..<binCount {
            var acc = 0.0
            let last = series.lastIndex { $0.counts[b] > 0 }
            for s in series where s.counts[b] > 0 {
                let c = s.counts[b] * scale
                let y0 = stacked ? acc : 0
                bars.append(Bar(id: id, series: s.index, bin: b, x0: edges[b] + inset, x1: edges[b + 1] - inset, y0: y0, y1: y0 + c,
                                count: s.counts[b], isTop: !stacked || s.index == last))
                id += 1; acc += c
                maxY = max(maxY, y0 + c)
            }
        }
        if maxY == 0 { maxY = 1 }
    }

    func rangeLabel(_ b: Int) -> String {
        "\(AxisFormatter.label(edges[b], units: .none, format: format)) – \(AxisFormatter.label(edges[b + 1], units: .none, format: format))"
    }
    func selection(_ s: Int) -> DataPointSelection? {
        guard let f = categoryField, let v = series[safe: s]?.value else { return nil }
        return DataPointSelection(fields: [f], values: [v])
    }
}

struct HistogramView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    var body: some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        let H = HistogramModel(spec: spec, data: data, style: style)
        let items = H.series.map { LegendItem(id: $0.index, name: $0.name, color: colors.seriesColor($0.index, name: $0.name), selection: H.selection($0.index)) }
        let matcher = SelectionMatcher(context.selection)
        let stacked = style.format.bool("histogram", "stacked", true)
        let radius = CGFloat(style.format.double("bars", "cornerRadius", 2))
        let yFormat = H.percent ? "0%" : "#,0"
        ChartScaffold(spec: spec, context: context, items: items) { highlighted in
            StatPlot(spec: spec, context: context, style: style,
                     xDomain: (H.edges.first ?? 0)...(H.edges.last ?? 1),
                     xTicks: H.edges.map { StatTick(pos: $0, label: AxisFormatter.label($0, units: .auto, format: H.format)) },
                     xDefaultTitle: H.caption, yExtent: 0...H.maxY, includeZero: true, yFormat: yFormat,
                     yDefaultTitle: H.percent ? "Share" : "Count", refValues: H.values, signature: H.bars.count &* 31 &+ Int(H.total),
                     hits: { map in
                         H.bars.map { b in
                             ChartHit(id: b.id, rect: map.rect(x0: b.x0, x1: b.x1, y0: b.y0, y1: b.y1), selection: H.selection(b.series),
                                      tooltip: TooltipContent(title: H.rangeLabel(b.bin), rows: [
                                          .init(color: colors.seriesColor(b.series, name: H.series[b.series].name), label: H.series.count > 1 ? H.series[b.series].name : "Count",
                                                value: ValueFormatter.format(.double(b.count), "#,0"), isEmphasized: true),
                                          .init(label: "Share", value: AxisFormatter.label(b.count / max(H.total, 1), format: "0.0%")),
                                      ]))
                         }
                     },
                     draw: { ctx, map in
                         if style.usesPatterns {
                             for b in H.bars where ChartPattern.forSeries(b.series) != .solid {
                                 ChartPattern.forSeries(b.series).draw(in: ctx, clip: Path(map.rect(x0: b.x0, x1: b.x1, y0: b.y0, y1: b.y1)), color: style.patternInk)
                             }
                         }
                         guard style.format.bool("dataLabels", "show", false), map.plot.width >= 180 else { return }
                         let fs = style.size("dataLabels", style.labelSize - 1)
                         var placer = DataLabelPlacer(bounds: map.plot.insetBy(dx: -2, dy: -fs - 4), fontSize: fs)
                         let color = style.format.value("dataLabels", "color")?.stringValue.map { Color(hex: $0) } ?? style.foreground.opacity(0.85)
                         for b in H.bars where b.isTop && stacked || !stacked {
                             let total = stacked ? H.series.reduce(0) { $0 + $1.counts[b.bin] } : b.count
                             let text = H.percent ? AxisFormatter.label(total / max(H.total, 1), format: "0.0%")
                                 : AxisFormatter.label(total, units: DisplayUnits(style.format.string("dataLabels", "displayUnits", "auto")),
                                                       decimals: style.format.decimals("dataLabels"))
                             let r = map.rect(x0: b.x0, x1: b.x1, y0: b.y0, y1: b.y1)
                             placer.place(text, color: color, candidates: [CGPoint(x: r.midX, y: r.minY - fs / 2 - 3)])
                         }
                         placer.draw(in: ctx, leaderColor: style.secondary)
                     }) {
                ForEach(H.bars) { b in
                    let name = H.series[safe: b.series]?.name ?? ""
                    let emphasis = (H.selection(b.series).map { matcher.emphasis($0) } ?? 1) * (highlighted.isEmpty || highlighted.contains(b.series) ? 1 : 0.22)
                    RectangleMark(xStart: .value("x0", b.x0), xEnd: .value("x1", b.x1), yStart: .value("y0", b.y0), yEnd: .value("y1", b.y1))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: b.isTop ? radius : 0, topTrailingRadius: b.isTop ? radius : 0, style: .continuous))
                        .foregroundStyle(colors.seriesColor(b.series, name: name))
                        .opacity((stacked || H.series.count == 1 ? 1 : 0.62) * emphasis)
                        .accessibilityLabel("\(name), \(H.rangeLabel(b.bin))")
                        .accessibilityValue("\(Int(b.count))")
                }
                RuleMark(y: .value("zero", 0.0)).foregroundStyle(style.baseline).lineStyle(StrokeStyle(lineWidth: style.gridWidth * 1.5))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Histogram of \(H.caption): \(Int(H.total)) values in \(max(0, H.edges.count - 1)) bins from \(AxisFormatter.label(H.edges.first ?? 0, format: H.format)) to \(AxisFormatter.label(H.edges.last ?? 0, format: H.format)).")
    }
}

// MARK: - Box plot

struct BoxPlotModel {
    struct Box: Identifiable {
        let id: Int
        let group: Int, series: Int
        let center: Double, half: Double
        let low: Double, q1: Double, median: Double, q3: Double, high: Double, mean: Double
        let count: Int
        let outliers: [Double]
    }
    var groups: [(label: String, value: Value?)] = []
    var series: [(name: String, col: Int)] = []
    var boxes: [Box] = []
    var extent: ClosedRange<Double> = 0...1
    var all: [Double] = []
    var format = ""
    var categoryField: FieldRef?
    var categoryTitle = ""

    init(data: VisualData) {
        let cols = data.indices(.values).filter { $0 < data.table.columnCount }
        guard !cols.isEmpty else { return }
        series = cols.map { (StatSupport.caption(data, $0), $0) }
        format = data.formats[safe: cols[0]] ?? ""
        let catCol = data.indices(.category).first.flatMap { $0 < data.table.columnCount ? $0 : nil }
        categoryField = catCol.flatMap { data.fields[safe: $0] ?? nil }
        categoryTitle = catCol.map { StatSupport.caption(data, $0) } ?? ""
        var index: [Value: Int] = [:]
        var samples: [[[Double]]] = [] // group → series → values
        if catCol == nil { groups = [("All", nil)]; samples = [Array(repeating: [], count: cols.count)] }
        for r in 0..<data.table.rowCount {
            var g = 0
            if let c = catCol {
                let key = data.table[r, c]
                if let i = index[key] { g = i } else {
                    g = groups.count; index[key] = g
                    groups.append((key.isNull ? "(Blank)" : ValueFormatter.format(key, data.formats[safe: c] ?? ""), key))
                    samples.append(Array(repeating: [], count: cols.count))
                }
            }
            for (s, col) in cols.enumerated() { if let v = data.table[r, col].asDouble, v.isFinite { samples[g][s].append(v) } }
        }
        let ns = Double(cols.count)
        let slot = 0.7 / ns
        var lo = Double.infinity, hi = -Double.infinity, id = 0
        for (g, perSeries) in samples.enumerated() {
            for (s, vals) in perSeries.enumerated() where !vals.isEmpty {
                let q1 = ChartMath.percentile(vals, 25) ?? 0, q3 = ChartMath.percentile(vals, 75) ?? 0
                let fenceLo = q1 - 1.5 * (q3 - q1), fenceHi = q3 + 1.5 * (q3 - q1)
                let inside = vals.filter { $0 >= fenceLo && $0 <= fenceHi }
                let center = Double(g) - 0.35 + slot * (Double(s) + 0.5)
                boxes.append(Box(id: id, group: g, series: s, center: center, half: slot * (ns > 1 ? 0.4 : 0.36),
                                 low: inside.min() ?? q1, q1: q1, median: ChartMath.median(vals) ?? q1, q3: q3, high: inside.max() ?? q3,
                                 mean: ChartMath.mean(vals) ?? q1, count: vals.count, outliers: vals.filter { $0 < fenceLo || $0 > fenceHi }))
                id += 1
                lo = min(lo, vals.min() ?? lo); hi = max(hi, vals.max() ?? hi)
                all += vals
            }
        }
        if lo <= hi { extent = lo...hi }
    }

    func selection(_ g: Int) -> DataPointSelection? {
        guard let f = categoryField, let v = groups[safe: g]?.value else { return nil }
        return DataPointSelection(fields: [f], values: [v])
    }
}

struct BoxPlotView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    var body: some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        let M = BoxPlotModel(data: data)
        let f = style.format
        let showOutliers = f.bool("boxPlot", "showOutliers", true), showMean = f.bool("boxPlot", "showMean", false)
        let matcher = SelectionMatcher(context.selection)
        let items = M.series.enumerated().map { LegendItem(id: $0.offset, name: $0.element.name, color: colors.seriesColor($0.offset, name: $0.element.name)) }
        func color(_ b: BoxPlotModel.Box) -> Color {
            colors.pointColor(series: b.series, seriesName: M.series[b.series].name, category: M.groups[b.group].label, value: b.median)
        }
        func fmt(_ v: Double) -> String { ValueFormatter.format(.double(v), M.format.isEmpty ? "#,0.##" : M.format) }
        let lo = showOutliers ? M.extent.lowerBound : (M.boxes.map(\.low).min() ?? 0)
        let hi = showOutliers ? M.extent.upperBound : (M.boxes.map(\.high).max() ?? 1)
        return ChartScaffold(spec: spec, context: context, items: items) { highlighted in
            StatPlot(spec: spec, context: context, style: style,
                     xDomain: -0.5...(Double(max(M.groups.count, 1)) - 0.5),
                     xTicks: M.groups.enumerated().map { StatTick(pos: Double($0.offset), label: ChartText.truncated($0.element.label, fontSize: style.labelSize, width: 110)) },
                     xDefaultTitle: M.categoryTitle, yExtent: lo...max(hi, lo + 1e-9), includeZero: lo >= 0 && (hi - lo) > 0.5 * hi,
                     yFormat: M.format, yDefaultTitle: M.series.first?.name ?? "", refValues: M.all, signature: M.all.count,
                     hits: { map in
                         M.boxes.map { b in
                             var r = map.rect(x0: b.center - b.half, x1: b.center + b.half, y0: b.low, y1: b.high)
                             if r.height < 6 { r = r.insetBy(dx: 0, dy: -3) }
                             return ChartHit(id: b.id, rect: r, selection: M.selection(b.group),
                                             tooltip: TooltipContent(title: M.groups[b.group].label + (M.series.count > 1 ? " · \(M.series[b.series].name)" : ""), rows: [
                                                 .init(label: "Maximum", value: fmt(b.high)), .init(label: "Upper quartile", value: fmt(b.q3)),
                                                 .init(color: color(b), label: "Median", value: fmt(b.median), isEmphasized: true),
                                                 .init(label: "Lower quartile", value: fmt(b.q1)), .init(label: "Minimum", value: fmt(b.low)),
                                                 .init(label: "Mean", value: fmt(b.mean)), .init(label: "Count", value: "\(b.count)"),
                                             ] + (b.outliers.isEmpty ? [] : [.init(label: "Outliers", value: "\(b.outliers.count)")])),
                                             copyText: fmt(b.median))
                         }
                     },
                     draw: { ctx, map in
                         for b in M.boxes {
                             let o = (M.selection(b.group).map { matcher.emphasis($0) } ?? 1) * (highlighted.isEmpty || highlighted.contains(b.series) ? 1 : 0.22)
                             let r = map.rect(x0: b.center - b.half, x1: b.center + b.half, y0: b.q1, y1: b.q3)
                             let path = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: min(2.5, r.height / 2), style: .continuous)
                             if style.usesPatterns { ChartPattern.forSeries(b.series).draw(in: ctx, clip: path, color: color(b).opacity(0.5)) }
                             ctx.stroke(path, with: .color(color(b).opacity(o)), lineWidth: 1.25)
                         }
                         guard f.bool("dataLabels", "show", false), map.plot.width >= 180 else { return }
                         let fs = style.size("dataLabels", style.labelSize - 1)
                         var placer = DataLabelPlacer(bounds: map.plot.insetBy(dx: -40, dy: -2), fontSize: fs)
                         let c = f.value("dataLabels", "color")?.stringValue.map { Color(hex: $0) } ?? style.foreground.opacity(0.85)
                         for b in M.boxes {
                             let text = AxisFormatter.label(b.median, units: DisplayUnits(f.string("dataLabels", "displayUnits", "auto")),
                                                            decimals: f.decimals("dataLabels"), format: M.format)
                             let p = map.point(b.center + b.half, b.median)
                             placer.place(text, color: c, candidates: [CGPoint(x: p.x + ChartText.size(text, fontSize: fs).width / 2 + 4, y: p.y)])
                         }
                         placer.draw(in: ctx, leaderColor: style.secondary)
                     }) {
                ForEach(M.boxes) { b in
                    let c = color(b)
                    let o = (M.selection(b.group).map { matcher.emphasis($0) } ?? 1) * (highlighted.isEmpty || highlighted.contains(b.series) ? 1 : 0.22)
                    let label = M.groups[b.group].label + (M.series.count > 1 ? ", \(M.series[b.series].name)" : "")
                    RuleMark(x: .value("c", b.center), yStart: .value("lo", b.low), yEnd: .value("q1", b.q1))
                        .foregroundStyle(c.opacity(o)).lineStyle(StrokeStyle(lineWidth: 1.25)).accessibilityHidden(true)
                    RuleMark(x: .value("c", b.center), yStart: .value("q3", b.q3), yEnd: .value("hi", b.high))
                        .foregroundStyle(c.opacity(o)).lineStyle(StrokeStyle(lineWidth: 1.25)).accessibilityHidden(true)
                    RuleMark(xStart: .value("a", b.center - b.half * 0.45), xEnd: .value("b", b.center + b.half * 0.45), y: .value("lo", b.low))
                        .foregroundStyle(c.opacity(o)).lineStyle(StrokeStyle(lineWidth: 1.25)).accessibilityHidden(true)
                    RuleMark(xStart: .value("a", b.center - b.half * 0.45), xEnd: .value("b", b.center + b.half * 0.45), y: .value("hi", b.high))
                        .foregroundStyle(c.opacity(o)).lineStyle(StrokeStyle(lineWidth: 1.25)).accessibilityHidden(true)
                    RectangleMark(xStart: .value("x0", b.center - b.half), xEnd: .value("x1", b.center + b.half), yStart: .value("q1", b.q1), yEnd: .value("q3", b.q3))
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        .foregroundStyle(c.opacity(0.2 * o))
                        .accessibilityLabel(label)
                        .accessibilityValue("Median \(fmt(b.median)), quartiles \(fmt(b.q1)) to \(fmt(b.q3)), range \(fmt(b.low)) to \(fmt(b.high))")
                    RuleMark(xStart: .value("a", b.center - b.half), xEnd: .value("b", b.center + b.half), y: .value("med", b.median))
                        .foregroundStyle(c.opacity(o)).lineStyle(StrokeStyle(lineWidth: 2.25)).accessibilityHidden(true)
                    if showOutliers {
                        ForEach(Array(b.outliers.prefix(300).enumerated()), id: \.offset) { _, v in
                            PointMark(x: .value("c", b.center), y: .value("v", v))
                                .symbol { Circle().strokeBorder(c.opacity(0.75 * o), lineWidth: 1).frame(width: 5, height: 5) }
                                .accessibilityLabel("\(label) outlier").accessibilityValue(fmt(v))
                        }
                    }
                    if showMean {
                        PointMark(x: .value("c", b.center), y: .value("mean", b.mean))
                            .symbol(.diamond).symbolSize(34).foregroundStyle(style.foreground.opacity(0.8 * o))
                            .accessibilityLabel("\(label) mean").accessibilityValue(fmt(b.mean))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Box plot of \(M.series.map(\.name).joined(separator: ", ")) across \(M.groups.count) group\(M.groups.count == 1 ? "" : "s"), \(M.all.count) values.")
    }
}
