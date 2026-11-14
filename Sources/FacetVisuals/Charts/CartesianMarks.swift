import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Swift Charts mark builders for `CartesianPanel`.
extension CartesianPanel {
    func interpolation() -> InterpolationMethod {
        switch options.interpolation.lowercased() {
        case "linear": return .linear
        case "step": return .stepCenter
        default: return .monotone
        }
    }

    func stroke(series s: Int, baseline: Bool = false) -> StrokeStyle {
        var dash: [CGFloat]
        switch options.lineStyle.lowercased() {
        case "dashed": dash = [6, 4]
        case "dotted": dash = [1.5, 4]
        default: dash = []
        }
        if style.usesPatterns, dash.isEmpty {
            let cycle: [[CGFloat]] = [[], [7, 3], [2, 3.5], [9, 3, 2, 3]]
            dash = cycle[s % cycle.count]
        }
        return StrokeStyle(lineWidth: options.lineWidth, lineCap: .round, lineJoin: .round, dash: dash)
    }

    func marker(series s: Int) -> MarkerShape {
        if let m = MarkerShape(rawValue: options.markerShape) { return m }
        return style.usesPatterns ? .forSeries(s) : .circle
    }

    /// Rounded corners only on the end of the bar the value grows towards.
    func barShape(_ b: CartesianLayout.Bar, radius r: CGFloat) -> UnevenRoundedRectangle {
        guard b.isOuter, r > 0 else { return UnevenRoundedRectangle() }
        let positive = (b.v1 >= b.v0) != options.reverseValue
        if kind.horizontal {
            return positive ? UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
                            : UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, style: .continuous)
        }
        return positive ? UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r, style: .continuous)
                        : UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous)
    }

    @ChartContentBuilder
    func barMarks(_ bars: [CartesianLayout.Bar], radius: CGFloat) -> some ChartContent {
        let m = matcher
        ForEach(bars) { b in
            let cat = model.categories[safe: b.cat]?.label ?? ""
            let name = model.series[safe: b.series]?.name ?? ""
            let emphasis = m.emphasis(model.selection(category: b.cat, series: b.series)) * seriesOpacity(b.series)
            RectangleMark(xStart: .value("x0", X(b.c0, b.v0)), xEnd: .value("x1", X(b.c1, b.v1)),
                          yStart: .value("y0", Y(b.c0, b.v0)), yEnd: .value("y1", Y(b.c1, b.v1)))
                .clipShape(barShape(b, radius: radius))
                .foregroundStyle(color(series: b.series, cat: b.cat, value: b.value))
                .opacity((b.isBaseline ? 0.3 : 1) * emphasis)
                .accessibilityLabel(b.isBaseline ? "\(cat), \(name), total" : "\(cat), \(name)")
                .accessibilityValue(model.formatted(b.value, series: b.series, category: b.cat))
        }
    }

    @ChartContentBuilder
    func zeroRule(_ L: CartesianLayout) -> some ChartContent {
        if (kind.drawsBars || kind.drawsArea || L.valueScale.lower < 0), !options.logScale, L.valueScale.lower <= 0, L.valueScale.upper >= 0 {
            if kind.horizontal {
                RuleMark(x: .value("zero", 0.0)).foregroundStyle(style.baseline).lineStyle(StrokeStyle(lineWidth: style.gridWidth * 1.5))
                    .accessibilityHidden(true)
            } else {
                RuleMark(y: .value("zero", 0.0)).foregroundStyle(style.baseline).lineStyle(StrokeStyle(lineWidth: style.gridWidth * 1.5))
                    .accessibilityHidden(true)
            }
        }
    }

    @ChartContentBuilder
    func areaMarks(_ L: CartesianLayout) -> some ChartContent {
        let stacked = kind.stacking != .none
        let method = interpolation()
        ForEach(L.areas) { a in
            let c = color(series: a.series, cat: nil, value: nil)
            let o = (a.isBaseline ? 0.3 : 1) * seriesOpacity(a.series)
            let fill: AnyShapeStyle = stacked
                ? AnyShapeStyle(c.opacity(0.82 * o))
                : AnyShapeStyle(LinearGradient(colors: [c.opacity(0.30 * o), c.opacity(0.03 * o)], startPoint: .top, endPoint: .bottom))
            ForEach(Array(a.points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("x", p.x), yStart: .value("y0", p.y0), yEnd: .value("y1", p.y1), series: .value("s", a.id))
            }
            .foregroundStyle(fill)
            .interpolationMethod(method)
            .accessibilityHidden(true)
        }
    }

    @ChartContentBuilder
    func lineMarks(_ L: CartesianLayout) -> some ChartContent {
        let m = matcher
        let method = interpolation()
        let stackedArea = kind.drawsArea && kind.stacking != .none
        ForEach(L.lines) { line in
            let c = color(series: line.series, cat: nil, value: nil)
            let o = (line.isBaseline ? 0.3 : 1) * seriesOpacity(line.series) * (m.isActive && model.seriesSelection(line.series).map { !m.isSelected($0) } ?? false && !pointsSelectable ? 0.3 : 1)
            let name = model.series[safe: line.series]?.name ?? ""
            if !kind.drawsDots {
                ForEach(Array(line.points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("s", line.id))
                        .accessibilityLabel("\(model.categories[safe: p.cat]?.label ?? ""), \(name)")
                        .accessibilityValue(model.formatted(p.value, series: line.series, category: p.cat))
                }
                .foregroundStyle(stackedArea ? AnyShapeStyle(style.card.opacity(0.7 * o)) : AnyShapeStyle(c.opacity(o)))
                .lineStyle(stackedArea ? StrokeStyle(lineWidth: 1) : stroke(series: line.series))
                .interpolationMethod(method)
            }
            if !stackedArea, !line.isBaseline || kind.drawsDots, kind.drawsDots || (options.showMarkers && line.points.count <= 240) || line.points.count == 1 || m.isActive && line.points.count <= 240 {
                let shape = marker(series: line.series)
                ForEach(Array(line.points.enumerated()), id: \.offset) { _, p in
                    let e = m.emphasis(model.selection(category: p.cat, series: line.series))
                    let visible = kind.drawsDots || options.showMarkers || line.points.count == 1 || (m.isActive && e == 1)
                    PointMark(x: .value("x", p.x), y: .value("y", p.y))
                        .symbol(shape.symbol)
                        .symbolSize(visible ? options.markerSize * options.markerSize * 1.6 * dotScale(series: line.series, cat: p.cat) : 0)
                        .foregroundStyle(c.opacity(o * (m.isActive ? e : 1)))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Dot plots scale each marker's area by the Size well (0.35× … 2.5×).
    func dotScale(series s: Int, cat: Int) -> CGFloat {
        guard kind.drawsDots, let col = model.data.indices(.size).first, col < model.data.table.columnCount,
              let row = model.series[safe: s]?.rows[safe: cat] ?? nil, let v = model.data.table[row, col].asDouble else { return 1 }
        let r = ConditionalFormatEvaluator.Range(model.data.table.columns[col].values)
        guard r.max > r.min else { return 1 }
        return 0.35 + 2.15 * CGFloat((v - r.min) / (r.max - r.min))
    }

    /// Hairline joining the lowest and highest series value of each category in a dot plot.
    @ChartContentBuilder
    func dotStems(_ L: CartesianLayout) -> some ChartContent {
        if kind.drawsDots, model.series.count > 1 {
            ForEach(model.categories.indices, id: \.self) { c in
                let vals = model.series.compactMap { $0.values[safe: c] ?? nil }
                if let lo = vals.min(), let hi = vals.max(), hi > lo, let x = L.catPos[safe: c] {
                    RuleMark(x: .value("c", x), yStart: .value("lo", lo), yEnd: .value("hi", hi))
                        .foregroundStyle(style.secondary.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// True when individual points (not just whole series) can be selected, i.e. a category axis exists.
    var pointsSelectable: Bool { !model.categoryColumns.isEmpty }

    /// Vertical guide and focus dots at the hovered category of line and area charts.
    @ChartContentBuilder
    func crosshair(_ L: CartesianLayout) -> some ChartContent {
        if let c = hoverCat, !kind.drawsBars, let x = L.catPos[safe: c] {
            RuleMark(x: .value("hover", x))
                .foregroundStyle(style.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.75))
                .accessibilityHidden(true)
            ForEach(L.lines.filter { !$0.isBaseline }) { line in
                if let p = line.points.first(where: { $0.cat == c }) {
                    PointMark(x: .value("x", p.x), y: .value("y", p.y))
                        .symbolSize(60).foregroundStyle(style.card).accessibilityHidden(true)
                    PointMark(x: .value("x", p.x), y: .value("y", p.y))
                        .symbolSize(28).foregroundStyle(color(series: line.series, cat: nil, value: nil)).accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: Analytics

    @ChartContentBuilder
    func analyticsBackground(_ L: CartesianLayout, _ R: CartesianAnalytics.Resolved, window: ClosedRange<Double>) -> some ChartContent {
        ForEach(R.lines.filter { $0.shadeTo != nil }) { l in
            let a = min(l.value, l.shadeTo ?? l.value), b = max(l.value, l.shadeTo ?? l.value)
            RectangleMark(xStart: .value("x0", X(window.lowerBound, a)), xEnd: .value("x1", X(window.upperBound, b)),
                          yStart: .value("y0", Y(window.lowerBound, a)), yEnd: .value("y1", Y(window.upperBound, b)))
                .foregroundStyle(l.color.opacity(0.10))
                .accessibilityHidden(true)
        }
        ForEach(R.bands) { band in
            ForEach(Array(band.points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("x", p.x), yStart: .value("lo", p.lo), yEnd: .value("hi", p.hi), series: .value("s", "band\(band.id)"))
            }
            .foregroundStyle(band.color.opacity(0.12))
            .interpolationMethod(.monotone)
            .accessibilityHidden(true)
        }
        ForEach(R.forecasts) { fc in
            ForEach(Array(fc.points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("x", p.x), yStart: .value("lo", p.lo), yEnd: .value("hi", p.hi), series: .value("s", "fband\(fc.id)"))
            }
            .foregroundStyle(fc.color.opacity(0.14))
            .interpolationMethod(.monotone)
            .accessibilityHidden(true)
        }
    }

    @ChartContentBuilder
    func analyticsForeground(_ L: CartesianLayout, _ R: CartesianAnalytics.Resolved) -> some ChartContent {
        ForEach(R.forecasts) { fc in
            ForEach(Array(fc.points.enumerated()), id: \.offset) { i, p in
                LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("s", "fline\(fc.id)"))
                    .accessibilityLabel("Forecast \(i)")
                    .accessibilityValue(AxisFormatter.label(p.y))
            }
            .foregroundStyle(fc.color)
            .lineStyle(StrokeStyle(lineWidth: options.lineWidth, lineCap: .round, dash: [5, 4]))
            .interpolationMethod(.monotone)
        }
        ForEach(R.trends) { t in
            LineMark(x: .value("x", X(t.x0, t.y0)), y: .value("y", Y(t.x0, t.y0)), series: .value("s", "trend\(t.id)"))
                .foregroundStyle(t.color.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [5, 4]))
                .accessibilityLabel("Trend line")
            LineMark(x: .value("x", X(t.x1, t.y1)), y: .value("y", Y(t.x1, t.y1)), series: .value("s", "trend\(t.id)"))
                .foregroundStyle(t.color.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [5, 4]))
                .accessibilityHidden(true)
        }
        ForEach(R.errorBars) { e in
            RuleMark(x: .value("c", X(e.c, e.lo)), yStart: .value("lo", Y(e.c, e.lo)), yEnd: .value("hi", Y(e.c, e.hi)))
                .foregroundStyle(style.foreground.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1))
                .accessibilityHidden(true)
            errorCap(e, e.lo)
            errorCap(e, e.hi)
        }
        ForEach(R.lines) { l in referenceRule(l) }
        ForEach(R.anomalies) { a in
            PointMark(x: .value("x", a.x), y: .value("y", a.y))
                .symbol(.circle).symbolSize(110)
                .foregroundStyle(style.card)
                .accessibilityHidden(true)
            PointMark(x: .value("x", a.x), y: .value("y", a.y))
                .symbol { Circle().strokeBorder(a.color, lineWidth: 2).frame(width: 12, height: 12) }
                .accessibilityLabel("Anomaly")
                .accessibilityValue(AxisFormatter.label(a.y))
        }
    }

    @ChartContentBuilder
    private func errorCap(_ e: CartesianAnalytics.ErrorBar, _ v: Double) -> some ChartContent {
        if kind.horizontal {
            RuleMark(x: .value("v", v), yStart: .value("a", e.c - e.cap), yEnd: .value("b", e.c + e.cap))
                .foregroundStyle(style.foreground.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1)).accessibilityHidden(true)
        } else {
            RuleMark(xStart: .value("a", e.c - e.cap), xEnd: .value("b", e.c + e.cap), y: .value("v", v))
                .foregroundStyle(style.foreground.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1)).accessibilityHidden(true)
        }
    }

    @ChartContentBuilder
    private func referenceRule(_ l: CartesianAnalytics.RefLine) -> some ChartContent {
        let label = Text(l.label).font(style.font(style.labelSize - 1, weight: .medium)).foregroundStyle(l.color)
            .padding(.horizontal, 3).background(style.card.opacity(0.82), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        if kind.horizontal {
            RuleMark(x: .value("ref", l.value))
                .foregroundStyle(l.color).lineStyle(StrokeStyle(lineWidth: 1, dash: l.dash))
                .annotation(position: .top, alignment: .center, spacing: 2) { if !l.label.isEmpty { label } }
                .accessibilityLabel(l.label.isEmpty ? "Reference line" : l.label)
        } else {
            RuleMark(y: .value("ref", l.value))
                .foregroundStyle(l.color).lineStyle(StrokeStyle(lineWidth: 1, dash: l.dash))
                .annotation(position: .top, alignment: .trailing, spacing: 2) { if !l.label.isEmpty { label } }
                .accessibilityLabel(l.label.isEmpty ? "Reference line" : l.label)
        }
    }
}
