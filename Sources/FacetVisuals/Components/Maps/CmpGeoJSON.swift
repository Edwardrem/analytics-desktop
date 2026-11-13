import Foundation
import CoreGraphics

// GeoJSON / TopoJSON shape files for filled and shape maps: model, parser, TopoJSON arc decoder,
// name matching, projection and hit-testing. Pure logic — no UI.

/// One region (or line / point set) from a shape file. Coordinates are stored as (x: longitude, y: latitude)
/// or, for pre-projected files, raw planar x/y.
struct CmpGeoFeature {
    var id: String?
    var properties: [String: String] = [:]
    /// polygon → rings (first is the exterior, the rest holes) → points.
    var polygons: [[[CGPoint]]] = []
    var lines: [[CGPoint]] = []
    var points: [CGPoint] = []

    static let nameKeys = ["name", "NAME", "Name", "admin", "ADMIN", "name_long", "NAME_LONG", "NAME_1", "name_en", "NAME_EN", "nom", "title", "label"]

    /// Display name: the first well-known name property, else the id.
    var name: String? {
        for k in CmpGeoFeature.nameKeys { if let v = properties[k], !v.isEmpty { return v } }
        return id
    }

    var bounds: CGRect? {
        var lo = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity), hi = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        func add(_ p: CGPoint) { lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y) }
        for poly in polygons { for ring in poly { ring.forEach(add) } }
        for l in lines { l.forEach(add) }
        points.forEach(add)
        return lo.x <= hi.x ? CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y) : nil
    }

    /// Even-odd containment in the feature's polygons (coordinates in the same space as the feature).
    func contains(_ p: CGPoint) -> Bool {
        polygons.contains { CmpGeo.contains(p, rings: $0) }
    }
}

enum CmpGeoError: LocalizedError {
    case notJSON
    case unsupported(String)
    case noShapes
    case badTopology(String)

    var errorDescription: String? {
        switch self {
        case .notJSON: return "The shape file is not valid JSON. Supply a GeoJSON or TopoJSON document."
        case .unsupported(let t): return "Unsupported shape file type “\(t)”. Expected a GeoJSON FeatureCollection, Feature or geometry, or a TopoJSON Topology."
        case .noShapes: return "The shape file contains no polygons, lines or points."
        case .badTopology(let why): return "The TopoJSON topology is malformed: \(why)."
        }
    }
}

/// A parsed shape file.
struct CmpGeoShapes {
    var features: [CmpGeoFeature]
    /// True when the source was TopoJSON.
    var isTopology = false

    var bounds: CGRect {
        features.compactMap(\.bounds).reduce(nil as CGRect?) { $0?.union($1) ?? $1 } ?? .zero
    }

    /// True when every coordinate is a plausible longitude/latitude.
    var looksGeographic: Bool {
        let b = bounds
        return b.minX >= -181 && b.maxX <= 181 && b.minY >= -91 && b.maxY <= 91
    }

    /// Lookup from a normalised location string to a feature index. With `matchProperty` set only that
    /// property (and the feature id) is matched; otherwise the id, well-known name properties, then every
    /// other string property are tried, in that priority.
    func matchIndex(matchProperty: String = "") -> [String: Int] {
        var index: [String: Int] = [:]
        func put(_ s: String?, _ i: Int) {
            guard let s else { return }
            let k = CmpGeo.normalise(s)
            if !k.isEmpty, index[k] == nil { index[k] = i }
        }
        for (i, f) in features.enumerated() { put(f.id, i) }
        if !matchProperty.isEmpty {
            for (i, f) in features.enumerated() { put(f.properties[matchProperty], i) }
            return index
        }
        for k in CmpGeoFeature.nameKeys { for (i, f) in features.enumerated() { put(f.properties[k], i) } }
        for (i, f) in features.enumerated() {
            for k in f.properties.keys.sorted() where !CmpGeoFeature.nameKeys.contains(k) { put(f.properties[k], i) }
        }
        return index
    }
}

enum CmpGeo {
    /// Case-, whitespace- and diacritic-insensitive key for matching location text to feature names.
    static func normalise(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// Ray-casting point-in-ring test.
    static func contains(_ p: CGPoint, ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Even-odd test over an exterior ring plus holes.
    static func contains(_ p: CGPoint, rings: [[CGPoint]]) -> Bool {
        rings.reduce(false) { $0 != contains(p, ring: $1) }
    }

    /// Area-weighted centroid of a ring (falls back to the vertex mean for degenerate rings).
    static func centroid(_ ring: [CGPoint]) -> CGPoint {
        guard !ring.isEmpty else { return .zero }
        var a: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        var j = ring.count - 1
        for i in ring.indices {
            let cross = ring[j].x * ring[i].y - ring[i].x * ring[j].y
            a += cross; cx += (ring[j].x + ring[i].x) * cross; cy += (ring[j].y + ring[i].y) * cross
            j = i
        }
        if abs(a) < 1e-12 {
            let n = CGFloat(ring.count)
            return CGPoint(x: ring.map(\.x).reduce(0, +) / n, y: ring.map(\.y).reduce(0, +) / n)
        }
        return CGPoint(x: cx / (3 * a), y: cy / (3 * a))
    }

    static func area(_ ring: [CGPoint]) -> CGFloat {
        var a: CGFloat = 0
        var j = ring.count - 1
        for i in ring.indices { a += ring[j].x * ring[i].y - ring[i].x * ring[j].y; j = i }
        return abs(a) / 2
    }
}

/// Map projections for shape files. Output is planar with y growing downwards (screen convention).
enum CmpGeoProjection: String {
    case mercator, equirectangular, identity, screen

    /// Resolves the `format["shape"]["projection"]` value; "auto" picks Mercator for lon/lat data and
    /// `identity` (y flipped) for pre-projected coordinates.
    static func resolve(_ name: String, shapes: CmpGeoShapes) -> CmpGeoProjection {
        if let p = CmpGeoProjection(rawValue: name) { return p }
        return shapes.looksGeographic ? .mercator : .identity
    }

    func project(_ p: CGPoint) -> CGPoint {
        switch self {
        case .mercator:
            let lat = max(-85, min(85, Double(p.y))) * .pi / 180
            return CGPoint(x: Double(p.x) * .pi / 180, y: -log(tan(.pi / 4 + lat / 2)))
        case .equirectangular: return CGPoint(x: p.x * .pi / 180, y: -p.y * .pi / 180)
        case .identity: return CGPoint(x: p.x, y: -p.y)
        case .screen: return p
        }
    }
}

// MARK: - Parser

enum CmpGeoParser {
    /// Parses GeoJSON (FeatureCollection, Feature, or bare geometry) or TopoJSON (Topology).
    static func parse(_ text: String) throws -> CmpGeoShapes {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CmpGeoError.notJSON }
        let type = obj["type"] as? String ?? ""
        var shapes: CmpGeoShapes
        switch type {
        case "Topology": shapes = CmpGeoShapes(features: try topology(obj), isTopology: true)
        case "FeatureCollection":
            let list = obj["features"] as? [[String: Any]] ?? []
            shapes = CmpGeoShapes(features: list.flatMap { feature($0) })
        case "Feature": shapes = CmpGeoShapes(features: feature(obj))
        case "Point", "MultiPoint", "LineString", "MultiLineString", "Polygon", "MultiPolygon", "GeometryCollection":
            var f = CmpGeoFeature()
            addGeometry(obj, to: &f)
            shapes = CmpGeoShapes(features: [f])
        default: throw CmpGeoError.unsupported(type.isEmpty ? "(missing type)" : type)
        }
        shapes.features.removeAll { $0.polygons.isEmpty && $0.lines.isEmpty && $0.points.isEmpty }
        if shapes.features.isEmpty { throw CmpGeoError.noShapes }
        return shapes
    }

    // MARK: GeoJSON

    private static func feature(_ obj: [String: Any]) -> [CmpGeoFeature] {
        var f = CmpGeoFeature()
        f.id = scalar(obj["id"])
        f.properties = properties(obj["properties"])
        if let g = obj["geometry"] as? [String: Any] { addGeometry(g, to: &f) }
        return [f]
    }

    private static func addGeometry(_ g: [String: Any], to f: inout CmpGeoFeature) {
        let coords = g["coordinates"]
        switch g["type"] as? String ?? "" {
        case "Point": if let p = point(coords) { f.points.append(p) }
        case "MultiPoint": f.points += line(coords)
        case "LineString": let l = line(coords); if l.count > 1 { f.lines.append(l) }
        case "MultiLineString": f.lines += (coords as? [Any] ?? []).map(line).filter { $0.count > 1 }
        case "Polygon": let p = polygon(coords); if !p.isEmpty { f.polygons.append(p) }
        case "MultiPolygon": f.polygons += (coords as? [Any] ?? []).map(polygon).filter { !$0.isEmpty }
        case "GeometryCollection":
            for sub in g["geometries"] as? [[String: Any]] ?? [] { addGeometry(sub, to: &f) }
        default: break
        }
    }

    private static func point(_ a: Any?) -> CGPoint? {
        guard let c = a as? [Any], c.count >= 2, let x = (c[0] as? NSNumber)?.doubleValue,
              let y = (c[1] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }
    private static func line(_ a: Any?) -> [CGPoint] { (a as? [Any] ?? []).compactMap(point) }
    private static func polygon(_ a: Any?) -> [[CGPoint]] { (a as? [Any] ?? []).map(line).filter { $0.count >= 3 } }

    private static func scalar(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }
        return nil
    }
    private static func properties(_ v: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, val) in v as? [String: Any] ?? [:] { if let s = scalar(val) { out[k] = s } }
        return out
    }

    // MARK: TopoJSON

    /// Decodes a TopoJSON topology into features: un-quantizes and delta-decodes the shared arcs, then
    /// stitches each geometry's arc references (negative index `i` = arc `~i` reversed) into rings/lines.
    private static func topology(_ obj: [String: Any]) throws -> [CmpGeoFeature] {
        guard let rawArcs = obj["arcs"] as? [Any] else { throw CmpGeoError.badTopology("missing “arcs” array") }
        var sx = 1.0, sy = 1.0, tx = 0.0, ty = 0.0, quantized = false
        if let t = obj["transform"] as? [String: Any] {
            guard let s = t["scale"] as? [NSNumber], s.count == 2, let tr = t["translate"] as? [NSNumber], tr.count == 2 else {
                throw CmpGeoError.badTopology("“transform” needs two-element “scale” and “translate” arrays")
            }
            sx = s[0].doubleValue; sy = s[1].doubleValue; tx = tr[0].doubleValue; ty = tr[1].doubleValue
            quantized = true
        }
        let arcs: [[CGPoint]] = rawArcs.map { raw in
            var x = 0.0, y = 0.0
            return (raw as? [Any] ?? []).compactMap { p -> CGPoint? in
                guard let c = p as? [NSNumber], c.count >= 2 else { return nil }
                if quantized {
                    x += c[0].doubleValue; y += c[1].doubleValue
                    return CGPoint(x: x * sx + tx, y: y * sy + ty)
                }
                return CGPoint(x: c[0].doubleValue, y: c[1].doubleValue)
            }
        }
        func position(_ a: Any?) -> CGPoint? {
            guard let c = a as? [NSNumber], c.count >= 2 else { return nil }
            return CGPoint(x: c[0].doubleValue * sx + tx, y: c[1].doubleValue * sy + ty)
        }
        func stitch(_ refs: Any?) throws -> [CGPoint] {
            var out: [CGPoint] = []
            for n in refs as? [NSNumber] ?? [] {
                let i = n.intValue
                let idx = i >= 0 ? i : ~i
                guard idx < arcs.count else { throw CmpGeoError.badTopology("arc index \(i) is out of range (\(arcs.count) arcs)") }
                let arc = i >= 0 ? arcs[idx] : arcs[idx].reversed()
                out += out.isEmpty ? arc : Array(arc.dropFirst())
            }
            return out
        }
        func rings(_ a: Any?) throws -> [[CGPoint]] { try (a as? [Any] ?? []).map(stitch).filter { $0.count >= 3 } }

        func add(_ g: [String: Any], to f: inout CmpGeoFeature) throws {
            switch g["type"] as? String ?? "" {
            case "Point": if let p = position(g["coordinates"]) { f.points.append(p) }
            case "MultiPoint": f.points += (g["coordinates"] as? [Any] ?? []).compactMap(position)
            case "LineString": let l = try stitch(g["arcs"]); if l.count > 1 { f.lines.append(l) }
            case "MultiLineString": f.lines += try (g["arcs"] as? [Any] ?? []).map(stitch).filter { $0.count > 1 }
            case "Polygon": let p = try rings(g["arcs"]); if !p.isEmpty { f.polygons.append(p) }
            case "MultiPolygon": f.polygons += try (g["arcs"] as? [Any] ?? []).map(rings).filter { !$0.isEmpty }
            case "GeometryCollection":
                // A nested collection that carries its own id/properties is one feature made of its members.
                for sub in g["geometries"] as? [[String: Any]] ?? [] { try add(sub, to: &f) }
            default: break
            }
        }
        func features(_ g: [String: Any], topLevel: Bool) throws -> [CmpGeoFeature] {
            let isCollection = (g["type"] as? String) == "GeometryCollection"
            let hasIdentity = g["id"] != nil || !(g["properties"] as? [String: Any] ?? [:]).isEmpty
            if isCollection, !hasIdentity {
                return try (g["geometries"] as? [[String: Any]] ?? []).flatMap { try features($0, topLevel: false) }
            }
            var f = CmpGeoFeature()
            f.id = scalar(g["id"])
            f.properties = properties(g["properties"])
            try add(g, to: &f)
            return [f]
        }
        guard let objects = obj["objects"] as? [String: Any] else { throw CmpGeoError.badTopology("missing “objects”") }
        var out: [CmpGeoFeature] = []
        for key in objects.keys.sorted() {
            guard let g = objects[key] as? [String: Any] else { continue }
            var fs = try features(g, topLevel: true)
            // A single unnamed top-level geometry takes the object's key as its id.
            if fs.count == 1, fs[0].id == nil, fs[0].properties.isEmpty { fs[0].id = key }
            out += fs
        }
        return out
    }
}

/// Parsed-shape cache so large files are decoded once, not on every redraw.
final class CmpGeoShapeCache {
    static let shared = CmpGeoShapeCache()
    private var store: [String: Result<CmpGeoShapes, Error>] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    func shapes(for text: String) -> Result<CmpGeoShapes, Error> {
        let key = "\(text.utf8.count):\(text.hashValue)"
        lock.lock(); defer { lock.unlock() }
        if let hit = store[key] { return hit }
        let result = Result { try CmpGeoParser.parse(text) }
        store[key] = result; order.append(key)
        if order.count > 8 { store[order.removeFirst()] = nil }
        return result
    }
}
