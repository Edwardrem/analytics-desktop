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

    // MARK: Links and paths that leave the project folder

    /// A folder beside the project holding files that a save must never touch.
    private func outsideFolder() throws -> (URL, [String: Data]) {
        let outside = dir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let files = ["keep.txt": Data("keep".utf8), "notes.json": Data("{\"a\":1}".utf8)]
        for (name, data) in files { try data.write(to: outside.appendingPathComponent(name)) }
        return (outside, files)
    }

    private func contents(of folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            out[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return out
    }

    func testSavingThroughALinkedFolderLeavesTheLinkTargetUntouched() throws {
        let fm = FileManager.default
        let (outside, original) = try outsideFolder()
        for linked in ["Sales.Report/StaticResources/RegisteredResources", "Sales.SemanticModel/definition", "Sales.SemanticModel/.pbi"] {
            let project = dir.appendingPathComponent("Project-\(UUID().uuidString)")
            try PBIPProject.write(document: document(), to: project, name: "Sales")
            let link = project.appendingPathComponent(linked)
            if fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)

            XCTAssertThrowsError(try PBIPProject.write(document: document(), to: project, name: "Sales",
                                                       options: .init(includeFacetDataCache: true)), linked) { error in
                XCTAssertTrue(error.localizedDescription.contains("symbolic link"), error.localizedDescription)
            }
            XCTAssertEqual(try contents(of: outside), original, "a save through \(linked) changed the folder it points to")
        }
    }

    func testPruningNeverFollowsOrDeletesLinks() throws {
        let fm = FileManager.default
        let (outside, original) = try outsideFolder()
        let project = dir.appendingPathComponent("Project")
        let base = project.appendingPathComponent("Sales.Report/definition")
        try fm.createDirectory(at: base.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: base.appendingPathComponent("pages/stale.json"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("pages/linked"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: base.appendingPathComponent("keep.txt"), withDestinationURL: outside.appendingPathComponent("keep.txt"))
        let root = try XCTUnwrap(ProjectPaths.realPath(project))

        PBIPProject.prune("Sales.Report/definition", keeping: [], in: project, root: root)
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("pages/stale.json").path), "stale generated files still go")
        XCTAssertTrue(ProjectPaths.isSymbolicLink(base.appendingPathComponent("pages/linked")))
        XCTAssertTrue(ProjectPaths.isSymbolicLink(base.appendingPathComponent("keep.txt")))
        XCTAssertEqual(try contents(of: outside), original)

        // A managed folder that is itself a link is never walked.
        let other = dir.appendingPathComponent("Other")
        try fm.createDirectory(at: other.appendingPathComponent("Sales.Report"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: other.appendingPathComponent("Sales.Report/definition"), withDestinationURL: outside)
        PBIPProject.prune("Sales.Report/definition", keeping: [], in: other, root: try XCTUnwrap(ProjectPaths.realPath(other)))
        XCTAssertEqual(try contents(of: outside), original)
    }

    func testAProjectFolderReachedThroughALinkStillSaves() throws {
        let real = dir.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertNoThrow(try PBIPProject.write(document: document(), to: alias, name: "Sales"))
        XCTAssertNoThrow(try PBIPProject.write(document: document(), to: alias, name: "Sales"), "saving again over the same project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("Sales.pbip").path))
        XCTAssertEqual(try PBIPProject.read(from: alias.appendingPathComponent("Sales.pbip")).0.model.tables.map(\.name), ["Sales"])
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
