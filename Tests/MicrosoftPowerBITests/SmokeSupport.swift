import XCTest
import AppKit
import SwiftUI
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Shared plumbing for the end-to-end smoke suite: real stores on the live services, waiting for
/// the engine, offscreen rendering, and whole-document comparison.
@MainActor
enum Smoke {
    /// A document store on the live engines, as a new window gets one.
    static func emptyStore() async -> DocumentStore {
        Features.registerAll()
        let store = DocumentStore(services: .live())
        await settle(store)
        return store
    }

    /// A store with the sample data loaded through the `Data ▸ Load Sample Data` command.
    static func sampleStore() async -> DocumentStore {
        let store = await emptyStore()
        AppCommands.run("data.sample", store)
        await settle(store)
        return store
    }

    /// Waits until the engine has loaded and every pending visual query has delivered its result.
    /// The store hops calculation queue → main queue (→ calculation queue → main queue), so this
    /// drains both until nothing has been loading for several rounds in a row.
    static func settle(_ store: DocumentStore, file: StaticString = #filePath, line: UInt = #line) async {
        var quiet = 0
        for _ in 0..<20_000 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.calcQueue.async { c.resume() } }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
            quiet = store.loadingVisuals.isEmpty ? quiet + 1 : 0
            if quiet >= 4 { return }
        }
        XCTFail("the store never settled: \(store.loadingVisuals.count) visuals still loading", file: file, line: line)
    }

    /// Runs the main run loop until `condition` holds (for work that finishes in a `Task`).
    static func wait(seconds: Double = 20, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: Rendering

    /// Hosts a view at a real size in a window that is never shown (so `onAppear` and `task` run as
    /// they do on screen), lays it out and draws it into a bitmap. With `patience`, views that
    /// compute after they appear get up to that many seconds for the drawing to change.
    static func bitmap<V: View>(_ view: V, size: CGSize, patience: Double = 0) async -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func capture() -> NSBitmapImageRep? {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        guard let first = capture() else { return nil }
        guard patience > 0 else { return first }
        let deadline = Date().addingTimeInterval(patience)
        var latest = first
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let next = capture() else { break }
            latest = next
            if difference(first, next) > 0.002 {
                // It changed: give it a moment to finish, then take the settled drawing.
                try? await Task.sleep(nanoseconds: 300_000_000)
                return capture() ?? next
            }
        }
        return latest
    }

    /// Hosts a view offscreen and runs a layout pass, as a window would. Returns the fitted size.
    @discardableResult
    static func host<V: View>(_ view: V, size: CGSize) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        return host.fittingSize
    }

    /// What a bitmap holds, sampled on a grid: how many different colours, and the share of samples
    /// that differ from the most common one (the background).
    static func ink(_ rep: NSBitmapImageRep, step: Int = 3) -> (colours: Int, share: Double) {
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Quantise to 5 bits a channel so antialiasing noise does not count as colour.
                let key = UInt32(c.redComponent * 31) << 16 | UInt32(c.greenComponent * 31) << 8 | UInt32(c.blueComponent * 31)
                    | (c.alphaComponent < 0.05 ? 1 << 24 : 0)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let background = counts.values.max() else { return (0, 0) }
        return (counts.count, Double(total - background) / Double(total))
    }

    /// The share of samples at which two bitmaps of the same size differ.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, step: Int = 3) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var differing = 0, total = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: step) {
            for x in stride(from: 0, to: a.pixelsWide, by: step) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent) + abs(p.alphaComponent - q.alphaComponent) > 0.06 { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    // MARK: Comparing documents

    private static func canonical<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }

    /// Asserts two documents hold the same model, report, queries, sources and data.
    static func assertSame(_ a: FacetDocument, _ b: FacetDocument, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(canonical(a.model), canonical(b.model), "\(what): model differs", file: file, line: line)
        XCTAssertEqual(a.report.pages, b.report.pages, "\(what): pages differ", file: file, line: line)
        XCTAssertEqual(a.report.theme, b.report.theme, "\(what): theme differs", file: file, line: line)
        XCTAssertEqual(a.report.bookmarks, b.report.bookmarks, "\(what): bookmarks differ", file: file, line: line)
        XCTAssertEqual(a.report.filters, b.report.filters, "\(what): report filters differ", file: file, line: line)
        XCTAssertEqual(a.report.settings, b.report.settings, "\(what): settings differ", file: file, line: line)
        XCTAssertEqual(a.report.landingPageID, b.report.landingPageID, "\(what): landing page differs", file: file, line: line)
        XCTAssertEqual(a.report.daxQueries, b.report.daxQueries, "\(what): DAX query tabs differ", file: file, line: line)
        XCTAssertEqual(a.queries, b.queries, "\(what): queries differ", file: file, line: line)
        XCTAssertEqual(a.dataSources, b.dataSources, "\(what): data sources differ", file: file, line: line)
        XCTAssertEqual(a.data.tables.keys.sorted(), b.data.tables.keys.sorted(), "\(what): tables differ", file: file, line: line)
        for (name, table) in a.data.tables {
            guard let other = b.data.tables[name] else { continue }
            XCTAssertEqual(table.columnNames, other.columnNames, "\(what): \(name) columns differ", file: file, line: line)
            XCTAssertEqual(table.columns.map(\.type), other.columns.map(\.type), "\(what): \(name) column types differ", file: file, line: line)
            XCTAssertEqual(table.rowCount, other.rowCount, "\(what): \(name) row count differs", file: file, line: line)
            for (x, y) in zip(table.columns, other.columns) where x.values != y.values {
                XCTFail("\(what): values of \(name)[\(x.name)] differ", file: file, line: line)
            }
        }
    }

    // MARK: Sample facts, computed straight from the source rows

    /// The sum of a numeric column of a source table, without going near the engine.
    static func sum(_ store: DocumentStore, _ table: String, _ column: String, where keep: ([Value]) -> Bool = { _ in true }) -> Double {
        guard let t = store.doc.data.tables[table], let c = t.columnIndex(column) else { return .nan }
        var total = 0.0
        for r in 0..<t.rowCount where keep(t.row(r)) { total += t[r, c].asDouble ?? 0 }
        return total
    }

    /// Temporary folder for one test, removed afterwards by the caller.
    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facet-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Building a page as a user does

    /// Adds a data visual from the Visualizations gallery's command and drops fields into its wells
    /// the way the Data pane does. Returns the new visual's id.
    @discardableResult
    static func addVisual(_ type: VisualType, _ fields: [(Well, FieldRef)], to store: DocumentStore,
                          file: StaticString = #filePath, line: UInt = #line) -> UUID {
        store.selection = []
        AppCommands.run(RibbonLayout.visualPrefix + type.rawValue, store)
        guard let id = store.selectedVisual?.id, store.selectedVisual?.type == type else {
            XCTFail("the gallery command did not add a \(type.displayName)", file: file, line: line)
            return UUID()
        }
        for (well, field) in fields { store.addField(field, to: id, well: well) }
        return id
    }

    /// The data point a chart's mark stands for, built as the chart builds it (`SeriesModel`).
    static func point(_ store: DocumentStore, _ id: UUID, category value: String,
                      file: StaticString = #filePath, line: UInt = #line) -> DataPointSelection {
        guard let spec = store.visual(id), let data = store.visualData[id] else {
            XCTFail("the visual has no data", file: file, line: line)
            return DataPointSelection(fields: [], values: [])
        }
        let model = SeriesModel(spec: spec, data: data)
        guard let c = model.categories.firstIndex(where: { $0.values.last?.asString == value }) else {
            XCTFail("no mark for \(value) in \(model.categories.map(\.label))", file: file, line: line)
            return DataPointSelection(fields: [], values: [])
        }
        return model.selection(category: c)
    }

    /// The data point behind a row of a visual without a category axis (pie legend, table row).
    static func point(_ store: DocumentStore, _ id: UUID, row value: String, in well: Well,
                      file: StaticString = #filePath, line: UInt = #line) -> DataPointSelection {
        let data = store.visualData[id] ?? VisualData()
        guard let column = data.indices(well).first,
              let row = (0..<data.table.rowCount).first(where: { data.table[$0, column].asString == value }) else {
            XCTFail("no row for \(value)", file: file, line: line)
            return DataPointSelection(fields: [], values: [])
        }
        return SeriesModel.selection(data: data, row: row, columns: data.indices(well))
    }

    /// A visual's result as label → number, read from the first column of `labels` and the column of `values`.
    static func series(_ store: DocumentStore, _ id: UUID, labels: Well, values: Well = .values, baseline: Bool = false) -> [String: Double] {
        let data = store.visualData[id] ?? VisualData()
        guard let l = data.indices(labels).first, let v = data.indices(values).first else { return [:] }
        let table = baseline ? (data.baseline ?? DataTable()) : data.table
        var out: [String: Double] = [:]
        for r in 0..<table.rowCount where !table[r, v].isNull {
            out[table[r, l].asString, default: 0] += table[r, v].asDouble ?? 0
        }
        return out
    }

    /// A table visual's rows as first column → last column.
    static func rows(_ store: DocumentStore, _ id: UUID) -> [String: Double] {
        let table = store.visualData[id]?.table ?? DataTable()
        guard table.columnCount >= 2 else { return [:] }
        var out: [String: Double] = [:]
        for r in 0..<table.rowCount { out[table[r, 0].asString, default: 0] += table[r, table.columnCount - 1].asDouble ?? 0 }
        return out
    }

    /// The kinds of value a column holds ("int", "double", …), to catch values that change kind.
    static func kinds(_ values: [Value]) -> Set<String> {
        Set(values.map { v -> String in
            switch v {
            case .null: return "null"
            case .bool: return "bool"
            case .int: return "int"
            case .double: return "double"
            case .string: return "string"
            case .date: return "date"
            }
        })
    }

    /// The single number a card shows.
    static func card(_ store: DocumentStore, _ id: UUID) -> Double {
        store.visualData[id]?.table.rows.first?.first?.asDouble ?? .nan
    }
}

/// `XCTUnwrap` for a value produced by an `await`.
func XCTUnwrapAsync<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}

/// Asserts two label → number maps hold the same labels and (within a cent) the same numbers.
func assertSameSeries(_ actual: [String: Double], _ expected: [String: Double], _ what: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Set(actual.keys), Set(expected.keys), "\(what): labels", file: file, line: line)
    for (key, value) in expected {
        XCTAssertEqual(actual[key] ?? .nan, value, accuracy: 0.01, "\(what): \(key)", file: file, line: line)
    }
}

/// The sample's sales rows joined to their product, customer and date in plain Swift, so expected
/// values never come from the engine under test.
struct SampleFacts {
    struct Row {
        var category = "", subcategory = "", product = "", segment = "", country = "", city = ""
        var date = Date.distantPast
        var amount = 0.0, unitPrice = 0.0
    }
    let rows: [Row]

    @MainActor
    init(_ store: DocumentStore) {
        let data = store.doc.data
        guard let sales = data.tables["Sales"], let products = data.tables["Product"], let customers = data.tables["Customer"] else {
            rows = []; return
        }
        func index(_ t: DataTable, _ key: String) -> [Value: [Value]] {
            guard let k = t.columnIndex(key) else { return [:] }
            var out: [Value: [Value]] = [:]
            for r in 0..<t.rowCount { out[t[r, k]] = t.row(r) }
            return out
        }
        let product = index(products, "ProductID"), customer = index(customers, "CustomerID")
        func col(_ t: DataTable, _ name: String) -> Int { t.columnIndex(name) ?? -1 }
        let (pCat, pSub, pName) = (col(products, "Category"), col(products, "Subcategory"), col(products, "Product"))
        let (cSeg, cCountry, cCity) = (col(customers, "Segment"), col(customers, "Country"), col(customers, "City"))
        let (sProduct, sCustomer, sDate, sAmount, sPrice) = (col(sales, "ProductID"), col(sales, "CustomerID"), col(sales, "Order Date"),
                                                             col(sales, "Amount"), col(sales, "Unit Price"))
        var out: [Row] = []
        out.reserveCapacity(sales.rowCount)
        for r in 0..<sales.rowCount {
            var row = Row()
            if let p = product[sales[r, sProduct]] {
                row.category = p[pCat].asString; row.subcategory = p[pSub].asString; row.product = p[pName].asString
            }
            if let c = customer[sales[r, sCustomer]] {
                row.segment = c[cSeg].asString; row.country = c[cCountry].asString; row.city = c[cCity].asString
            }
            if case .date(let d) = sales[r, sDate] { row.date = d }
            row.amount = sales[r, sAmount].asDouble ?? 0
            row.unitPrice = sales[r, sPrice].asDouble ?? 0
            out.append(row)
        }
        rows = out
    }

    func total(where keep: (Row) -> Bool = { _ in true }) -> Double {
        rows.reduce(0) { keep($1) ? $0 + $1.amount : $0 }
    }
    func totals(by key: (Row) -> String, where keep: (Row) -> Bool = { _ in true }) -> [String: Double] {
        var out: [String: Double] = [:]
        for row in rows where keep(row) { out[key(row), default: 0] += row.amount }
        return out
    }

    /// A UTC calendar day.
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.utc.date(from: DateComponents(year: y, month: m, day: d)) ?? .distantPast
    }
    static func year(_ d: Date) -> Int { Calendar.utc.component(.year, from: d) }
}
