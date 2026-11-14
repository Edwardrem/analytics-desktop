import XCTest
import AppKit
import SwiftUI
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// End to end, headless, through the code the window runs: load the sample data with its command,
/// then add every visual type from the Visualizations gallery's command, give it fields the way the
/// Data pane does, run the live query and draw the result offscreen.
///
/// Expected values come from the sample's definition, not from the engine: 4 categories,
/// 9 subcategories, 24 products, 4 segments, 20 cities in 13 countries, 3 years (2024–2026) of
/// 1,096 days, and totals summed here straight from the Sales rows.
@MainActor
final class EndToEndSmokeTests: XCTestCase {
    private let category = FieldRef.column("Product", "Category")
    private let subcategory = FieldRef.column("Product", "Subcategory")
    private let product = FieldRef.column("Product", "Product")
    private let segment = FieldRef.column("Customer", "Segment")
    private let country = FieldRef.column("Customer", "Country")
    private let city = FieldRef.column("Customer", "City")
    private let year = FieldRef.column("Date", "Year")
    private let day = FieldRef.column("Date", "Date")
    private let unitPrice = FieldRef.column("Sales", "Unit Price")
    private let orderDate = FieldRef.column("Sales", "Order Date")
    private func m(_ name: String) -> FieldRef { .measure("Sales", name) }

    // MARK: Sample data

    func testSampleDataLoadsThroughItsCommandWithoutModelErrors() async {
        let store = await Smoke.emptyStore()
        XCTAssertTrue(store.model.tables.isEmpty)
        XCTAssertNotNil(AppCommands.command("data.sample"))
        AppCommands.run("data.sample", store)
        await Smoke.settle(store)

        XCTAssertEqual(store.modelErrors, [:], "the sample model has engine errors")
        XCTAssertEqual(store.model.tables.map(\.name), ["Sales", "Product", "Customer", "Date"])
        XCTAssertEqual(store.model.relationships.count, 3)
        XCTAssertEqual(store.doc.data.tables["Product"]?.rowCount, 24)
        XCTAssertEqual(store.doc.data.tables["Customer"]?.rowCount, 240)
        XCTAssertEqual(store.doc.data.tables["Date"]?.rowCount, 1096)
        XCTAssertGreaterThan(store.doc.data.tables["Sales"]?.rowCount ?? 0, 10_000)
        XCTAssertEqual(store.status?.kind, .success)
        XCTAssertEqual(store.undoName, "Load Sample Data")
        XCTAssertTrue(store.isDirty)

        // The starter page queried every data visual, and none of them failed.
        let page = store.currentPage
        XCTAssertEqual(page.name, "Overview")
        XCTAssertEqual(page.visuals.count, 10)
        for spec in page.visuals where !spec.type.isPageElement {
            let data = store.visualData[spec.id]
            XCTAssertNotNil(data, "\(spec.name) was never queried")
            XCTAssertNil(data?.error, "\(spec.name): \(data?.error ?? "")")
            XCTAssertFalse(data?.isEmpty ?? true, "\(spec.name) has no rows")
        }
        // The Total Sales card shows the sum of the Sales rows.
        let total = Smoke.sum(store, "Sales", "Amount")
        let card = page.visuals.first { $0.name == "Total Sales" }
        let shown = card.flatMap { store.visualData[$0.id]?.table.rows.first?.first?.asDouble }
        XCTAssertEqual(shown ?? .nan, total, accuracy: 0.01)
        // Loading it twice replaces the tables instead of doubling the model.
        AppCommands.run("data.sample", store)
        await Smoke.settle(store)
        XCTAssertEqual(store.model.tables.count, 4)
        XCTAssertEqual(store.model.relationships.count, 3, "relationships were duplicated by a second load")
        XCTAssertEqual(store.modelErrors, [:])
    }

    // MARK: Every visual type

    /// The fields each type is given (in the order a user would add them) and the rows to expect.
    private func plan(_ type: VisualType) -> (fields: [(Well, FieldRef)], rows: Int?) {
        let sales = m("Total Sales")
        switch type {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .ribbon:
            return ([(.category, category), (.values, sales), (.values, m("Total Cost"))], 4)
        case .lineStackedColumn, .lineClusteredColumn:
            return ([(.category, year), (.values, sales), (.lineValues, m("Margin %"))], 3)
        case .waterfall: return ([(.category, segment), (.values, m("Profit"))], 4)
        case .pie, .donut: return ([(.legend, segment), (.values, sales)], 4)
        case .treemap, .dotPlot: return ([(.category, category), (.values, sales)], 4)
        case .sunburst: return ([(.category, category), (.category, subcategory), (.values, sales)], 9)
        case .funnel, .radar, .wordCloud: return ([(.category, subcategory), (.values, sales)], 9)
        case .scatter: return ([(.details, product), (.x, sales), (.y, m("Profit")), (.size, m("Units"))], 24)
        case .map, .azureMap:
            return ([(.location, city), (.latitude, .column("Customer", "Latitude")), (.longitude, .column("Customer", "Longitude")), (.size, sales)], 20)
        case .filledMap, .shapeMap: return ([(.location, country), (.values, sales)], 13)
        case .card, .cardLegacy: return ([(.values, sales)], 1)
        case .multiRowCard: return ([(.values, sales), (.values, m("Orders"))], 1)
        case .kpi: return ([(.values, sales), (.trendAxis, year), (.target, m("Total Cost"))], 3)
        case .gauge, .bullet: return ([(.values, m("Profit")), (.target, sales)], 1)
        case .table: return ([(.values, country), (.values, sales)], 13)
        case .matrix, .heatmap: return ([(.rows, category), (.columns, segment), (.values, sales)], 16)
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer: return ([(.field, segment)], 4)
        // Key influencers analyses rows, so it is given a column to explain.
        case .keyInfluencers: return ([(.analyze, .column("Sales", "Amount")), (.explainBy, segment)], 4)
        case .decompositionTree: return ([(.analyze, sales), (.explainBy, category)], 4)
        case .gantt: return ([(.task, category), (.start, orderDate), (.end, orderDate)], 4)
        case .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics: return ([(.values, sales)], 1)
        case .histogram, .boxPlot: return ([(.values, sales), (.category, product)], 24)
        case .sankey: return ([(.source, segment), (.destination, category), (.values, sales)], 16)
        case .calendarHeatmap: return ([(.category, day), (.values, sales)], 1096)
        case .candlestick:
            return ([(.category, year), (.open, unitPrice), (.high, unitPrice), (.low, unitPrice), (.close, unitPrice)], 3)
        case .narrative, .qna, .textBox, .image, .shape, .button, .pageNavigator, .bookmarkNavigator:
            return ([], nil)
        }
    }

    /// Adds a visual the way the window does: data visuals from the gallery's command, page
    /// elements from the Insert commands. The image command opens a file panel, so an image goes in
    /// through the store call that command ends in.
    private func add(_ type: VisualType, to store: DocumentStore) -> UUID? {
        store.selection = []
        switch type {
        case .image:
            let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
                NSColor.systemTeal.setFill(); rect.fill(); return true
            }
            let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            store.addVisual(.image) { $0.imageData = png }
        case .textBox, .button, .shape, .pageNavigator, .bookmarkNavigator:
            AppCommands.run("insert.\(type.rawValue)", store)
        default:
            AppCommands.run(RibbonLayout.visualPrefix + type.rawValue, store)
        }
        guard let spec = store.selectedVisual, spec.type == type else { return nil }
        return spec.id
    }

    func testEveryVisualTypeQueriesAndRenders() async throws {
        let store = await Smoke.sampleStore()
        AppCommands.run("insert.page", store)
        // A second page and a bookmark, so the navigators have something to show.
        store.addBookmark(named: "Start")
        let total = Smoke.sum(store, "Sales", "Amount")
        XCTAssertGreaterThan(total, 1_000_000)
        readOrderSpans(store)
        let only = ProcessInfo.processInfo.environment["FACET_SMOKE_ONLY"]
        // One chart stays on the page throughout, so the narrative has something to summarise.
        AppCommands.run(RibbonLayout.visualPrefix + VisualType.clusteredColumn.rawValue, store)
        let anchor = try XCTUnwrap(store.selectedVisual?.id)
        store.addField(category, to: anchor, well: .category)
        store.addField(m("Total Sales"), to: anchor, well: .values)
        store.updateVisual(anchor, invalidates: .layout) { $0.frame = Frame(x: 800, y: 400, width: 420, height: 280) }

        for type in VisualType.allCases {
            if let only, type.rawValue != only { continue }
            let name = type.rawValue
            guard let id = add(type, to: store) else { XCTFail("\(name): the command did not add a \(type.displayName)"); continue }
            XCTAssertEqual(store.undoName, "Add \(type.displayName)", "\(name): adding it is not an undo step")
            let (fields, expectedRows) = plan(type)
            XCTAssertEqual(fields.isEmpty, type.wells.isEmpty, "\(name): the plan and the type's wells disagree")
            for (well, field) in fields {
                XCTAssertTrue(type.wells.contains(well), "\(name) has no \(well.rawValue) well")
                store.addField(field, to: id, well: well)
            }
            if type == .candlestick {
                // As in the Build pane: pick each field's summarization after adding it.
                let pick: [(Well, Aggregation)] = [(.open, .median), (.high, .max), (.low, .min), (.close, .average)]
                store.updateVisual(id, name: "Summarize") { v in
                    for (well, aggregation) in pick {
                        var f = v.fields(well); if !f.isEmpty { f[0].aggregation = aggregation }; v.setFields(well, f)
                    }
                }
            }
            await Smoke.settle(store)
            guard let spec = store.visual(id) else { XCTFail("\(name): the visual vanished"); continue }
            XCTAssertEqual(spec.allFields.count, fields.count, "\(name): not every field landed in a well")
            let data = store.visualData[id] ?? VisualData()

            // The query.
            XCTAssertNil(data.error, "\(name): \(data.error ?? "")")
            if let expectedRows {
                XCTAssertEqual(data.table.rowCount, expectedRows, "\(name): rows")
                for (well, _) in fields {
                    XCTAssertFalse(data.indices(well).isEmpty, "\(name): no result column for the \(well.rawValue) well")
                }
                XCTAssertFalse(data.daxQuery.isEmpty, "\(name): no DAX recorded")
                checkTotals(name, data, total: total)
                checkValues(type, data)
            }

            // The drawing, at the size the visual has on the page: something is there, and with data
            // it is neither the "add fields" placeholder nor the error state.
            let size = CGSize(width: spec.frame.width, height: spec.frame.height)
            let context = store.context(for: spec, interactive: false)
            // The AI visuals analyse after they appear; give them time to draw their result.
            let patience: Double = Self.analysesAfterAppearing.contains(type) ? 6 : 0
            guard let drawn = await Smoke.bitmap(VisualView(spec: spec, data: data, context: context), size: size, patience: patience) else {
                XCTFail("\(name): nothing could be drawn"); continue
            }
            if let folder = ProcessInfo.processInfo.environment["FACET_SMOKE_DUMP"], let png = drawn.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
            }
            // Page elements have no card behind them, so draw over a backdrop and look for the element.
            let backdrop = await Smoke.bitmap(Color.clear, size: size)
            let ink = Smoke.ink(drawn)
            if type.isPageElement {
                XCTAssertGreaterThan(backdrop.map { Smoke.difference(drawn, $0) } ?? 0, 0.004, "\(name): nothing is drawn")
            } else {
                XCTAssertGreaterThanOrEqual(ink.colours, 3, "\(name): the drawing is flat")
                XCTAssertGreaterThan(ink.share, 0.004, "\(name): the drawing is blank")
            }
            if expectedRows != nil, !Self.drawsWithoutData.contains(type),
               let empty = await Smoke.bitmap(VisualView(spec: spec, data: VisualData(), context: context), size: size) {
                XCTAssertGreaterThan(Smoke.difference(drawn, empty), 0.004, "\(name): with data it draws the same as with none")
            }
            var failed = data
            failed.error = "Smoke test error"
            if !type.isPageElement, let error = await Smoke.bitmap(VisualView(spec: spec, data: failed, context: context), size: size) {
                XCTAssertGreaterThan(Smoke.difference(drawn, error), 0.004, "\(name): it draws the error state")
            }
            // The exporter's renderer (Copy as image) produces a real image too.
            let image = VisualExport.render(spec, store: store, scale: 1)
            XCTAssertEqual(image?.size.width ?? 0, CGFloat(spec.frame.width), accuracy: 1, "\(name): exported image width")

            // Taking it away again leaves the page as it was.
            store.deleteSelection()
            XCTAssertNil(store.visual(id), "\(name): delete did not remove it")
        }
        XCTAssertEqual(store.currentPage.visuals.map(\.id), [anchor])
    }

    /// Visuals that compute their content in a task after they appear.
    private static let analysesAfterAppearing: Set<VisualType> = [.keyInfluencers, .decompositionTree, .narrative, .qna]
    /// Visuals whose drawing does not depend on their query: the input slicer is a text box, the
    /// scripted and embedded visuals show their set-up prompt until a script or address is entered,
    /// and Key influencers explaining a column analyses that table's rows under the page's filters
    /// (see `InteractionSmokeTests.testKeyInfluencersAnalyseTheRowsTheSlicersLeave`).
    private static let drawsWithoutData: Set<VisualType> = [
        .inputSlicer, .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics, .keyInfluencers,
    ]

    /// Wherever Total Sales is in the result, its rows add up to the Sales rows' own sum, and the
    /// grand total the engine reports is that sum.
    private func checkTotals(_ name: String, _ data: VisualData, total: Double) {
        guard let column = data.fields.firstIndex(where: { $0?.kind == .measure && $0?.name == "Total Sales" }) else { return }
        let sum = (0..<data.table.rowCount).reduce(0.0) { $0 + (data.table[$1, column].asDouble ?? 0) }
        XCTAssertEqual(sum, total, accuracy: 0.5, "\(name): Total Sales over the rows")
        let grouped = data.fields.contains { $0.map { !$0.isAggregate } ?? false }
        if grouped {
            XCTAssertEqual(data.totals[safe: column]?.asDouble ?? .nan, total, accuracy: 0.5, "\(name): grand total")
        }
    }

    /// First and last order date of a product category, from the Sales and Product rows.
    private var orderSpans: [String: (first: Date, last: Date)] = [:]
    private func orderSpan(_ category: String) -> (first: Date, last: Date)? { orderSpans[category] }
    private func readOrderSpans(_ store: DocumentStore) {
        guard let sales = store.doc.data.tables["Sales"], let products = store.doc.data.tables["Product"],
              let pid = products.columnIndex("ProductID"), let cat = products.columnIndex("Category"),
              let sp = sales.columnIndex("ProductID"), let sd = sales.columnIndex("Order Date") else { return }
        var categoryOf: [Value: String] = [:]
        for r in 0..<products.rowCount { categoryOf[products[r, pid]] = products[r, cat].asString }
        for r in 0..<sales.rowCount {
            guard let c = categoryOf[sales[r, sp]], case .date(let d) = sales[r, sd] else { continue }
            let old = orderSpans[c]
            orderSpans[c] = (min(old?.first ?? d, d), max(old?.last ?? d, d))
        }
    }

    /// Checks that depend on the type: coordinates are coordinates, dates are dates, prices are ordered.
    private func checkValues(_ type: VisualType, _ data: VisualData) {
        let name = type.rawValue
        func numbers(_ well: Well) -> [Double] { data.column(well)?.values.compactMap(\.asDouble) ?? [] }
        switch type {
        case .map, .azureMap:
            // Every city has one position: the latitude of its customers, not their sum.
            XCTAssertEqual(numbers(.latitude).count, 20, "\(name): latitudes")
            XCTAssertTrue(numbers(.latitude).allSatisfy { (-90...90).contains($0) }, "\(name): latitudes out of range \(numbers(.latitude).prefix(4))")
            XCTAssertTrue(numbers(.longitude).allSatisfy { (-180...180).contains($0) }, "\(name): longitudes out of range")
            let cities = data.column(.location)?.values.map(\.asString) ?? []
            if let harare = cities.firstIndex(of: "Harare") {
                XCTAssertEqual(numbers(.latitude)[safe: harare] ?? .nan, -17.83, accuracy: 1e-6, "\(name): Harare latitude")
                XCTAssertEqual(numbers(.longitude)[safe: harare] ?? .nan, 31.05, accuracy: 1e-6, "\(name): Harare longitude")
            } else { XCTFail("\(name): Harare is missing") }
        case .gantt:
            // Each category's bar runs from its first order to its last, read here from the Sales rows.
            let starts = data.column(.start)?.values ?? [], ends = data.column(.end)?.values ?? []
            let tasks = data.column(.task)?.values.map(\.asString) ?? []
            XCTAssertEqual(tasks.count, 4)
            for (i, task) in tasks.enumerated() {
                guard case .date(let from)? = starts[safe: i], case .date(let to)? = ends[safe: i] else {
                    XCTFail("\(name): start/end of \(task) are not dates"); continue
                }
                let span = orderSpan(task)
                XCTAssertEqual(from, span?.first, "\(name): start of \(task)")
                XCTAssertEqual(to, span?.last, "\(name): end of \(task)")
                XCTAssertLessThan(from, to)
            }
        case .candlestick:
            let low = numbers(.low), high = numbers(.high), open = numbers(.open), close = numbers(.close)
            XCTAssertEqual(low, [29, 29, 29], "\(name): the cheapest product is 29")
            XCTAssertEqual(high, [2399, 2399, 2399], "\(name): the dearest product is 2399")
            for i in 0..<min(open.count, close.count, 3) {
                XCTAssertTrue((29...2399).contains(open[i]) && (29...2399).contains(close[i]), "\(name): open/close outside low…high")
            }
        case .card, .cardLegacy, .multiRowCard, .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics:
            XCTAssertEqual(data.table.columnCount, type == .multiRowCard ? 2 : 1, "\(name): columns")
        case .slicer, .buttonSlicer, .listSlicer, .inputSlicer:
            XCTAssertEqual(Set(data.table.columns.first?.values.map(\.asString) ?? []), ["Consumer", "Small Business", "Enterprise", "Education"], name)
        case .lineStackedColumn, .lineClusteredColumn, .kpi:
            let years = (type == .kpi ? data.column(.trendAxis) : data.column(.category))?.values.compactMap(\.asDouble) ?? []
            XCTAssertEqual(Set(years), [2024, 2025, 2026], "\(name): years")
        default: break
        }
    }
}
