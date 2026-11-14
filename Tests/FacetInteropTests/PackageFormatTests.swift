import XCTest
import FacetCore
@testable import FacetInterop

/// .pbit export/import, .pbix import and its stated limit, the query stream, .pbids, and zipped documents.
final class PackageFormatTests: XCTestCase {
    private func utf16(_ object: Any) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return try XCTUnwrap(text.data(using: .utf16LittleEndian))
    }

    private func salesDocument() -> FacetDocument {
        var doc = FacetDocument()
        doc.model.name = "Sales"
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal),
                         ModelColumn(name: "CustomerID", dataType: .integer),
                         ModelColumn(name: "Double", dataType: .decimal, expression: "Sales[Amount] * 2")]
        var total = Measure(name: "Total", expression: "SUM ( Sales[Amount] )", formatString: "#,0.00")
        total.displayFolder = "Totals"
        sales.measures = [total]
        sales.sourceQuery = "Sales"
        var customers = ModelTable(name: "Customers")
        customers.columns = [ModelColumn(name: "CustomerID", dataType: .integer), ModelColumn(name: "Name", dataType: .text)]
        customers.sourceQuery = "Customers"
        doc.model.tables = [sales, customers]
        var rel = Relationship(fromTable: "Sales", fromColumn: "CustomerID", toTable: "Customers", toColumn: "CustomerID")
        rel.crossFilter = .both
        doc.model.relationships = [rel]
        doc.queries = [QueryDefinition(name: "Sales", mScript: "let\n    Source = Csv.Document(File.Contents(BasePath & \"sales.csv\"))\nin\n    Source"),
                       QueryDefinition(name: "Customers", mScript: "let\n    Source = Sql.Database(\"srv\", \"db\")\nin\n    Source"),
                       QueryDefinition(name: "BasePath", mScript: "\"/data/\"")]

        var page = Page(name: "Overview")
        var chart = VisualSpec(type: .clusteredColumn, frame: Frame(x: 20, y: 30, width: 400, height: 300))
        chart.zIndex = 3
        chart.wells[Well.category.rawValue] = [.column("Sales", "Region")]
        chart.wells[Well.values.rawValue] = [.measure("Sales", "Total"), .column("Sales", "Amount", .sum)]
        chart.wells[Well.legend.rawValue] = [.column("Customers", "Name")]
        chart.sort = [SortSpec(field: .measure("Sales", "Total"), descending: true)]
        var matrix = VisualSpec(type: .matrix, frame: Frame(x: 440, y: 30, width: 500, height: 300))
        matrix.wells[Well.rows.rawValue] = [.column("Sales", "Region")]
        matrix.wells[Well.columns.rawValue] = [.column("Customers", "Name")]
        matrix.wells[Well.values.rawValue] = [.column("Sales", "Amount", .average)]
        page.visuals = [chart, matrix]
        var second = Page(name: "Detail")
        second.size = PageSize(width: 1920, height: 1080)
        doc.report.pages = [page, second]
        doc.report.settings.sensitivityLabel = "Confidential"
        return doc
    }

    // MARK: .pbit

    func testTemplateRoundTripKeepsModelQueriesAndVisualWells() throws {
        let url = Fixtures.tempDir("pbit").appendingPathComponent("Sales.pbit")
        let original = salesDocument()
        try PBIXPackage.writeTemplate(original, to: url)

        // The package has the streams Power BI Desktop expects, with UTF-16LE text and no data model.
        let zip = try ZipArchive(url: url)
        XCTAssertEqual(Set(zip.entries.map(\.path)), ["Version", "[Content_Types].xml", "DataModelSchema", "Report/Layout", "Settings", "Metadata"])
        XCTAssertEqual(String(data: try zip.data(named: "Version"), encoding: .utf16LittleEndian), "1.28")
        let schema = try zip.data(named: "DataModelSchema")
        XCTAssertEqual(Array(schema.prefix(4)), [0x7B, 0x00, 0x22, 0x00], "DataModelSchema is UTF-16LE JSON without a byte-order mark")
        XCTAssertFalse(zip.contains("DataModel"), "a template carries no data")

        let (doc, warnings) = try PBIXPackage.read(from: url)
        XCTAssertEqual(doc.model.name, "Sales")
        XCTAssertEqual(doc.model.tables.map(\.name), ["Sales", "Customers"])
        let sales = try XCTUnwrap(doc.model.tables.first)
        XCTAssertEqual(sales.columns.map(\.name), ["Region", "Amount", "CustomerID", "Double"])
        XCTAssertEqual(sales.columns.map(\.dataType), [.text, .decimal, .integer, .decimal])
        XCTAssertEqual(sales.columns.last?.expression, "Sales[Amount] * 2")
        XCTAssertEqual(sales.columns[1].summarizeBy, .sum)
        XCTAssertEqual(sales.measures.first?.expression, "SUM ( Sales[Amount] )")
        XCTAssertEqual(sales.measures.first?.formatString, "#,0.00")
        XCTAssertEqual(sales.measures.first?.displayFolder, "Totals")
        XCTAssertEqual(sales.sourceQuery, "Sales")
        let rel = try XCTUnwrap(doc.model.relationships.first)
        XCTAssertEqual([rel.fromTable, rel.fromColumn, rel.toTable, rel.toColumn], ["Sales", "CustomerID", "Customers", "CustomerID"])
        XCTAssertEqual(rel.crossFilter, .both)
        XCTAssertEqual(Set(doc.queries.map(\.name)), ["Sales", "Customers", "BasePath"])
        XCTAssertEqual(doc.queries.first { $0.name == "BasePath" }?.mScript, "\"/data/\"")
        XCTAssertEqual(doc.queries.first { $0.name == "Customers" }?.mScript, original.queries[1].mScript)

        XCTAssertEqual(doc.report.pages.map(\.name), ["Overview", "Detail"])
        XCTAssertEqual(doc.report.pages[1].size.width, 1920)
        let chart = try XCTUnwrap(doc.report.pages.first?.visuals.first)
        XCTAssertEqual(chart.type, .clusteredColumn)
        XCTAssertEqual(chart.frame, Frame(x: 20, y: 30, width: 400, height: 300))
        XCTAssertEqual(chart.zIndex, 3)
        XCTAssertEqual(chart.fields(.category).map(\.name), ["Region"])
        XCTAssertEqual(chart.fields(.values).map(\.name), ["Total", "Amount"])
        XCTAssertEqual(chart.fields(.values).map(\.kind), [.measure, .column])
        XCTAssertEqual(chart.fields(.values).last?.aggregation, .sum)
        XCTAssertEqual(chart.fields(.legend).map { "\($0.table).\($0.name)" }, ["Customers.Name"])
        XCTAssertEqual(chart.sort.first?.field.name, "Total")
        XCTAssertEqual(chart.sort.first?.descending, true)
        let matrix = try XCTUnwrap(doc.report.pages.first?.visuals.last)
        XCTAssertEqual(matrix.fields(.rows).map(\.name), ["Region"])
        XCTAssertEqual(matrix.fields(.columns).map(\.name), ["Name"])
        XCTAssertEqual(matrix.fields(.values).first?.aggregation, .average)

        XCTAssertTrue(warnings.contains { $0.message.contains("no data") })
        XCTAssertFalse(warnings.contains { $0.message == PBIXPackage.dataModelLimitNote })
        // The sensitivity label travels with the export.
        XCTAssertEqual(PBIXPackage.sensitivityLabel(in: url), "Confidential")
    }

    /// A layout the way Power BI Desktop writes it: projections keyed by data role, filters as a bare array.
    private func desktopLayout() -> [String: Any] {
        let select: [[String: Any]] = [
            ["Column": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Region"], "Name": "Sales.Region"],
            ["Aggregation": ["Expression": ["Column": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Amount"]], "Function": 0], "Name": "Sum(Sales.Amount)"],
            ["Column": ["Expression": ["SourceRef": ["Source": "c"]], "Property": "Name"], "Name": "Customers.Name"]]
        let config: [String: Any] = ["name": "abc", "singleVisual": [
            "visualType": "clusteredColumnChart",
            // Deliberately not in well order: only the role names can place these correctly.
            "projections": ["Series": [["queryRef": "Customers.Name"]], "Y": [["queryRef": "Sum(Sales.Amount)"]], "Category": [["queryRef": "Sales.Region"]]],
            "prototypeQuery": ["Version": 2, "From": [["Name": "s", "Entity": "Sales", "Type": 0], ["Name": "c", "Entity": "Customers", "Type": 0]], "Select": select]]]
        let configText = String(decoding: (try? JSONSerialization.data(withJSONObject: config)) ?? Data(), as: UTF8.self)
        return ["id": 0, "sections": [["name": "ReportSection", "displayName": "Page 1", "width": 1280, "height": 720, "filters": "[]",
                                        "visualContainers": [["x": 10, "y": 20, "z": 1, "width": 300, "height": 200, "config": configText, "filters": "[]"]]]]]
    }

    private func dataMashup(section: String) throws -> Data {
        let package = try ZipWriter.archive([("Config/Package.xml", Data("<Package/>".utf8)), ("Formulas/Section1.m", Data(section.utf8))])
        var out = Data([0, 0, 0, 0])
        withUnsafeBytes(of: UInt32(package.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(package)
        out.append(Data([0, 0, 0, 0]))   // empty permissions
        return out
    }

    func testPbixBringsPagesAndQueriesAndStatesTheDataModelLimit() throws {
        let section = """
        section Section1;

        shared Sales = let
            Source = Csv.Document(File.Contents("C:\\data\\sales;2024.csv"), [Delimiter = ";"]),
            Typed = Table.TransformColumnTypes(Source, {{"Amount", type number}})
        in
            Typed;

        [ Description = "Folder with the ""raw"" files" ]
        shared #"Base Path" = "C:\\data\\" meta [IsParameterQuery = true];

        // a comment with a ; in it
        shared Helper = (x) => x + 1;
        """
        let pbix = try ZipWriter.archive([
            ("Version", try XCTUnwrap("1.28".data(using: .utf16LittleEndian))),
            ("Report/Layout", try utf16(desktopLayout())),
            ("DataMashup", try dataMashup(section: section)),
            ("DataModel", Data(repeating: 0xAB, count: 4096)),   // opaque: stands in for the XPress9 VertiPaq stream
        ])
        let (doc, warnings) = try PBIXPackage.read(data: pbix, name: "Sales")

        let visual = try XCTUnwrap(doc.report.pages.first?.visuals.first)
        XCTAssertEqual(doc.report.pages.first?.name, "Page 1")
        XCTAssertEqual(visual.type, .clusteredColumn)
        XCTAssertEqual(visual.fields(.category).map(\.name), ["Region"])
        XCTAssertEqual(visual.fields(.values).map(\.name), ["Amount"])
        XCTAssertEqual(visual.fields(.values).first?.aggregation, .sum)
        XCTAssertEqual(visual.fields(.legend).map(\.table), ["Customers"])

        XCTAssertEqual(doc.queries.map(\.name), ["Sales", "Base Path", "Helper"])
        XCTAssertTrue(doc.queries[0].mScript.hasPrefix("let"))
        XCTAssertTrue(doc.queries[0].mScript.contains("sales;2024.csv"), "a semicolon inside a string does not end the query")
        XCTAssertTrue(doc.queries[0].mScript.hasSuffix("Typed"))
        XCTAssertEqual(doc.queries[1].mScript, "\"C:\\data\\\" meta [IsParameterQuery = true]")
        XCTAssertEqual(doc.queries[1].description, "Folder with the \"raw\" files")
        XCTAssertEqual(doc.queries[2].mScript, "(x) => x + 1")

        // The limit is stated, and nothing is invented for the part that can't be read.
        XCTAssertTrue(warnings.contains { $0.message == PBIXPackage.dataModelLimitNote && $0.severity == .warning })
        XCTAssertTrue(PBIXPackage.dataModelLimitNote.contains("data, measures and relationships were not"))
        XCTAssertTrue(doc.model.tables.isEmpty)
        XCTAssertTrue(doc.data.tables.isEmpty)
    }

    func testPackagesThatAreNotReportsOrAreHostileAreRefused() throws {
        XCTAssertThrowsError(try PBIXPackage.read(data: Data("not a zip at all, just text".utf8), name: "x")) {
            XCTAssertEqual($0 as? ZipError, .notAZip)
        }
        let empty = try ZipWriter.archive([("readme.txt", Data("hello".utf8))])
        XCTAssertThrowsError(try PBIXPackage.read(data: empty, name: "x")) { error in
            guard case InteropError.invalidFormat = error else { return XCTFail("unexpected \(error)") }
        }
        // More entries than any report holds.
        var tight = ZipArchive.Limits()
        tight.maxEntryCount = 3
        let many = try ZipWriter.archive((0..<4).map { ("f\($0).txt", Data([UInt8($0)])) })
        XCTAssertThrowsError(try ZipArchive(data: many, limits: tight)) { XCTAssertEqual($0 as? ZipError, .tooLarge("4 entries")) }
        XCTAssertEqual(ZipArchive.Limits().maxEntryCount, 100_000)
        XCTAssertEqual(PBIXPackage.limits.maxEntryCount, 20_000)
        // A query stream whose declared length runs past the end.
        XCTAssertThrowsError(try DataMashup.queries(from: Data([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F, 1, 2, 3])))
        XCTAssertThrowsError(try DataMashup.queries(from: Data([1, 0, 0, 0, 0, 0, 0, 0])))
    }

    // MARK: .pbids

    func testPbidsConnectionsBecomeQueries() throws {
        let text = """
        {"version":"0.1","connections":[
          {"details":{"protocol":"tds","address":{"server":"sql.contoso.com","database":"Sales \\"EU\\""}},"options":{},"mode":"DirectQuery"},
          {"details":{"protocol":"file","address":{"path":"/Users/me/Budget 2024.xlsx"}},"mode":"Import"},
          {"details":{"protocol":"http","address":{"url":"https://example.com/data.csv"}}},
          {"details":{"protocol":"folder","address":{"path":"/data/in"}}},
          {"details":{"protocol":"tds","address":{"server":"onlyserver"}}}
        ]}
        """
        let connections = try PBIDS.parse(Data(text.utf8))
        XCTAssertEqual(connections.count, 5)
        // Quotes inside values are doubled, as M requires, so a value can never break out of its string.
        XCTAssertEqual(connections[0].mScript, "let\n    Source = Sql.Database(\"sql.contoso.com\", \"Sales \"\"EU\"\"\")\nin\n    Source")
        XCTAssertTrue(connections[0].isDirectQuery)
        XCTAssertEqual(connections[0].queryName, "Sales \"EU\"")
        XCTAssertEqual(connections[1].mScript, "let\n    Source = Excel.Workbook(File.Contents(\"/Users/me/Budget 2024.xlsx\"), null, true)\nin\n    Source")
        XCTAssertEqual(connections[1].queryName, "Budget 2024")
        XCTAssertFalse(connections[1].isDirectQuery)
        XCTAssertEqual(connections[2].mScript, "let\n    Source = Web.Contents(\"https://example.com/data.csv\")\nin\n    Source")
        XCTAssertEqual(connections[2].mode, "Import")
        XCTAssertEqual(connections[3].mScript, "let\n    Source = Folder.Files(\"/data/in\")\nin\n    Source")
        XCTAssertEqual(connections[4].mScript, "let\n    Source = Sql.Databases(\"onlyserver\")\nin\n    Source")
    }

    func testPbidsErrorsAreSpecific() {
        func failure(_ text: String) -> String {
            do { _ = try PBIDS.parse(Data(text.utf8)); return "" } catch { return error.localizedDescription }
        }
        XCTAssertTrue(failure("{}").contains("no “connections” list"))
        XCTAssertTrue(failure(#"{"connections":[]}"#).contains("no connections"))
        XCTAssertTrue(failure(#"{"connections":[{"details":{"protocol":"tds","address":{}}}]}"#).contains("missing its “server”"))
        XCTAssertTrue(failure(#"{"connections":[{"details":{"protocol":"sap-hana-sql","address":{"server":"h"}}}]}"#).contains("“sap-hana-sql” protocol"))
        XCTAssertTrue(failure(#"{"connections":[{"details":{}}]}"#).contains("which protocol"))
        let big = "{\"connections\":[" + String(repeating: " ", count: PBIDS.maxFileSize) + "]}"
        XCTAssertTrue(failure(big).contains("too large"))
    }

    /// Data source files and archives are read only from regular files, with a limit: a link to a device, or a pipe,
    /// is refused at once instead of hanging the app or reading without end.
    func testPbidsAndArchivesReadOnlyRegularFiles() throws {
        let dir = Fixtures.tempDir("regular-files")
        let fm = FileManager.default
        let valid = dir.appendingPathComponent("real.pbids")
        try Data(#"{"connections":[{"details":{"protocol":"tds","address":{"server":"sql.contoso.com"}}}]}"#.utf8).write(to: valid)
        let linkToValid = dir.appendingPathComponent("link.pbids")
        try fm.createSymbolicLink(at: linkToValid, withDestinationURL: valid)
        XCTAssertEqual(try PBIDS.read(from: linkToValid).map(\.queryName), ["sql.contoso.com"], "a link to a real file still opens")

        let zero = dir.appendingPathComponent("zero.pbids")
        try fm.createSymbolicLink(atPath: zero.path, withDestinationPath: "/dev/zero")
        let zeroZip = dir.appendingPathComponent("zero.pbix")
        try fm.createSymbolicLink(atPath: zeroZip.path, withDestinationPath: "/dev/zero")
        let fifo = dir.appendingPathComponent("pipe.pbids")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let fifoZip = dir.appendingPathComponent("pipe.facet")
        XCTAssertEqual(mkfifo(fifoZip.path, 0o600), 0)
        let big = dir.appendingPathComponent("big.pbids")
        try Data(repeating: 0x20, count: PBIDS.maxFileSize + 1).write(to: big)

        @Sendable func check() {
            XCTAssertThrowsError(try PBIDS.read(from: zero), "a link to /dev/zero")
            XCTAssertThrowsError(try PBIDS.read(from: fifo), "a pipe")
            XCTAssertThrowsError(try PBIDS.read(from: big)) { XCTAssertTrue($0.localizedDescription.contains("too large"), $0.localizedDescription) }
            XCTAssertThrowsError(try ZipArchive(url: zeroZip), "a link to /dev/zero as a .pbix")
            XCTAssertThrowsError(try ZipArchive(url: fifoZip), "a pipe as a zipped document")
            XCTAssertFalse(FacetArchive.isArchive(fifoZip), "a pipe is never opened")
        }
        // Off the test thread, so a read that blocks fails the test instead of hanging the run.
        let done = expectation(description: "every read returns")
        DispatchQueue.global().async { check(); done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    // MARK: Zipped documents

    func testDocumentArchiveRoundTripAndRejections() throws {
        let dir = Fixtures.tempDir("archive")
        let package = dir.appendingPathComponent("Sales.facet")
        var doc = salesDocument()
        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Region", "Amount"], rows: [[.string("EU"), .double(12.5)]])
        try DocumentPackage.write(doc, to: package)
        XCTAssertFalse(FacetArchive.isArchive(package), "a package folder is not an archive")

        let zipped = dir.appendingPathComponent("upload.facet")
        try FacetArchive.pack(package: package, to: zipped)
        XCTAssertTrue(FacetArchive.isArchive(zipped))

        let restored = dir.appendingPathComponent("restored/Sales.facet")
        try FileManager.default.createDirectory(at: restored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FacetArchive.unpack(zipped, to: restored)
        let back = try DocumentPackage.read(from: restored)
        XCTAssertEqual(back.model.tables.map(\.name), ["Sales", "Customers"])
        XCTAssertEqual(back.report.pages.map(\.name), ["Overview", "Detail"])
        XCTAssertEqual(back.data["Sales"]?.rows.first?.last, .double(12.5))

        // An archive that is not a document, and one that tries to write outside the package.
        let other = dir.appendingPathComponent("other.facet")
        try ZipWriter.archive([("hello.txt", Data("x".utf8))]).write(to: other)
        XCTAssertThrowsError(try FacetArchive.unpack(other, to: dir.appendingPathComponent("o.facet")))
        XCTAssertNil(ZipArchive.sanitizedPath("../../Library/LaunchAgents/x.plist"))
        XCTAssertNil(ZipArchive.sanitizedPath("/etc/passwd"))
        XCTAssertNil(ZipArchive.sanitizedPath("a/../../b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("o.facet").path))
        // Nothing is left behind by a refused unpack.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".unpack-") }
        XCTAssertEqual(leftovers, [])
    }
}
