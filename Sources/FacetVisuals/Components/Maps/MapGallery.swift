import Foundation
import FacetCore

/// Gallery samples for the maps and the Gantt chart.
enum CmpMapGallery {
    static func samples() -> [(spec: VisualSpec, data: VisualData)] {
        [bubbleMap(), heatPathMap(), tileShapeMap(), districtShapeMap(), filledFallback(), ganttPlan(), ganttSprint(), ganttDense()]
    }

    // MARK: Maps

    private static let cities: [(String, String, Double, Double, Double, Double)] = [
        // city, region, lat, lon, revenue, orders
        ("London", "North", 51.5074, -0.1278, 4_820_000, 18_400), ("Paris", "West", 48.8566, 2.3522, 3_910_000, 15_100),
        ("Berlin", "Central", 52.52, 13.405, 2_760_000, 11_900), ("Madrid", "South", 40.4168, -3.7038, 2_140_000, 9_300),
        ("Rome", "South", 41.9028, 12.4964, 1_980_000, 8_700), ("Amsterdam", "West", 52.3676, 4.9041, 1_620_000, 7_800),
        ("Vienna", "Central", 48.2082, 16.3738, 1_240_000, 5_600), ("Stockholm", "North", 59.3293, 18.0686, 1_130_000, 4_900),
        ("Lisbon", "South", 38.7223, -9.1393, 870_000, 4_100), ("Dublin", "North", 53.3498, -6.2603, 940_000, 4_300),
        ("Warsaw", "Central", 52.2297, 21.0122, 1_050_000, 5_200), ("Copenhagen", "North", 55.6761, 12.5683, 990_000, 4_400),
        ("Munich", "Central", 48.1351, 11.582, 1_710_000, 7_200), ("Barcelona", "South", 41.3874, 2.1686, 1_560_000, 6_900),
        ("Brussels", "West", 50.8503, 4.3517, 780_000, 3_600), ("Zurich", "Central", 47.3769, 8.5417, 1_390_000, 4_800),
    ]

    private static func bubbleMap() -> (spec: VisualSpec, data: VisualData) {
        CmpSample.make(.map, name: "Map bubbles by city", size: (560, 380), columns: [
            CmpCol("City", .location), CmpCol("Latitude", .latitude), CmpCol("Longitude", .longitude),
            CmpCol("Region", .legend), CmpCol("Revenue", .size, measure: true, format: "$#,0"),
            CmpCol("Orders", .tooltips, measure: true, format: "#,0"),
        ], rows: cities.map { [.string($0.0), .double($0.2), .double($0.3), .string($0.1), .double($0.4), .double($0.5)] })
    }

    private static func heatPathMap() -> (spec: VisualSpec, data: VisualData) {
        // A delivery route sampled along the Rhine corridor, with stop dwell time as heat weight.
        let stops: [(String, Double, Double, Double)] = [
            ("Rotterdam", 51.9244, 4.4777, 42), ("Utrecht", 52.0907, 5.1214, 18), ("Arnhem", 51.9851, 5.8987, 12),
            ("Duisburg", 51.4344, 6.7623, 35), ("Düsseldorf", 51.2277, 6.7735, 28), ("Cologne", 50.9375, 6.9603, 47),
            ("Bonn", 50.7374, 7.0982, 14), ("Koblenz", 50.3569, 7.589, 9), ("Mainz", 49.9929, 8.2473, 22),
            ("Mannheim", 49.4875, 8.466, 31), ("Karlsruhe", 49.0069, 8.4037, 16), ("Strasbourg", 48.5734, 7.7521, 25),
            ("Freiburg", 47.999, 7.8421, 11), ("Basel", 47.5596, 7.5886, 38),
        ]
        return CmpSample.make(.azureMap, name: "AzureMap heat and path", size: (560, 380), columns: [
            CmpCol("Stop", .location), CmpCol("Latitude", .latitude), CmpCol("Longitude", .longitude),
            CmpCol("Dwell minutes", .size, measure: true, format: "0"),
        ], rows: stops.map { [.string($0.0), .double($0.1), .double($0.2), .double($0.3)] }) { spec in
            spec.format["layers"] = ["bubble": .bool(false), "heatmap": .bool(true), "path": .bool(true)]
            spec.format["map"] = ["style": .string("muted")]
        }
    }

    /// US states as a square tile grid — a custom GeoJSON shape file with one unit square per state.
    static let tileLayout: [(String, Int, Int)] = [
        ("AK", 0, 0), ("ME", 10, 0), ("VT", 9, 1), ("NH", 10, 1),
        ("WA", 0, 2), ("ID", 1, 2), ("MT", 2, 2), ("ND", 3, 2), ("MN", 4, 2), ("IL", 5, 2), ("WI", 6, 2), ("MI", 7, 2), ("NY", 8, 2), ("RI", 9, 2), ("MA", 10, 2),
        ("OR", 0, 3), ("NV", 1, 3), ("WY", 2, 3), ("SD", 3, 3), ("IA", 4, 3), ("IN", 5, 3), ("OH", 6, 3), ("PA", 7, 3), ("NJ", 8, 3), ("CT", 9, 3),
        ("CA", 0, 4), ("UT", 1, 4), ("CO", 2, 4), ("NE", 3, 4), ("MO", 4, 4), ("KY", 5, 4), ("WV", 6, 4), ("VA", 7, 4), ("MD", 8, 4), ("DE", 9, 4),
        ("AZ", 1, 5), ("NM", 2, 5), ("KS", 3, 5), ("AR", 4, 5), ("TN", 5, 5), ("NC", 6, 5), ("SC", 7, 5), ("DC", 8, 5),
        ("OK", 3, 6), ("LA", 4, 6), ("MS", 5, 6), ("AL", 6, 6), ("GA", 7, 6),
        ("HI", 0, 7), ("TX", 3, 7), ("FL", 8, 7),
    ]

    static func tileGeoJSON() -> String {
        let s = 0.93
        let features: [[String: Any]] = tileLayout.map { code, c, r in
            let x = Double(c), y = -Double(r)
            return ["type": "Feature", "id": code, "properties": ["name": code],
                    "geometry": ["type": "Polygon", "coordinates": [[[x, y], [x + s, y], [x + s, y - s], [x, y - s], [x, y]]]]]
        }
        let obj: [String: Any] = ["type": "FeatureCollection", "features": features]
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func noise(_ a: Int, _ b: Int) -> Double {
        let v = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private static func tileShapeMap() -> (spec: VisualSpec, data: VisualData) {
        let skip: Set<String> = ["AK", "HI", "WY", "DC"]
        let rows: [[Value]] = tileLayout.enumerated().compactMap { i, t in
            skip.contains(t.0) ? nil : [.string(t.0), .double((180_000 + noise(i, 7) * noise(t.1, t.2) * 5_400_000).rounded())]
        }
        return CmpSample.make(.shapeMap, name: "ShapeMap GeoJSON tile grid", size: (560, 400), columns: [
            CmpCol("State", .location), CmpCol("Sales", .values, measure: true, format: "$#,0"),
        ], rows: rows) { spec in
            spec.content = tileGeoJSON()
            spec.format["shape"] = ["projection": .string("identity"), "labels": .bool(true)]
        }
    }

    static let districtNames = ["Harbour", "Old Town", "Riverside", "Market", "Northgate", "Hillcrest",
                                "Eastfield", "Parklands", "Southbank", "Westend", "Lakeside", "Midtown"]

    /// City districts as a quantized, delta-encoded TopoJSON topology whose neighbouring polygons share arcs.
    static func districtTopoJSON() -> String {
        let R = 3, C = 4
        // Jittered lattice of shared vertices in quantized space (0…1000).
        func vertex(_ r: Int, _ c: Int) -> (Int, Int) {
            let jx = (c == 0 || c == C) ? 0 : Int((noise(r, c) - 0.5) * 110)
            let jy = (r == 0 || r == R) ? 0 : Int((noise(c + 9, r + 3) - 0.5) * 120)
            return (c * 1000 / C + jx, 1000 - r * 1000 / R + jy)
        }
        func arc(_ a: (Int, Int), _ b: (Int, Int), bend: Double, outer: Bool) -> [[Int]] {
            // One displaced midpoint makes inner boundaries organic; outer edges stay straight.
            let mx = (a.0 + b.0) / 2, my = (a.1 + b.1) / 2
            let dx = b.0 - a.0, dy = b.1 - a.1
            let k = outer ? 0 : (bend - 0.5) * 0.28
            let mid = (mx + Int(Double(-dy) * k), my + Int(Double(dx) * k))
            return [[a.0, a.1], [mid.0 - a.0, mid.1 - a.1], [b.0 - mid.0, b.1 - mid.1]]
        }
        var arcs: [[[Int]]] = []
        for r in 0...R { for c in 0..<C { arcs.append(arc(vertex(r, c), vertex(r, c + 1), bend: noise(r + 20, c), outer: r == 0 || r == R)) } }
        for r in 0..<R { for c in 0...C { arcs.append(arc(vertex(r, c), vertex(r + 1, c), bend: noise(r, c + 40), outer: c == 0 || c == C)) } }
        func h(_ r: Int, _ c: Int) -> Int { r * C + c }
        func v(_ r: Int, _ c: Int) -> Int { (R + 1) * C + r * (C + 1) + c }
        var geometries: [[String: Any]] = []
        for r in 0..<R {
            for c in 0..<C {
                let ring = [h(r, c), v(r, c + 1), ~h(r + 1, c), ~v(r, c)]
                geometries.append(["type": "Polygon", "arcs": [ring], "id": "D\(r * C + c + 1)",
                                   "properties": ["name": districtNames[r * C + c]]])
            }
        }
        let obj: [String: Any] = [
            "type": "Topology",
            "transform": ["scale": [0.00042, 0.00028], "translate": [18.36, -34.08]],
            "objects": ["districts": ["type": "GeometryCollection", "geometries": geometries]],
            "arcs": arcs,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func districtShapeMap() -> (spec: VisualSpec, data: VisualData) {
        let visits: [Double] = [48_200, 61_500, 37_900, 52_300, 21_400, 18_700, 26_300, 33_100, 44_800, 29_600, 15_200, 57_400]
        var rows: [[Value]] = districtNames.enumerated().map { [.string($1), .double(visits[$0])] }
        rows.remove(at: 6)                       // one district without data
        rows.append([.string("Airport"), .double(9_800)])   // one location without a shape
        return CmpSample.make(.shapeMap, name: "ShapeMap TopoJSON districts", size: (520, 380), columns: [
            CmpCol("District", .location), CmpCol("Store visits", .values, measure: true, format: "#,0"),
        ], rows: rows) { spec in
            spec.format["shape"] = ["geojson": .string(districtTopoJSON()), "labels": .bool(true)]
        }
    }

    private static func filledFallback() -> (spec: VisualSpec, data: VisualData) {
        let rows: [[Value]] = [["France", 3_910_000.0], ["Germany", 4_470_000.0], ["Spain", 3_700_000.0], ["Italy", 1_980_000.0],
                               ["Poland", 1_050_000.0], ["Netherlands", 1_620_000.0], ["Sweden", 1_130_000.0], ["Portugal", 870_000.0]]
        return CmpSample.make(.filledMap, name: "FilledMap without shape file", size: (520, 360), columns: [
            CmpCol("Country", .location), CmpCol("Revenue", .values, measure: true, format: "$#,0"),
        ], rows: rows)
    }

    // MARK: Gantt

    private static func day(_ offset: Int) -> Value {
        .date(Calendar.utc.startOfDay(for: Date()).addingTimeInterval(Double(offset) * 86400))
    }

    private static func ganttPlan() -> (spec: VisualSpec, data: VisualData) {
        // task, phase, start offset, end offset (nil = milestone), progress
        let tasks: [(String, String, Int, Int?, Double?)] = [
            ("Discovery interviews", "Research", -58, -44, 1), ("Market sizing", "Research", -50, -36, 1),
            ("Requirements sign-off", "Research", -35, nil, nil),
            ("Information architecture", "Design", -34, -20, 1), ("Visual design system", "Design", -26, -4, 0.9),
            ("Prototype usability tests", "Design", -12, 3, 0.65),
            ("API and data model", "Build", -18, 16, 0.55), ("Web client", "Build", -6, 34, 0.3),
            ("Mobile client", "Build", 4, 44, 0.1), ("Beta release", "Build", 45, nil, nil),
            ("Security review", "Launch", 30, 48, 0), ("Launch campaign", "Launch", 40, 66, 0),
            ("General availability", "Launch", 68, nil, nil),
        ]
        return CmpSample.make(.gantt, name: "Gantt project plan", size: (680, 400), columns: [
            CmpCol("Task", .task), CmpCol("Start", .start, format: "d MMM yyyy"), CmpCol("End", .end, format: "d MMM yyyy"),
            CmpCol("Progress", .progress, measure: true, format: "0%"), CmpCol("Phase", .legend),
        ], rows: tasks.map { [.string($0.0), day($0.2), $0.3.map(day) ?? day($0.2), $0.4.map(Value.double) ?? .null, .string($0.1)] })
    }

    private static func ganttSprint() -> (spec: VisualSpec, data: VisualData) {
        let tasks: [(String, String, Int, Int?, Double?)] = [
            ("Sprint planning", "Amara", -6, nil, nil), ("Checkout redesign", "Amara", -6, -1, 1),
            ("Payment retries", "Jonas", -5, 1, 0.8), ("Address autocomplete", "Mei", -3, 2, 0.6),
            ("Order tracking page", "Jonas", 0, 5, 0.2), ("Load testing", "Mei", 2, 6, 0),
            ("Accessibility audit", "Amara", 1, 4, 0.25), ("Sprint review", "Amara", 7, nil, nil),
        ]
        return CmpSample.make(.gantt, name: "Gantt sprint by day", size: (600, 300), columns: [
            CmpCol("Story", .task), CmpCol("Start", .start, format: "d MMM yyyy"), CmpCol("End", .end, format: "d MMM yyyy"),
            CmpCol("Progress", .progress, measure: true, format: "0%"), CmpCol("Owner", .legend),
        ], rows: tasks.map { [.string($0.0), day($0.2), $0.3.map(day) ?? day($0.2), $0.4.map(Value.double) ?? .null, .string($0.1)] }) { spec in
            spec.format["gantt"] = ["progressLabels": .bool(true)]
        }
    }

    private static func ganttDense() -> (spec: VisualSpec, data: VisualData) {
        let streams = ["Platform", "Payments", "Growth", "Data", "Mobile"]
        let verbs = ["Migrate", "Refactor", "Launch", "Pilot", "Audit", "Scale", "Automate", "Retire"]
        let nouns = ["billing engine", "search index", "onboarding flow", "event pipeline", "design tokens", "partner API",
                     "pricing page", "identity service", "reporting suite", "push notifications"]
        var rows: [[Value]] = []
        for i in 0..<64 {
            let start = -260 + Int(noise(i, 3) * 60) + i * 7
            let length = 14 + Int(noise(i, 11) * 95)
            let milestone = i % 13 == 12
            rows.append([.string("\(verbs[i % verbs.count]) \(nouns[(i * 7) % nouns.count])"), day(start),
                         day(milestone ? start : start + length), .string(streams[(i * 3 + i / 5) % streams.count])])
        }
        return CmpSample.make(.gantt, name: "Gantt dense roadmap", size: (680, 440), columns: [
            CmpCol("Initiative", .task), CmpCol("Start", .start, format: "d MMM yyyy"), CmpCol("End", .end, format: "d MMM yyyy"),
            CmpCol("Stream", .legend),
        ], rows: rows) { spec in
            spec.format["gantt"] = ["rowHeight": .number(20)]
        }
    }
}
