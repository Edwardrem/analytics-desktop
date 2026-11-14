import XCTest
import AppKit
import PDFKit
import FacetCore
import FacetQuery
import FacetVisuals
@testable import MicrosoftPowerBI

/// End to end on whole documents: undo and redo across a run of edits, saving to a `.facet`
/// package and opening it again, exporting to PDF, image and data files, and getting a CSV
/// through Get Data and the Power Query engine into a visual.
@MainActor
final class DocumentSmokeTests: XCTestCase {
    private let category = FieldRef.column("Product", "Category")
    private let segment = FieldRef.column("Customer", "Segment")
    private let country = FieldRef.column("Customer", "Country")
    private let sales = FieldRef.measure("Sales", "Total Sales")
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try Smoke.temporaryFolder()
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try await super.tearDown()
    }

    // MARK: Undo and redo

    func testUndoAndRedoWalkBackAndForthThroughExactDocuments() async throws {
        let store = await Smoke.sampleStore()
        var snapshots: [(name: String, doc: FacetDocument)] = [("", store.doc)]
        func step(_ expected: String, _ edit: () -> Void) {
            edit()
            XCTAssertEqual(store.undoName, expected)
            snapshots.append((expected, store.doc))
        }
        step("Add Page") { AppCommands.run("insert.page", store) }
        step("Add Clustered column chart") { AppCommands.run(RibbonLayout.visualPrefix + VisualType.clusteredColumn.rawValue, store) }
        let id = try XCTUnwrap(store.selectedVisual?.id)
        step("Add Field") { store.addField(category, to: id, well: .category) }
        step("Add Field") { store.addField(sales, to: id, well: .values) }
        step("Move") { store.setFrames([id: Frame(x: 40, y: 60, width: 500, height: 300)]) }
        step("Change Visual") { store.updateVisual(id, invalidates: .layout) { $0.setFmt("title", "text", .string("Sales by category")) } }
        step("Change Visual Type") { store.changeType(of: id, to: .clusteredBar) }
        step("Add Page Filter") { store.addFilter(segment, scope: .page, announce: true) }
        let filter = try XCTUnwrap(store.currentPage.filters.first?.id)
        step("Change Filter") { store.updateFilter(id: filter, scope: .page) { $0.values = [.string("Enterprise")] } }
        step("Add Measure") {
            store.updateModel("Add Measure") { m in
                if let i = m.tableIndex("Sales") { m.tables[i].measures.append(Measure(name: "Double Sales", expression: "[Total Sales] * 2")) }
            }
        }
        step("Add Bookmark") { store.addBookmark(named: "Enterprise view") }
        step("Duplicate") { store.selection = [id]; store.duplicateSelection() }
        step("Delete Visual") { store.selection = [id]; store.deleteSelection() }
        await Smoke.settle(store)
        let final = store.doc

        // Undo every step: each one restores the document exactly as it was before that step.
        for k in stride(from: snapshots.count - 1, through: 1, by: -1) {
            XCTAssertEqual(store.undoName, snapshots[k].name)
            AppCommands.run("edit.undo", store)
            Smoke.assertSame(store.doc, snapshots[k - 1].doc, "after undoing \(snapshots[k].name) (step \(k))")
        }
        // Back at the loaded sample: loading it is the one step left to undo.
        XCTAssertEqual(store.undoName, "Load Sample Data")
        await Smoke.settle(store)
        XCTAssertEqual(store.modelErrors, [:])

        // Redo every step: each one brings the edit back exactly.
        for k in 1..<snapshots.count {
            XCTAssertEqual(store.redoName, snapshots[k].name)
            AppCommands.run("edit.redo", store)
            Smoke.assertSame(store.doc, snapshots[k].doc, "after redoing \(snapshots[k].name) (step \(k))")
        }
        XCTAssertNil(store.redoName)
        Smoke.assertSame(store.doc, final, "after redoing everything")
        // The engine follows: the restored measure works and the page filter applies.
        await Smoke.settle(store)
        XCTAssertEqual(store.modelErrors, [:])
        let value = await store.withEngine { (try? $0.scalar("[Double Sales]", filters: [])) ?? .null }
        XCTAssertEqual(value.asDouble ?? .nan, 2 * SampleFacts(store).total(), accuracy: 0.05)

        // A new edit after undoing clears what could be redone.
        AppCommands.run("edit.undo", store)
        XCTAssertNotNil(store.redoName)
        AppCommands.run("insert.page", store)
        XCTAssertNil(store.redoName)
        XCTAssertFalse(AppCommands.command("edit.redo")?.isEnabled(store) ?? true)
    }

    func testDragsAndTypingCoalesceIntoOneUndoStep() async {
        let store = await Smoke.sampleStore()
        let id = Smoke.addVisual(.card, [(.values, sales)], to: store)
        let before = store.doc
        for x in stride(from: 100.0, through: 160, by: 10) {
            store.setFrames([id: Frame(x: x, y: 300, width: 220, height: 130)], name: "Move", coalesce: "drag-\(id)")
        }
        XCTAssertEqual(store.visual(id)?.frame.x, 160)
        AppCommands.run("edit.undo", store)
        Smoke.assertSame(store.doc, before, "one undo takes back the whole drag")
    }

    // MARK: Save and open

    func testSaveToAFacetPackageAndOpenItAgain() async throws {
        let store = await Smoke.sampleStore()
        // Give the document something of everything: a second page with a slicer and a chart, a
        // report filter, a bookmark, a theme colour and a DAX query.
        AppCommands.run("insert.page", store)
        let slicer = Smoke.addVisual(.slicer, [(.field, segment)], to: store)
        let chart = Smoke.addVisual(.clusteredColumn, [(.category, category), (.values, sales)], to: store)
        store.setSlicerState({ var s = SlicerState(); s.selected = [.string("Education")]; return s }(), for: slicer)
        store.addFilter(country, scope: .report, announce: true)
        let reportFilter = try XCTUnwrap(store.report.filters.first?.id)
        store.updateFilter(id: reportFilter, scope: .report) { $0.values = [.string("Kenya"), .string("Japan")] }
        store.addBookmark(named: "Education")
        store.mutate("Change Theme", invalidates: .layout) { d in
            d.report.theme.dataColors[0] = "#FF00AA"
            d.report.daxQueries[0].text = "EVALUATE VALUES(Product[Category])"
        }
        await Smoke.settle(store)
        let chartBefore = Smoke.series(store, chart, labels: .category)
        XCTAssertFalse(chartBefore.isEmpty)

        // File ▸ Save, to a file the document already has.
        let url = folder.appendingPathComponent("Retail.facet")
        store.fileURL = url
        AppCommands.run("file.save", store)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.displayName, "Retail")
        for part in ["manifest.json", "model.json", "report.json", "queries.json", "data/Sales.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(part).path), "the package has no \(part)")
        }

        // File ▸ Open, into a new window's store.
        let reopened = await Smoke.emptyStore()
        FileOperations.open(url, into: reopened)
        XCTAssertNil(reopened.status?.kind == .error ? reopened.status?.text : nil)
        XCTAssertEqual(reopened.fileURL, url)
        XCTAssertFalse(reopened.isDirty)
        Smoke.assertSame(store.doc, reopened.doc, "reopened")
        // Numbers come back as the kind they were saved as (a whole price is still a decimal).
        for (name, table) in store.doc.data.tables {
            guard let other = reopened.doc.data.tables[name] else { continue }
            for (a, b) in zip(table.columns, other.columns) where Smoke.kinds(a.values) != Smoke.kinds(b.values) {
                XCTFail("\(name)[\(a.name)] comes back as \(Smoke.kinds(b.values)), saved as \(Smoke.kinds(a.values))")
            }
        }
        // It opens on its first page (there is no landing page set).
        XCTAssertEqual(reopened.currentPageID, reopened.report.pages.first?.id)
        reopened.goToPage(try XCTUnwrap(reopened.report.pages.last?.id))
        await Smoke.settle(reopened)
        XCTAssertEqual(reopened.modelErrors, [:])
        assertSameSeries(Smoke.series(reopened, chart, labels: .category), chartBefore, "the chart after reopening")
        XCTAssertNil(reopened.undoName, "opening a document starts a fresh undo history")

        // Saving again over the same package replaces it.
        reopened.updateVisual(chart, invalidates: .layout) { $0.name = "Renamed" }
        XCTAssertTrue(FileOperations.save(reopened))
        XCTAssertEqual(try DocumentPackage.read(from: url).report.pages.last?.visual(chart)?.name, "Renamed")

        // A folder that is not a package says so instead of opening empty.
        let bogus = folder.appendingPathComponent("Not a document.facet")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        let third = await Smoke.emptyStore()
        FileOperations.open(bogus, into: third)
        XCTAssertEqual(third.status?.kind, .error)
        XCTAssertTrue(third.status?.text.contains("is not an \(AppIdentity.name) document") ?? false, third.status?.text ?? "")
        XCTAssertTrue(third.model.tables.isEmpty)
    }

    // MARK: Export

    func testPDFExportDrawsEveryVisiblePage() async throws {
        let store = await Smoke.sampleStore()
        AppCommands.run("insert.page", store)
        Smoke.addVisual(.clusteredColumn, [(.category, category), (.values, sales)], to: store)
        AppCommands.run("insert.tooltipPage", store)   // hidden: not exported
        let start = try XCTUnwrap(store.report.pages.first?.id)
        store.goToPage(start)
        await Smoke.settle(store)

        let url = folder.appendingPathComponent("Retail.pdf")
        try await VisualExport.writePDF(store, to: url)
        XCTAssertEqual(store.currentPageID, start, "the export returns to the page that was showing")
        let pdf = try XCTUnwrap(PDFDocument(url: url), "not a readable PDF")
        XCTAssertEqual(pdf.pageCount, 2)
        let first = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(first.bounds(for: .mediaBox).size, CGSize(width: 1280, height: 720))
        // The overview page has its title and its card captions as real (selectable) text.
        let text = first.string ?? ""
        XCTAssertTrue(text.contains("Sales overview"), "the PDF page has no title text: \(text.prefix(200))")
        // And it is drawn: rasterised, it is not a blank page.
        let image = first.thumbnail(of: CGSize(width: 640, height: 360), for: .mediaBox)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertGreaterThan(Smoke.ink(rep).share, 0.05)
        XCTAssertGreaterThanOrEqual(Smoke.ink(rep).colours, 6)
    }

    func testVisualImageAndDataExport() async throws {
        let store = await Smoke.sampleStore()
        let table = try XCTUnwrap(store.currentPage.visuals.first { $0.name == "Countries" })
        await Smoke.settle(store)
        let data = try XCTUnwrap(store.visualData[table.id])

        // Copy as image renders the visual at twice its size.
        let image = try XCTUnwrap(VisualExport.render(table, store: store, scale: 2))
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(rep.pixelsWide, Int(table.frame.width * 2))
        XCTAssertGreaterThan(Smoke.ink(rep).share, 0.01)

        // Export data, CSV: a header of field captions, then one line per row, unformatted.
        let csv = try XCTUnwrap(VisualExport.dataExporters["csv"], "no CSV exporter is registered")
        let csvURL = folder.appendingPathComponent("Countries.csv")
        XCTAssertEqual(try VisualExport.write(data, with: csv, to: csvURL), 13)
        let lines = try String(contentsOf: csvURL, encoding: .utf8).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 14)
        XCTAssertEqual(lines.first?.replacingOccurrences(of: "\u{FEFF}", with: ""), "Country,Total Sales,Profit,Margin %,Sales YoY %")
        let facts = SampleFacts(store)
        let kenya = try XCTUnwrap(lines.first { $0.hasPrefix("Kenya,") }).split(separator: ",")
        XCTAssertEqual(Double(kenya[1]) ?? .nan, facts.total { $0.country == "Kenya" }, accuracy: 0.01)

        // Excel: a workbook the Power Query engine reads back with the same rows and numbers.
        let xlsx = try XCTUnwrap(VisualExport.dataExporters["xlsx"], "no Excel exporter is registered")
        let xlsxURL = folder.appendingPathComponent("Countries.xlsx")
        XCTAssertEqual(try VisualExport.write(data, with: xlsx, to: xlsxURL), 13)
        let script = "let Source = Excel.Workbook(File.Contents(\"\(xlsxURL.path)\"), true), Data = Source{[Item = \"Data\", Kind = \"Sheet\"]}[Data] in Data"
        let back = try await QueryEngine(queries: [QueryDefinition(name: "Back", mScript: script)], environment: QueryEnvironment()).evaluate("Back")
        XCTAssertEqual(back.columnNames, ["Country", "Total Sales", "Profit", "Margin %", "Sales YoY %"])
        XCTAssertEqual(back.rowCount, 13)
        let row = try XCTUnwrap((0..<back.rowCount).first { back[$0, 0].asString == "Kenya" })
        XCTAssertEqual(back[row, 1].asDouble ?? .nan, facts.total { $0.country == "Kenya" }, accuracy: 0.01)

        // The command itself refuses politely when the report turns data export off.
        store.mutate("No Export") { $0.report.settings.allowExportData = "none" }
        store.selection = [table.id]
        AppCommands.run("drill.exportData", store)
        XCTAssertEqual(store.status?.kind, .warning)
    }

    // MARK: Get Data ▸ Text/CSV, Power Query, a visual

    func testCSVThroughGetDataAndPowerQueryIntoAVisual() async throws {
        let csvURL = folder.appendingPathComponent("orders.csv")
        try """
            Order,Order Date,Region,Product,Units,Unit Price
            1,2025-01-05,North,Widget,3,2.50
            2,2025-01-06,South,Gadget,1,10.00
            3,2025-01-06,North,"Gizmo, large",2,7.25
            4,2025-02-10,East,Widget,5,2.50
            5,2025-02-11,South,Widget,,2.50
            6,2025-02-12,West,Gadget,4,10.00
            7,2025-03-01,North,Gadget,2,10.00
            8,2025-03-02,East,"Gizmo, large",1,7.25

            """.write(to: csvURL, atomically: true, encoding: .utf8)
        let store = await Smoke.emptyStore()

        // Get Data ▸ Text/CSV ▸ Connect ▸ Load, as the dialog runs it (recent sources kept out of the user's defaults).
        let suite = "DocumentSmokeTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let security = QuerySecurity(defaults: defaults)
        let getData = GetDataSession(store: store, security: security)
        getData.choose(try XCTUnwrap(DataConnector.connector("csv")), location: csvURL.path)
        await getData.connect()
        XCTAssertNil(getData.error)
        XCTAssertEqual(getData.request.delimiter, ",")
        XCTAssertTrue(getData.promoteHeaders, "the first row is taken as headers")
        let loadedFromDialog = await getData.finish(.load)
        XCTAssertTrue(loadedFromDialog, getData.error ?? "")
        let name = "orders"
        XCTAssertEqual(store.doc.queries.map(\.name), [name])
        XCTAssertEqual(store.undoName, "Get Data")
        XCTAssertEqual(store.doc.data[name]?.rowCount, 8)
        XCTAssertEqual(store.doc.data[name]?.column("Product")?.values[2], .string("Gizmo, large"))
        let loadedScript = store.doc.queries[0].mScript
        XCTAssertEqual(MScript.steps(of: loadedScript).map(\.name), ["Source", "Promoted Headers", "Changed Type"])

        // Power Query Editor: four transforms, each applied as a step as its command does.
        let editor = QueryEditorSession(store: store, security: security)
        XCTAssertEqual(editor.selectedQuery?.name, name)
        let transforms: [Transform] = [
            .changeType([("Order", .integer), ("Order Date", .date), ("Units", .integer), ("Unit Price", .decimal)], culture: "en-US"),
            .filterRows(.isNotNull(column: "Units")),
            .addCustomColumn(name: "Revenue", expression: "[Units] * [Unit Price]", type: .decimal),
            .renameColumns([("Region", "Sales Region")]),
        ]
        for transform in transforms { editor.apply(transform) }
        await editor.waitForPreview()
        XCTAssertNil(editor.previewError)
        XCTAssertEqual(editor.preview?.table.rowCount, 7)
        let script = try XCTUnwrap(editor.selectedQuery?.mScript)
        XCTAssertEqual(MScript.steps(of: script).count, 7)
        XCTAssertEqual(store.doc.queries[0].mScript, loadedScript, "nothing reaches the document before Apply")
        XCTAssertTrue(editor.hasPendingChanges)

        // Close & Apply: write the queries and refresh through the Power Query service into the model.
        store.status = nil
        editor.applyChanges()
        XCTAssertEqual(store.doc.queries[0].mScript, script)
        let finished = await Smoke.wait { store.status != nil }
        XCTAssertTrue(finished, "the refresh did not finish")
        XCTAssertEqual(store.status?.kind, .success, store.status?.text ?? "")
        XCTAssertEqual(store.status?.text, "Refreshed 1 table.")
        await Smoke.settle(store)
        XCTAssertNil(store.refreshProgress, "the refresh progress stays up after the refresh")
        let loaded = try XCTUnwrap(store.doc.data[name])
        XCTAssertEqual(loaded.rowCount, 7, "the blank-units row is filtered out")
        XCTAssertEqual(loaded.columnNames, ["Order", "Order Date", "Sales Region", "Product", "Units", "Unit Price", "Revenue"])
        let modelTable = try XCTUnwrap(store.model.table(name))
        XCTAssertEqual(modelTable.column("Order Date")?.dataType, .date)
        XCTAssertEqual(modelTable.column("Revenue")?.dataType, .decimal)
        XCTAssertNil(modelTable.column("Region"), "the renamed column is gone from the model")
        await Smoke.settle(store)
        XCTAssertEqual(store.modelErrors, [:])

        // Into a visual: Revenue by region, hand-computed from the file:
        // North 3×2.50 + 2×7.25 + 2×10 = 42; South 1×10 = 10 (order 5 has no units); East 5×2.50 + 1×7.25 = 19.75; West 4×10 = 40.
        let chart = Smoke.addVisual(.clusteredColumn, [(.category, .column(name, "Sales Region")), (.values, .column(name, "Revenue"))], to: store)
        let card = Smoke.addVisual(.card, [(.values, .column(name, "Revenue"))], to: store)
        await Smoke.settle(store)
        XCTAssertEqual(store.visual(chart)?.fields(.values).first?.aggregation, .sum)
        assertSameSeries(Smoke.series(store, chart, labels: .category), ["North": 42, "South": 10, "East": 19.75, "West": 40], "revenue by region")
        XCTAssertEqual(Smoke.card(store, card), 111.75, accuracy: 1e-9)
        let spec = try XCTUnwrap(store.visual(chart))
        let drawn = await Smoke.bitmap(VisualView(spec: spec, data: store.visualData[chart] ?? VisualData(), context: store.context(for: spec, interactive: false)),
                                       size: CGSize(width: spec.frame.width, height: spec.frame.height))
        XCTAssertGreaterThan(drawn.map { Smoke.ink($0).share } ?? 0, 0.01)
    }
}
