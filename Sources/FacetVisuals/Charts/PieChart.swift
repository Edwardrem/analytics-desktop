import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Pie and donut charts: Swift Charts sector marks, outside detail labels with leader lines,
/// an optional centre value for donuts, and cross-highlight drawn as a faded full slice behind
/// the highlighted portion.
struct PieVisual: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    struct Slice: Identifiable {
        let id: Int
        let label: String
        let legendIndex: Int
        let value: Double
        /// Highlighted part when cross-highlighting (nil otherwise).
        let highlight: Double?
        let color: Color
        let selection: DataPointSelection
        let row: Int?
        let format: String
        var start = 0.0, end = 0.0 // fraction of the full turn
    }

    private var style: ChartStyle { ChartStyle(spec: spec, theme: context.theme) }

    /// One slice per row (legend × details), or one per measure when there is no grouping.
    private func slices() -> (slices: [Slice], legend: [LegendItem], total: Double, format: String) {
        let colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        let t = data.table
        let legCols = data.indices(.legend), detCols = data.indices(.details)
        let valCols = data.indices(.values).filter { !((data.fields[safe: $0] ?? nil)?.isHidden ?? false) }
        let base = data.baseline.flatMap { $0.rowCount == t.rowCount && $0.columnCount == t.columnCount ? $0 : nil }
        var out: [Slice] = [], legend: [LegendItem] = []
        let fmt = valCols.first.flatMap { data.formats[safe: $0] } ?? ""
        if legCols.isEmpty && detCols.isEmpty {
            for (i, c) in valCols.enumerated() {
                let name = (data.fields[safe: c] ?? nil)?.caption ?? t.columns[c].name
                let v = t.rowCount > 0 ? t[0, c].asDouble ?? 0 : 0
                let total = base.flatMap { $0[0, c].asDouble } ?? v
                guard total > 0 else { continue }
                let color = colors.seriesColor(i, name: name)
                out.append(Slice(id: i, label: name, legendIndex: i, value: total, highlight: base != nil ? max(0, min(v, total)) : nil,
                                 color: color, selection: DataPointSelection(fields: [], values: []), row: 0, format: data.formats[safe: c] ?? ""))
                legend.append(LegendItem(id: i, name: name, color: color))
            }
        } else if let vc = valCols.first {
            var legIndex: [[Value]: Int] = [:]
            for r in 0..<t.rowCount {
                let v = t[r, vc].asDouble ?? 0
                let total = base.flatMap { $0[r, vc].asDouble } ?? v
                guard total > 0, total.isFinite else { continue }
                let key = (legCols.isEmpty ? detCols : legCols).map { t[r, $0] }
                let name = zip(legCols.isEmpty ? detCols : legCols, key).map { c, v in v.isNull ? "(Blank)" : ValueFormatter.format(v, data.formats[safe: c] ?? "") }.joined(separator: " ")
                let li: Int
                if let i = legIndex[key] { li = i } else {
                    li = legIndex.count; legIndex[key] = li
                    legend.append(LegendItem(id: li, name: name, color: colors.pointColor(series: li, seriesName: name, category: name),
                                             selection: SeriesModel.selection(data: data, row: r, columns: legCols.isEmpty ? detCols : legCols)))
                }
                let detail = legCols.isEmpty ? "" : detCols.map { data.formatted(row: r, col: $0) }.joined(separator: " ")
                let label = detail.isEmpty ? name : "\(name) · \(detail)"
                out.append(Slice(id: r, label: label, legendIndex: li, value: total, highlight: base != nil ? max(0, min(v, total)) : nil,
                                 color: colors.pointColor(series: li, seriesName: name, category: name, row: r, value: total),
                                 selection: SeriesModel.selection(data: data, row: r, columns: legCols + detCols), row: r, format: fmt))
            }
        }
        let total = out.reduce(0) { $0 + $1.value }
        var acc = 0.0
        for i in out.indices { out[i].start = acc / max(total, 1e-12); acc += out[i].value; out[i].end = acc / max(total, 1e-12) }
        return (out, legend, total, fmt)
    }

    var body: some View {
        let s = slices()
        let style = self.style
        if s.slices.isEmpty {
            ChartPlaceholder(systemImage: "chart.pie", title: "No data", message: "There are no positive values to show.", theme: context.theme)
        } else {
            ChartScaffold(spec: spec, context: context, items: s.legend, defaultShow: false) { highlighted in
                GeometryReader { geo in
                    plot(s.slices, total: s.total, format: s.format, size: geo.size, style: style, highlighted: highlighted)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(spec.type.displayName), \(s.slices.count) slices. Largest: \(s.slices.max { $0.value < $1.value }?.label ?? "").")
        }
    }

    private func sectorPath(_ s: Slice, center: CGPoint, inner: CGFloat, outer: CGFloat) -> Path {
        var p = Path()
        let a0 = Angle.degrees(s.start * 360 - 90), a1 = Angle.degrees(s.end * 360 - 90)
        p.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: center, radius: max(inner, 0.01), startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }

    @ViewBuilder
    private func plot(_ slices: [Slice], total: Double, format: String, size: CGSize, style: ChartStyle, highlighted: Set<Int>) -> some View {
        let f = style.format
        let isDonut = spec.type == .donut
        let innerRatio = max(0, min(0.92, f.double("slices", "innerRadius", isDonut ? 64 : 0) / 100))
        let labelMode = f.string("slices", "labels", "categoryPercent")
        let wantsLabels = f.bool("dataLabels", "show", true) && labelMode != "none" && size.width >= 230 && size.height >= 150
        let fs = style.size("dataLabels")
        let texts = wantsLabels ? slices.map { labelText($0, total: total, mode: labelMode) } : []
        let labelW = min(texts.map { ChartText.size($0, fontSize: fs).width }.max() ?? 0, size.width * 0.28)
        let radius = max(10, min((size.width - (wantsLabels ? 2 * (labelW + 18) : 0)) / 2, (size.height - (wantsLabels ? 2 * (fs + 8) : 0)) / 2))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let matcher = SelectionMatcher(context.selection)
        let hasBase = slices.contains { $0.highlight != nil }
        let opacity = { (s: Slice) -> Double in
            (s.selection.fields.isEmpty ? 1 : matcher.emphasis(s.selection)) * (highlighted.isEmpty || highlighted.contains(s.legendIndex) ? 1 : 0.25)
        }
        let inset: CGFloat = slices.count > 1 ? (radius > 60 ? 1 : 0.5) : 0
        let corner: CGFloat = slices.count > 1 && radius > 50 ? CGFloat(f.double("slices", "cornerRadius", 3)) : 0

        ZStack {
            Chart(slices) { s in
                SectorMark(angle: .value("Value", s.value), innerRadius: .ratio(innerRatio), angularInset: inset)
                    .cornerRadius(corner)
                    .foregroundStyle(s.color)
                    .opacity(opacity(s) * (hasBase ? 0.3 : 1))
                    .accessibilityLabel(s.label)
                    .accessibilityValue("\(ValueFormatter.format(.double(s.value), s.format)), \(AxisFormatter.label(s.value / max(total, 1e-12), format: "0.0%"))")
            }
            .chartLegend(.hidden)
            .frame(width: radius * 2, height: radius * 2)
            if hasBase {
                // Highlighted share of each slice grows outwards from the inner edge (area-proportional).
                Chart(slices) { s in
                    let share = (s.highlight ?? 0) / max(s.value, 1e-12)
                    let outer = (innerRatio * innerRatio + share * (1 - innerRatio * innerRatio)).squareRoot()
                    SectorMark(angle: .value("Value", s.value), innerRadius: .ratio(innerRatio), outerRadius: .ratio(outer), angularInset: inset)
                        .foregroundStyle(s.color)
                        .opacity(opacity(s))
                        .accessibilityLabel("\(s.label), highlighted")
                        .accessibilityValue(ValueFormatter.format(.double(s.highlight ?? 0), s.format))
                }
                .chartLegend(.hidden)
                .frame(width: radius * 2, height: radius * 2)
            }
            Canvas { ctx, _ in
                if style.usesPatterns {
                    for s in slices {
                        ChartPattern.forSeries(s.legendIndex).draw(in: ctx, clip: sectorPath(s, center: center, inner: radius * innerRatio, outer: radius), color: style.patternInk)
                    }
                }
                if wantsLabels { drawLabels(ctx, slices: slices, texts: texts, center: center, radius: radius, size: size, fs: fs, style: style) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if isDonut, f.bool("slices", "centerValue", true), radius * innerRatio > 26 {
                centerLabel(total: total, format: format, width: radius * innerRatio * 1.7, style: style)
            }
            ChartInteractionLayer(hits: slices.map { s in
                ChartHit(id: s.id, path: sectorPath(s, center: center, inner: radius * innerRatio, outer: radius),
                         anchor: point(center, radius * (1 + innerRatio) / 2, (s.start + s.end) / 2),
                         selection: s.selection, tooltip: tooltip(s, total: total))
            }, spec: spec, context: context)
        }
        .frame(width: size.width, height: size.height)
        .animation(context.isInteractive ? Design.Motion.standard : nil, value: slices.map(\.value))
    }

    private func centerLabel(total: Double, format: String, width: CGFloat, style: ChartStyle) -> some View {
        let f = style.format
        let caption = f.string("slices", "centerLabel", spec.fields(.values).first?.caption ?? "Total")
        let big = min(CGFloat(style.theme.callout.size), width / 3.4)
        return VStack(spacing: 1) {
            Text(AxisFormatter.label(total, units: DisplayUnits(f.string("slices", "centerUnits", "auto")), format: format))
                .font(.system(size: big, weight: .semibold)).monospacedDigit().foregroundStyle(style.foreground)
                .lineLimit(1).minimumScaleFactor(0.5)
            if width > 70, !caption.isEmpty {
                Text(caption).font(style.font()).foregroundStyle(style.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ turn: Double) -> CGPoint {
        let a = turn * 2 * .pi - .pi / 2
        return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }

    private func labelText(_ s: Slice, total: Double, mode: String) -> String {
        let pct = AxisFormatter.label(s.value / max(total, 1e-12), format: s.value / max(total, 1e-12) < 0.1 ? "0.0%" : "0%")
        let f = style.format
        let value = AxisFormatter.label(s.value, units: DisplayUnits(f.string("dataLabels", "displayUnits", "auto")),
                                        decimals: f.decimals("dataLabels"), format: s.format)
        switch mode {
        case "category": return s.label
        case "value": return value
        case "percent": return pct
        case "categoryValue": return "\(s.label)  \(value)"
        case "all": return "\(s.label)  \(value) (\(pct))"
        default: return "\(s.label)  \(pct)"
        }
    }

    private func drawLabels(_ ctx: GraphicsContext, slices: [Slice], texts: [String], center: CGPoint, radius: CGFloat, size: CGSize,
                            fs: CGFloat, style: ChartStyle) {
        let custom = style.format.value("dataLabels", "color")?.stringValue.map { Color(hex: $0) }
        var placer = DataLabelPlacer(bounds: CGRect(origin: .zero, size: size), fontSize: fs)
        // Largest slices claim their spots first.
        for i in slices.indices.sorted(by: { slices[$0].value > slices[$1].value }) {
            let s = slices[i]
            let mid = (s.start + s.end) / 2
            let edge = point(center, radius + 2, mid), elbow = point(center, radius + 10, mid)
            let right = elbow.x >= center.x
            let avail = (right ? size.width - elbow.x : elbow.x) - 8
            let text = ChartText.truncated(texts[i], fontSize: fs, width: max(20, avail))
            let w = ChartText.size(text, fontSize: fs).width
            let x = elbow.x + (right ? 6 + w / 2 : -6 - w / 2)
            let step = fs + 3
            let cands = [0, -1, 1, -2, 2].map { CGPoint(x: x, y: elbow.y + CGFloat($0) * step) }
            guard let rect = placer.place(text, color: custom ?? style.secondary, candidates: cands) else { continue }
            var p = Path()
            p.move(to: edge); p.addLine(to: elbow)
            p.addLine(to: CGPoint(x: right ? rect.minX - 3 : rect.maxX + 3, y: rect.midY))
            ctx.stroke(p, with: .color(style.secondary.opacity(0.55)), lineWidth: 0.5)
        }
        placer.draw(in: ctx, leaderColor: .clear)
    }

    private func tooltip(_ s: Slice, total: Double) -> TooltipContent {
        var rows: [TooltipContent.Row] = [
            .init(color: s.color, label: spec.fields(.values).first?.caption ?? "Value", value: ValueFormatter.format(.double(s.value), s.format), isEmphasized: true),
        ]
        if let h = s.highlight { rows.append(.init(label: "Highlighted", value: ValueFormatter.format(.double(h), s.format))) }
        rows.append(.init(label: "Share", value: AxisFormatter.label(s.value / max(total, 1e-12), format: "0.0%")))
        for f in SeriesModel.tooltipFields(data: data, row: s.row) { rows.append(.init(label: f.label, value: f.value)) }
        return TooltipContent(title: s.label, rows: rows)
    }
}
