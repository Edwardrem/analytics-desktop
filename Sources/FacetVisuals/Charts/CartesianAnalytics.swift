import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Analytics-pane overlays for cartesian charts, resolved into plot coordinates:
/// reference lines (constant / min / max / average / median / percentile) with optional shading,
/// least-squares trend lines, forecast lines with confidence bands, anomaly markers with their
/// expected range, and error bars.
struct CartesianAnalytics {
    struct RefLine: Identifiable {
        let id: Int
        let value: Double
        let label: String
        let color: Color
        let dash: [CGFloat]
        /// Other edge of a shaded region starting at `value`.
        let shadeTo: Double?
    }
    struct Trend: Identifiable { let id: Int; let x0: Double, y0: Double, x1: Double, y1: Double; let color: Color }
    struct BandPoint { let x: Double; let y: Double; let lo: Double; let hi: Double }
    struct ForecastLine: Identifiable { let id: Int; let points: [BandPoint]; let color: Color }
    struct Anomaly: Identifiable { let id: Int; let x: Double; let y: Double; let color: Color }
    struct Band: Identifiable { let id: Int; let points: [BandPoint]; let color: Color }
    struct ErrorBar: Identifiable { let id: Int; let c: Double; let lo: Double; let hi: Double; let cap: Double }

    struct Resolved {
        var lines: [RefLine] = []
        var trends: [Trend] = []
        var forecasts: [ForecastLine] = []
        var anomalies: [Anomaly] = []
        var bands: [Band] = []
        var errorBars: [ErrorBar] = []
    }

    let items: [AnalyticsItem]
    let overlays: AnalyticsOverlays
    /// Values the value axis must include so overlays stay visible.
    private(set) var extraExtent: [Double] = []

    static func dash(_ style: String) -> [CGFloat] {
        let s = style.lowercased()
        if s.hasPrefix("solid") { return [] }
        if s.hasPrefix("dotted") { return [1.5, 3.5] }
        return [5, 4]
    }

    init(spec: VisualSpec, model: SeriesModel, overlays: AnalyticsOverlays, kind: CartesianKind) {
        items = spec.analytics
        self.overlays = overlays
        let combo = kind.isCombo
        for i in items where i.kind == .constantLine {
            extraExtent.append(i.value)
            if i.style.lowercased().contains("band") { extraExtent.append(i.secondaryValue) }
        }
        if kind.stacking == .none {
            for fc in overlays.forecasts where !(combo && model.series.first { $0.column == fc.seriesColumn }?.isLine == true) {
                extraExtent += fc.upper + fc.lower + fc.values
            }
            for (_, band) in overlays.expectedBands { for b in band { extraExtent.append(b.lower); extraExtent.append(b.upper) } }
            if let e = items.first(where: { $0.kind == .errorBars }), !e.style.lowercased().contains("field") {
                let p = e.secondaryValue / 100
                for s in model.series where !(combo && s.isLine) { for v in s.values { if let v { extraExtent.append(v * (1 + p)); extraExtent.append(v * (1 - p)) } } }
            }
        }
    }

    private func targets(_ item: AnalyticsItem, _ model: SeriesModel, _ kind: CartesianKind) -> [SeriesModel.Series] {
        if let key = item.seriesKey, !key.isEmpty {
            let m = model.series.filter { $0.field?.key == key || $0.name == key }
            if !m.isEmpty { return m }
        }
        return kind.drawsBars ? model.series.filter { !$0.isLine } : model.series
    }

    func resolve(layout L: CartesianLayout, model: SeriesModel, colors: ColorResolver, style: ChartStyle, kind: CartesianKind) -> Resolved {
        var r = Resolved()
        var id = 0
        func nextID() -> Int { id += 1; return id }
        let stacked = kind.stacking != .none
        func plotY(_ v: Double, _ s: SeriesModel.Series?) -> Double {
            (s?.isLine == true && L.secondaryScale != nil) ? L.toPrimary(v) : v
        }
        let n = model.categories.count

        for item in items {
            let ts = targets(item, model, kind)
            let fmt = ts.first?.format ?? ""
            let color = item.color.flatMap { HexColor.rgb($0) != nil ? Color(hex: $0) : nil } ?? style.secondary
            switch item.kind {
            case .constantLine, .minLine, .maxLine, .averageLine, .medianLine, .percentileLine:
                let values: [Double] = stacked && (item.seriesKey ?? "").isEmpty
                    ? L.totals.map(\.sum)
                    : ts.flatMap { $0.values.compactMap { $0 } }
                let v: Double?, name: String
                switch item.kind {
                case .constantLine: v = item.value; name = ""
                case .minLine: v = values.min(); name = "Min"
                case .maxLine: v = values.max(); name = "Max"
                case .averageLine: v = ChartMath.mean(values); name = "Average"
                case .medianLine: v = ChartMath.median(values); name = "Median"
                default: v = ChartMath.percentile(values, item.value); name = "P\(Int(item.value))"
                }
                guard let raw = v, kind.stacking != .percent || item.kind == .constantLine else { continue }
                let title = item.name.isEmpty ? name : item.name
                let text = AxisFormatter.label(raw, units: .auto, format: kind.stacking == .percent ? "0%" : fmt)
                let st = item.style.lowercased()
                let y = plotY(raw, ts.count == 1 ? ts.first : nil)
                var shade: Double?
                if st.contains("shadeabove") { shade = L.valueScale.upper }
                else if st.contains("shadebelow") { shade = L.valueScale.lower }
                else if st.contains("band"), item.kind == .constantLine { shade = item.secondaryValue }
                r.lines.append(RefLine(id: nextID(), value: y, label: item.showLabel ? (title.isEmpty ? text : "\(title) \(text)") : "",
                                       color: color, dash: CartesianAnalytics.dash(item.style), shadeTo: shade))
            case .trendLine:
                if stacked && (item.seriesKey ?? "").isEmpty {
                    let pts = (0..<n).map { (x: L.catPos[$0], y: L.totals[$0].pos + L.totals[$0].neg) }
                    if let t = trend(pts, nextID(), color) { r.trends.append(t) }
                } else {
                    for s in ts {
                        let pts: [(x: Double, y: Double)] = (0..<n).compactMap { c in s.values[c].map { (L.catPos[c], plotY($0, s)) } }
                        let c = item.color == nil ? colors.seriesColor(s.index, name: s.name) : color
                        if let t = trend(pts, nextID(), c) { r.trends.append(t) }
                    }
                }
            case .errorBars:
                let byField = item.style.lowercased().contains("field")
                let cols = model.data.indices(.tooltips)
                func bounds(_ s: SeriesModel.Series, _ c: Int, _ v: Double, at y: Double) -> (Double, Double)? {
                    if byField {
                        guard cols.count >= 2, let row = s.rows[c], let lo = model.data.table[row, cols[0]].asDouble,
                              let hi = model.data.table[row, cols[1]].asDouble else { return nil }
                        return (y - (v - lo), y + (hi - v))
                    }
                    let d = abs(v) * item.secondaryValue / 100
                    return (y - d, y + d)
                }
                if kind.stacking != .percent {
                    for b in L.bars where !b.isBaseline && (kind.stacking == .none || b.isOuter) {
                        guard let s = model.series[safe: b.series], let (lo, hi) = bounds(s, b.cat, b.value, at: b.v1) else { continue }
                        r.errorBars.append(ErrorBar(id: nextID(), c: (b.c0 + b.c1) / 2, lo: lo, hi: hi, cap: min(0.12, (b.c1 - b.c0) * 0.3)))
                    }
                    if !kind.drawsArea || kind.stacking == .none {
                        for l in L.lines where !l.isBaseline && l.points.count <= 400 {
                            guard let s = model.series[safe: l.series] else { continue }
                            for p in l.points {
                                guard let (lo, hi) = bounds(s, p.cat, p.value, at: p.value) else { continue }
                                r.errorBars.append(ErrorBar(id: nextID(), c: p.x, lo: plotY(lo, s), hi: plotY(hi, s), cap: L.halfBand * 0.16))
                            }
                        }
                    }
                }
            default: break
            }
        }

        guard kind.stacking == .none else { return r }
        func cat(_ s: SeriesModel.Series, row: Int) -> Int? {
            s.rows.firstIndex(of: row) ?? (row < n && model.legendColumn == nil ? row : nil)
        }
        let fItem = items.first { $0.kind == .forecast }, aItem = items.first { $0.kind == .anomalies }
        for fc in overlays.forecasts {
            guard let s = model.series.first(where: { $0.column == fc.seriesColumn }),
                  let lastCat = s.values.lastIndex(where: { $0 != nil }), let lastV = s.values[lastCat] else { continue }
            let color = fItem?.color.map { Color(hex: $0) } ?? colors.seriesColor(s.index, name: s.name)
            var pts = [BandPoint(x: L.catPos[lastCat], y: plotY(lastV, s), lo: plotY(lastV, s), hi: plotY(lastV, s))]
            let lastX = L.catPos.max() ?? 0
            for k in fc.values.indices {
                let x = L.isContinuous ? (fc.labels[safe: k]?.asDouble ?? lastX + Double(k + 1) * L.halfBand * 2) : lastX + Double(k + 1)
                pts.append(BandPoint(x: x, y: plotY(fc.values[k], s), lo: plotY(fc.lower[safe: k] ?? fc.values[k], s),
                                     hi: plotY(fc.upper[safe: k] ?? fc.values[k], s)))
            }
            r.forecasts.append(ForecastLine(id: nextID(), points: pts, color: color))
        }
        for (col, band) in overlays.expectedBands {
            guard let s = model.series.first(where: { $0.column == col }) else { continue }
            let pts: [BandPoint] = band.enumerated().compactMap { row, b in
                guard let c = cat(s, row: row) else { return nil }
                return BandPoint(x: L.catPos[c], y: 0, lo: plotY(b.lower, s), hi: plotY(b.upper, s))
            }.sorted { $0.x < $1.x }
            r.bands.append(Band(id: nextID(), points: pts, color: colors.seriesColor(s.index, name: s.name)))
        }
        for a in overlays.anomalies {
            guard let s = model.series.first(where: { $0.column == a.seriesColumn }), let c = cat(s, row: a.row), let v = s.values[c] else { continue }
            r.anomalies.append(Anomaly(id: nextID(), x: L.catPos[c], y: plotY(v, s),
                                       color: aItem?.color.map { Color(hex: $0) } ?? style.theme.foregroundColor))
        }
        return r
    }

    private func trend(_ pts: [(x: Double, y: Double)], _ id: Int, _ color: Color) -> Trend? {
        guard let fit = ChartMath.linearRegression(pts), let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max() else { return nil }
        return Trend(id: id, x0: x0, y0: fit.intercept + fit.slope * x0, x1: x1, y1: fit.intercept + fit.slope * x1, color: color)
    }
}
