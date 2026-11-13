import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Axis options (`xAxis` / `yAxis` cards) shared by the statistical charts.
struct StatAxisOptions {
    let show: Bool
    /// nil = no title; empty = use the chart's default caption.
    let title: String?
    let min: Double?, max: Double?
    let units: DisplayUnits
    let decimals: Int?
    let gridlines: Bool
    let size: CGFloat

    init(card: String, style: ChartStyle, gridlines defaultGrid: Bool) {
        let f = style.format
        show = f.bool(card, "show", true)
        title = f.bool(card, "showTitle", false) ? f.string(card, "title", "") : nil
        min = f.value(card, "min")?.doubleValue
        max = f.value(card, "max")?.doubleValue
        units = DisplayUnits(f.string(card, "displayUnits", "auto"))
        decimals = f.decimals(card)
        gridlines = f.bool(card, "gridlines", defaultGrid)
        size = style.size(card)
    }
}

struct StatTick { let pos: Double; let label: String }

struct StatRefLine: Identifiable {
    let id: Int
    let value: Double
    let label: String
    let color: Color
    let dash: [CGFloat]
}

/// Converts data coordinates of a statistical plot into overlay points.
struct StatMap {
    let plot: CGRect
    private let x0: CGFloat, kx: CGFloat, xLo: Double
    private let y0: CGFloat, ky: CGFloat, yLo: Double

    init(proxy: ChartProxy, plot: CGRect, x: ClosedRange<Double>, y: ClosedRange<Double>) {
        self.plot = plot
        xLo = x.lowerBound; yLo = y.lowerBound
        x0 = proxy.position(forX: x.lowerBound) ?? 0
        kx = ((proxy.position(forX: x.upperBound) ?? plot.width) - x0) / CGFloat(Swift.max(x.upperBound - x.lowerBound, 1e-12))
        y0 = proxy.position(forY: y.lowerBound) ?? plot.height
        ky = ((proxy.position(forY: y.upperBound) ?? 0) - y0) / CGFloat(Swift.max(y.upperBound - y.lowerBound, 1e-12))
    }
    func x(_ v: Double) -> CGFloat { plot.minX + x0 + CGFloat(v - xLo) * kx }
    func y(_ v: Double) -> CGFloat { plot.minY + y0 + CGFloat(v - yLo) * ky }
    func point(_ xv: Double, _ yv: Double) -> CGPoint { CGPoint(x: x(xv), y: y(yv)) }
    func rect(x0 a: Double, x1 b: Double, y0 c: Double, y1 d: Double) -> CGRect {
        let p = point(a, c), q = point(b, d)
        return CGRect(x: Swift.min(p.x, q.x), y: Swift.min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }
}

enum StatSupport {
    /// Reference lines from the Analytics pane (constant / min / max / average / median / percentile).
    static func refLines(spec: VisualSpec, values: [Double], format: String, style: ChartStyle) -> [StatRefLine] {
        var out: [StatRefLine] = []
        for (i, item) in spec.analytics.enumerated() {
            let v: Double?, name: String
            switch item.kind {
            case .constantLine: v = item.value; name = ""
            case .minLine: v = values.min(); name = "Min"
            case .maxLine: v = values.max(); name = "Max"
            case .averageLine: v = ChartMath.mean(values); name = "Average"
            case .medianLine: v = ChartMath.median(values); name = "Median"
            case .percentileLine: v = ChartMath.percentile(values, item.value); name = "P\(Int(item.value))"
            default: continue
            }
            guard let raw = v else { continue }
            let title = item.name.isEmpty ? name : item.name
            let text = AxisFormatter.label(raw, units: .auto, format: format)
            let s = item.style.lowercased()
            out.append(StatRefLine(id: i, value: raw, label: item.showLabel ? (title.isEmpty ? text : "\(title) \(text)") : "",
                                   color: item.color.flatMap { HexColor.rgb($0) != nil ? Color(hex: $0) : nil } ?? style.secondary,
                                   dash: s.hasPrefix("solid") ? [] : (s.hasPrefix("dotted") ? [1.5, 3.5] : [5, 4])))
        }
        return out
    }

    /// Keeps the ticks whose labels fit side by side along `width` points.
    static func thin(_ ticks: [StatTick], domain: ClosedRange<Double>, width: CGFloat, fontSize: CGFloat) -> [StatTick] {
        let span = Swift.max(domain.upperBound - domain.lowerBound, 1e-12)
        let sorted = ticks.filter { domain.contains($0.pos) }.sorted { $0.pos < $1.pos }
        guard sorted.count > 1 else { return sorted }
        func px(_ t: StatTick) -> CGFloat { CGFloat((t.pos - domain.lowerBound) / span) * width }
        let widths = sorted.map { ChartText.size($0.label, fontSize: fontSize).width }
        // Uniform stride keeps the rhythm of the axis regular.
        let maxW = widths.max() ?? 0
        let gap = (px(sorted[sorted.count - 1]) - px(sorted[0])) / CGFloat(sorted.count - 1)
        let step = Swift.max(1, Int(((maxW + 10) / Swift.max(gap, 0.01)).rounded(.up)))
        return sorted.enumerated().filter { i, t in
            i % step == 0 && px(t) + widths[i] / 2 <= width + 14 && px(t) - widths[i] / 2 >= -34
        }.map(\.element)
    }

    /// Category label for a row: the formatted values of `columns`, joined.
    static func label(data: VisualData, row: Int, columns: [Int]) -> String {
        columns.map { c in
            let v = data.table[row, c]
            return v.isNull ? "(Blank)" : ValueFormatter.format(v, data.formats[safe: c] ?? "")
        }.joined(separator: " ")
    }

    static func caption(_ data: VisualData, _ col: Int) -> String {
        (data.fields[safe: col] ?? nil)?.caption ?? data.table.columns[safe: col]?.name ?? ""
    }
}

/// Sequential colour scale for heat-style charts: theme minimum → maximum (optionally through the
/// theme centre), with per-visual overrides `<card>.minColor` / `<card>.maxColor`.
struct StatColorScale {
    let lo: Double, hi: Double
    let stops: [String]

    init(style: ChartStyle, card: String, values: [Double]) {
        let f = style.format
        lo = f.value(card, "min")?.doubleValue ?? values.min() ?? 0
        hi = f.value(card, "max")?.doubleValue ?? values.max() ?? 1
        let a = f.string(card, "minColor", style.theme.minimum), b = f.string(card, "maxColor", style.theme.maximum)
        stops = f.bool(card, "threeColor", false) ? [a, f.string(card, "midColor", style.theme.center), b] : [a, b]
    }

    init(lo: Double, hi: Double, stops: [String]) {
        self.lo = lo; self.hi = hi; self.stops = stops
    }
    func fraction(_ v: Double) -> Double { hi > lo ? Swift.max(0, Swift.min(1, (v - lo) / (hi - lo))) : 1 }
    func hex(at t: Double) -> String {
        let k = Swift.max(0, Swift.min(1, t))
        if stops.count == 3 { return k < 0.5 ? HexColor.lerp(stops[0], stops[1], k * 2) : HexColor.lerp(stops[1], stops[2], (k - 0.5) * 2) }
        return HexColor.lerp(stops[0], stops[1], k)
    }
    func color(_ v: Double) -> Color { Color(hex: hex(at: fraction(v))) }
    var gradient: Gradient { Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { Color(hex: hex(at: $0)) }) }
}

/// A vertical Swift Charts plot on numeric axes with the standard value axis, thinned category /
/// numeric x labels, axis titles, reference lines, an overlay canvas and the interaction layer.
struct StatPlot<Marks: ChartContent>: View {
    let spec: VisualSpec
    let context: VisualContext
    let style: ChartStyle
    let xDomain: ClosedRange<Double>
    let xTicks: [StatTick]
    var xDefaultTitle = ""
    /// Data extent along the value axis.
    let yExtent: ClosedRange<Double>
    var includeZero = false
    var yFormat = ""
    var yDefaultTitle = ""
    /// Values the Analytics-pane statistics are computed over.
    var refValues: [Double] = []
    var allowsLasso = true
    var snapRadius: CGFloat = 0
    var signature = 0
    let hits: (StatMap) -> [ChartHit]
    var draw: ((GraphicsContext, StatMap) -> Void)?
    @ChartContentBuilder let marks: () -> Marks

    var body: some View {
        GeometryReader { geo in
            let sc = ChartSizeClass(geo.size)
            let xo = StatAxisOptions(card: "xAxis", style: style, gridlines: false)
            let yo = StatAxisOptions(card: "yAxis", style: style, gridlines: true)
            let refs = StatSupport.refLines(spec: spec, values: refValues, format: yFormat, style: style)
            let lo = min(yExtent.lowerBound, refs.map(\.value).min() ?? yExtent.lowerBound)
            let hi = max(yExtent.upperBound, refs.map(\.value).max() ?? yExtent.upperBound)
            let scale = AxisFormatter.niceScale(dataMin: lo, dataMax: hi, includeZero: includeZero, fixedMin: yo.min, fixedMax: yo.max,
                                                targetTicks: ChartSizeClass.tickCount(geo.size.height - 36))
            let showX = sc.showAxisLabels && xo.show, showY = sc.showAxisLabels && yo.show
            let ticks = showX ? StatSupport.thin(xTicks, domain: xDomain, width: geo.size.width - (showY ? 44 : 4), fontSize: xo.size) : []
            let xTitle = sc.showAxisTitles ? xo.title.map { $0.isEmpty ? xDefaultTitle : $0 } : nil
            let yTitle = sc.showAxisTitles ? yo.title.map { $0.isEmpty ? yDefaultTitle : $0 } : nil
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    if let t = yTitle, !t.isEmpty {
                        Text(t).font(style.font()).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
                            .rotationEffect(.degrees(-90)).frame(width: style.labelSize + 4).frame(maxHeight: .infinity)
                    }
                    chart(scale: scale, refs: refs, ticks: ticks, xo: xo, yo: yo, showY: showY)
                }
                if let t = xTitle, !t.isEmpty { Text(t).font(style.font()).foregroundStyle(style.secondary).lineLimit(1) }
            }
        }
    }

    private func chart(scale: AxisScale, refs: [StatRefLine], ticks: [StatTick], xo: StatAxisOptions, yo: StatAxisOptions, showY: Bool) -> some View {
        let plotBG = style.format.color("plotArea", "background", "#00000000")
        return Chart {
            marks()
            ForEach(refs) { l in
                RuleMark(y: .value("ref", l.value))
                    .foregroundStyle(l.color).lineStyle(StrokeStyle(lineWidth: 1, dash: l.dash))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        if !l.label.isEmpty {
                            Text(l.label).font(style.font(style.labelSize - 1, weight: .medium)).foregroundStyle(l.color)
                                .padding(.horizontal, 3).background(style.card.opacity(0.82), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                    .accessibilityLabel(l.label.isEmpty ? "Reference line" : l.label)
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: [xDomain.lowerBound, xDomain.upperBound])
        .chartYScale(domain: [scale.lower, scale.upper])
        .chartXAxis {
            AxisMarks(position: .bottom, values: ticks.map(\.pos)) { v in
                if xo.gridlines { AxisGridLine(stroke: StrokeStyle(lineWidth: style.gridWidth)).foregroundStyle(style.grid) }
                if let t = ticks[safe: v.index] {
                    AxisValueLabel(anchor: .top) {
                        Text(t.label).font(style.font(xo.size)).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.ticks) { v in
                if yo.gridlines { AxisGridLine(stroke: StrokeStyle(lineWidth: style.gridWidth)).foregroundStyle(style.grid) }
                if showY, let d = v.as(Double.self) {
                    AxisValueLabel {
                        Text(AxisFormatter.label(d, units: yo.units, decimals: yo.decimals, format: yFormat))
                            .font(style.font(yo.size).monospacedDigit()).foregroundStyle(style.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(plotBG) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let map = StatMap(proxy: proxy, plot: geo[anchor], x: xDomain, y: scale.lower...scale.upper)
                    ZStack(alignment: .topLeading) {
                        if let draw {
                            Canvas { ctx, _ in draw(ctx, map) }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                        if context.isInteractive {
                            ChartInteractionLayer(hits: hits(map), spec: spec, context: context, allowsLasso: allowsLasso, snapRadius: snapRadius)
                        }
                    }
                }
            }
        }
        .animation(context.isInteractive ? Design.Motion.standard : nil, value: signature)
    }
}
