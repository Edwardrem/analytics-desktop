import Foundation
import FacetCore

/// A small, deterministic retail star schema with a starter report — so a new user can explore
/// every feature before connecting their own data.
@MainActor
enum SampleData {
    /// Deterministic generator so the sample is identical on every machine.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func int(_ n: Int) -> Int { Int(next() * Double(n)) % max(1, n) }
    }

    static func install(into store: DocumentStore) {
        let (tables, model, report) = build()
        store.mutate("Load Sample Data", invalidates: .model) { d in
            for t in tables { d.data[t.name] = t }
            d.model.tables.removeAll { t in tables.contains { $0.name == t.name } }
            d.model.tables.append(contentsOf: model.tables)
            d.model.relationships.append(contentsOf: model.relationships)
            if d.report.pages.allSatisfy({ $0.visuals.isEmpty }) {
                d.report.pages = report.pages
            }
        }
        store.goToPage(store.report.pages[0].id)
        store.status = StatusMessage(kind: .success, text: "Sample retail data loaded: 4 tables, \(tables[0].rowCount.formatted()) sales rows.")
    }

    static func build() -> ([DataTable], SemanticModel, Report) {
        var rng = LCG(state: 42)
        let cal = Calendar.utc

        // Products
        let catalog: [(String, String, [(String, Double)])] = [
            ("Audio", "Headphones", [("Aria Over-Ear", 249), ("Aria Buds", 129), ("Studio Monitor", 399)]),
            ("Audio", "Speakers", [("Pulse Mini", 89), ("Pulse Home", 199), ("Pulse Max", 349)]),
            ("Computing", "Laptops", [("Slate 13", 1099), ("Slate 15", 1499), ("Slate Pro 16", 2399)]),
            ("Computing", "Tablets", [("Leaf 10", 449), ("Leaf 12", 699)]),
            ("Computing", "Accessories", [("Glide Mouse", 59), ("Type Keyboard", 119), ("Dock Hub", 179)]),
            ("Wearables", "Watches", [("Orbit SE", 249), ("Orbit 2", 399), ("Orbit Ultra", 749)]),
            ("Wearables", "Bands", [("Loop Band", 49), ("Sport Band", 39)]),
            ("Home", "Lighting", [("Glow Bulb", 29), ("Glow Strip", 59), ("Glow Lamp", 129)]),
            ("Home", "Climate", [("Breeze Fan", 159), ("Therm Sensor", 79)]),
        ]
        let brands = ["Northwind", "Halden", "Kite", "Mono"]
        var productRows: [[Value]] = [], prices: [Double] = [], costs: [Double] = []
        for (cat, sub, items) in catalog {
            for (name, price) in items {
                let id = productRows.count + 1
                productRows.append([.int(Int64(id)), .string(name), .string(cat), .string(sub), .string(brands[id % brands.count]), .double(price)])
                prices.append(price); costs.append((price * (0.48 + rng.next() * 0.2)).rounded())
            }
        }
        let product = DataTable(name: "Product", columnNames: ["ProductID", "Product", "Category", "Subcategory", "Brand", "List Price"],
                                rows: productRows, types: [.integer, .text, .text, .text, .text, .currency])

        // Customers
        let places: [(String, String, Double, Double)] = [
            ("United States", "New York", 40.71, -74.01), ("United States", "San Francisco", 37.77, -122.42), ("United States", "Chicago", 41.88, -87.63),
            ("United States", "Austin", 30.27, -97.74), ("Canada", "Toronto", 43.65, -79.38), ("Canada", "Vancouver", 49.28, -123.12),
            ("United Kingdom", "London", 51.51, -0.13), ("United Kingdom", "Manchester", 53.48, -2.24), ("Germany", "Berlin", 52.52, 13.40),
            ("Germany", "Munich", 48.14, 11.58), ("France", "Paris", 48.86, 2.35), ("Netherlands", "Amsterdam", 52.37, 4.90),
            ("South Africa", "Cape Town", -33.92, 18.42), ("South Africa", "Johannesburg", -26.20, 28.05), ("Zimbabwe", "Harare", -17.83, 31.05),
            ("Kenya", "Nairobi", -1.29, 36.82), ("Japan", "Tokyo", 35.68, 139.69), ("Australia", "Sydney", -33.87, 151.21),
            ("Brazil", "São Paulo", -23.55, -46.63), ("India", "Bengaluru", 12.97, 77.59),
        ]
        let segments = ["Consumer", "Small Business", "Enterprise", "Education"]
        let first = ["Ava", "Liam", "Noah", "Mia", "Tendai", "Zoe", "Kai", "Lena", "Omar", "Ivy", "Rufaro", "Theo", "Nia", "Hugo", "Sara", "Yuki"]
        let last = ["Moyo", "Smith", "Garcia", "Müller", "Dubois", "Tanaka", "Okafor", "Brown", "Singh", "Rossi", "Ncube", "Jansen", "Silva", "Khan"]
        var customerRows: [[Value]] = []
        for id in 1...240 {
            let p = places[rng.int(places.count)]
            let seg = segments[[0, 0, 0, 1, 1, 2, 3][rng.int(7)]]
            customerRows.append([.int(Int64(id)), .string("\(first[rng.int(first.count)]) \(last[rng.int(last.count)])"), .string(seg),
                                 .string(p.0), .string(p.1), .double(p.2), .double(p.3)])
        }
        let customer = DataTable(name: "Customer", columnNames: ["CustomerID", "Customer", "Segment", "Country", "City", "Latitude", "Longitude"],
                                 rows: customerRows, types: [.integer, .text, .text, .text, .text, .decimal, .decimal])

        // Dates: three full years ending last year-end relative to a fixed anchor, so time intelligence has history.
        let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let dayCount = 366 + 365 + 365
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var dateRows: [[Value]] = [], dates: [Date] = []
        for i in 0..<dayCount {
            let d = cal.date(byAdding: .day, value: i, to: start)!
            let c = cal.dateComponents([.year, .month, .weekday], from: d)
            let q = (c.month! - 1) / 3 + 1
            dates.append(d)
            dateRows.append([.date(d), .int(Int64(c.year!)), .string("Q\(q)"), .string(monthNames[c.month! - 1]), .int(Int64(c.month!)),
                             .string("\(monthNames[c.month! - 1]) \(c.year!)"), .int(Int64(c.year! * 100 + c.month!)),
                             .string(dayNames[c.weekday! - 1]), .int(Int64(c.weekday!))])
        }
        let date = DataTable(name: "Date", columnNames: ["Date", "Year", "Quarter", "Month", "Month Number", "Month Year", "Month Year Sort", "Weekday", "Weekday Number"],
                             rows: dateRows, types: [.date, .integer, .text, .text, .integer, .text, .integer, .text, .integer])

        // Sales: growth trend, yearly seasonality, a weekend lift, segment-dependent basket sizes.
        var salesRows: [[Value]] = []
        salesRows.reserveCapacity(24_000)
        var orderID: Int64 = 10_000
        for (i, d) in dates.enumerated() {
            let c = cal.dateComponents([.month, .weekday], from: d)
            let season = 1 + 0.35 * sin((Double(c.month!) - 9.5) / 12 * 2 * .pi) + (c.month == 11 || c.month == 12 ? 0.35 : 0)
            let growth = 1 + Double(i) / Double(dayCount) * 0.6
            let weekend = (c.weekday == 1 || c.weekday == 7) ? 1.25 : 1
            let orders = Int((14 * season * growth * weekend * (0.8 + rng.next() * 0.4)).rounded())
            for _ in 0..<orders {
                orderID += 1
                let cust = rng.int(customerRows.count)
                let prod = Int(pow(rng.next(), 1.6) * Double(productRows.count)) % productRows.count
                let seg = customerRows[cust][2].asString
                let qty = seg == "Enterprise" ? 2 + rng.int(9) : (seg == "Education" ? 1 + rng.int(5) : 1 + rng.int(3))
                let discount = [0, 0, 0, 0.05, 0.1, 0.15][rng.int(6)] + (seg == "Enterprise" ? 0.05 : 0)
                let amount = (Double(qty) * prices[prod] * (1 - discount) * 100).rounded() / 100
                let cost = Double(qty) * costs[prod]
                salesRows.append([.int(orderID), .date(d), .int(Int64(prod + 1)), .int(Int64(cust + 1)), .int(Int64(qty)),
                                  .double(prices[prod]), .double(discount), .double(amount), .double(cost),
                                  .string(["Online", "Online", "Store", "Partner"][rng.int(4)])])
            }
        }
        let sales = DataTable(name: "Sales", columnNames: ["OrderID", "Order Date", "ProductID", "CustomerID", "Quantity", "Unit Price", "Discount", "Amount", "Cost", "Channel"],
                              rows: salesRows, types: [.integer, .date, .integer, .integer, .integer, .currency, .decimal, .currency, .currency, .text])

        // Model
        var model = SemanticModel()
        func table(_ t: DataTable) -> ModelTable { ModelTable(name: t.name, columns: t.columns.map(DocumentStore.modelColumn)) }
        var mSales = table(sales), mProduct = table(product), mCustomer = table(customer), mDate = table(date)
        func edit(_ t: inout ModelTable, _ col: String, _ change: (inout ModelColumn) -> Void) {
            if let i = t.columns.firstIndex(where: { $0.name == col }) { change(&t.columns[i]) }
        }
        edit(&mSales, "Discount") { $0.formatString = "0%"; $0.summarizeBy = .average }
        edit(&mSales, "Amount") { $0.formatString = "$#,0" }
        edit(&mSales, "Cost") { $0.formatString = "$#,0" }
        edit(&mSales, "Unit Price") { $0.formatString = "$#,0.00"; $0.summarizeBy = .average }
        for c in ["OrderID", "ProductID", "CustomerID"] { edit(&mSales, c) { $0.summarizeBy = .none; $0.isHidden = c != "OrderID" } }
        edit(&mProduct, "ProductID") { $0.isHidden = true; $0.isKey = true }
        edit(&mProduct, "List Price") { $0.formatString = "$#,0.00"; $0.summarizeBy = .average }
        edit(&mCustomer, "CustomerID") { $0.isHidden = true; $0.isKey = true }
        edit(&mDate, "Month") { $0.sortByColumn = "Month Number" }
        edit(&mDate, "Month Year") { $0.sortByColumn = "Month Year Sort" }
        edit(&mDate, "Weekday") { $0.sortByColumn = "Weekday Number" }
        for c in ["Year", "Month Number", "Month Year Sort", "Weekday Number"] { edit(&mDate, c) { $0.summarizeBy = .none } }
        for c in ["Month Number", "Month Year Sort", "Weekday Number"] { edit(&mDate, c) { $0.isHidden = true } }
        mDate.dateColumn = "Date"
        mDate.hierarchies = [Hierarchy(name: "Calendar", levels: ["Year", "Quarter", "Month"])]
        mProduct.hierarchies = [Hierarchy(name: "Product hierarchy", levels: ["Category", "Subcategory", "Product"])]
        mCustomer.hierarchies = [Hierarchy(name: "Geography", levels: ["Country", "City"])]
        func measure(_ name: String, _ dax: String, _ fmt: String, folder: String = "", _ desc: String = "") -> Measure {
            var m = Measure(name: name, expression: dax, formatString: fmt); m.displayFolder = folder; m.description = desc; return m
        }
        mSales.measures = [
            measure("Total Sales", "SUM(Sales[Amount])", "$#,0", "Revenue after discounts."),
            measure("Total Cost", "SUM(Sales[Cost])", "$#,0"),
            measure("Profit", "[Total Sales] - [Total Cost]", "$#,0"),
            measure("Margin %", "DIVIDE([Profit], [Total Sales])", "0.0%"),
            measure("Orders", "COUNTROWS(Sales)", "#,0"),
            measure("Units", "SUM(Sales[Quantity])", "#,0"),
            measure("Average Order Value", "DIVIDE([Total Sales], [Orders])", "$#,0.00"),
            measure("Customers", "DISTINCTCOUNT(Sales[CustomerID])", "#,0"),
            measure("Sales YTD", "TOTALYTD([Total Sales], 'Date'[Date])", "$#,0", folder: "Time intelligence"),
            measure("Sales PY", "CALCULATE([Total Sales], SAMEPERIODLASTYEAR('Date'[Date]))", "$#,0", folder: "Time intelligence"),
            measure("Sales YoY %", "DIVIDE([Total Sales] - [Sales PY], [Sales PY])", "+0.0%;-0.0%", folder: "Time intelligence"),
        ]
        model.tables = [mSales, mProduct, mCustomer, mDate]
        model.relationships = [
            Relationship(fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "ProductID"),
            Relationship(fromTable: "Sales", fromColumn: "CustomerID", toTable: "Customer", toColumn: "CustomerID"),
            Relationship(fromTable: "Sales", fromColumn: "Order Date", toTable: "Date", toColumn: "Date"),
        ]

        // Starter report
        var report = Report()
        var page = Page(name: "Overview")
        func visual(_ type: VisualType, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ configure: (inout VisualSpec) -> Void) {
            var v = VisualSpec(type: type, frame: Frame(x: x, y: y, width: w, height: h))
            v.zIndex = page.visuals.count
            configure(&v)
            page.visuals.append(v)
        }
        let m = { (name: String) in FieldRef.measure("Sales", name) }
        visual(.textBox, 32, 24, 600, 44) { $0.content = "# Sales overview"; $0.name = "Title" }
        visual(.slicer, 1008, 24, 240, 60) { v in
            v.setFields(.field, [.column("Date", "Year")]); v.setFmt("slicer", "style", .string("tile")); v.setFmt("title", "show", .bool(false))
        }
        for (i, name) in ["Total Sales", "Profit", "Margin %", "Orders"].enumerated() {
            visual(.card, 32 + Double(i) * 308, 92, 292, 112) { $0.setFields(.values, [m(name)]); $0.name = name }
        }
        visual(.lineClusteredColumn, 32, 220, 760, 300) { v in
            v.setFields(.category, [.column("Date", "Month Year")])
            v.setFields(.values, [m("Total Sales")]); v.setFields(.lineValues, [m("Margin %")])
            v.setFmt("title", "text", .string("Sales and margin by month"))
        }
        visual(.donut, 808, 220, 440, 300) { v in
            v.setFields(.legend, [.column("Customer", "Segment")]); v.setFields(.values, [m("Total Sales")])
        }
        visual(.clusteredBar, 32, 536, 440, 160) { v in
            v.setFields(.category, [.column("Product", "Category"), .column("Product", "Subcategory"), .column("Product", "Product")])
            v.setFields(.values, [m("Total Sales")])
        }
        visual(.table, 488, 536, 760, 160) { v in
            v.setFields(.values, [.column("Customer", "Country"), m("Total Sales"), m("Profit"), m("Margin %"), m("Sales YoY %")])
            v.name = "Countries"
        }
        report.pages = [page]
        return ([sales, product, customer, date], model, report)
    }
}
