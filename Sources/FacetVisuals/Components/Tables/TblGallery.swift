import Foundation
import FacetCore

/// Gallery samples for the table and matrix.
enum CmpTblGallery {
    /// Small deterministic generator so samples are stable between runs.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 1_000_000) / 1_000_000
        }
    }

    static func samples() -> [(spec: VisualSpec, data: VisualData)] {
        [richTable(), plainTable(), largeTable(), wrapTable(), steppedMatrix(), tabularMatrix(), valuesOnRowsMatrix()]
    }

    private static func merge(_ preset: String, _ type: VisualType, into spec: inout VisualSpec) {
        guard let p = CmpTableFamily.presets(for: type).first(where: { $0.name == preset }) else { return }
        for (card, props) in p.format { for (k, v) in props where v != .null { spec.setFmt(card, k, v) } }
    }

    static func richTable() -> (spec: VisualSpec, data: VisualData) {
        let products: [(String, String, Double, Double, Double, String, Double)] = [
            ("Aurora Desk Lamp", "Lighting", 184_320, 0.412, 0.182, "12|14|13|17|19|18|22|24", 320),
            ("Fjord Lounge Chair", "Furniture", 412_900, 0.287, 0.064, "30|31|29|33|35|34|36|38", 85),
            ("Kumo Floor Cushion", "Textiles", 56_140, 0.531, -0.127, "9|8|8|7|7|6|6|5", -40),
            ("Linea Bookshelf", "Furniture", 268_450, 0.243, 0.021, "20|21|20|22|21|22|23|22", 140),
            ("Mesa Coffee Table", "Furniture", 301_775, 0.198, -0.043, "26|27|25|24|25|23|24|22", 12),
            ("Nimbus Pendant", "Lighting", 97_310, 0.466, 0.305, "4|5|7|8|11|13|16|21", 510),
            ("Orbit Wall Clock", "Decor", 38_990, 0.582, 0.009, "3|4|3|4|4|3|4|4", 230),
            ("Prisma Vase", "Decor", 22_415, 0.611, -0.214, "5|5|4|4|3|3|2|2", -15),
            ("Sora Linen Throw", "Textiles", 71_205, 0.495, 0.118, "6|6|7|7|8|8|9|10", 96),
            ("Terra Planter Set", "Decor", 64_880, 0.374, 0.076, "5|6|6|6|7|7|7|8", 410),
        ]
        return cmpTblWithTotals(CmpSample.make(.table, name: "Table Rich", size: (880, 380), columns: [
            CmpCol("Product", .values), CmpCol("Category", .values),
            CmpCol("Sales", .values, measure: true, format: "$#,0"),
            CmpCol("Margin", .values, measure: true, format: "0.0%"),
            CmpCol("YoY", .values, measure: true, format: "+0.0%;-0.0%"),
            CmpCol("Trend", .values, measure: true),
            CmpCol("Stock Δ", .values, measure: true, format: "#,0"),
            CmpCol("Page", .values),
        ], rows: products.map { p in
            [.string(p.0), .string(p.1), .double(p.2), .double(p.3), .double(p.4), .string(p.5), .double(p.6),
             .string("https://shop.example.com/" + p.0.lowercased().split(separator: " ").joined(separator: "-"))]
        }, totals: false) { spec in
            let f = spec.fields(.values)
            var bg = ConditionalFormat(target: .background)
            bg.appliesToKey = f[3].key; bg.minColor = "#FFF4DE"; bg.maxColor = "#FFB340"
            var bars = ConditionalFormat(target: .dataBars)
            bars.appliesToKey = f[2].key; bars.maxColor = "#0A84FF"
            var stock = ConditionalFormat(target: .dataBars)
            stock.appliesToKey = f[6].key; stock.maxColor = "#30B0C7"
            var icons = ConditionalFormat(target: .icons)
            icons.appliesToKey = f[4].key; icons.mode = .rules
            var down = ConditionalFormat.Rule(); down.op = .lessThan; down.value = -0.05; down.upperOp = nil; down.icon = "arrows:0"
            var flat = ConditionalFormat.Rule(); flat.op = .greaterOrEqual; flat.value = -0.05; flat.upperOp = .lessThan; flat.upperValue = 0.05; flat.icon = "arrows:1"
            var up = ConditionalFormat.Rule(); up.op = .greaterOrEqual; up.value = 0.05; up.upperOp = nil; up.icon = "arrows:2"
            icons.rules = [down, flat, up]
            var font = ConditionalFormat(target: .fontColor)
            font.appliesToKey = f[4].key; font.mode = .rules
            var neg = ConditionalFormat.Rule(); neg.op = .lessThan; neg.value = 0; neg.upperOp = nil; neg.color = "#FF453A"
            font.rules = [neg]
            spec.conditionalFormats = [bg, bars, stock, icons, font]
            spec.setFmt("sparklines", "Trend", .object(["type": .string("line"), "by": .string("Month")]))
            spec.sort = [SortSpec(field: f[2], descending: true)]
        }, [.null, .null, .double(1_718_385), .double(0.341), .double(0.058), .null, .double(1748), .null])
    }

    static func plainTable() -> (spec: VisualSpec, data: VisualData) {
        CmpSample.make(.table, name: "Table Plain", size: (440, 250), columns: [
            CmpCol("Region", .values), CmpCol("Manager", .values),
            CmpCol("Orders", .values, measure: true, format: "#,0"),
            CmpCol("Revenue", .values, measure: true, format: "$#,0"),
        ], rows: [
            ["North America", "Dana Whitfield", 4_812, 1_284_400.0], ["Europe", "Lukas Brandt", 3_977, 1_051_250.0],
            ["Asia Pacific", "Mei Tanaka", 3_120, 902_310.0], ["Latin America", "Sofía Herrera", 1_406, 318_720.0],
            ["Middle East", "Omar Haddad", 884, 241_090.0], ["Africa", "Thandiwe Nkosi", 612, 139_480.0],
        ], totals: true)
    }

    static func largeTable() -> (spec: VisualSpec, data: VisualData) {
        var g = LCG(state: 42)
        let cities = ["Lisbon", "Osaka", "Denver", "Nairobi", "Lyon", "Perth", "Quito", "Tallinn", "Hanoi", "Leeds"]
        let channels = ["Online", "Retail", "Partner", "Wholesale"]
        var rows: [[Value]] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let units = Int64(1 + g.next() * 40)
            let price = (5 + g.next() * 240).rounded()
            rows.append([.int(Int64(100_000 + i)), .string(cities[Int(g.next() * 10) % 10]), .string(channels[Int(g.next() * 4) % 4]),
                         .int(units), .double(Double(units) * price)])
        }
        return CmpSample.make(.table, name: "Table 100k rows", size: (540, 300), columns: [
            CmpCol("Order ID", .values), CmpCol("City", .values), CmpCol("Channel", .values),
            CmpCol("Units", .values, measure: true, format: "#,0"), CmpCol("Amount", .values, measure: true, format: "$#,0.00"),
        ], rows: rows, totals: true) { spec in
            merge("Alternating rows", .table, into: &spec)
        }
    }

    static func wrapTable() -> (spec: VisualSpec, data: VisualData) {
        cmpTblWithTotals(CmpSample.make(.table, name: "Table Wrap", size: (620, 330), columns: [
            CmpCol("Initiative", .values), CmpCol("Summary", .values), CmpCol("Owner", .values),
            CmpCol("Budget", .values, measure: true, format: "$#,0"),
            CmpCol("Health", .values, measure: true, format: "0%"),
        ], rows: [
            ["Checkout redesign", "Rebuild the payment flow around saved wallets and one-tap reorder for returning customers.", "Priya", 420_000.0, 0.92],
            ["Warehouse routing", "Shorten pick paths with zone batching; pilot in two fulfilment centres before the holiday peak.", "Marcus", 310_000.0, 0.64],
            ["Loyalty tiers", "Introduce three tiers with partner perks.", "Elena", 180_000.0, 0.38],
            ["Supplier portal", "Self-service onboarding, document checks and scorecards for the top two hundred suppliers.", "Kofi", 265_000.0, 0.81],
        ]) { spec in
            spec.setFmt("columnHeaders", "uppercase", .bool(true))
            spec.setFmt("columnHeaders", "fontSize", .number(10.5))
            spec.setFmt("values", "wordWrap", .bool(true))
            spec.setFmt("grid", "vertical", .bool(true))
            spec.setFmt("columnWidths", "Summary", .number(190))
            var icons = ConditionalFormat(target: .icons)
            icons.appliesToKey = spec.fields(.values)[4].key
            spec.conditionalFormats = [icons]
            spec.setFmt("conditionalIcons", "set", .string("trafficLights"))
        }, [.null, .null, .null, .double(1_175_000), .double(0.69)])
    }

    /// Long-format sales data: Region > Country × Year > Quarter.
    private static func salesRows(values: Int) -> [[Value]] {
        var g = LCG(state: 7)
        let geo: [(String, [String])] = [
            ("Americas", ["United States", "Canada", "Brazil", "Mexico"]),
            ("Europe", ["Germany", "France", "United Kingdom", "Spain"]),
            ("Asia Pacific", ["Japan", "Australia", "India"]),
        ]
        var rows: [[Value]] = []
        for (region, countries) in geo {
            for country in countries {
                let base = 40_000 + g.next() * 160_000
                for year in [2024, 2025] {
                    for q in 1...4 {
                        let sales = (base * (1 + Double(year - 2024) * 0.12) * (0.8 + g.next() * 0.5)).rounded()
                        var row: [Value] = [.string(region), .string(country), .int(Int64(year)), .string("Q\(q)"), .double(sales)]
                        if values > 1 { row.append(.int(Int64(sales / (90 + g.next() * 40)))) }
                        if values > 2 { row.append(.double(0.18 + g.next() * 0.3)) }
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    static func steppedMatrix() -> (spec: VisualSpec, data: VisualData) {
        CmpSample.make(.matrix, name: "Matrix Stepped", size: (780, 380), columns: [
            CmpCol("Region", .rows), CmpCol("Country", .rows), CmpCol("Year", .columns), CmpCol("Quarter", .columns),
            CmpCol("Sales", .values, measure: true, format: "$#,0"),
        ], rows: salesRows(values: 1)) { spec in
            spec.expandedPaths = ["R\u{1F}Americas", "R\u{1F}Europe", "C\u{1F}2025"]
            spec.setFmt("values", "heatmap", .bool(true))
        }
    }

    static func tabularMatrix() -> (spec: VisualSpec, data: VisualData) {
        CmpSample.make(.matrix, name: "Matrix Tabular", size: (700, 360), columns: [
            CmpCol("Region", .rows), CmpCol("Country", .rows), CmpCol("Year", .columns), CmpCol("Quarter", .columns),
            CmpCol("Sales", .values, measure: true, format: "$#,0"), CmpCol("Units", .values, measure: true, format: "#,0"),
        ], rows: salesRows(values: 2)) { spec in
            spec.expandedPaths = ["R\u{1F}Americas", "R\u{1F}Asia Pacific"]
            spec.setFmt("layout", "stepped", .bool(false))
            spec.setFmt("totals", "Units", .string("average"))
            spec.setFmt("values", "alternating", .bool(true))
            var bars = ConditionalFormat(target: .dataBars)
            bars.appliesToKey = spec.fields(.values)[0].key
            bars.maxColor = "#5E5CE6"
            spec.conditionalFormats = [bars]
        }
    }

    static func valuesOnRowsMatrix() -> (spec: VisualSpec, data: VisualData) {
        CmpSample.make(.matrix, name: "Matrix Values on rows", size: (640, 360), columns: [
            CmpCol("Region", .rows), CmpCol("Country", .rows), CmpCol("Year", .columns), CmpCol("Quarter", .columns),
            CmpCol("Sales", .values, measure: true, format: "$#,0"), CmpCol("Units", .values, measure: true, format: "#,0"),
            CmpCol("Margin", .values, measure: true, format: "0.0%"),
        ], rows: salesRows(values: 3)) { spec in
            spec.expandedPaths = ["R\u{1F}Europe", "C\u{1F}2024"]
            spec.setFmt("layout", "valuesOnRows", .bool(true))
            spec.setFmt("totals", "Margin", .string("average"))
            merge("Condensed", .matrix, into: &spec)
        }
    }
}

private func cmpTblWithTotals(_ s: (spec: VisualSpec, data: VisualData), _ totals: [Value]) -> (spec: VisualSpec, data: VisualData) {
    var d = s.data
    d.totals = totals
    return (s.spec, d)
}
