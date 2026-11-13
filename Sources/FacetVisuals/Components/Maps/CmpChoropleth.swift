import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// Filled map / shape map drawn from a user-supplied GeoJSON or TopoJSON file: regions are projected
// and filled in a Canvas (no network, snapshots cleanly), coloured by `values` or `legend`.

/// Matches data rows to shape features and resolves each feature's colour.
struct CmpChoroplethModel {
    let shapes: CmpGeoShapes
    let locationColumn: Int?
    let valueColumn: Int?
    let legendColumn: Int?
    /// feature index → data row.
    var featureRow: [Int: Int] = [:]
    /// Location values that matched no feature.
    var unmatched: [String] = []
    var range: (min: Double, max: Double)?
    var legendValues: [Value] = []
    private(set) var fillHex: [Int: String] = [:]
    let emptyHex: String
    let rampHex: [String]

    init(env: CmpEnv, shapes: CmpGeoShapes) {
        self.shapes = shapes
        let data = env.data, theme = env.theme
        locationColumn = data.indices(.location).first
        valueColumn = data.indices(.values).first
        legendColumn = data.indices(.legend).first
        let minHex = env.f.string("fill", "minColor", theme.minimum)
        let maxHex = env.f.string("fill", "maxColor", theme.maximum)
        let midHex = env.f.value("fill", "midColor")?.stringValue
        rampHex = midHex.map { [minHex, $0, maxHex] } ?? [minHex, maxHex]
        emptyHex = env.f.string("fill", "emptyColor", HexColor.lerp(theme.cardBackground, theme.foreground, theme.isDark ? 0.14 : 0.07))
        guard let loc = locationColumn else { return }

        let index = shapes.matchIndex(matchProperty: env.f.string("shape", "matchProperty", ""))
        for r in 0..<data.table.rowCount {
            let text = data.table[r, loc].asString
            if let fi = index[CmpGeo.normalise(text)] {
                if featureRow[fi] == nil { featureRow[fi] = r }
            } else if !text.isEmpty { unmatched.append(text) }
        }
        if let vc = valueColumn { range = CmpConditionalFormat.range(data.table.columns[vc].values) }
        if let lc = legendColumn {
            var seen = Set<Value>()
            for v in data.table.columns[lc].values where seen.insert(v).inserted { legendValues.append(v) }
        }
        let cf = CmpConditionalFormat(spec: env.spec)
        let valueField = valueColumn.flatMap { data.fields[safe: $0] ?? nil }
        let rule = cf.rule(.dataPointColor, field: valueField) ?? cf.rule(.background, field: valueField)
        for (fi, r) in featureRow {
            if let vc = valueColumn {
                let v = data.table[r, vc]
                if let rule {
                    let driver = cf.driverColumn(rule, column: vc, data: data)
                    let driverRange = driver == vc ? range : CmpConditionalFormat.range(data.table.columns[driver].values)
                    if let hex = cf.colorHex(rule, value: data.table[r, driver], range: driverRange) { fillHex[fi] = hex; continue }
                }
                if let d = v.asDouble, v.isNumber, let range {
                    let t = range.max > range.min ? (d - range.min) / (range.max - range.min) : 1
                    fillHex[fi] = CmpColor.gradient(t, min: minHex, mid: midHex, max: maxHex)
                }
            } else if let lc = legendColumn, let i = legendValues.firstIndex(of: data.table[r, lc]), !theme.dataColors.isEmpty {
                fillHex[fi] = theme.dataColors[i % theme.dataColors.count]
            } else {
                fillHex[fi] = maxHex
            }
        }
    }

    func selection(feature: Int, data: VisualData) -> DataPointSelection? {
        guard let r = featureRow[feature], let loc = locationColumn else { return nil }
        return CmpSelection.point(data, row: r, columns: [loc])
    }
}

/// Projected paths for one canvas size, cached across hover redraws.
final class CmpGeoPathCache {
    private var key = ""
    private(set) var paths: [Path] = []
    private(set) var labelAnchors: [(point: CGPoint, width: CGFloat)] = []

    func prepare(shapes: CmpGeoShapes, projection: CmpGeoProjection, size: CGSize, signature: Int) {
        let k = "\(Int(size.width))x\(Int(size.height))|\(projection.rawValue)|\(signature)"
        guard k != key else { return }
        key = k
        // Project everything once, then fit to the canvas keeping aspect ratio.
        var lo = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity), hi = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        let projected: [(polys: [[[CGPoint]]], lines: [[CGPoint]], points: [CGPoint])] = shapes.features.map { f in
            func pr(_ p: CGPoint) -> CGPoint {
                let q = projection.project(p)
                lo.x = min(lo.x, q.x); lo.y = min(lo.y, q.y); hi.x = max(hi.x, q.x); hi.y = max(hi.y, q.y)
                return q
            }
            return (f.polygons.map { $0.map { $0.map(pr) } }, f.lines.map { $0.map(pr) }, f.points.map(pr))
        }
        let w = max(hi.x - lo.x, 1e-9), h = max(hi.y - lo.y, 1e-9)
        let scale = min(size.width / w, size.height / h)
        let ox = (size.width - w * scale) / 2 - lo.x * scale, oy = (size.height - h * scale) / 2 - lo.y * scale
        func fit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + ox, y: p.y * scale + oy) }
        paths = []; labelAnchors = []
        for f in projected {
            var path = Path()
            var best: (area: CGFloat, ring: [CGPoint])?
            for poly in f.polys {
                for (ri, ring) in poly.enumerated() {
                    let pts = ring.map(fit)
                    path.addLines(pts); path.closeSubpath()
                    if ri == 0 {
                        let a = CmpGeo.area(pts)
                        if a > (best?.area ?? -1) { best = (a, pts) }
                    }
                }
            }
            for line in f.lines { path.addLines(line.map(fit)) }
            for p in f.points { let q = fit(p); path.addEllipse(in: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)) }
            paths.append(path)
            if let best {
                let xs = best.ring.map(\.x)
                labelAnchors.append((CmpGeo.centroid(best.ring), (xs.max() ?? 0) - (xs.min() ?? 0)))
            } else {
                let b = path.boundingRect
                labelAnchors.append((CGPoint(x: b.midX, y: b.midY), b.width))
            }
        }
    }
}

struct CmpChoroplethView: View {
    let env: CmpEnv
    let shapes: CmpGeoShapes

    @State private var cache = CmpGeoPathCache()
    @State private var hover: Int?
    @State private var hoverPoint: CGPoint = .zero
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @FocusState private var focused: Bool
    @State private var showRing = false

    var body: some View {
        let model = CmpChoroplethModel(env: env, shapes: shapes)
        let theme = env.theme
        GeometryReader { geo in
            let showLegend = env.f.bool("legend", "show", true) && geo.size.height >= 96 && geo.size.width >= 150
                && (model.valueColumn != nil || model.legendColumn != nil)
            let legendTop = env.f.string("legend", "position", "bottom") == "top"
            VStack(spacing: 6) {
                if showLegend, legendTop { legend(model) }
                canvas(model)
                if showLegend, !legendTop { legend(model) }
            }
        }
        .focusable(env.isInteractive)
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            if focused, showRing { RoundedRectangle(cornerRadius: 4).strokeBorder(theme.accentColor.opacity(0.7), lineWidth: 1.5).padding(-3) }
        }
        .onKeyPress(.rightArrow) { step(1, model); return .handled }
        .onKeyPress(.leftArrow) { step(-1, model); return .handled }
        .onKeyPress(.downArrow) { step(1, model); return .handled }
        .onKeyPress(.upArrow) { step(-1, model); return .handled }
        .onKeyPress(.space) { activate(hover, model); return .handled }
        .onKeyPress(.return) { activate(hover, model); return .handled }
        .onKeyPress(.escape) { hover = nil; env.context.onSelect([], false); return .handled }
        .onChange(of: focused) { _, f in showRing = f && CmpMapChromeFocus.arrivedByKeyboard }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(env.spec.type.displayName), \(model.featureRow.count) regions with data")
        .accessibilityRepresentation { accessibilityList(model) }
    }

    // MARK: Canvas

    private func canvas(_ model: CmpChoroplethModel) -> some View {
        let theme = env.theme
        let projection = CmpGeoProjection.resolve(env.f.string("shape", "projection", "auto"), shapes: shapes)
        let outlineHex = env.f.string("shape", "outlineColor", theme.isHighContrast ? theme.foreground : theme.cardBackground)
        let outlineWidth = env.f.double("shape", "outlineWidth", theme.isHighContrast ? 1 : 0.75)
        let showUnmatched = env.f.bool("shape", "showUnmatched", true)
        let showLabels = env.f.bool("shape", "labels", false)
        let hasSelection = !env.context.selection.isEmpty
        return GeometryReader { geo in
            let size = geo.size
            let z = min(12, max(1, zoom * pinch))
            let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
            let transform = viewTransform(size: size, zoom: z, offset: offset)
            let _ = cache.prepare(shapes: shapes, projection: projection, size: size, signature: shapes.features.count)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.concatenate(transform)
                    let lw = outlineWidth / z
                    for (i, path) in cache.paths.enumerated() {
                        let matched = model.fillHex[i]
                        if matched == nil, !showUnmatched { continue }
                        var opacity = 1.0
                        if hasSelection { opacity = model.selection(feature: i, data: env.data).map(env.context.emphasis) ?? 0.3 }
                        let feature = shapes.features[i]
                        if feature.polygons.isEmpty, feature.points.isEmpty {
                            ctx.stroke(path, with: .color(Color(hex: matched ?? theme.secondaryForeground).opacity(opacity)), lineWidth: 1.5 / z)
                        } else {
                            ctx.fill(path, with: .color(Color(hex: matched ?? model.emptyHex).opacity(opacity)), style: FillStyle(eoFill: true))
                            ctx.stroke(path, with: .color(Color(hex: outlineHex)), lineWidth: lw)
                        }
                    }
                    // Selected and hovered outlines on top.
                    for (i, path) in cache.paths.enumerated() where hasSelection {
                        if let p = model.selection(feature: i, data: env.data), env.context.isSelected(p) {
                            ctx.stroke(path, with: .color(theme.accentColor), lineWidth: 2 / z)
                        }
                    }
                    if let h = hover, let path = cache.paths[safe: h] {
                        ctx.stroke(path, with: .color(theme.foregroundColor.opacity(theme.isHighContrast ? 1 : 0.75)), lineWidth: 1.5 / z)
                    }
                    if showLabels {
                        let labelFont = NSFont.systemFont(ofSize: max(8, theme.label.size - 1), weight: .medium)
                        let fits: [Bool] = cache.labelAnchors.enumerated().map { i, anchor in
                            guard let name = shapes.features[i].name else { return false }
                            return CmpFit.width(name, font: labelFont) / z < anchor.width * 0.9
                        }
                        // Labels are all-or-mostly: a sprinkling of the few that fit reads as noise.
                        let enough = fits.filter { $0 }.count * 10 >= fits.count * 6
                        for (i, anchor) in cache.labelAnchors.enumerated() where enough && fits[i] {
                            guard let name = shapes.features[i].name, model.fillHex[i] != nil || showUnmatched else { continue }
                            let fontSize = max(8, theme.label.size - 1) / z
                            var on = model.fillHex[i] ?? model.emptyHex
                            if hasSelection {
                                // Dimmed regions blend towards the card, so pick the label colour for the blended fill.
                                let k = model.selection(feature: i, data: env.data).map(env.context.emphasis) ?? 0.3
                                on = HexColor.lerp(theme.cardBackground, on, k)
                            }
                            ctx.draw(Text(name).font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(Color(hex: CmpColor.readableText(on: on)).opacity(0.9)), at: anchor.point)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard env.isInteractive else { return }
                    switch phase {
                    case .active(let p):
                        hoverPoint = p
                        hover = hit(p, transform: transform, model: model, showUnmatched: showUnmatched)
                    case .ended: hover = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    guard env.isInteractive else { return }
                    focused = true
                    activate(hit(tap.location, transform: transform, model: model, showUnmatched: false), model)
                })
                .simultaneousGesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in
                        zoom = min(12, max(1, zoom * v.magnification))
                        if zoom == 1 { pan = .zero }
                    })
                .simultaneousGesture(DragGesture(minimumDistance: 4).updating($drag) { v, s, _ in if zoom > 1 { s = v.translation } }
                    .onEnded { v in if zoom > 1 { pan.width += v.translation.width; pan.height += v.translation.height } })

                if let h = hover, env.f.bool("tooltips", "show", true), let content = tooltip(h, model) {
                    let anchor = hoverPoint == .zero ? (cache.labelAnchors[safe: h]?.point.applying(transform) ?? .zero) : hoverPoint
                    let origin = CmpMapTooltip.origin(for: content, near: anchor, in: CGRect(origin: .zero, size: size))
                    CmpMapTooltip(content: content, theme: theme).offset(x: origin.x, y: origin.y)
                }
                if zoom > 1, env.isInteractive {
                    CmpMapToolbar(theme: theme) {
                        CmpMapToolButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Zoom to fit", theme: theme) {
                            withAnimation(Design.Motion.standard) { zoom = 1; pan = .zero }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipped()
        }
    }

    private func viewTransform(size: CGSize, zoom: CGFloat, offset: CGSize) -> CGAffineTransform {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGAffineTransform(translationX: c.x + offset.width, y: c.y + offset.height)
            .scaledBy(x: zoom, y: zoom).translatedBy(x: -c.x, y: -c.y)
    }

    /// Topmost feature under a view-space point (matched features only unless `showUnmatched`).
    private func hit(_ p: CGPoint, transform: CGAffineTransform, model: CmpChoroplethModel, showUnmatched: Bool) -> Int? {
        let q = p.applying(transform.inverted())
        for i in cache.paths.indices.reversed() {
            if model.fillHex[i] == nil, !showUnmatched { continue }
            if cache.paths[i].boundingRect.contains(q), cache.paths[i].contains(q, eoFill: true) { return i }
        }
        return nil
    }

    private func tooltip(_ feature: Int, _ model: CmpChoroplethModel) -> CmpMapTooltipContent? {
        if let r = model.featureRow[feature] {
            var c = CmpMapTooltipContent.forRow(r, env: env, titleColumn: model.locationColumn)
            if c.title.isEmpty { c.title = shapes.features[feature].name ?? "" }
            return c
        }
        guard let name = shapes.features[feature].name else { return nil }
        return CmpMapTooltipContent(title: name, rows: [["", "No data"]])
    }

    private func activate(_ feature: Int?, _ model: CmpChoroplethModel) {
        let additive = NSEvent.modifierFlags.contains(.command)
        guard let feature, let point = model.selection(feature: feature, data: env.data) else {
            if !additive { env.context.onSelect([], false) }
            return
        }
        env.context.onSelect([point], additive)
    }

    /// Keyboard: move the focus ring through regions that have data.
    private func step(_ delta: Int, _ model: CmpChoroplethModel) {
        let order = model.featureRow.keys.sorted { (model.featureRow[$0] ?? 0) < (model.featureRow[$1] ?? 0) }
        guard !order.isEmpty else { return }
        let current = hover.flatMap { order.firstIndex(of: $0) }
        let next = current.map { ($0 + delta + order.count) % order.count } ?? (delta > 0 ? 0 : order.count - 1)
        hoverPoint = .zero
        showRing = true
        hover = order[next]
    }

    // MARK: Legend

    @ViewBuilder private func legend(_ model: CmpChoroplethModel) -> some View {
        ViewThatFits(in: .horizontal) {
            legendRow(model, title: true, unmatched: true)
            legendRow(model, title: false, unmatched: true)
            legendRow(model, title: false, unmatched: false)
        }
    }

    private func legendRow(_ model: CmpChoroplethModel, title: Bool, unmatched: Bool) -> some View {
        let theme = env.theme
        return HStack(spacing: 8) {
            if let vc = model.valueColumn, let range = model.range {
                let fmt = env.data.formats[safe: vc] ?? ""
                CmpMapGradientLegend(title: title ? env.caption(vc) : "",
                                     minLabel: CmpNumber.callout(.double(range.min), format: fmt),
                                     maxLabel: CmpNumber.callout(.double(range.max), format: fmt),
                                     stops: model.rampHex.map { Color(hex: $0) }, theme: theme)
            } else if let lc = model.legendColumn {
                CmpMapCategoryLegend(title: title ? env.caption(lc) : "", entries: model.legendValues.enumerated().map {
                    (ValueFormatter.format($1, env.data.formats[safe: lc] ?? ""), theme.dataColor($0))
                }, theme: theme)
            }
            if unmatched, !model.unmatched.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.circle").font(.system(size: 10))
                    Text("\(model.unmatched.count) unmatched").font(.system(size: theme.label.size)).lineLimit(1)
                }
                .foregroundStyle(theme.secondaryColor)
                .fixedSize()
                .help("No shape matched: " + model.unmatched.prefix(20).joined(separator: ", ") + (model.unmatched.count > 20 ? "…" : ""))
                .accessibilityLabel("\(model.unmatched.count) locations matched no shape")
            }
        }
    }

    private func accessibilityList(_ model: CmpChoroplethModel) -> some View {
        let rows = model.featureRow.sorted { $0.value < $1.value }.prefix(300)
        return VStack {
            ForEach(Array(rows), id: \.key) { feature, row in
                let content = CmpMapTooltipContent.forRow(row, env: env, titleColumn: model.locationColumn)
                Button(content.title) { activate(feature, model) }
                    .accessibilityValue(content.rows.map { "\($0[0]) \($0[1])" }.joined(separator: ", "))
                    .accessibilityAddTraits(model.selection(feature: feature, data: env.data).map(env.context.isSelected) == true ? [.isSelected] : [])
            }
        }
    }
}
