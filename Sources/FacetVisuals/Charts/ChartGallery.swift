import Foundation
import FacetCore

/// Realistic sample specs and data for every chart type, used by the app's visual gallery, previews
/// and snapshot checks. The data is synthetic but deterministic.
public enum ChartGallery {
    public typealias Sample = (spec: VisualSpec, data: VisualData)

    /// At least one sample per supported chart type, plus variants that exercise formatting,
    /// analytics, small multiples and cross-highlighting. `spec.name` describes each sample.
    public static func samples() -> [Sample] {
        cartesianSamples() + partToWholeSamples() + scatterSamples() + flowSamples() + statisticalSamples() + gridSamples()
    }

    /// The first sample for a given type.
    public static func sample(for type: VisualType) -> Sample? { samples().first { $0.spec.type == type } }

    // MARK: Builder

    /// Assembles a `VisualSpec` and matching `VisualData` column by column.
    struct Builder {
        var spec: VisualSpec
        var columns: [DataColumn] = []
        var roles: [String: [Int]] = [:]
        var fields: [FieldRef?] = []
        var formats: [String] = []
        var baseline: [Int: [Value]] = [:]

        init(_ type: VisualType, _ name: String, width: Double = 520, height: Double = 340) {
            spec = VisualSpec(type: type, frame: Frame(x: 0, y: 0, width: width, height: height), name: name)
        }

        /// Adds a grouping column to `well`.
        mutating func group(_ well: Well, _ name: String, _ values: [Value], format: String = "", table: String = "Sales") {
            add(well, .column(table, name), DataColumn(name: name, values: values), format)
        }
        /// Adds a measure column to `well`.
        mutating func measure(_ well: Well, _ name: String, _ values: [Double?], format: String = "#,0", table: String = "Sales", baseline: [Double?]? = nil) {
            let col = DataColumn(name: name, type: .decimal, values: values.map { $0.map(Value.double) ?? .null })
            if let baseline { self.baseline[columns.count] = baseline.map { $0.map(Value.double) ?? .null } }
            add(well, .measure(table, name), col, format)
        }
        private mutating func add(_ well: Well, _ field: FieldRef, _ col: DataColumn, _ format: String) {
            roles[well.rawValue, default: []].append(columns.count)
            spec.wells[well.rawValue, default: []].append(field)
            columns.append(col); fields.append(field); formats.append(format)
        }
        mutating func fmt(_ card: String, _ key: String, _ value: JSONValue) { spec.setFmt(card, key, value) }

        func build() -> Sample {
            var table = DataTable(name: spec.name, columns: columns)
            table.inferTypes()
            var data = VisualData(table: table, roles: roles, fields: fields, formats: formats,
                                  totals: columns.enumerated().map { i, c in
                                      fields[i]?.isAggregate == true ? .double(c.values.compactMap(\.asDouble).reduce(0, +)) : .null
                                  })
            if !baseline.isEmpty {
                var b = table
                for (i, v) in baseline { b.columns[i].values = v }
                // `table` holds the highlighted values; `baseline` the un-highlighted totals.
                data.baseline = b
            }
            return (spec, data)
        }
    }

    /// Deterministic pseudo-random generator so samples are stable between runs.
    struct Random {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 1_000_000) / 1_000_000
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
        /// Approximately normal (sum of uniforms).
        mutating func normal(_ mean: Double, _ sd: Double) -> Double {
            var s = 0.0
            for _ in 0..<6 { s += next() }
            return mean + (s - 3) / 0.7071 * sd
        }
    }

    static let regions = ["North America", "Europe", "Asia Pacific", "Latin America", "Middle East", "Africa"]
    static let products = ["Laptops", "Phones", "Tablets", "Wearables"]
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func date(_ y: Int, _ m: Int, _ d: Int = 1) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar.utc.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }
    static func strings(_ s: [String]) -> [Value] { s.map(Value.string) }

    /// Long-format region × product revenue: (regions, products, revenue).
    static func regionProduct(seed: UInt64 = 7) -> (r: [Value], p: [Value], v: [Double?]) {
        var rng = Random(seed)
        var r: [Value] = [], p: [Value] = [], v: [Double?] = []
        let scale = [1.0, 0.82, 0.74, 0.38, 0.27, 0.18]
        let mix = [1.0, 0.85, 0.42, 0.3]
        for (i, region) in regions.enumerated() {
            for (j, product) in products.enumerated() {
                r.append(.string(region)); p.append(.string(product))
                v.append((420_000 * scale[i] * mix[j] * rng.range(0.75, 1.25)).rounded())
            }
        }
        return (r, p, v)
    }

    // MARK: Cartesian samples

    static func cartesianSamples() -> [Sample] {
        var out: [Sample] = []
        let rp = regionProduct()

        for type in [VisualType.stackedBar, .stackedColumn, .stackedBar100, .stackedColumn100] {
            var b = Builder(type, type.displayName)
            b.group(.category, "Region", rp.r); b.group(.legend, "Product", rp.p)
            b.measure(.values, "Revenue", rp.v, format: "$#,0")
            if type == .stackedColumn { b.fmt("totalLabels", "show", .bool(true)) }
            if type == .stackedBar100 { b.fmt("dataLabels", "show", .bool(true)) }
            out.append(b.build())
        }

        // Clustered column: two measures with data labels and an average line.
        var rng = Random(11)
        let quarters = ["Q1 2025", "Q2 2025", "Q3 2025", "Q4 2025", "Q1 2026", "Q2 2026"]
        let actual: [Double?] = [3.2, 3.6, 3.4, 4.3, 3.9, 4.6].map { $0 * 1_000_000 }
        let target: [Double?] = [3.0, 3.4, 3.7, 4.0, 4.1, 4.4].map { $0 * 1_000_000 }
        var cc = Builder(.clusteredColumn, "Clustered column chart")
        cc.group(.category, "Quarter", strings(quarters))
        cc.measure(.values, "Revenue", actual, format: "$#,0"); cc.measure(.values, "Target", target, format: "$#,0")
        cc.fmt("dataLabels", "show", .bool(true))
        var avg = AnalyticsItem(kind: .averageLine); avg.seriesKey = "Revenue"
        cc.spec.analytics = [avg]
        out.append(cc.build())

        var cb = Builder(.clusteredBar, "Clustered bar chart")
        let teams = ["Enterprise", "Mid-market", "Small business", "Public sector", "Education", "Non-profit", "Start-ups"]
        cb.group(.category, "Segment", strings(teams))
        cb.measure(.values, "This year", [182, 149, 121, 96, 64, 38, 27].map { Double($0) * 1000 }, format: "$#,0")
        cb.measure(.values, "Last year", [160, 155, 98, 91, 70, 31, 12].map { Double($0) * 1000 }, format: "$#,0")
        out.append(cb.build())

        // Cross-highlight: table = highlighted subset, baseline = totals.
        var hl = Builder(.clusteredColumn, "Clustered column — cross-highlight")
        let totals: [Double] = [520, 430, 390, 210, 150, 95].map { $0 * 1000 }
        hl.group(.category, "Region", strings(regions))
        hl.measure(.values, "Revenue", totals.enumerated().map { i, t in t * [0.42, 0.3, 0.55, 0.25, 0.6, 0.35][i] }, format: "$#,0", baseline: totals.map { $0 })
        out.append(hl.build())

        // Line: 24 months, three series, continuous date axis.
        let months: [Value] = (0..<24).map { .date(date(2024 + $0 / 12, $0 % 12 + 1)) }
        func trend(_ base: Double, _ slope: Double, _ noise: Double) -> [Double?] {
            (0..<24).map { i in (base + slope * Double(i) + sin(Double(i) / 12 * 2 * .pi) * base * 0.12 + rng.range(-noise, noise)).rounded() }
        }
        var ln = Builder(.line, "Line chart")
        ln.group(.category, "Month", months, format: "mmm yyyy")
        ln.measure(.values, "Online", trend(52_000, 2_600, 5_000), format: "$#,0")
        ln.measure(.values, "Retail", trend(74_000, 400, 6_000), format: "$#,0")
        ln.measure(.values, "Partners", trend(31_000, 900, 3_500), format: "$#,0")
        out.append(ln.build())

        // Line with analytics: trend, forecast, anomalies, markers, series labels.
        var la = Builder(.line, "Line chart — forecast, trend and anomalies")
        let visits = trend(18_000, 520, 1_400).enumerated().map { i, v in i == 9 ? v.map { $0 * 1.45 } : (i == 17 ? v.map { $0 * 0.62 } : v) }
        la.group(.category, "Month", months, format: "mmm yyyy")
        la.measure(.values, "Visits", visits)
        la.fmt("lines", "seriesLabels", .bool(true))
        var tl = AnalyticsItem(kind: .trendLine); tl.color = "#8E8E93"
        la.spec.analytics = [tl, AnalyticsItem(kind: .forecast), AnalyticsItem(kind: .anomalies)]
        out.append(la.build())

        var ar = Builder(.area, "Area chart")
        ar.group(.category, "Month", months, format: "mmm yyyy")
        ar.measure(.values, "Active users", trend(120_000, 5_200, 9_000))
        ar.measure(.values, "New users", trend(42_000, 1_100, 6_000))
        out.append(ar.build())

        // Stacked areas: long format month × channel.
        let channels = ["Direct", "Search", "Social", "Email"]
        var m12: [Value] = [], ch: [Value] = [], sessions: [Double?] = []
        for i in 0..<12 {
            for (j, c) in channels.enumerated() {
                m12.append(.string(monthNames[i])); ch.append(.string(c))
                sessions.append(([40, 62, 28, 17][j] * 1000 * (1 + Double(i) * [0.02, 0.05, 0.09, 0.01][j]) * rng.range(0.9, 1.1)).rounded())
            }
        }
        for type in [VisualType.stackedArea, .stackedArea100] {
            var b = Builder(type, type.displayName)
            b.group(.category, "Month", m12); b.group(.legend, "Channel", ch); b.measure(.values, "Sessions", sessions)
            out.append(b.build())
        }

        // Combos
        let margin: [Double?] = [0.31, 0.33, 0.29, 0.36, 0.34, 0.38, 0.41, 0.37, 0.39, 0.42, 0.40, 0.44]
        var ls = Builder(.lineStackedColumn, "Line and stacked column chart")
        ls.group(.category, "Month", strings(monthNames))
        ls.measure(.values, "Hardware", (0..<12).map { 210_000 + Double($0) * 9_000 + rng.range(-20_000, 20_000) }, format: "$#,0")
        ls.measure(.values, "Services", (0..<12).map { 90_000 + Double($0) * 7_000 + rng.range(-10_000, 10_000) }, format: "$#,0")
        ls.measure(.lineValues, "Gross margin", margin, format: "0%")
        out.append(ls.build())

        var lc = Builder(.lineClusteredColumn, "Line and clustered column chart")
        lc.group(.category, "Month", strings(monthNames))
        lc.measure(.values, "Orders", (0..<12).map { (1800 + Double($0) * 95 + rng.range(-150, 150)).rounded() })
        lc.measure(.values, "Returns", (0..<12).map { (210 + Double($0) * 6 + rng.range(-40, 40)).rounded() })
        lc.measure(.lineValues, "Satisfaction", [4.1, 4.2, 4.0, 4.3, 4.4, 4.3, 4.5, 4.4, 4.6, 4.5, 4.7, 4.6], format: "0.0")
        lc.fmt("lines", "showMarkers", .bool(true))
        out.append(lc.build())

        // Small multiples
        var sm = Builder(.clusteredColumn, "Clustered column — small multiples", width: 640, height: 420)
        var smR: [Value] = [], smQ: [Value] = [], smV: [Double?] = []
        for (i, region) in regions.prefix(4).enumerated() {
            for q in ["Q1", "Q2", "Q3", "Q4"] {
                smR.append(.string(region)); smQ.append(.string(q))
                smV.append((300_000 * [1, 0.8, 0.7, 0.4][i] * rng.range(0.7, 1.3)).rounded())
            }
        }
        sm.group(.category, "Quarter", smQ); sm.group(.smallMultiples, "Region", smR); sm.measure(.values, "Revenue", smV, format: "$#,0")
        out.append(sm.build())

        // Accessibility patterns + conditional colours
        var pt = Builder(.stackedColumn, "Stacked column — patterns")
        pt.group(.category, "Region", rp.r); pt.group(.legend, "Product", rp.p); pt.measure(.values, "Revenue", rp.v, format: "$#,0")
        pt.fmt("accessibility", "patterns", .bool(true))
        out.append(pt.build())

        var cf = Builder(.clusteredBar, "Clustered bar — conditional colour")
        cf.group(.category, "Segment", strings(teams))
        cf.measure(.values, "Growth", [0.24, 0.18, 0.11, 0.05, -0.04, -0.09, 0.31], format: "0%")
        var rule = ConditionalFormat(target: .dataPointColor)
        rule.mode = .gradient; rule.minColor = "#FF453A"; rule.midColor = "#E5E5EA"; rule.maxColor = "#34C759"; rule.midValue = 0
        cf.spec.conditionalFormats = [rule]
        cf.fmt("dataLabels", "show", .bool(true))
        out.append(cf.build())

        // Many categories → windowed with a scroll slider
        var many = Builder(.clusteredColumn, "Clustered column — 200 categories")
        many.group(.category, "Store", (1...200).map { .string("Store \($0)") })
        many.measure(.values, "Sales", (0..<200).map { 40_000 + sin(Double($0) / 9) * 14_000 + rng.range(0, 12_000) }, format: "$#,0")
        out.append(many.build())
        return out
    }

    /// Analytics overlays that accompany the "forecast, trend and anomalies" sample (normally computed by FacetAnalytics).
    public static func sampleOverlays(for sample: Sample) -> AnalyticsOverlays {
        var o = AnalyticsOverlays()
        guard sample.spec.analytics.contains(where: { $0.kind == .forecast || $0.kind == .anomalies }),
              let col = sample.data.indices(.values).first else { return o }
        let values = sample.data.table.columns[col].values.compactMap(\.asDouble)
        guard values.count > 4, let fit = ChartMath.linearRegression(values.enumerated().map { (Double($0.offset), $0.element) }) else { return o }
        let n = values.count
        let lastDate = sample.data.column(.category)?.values.last?.asDate ?? Date()
        let labels: [Value] = (1...6).map { .date(Calendar.utc.date(byAdding: .month, value: $0, to: lastDate) ?? lastDate) }
        let predicted = (0..<6).map { fit.intercept + fit.slope * Double(n + $0) }
        let spread = values.enumerated().map { abs($0.element - (fit.intercept + fit.slope * Double($0.offset))) }.sorted()[n / 2] * 2.2
        o.forecasts = [.init(seriesColumn: col, labels: labels, values: predicted,
                             lower: predicted.enumerated().map { $0.element - spread * (1 + Double($0.offset) * 0.25) },
                             upper: predicted.enumerated().map { $0.element + spread * (1 + Double($0.offset) * 0.25) })]
        o.expectedBands[col] = (0..<n).map { let e = fit.intercept + fit.slope * Double($0); return (e - spread, e + spread) }
        for (i, v) in values.enumerated() {
            let e = fit.intercept + fit.slope * Double(i)
            if abs(v - e) > spread * 1.25 { o.anomalies.append(.init(seriesColumn: col, row: i, expected: e, lower: e - spread, upper: e + spread)) }
        }
        return o
    }
}
