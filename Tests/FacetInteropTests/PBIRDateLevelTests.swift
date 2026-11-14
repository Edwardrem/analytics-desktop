import XCTest
import FacetCore
@testable import FacetInterop

/// Date levels (Year, Quarter, Month, Day of a column's auto date/time hierarchy) in PBIR: written as Power BI writes
/// them, a `HierarchyLevel` of the column's "Date Hierarchy" reached through its "Variation", and read back as the level.
final class PBIRDateLevelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pbir-date-level-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// The projection Power BI Desktop saves for Sales[Order Date] › Year in a visual.json.
    private let powerBIYear = #"""
    {"field":{"HierarchyLevel":{"Expression":{"Hierarchy":{"Expression":{"PropertyVariationSource":{
        "Expression":{"SourceRef":{"Entity":"Sales"}},"Name":"Variation","Property":"Order Date"}},
        "Hierarchy":"Date Hierarchy"}},"Level":"Year"}},
     "queryRef":"Sales.Order Date.Variation.Date Hierarchy.Year","nativeQueryRef":"Order Date Year","active":true}
    """#

    func testADateLevelIsWrittenAsAHierarchyLevelOfTheColumnsVariation() throws {
        let field = PBIExpr.field(.dateLevel("Sales", "Order Date", "Month"))
        let expected = try JSONValue.parse(Data(#"""
        {"HierarchyLevel":{"Expression":{"Hierarchy":{"Expression":{"PropertyVariationSource":{
            "Expression":{"SourceRef":{"Entity":"Sales"}},"Name":"Variation","Property":"Order Date"}},
            "Hierarchy":"Date Hierarchy"}},"Level":"Month"}}
        """#.utf8))
        XCTAssertEqual(field, expected)
        XCTAssertEqual(PBIExpr.queryRef(.dateLevel("Sales", "Order Date", "Month")), "Sales.Order Date.Variation.Date Hierarchy.Month")
        XCTAssertEqual(PBIExpr.nativeQueryRef(.dateLevel("Sales", "Order Date", "Month")), "Order Date Month")
        // The column itself is still a plain Column.
        XCTAssertEqual(PBIExpr.field(.column("Sales", "Order Date")),
                       try JSONValue.parse(Data(#"{"Column":{"Expression":{"SourceRef":{"Entity":"Sales"}},"Property":"Order Date"}}"#.utf8)))
    }

    func testAPowerBIProjectionReadsAsTheDateLevelNotACaption() throws {
        let projection = try JSONValue.parse(Data(powerBIYear.utf8))
        let f = try XCTUnwrap(PBIExpr.parseField(projection["field"]))
        XCTAssertEqual(f.kind, .column)
        XCTAssertEqual(f.table, "Sales")
        XCTAssertEqual(f.name, "Order Date")
        XCTAssertEqual(f.dateLevel, "Year")
        XCTAssertNil(f.displayName, "the level is the field, not a renamed caption")
        XCTAssertEqual(f.daxReference, "'Sales'[Order Date].[Year]")
        // Inside a query the column comes from a source alias.
        let text = try XCTUnwrap(projection["field"]?.compactString)
        let aliased = try JSONValue.parse(Data(text.replacingOccurrences(of: #"{"Entity":"Sales"}"#, with: #"{"Source":"s"}"#).utf8))
        XCTAssertNotEqual(text, aliased.compactString, "the source was replaced by an alias")
        XCTAssertEqual(PBIExpr.parseField(aliased, aliases: ["s": "Sales"])?.dateLevel, "Year")
        XCTAssertEqual(PBIExpr.parseField(aliased, aliases: ["s": "Sales"])?.table, "Sales")
    }

    private func document() -> FacetDocument {
        var doc = FacetDocument()
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Order Date", dataType: .date), ModelColumn(name: "Amount", dataType: .decimal)]
        doc.model.tables = [sales]
        doc.model.autoDateTime = true
        var page = Page(name: "Trend")
        var chart = VisualSpec(type: .clusteredColumn, frame: Frame(x: 10, y: 20, width: 400, height: 260))
        chart.setFields(.category, [.dateLevel("Sales", "Order Date", "Year"), .dateLevel("Sales", "Order Date", "Quarter"),
                                    .dateLevel("Sales", "Order Date", "Month")])
        chart.setFields(.values, [.column("Sales", "Amount", .sum)])
        chart.sort = [SortSpec(field: .dateLevel("Sales", "Order Date", "Month"), descending: false)]
        var year = FilterSpec(field: .dateLevel("Sales", "Order Date", "Year"))
        year.values = [.int(2024), .int(2025)]
        chart.filters = [year]
        page.visuals = [chart]
        doc.report.pages = [page]
        return doc
    }

    private func checkLevels(_ v: VisualSpec?, file: StaticString = #filePath, line: UInt = #line) {
        let category = v?.fields(.category) ?? []
        XCTAssertEqual(category.map(\.name), ["Order Date", "Order Date", "Order Date"], file: file, line: line)
        XCTAssertEqual(category.map(\.dateLevel), ["Year", "Quarter", "Month"], file: file, line: line)
        XCTAssertEqual(category.map(\.displayName), [nil, nil, nil], file: file, line: line)
        XCTAssertEqual(v?.fields(.values).map(\.key), [FieldRef.column("Sales", "Amount", .sum).key], file: file, line: line)
        XCTAssertEqual(v?.sort.first?.field.dateLevel, "Month", file: file, line: line)
        XCTAssertEqual(v?.sort.first?.descending, false, file: file, line: line)
        XCTAssertEqual(v?.filters.first?.field.dateLevel, "Year", file: file, line: line)
        XCTAssertEqual(v?.filters.first?.values, [.int(2024), .int(2025)], file: file, line: line)
    }

    func testAPurePowerBIProjectKeepsDateLevelsThroughARoundTrip() throws {
        // Without Facet annotations everything comes from the native PBIR JSON.
        try PBIPProject.write(document: document(), to: dir, name: "Trend", options: .init(includeFacetAnnotations: false))
        let visualFiles = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "visual.json" })
        XCTAssertEqual(visualFiles.count, 1)
        let text = try String(contentsOf: try XCTUnwrap(visualFiles.first), encoding: .utf8)
        XCTAssertTrue(text.contains("\"PropertyVariationSource\""), text)
        XCTAssertTrue(text.contains("Sales.Order Date.Variation.Date Hierarchy.Quarter"), text)
        XCTAssertFalse(text.contains("Facet_visual"))

        let (read, _) = try PBIPProject.read(from: dir)
        checkLevels(read.report.pages.first?.visuals.first)
    }

    func testAnExternallyEditedQueryStateStillReadsDateLevels() throws {
        // With annotations, a queryState that no longer matches the saved visual is re-read from the JSON.
        try PBIPProject.write(document: document(), to: dir, name: "Trend")
        let file = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "visual.json" })
        var visual = try JSONValue.parse(Data(contentsOf: file))
        // Power BI drops the Quarter level from the axis.
        guard case .object(var root) = visual, case .object(var v) = root["visual"], case .object(var q) = v["query"],
              case .object(var state) = q["queryState"], case .object(var category) = state["Category"],
              var projections = category["projections"]?.arrayValue else { return XCTFail("unexpected visual.json shape") }
        projections.remove(at: 1)
        category["projections"] = .array(projections)
        state["Category"] = .object(category); q["queryState"] = .object(state); v["query"] = .object(q); root["visual"] = .object(v)
        visual = .object(root)
        try visual.serialized().write(to: file)

        let (read, _) = try PBIPProject.read(from: dir)
        let category2 = read.report.pages.first?.visuals.first?.fields(.category) ?? []
        XCTAssertEqual(category2.map(\.dateLevel), ["Year", "Month"])
        XCTAssertEqual(category2.map(\.name), ["Order Date", "Order Date"])
    }

    func testALegacyLayoutRoundTripKeepsDateLevels() throws {
        // .pbit/.pbix Layout uses the same field expressions in its prototype query.
        let (report, _) = LegacyReportLayout.convert(LegacyLayoutWriter.layout(document().report), resource: { _ in nil })
        checkLevels(report.pages.first?.visuals.first)
    }

    func testALegacyQueryRefWithoutAPrototypeQueryStillNamesTheLevel() throws {
        let config = #"{"singleVisual":{"visualType":"clusteredColumnChart","projections":{"Category":[{"queryRef":"Sales.Order Date.Variation.Date Hierarchy.Quarter"}]}}}"#
        let layout = jo(["sections": ja([jo(["displayName": js("P"), "visualContainers": ja([jo(["config": js(config)])])])])])
        let (report, _) = LegacyReportLayout.convert(layout, resource: { _ in nil })
        let f = report.pages.first?.visuals.first?.fields(.category).first
        XCTAssertEqual(f?.table, "Sales")
        XCTAssertEqual(f?.name, "Order Date")
        XCTAssertEqual(f?.dateLevel, "Quarter")
    }
}
