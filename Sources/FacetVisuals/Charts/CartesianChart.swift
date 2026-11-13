import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Bar, column, line, area and combo charts: legend, small multiples and one `CartesianPanel` per panel.
struct CartesianVisual: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    var body: some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let kind = CartesianKind(spec.type) ?? CartesianKind(.clusteredColumn)!
        let options = CartesianOptions(spec: spec, style: style, kind: kind)
        let model = SeriesModel(spec: spec, data: data, lineWell: kind.isCombo ? .lineValues : nil)
        let colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        let items = model.series.map { s in
            LegendItem(id: s.index, name: s.name, color: colors.seriesColor(s.index, name: s.name),
                       marker: (s.isLine || !kind.drawsBars && !kind.drawsArea) ? (style.usesPatterns ? .forSeries(s.index) : .circle) : .roundedSquare,
                       selection: model.seriesSelection(s.index))
        }
        let parts = SeriesModel.partitions(data: data)
        ChartScaffold(spec: spec, context: context, items: items) { highlighted in
            if parts.isEmpty {
                CartesianPanel(spec: spec, context: context, model: model, style: style, colors: colors, options: options,
                               highlighted: highlighted, sharedRange: nil)
            } else {
                let models = parts.map { SeriesModel(spec: spec, data: data, lineWell: kind.isCombo ? .lineValues : nil, partition: $0) }
                let shared = style.format.bool("smallMultiples", "sharedYAxis", true) ? CartesianVisual.sharedRange(models, options) : nil
                SmallMultiplesGrid(partitions: parts, style: style) { p, column in
                    if let i = parts.firstIndex(where: { $0.title == p.title }) {
                        CartesianPanel(spec: spec, context: context, model: models[i], style: style, colors: colors, options: options,
                                       highlighted: highlighted, sharedRange: shared,
                                       hidesValueLabels: shared != nil && column > 0 && !kind.horizontal)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CartesianVisual.summary(spec: spec, model: model))
    }

    static func sharedRange(_ models: [SeriesModel], _ o: CartesianOptions) -> ClosedRange<Double>? {
        guard o.kind.stacking != .percent else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for m in models {
            let L = CartesianLayout(model: m, options: o)
            lo = min(lo, L.valueScale.lower); hi = max(hi, L.valueScale.upper)
        }
        return lo < hi ? lo...hi : nil
    }

    /// One-sentence description for VoiceOver.
    static func summary(spec: VisualSpec, model: SeriesModel) -> String {
        var s = "\(spec.type.displayName), \(model.categories.count) categor\(model.categories.count == 1 ? "y" : "ies"), \(model.series.count) series."
        if let first = model.series.first {
            let pairs = first.values.enumerated().compactMap { i, v in v.map { (i, $0) } }
            if let mx = pairs.max(by: { $0.1 < $1.1 }), let mn = pairs.min(by: { $0.1 < $1.1 }), pairs.count > 1 {
                s += " \(first.name) ranges from \(model.formatted(mn.1, series: 0)) at \(model.categories[mn.0].label) to \(model.formatted(mx.1, series: 0)) at \(model.categories[mx.0].label)."
            }
        }
        return s
    }
}

/// One cartesian plot: Swift Charts marks on numeric axes, plus an overlay for labels, patterns and interaction.
struct CartesianPanel: View {
    let spec: VisualSpec
    let context: VisualContext
    let model: SeriesModel
    let style: ChartStyle
    let colors: ColorResolver
    let options: CartesianOptions
    let highlighted: Set<Int>
    let sharedRange: ClosedRange<Double>?
    /// Small multiples sharing a value axis label it only in the first column.
    var hidesValueLabels = false

    @State var zoom: ClosedRange<Double>?
    @State var hoverCat: Int?

    var kind: CartesianKind { options.kind }
    var matcher: SelectionMatcher { SelectionMatcher(context.selection) }

    var body: some View {
        GeometryReader { geo in
            let sc = ChartSizeClass(geo.size)
            let analytics = CartesianAnalytics(spec: spec, model: model, overlays: context.overlays, kind: kind)
            let valueLength = (kind.horizontal ? geo.size.width : geo.size.height) - 36
            let L = CartesianLayout(model: model, options: options, forecasts: kind.stacking == .none ? context.overlays.forecasts : [],
                                    extraExtent: analytics.extraExtent, sharedRange: sharedRange, valueLength: valueLength,
                                    maxLinePoints: max(200, Int(geo.size.width * 1.5)))
            let R = analytics.resolve(layout: L, model: model, colors: colors, style: style, kind: kind)
            let catLength = max(20, (kind.horizontal ? geo.size.height - 24 : geo.size.width - 44))
            let span = L.catDomain.upperBound - L.catDomain.lowerBound
            // Too many bars for the space: show a window with a minimum bar thickness and let the reader scroll.
            let minBand: CGFloat = kind.stacking == .none ? max(14, CGFloat(model.series.filter { !$0.isLine }.count) * 5 + 4) : 12
            let overflow = kind.drawsBars && model.categories.count > 60 && catLength / CGFloat(span) < minBand
            let maxSpan = overflow ? min(1, max(4, (Double(catLength / minBand)).rounded(.down)) / span) : 1
            let z = zoom ?? 0...maxSpan
            let window = (L.catDomain.lowerBound + z.lowerBound * span)...(L.catDomain.lowerBound + z.upperBound * span)
            let showSlider = (options.zoomSlider || overflow) && geo.size.height > 110
            VStack(spacing: 4) {
                titledChart(L, R, window: window, sc: sc, size: CGSize(width: geo.size.width, height: geo.size.height - (showSlider ? 16 : 0)))
                if showSlider {
                    ZoomSlider(range: Binding(get: { z }, set: { zoom = $0 }), theme: context.theme,
                               minimumSpan: min(maxSpan, max(0.01, 3 / max(span, 1))), maximumSpan: maxSpan)
                        .padding(.horizontal, 4)
                }
            }
            .onScrollWheel(isEnabled: context.isInteractive && (overflow || zoom != nil)) { dx, dy in
                let d = Double(abs(dx) > abs(dy) ? -dx : (kind.horizontal ? -dy : -dy)) / Double(max(catLength, 1)) * (z.upperBound - z.lowerBound)
                let w = z.upperBound - z.lowerBound
                let lo = max(0, min(1 - w, z.lowerBound + d))
                zoom = lo...(lo + w)
            }
        }
    }

    // MARK: Axis titles around the chart

    @ViewBuilder
    private func titledChart(_ L: CartesianLayout, _ R: CartesianAnalytics.Resolved, window: ClosedRange<Double>, sc: ChartSizeClass, size: CGSize) -> some View {
        let catTitle = sc.showAxisTitles ? options.catTitle.map { $0.isEmpty ? model.categoryTitle : $0 } : nil
        let valDefault = model.series.filter { !$0.isLine || !kind.isCombo }.prefix(2).map(\.name).joined(separator: " and ")
        let valTitle = sc.showAxisTitles ? options.valTitle.map { $0.isEmpty ? valDefault : $0 } : nil
        let y2Default = model.series.filter { $0.isLine }.prefix(2).map(\.name).joined(separator: " and ")
        let y2Title = sc.showAxisTitles && L.secondaryScale != nil ? options.y2Title.map { $0.isEmpty ? y2Default : $0 } : nil
        let xTitle = kind.horizontal ? valTitle : catTitle, yTitle = kind.horizontal ? catTitle : valTitle
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let t = yTitle, !t.isEmpty { verticalTitle(t) }
                chart(L, R, window: window, sc: sc, size: size)
                if let t = y2Title, !t.isEmpty { verticalTitle(t) }
            }
            if let t = xTitle, !t.isEmpty {
                Text(t).font(style.font()).foregroundStyle(style.secondary).lineLimit(1)
            }
        }
    }

    private func verticalTitle(_ t: String) -> some View {
        Text(t).font(style.font()).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
            .rotationEffect(.degrees(-90)).frame(width: style.labelSize + 4).frame(maxHeight: .infinity)
    }

    // MARK: Chart

    private func chart(_ L: CartesianLayout, _ R: CartesianAnalytics.Resolved, window: ClosedRange<Double>, sc: ChartSizeClass, size: CGSize) -> some View {
        let o = options
        let fs = style.size(o.catCard)
        let showCat = sc.showAxisLabels && o.showCatAxis
        let showVal = sc.showAxisLabels && o.showValAxis && !hidesValueLabels
        let maxLabel = kind.horizontal ? min(150, size.width * 0.3) : 110
        let catLength = max(20, kind.horizontal ? size.height - 24 : size.width - (showVal ? 44 : 4))
        let axis = showCat ? L.categoryAxis(model: model, options: o, length: catLength, fontSize: fs, window: window, maxLabelWidth: maxLabel) : CartesianLayout.CategoryAxis()
        let band = catLength / CGFloat(max(window.upperBound - window.lowerBound, 0.001))
        let zoomed = window != L.catDomain || o.valMin != nil || o.valMax != nil
        let bars = L.bars.filter { $0.c1 >= window.lowerBound && $0.c0 <= window.upperBound }
        let thickness = (bars.first.map { CGFloat($0.c1 - $0.c0) } ?? 1) * band
        let valueDomain: [Double] = o.reverseValue ? [L.valueScale.upper, L.valueScale.lower] : [L.valueScale.lower, L.valueScale.upper]
        let catDomain: [Double] = [window.lowerBound, window.upperBound]
        let trailing = seriesLabelReserve(L)
        let plotBG = style.format.color("plotArea", "background", "#00000000")
            .opacity(1 - style.format.double("plotArea", "transparency", 0) / 100)

        return Chart {
            analyticsBackground(L, R, window: window)
            areaMarks(L)
            barMarks(bars, radius: min(o.cornerRadius, thickness / 2))
            zeroRule(L)
            dotStems(L)
            lineMarks(L)
            analyticsForeground(L, R)
            crosshair(L)
        }
        .chartLegend(.hidden)
        .chartXScale(domain: kind.horizontal ? valueDomain : catDomain, type: kind.horizontal && o.logScale ? .log : .linear)
        .chartYScale(domain: kind.horizontal ? catDomain : valueDomain, type: !kind.horizontal && o.logScale ? .log : .linear)
        .chartXAxis {
            if kind.horizontal { valueAxis(L, show: showVal, position: .bottom) }
            else { categoryAxis(axis, show: showCat, position: .bottom, band: band, window: window) }
        }
        .chartYAxis {
            if kind.horizontal { categoryAxis(axis, show: showCat, position: .leading, band: band, window: window) }
            else { valueAxis(L, show: showVal, position: .leading) }
            secondaryAxis(L, show: showVal)
            if trailing > 0 {
                AxisMarks(position: .trailing, values: [(L.valueScale.lower + L.valueScale.upper) / 2]) { _ in
                    AxisValueLabel { Color.clear.frame(width: trailing, height: 1) }
                }
            }
        }
        .chartPlotStyle { $0.background(plotBG).clipShape(Rectangle().inset(by: zoomed ? 0 : -400)) }
        .chartOverlay { proxy in overlay(proxy: proxy, L: L, R: R, window: window, bars: bars, sc: sc) }
        .animation(context.isInteractive ? Design.Motion.standard : nil, value: L.signature)
    }

    // MARK: Axes

    @AxisContentBuilder
    private func valueAxis(_ L: CartesianLayout, show: Bool, position: AxisMarkPosition) -> some AxisContent {
        let fmt = kind.stacking == .percent ? "0%" : (model.series.first { !$0.isLine || !kind.isCombo }?.format ?? "")
        let fs = style.size(options.valCard)
        AxisMarks(position: position, values: L.valueScale.ticks) { v in
            if options.valGridlines {
                AxisGridLine(stroke: StrokeStyle(lineWidth: style.gridWidth)).foregroundStyle(style.grid)
            }
            if show, let d = v.as(Double.self) {
                // Along the bottom, centre labels on their gridline; pin the last one inside the plot.
                AxisValueLabel(anchor: kind.horizontal ? (v.index == L.valueScale.ticks.count - 1 ? .topTrailing : (v.index == 0 ? .topLeading : .top)) : nil) {
                    Text(AxisFormatter.label(d, units: options.units, decimals: options.decimals, format: fmt))
                        .font(style.font(fs).monospacedDigit()).foregroundStyle(style.secondary)
                }
            }
        }
    }

    @AxisContentBuilder
    private func secondaryAxis(_ L: CartesianLayout, show: Bool) -> some AxisContent {
        if let s = L.secondaryScale, show {
            let fmt = model.series.first { $0.isLine }?.format ?? ""
            let positions = s.ticks.map { L.toPrimary($0) }
            AxisMarks(position: .trailing, values: positions) { v in
                AxisValueLabel {
                    Text(AxisFormatter.label(s.ticks[safe: v.index] ?? 0, units: .auto, format: fmt))
                        .font(style.font().monospacedDigit()).foregroundStyle(style.secondary)
                }
            }
        }
    }

    @AxisContentBuilder
    private func categoryAxis(_ axis: CartesianLayout.CategoryAxis, show: Bool, position: AxisMarkPosition, band: CGFloat,
                              window: ClosedRange<Double>) -> some AxisContent {
        let fs = style.size(options.catCard)
        let rotation = options.labelRotation
        let ticks = axis.ticks
        let hasGroups = ticks.contains { !$0.group.isEmpty }
        AxisMarks(position: position, values: ticks.map(\.pos)) { v in
            if options.catGridlines {
                AxisGridLine(stroke: StrokeStyle(lineWidth: style.gridWidth)).foregroundStyle(style.grid)
            }
            if show, let t = ticks[safe: v.index] {
                if kind.horizontal {
                    AxisValueLabel {
                        Text(ChartText.truncated(t.label, fontSize: fs, width: axis.labelWidth))
                            .font(style.font(fs)).foregroundStyle(style.secondary).lineLimit(1)
                    }
                } else if rotation >= 60 {
                    AxisValueLabel(orientation: .verticalReversed) {
                        Text(ChartText.truncated(t.label, fontSize: fs, width: axis.labelWidth)).font(style.font(fs)).foregroundStyle(style.secondary)
                    }
                } else if rotation >= 30 {
                    let text = ChartText.truncated(t.label, fontSize: fs, width: axis.labelWidth)
                    let w = ChartText.size(text, fontSize: fs).width
                    AxisValueLabel(anchor: .top) {
                        Text(text).font(style.font(fs)).foregroundStyle(style.secondary).fixedSize()
                            .rotationEffect(.degrees(-45), anchor: .topTrailing)
                            .frame(width: fs, height: w * 0.71 + fs, alignment: .topTrailing)
                    }
                } else {
                    // Centre on the tick, but keep the first and last labels inside the chart.
                    let w = axis.wraps ? axis.labelWidth : ChartText.size(t.label, fontSize: fs).width
                    let right = CGFloat(window.upperBound - t.pos) * band, left = CGFloat(t.pos - window.lowerBound) * band
                    AxisValueLabel(anchor: right < w / 2 ? .topTrailing : (left < w / 2 - 28 ? .topLeading : .top)) {
                        VStack(spacing: 1) {
                            if axis.dropsOverflow && right < w / 2 {
                                EmptyView()
                            } else if axis.wraps {
                                Text(t.label).font(style.font(fs)).foregroundStyle(style.secondary)
                                    .lineLimit(2).multilineTextAlignment(.center).frame(width: axis.labelWidth)
                            } else {
                                Text(t.label).font(style.font(fs)).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
                            }
                            if hasGroups {
                                Text(groupLabel(ticks, v.index)).font(style.font(fs, weight: .medium)).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Outer hierarchy level shown once per group, under the group's middle label.
    private func groupLabel(_ ticks: [CartesianLayout.Tick], _ i: Int) -> String {
        let g = ticks[i].group
        var lo = i, hi = i
        while lo > 0, ticks[lo - 1].group == g { lo -= 1 }
        while hi < ticks.count - 1, ticks[hi + 1].group == g { hi += 1 }
        return i == (lo + hi) / 2 ? g : " "
    }

    /// Trailing space reserved for series labels at the ends of lines.
    func seriesLabelReserve(_ L: CartesianLayout) -> CGFloat {
        guard options.seriesLabels, !L.lines.isEmpty else { return 0 }
        let w = Set(L.lines.map(\.series)).compactMap { model.series[safe: $0]?.name }
            .map { ChartText.size($0, fontSize: style.labelSize).width }.max() ?? 0
        return min(96, w) + 10
    }

    // MARK: Orientation helpers

    func X(_ c: Double, _ v: Double) -> Double { kind.horizontal ? v : c }
    func Y(_ c: Double, _ v: Double) -> Double { kind.horizontal ? c : v }

    func seriesOpacity(_ s: Int) -> Double { highlighted.isEmpty || highlighted.contains(s) ? 1 : 0.22 }

    func color(series s: Int, cat: Int?, value: Double?) -> Color {
        let sm = model.series[safe: s]
        return colors.pointColor(series: s, seriesName: sm?.name ?? "", category: cat.flatMap { model.categories[safe: $0]?.label },
                                 row: cat.flatMap { sm?.rows[safe: $0] ?? nil }, value: value)
    }
}
