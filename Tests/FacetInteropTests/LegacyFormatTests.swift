import XCTest
import FacetCore
@testable import FacetInterop

/// Tests for the legacy-format readers: a TMSL `model.bim` and a legacy Layout `report.json`,
/// as written by Power BI Desktop before the TMDL/PBIR project formats.
final class LegacyFormatTests: XCTestCase {
    // MARK: TMSL model.bim

    private func tmsl() throws -> JSONValue {
        try JSONValue.parse("""
        {
          "name": "Contoso",
          "model": {
            "culture": "en-GB",
            "annotations": [{"name": "__PBI_TimeIntelligenceEnabled", "value": "1"}],
            "expressions": [{"name": "BasePath", "kind": "m", "expression": ["let", "    v = \\"/data/\\"", "in", "    v"]}],
            "tables": [
              {
                "name": "Sales",
                "description": "Facts",
                "columns": [
                  {"name": "Amount", "dataType": "double", "formatString": "#,0.00", "summarizeBy": "sum", "sourceColumn": "Amount"},
                  {"name": "Margin %", "type": "calculated", "dataType": "double", "expression": "DIVIDE(Sales[Amount], 2)"},
                  {"name": "RowNumber-1", "type": "rowNumber", "dataType": "int64"}
                ],
                "measures": [{"name": "Total", "expression": "SUM(Sales[Amount])", "formatString": "$#,0",
                              "formatStringDefinition": {"expression": "IF(1 > 0, \\"$#,0\\", \\"0\\")"}, "displayFolder": "KPIs"}],
                "hierarchies": [{"name": "Geo", "levels": [{"name": "Country", "column": "Amount", "ordinal": 0}]}],
                "partitions": [{"name": "Sales", "mode": "directQuery",
                                "source": {"type": "m", "expression": ["let", "    Source = 1", "in", "    Source"]}}]
              },
              {
                "name": "Dates",
                "columns": [{"name": "Date", "dataType": "dateTime", "isKey": true, "sourceColumn": "Date"}],
                "partitions": [{"name": "Dates", "mode": "import", "source": {"type": "calculated", "expression": "CALENDAR(DATE(2020,1,1), DATE(2026,12,31))"}}]
              }
            ],
            "relationships": [{"name": "r1", "fromTable": "Sales", "fromColumn": "Amount", "toTable": "Dates", "toColumn": "Date",
                               "crossFilteringBehavior": "bothDirections", "isActive": true,
                               "securityFilteringBehavior": "bothDirections", "assumeReferentialIntegrity": true}],
            "roles": [{"name": "West", "modelPermission": "read",
                       "tablePermissions": [{"name": "Sales", "filterExpression": "[Amount] > 0",
                                            "columnPermissions": [{"name": "Amount", "metadataPermission": "none"}]}]}],
            "perspectives": [{"name": "Exec", "perspectiveTables": [{"name": "Sales"}],
                              "perspectiveMeasures": [{"table": "Sales", "name": "Total"}]}],
            "calculationGroups": []
          }
        }
        """)
    }

    func testTMSLConvert() throws {
        let result = TMSLConverter.convert(try tmsl())
        let model = result.model
        XCTAssertEqual(model.name, "Contoso")
        XCTAssertEqual(model.culture, "en-GB")
        XCTAssertTrue(model.autoDateTime)
        XCTAssertEqual(model.tables.count, 2)

        let sales = try XCTUnwrap(model.table("Sales"))
        XCTAssertEqual(sales.description, "Facts")
        XCTAssertEqual(sales.storageMode, .directQuery)
        XCTAssertEqual(sales.columns.count, 2)   // the rowNumber column is skipped
        let amount = try XCTUnwrap(sales.column("Amount"))
        XCTAssertEqual(amount.dataType, .decimal)
        XCTAssertEqual(amount.formatString, "#,0.00")
        XCTAssertEqual(amount.summarizeBy, .sum)
        let margin = try XCTUnwrap(sales.column("Margin %"))
        XCTAssertEqual(margin.expression, "DIVIDE(Sales[Amount], 2)")
        let total = try XCTUnwrap(sales.measure("Total"))
        XCTAssertEqual(total.expression, "SUM(Sales[Amount])")
        XCTAssertEqual(total.formatExpression, "IF(1 > 0, \"$#,0\", \"0\")")
        XCTAssertEqual(total.displayFolder, "KPIs")
        XCTAssertEqual(sales.hierarchies.first?.levels, ["Amount"])

        let dates = try XCTUnwrap(model.table("Dates"))
        XCTAssertEqual(dates.expression, "CALENDAR(DATE(2020,1,1), DATE(2026,12,31))")
        XCTAssertEqual(dates.dateColumn, "Date")

        let rel = try XCTUnwrap(model.relationships.first)
        XCTAssertEqual(rel.fromTable, "Sales")
        XCTAssertEqual(rel.toTable, "Dates")
        XCTAssertEqual(rel.crossFilter, .both)
        XCTAssertTrue(rel.isActive)
        XCTAssertTrue(rel.assumeReferentialIntegrity)
        XCTAssertTrue(rel.securityFilterBothDirections)

        let role = try XCTUnwrap(model.roles.first)
        XCTAssertEqual(role.tableFilters["Sales"], "[Amount] > 0")
        XCTAssertEqual(role.hiddenColumns, ["Sales[Amount]"])

        let perspective = try XCTUnwrap(model.perspectives.first)
        XCTAssertEqual(perspective.members, ["Sales", "Sales[Total]"])

        // The shared M expression and the table partition both become queries.
        XCTAssertTrue(result.queries.contains { $0.name == "BasePath" && $0.mScript.contains("/data/") })
        XCTAssertTrue(result.queries.contains { $0.name == "Sales" })
        XCTAssertEqual(sales.sourceQuery, "Sales")
    }

    // MARK: Legacy Layout report.json

    private func jsonText(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func layoutJSON() throws -> JSONValue {
        let filterID = UUID().uuidString
        let filterQuery: [String: Any] = ["Version": 2,
            "From": [["Name": "s", "Entity": "Sales", "Type": 0]],
            "Where": [["Condition": ["In": ["Expressions": [["Column": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Region"]]],
                                             "Values": [[["Literal": ["Value": "'US'"]]]]]]]]]
        let filterEntry: [String: Any] = [
            "expression": ["Column": ["Expression": ["SourceRef": ["Entity": "Sales"]], "Property": "Region"]],
            "filter": filterQuery, "type": "Categorical", "name": filterID]
        let visualFilters: [String: Any] = ["filters": [filterEntry]]
        let select: [[String: Any]] = [
            ["Column": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Region"], "Name": "Sales.Region"],
            ["Measure": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Total"], "Name": "Sales.Total"],
            ["Aggregation": ["Expression": ["Column": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Amount"]], "Function": 0], "Name": "Sales.Amount"]]
        let barConfig: [String: Any] = ["singleVisual": [
            "visualType": "columnChart",
            "projections": [["queryRef": "Sales.Region"], ["queryRef": "Sales.Total"], ["queryRef": "Sales.Amount"]],
            "prototypeQuery": ["Version": 2, "From": [["Name": "s", "Entity": "Sales", "Type": 0]], "Select": select],
            "sortDefinition": ["sort": [["field": ["Column": ["Expression": ["SourceRef": ["Source": "s"]], "Property": "Region"]], "direction": 1]]],
            "objects": ["title": [["properties": ["text": ["expr": ["Literal": ["Value": "'Sales by region'"]]]]]]]]]
        let slicerConfig: [String: Any] = ["singleVisual": ["visualType": "slicer", "projections": [["queryRef": "Sales.Region"]]]]
        let section: [String: Any] = ["name": "ReportSection1", "displayName": "Overview", "width": 1280, "height": 720,
             "filters": jsonText(visualFilters),
             "visualContainers": [
                ["x": 20, "y": 30, "width": 400, "height": 300, "z": 2, "config": jsonText(barConfig),
                 "filters": jsonText(["filters": [filterEntry]])],
                ["x": 440, "y": 30, "width": 200, "height": 120, "config": jsonText(slicerConfig),
                 "filters": jsonText(["filters": [filterEntry]])]]]
        let layout: [String: Any] = ["name": "Report", "sections": [section]]
        return try JSONValue.parse(JSONSerialization.data(withJSONObject: layout))
    }

    func testLegacyLayoutConvert() throws {
        let (report, warnings) = LegacyReportLayout.convert(try layoutJSON(), resource: { _ in nil })
        XCTAssertEqual(report.pages.count, 1)
        let page = try XCTUnwrap(report.pages.first)
        XCTAssertEqual(page.name, "Overview")
        XCTAssertEqual(page.size.width, 1280)
        XCTAssertEqual(page.visuals.count, 2)

        let bar = page.visuals[0]
        XCTAssertEqual(bar.type, .stackedColumn)   // a legacy "columnChart" is a stacked column chart
        XCTAssertEqual(bar.frame, Frame(x: 20, y: 30, width: 400, height: 300))
        XCTAssertEqual(bar.zIndex, 2)
        // Positional well assignment: the category, then the aggregated value wells.
        XCTAssertEqual(bar.fields(.category).first?.name, "Region")
        XCTAssertEqual(bar.fields(.values).count, 2)
        XCTAssertTrue(bar.fields(.values).contains { $0.kind == .measure && $0.name == "Total" })
        XCTAssertEqual(bar.fields(.values).first { $0.name == "Amount" }?.aggregation, .sum)
        XCTAssertEqual(bar.sort.first?.field.name, "Region")
        XCTAssertEqual(bar.sort.first?.descending, false)
        XCTAssertEqual(bar.fmt("title", "text")?.stringValue, "Sales by region")

        // Visual-level and page-level filters are read with their conditions.
        XCTAssertEqual(page.filters.count, 1)
        XCTAssertEqual(bar.filters.count, 1)
        let filter = try XCTUnwrap(bar.filters.first)
        XCTAssertEqual(filter.field.name, "Region")
        XCTAssertEqual(filter.values, ["US"])

        // A slicer's container filter becomes its selection state.
        let slicer = page.visuals[1]
        XCTAssertEqual(slicer.type, .slicer)
        XCTAssertEqual(slicer.slicerState?.selected, ["US"])
        _ = warnings
    }

    func testLegacyRoundTripThroughPBIP() throws {
        // A legacy report.json dropped into a Report folder reads through PBIPProject.read.
        let dir = Fixtures.tempDir("legacy-pbip")
        let reportDir = dir.appendingPathComponent("Sales.Report")
        let definition = reportDir.appendingPathComponent("definition")
        try FileManager.default.createDirectory(at: definition, withIntermediateDirectories: true)
        let (model, _) = Fixtures.richModel()
        let files = TMDL.serialize(model: model)
        for f in files {
            let url = dir.appendingPathComponent("Sales.SemanticModel/definition").appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.text.write(to: url, atomically: true, encoding: .utf8)
        }
        // PBIR's report.json lives inside definition/; a legacy file sits at the report root.
        let legacy = try layoutJSON()
        try legacy.serialized().write(to: reportDir.appendingPathComponent("report.json"), options: .atomic)
        let (doc, _) = try PBIPProject.read(from: dir)
        XCTAssertEqual(doc.report.pages.first?.visuals.count, 2)
        XCTAssertEqual(doc.model.tables.count, model.tables.count)
    }
}
