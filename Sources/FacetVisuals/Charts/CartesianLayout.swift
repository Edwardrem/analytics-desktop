import SwiftUI
import FacetCore
import FacetDesign

/// How a cartesian visual type draws: orientation, stacking and which mark families it uses.
struct CartesianKind {
    enum Stacking { case none, stacked, percent }
    var horizontal = false
    var stacking: Stacking = .none
    var drawsBars = false
    var drawsArea = false
    var isCombo = false
    /// Dot plot: markers only, with a hairline joining the series of each category.
    var drawsDots = false

    init?(_ type: VisualType) {
        switch type {
        case .stackedBar: horizontal = true; stacking = .stacked; drawsBars = true
        case .clusteredBar: horizontal = true; drawsBars = true
        case .stackedBar100: horizontal = true; stacking = .percent; drawsBars = true
        case .stackedColumn: stacking = .stacked; drawsBars = true
        case .clusteredColumn: drawsBars = true
        case .stackedColumn100: stacking = .percent; drawsBars = true
        case .line: break
        case .area: drawsArea = true
        case .stackedArea: drawsArea = true; stacking = .stacked
        case .stackedArea100: drawsArea = true; stacking = .percent
        case .lineStackedColumn: stacking = .stacked; drawsBars = true; isCombo = true
        case .lineClusteredColumn: drawsBars = true; isCombo = true
        case .dotPlot: drawsDots = true
        default: return nil
        }
    }
}

/// Format-pane options for cartesian charts, read once per render.
struct CartesianOptions {
    let kind: CartesianKind
    let catCard: String, valCard: String
    let innerPadding: Double, outerPadding: Double, cornerRadius: CGFloat
    let lineWidth: CGFloat, lineStyle: String, interpolation: String
    let showMarkers: Bool, markerSize: CGFloat, markerShape: String
    let seriesLabels: Bool, shadeArea: Bool
    let valMin: Double?, valMax: Double?, logScale: Bool, reverseValue: Bool, reverseCategory: Bool
    let units: DisplayUnits, decimals: Int?
    let showCatAxis: Bool, showValAxis: Bool, valGridlines: Bool, catGridlines: Bool
    let catTitle: String?, valTitle: String?
    let labelRotation: Double, concatenate: Bool, continuous: Bool?
    let showY2: Bool, y2Title: String?
    let dataLabels: Bool, dataLabelPosition: DataLabelPosition, totalLabels: Bool
    let zoomSlider: Bool

    init(spec: VisualSpec, style: ChartStyle, kind: CartesianKind) {
        let f = style.format
        self.kind = kind
        catCard = kind.horizontal ? "yAxis" : "xAxis"
        valCard = kind.horizontal ? "xAxis" : "yAxis"
        innerPadding = max(0, min(0.9, (f.value("bars", "innerPadding") ?? f.value("bars", "spacing"))?.doubleValue.map { $0 / 100 } ?? (kind.stacking == .none ? 0.26 : 0.34)))
        outerPadding = max(0, min(2, f.double("bars", "outerPadding", 0) / 100))
        cornerRadius = CGFloat(f.double("bars", "cornerRadius", 2.5))
        lineWidth = CGFloat(f.double("lines", "width", 2))
        lineStyle = f.string("lines", "style", "solid")
        interpolation = f.string("lines", "interpolation", "smooth")
        showMarkers = f.bool("lines", "showMarkers", false)
        markerSize = CGFloat(f.double("lines", "markerSize", kind.drawsDots ? 9 : 5))
        markerShape = f.string("lines", "markerShape", "auto")
        seriesLabels = f.bool("lines", "seriesLabels", false)
        shadeArea = f.bool("lines", "shadeArea", false)
        valMin = f.value(valCard, "min")?.doubleValue
        valMax = f.value(valCard, "max")?.doubleValue
        logScale = f.bool(valCard, "logScale", false) && kind.stacking != .percent
        reverseValue = f.bool(valCard, "reverse", false)
        reverseCategory = f.bool(catCard, "reverse", false)
        units = DisplayUnits(f.string(valCard, "displayUnits", "auto"))
        decimals = f.value(valCard, "decimals")?.doubleValue.map { Int($0) }
        showCatAxis = f.bool(catCard, "show", true)
        showValAxis = f.bool(valCard, "show", true)
        valGridlines = f.bool(valCard, "gridlines", true)
        catGridlines = f.bool(catCard, "gridlines", false)
        catTitle = f.bool(catCard, "showTitle", false) ? f.string(catCard, "title", "") : nil
        valTitle = f.bool(valCard, "showTitle", false) ? f.string(valCard, "title", "") : nil
        labelRotation = f.double(catCard, "labelRotation", 0)
        concatenate = f.bool(catCard, "concatenateLabels", true)
        continuous = f.value(catCard, "type")?.stringValue.map { $0 == "continuous" }
        showY2 = f.bool("y2Axis", "show", true)
        y2Title = f.bool("y2Axis", "showTitle", false) ? f.string("y2Axis", "title", "") : nil
        dataLabels = f.bool("dataLabels", "show", false)
        dataLabelPosition = DataLabelPosition(rawValue: f.string("dataLabels", "position", "auto")) ?? .auto
        totalLabels = f.bool("totalLabels", "show", false)
        zoomSlider = f.bool("zoomSlider", "show", false)
    }
}

/// Geometry of a cartesian chart in data units: bars, line segments, area bands, scales and axis ticks.
/// The category axis is numeric (band `i` spans i − 0.5 … i + 0.5, or real positions on continuous axes),
/// so the renderer and the hit-testing overlay share exact coordinates.
struct CartesianLayout {
    struct Bar: Identifiable {
        let id: Int
        let cat: Int, series: Int
        let c0: Double, c1: Double
        var v0: Double, v1: Double
        /// Raw (un-normalised) value for labels and tooltips.
        let value: Double
        let isBaseline: Bool
        var isOuter = false
    }
    struct LinePoint { let cat: Int; let x: Double; let y: Double; let value: Double }
    struct Line: Identifiable {
        let id: String
        let series: Int
        var points: [LinePoint]
        let isBaseline: Bool
        let secondary: Bool
    }
    struct AreaPoint { let x: Double; let y0: Double; let y1: Double }
    struct Area: Identifiable { let id: String; let series: Int; var points: [AreaPoint]; let isBaseline: Bool }
    struct Tick { let pos: Double; let label: String; let group: String }

    var bars: [Bar] = []
    var lines: [Line] = []
    var areas: [Area] = []
    /// Axis position per category (after reversal).
    var catPos: [Double] = []
    var catDomain: ClosedRange<Double> = 0...1
    var isContinuous = false
    var valueScale = AxisScale(lower: 0, upper: 1, ticks: [0, 1])
    var secondaryScale: AxisScale?
    /// Per category: (positive stack end, negative stack end, raw total) for total labels.
    var totals: [(pos: Double, neg: Double, sum: Double)] = []
    /// Half the width of a category band in axis units (for hit columns).
    var halfBand = 0.5
    /// Labels of categories appended by a forecast.
    var forecastLabels: [String] = []
    var signature = 0

    /// Maps a secondary-axis value onto the primary scale.
    func toPrimary(_ v: Double) -> Double {
        guard let s = secondaryScale, s.span > 0 else { return v }
        return valueScale.lower + (v - s.lower) / s.span * valueScale.span
    }

    init(model: SeriesModel, options o: CartesianOptions, forecasts: [AnalyticsOverlays.Forecast] = [],
         extraExtent: [Double] = [], sharedRange: ClosedRange<Double>? = nil, valueLength: CGFloat = 300, maxLinePoints: Int = 600) {
        let kind = o.kind
        let n = model.categories.count
        let barSeries = kind.drawsBars ? model.series.filter { !$0.isLine } : []
        let lineSeries = kind.drawsBars ? model.series.filter(\.isLine) : model.series
        let hasBase = model.hasBaseline

        // Category positions
        let positions = (o.continuous ?? !kind.drawsBars) && !kind.drawsBars && !kind.drawsDots ? model.continuousPositions : nil
        isContinuous = positions != nil
        var maxForecast = 0
        for fc in forecasts { maxForecast = max(maxForecast, fc.labels.count) }
        if let p = positions, let lo = p.min(), var hi = p.max() {
            catPos = p
            for fc in forecasts { for l in fc.labels { if let d = l.asDouble { hi = max(hi, d) } } }
            let pad = hi > lo ? (hi - lo) * 0.01 : 0.5
            catDomain = (lo - pad)...(hi + pad)
            halfBand = n > 1 ? (hi - lo) / Double(n - 1) / 2 : 0.5
        } else {
            let count = n + maxForecast
            let rev = o.reverseCategory != kind.horizontal // horizontal charts list the first category at the top
            catPos = (0..<n).map { rev ? Double(count - 1 - $0) : Double($0) }
            // Bars need the full band; lines breathe a little; areas run edge to edge.
            let edge = kind.drawsBars || kind.drawsDots ? 0.5 + o.outerPadding : (kind.drawsArea ? 0.04 : 0.3)
            catDomain = (-edge)...(Double(max(count, 1)) - 1 + edge)
            if let fc = forecasts.max(by: { $0.labels.count < $1.labels.count }) {
                let fmt = model.categoryColumns.first.flatMap { model.data.formats[safe: $0] } ?? ""
                forecastLabels = fc.labels.map { ValueFormatter.format($0, fmt) }
            }
        }

        // Bars
        var extent: [Double] = extraExtent
        totals = Array(repeating: (0, 0, 0), count: n)
        var nextID = 0
        if !barSeries.isEmpty {
            let inner = 1 - o.innerPadding
            let nb = Double(barSeries.count)
            for c in 0..<n {
                let p = catPos[c]
                switch kind.stacking {
                case .none:
                    let slot = inner / nb, gap = barSeries.count > 1 ? slot * 0.08 : 0
                    for (k, s) in barSeries.enumerated() {
                        // Horizontal charts reverse the slot order so the first series sits on top.
                        let kk = kind.horizontal ? Double(barSeries.count - 1 - k) : Double(k)
                        let c0 = p - inner / 2 + kk * slot + gap / 2, c1 = c0 + slot - gap
                        if hasBase, let b = s.baseline[c] {
                            bars.append(Bar(id: nextID, cat: c, series: s.index, c0: c0, c1: c1, v0: 0, v1: b, value: b, isBaseline: true, isOuter: true)); nextID += 1
                            extent.append(b)
                        }
                        if let v = s.values[c] {
                            bars.append(Bar(id: nextID, cat: c, series: s.index, c0: c0, c1: c1, v0: 0, v1: v, value: v, isBaseline: false, isOuter: true)); nextID += 1
                            extent.append(v)
                        }
                    }
                case .stacked, .percent:
                    let cells: [(s: SeriesModel.Series, total: Double, hi: Double?)] = barSeries.compactMap { s in
                        guard let total = hasBase ? (s.baseline[c] ?? s.values[c]) : s.values[c] else { return nil }
                        return (s, total, s.values[c])
                    }
                    let den = kind.stacking == .percent ? max(cells.reduce(0) { $0 + abs($1.total) }, 1e-12) : 1
                    var pos = 0.0, neg = 0.0, lastPos: Int?, lastNeg: Int?
                    for cell in cells {
                        let t = cell.total / den
                        let v0 = t >= 0 ? pos : neg
                        if t >= 0 { pos += t } else { neg += t }
                        if hasBase {
                            bars.append(Bar(id: nextID, cat: c, series: cell.s.index, c0: p - inner / 2, c1: p + inner / 2, v0: v0, v1: v0 + t, value: cell.total, isBaseline: true)); nextID += 1
                        }
                        if let hv = cell.hi {
                            let h = hasBase ? hv / den : t
                            bars.append(Bar(id: nextID, cat: c, series: cell.s.index, c0: p - inner / 2, c1: p + inner / 2, v0: v0, v1: v0 + h, value: hv, isBaseline: false))
                            if !hasBase, t != 0 { if t >= 0 { lastPos = bars.count - 1 } else { lastNeg = bars.count - 1 } }
                            nextID += 1
                        }
                        if hasBase, t != 0 {
                            let bi = bars.lastIndex { $0.isBaseline } ?? bars.count - 1
                            if t >= 0 { lastPos = bi } else { lastNeg = bi }
                        }
                    }
                    if let i = lastPos { bars[i].isOuter = true }
                    if let i = lastNeg { bars[i].isOuter = true }
                    totals[c] = (pos, neg, cells.reduce(0) { $0 + $1.total })
                    extent.append(pos); extent.append(neg)
                }
            }
        }

        // Lines and areas (values in raw units first; secondary mapping applied below)
        let stackedArea = kind.drawsArea && kind.stacking != .none
        var rawLines: [(series: Int, base: Bool, pts: [(cat: Int, x: Double, v: Double)])] = []
        var secondaryExtent: [Double] = []
        let useSecondary = kind.isCombo && o.showY2 && !barSeries.isEmpty && !lineSeries.isEmpty
        if stackedArea {
            var acc = [Double](repeating: 0, count: n)
            let den: [Double] = (0..<n).map { c in
                kind.stacking == .percent ? max(lineSeries.reduce(0) { $0 + abs((hasBase ? $1.baseline[c] : nil) ?? $1.values[c] ?? 0) }, 1e-12) : 1
            }
            for s in lineSeries {
                var pts: [AreaPoint] = [], hi: [AreaPoint] = []
                var top: [(cat: Int, x: Double, v: Double)] = []
                for c in 0..<n {
                    let total = ((hasBase ? s.baseline[c] : nil) ?? s.values[c] ?? 0) / den[c]
                    let y0 = acc[c]; acc[c] += total
                    pts.append(AreaPoint(x: catPos[c], y0: y0, y1: acc[c]))
                    if hasBase { hi.append(AreaPoint(x: catPos[c], y0: y0, y1: y0 + (s.values[c] ?? 0) / den[c])) }
                    top.append((c, catPos[c], acc[c]))
                    extent.append(acc[c])
                }
                areas.append(Area(id: "a\(s.index)", series: s.index, points: pts, isBaseline: hasBase))
                if hasBase { areas.append(Area(id: "h\(s.index)", series: s.index, points: hi, isBaseline: false)) }
                rawLines.append((s.index, false, top))
            }
            totals = (0..<n).map { c in (acc[c], 0, lineSeries.reduce(0) { $0 + ($1.values[c] ?? 0) }) }
        } else {
            for s in lineSeries {
                func collect(_ vals: [Double?]) -> [(cat: Int, x: Double, v: Double)] {
                    var out: [(cat: Int, x: Double, v: Double)] = []
                    for c in 0..<n { if let v = vals[c] { out.append((c, catPos[c], v)) } }
                    return out
                }
                let main = collect(s.values)
                if useSecondary { secondaryExtent += main.map(\.v) } else { extent += main.map(\.v) }
                if hasBase {
                    let b = collect(s.baseline)
                    if useSecondary { secondaryExtent += b.map(\.v) } else { extent += b.map(\.v) }
                    rawLines.append((s.index, true, b))
                }
                rawLines.append((s.index, false, main))
            }
        }

        // Value scale
        let ticks = kind.horizontal ? max(2, min(6, Int(valueLength / 84))) : ChartSizeClass.tickCount(valueLength)
        if kind.stacking == .percent {
            let hasNeg = extent.contains { $0 < -1e-9 }
            let t: [Double] = ticks >= 4 ? [0, 0.25, 0.5, 0.75, 1] : [0, 0.5, 1]
            valueScale = AxisScale(lower: hasNeg ? -1 : 0, upper: 1, ticks: hasNeg ? t.dropFirst().reversed().map { -$0 } + t : t)
        } else {
            let lo = sharedRange?.lowerBound ?? extent.min() ?? 0, hi = sharedRange?.upperBound ?? extent.max() ?? 1
            // Bars and areas are anchored at zero; plain lines may zoom into their range.
            let includeZero = kind.drawsBars || kind.drawsArea || (lo >= 0 && (hi - lo) > 0.3 * hi) || lo < 0 && hi > 0
            valueScale = AxisFormatter.niceScale(dataMin: lo, dataMax: hi, includeZero: includeZero, fixedMin: o.valMin, fixedMax: o.valMax,
                                                 targetTicks: ticks, log: o.logScale)
        }
        if useSecondary, let lo = secondaryExtent.min(), let hi = secondaryExtent.max() {
            // Same number of intervals as the primary axis so both share gridlines.
            let intervals = Double(max(1, valueScale.ticks.count - 1))
            let lo0 = min(lo, 0)
            var step = AxisFormatter.niceStep((max(hi, lo0 + 1e-9) - lo0) / intervals)
            var base = floor(lo0 / step) * step
            while base + step * intervals < hi { step = AxisFormatter.niceStep(step * 1.01); base = floor(lo0 / step) * step }
            secondaryScale = AxisScale(lower: base, upper: base + step * intervals, ticks: (0...Int(intervals)).map { base + Double($0) * step })
        }
        if o.logScale {
            for i in bars.indices { bars[i].v0 = max(bars[i].v0, valueScale.lower); bars[i].v1 = max(bars[i].v1, valueScale.lower) }
        }

        // Lines: split at blanks, down-sample long runs (LTTB) and map to the primary scale.
        for raw in rawLines {
            var pts = raw.pts
            if pts.count > maxLinePoints, !stackedArea {
                let keep = ChartMath.lttb(pts.map { ($0.x, $0.v) }, threshold: maxLinePoints)
                pts = keep.map { pts[$0] }
            }
            let secondary = useSecondary
            var seg: [LinePoint] = [], segIndex = 0, lastCat = -2
            func flush() {
                guard !seg.isEmpty else { return }
                lines.append(Line(id: "\(raw.base ? "b" : "l")\(raw.series)#\(segIndex)", series: raw.series, points: seg, isBaseline: raw.base, secondary: secondary))
                seg = []; segIndex += 1
            }
            let sampled = pts.count != raw.pts.count
            for p in pts {
                if !sampled, !stackedArea, lastCat >= 0, p.cat != lastCat + 1 { flush() }
                var y = secondary ? toPrimary(p.v) : p.v
                if o.logScale { y = max(y, valueScale.lower) }
                seg.append(LinePoint(cat: p.cat, x: p.x, y: y, value: p.v))
                lastCat = p.cat
            }
            flush()
        }
        if kind.drawsArea, !stackedArea {
            let floorV = o.logScale ? valueScale.lower : max(valueScale.lower, min(0, valueScale.upper))
            for l in lines {
                areas.append(Area(id: "a" + l.id, series: l.series, points: l.points.map { AreaPoint(x: $0.x, y0: floorV, y1: $0.y) }, isBaseline: l.isBaseline))
            }
        }

        var h = Hasher()
        for s in model.series { h.combine(s.values); h.combine(s.baseline) }
        h.combine(n)
        signature = h.finalize()
    }

    /// How category labels are laid out: which ticks are labelled, the width each label may use and
    /// whether labels wrap onto two lines.
    struct CategoryAxis {
        var ticks: [Tick] = []
        var labelWidth: CGFloat = 0
        var wraps = false
        /// Drop (rather than re-anchor) labels that would overflow the trailing edge.
        var dropsOverflow = false
    }

    /// Narrowest width at which `s` fits on two lines.
    static func wrappedWidth(_ s: String, fontSize: CGFloat) -> CGFloat {
        let words = s.split(separator: " ").map(String.init)
        guard words.count > 1 else { return ChartText.size(s, fontSize: fontSize).width }
        var best = CGFloat.infinity
        for i in 1..<words.count {
            let a = ChartText.size(words[..<i].joined(separator: " "), fontSize: fontSize).width
            let b = ChartText.size(words[i...].joined(separator: " "), fontSize: fontSize).width
            best = min(best, max(a, b))
        }
        return best
    }

    /// Axis ticks for the category axis that fit `length` points without colliding.
    func categoryAxis(model: SeriesModel, options o: CartesianOptions, length: CGFloat, fontSize: CGFloat,
                      window: ClosedRange<Double>, maxLabelWidth: CGFloat) -> CategoryAxis {
        if isContinuous {
            let target = max(2, Int(length / 84))
            let ticks: [Tick]
            if model.axisKind == .date {
                ticks = AxisFormatter.dateTicks(min: Value.date(fromSerial: window.lowerBound), max: Value.date(fromSerial: window.upperBound), targetCount: target)
                    .map { Tick(pos: Value.serial(from: $0.date), label: $0.label, group: "") }
            } else {
                let s = AxisFormatter.niceScale(dataMin: window.lowerBound, dataMax: window.upperBound, includeZero: false, targetTicks: target)
                let fmt = model.categoryColumns.first.flatMap { model.data.formats[safe: $0] } ?? ""
                ticks = s.ticks.filter { window.contains($0) }.map { Tick(pos: $0, label: AxisFormatter.label($0, units: .none, format: fmt), group: "") }
            }
            return CategoryAxis(ticks: ticks, labelWidth: ticks.map { ChartText.size($0.label, fontSize: fontSize).width }.max() ?? 0, dropsOverflow: true)
        }
        let nested = !o.concatenate && model.categoryColumns.count > 1
        var all: [Tick] = model.categories.enumerated().map { i, c in
            Tick(pos: catPos[i], label: nested ? (c.levels.last ?? c.label) : c.label,
                 group: nested ? c.levels.dropLast().joined(separator: " ") : "")
        }
        let last = (catPos.max() ?? -1)
        let rev = o.reverseCategory != o.kind.horizontal
        for (k, l) in forecastLabels.enumerated() {
            let p = rev ? Double(forecastLabels.count - 1 - k) : last + 1 + Double(k)
            all.append(Tick(pos: p, label: l, group: ""))
        }
        let visible = all.filter { window.contains($0.pos) }.sorted { $0.pos < $1.pos }
        guard !visible.isEmpty else { return CategoryAxis() }
        let band = length / CGFloat(max(1, window.upperBound - window.lowerBound))
        func every(_ step: Int) -> [Tick] { step <= 1 ? visible : visible.enumerated().filter { $0.offset % step == 0 }.map(\.element) }
        if o.kind.horizontal {
            let w = min(maxLabelWidth, visible.map { ChartText.size($0.label, fontSize: fontSize).width }.max() ?? 0)
            return CategoryAxis(ticks: every(Int(((fontSize + 5) / max(band, 0.01)).rounded(.up))), labelWidth: w)
        }
        if o.labelRotation >= 30 {
            return CategoryAxis(ticks: every(Int(((fontSize + 6) / max(band, 0.01)).rounded(.up))), labelWidth: maxLabelWidth)
        }
        let sample = visible.count > 400 ? Array(visible.prefix(200) + visible.suffix(200)) : visible
        let full = sample.map { ChartText.size($0.label, fontSize: fontSize).width }.max() ?? 0
        if full + 8 <= band { return CategoryAxis(ticks: visible, labelWidth: full) }
        let wrapped = sample.map { CartesianLayout.wrappedWidth($0.label, fontSize: fontSize) }.max() ?? 0
        if wrapped + 8 <= band { return CategoryAxis(ticks: visible, labelWidth: band - 6, wraps: true) }
        // Few, wide bands: keep every label and truncate. Many narrow bands: label every n-th category in full.
        if band >= 46 { return CategoryAxis(ticks: visible, labelWidth: band - 6, wraps: true) }
        let w = min(full, maxLabelWidth)
        return CategoryAxis(ticks: every(Int(((w + 10) / max(band, 0.01)).rounded(.up))), labelWidth: w, dropsOverflow: true)
    }
}
