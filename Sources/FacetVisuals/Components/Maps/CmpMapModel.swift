import Foundation
import CoreLocation
import CoreGraphics
import FacetCore

/// One plotted row of a bubble map.
struct CmpMapPoint {
    var row: Int
    var coordinate: CLLocationCoordinate2D
    var radius: CGFloat
    var colorHex: String
    /// Relative weight (0…1) for the heat-map layer.
    var weight: Double
    var group: Int
    var selection: DataPointSelection?
    var tooltip: CmpMapTooltipContent
}

/// Turns `VisualData` into plotted points: coordinates from `latitude`/`longitude` or geocoded
/// `location` text, bubble radius from `size`, colour from `legend`.
struct CmpMapModel {
    var points: [CmpMapPoint] = []
    /// Location strings without a coordinate yet (to be geocoded).
    var pending: [String] = []
    /// Location strings the geocoder could not find.
    var notFound: [String] = []
    var legend: [(label: String, colorHex: String)] = []
    var legendTitle = ""
    var usesGeocoding = false
    var hasFields = false
    /// Value range when bubbles are coloured by a gradient (choropleth fallback).
    var valueRange: (min: Double, max: Double)?
    var valueColumn: Int?

    /// - Parameters:
    ///   - resolve: cached/geocoded coordinate for a location string, if known.
    ///   - isMiss: true when the geocoder has confirmed the string has no result.
    init(env: CmpEnv, resolve: (String) -> CLLocationCoordinate2D?, isMiss: (String) -> Bool = { _ in false }) {
        let data = env.data, theme = env.theme, f = env.f
        let isRegionFallback = env.spec.type == .filledMap || env.spec.type == .shapeMap
        let latCol = data.indices(.latitude).first, lonCol = data.indices(.longitude).first
        let locCol = data.indices(.location).first
        let legCol = data.indices(.legend).first
        let sizeCol = data.indices(.size).first ?? (isRegionFallback ? data.indices(.values).first : nil)
        hasFields = (latCol != nil && lonCol != nil) || locCol != nil
        guard hasFields else { return }
        let useLatLon = latCol != nil && lonCol != nil
        usesGeocoding = !useLatLon

        let maxR = CGFloat(max(2, f.double("bubbles", "size", isRegionFallback ? 18 : 22)))
        let minR = CGFloat(max(1, min(Double(maxR), f.double("bubbles", "minSize", 4))))
        let uniformR = min(maxR, max(minR, 6))
        let baseHex = f.string("bubbles", "color", theme.dataColors.first ?? theme.accent)
        let sizeRange = sizeCol.flatMap { CmpConditionalFormat.range(data.table.columns[$0].values) }
        let sizeMax = max(abs(sizeRange?.max ?? 0), abs(sizeRange?.min ?? 0))

        var legendValues: [Value] = []
        if let lc = legCol {
            var seen = Set<Value>()
            for v in data.table.columns[lc].values where seen.insert(v).inserted { legendValues.append(v) }
            legendTitle = env.caption(lc)
            legend = legendValues.enumerated().map { i, v in
                (ValueFormatter.format(v, data.formats[safe: lc] ?? ""), theme.dataColors.isEmpty ? baseHex : theme.dataColors[i % theme.dataColors.count])
            }
        }
        let cf = CmpConditionalFormat(spec: env.spec)
        let colorRule = sizeCol.flatMap { cf.rule(.dataPointColor, field: data.fields[safe: $0] ?? nil) }
        if isRegionFallback, legCol == nil, let sc = sizeCol { valueRange = sizeRange; valueColumn = sc }
        let minHex = f.string("fill", "minColor", theme.minimum), maxHex = f.string("fill", "maxColor", theme.maximum)
        let midHex = f.value("fill", "midColor")?.stringValue

        var selectionColumns = data.indices(.location) + data.indices(.legend)
        if data.indices(.location).isEmpty { selectionColumns = CmpSelection.groupingColumns(data) }
        let titleCol = locCol ?? legCol
        var pendingSeen = Set<String>(), missSeen = Set<String>()

        for r in 0..<data.table.rowCount {
            var coord: CLLocationCoordinate2D?
            if useLatLon, let la = latCol, let lo = lonCol {
                if let lat = data.table[r, la].asDouble, let lon = data.table[r, lo].asDouble,
                   lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
                    coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            } else if let lc = locCol {
                let text = data.table[r, lc].asString.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                coord = resolve(text)
                if coord == nil {
                    if isMiss(text) { if missSeen.insert(text).inserted { notFound.append(text) } }
                    else if pendingSeen.insert(text).inserted { pending.append(text) }
                }
            }
            guard let coord else { continue }

            var radius = uniformR, weight = 1.0
            let sizeValue = sizeCol.flatMap { data.table[r, $0].asDouble }
            if let v = sizeValue, sizeMax > 0 {
                weight = min(1, abs(v) / sizeMax)
                radius = minR + (maxR - minR) * CGFloat(weight.squareRoot())
            } else if sizeCol != nil {
                radius = minR; weight = 0
            }
            var hex = baseHex
            var group = 0
            if let lc = legCol, let i = legendValues.firstIndex(of: data.table[r, lc]) {
                hex = legend[i].colorHex; group = i
            } else if let sc = sizeCol, let rule = colorRule,
                      let c = cf.colorHex(rule, value: data.table[r, cf.driverColumn(rule, column: sc, data: data)], range: sizeRange) {
                hex = c
            } else if isRegionFallback, let v = sizeValue, let range = sizeRange {
                hex = CmpColor.gradient(range.max > range.min ? (v - range.min) / (range.max - range.min) : 1, min: minHex, mid: midHex, max: maxHex)
            }
            var tip = CmpMapTooltipContent.forRow(r, env: env, titleColumn: titleCol)
            if titleCol == nil { tip.title = String(format: "%.4f, %.4f", coord.latitude, coord.longitude) }
            points.append(CmpMapPoint(row: r, coordinate: coord, radius: radius, colorHex: hex, weight: weight, group: group,
                                      selection: CmpSelection.point(data, row: r, columns: selectionColumns), tooltip: tip))
        }
    }

    /// Cheap fingerprint so the MapKit view only rebuilds annotations when the plotted points change.
    var signature: Int {
        var h = Hasher()
        h.combine(points.count)
        for p in points {
            h.combine(p.coordinate.latitude); h.combine(p.coordinate.longitude)
            h.combine(p.radius); h.combine(p.colorHex); h.combine(p.row)
        }
        return h.finalize()
    }
}

// MARK: - Screen-space selection

enum CmpMapHitTest {
    /// Indices of `screenPoints` inside a rectangle.
    static func inRect(_ rect: CGRect, _ screenPoints: [CGPoint]) -> [Int] {
        let r = rect.standardized
        return screenPoints.indices.filter { r.contains(screenPoints[$0]) }
    }
    /// Indices of `screenPoints` inside a freehand lasso (closed implicitly).
    static func inLasso(_ lasso: [CGPoint], _ screenPoints: [CGPoint]) -> [Int] {
        guard lasso.count >= 3 else { return [] }
        return screenPoints.indices.filter { CmpGeo.contains(screenPoints[$0], ring: lasso) }
    }
}

// MARK: - Heat map

/// Renders a density heat map: every point adds a smooth kernel to a low-resolution intensity grid,
/// which is colour-mapped and scaled up (bilinear) to give the blurred overlay.
enum CmpHeatmapRenderer {
    /// - Parameters:
    ///   - points: view-space positions (origin top-left) with weights 0…1.
    ///   - radius: kernel radius in points.
    ///   - intensity: multiplier on the normalised density (1 = hottest spot reaches the top of the ramp).
    ///   - ramp: hex colours from cool to hot.
    ///   - opacity: overall opacity 0…1.
    static func image(points: [(p: CGPoint, weight: Double)], size: CGSize, radius: CGFloat, intensity: Double,
                      ramp: [String], opacity: Double) -> CGImage? {
        let scale: CGFloat = 4
        let w = Int(ceil(size.width / scale)), h = Int(ceil(size.height / scale))
        guard w > 0, h > 0, w * h < 4_000_000, !ramp.isEmpty else { return nil }
        var grid = [Float](repeating: 0, count: w * h)
        let r = max(1, radius / scale)
        let ri = Int(ceil(r))
        for (p, weight) in points {
            let cx = p.x / scale, cy = p.y / scale
            if cx < -r || cy < -r || cx > CGFloat(w) + r || cy > CGFloat(h) + r { continue }
            let x0 = max(0, Int(cx) - ri), x1 = min(w - 1, Int(cx) + ri)
            let y0 = max(0, Int(cy) - ri), y1 = min(h - 1, Int(cy) + ri)
            guard x0 <= x1, y0 <= y1 else { continue }
            let wt = Float(max(0.08, weight))
            for y in y0...y1 {
                let dy = (CGFloat(y) + 0.5 - cy) / r
                for x in x0...x1 {
                    let dx = (CGFloat(x) + 0.5 - cx) / r
                    let d2 = dx * dx + dy * dy
                    if d2 < 1 { let k = Float(1 - d2); grid[y * w + x] += wt * k * k }
                }
            }
        }
        guard let peak = grid.max(), peak > 0 else { return nil }
        let stops = ramp.compactMap { HexColor.rgb($0) }
        guard !stops.isEmpty else { return nil }
        // 256-entry colour lookup table (premultiplied RGBA).
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let t = Double(i) / 255
            let pos = t * Double(stops.count - 1)
            let a = stops[min(stops.count - 1, Int(pos))], b = stops[min(stops.count - 1, Int(pos) + 1)]
            let k = pos - floor(pos)
            let alpha = min(1, t * 2.2) * opacity
            lut[i * 4] = UInt8(((a.r + (b.r - a.r) * k) * alpha * 255).rounded())
            lut[i * 4 + 1] = UInt8(((a.g + (b.g - a.g) * k) * alpha * 255).rounded())
            lut[i * 4 + 2] = UInt8(((a.b + (b.b - a.b) * k) * alpha * 255).rounded())
            lut[i * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let gain = Float(max(0.05, intensity)) / peak
        for i in 0..<(w * h) where grid[i] > 0 {
            let v = Int(min(1, grid[i] * gain) * 255)
            pixels[i * 4] = lut[v * 4]; pixels[i * 4 + 1] = lut[v * 4 + 1]
            pixels[i * 4 + 2] = lut[v * 4 + 2]; pixels[i * 4 + 3] = lut[v * 4 + 3]
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        return provider.flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
