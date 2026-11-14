import XCTest
import FacetCore
@testable import FacetInterop

/// Bounded reads of project files, resource names that stay in their folder, the definition parts a publish sends,
/// and sensitivity labels that travel with templates.
final class ProjectSafetyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("project-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func document() -> FacetDocument {
        var doc = FacetDocument()
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Amount", dataType: .decimal)]
        sales.measures = [Measure(name: "Total", expression: "SUM ( Sales[Amount] )")]
        doc.model.tables = [sales]
        var page = Page(name: "Overview")
        var card = VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 200, height: 120))
        card.wells[Well.values.rawValue] = [.measure("Sales", "Total")]
        page.visuals = [card]
        doc.report.pages = [page]
        doc.data["Sales"] = DataTable(name: "Sales", columns: [DataColumn(name: "Amount", type: .decimal, values: [.double(1)])])
        return doc
    }

    func testBoundedReadsRefuseLargeAndNonRegularFiles() throws {
        let small = dir.appendingPathComponent("a.json")
        try Data("{}".utf8).write(to: small)
        XCTAssertEqual(try BoundedFile.read(small, limit: 2), Data("{}".utf8))
        XCTAssertThrowsError(try BoundedFile.read(small, limit: 1))
        XCTAssertThrowsError(try BoundedFile.read(dir, limit: 100), "a folder is not a file")
        XCTAssertNil(BoundedFile.readIfPresent(dir.appendingPathComponent("missing.json")))
    }

    func testResourceNamesCannotLeaveTheResourcesFolder() throws {
        let resources = dir.appendingPathComponent("StaticResources/RegisteredResources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: dir.appendingPathComponent("secret.txt"))
        try Data("theme".utf8).write(to: resources.appendingPathComponent("Theme.json"))
        XCTAssertEqual(PBIPProject.resource(resources, "Theme.json"), Data("theme".utf8))
        XCTAssertNil(PBIPProject.resource(resources, "../../secret.txt"))
        XCTAssertNil(PBIPProject.resource(resources, ".."))
        XCTAssertFalse(BoundedFile.isSafeResourceName("a/b.json"))
        XCTAssertTrue(BoundedFile.isSafeResourceName("Theme 2.json"))
    }

    func testAnOversizedModelFileIsSkippedWithAWarning() throws {
        let doc = document()
        _ = try PBIPProject.write(document: doc, to: dir, name: "Sales")
        let big = dir.appendingPathComponent("Sales.SemanticModel/definition/tables/Huge.tmdl")
        // A sparse file just over the limit: its size is checked before anything is read.
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(BoundedFile.textLimit + 1))
        try handle.close()
        let (read, warnings) = try PBIPProject.read(from: dir)
        XCTAssertEqual(read.model.tables.map(\.name), ["Sales"])
        XCTAssertTrue(warnings.contains { $0.message.contains("Huge.tmdl") }, "\(warnings)")
    }

    func testDefinitionPartsHoldOnlyWhatTheServiceUses() throws {
        let parts = PBIPProject.definitionParts(for: document(), name: "Sales: Q1")
        let model = Set(parts.model.map(\.path)), report = Set(parts.report.map(\.path))
        XCTAssertTrue(model.contains("definition.pbism"))
        XCTAssertTrue(model.contains("definition/model.tmdl"), "\(model)")
        XCTAssertTrue(model.contains { $0.hasPrefix("definition/tables/") })
        XCTAssertTrue(report.contains("definition.pbir"))
        XCTAssertTrue(report.contains("definition/report.json"))
        XCTAssertTrue(report.contains { $0.hasPrefix("definition/pages/") && $0.hasSuffix("visual.json") })
        XCTAssertTrue(report.contains { $0.hasPrefix("StaticResources/RegisteredResources/") })
        for path in model.union(report) {
            XCTAssertFalse(path.hasPrefix("/") || path.contains("..") || path == ".platform" || path.contains(".pbi/"), path)
        }
        // No table data in a definition, and no note about it either.
        XCTAssertFalse(model.contains { $0.contains("facet-cache") })
        XCTAssertFalse(parts.warnings.contains { $0.message.contains("Table data") })
    }

    func testTemplatesKeepTheirSensitivityLabel() throws {
        var doc = document()
        doc.report.settings.sensitivityLabel = "Highly Confidential"
        let url = dir.appendingPathComponent("Sales.pbit")
        try PBIXPackage.writeTemplate(doc, to: url)
        XCTAssertEqual(PBIXPackage.sensitivityLabel(in: url), "Highly Confidential")
        let (read, _) = try PBIXPackage.read(from: url)
        XCTAssertEqual(read.report.settings.sensitivityLabel, "Highly Confidential")
        XCTAssertTrue(read.data.tables.isEmpty, "a template carries no data")
    }
}
