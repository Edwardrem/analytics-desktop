import SwiftUI
import Charts
import FacetCore
import FacetDesign

// MARK: - Heatmap (matrix and calendar)

/// Heatmap: Rows × Columns colored by value. The calendar variant lays days out month by month.
struct HeatmapView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    private var env: FlowEnv { FlowEnv(spec: spec, data: data, context: context) }
    private var style: ChartStyle { ChartStyle(spec: spec, theme: context.theme) }

    var body: some View {
        if spec.type == .calendarHeatmap {
            calendar
        } else {
            matrix
        }
    }

    // MARK: Matrix

    private var matrix: some View {
        GeometryReader { geo in
            let L = matrixLayout(size: geo.size)
            let hits = cellHits(L)
            var h = Hasher()
            let _ = L.cells.forEach { h.combine($0.row); h.combine($0.col) }
            FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, size in
                drawMatrix(ctx, L, size: size)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Heatmap, \(L.rowLabels.count) rows, \(L.columnLabels.count) columns.")
        }
    }

    private struct Cell {
        let row: Int, col: Int
        let value: Double
        var rect: CGRect = .zero
    }
    private struct MatrixLayout {
        var cells: [Cell] = []
        var rowLabels: [String] = []
        var columnLabels: [String] = []
        var rowLabelWidth: CGFloat = 0
        var columnLabelHeight: CGFloat = 0
        var origin: CGPoint = .zero
        var cellWidth: CGFloat = 0, cellHeight: CGFloat = 0
        var scale = StatColorScale(lo: 0, hi: 1, stops: ["#FFFFFF", "#000000"])
        var caption = ""
        var format = ""
        var total = 0.0
    }

    private func matrixLayout(size: CGSize) -> MatrixLayout {
        var L = MatrixLayout()
        let t = data.table
        let rowCols = data.indices(.rows), colCols = data.indices(.columns)
        guard let vc = data.indices(.values).first, vc < t.columnCount, t.rowCount > 0 else { return L }
        var rowOrder: [String] = [], colOrder: [String] = []
        var rowIndex: [String: Int] = [:], colIndex: [String: Int] = [:]
        var raw: [(r: Int, c: Int, v: Double)] = []
        let valueCaption = (data.fields[safe: vc] ?? nil)?.caption ?? t.columns[vc].name
        for r in 0..<t.rowCount {
            let row = rowCols.isEmpty ? "Total" : StatSupport.label(data: data, row: r, columns: rowCols)
            let col = colCols.isEmpty ? valueCaption : StatSupport.label(data: data, row: r, columns: colCols)
            if rowIndex[row] == nil { rowIndex[row] = rowOrder.count; rowOrder.append(row) }
            if colIndex[col] == nil { colIndex[col] = colOrder.count; colOrder.append(col) }
            if let v = t[r, vc].asDouble, v.isFinite {
                raw.append((rowIndex[row]!, colIndex[col]!, v))
            }
        }
        L.rowLabels = rowOrder
        L.columnLabels = colOrder
        guard !rowOrder.isEmpty, !colOrder.isEmpty else { return L }
        let fs = env.labelSize
        L.rowLabelWidth = min(size.width * 0.3, max(30, (rowOrder.map { ChartText.size($0, fontSize: fs).width }.max() ?? 0)))
        L.columnLabelHeight = min(size.height * 0.4, max(14, (colOrder.map { ChartText.size($0, fontSize: fs).width }.max() ?? 0)) * 0.5 + 10)
        L.origin = CGPoint(x: L.rowLabelWidth + 6, y: L.columnLabelHeight + 2)
        let availableW = max(10, size.width - L.origin.x - 4)
        let availableH = max(10, size.height - L.origin.y - 4)
        L.cellWidth = availableW / CGFloat(colOrder.count)
        L.cellHeight = availableH / CGFloat(rowOrder.count)
        let radius = CGFloat(style.format.double("heatmap", "radius", 2))
        let values = raw.map(\.v)
        L.scale = StatColorScale(style: style, card: "heatmap", values: values)
        L.caption = valueCaption
        L.format = data.formats[safe: vc] ?? ""
        L.total = values.reduce(0, +)
        for (r, c, v) in raw {
            let rect = CGRect(x: L.origin.x + CGFloat(c) * L.cellWidth + 1,
                              y: L.origin.y + CGFloat(r) * L.cellHeight + 1,
                              width: max(1, L.cellWidth - 2), height: max(1, L.cellHeight - 2))
            L.cells.append(Cell(row: r, col: c, value: v, rect: rect))
        }
        return L
    }

    private func drawMatrix(_ ctx: GraphicsContext, _ L: MatrixLayout, size: CGSize) {
        guard !L.cells.isEmpty else { return }
        let fs = env.labelSize
        let radius = CGFloat(style.format.double("heatmap", "radius", 2))
        for cell in L.cells {
            let color = L.scale.color(cell.value)
            let shape = Path(roundedRect: cell.rect, cornerRadius: radius, style: .continuous)
            ctx.fill(shape, with: .color(color))
            if L.cellWidth > 46 && L.cellHeight > 18 {
                ctx.flowText(env.full(cell.value, format: L.format), at: CGPoint(x: cell.rect.midX, y: cell.rect.midY),
                             size: fs - 1, color: readableInk(on: color))
            }
        }
        // Headers
        for (r, label) in L.rowLabels.enumerated() {
            let y = L.origin.y + CGFloat(r) * L.cellHeight + L.cellHeight / 2
            let text = ChartText.truncated(label, fontSize: fs, width: L.rowLabelWidth)
            ctx.flowText(text, at: CGPoint(x: L.rowLabelWidth, y: y), anchor: .trailing, size: fs, color: env.style.theme.secondaryColor)
        }
        for (c, label) in L.columnLabels.enumerated() {
            let x = L.origin.x + CGFloat(c) * L.cellWidth + L.cellWidth / 2
            let text = ChartText.truncated(label, fontSize: fs, width: max(L.cellWidth, 24))
            ctx.flowText(text, at: CGPoint(x: x, y: L.columnLabelHeight), anchor: .bottom, size: fs, color: env.style.theme.secondaryColor)
        }
    }

    private func cellHits(_ L: MatrixLayout) -> [ChartHit] {
        let rowCols = data.indices(.rows), colCols = data.indices(.columns)
        return L.cells.enumerated().map { i, cell -> ChartHit in
            let r = sourceRow(cell.row, cell.col, L, rowCols: rowCols, colCols: colCols)
            var rows: [TooltipContent.Row] = [
                .init(label: L.caption, value: env.full(cell.value, format: L.format), isEmphasized: true),
                .init(label: "Share", value: env.percent(cell.value / max(L.total, 1e-12))),
            ]
            rows += env.tooltipRows(row: r)
            return ChartHit(id: i, path: Path(cell.rect), selection: SeriesModel.selection(data: data, row: r, columns: rowCols + colCols),
                            tooltip: TooltipContent(title: L.rowLabels[cell.row] + " · " + L.columnLabels[cell.col], rows: rows))
        }
    }

    /// The first source row backing a matrix cell (for tooltip detail rows and selection).
    private func sourceRow(_ row: Int, _ col: Int, _ L: MatrixLayout, rowCols: [Int], colCols: [Int]) -> Int {
        let t = data.table
        guard let vc = data.indices(.values).first, vc < t.columnCount else { return 0 }
        let valueCaption = (data.fields[safe: vc] ?? nil)?.caption ?? (t.columns[safe: vc]?.name ?? "")
        for r in 0..<t.rowCount {
            let rl = rowCols.isEmpty ? "Total" : StatSupport.label(data: data, row: r, columns: rowCols)
            let cl = colCols.isEmpty ? valueCaption : StatSupport.label(data: data, row: r, columns: colCols)
            if rl == L.rowLabels[row] && cl == L.columnLabels[col] { return r }
        }
        return 0
    }

    // MARK: Calendar

    private var calendar: some View {
        GeometryReader { geo in
            let L = calendarLayout(size: geo.size)
            let hits = dayHits(L)
            var h = Hasher()
            let _ = L.days.forEach { h.combine($0.date); h.combine($0.rect.minY) }
            FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, size in
                drawCalendar(ctx, L, size: size)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar heatmap.")
    }

    private struct Day {
        let date: Date
        let value: Double
        var rect: CGRect = .zero
    }
    private struct CalendarLayout {
        var days: [Day] = []
        var monthLabels: [(text: String, x: CGFloat, y: CGFloat)] = []
        var yearLabels: [(text: String, x: CGFloat, y: CGFloat)] = []
        var cell = CGSize.zero
        var scale = StatColorScale(lo: 0, hi: 1, stops: ["#FFFFFF", "#000000"])
        var caption = ""
        var format = ""
        var total = 0.0
    }

    private func calendarLayout(size: CGSize) -> CalendarLayout {
        var L = CalendarLayout()
        let t = data.table
        guard let cat = data.indices(.category).first ?? data.indices(.trendAxis).first, cat < t.columnCount,
              let vc = data.indices(.values).first, vc < t.columnCount else { return L }
        var raw: [(date: Date, v: Double)] = []
        for r in 0..<t.rowCount {
            guard let d = t[r, cat].asDate, let v = t[r, vc].asDouble, v.isFinite else { continue }
            raw.append((d, v))
        }
        guard !raw.isEmpty else { return L }
        let values = raw.map(\.v)
        L.scale = StatColorScale(style: style, card: "heatmap", values: values)
        L.caption = (data.fields[safe: vc] ?? nil)?.caption ?? t.columns[vc].name
        L.format = data.formats[safe: vc] ?? ""
        L.total = values.reduce(0, +)
        // One value per calendar day.
        let calendar = Calendar.current
        var byDay: [Date: Double] = [:]
        for (d, v) in raw { byDay[calendar.startOfDay(for: d)] = v }

        // One year per row of blocks; months flow three across, 7 weekday rows tall.
        let fs = env.labelSize
        let years = Array(Set(raw.map { calendar.component(.year, from: $0.date) })).sorted()
        let perRow = max(1, min(years.count, Int(size.width / 200)))
        let blockW = size.width / CGFloat(perRow)
        let rows = (years.count + perRow - 1) / perRow
        let blockH = size.height / CGFloat(rows)
        let monthGap: CGFloat = 6
        let monthW = (blockW - monthGap * 2) / 3
        L.cell = CGSize(width: min(22, (monthW - 12) / 7), height: min(22, (blockH - 34) / 7))
        let monthSymbols = calendar.monthSymbols
        for (i, year) in years.enumerated() {
            let bx = CGFloat(i % perRow) * blockW
            let by = CGFloat(i / perRow) * blockH
            L.yearLabels.append(("\(year)", bx + blockW - 24, by + 12))
            for m in 1...12 {
                let mx = bx + CGFloat((m - 1) % 3) * (monthW + monthGap)
                let my = by + CGFloat((m - 1) / 3) * (7 * L.cell.height + 18)
                L.monthLabels.append((monthSymbols[m - 1], mx, my))
                var comps = DateComponents()
                comps.year = year; comps.month = m; comps.day = 1
                guard let first = calendar.date(from: comps) else { continue }
                let weekday = (calendar.component(.weekday, from: first) + 5) % 7 // Monday first
                for day in 0..<31 {
                    guard let date = calendar.date(byAdding: .day, value: day, to: first),
                          calendar.component(.month, from: date) == m else { continue }
                    let col = (weekday + day) / 7, row = (weekday + day) % 7
                    let rect = CGRect(x: mx + CGFloat(col) * L.cell.width,
                                      y: my + 10 + CGFloat(row) * L.cell.height,
                                      width: max(2, L.cell.width - 2), height: max(2, L.cell.height - 2))
                    if let v = byDay[calendar.startOfDay(for: date)] {
                        L.days.append(Day(date: date, value: v, rect: rect))
                    }
                }
            }
        }
        return L
    }

    private func drawCalendar(_ ctx: GraphicsContext, _ L: CalendarLayout, size: CGSize) {
        guard !L.days.isEmpty else { return }
        let fs = env.labelSize
        for d in L.days {
            let color = L.scale.color(d.value)
            ctx.fill(Path(roundedRect: d.rect, cornerRadius: 2, style: .continuous), with: .color(color))
        }
        for (text, x, y) in L.monthLabels {
            ctx.flowText(text, at: CGPoint(x: x, y: y), anchor: .topLeading, size: fs - 1, color: env.style.theme.secondaryColor)
        }
        for (text, x, y) in L.yearLabels {
            ctx.flowText(text, at: CGPoint(x: x, y: y), anchor: .topTrailing, size: fs, weight: .medium, color: env.style.theme.foregroundColor)
        }
    }

    private func dayHits(_ L: CalendarLayout) -> [ChartHit] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return L.days.enumerated().map { i, d -> ChartHit in
            ChartHit(id: i, path: Path(d.rect), selection: nil,
                     tooltip: TooltipContent(title: formatter.string(from: d.date), rows: [
                         .init(label: L.caption, value: env.full(d.value, format: L.format), isEmphasized: true),
                         .init(label: "Share", value: env.percent(d.value / max(L.total, 1e-12))),
                     ]))
        }
    }

    /// Dark or light ink, whichever reads on `color`.
    private func readableInk(on color: Color) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        NSColor(color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .black.opacity(0.72) : .white.opacity(0.92)
    }
}

// MARK: - Candlestick

/// Candlestick chart: Open–High–Low–Close per category, wick plus body, green up / red down.
struct CandlestickView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    private struct Candle: Identifiable {
        let id: Int
        let label: String
        let open: Double, high: Double, low: Double, close: Double
        let selection: DataPointSelection?
        let row: Int
        var up: Bool { close >= open }
    }

    var body: some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let candles = model()
        let n = max(candles.count, 1)
        StatPlot(spec: spec, context: context, style: style,
                 xDomain: -0.5...(Double(n) - 0.5),
                 xTicks: candles.enumerated().map { StatTick(pos: Double($0.offset), label: ChartText.truncated($0.element.label, fontSize: style.labelSize, width: 90)) },
                 xDefaultTitle: categoryTitle,
                 yExtent: extent(candles), includeZero: false,
                 yFormat: format, yDefaultTitle: "",
                 refValues: candles.flatMap { [$0.open, $0.high, $0.low, $0.close] },
                 signature: candles.count,
                 hits: { map in
                     candles.enumerated().map { i, c in
                         ChartHit(id: i, rect: map.rect(x0: Double(i) - 0.4, x1: Double(i) + 0.4,
                                                        y0: c.low, y1: c.high),
                                  selection: c.selection,
                                  tooltip: TooltipContent(title: c.label, rows: [
                                      .init(label: "Open", value: fmt(c.open)),
                                      .init(label: "High", value: fmt(c.high)),
                                      .init(label: "Low", value: fmt(c.low)),
                                      .init(label: "Close", value: fmt(c.close), isEmphasized: true),
                                  ] + SeriesModel.tooltipFields(data: data, row: c.row).map { .init(label: $0.label, value: $0.value) }))
                     }
                 },
                 marks: {
                     ForEach(candles) { c in
                         RectangleMark(x: .value("i", c.id), yStart: .value("open", c.open), yEnd: .value("close", c.close),
                                       width: .ratio(0.5))
                             .foregroundStyle(c.up ? upColor(style) : downColor(style))
                         LineMark(x: .value("i", c.id), y: .value("high", c.high))
                             .lineStyle(StrokeStyle(lineWidth: 1))
                         LineMark(x: .value("i", c.id), y: .value("low", c.low))
                             .lineStyle(StrokeStyle(lineWidth: 1))
                     }
                 })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Candlestick chart, \(candles.count) candles.")
    }

    private func upColor(_ style: ChartStyle) -> Color { style.format.color("candlestick", "upColor", style.theme.good) }
    private func downColor(_ style: ChartStyle) -> Color { style.format.color("candlestick", "downColor", style.theme.bad) }

    private var categoryTitle: String {
        let cols = data.indices(.category)
        return cols.map { (data.fields[safe: $0] ?? nil)?.caption ?? data.table.columns[safe: $0]?.name ?? "" }.joined(separator: " ")
    }
    private var format: String {
        data.formats[safe: data.indices(.close).first ?? data.indices(.open).first ?? 0] ?? ""
    }
    private func fmt(_ v: Double) -> String { ValueFormatter.format(.double(v), format) }

    private func extent(_ candles: [Candle]) -> ClosedRange<Double> {
        guard !candles.isEmpty else { return 0...1 }
        let lo = candles.map(\.low).min() ?? 0
        let hi = candles.map(\.high).max() ?? 1
        return lo < hi ? lo...hi : lo...(lo + 1)
    }

    private func model() -> [Candle] {
        let t = data.table
        guard let o = data.indices(.open).first, let h = data.indices(.high).first,
              let l = data.indices(.low).first, let c = data.indices(.close).first else { return [] }
        let catCols = data.indices(.category)
        var out: [Candle] = []
        for r in 0..<t.rowCount {
            guard let open = t[r, o].asDouble, let high = t[r, h].asDouble,
                  let low = t[r, l].asDouble, let close = t[r, c].asDouble else { continue }
            let label = catCols.isEmpty ? "\(r + 1)" : StatSupport.label(data: data, row: r, columns: catCols)
            out.append(Candle(id: out.count, label: label, open: open, high: high, low: low, close: close,
                              selection: SeriesModel.selection(data: data, row: r, columns: catCols), row: r))
        }
        return out
    }
}

// MARK: - Bullet

/// Bullet chart: one thin bar per category — a light track, the value, and a target tick.
struct BulletView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    private struct Bullet: Identifiable {
        let id: Int
        let label: String
        let value: Double
        let target: Double?
        let selection: DataPointSelection?
        let row: Int
        var trackRect: CGRect = .zero
        var valueRect: CGRect = .zero
        var targetX: CGFloat?
    }

    private var env: FlowEnv { FlowEnv(spec: spec, data: data, context: context) }
    private var style: ChartStyle { ChartStyle(spec: spec, theme: context.theme) }

    var body: some View {
        let style = self.style
        GeometryReader { geo in
            let L = layout(style: style, size: geo.size)
            let hits = bulletHits(L, style: style)
            var h = Hasher()
            let _ = L.bullets.forEach { h.combine($0.value); h.combine($0.row) }
            FlowCanvas(env: env, hits: hits, signature: h.finalize()) { ctx, size in
                draw(ctx, L, style: style, size: size)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bullet chart, \(bullets.count) measures.")
    }

    private var bullets: [(label: String, value: Double, target: Double?, row: Int)] { model() }

    private func model() -> [(label: String, value: Double, target: Double?, row: Int)] {
        let t = data.table
        guard let vc = data.indices(.values).first, vc < t.columnCount else { return [] }
        let catCols = data.indices(.category)
        let targetCols = data.indices(.target)
        var out: [(label: String, value: Double, target: Double?, row: Int)] = []
        for r in 0..<t.rowCount {
            guard let v = t[r, vc].asDouble, v.isFinite else { continue }
            let label = catCols.isEmpty ? ((data.fields[safe: vc] ?? nil)?.caption ?? t.columns[vc].name) : StatSupport.label(data: data, row: r, columns: catCols)
            let target = targetCols.first.flatMap { t[r, $0].asDouble }
            out.append((label, v, target, r))
        }
        return out
    }

    private func layout(style: ChartStyle, size: CGSize) -> (bullets: [Bullet], scale: Double, format: String) {
        let rows = model()
        let fs = env.labelSize
        let labelWidth = min(size.width * 0.34, max(34, rows.map { ChartText.size($0.label, fontSize: fs).width }.max() ?? 0))
        let barHeight: CGFloat = 14
        let rowHeight: CGFloat = max(barHeight + 10, (size.height - 4) / CGFloat(max(rows.count, 1)))
        let trackWidth = max(10, size.width - labelWidth - 12)
        let maxValue = max(rows.map { max($0.value, $0.target ?? 0) }.max() ?? 0, 1e-9)
        var out: [Bullet] = []
        for (i, b) in rows.enumerated() {
            var bullet = Bullet(id: i, label: b.label, value: b.value, target: b.target,
                                selection: SeriesModel.selection(data: data, row: b.row, columns: data.indices(.category)),
                                row: b.row)
            let y = CGFloat(i) * rowHeight + (rowHeight - barHeight) / 2
            let track = CGRect(x: labelWidth + 6, y: y, width: trackWidth, height: barHeight)
            bullet.trackRect = track
            let width = max(2, track.width * CGFloat(min(1, b.value / maxValue)))
            bullet.valueRect = CGRect(x: track.minX, y: y + 2, width: width, height: barHeight - 4)
            if let t = b.target, t > 0, t <= maxValue * 1.02 {
                bullet.targetX = track.minX + track.width * CGFloat(min(1, t / maxValue))
            }
            out.append(bullet)
        }
        let format = data.formats[safe: data.indices(.values).first ?? 0] ?? ""
        return (out, maxValue, format)
    }

    private func draw(_ ctx: GraphicsContext, _ L: (bullets: [Bullet], scale: Double, format: String), style: ChartStyle, size: CGSize) {
        guard !L.bullets.isEmpty else { return }
        let fs = env.labelSize
        let trackColor = style.format.color("bullet", "trackColor", style.theme.gridline)
        let barColor = style.format.color("bullet", "barColor", style.theme.accent)
        for b in L.bullets {
            let dim = b.selection.map { env.matcher.isActive && !env.matcher.isSelected($0) } ?? false
            ctx.fill(Path(roundedRect: b.trackRect, cornerRadius: 3, style: .continuous), with: .color(trackColor.opacity(0.6)))
            ctx.fill(Path(roundedRect: b.valueRect, cornerRadius: 3, style: .continuous), with: .color(barColor.opacity(dim ? 0.35 : 1)))
            if let x = b.targetX {
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: b.trackRect.minY - 2))
                tick.addLine(to: CGPoint(x: x, y: b.trackRect.maxY + 2))
                ctx.stroke(tick, with: .color(style.theme.foregroundColor), lineWidth: 1.5)
            }
            ctx.flowText(ChartText.truncated(b.label, fontSize: fs, width: b.trackRect.minX - 8),
                         at: CGPoint(x: 0, y: b.trackRect.midY), anchor: .leading, size: fs, color: env.style.theme.secondaryColor)
            ctx.flowText(env.full(b.value, format: L.format), at: CGPoint(x: b.trackRect.maxX + 6, y: b.trackRect.midY),
                         anchor: .leading, size: fs - 1, color: env.style.theme.secondaryColor)
        }
    }

    private func bulletHits(_ L: (bullets: [Bullet], scale: Double, format: String), style: ChartStyle) -> [ChartHit] {
        L.bullets.map { b -> ChartHit in
            var rows: [TooltipContent.Row] = [
                .init(color: style.theme.dataColor(0), label: "Value", value: env.full(b.value, format: L.format), isEmphasized: true),
            ]
            if let t = b.target { rows.append(.init(label: "Target", value: env.full(t, format: L.format))) }
            rows += env.tooltipRows(row: b.row)
            let tooltip = TooltipContent(title: b.label, rows: rows)
            return ChartHit(id: b.id, path: Path(b.trackRect), selection: b.selection, tooltip: tooltip,
                            copyText: env.full(b.value, format: L.format))
        }
    }
}

// MARK: - Scatter

/// Scatter chart: one point per row at (X, Y), sized by the Size well, colored by legend value.
struct ScatterChart: View {
    /// Bounds of `markers.size` (the radius of a point without a Size value).
    static let markerSizes: ClosedRange<Double> = 1...40
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext

    private struct Point: Identifiable {
        let id: Int
        let x: Double, y: Double
        let size: Double?
        let color: Color
        let series: Int
        let label: String
        let selection: DataPointSelection?
        let row: Int
    }

    var body: some View {
        let style = ChartStyle(spec: spec, theme: context.theme)
        let points = model()
        let base = CGFloat(FormatNumber.clamped(style.format.double("markers", "size", 3.5), to: ScatterChart.markerSizes) ?? 3.5)
        StatPlot(spec: spec, context: context, style: style,
                 xDomain: axisExtent(points.map(\.x)),
                 xTicks: axisTicks(points.map(\.x), style: style),
                 xDefaultTitle: caption(well: .x),
                 yExtent: axisExtent(points.map(\.y)), includeZero: false,
                 yFormat: format(well: .y), yDefaultTitle: caption(well: .y),
                 refValues: points.map(\.y),
                 snapRadius: 8,
                 signature: points.count,
                 hits: { map in
                     points.enumerated().map { i, p in
                         ChartHit(id: i, path: Path(circle(around: map.point(p.x, p.y), radius: radius(p, map: map, base: base))),
                                  selection: p.selection,
                                  tooltip: TooltipContent(title: p.label, rows: [
                                      .init(color: p.color, label: caption(well: .x), value: fmt(p.x, well: .x)),
                                      .init(color: p.color, label: caption(well: .y), value: fmt(p.y, well: .y), isEmphasized: true),
                                  ] + (p.size.map { [.init(label: caption(well: .size), value: fmt($0, well: .size))] } ?? [])
                                    + SeriesModel.tooltipFields(data: data, row: p.row).map { .init(label: $0.label, value: $0.value) }))
                     }
                 },
                 draw: { ctx, map in
                     let fill = 1 - (FormatNumber.clamped(style.format.double("markers", "transparency", 20), to: 0...100) ?? 20) / 100
                     for p in points.prefix(4_000) {
                         let c = map.point(p.x, p.y)
                         let r = radius(p, map: map, base: base)
                         let dim = p.selection.map { env.matcher.isActive && !env.matcher.isSelected($0) } ?? false
                         ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                  with: .color(p.color.opacity(dim ? 0.25 : fill)))
                     }
                 },
                 marks: { })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Scatter chart, \(points.count) points.")
    }

    private var env: FlowEnv { FlowEnv(spec: spec, data: data, context: context) }

    private func circle(around c: CGPoint, radius r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    private func radius(_ p: Point, map: StatMap, base: CGFloat) -> CGFloat {
        guard let s = p.size, s > 0, map.plot.width > 0 else { return base }
        return base + CGFloat((s / maxSize).squareRoot()) * 7
    }

    private var maxSize: Double { model().map { $0.size ?? 0 }.max() ?? 0 }

    private func caption(well: Well) -> String {
        data.indices(well).first.flatMap { (data.fields[safe: $0] ?? nil)?.caption ?? data.table.columns[safe: $0]?.name } ?? well.displayName
    }
    private func format(well: Well) -> String {
        data.formats[safe: data.indices(well).first ?? 0] ?? ""
    }
    private func fmt(_ v: Double, well: Well) -> String {
        ValueFormatter.format(.double(v), format(well: well))
    }

    private func axisExtent(_ values: [Double]) -> ClosedRange<Double> {
        let vs = values.filter { $0.isFinite }
        guard !vs.isEmpty else { return 0...1 }
        return (vs.min() ?? 0)...(vs.max() ?? 1)
    }
    private func axisTicks(_ values: [Double], style: ChartStyle) -> [StatTick] {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let scale = AxisFormatter.niceScale(dataMin: lo, dataMax: hi, includeZero: false, targetTicks: 5)
        return scale.ticks.map { StatTick(pos: $0, label: AxisFormatter.label($0, format: "")) }
    }

    private func model() -> [Point] {
        let t = data.table
        guard let xc = data.indices(.x).first, let yc = data.indices(.y).first, xc < t.columnCount, yc < t.columnCount else { return [] }
        let sizeCol = data.indices(.size).first
        let legCol = data.indices(.legend).first
        let catCols = data.indices(.category)
        var legendOrder: [Value] = []
        var legendIndex: [Value: Int] = [:]
        if let lc = legCol {
            for r in 0..<t.rowCount where !t[r, lc].isNull {
                let v = t[r, lc]
                if legendIndex[v] == nil { legendIndex[v] = legendOrder.count; legendOrder.append(v) }
            }
        }
        let colors = ColorResolver(spec: spec, data: data, theme: context.theme)
        var out: [Point] = []
        for r in 0..<t.rowCount {
            guard let x = t[r, xc].asDouble, x.isFinite, let y = t[r, yc].asDouble, y.isFinite else { continue }
            let legendValue = legCol.map { t[r, $0] }
            let series = legendValue.flatMap { legendIndex[$0] } ?? 0
            let seriesName = legendValue.map { $0.isNull ? "(Blank)" : ValueFormatter.format($0, legCol.flatMap { data.formats[safe: $0] } ?? "") }
            let color = colors.seriesColor(series, name: seriesName ?? "")
            let label = catCols.isEmpty ? "\(r + 1)" : StatSupport.label(data: data, row: r, columns: catCols)
            out.append(Point(id: out.count, x: x, y: y,
                             size: sizeCol.flatMap { t[r, $0].asDouble },
                             color: color, series: series, label: label,
                             selection: SeriesModel.selection(data: data, row: r, columns: catCols + (legCol.map { [$0] } ?? [])),
                             row: r))
        }
        return out
    }
}
