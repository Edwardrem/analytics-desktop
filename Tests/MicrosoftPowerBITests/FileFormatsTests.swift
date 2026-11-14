import XCTest
import FacetCore
import FacetInterop
@testable import MicrosoftPowerBI

/// Power BI formats through File ▸ Open and Save: projects (with reload on external edits), templates, reports,
/// data source files, TMDL and themes.
@MainActor
final class FileFormatsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        Features.registerAll()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func document() -> FacetDocument {
        var doc = FacetDocument()
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal)]
        sales.measures = [Measure(name: "Total", expression: "SUM ( Sales[Amount] )", formatString: "#,0")]
        sales.sourceQuery = "Sales"
        doc.model.tables = [sales]
        doc.queries = [QueryDefinition(name: "Sales", mScript: "let\n    Source = Csv.Document(File.Contents(\"/data/sales.csv\"))\nin\n    Source")]
        var page = Page(name: "Overview")
        var chart = VisualSpec(type: .clusteredColumn, frame: Frame(x: 10, y: 10, width: 300, height: 200))
        chart.wells[Well.category.rawValue] = [.column("Sales", "Region")]
        chart.wells[Well.values.rawValue] = [.measure("Sales", "Total")]
        page.visuals = [chart]
        doc.report.pages = [page, Page(name: "Detail")]
        return doc
    }

    private func store(_ doc: FacetDocument = FacetDocument()) -> DocumentStore { DocumentStore(document: doc, services: .live()) }

    // MARK: Projects

    func testSavingAsAProjectWritesPBIRAndTMDLAndKeepsSavingThere() throws {
        let s = store(document())
        let pbip = dir.appendingPathComponent("Sales.pbip")
        XCTAssertTrue(FileOperations.write(s, to: pbip))
        for path in ["Sales.pbip", "Sales.Report/definition.pbir", "Sales.Report/definition/report.json",
                     "Sales.SemanticModel/definition.pbism", "Sales.SemanticModel/definition/tables/Sales.tmdl"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(s.fileURL, pbip)
        XCTAssertEqual(s.displayName, "Sales")
        XCTAssertEqual(DocumentFiles.of(s).watchedProject, pbip, "a project on disk is watched for edits elsewhere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sales.facet").path), "no .facet package is written")

        // Opening the project — by its .pbip or its folder — saves back to the same .pbip.
        XCTAssertEqual(FileOperations.documentURL(for: dir), pbip)
        XCTAssertEqual(FileOperations.documentURL(for: pbip), pbip)
        let reopened = store()
        FileOperations.open(dir, into: reopened)
        XCTAssertEqual(reopened.fileURL, pbip)
        XCTAssertEqual(reopened.model.measure("Total")?.measure.formatString, "#,0")
        XCTAssertEqual(reopened.report.pages.map(\.name), ["Overview", "Detail"])
        XCTAssertEqual(reopened.report.pages.first?.visuals.first?.fields(.values).map { "\($0.kind) \($0.table) \($0.name)" }, ["measure Sales Total"])
        DocumentFiles.of(s).stopWatching()
        DocumentFiles.of(reopened).stopWatching()
    }

    func testEditsMadeOutsideReloadTheProject() async throws {
        let pbip = dir.appendingPathComponent("Sales.pbip")
        _ = try FileOperations.writeProject(document(), to: pbip)
        let s = store()
        FileOperations.open(pbip, into: s)
        XCTAssertEqual(DocumentFiles.of(s).watchedProject, pbip)
        defer { DocumentFiles.of(s).stopWatching() }

        // Another app (VS Code, git checkout, an agent) adds a measure to the TMDL.
        let tmdl = dir.appendingPathComponent("Sales.SemanticModel/definition/tables/Sales.tmdl")
        var text = try String(contentsOf: tmdl, encoding: .utf8)
        text += "\n\tmeasure Count = COUNTROWS ( Sales )\n"
        try text.write(to: tmdl, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(10)
        while s.model.measure("Count") == nil, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotNil(s.model.measure("Count"), "the external edit was picked up")
        XCTAssertEqual(s.fileURL, pbip)
        XCTAssertFalse(s.isDirty)
    }

    func testOnlyAnUneditedDocumentReloadsWithoutAsking() {
        let changed = [URL(fileURLWithPath: "/p/Sales.Report/definition/report.json")]
        XCTAssertEqual(DocumentFiles.decision(isDirty: false, changed: changed, alreadyAsking: false), .reload)
        XCTAssertEqual(DocumentFiles.decision(isDirty: true, changed: changed, alreadyAsking: false), .ask)
        XCTAssertEqual(DocumentFiles.decision(isDirty: true, changed: changed, alreadyAsking: true), .ignore)
        XCTAssertEqual(DocumentFiles.decision(isDirty: false, changed: [], alreadyAsking: false), .ignore)
    }

    // MARK: Templates, reports, data source files

    func testTemplatesExportWithoutDataAndOpenAsNewDocuments() throws {
        var doc = document()
        doc.data["Sales"] = DataTable(name: "Sales", columns: [DataColumn(name: "Amount", type: .decimal, values: [.double(1)])])
        doc.report.settings.sensitivityLabel = "General"
        let pbit = dir.appendingPathComponent("Sales.pbit")
        try PBIXPackage.writeTemplate(doc, to: pbit)
        let s = store()
        FileOperations.open(pbit, into: s)
        XCTAssertNil(s.fileURL, "a template starts a new, unsaved document")
        XCTAssertEqual(s.model.measure("Total")?.measure.expression, "SUM ( Sales[Amount] )")
        XCTAssertEqual(s.doc.queries.map(\.name), ["Sales"])
        XCTAssertTrue(s.doc.data.tables.isEmpty)
        XCTAssertEqual(s.report.settings.sensitivityLabel, "General", "the label travels with the template")
        XCTAssertEqual(DocumentFiles.of(s).importedFrom, pbit)
        XCTAssertNil(FileOperations.documentURL(for: pbit))
    }

    func testTMDLFoldersOpenAsDocuments() throws {
        let folder = dir.appendingPathComponent("definition")
        for f in TMDL.serialize(model: document().model, queries: document().queries) {
            let url = folder.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.text.write(to: url, atomically: true, encoding: .utf8)
        }
        let result = try TMDLFiles.read(folder)
        XCTAssertEqual(result.document.model.tables.map(\.name), ["Sales"])
        XCTAssertEqual(result.document.model.measure("Total")?.measure.formatString, "#,0")
    }

    // MARK: Themes

    func testThemesRoundTripAsPowerBIThemeFiles() throws {
        var theme = ThemeSpec.facet
        theme.name = "Harbour"
        theme.dataColors = ["#123456", "#ABCDEF", "#FF8800"]
        let url = dir.appendingPathComponent("Harbour.json")
        try ThemeFiles.write(theme, to: url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "Harbour")
        XCTAssertEqual((json?["dataColors"] as? [String])?.map { $0.uppercased() }, ["#123456", "#ABCDEF", "#FF8800"], "readable by Power BI")
        let back = try ThemeFiles.read(url)
        XCTAssertEqual(back.name, "Harbour")
        XCTAssertEqual(back.dataColors.map { $0.uppercased() }, ["#123456", "#ABCDEF", "#FF8800"])

        // A Power BI theme written by hand.
        let pbi = dir.appendingPathComponent("City park.json")
        try Data(##"{"name":"City park","dataColors":["#3A6E00","#6FA300"],"background":"#FFFFFF","foreground":"#252423"}"##.utf8).write(to: pbi)
        XCTAssertEqual(try ThemeFiles.read(pbi).dataColors.map { $0.uppercased() }, ["#3A6E00", "#6FA300"])
        XCTAssertNotNil(ThemeIO.importer, "Import theme uses the Power BI reader")
    }

    // MARK: Lakehouse files and publishing

    func testLakehouseFilesBecomeFileQueries() {
        XCTAssertEqual(LakeFile.mScript(for: URL(fileURLWithPath: "/tmp/a \"b\".parquet")),
                       "let\n    Source = Parquet.Document(File.Contents(\"/tmp/a \"\"b\"\".parquet\"))\nin\n    Source")
        XCTAssertTrue(LakeFile.mScript(for: URL(fileURLWithPath: "/tmp/s.csv"))?.contains("Table.PromoteHeaders") == true)
        XCTAssertNil(LakeFile.mScript(for: URL(fileURLWithPath: "/tmp/model.delta")))
        XCTAssertEqual(LakeFile.queryName(for: URL(fileURLWithPath: "/x/Sales.csv"), existing: ["sales", "Sales (2)"]), "Sales (3)")
    }

    func testPublishSaysWhatWontWorkInTheService() {
        var doc = document()
        doc.model.tables.append(ModelTable(name: "Targets"))
        let plan = PublishPlan.make(for: doc, name: "Sales")
        XCTAssertTrue(plan.modelParts.contains { $0.path == "definition/tables/Sales.tmdl" })
        XCTAssertTrue(plan.reportParts.contains { $0.path == "definition.pbir" })
        XCTAssertTrue(plan.notes.contains { $0.contains("files on this Mac (Sales)") }, "\(plan.notes)")
        XCTAssertTrue(plan.notes.contains { $0.contains("Targets") && $0.contains("arrive empty") }, "\(plan.notes)")
        XCTAssertEqual(PublishPlan.localSourceQueries([QueryDefinition(name: "Web", mScript: "Web.Contents(\"https://x\")")]), [])
    }

    func testFileCommandsAreRegistered() {
        for id in ["file.openRecent", "file.saveAsProject", "file.exportTemplate", "file.openInVSCode"] {
            XCTAssertNotNil(AppCommands.command(id), id)
        }
        let s = store()
        XCTAssertEqual(AppCommands.command("file.openInVSCode")?.isEnabled(s), false)
        s.fileURL = dir.appendingPathComponent("P.pbip")
        XCTAssertEqual(AppCommands.command("file.openInVSCode")?.isEnabled(s), true)
        XCTAssertTrue(FileOperations.openableExtensions.contains("pbids"))
        XCTAssertTrue(FileOperations.openableExtensions.contains("pbit"))
    }
}
