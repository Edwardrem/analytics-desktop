import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Model

/// The points of a scatter chart: one per row at (X, Y), sized by Size, coloured by Legend and
/// named by Details. With a Play axis the rows split into frames, one per play-axis value.
struct ScatterModel {
    struct Point: Identifiable {
        let id: Int
        let x: Double, y: Double
        let size: Double?
        let series: Int
        let label: String
        /// Details and legend values: the same entity in every frame.
        let selection: DataPointSelection
        let row: Int
        /// Index into `frames`, when there is a play axis.
        let frame: Int?
    }
    struct Series { let name: String; let selection: DataPointSelection? }

    let points: [Point]
    let series: [Series]
    /// Distinct play-axis values in order (empty without a play axis).
    let frames: [Value]
    let maxSize: Double

    init(data: VisualData) {
        let t = data.table
        guard let xc = data.indices(.x).first, let yc = data.indices(.y).first, xc < t.columnCount, yc < t.columnCount else {
            points = []; series = []; frames = []; maxSize = 0
            return
        }
        let sizeCol = data.indices(.size).first.flatMap { $0 < t.columnCount ? $0 : nil }
        let legCol = data.indices(.legend).first.flatMap { $0 < t.columnCount ? $0 : nil }
        let playCol = data.indices(.playAxis).first.flatMap { $0 < t.columnCount ? $0 : nil }
        let nameCols = (data.indices(.details) + data.indices(.category)).filter { $0 < t.columnCount }

        var order: [Value] = [], index: [Value: Int] = [:]
        if let lc = legCol {
            for r in 0..<t.rowCount where index[t[r, lc]] == nil { index[t[r, lc]] = order.count; order.append(t[r, lc]) }
        }
        let legendField = legCol.flatMap { data.fields[safe: $0] ?? nil }
        series = order.map { v in
            Series(name: v.isNull ? "(Blank)" : ValueFormatter.format(v, legCol.flatMap { data.formats[safe: $0] } ?? ""),
                   selection: legendField.map { DataPointSelection(fields: [$0], values: [v]) })
        }

        let frameValues = playCol.map { pc in Array(Set((0..<t.rowCount).map { t[$0, pc] }.filter { !$0.isNull })).sorted() } ?? []
        let frameIndex = Dictionary(uniqueKeysWithValues: frameValues.enumerated().map { ($1, $0) })
        frames = frameValues

        var out: [Point] = []
        for r in 0..<t.rowCount {
            guard let x = t[r, xc].asDouble, x.isFinite, let y = t[r, yc].asDouble, y.isFinite else { continue }
            let frame = playCol.map { frameIndex[t[r, $0]] } ?? nil
            if playCol != nil, frame == nil { continue }   // a row without a play-axis value belongs to no frame
            out.append(Point(id: out.count, x: x, y: y, size: sizeCol.flatMap { t[r, $0].asDouble },
                             series: legCol.flatMap { index[t[r, $0]] } ?? 0,
                             label: nameCols.isEmpty ? "\(r + 1)" : StatSupport.label(data: data, row: r, columns: nameCols),
                             selection: SeriesModel.selection(data: data, row: r, columns: nameCols + (legCol.map { [$0] } ?? [])),
                             row: r, frame: frame))
        }
        points = out
        maxSize = out.compactMap(\.size).max() ?? 0
    }

    /// The points drawn at a play-axis position (all of them without a play axis).
    func visible(frame: Int) -> [Point] { frames.isEmpty ? points : points.filter { $0.frame == frame } }

    /// The path of each selected entity through the frames up to `frame`, in frame order.
    func trails(through frame: Int, matcher: SelectionMatcher) -> [[Point]] {
        guard !frames.isEmpty, matcher.isActive else { return [] }
        var byEntity: [String: [Point]] = [:]
        for p in points where (p.frame ?? 0) <= frame && matcher.isSelected(p.selection) {
            byEntity[p.selection.key, default: []].append(p)
        }
        return byEntity.values.map { $0.sorted { ($0.frame ?? 0) < ($1.frame ?? 0) } }.filter { $0.count > 1 }
    }
}

// MARK: - View

/// Scatter chart: one point per row at (X, Y), sized by the Size well, coloured by Legend (with a
/// legend), labelled by Details. A Play axis plays the points through its values.
struct ScatterChart: View {
    /// Bounds of `markers.size` (the radius of a point without a Size value).
    static let markerSizes: ClosedRange<Double> = 1...40
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    @State private var frame = 0
    @State private var playing = false

    var body: some View {
        let model = ScatterModel(data: data)
        let colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        let items = model.series.enumerated().map { i, s in
            LegendItem(id: i, name: s.name, color: colors.seriesColor(i, name: s.name), marker: .circle, selection: s.selection)
        }
        let current = min(frame, max(0, model.frames.count - 1))
        VStack(spacing: Design.Space.xs) {
            ChartScaffold(spec: spec, context: context, items: items) { highlighted in
                plot(model, frame: current, colors: colors, highlighted: highlighted)
            }
            if !model.frames.isEmpty { playBar(model, frame: current) }
        }
        .task(id: playing) {
            guard playing, !model.frames.isEmpty else { return }
            if frame >= model.frames.count - 1 { frame = 0 }
            while playing, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard playing, !Task.isCancelled else { return }
                if frame >= model.frames.count - 1 { playing = false } else { withAnimation(.easeInOut(duration: 0.6)) { frame += 1 } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.frames.isEmpty ? "Scatter chart, \(model.points.count) points."
                            : "Scatter chart, \(model.visible(frame: current).count) points at \(frameName(model, current)).")
    }

    private func plot(_ model: ScatterModel, frame: Int, colors: ColorResolver, highlighted: Set<Int>) -> some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let base = CGFloat(FormatNumber.clamped(style.format.double("markers", "size", 3.5), to: ScatterChart.markerSizes) ?? 3.5)
        let visible = model.visible(frame: frame)
        let matcher = SelectionMatcher(context.selection)
        // Axes span every frame, so they stay still while the points move.
        return StatPlot(spec: spec, context: context, style: style,
                        xDomain: extent(model.points.map(\.x)),
                        xTicks: ticks(model.points.map(\.x)),
                        xDefaultTitle: caption(.x),
                        yExtent: extent(model.points.map(\.y)), includeZero: false,
                        yFormat: format(.y), yDefaultTitle: caption(.y),
                        refValues: visible.map(\.y),
                        snapRadius: 8,
                        signature: visible.count &* 31 &+ frame,
                        hits: { map in
                            visible.map { p in
                                let color = colors.seriesColor(p.series, name: model.series[safe: p.series]?.name ?? "")
                                return ChartHit(id: p.id, path: Path(ellipseIn: circle(map.point(p.x, p.y), radius(p, model, base))),
                                                selection: p.selection,
                                                tooltip: TooltipContent(title: p.label, rows: tooltipRows(p, model, color)))
                            }
                        },
                        draw: { ctx, map in
                            let fill = 1 - (FormatNumber.clamped(style.format.double("markers", "transparency", 20), to: 0...100) ?? 20) / 100
                            for trail in model.trails(through: frame, matcher: matcher) {
                                var path = Path()
                                for (i, p) in trail.enumerated() {
                                    if i == 0 { path.move(to: map.point(p.x, p.y)) } else { path.addLine(to: map.point(p.x, p.y)) }
                                }
                                let color = colors.seriesColor(trail[0].series, name: model.series[safe: trail[0].series]?.name ?? "")
                                ctx.stroke(path, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            }
                            for p in visible.prefix(4_000) {
                                let color = colors.seriesColor(p.series, name: model.series[safe: p.series]?.name ?? "")
                                let dim = (matcher.isActive && !matcher.isSelected(p.selection))
                                    || (!highlighted.isEmpty && !highlighted.contains(p.series))
                                ctx.fill(Path(ellipseIn: circle(map.point(p.x, p.y), radius(p, model, base))),
                                         with: .color(color.opacity(dim ? 0.25 : fill)))
                            }
                        },
                        marks: { })
            .overlay(alignment: .topTrailing) {
                if !model.frames.isEmpty {
                    // The current play-axis value, large and quiet behind the points.
                    Text(frameName(model, frame)).font(.system(size: 28, weight: .semibold)).foregroundStyle(style.secondary.opacity(0.35))
                        .padding(Design.Space.m).allowsHitTesting(false)
                }
            }
    }

    private func playBar(_ model: ScatterModel, frame: Int) -> some View {
        HStack(spacing: Design.Space.s) {
            Button {
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 11)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(playing ? "Pause" : "Play through \(caption(.playAxis))")
            .accessibilityLabel(playing ? "Pause" : "Play")
            Slider(value: Binding(get: { Double(frame) }, set: { playing = false; self.frame = Int($0.rounded()) }),
                   in: 0...Double(max(1, model.frames.count - 1)), step: 1)
                .controlSize(.mini)
                .disabled(model.frames.count < 2)
                .accessibilityLabel(caption(.playAxis))
                .accessibilityValue(frameName(model, frame))
            Text(frameName(model, frame)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
        }
        .allowsHitTesting(context.isInteractive)
        .padding(.horizontal, Design.Space.xs)
    }

    private func frameName(_ model: ScatterModel, _ frame: Int) -> String {
        guard let v = model.frames[safe: frame] else { return "" }
        return ValueFormatter.format(v, data.indices(.playAxis).first.flatMap { data.formats[safe: $0] } ?? "")
    }

    private func tooltipRows(_ p: ScatterModel.Point, _ model: ScatterModel, _ color: Color) -> [TooltipContent.Row] {
        var rows: [TooltipContent.Row] = [
            .init(color: color, label: caption(.x), value: fmt(p.x, .x)),
            .init(color: color, label: caption(.y), value: fmt(p.y, .y), isEmphasized: true),
        ]
        if let s = p.size { rows.append(.init(label: caption(.size), value: fmt(s, .size))) }
        if !model.series.isEmpty, let name = model.series[safe: p.series]?.name { rows.append(.init(label: caption(.legend), value: name)) }
        if !model.frames.isEmpty, let f = p.frame { rows.append(.init(label: caption(.playAxis), value: frameName(model, f))) }
        return rows + SeriesModel.tooltipFields(data: data, row: p.row).map { .init(label: $0.label, value: $0.value) }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

    private func radius(_ p: ScatterModel.Point, _ model: ScatterModel, _ base: CGFloat) -> CGFloat {
        guard let s = p.size, s > 0, model.maxSize > 0 else { return base }
        return base + CGFloat((s / model.maxSize).squareRoot()) * 7
    }

    private func caption(_ well: Well) -> String {
        data.indices(well).first.flatMap { (data.fields[safe: $0] ?? nil)?.caption ?? data.table.columns[safe: $0]?.name } ?? well.displayName
    }
    private func format(_ well: Well) -> String { data.formats[safe: data.indices(well).first ?? -1] ?? "" }
    private func fmt(_ v: Double, _ well: Well) -> String { ValueFormatter.format(.double(v), format(well)) }

    private func extent(_ values: [Double]) -> ClosedRange<Double> {
        let vs = values.filter(\.isFinite)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        return lo...hi
    }
    private func ticks(_ values: [Double]) -> [StatTick] {
        let scale = AxisFormatter.niceScale(dataMin: values.min() ?? 0, dataMax: values.max() ?? 1, includeZero: false, targetTicks: 5)
        return scale.ticks.map { StatTick(pos: $0, label: AxisFormatter.label($0, format: format(.x))) }
    }
}
