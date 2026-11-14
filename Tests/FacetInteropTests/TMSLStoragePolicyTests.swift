import XCTest
import FacetCore
@testable import FacetInterop

/// Incremental refresh (`refreshPolicy`) and aggregations (`alternateOf`) in TMSL: the `model.bim` of a project and the
/// `DataModelSchema` of a `.pbit` carry both, in Tabular's JSON form, and read back into the same model.
final class TMSLStoragePolicyTests: XCTestCase {
    private let salesM = """
    let
        Source = Csv.Document(File.Contents("/data/sales.csv"), [Delimiter = ","]),
        Promoted = Table.PromoteHeaders(Source),
        Filtered = Table.SelectRows(Promoted, each [Order Date] >= RangeStart and [Order Date] < RangeEnd)
    in
        Filtered
    """

    private func document() -> (SemanticModel, [QueryDefinition]) {
        var m = SemanticModel()
        m.name = "Sales"
        var sales = ModelTable(name: "Sales")
        sales.columns = [ModelColumn(name: "Order Date", dataType: .date), ModelColumn(name: "Amount", dataType: .decimal),
                         ModelColumn(name: "Modified", dataType: .dateTime)]
        sales.sourceQuery = "Sales"
        var policy = IncrementalRefreshPolicy(dateColumn: "Order Date")
        policy.archiveCount = 3
        policy.archiveUnit = "year"
        policy.refreshCount = 10
        policy.refreshUnit = "day"
        policy.onlyCompletePeriods = true
        policy.realTimeDirectQuery = true
        policy.detectChangesColumn = "Modified"
        sales.incrementalRefresh = policy
        var agg = ModelTable(name: "Sales Agg")
        agg.columns = [ModelColumn(name: "Order Date", dataType: .date), ModelColumn(name: "Amount Sum", dataType: .decimal),
                       ModelColumn(name: "Rows", dataType: .integer), ModelColumn(name: "Amount Avg", dataType: .decimal)]
        agg.isHidden = true
        m.tables = [sales, agg]
        m.aggregations = [
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Amount Sum", summarization: .sum, detailTable: "Sales", detailColumn: "Amount"),
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Order Date", summarization: .none, detailTable: "Sales", detailColumn: "Order Date"),
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Rows", summarization: .count, detailTable: "Sales", detailColumn: ""),
            // Tabular has no average summarization: this one only travels in the Facet annotation.
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Amount Avg", summarization: .average, detailTable: "Sales", detailColumn: "Amount"),
        ]
        return (m, [QueryDefinition(name: "Sales", mScript: salesM)])
    }

    private func table(_ bim: JSONValue, _ name: String) -> JSONValue? {
        bim["model"]?["tables"]?.arrayValue?.first { $0["name"]?.stringValue == name }
    }
    private func column(_ table: JSONValue?, _ name: String) -> JSONValue? {
        table?["columns"]?.arrayValue?.first { $0["name"]?.stringValue == name }
    }
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(text) }

    func testTheWriterEmitsRefreshPolicyAndAlternateOfAsTabularDoes() throws {
        let (model, queries) = document()
        let bim = TMSLWriter.document(model: model, queries: queries)

        let polling = "let\n    Source =\n\(salesM)\n    ,\n    MaxValue = List.Max(Source[Modified])\nin\n    MaxValue"
        var expected: [String: JSONValue] = [
            "policyType": .string("basic"),
            "rollingWindowGranularity": .string("year"), "rollingWindowPeriods": .number(3),
            "incrementalGranularity": .string("day"), "incrementalPeriods": .number(10),
            "incrementalPeriodsOffset": .number(-1), "mode": .string("hybrid"),
        ]
        expected["pollingExpression"] = .string(polling)
        expected["sourceExpression"] = .string(salesM)
        XCTAssertEqual(table(bim, "Sales")?["refreshPolicy"], .object(expected))
        XCTAssertNil(table(bim, "Sales")?["annotations"], "the source filters Order Date with RangeStart, so no annotation is needed")

        let agg = table(bim, "Sales Agg")
        XCTAssertEqual(column(agg, "Amount Sum")?["alternateOf"],
                       try json(#"{"summarization":"sum","baseColumn":{"table":"Sales","column":"Amount"}}"#))
        XCTAssertEqual(column(agg, "Order Date")?["alternateOf"],
                       try json(#"{"summarization":"groupBy","baseColumn":{"table":"Sales","column":"Order Date"}}"#))
        XCTAssertEqual(column(agg, "Rows")?["alternateOf"], try json(#"{"summarization":"count","baseTable":"Sales"}"#))
        XCTAssertNil(column(agg, "Amount Avg")?["alternateOf"])
        XCTAssertNil(column(table(bim, "Sales"), "Amount")?["alternateOf"])

        // The model annotation lists all four, flagging the three written as alternateOf.
        let note = try XCTUnwrap(TMSLConverter.facet(try XCTUnwrap(bim["model"]), "aggregations")?.arrayValue)
        XCTAssertEqual(note.count, 4)
        XCTAssertEqual(note.map { $0["alternateOf"]?.boolValue ?? false }, [true, true, true, false])
    }

    func testAModelBimRoundTripKeepsThePolicyAndEveryMapping() throws {
        let (model, queries) = document()
        let (read, readQueries, warnings) = TMSLConverter.convert(TMSLWriter.document(model: model, queries: queries))
        XCTAssertEqual(read.table("Sales")?.incrementalRefresh, model.tables[0].incrementalRefresh)
        XCTAssertNil(read.table("Sales Agg")?.incrementalRefresh)
        XCTAssertEqual(read.aggregations, model.aggregations, "same mappings, ids and order")
        XCTAssertEqual(readQueries.map(\.name), ["Sales"])
        XCTAssertFalse(warnings.contains { $0.message.contains("refresh") || $0.message.contains("alternateOf") }, "\(warnings)")
    }

    func testAPolicyOnAColumnTheSourceDoesntFilterKeepsItsDateColumn() throws {
        var (model, queries) = document()
        queries[0].mScript = "let\n    Source = Csv.Document(File.Contents(\"/data/sales.csv\"))\nin\n    Source"
        model.tables[0].incrementalRefresh?.detectChangesColumn = nil
        let bim = TMSLWriter.document(model: model, queries: queries)
        let note = TMSLConverter.facet(try XCTUnwrap(table(bim, "Sales")), "refreshPolicyDateColumn")
        XCTAssertEqual(note, .string("Order Date"))
        let (read, _, _) = TMSLConverter.convert(bim)
        XCTAssertEqual(read.table("Sales")?.incrementalRefresh?.dateColumn, "Order Date")
        XCTAssertEqual(read.table("Sales")?.incrementalRefresh, model.tables[0].incrementalRefresh)
    }

    /// A `model.bim` the way Power BI Desktop and Analysis Services write it: no Facet annotations, M as arrays of lines.
    private let desktopBim = #"""
    {"name":"Sales","compatibilityLevel":1567,"model":{"culture":"en-US","tables":[
      {"name":"Sales","columns":[{"name":"OrderDate","dataType":"dateTime","sourceColumn":"OrderDate"},
                                 {"name":"Amount","dataType":"decimal","sourceColumn":"Amount"}],
       "partitions":[{"name":"Sales","mode":"import","source":{"type":"m","expression":["let","    Source = Sql.Database(\"srv\", \"db\"),","    Rows = Table.SelectRows(Source, each [OrderDate] >= RangeStart and [OrderDate] < RangeEnd)","in","    Rows"]}}],
       "refreshPolicy":{"policyType":"basic","rollingWindowGranularity":"month","rollingWindowPeriods":24,
                        "incrementalGranularity":"day","incrementalPeriods":7,
                        "pollingExpression":["let","    Max = List.Max(Sales[LastUpdated])","in","    Max"],
                        "sourceExpression":["let","    Source = Sql.Database(\"srv\", \"db\"),","    Rows = Table.SelectRows(Source, each [OrderDate] >= RangeStart and [OrderDate] < RangeEnd)","in","    Rows"],
                        "futureOption":true}},
      {"name":"Agg","isHidden":true,"columns":[
         {"name":"Total","dataType":"decimal","sourceColumn":"Total","alternateOf":{"baseColumn":{"table":"Sales","column":"Amount"},"summarization":"sum"}},
         {"name":"Day","dataType":"dateTime","sourceColumn":"Day","alternateOf":{"baseColumn":{"table":"Sales","column":"OrderDate"},"summarization":"groupBy"}},
         {"name":"Lines","dataType":"int64","sourceColumn":"Lines","alternateOf":{"baseTable":"Sales","summarization":"count"}},
         {"name":"Odd","dataType":"decimal","sourceColumn":"Odd","alternateOf":{"baseColumn":{"table":"Sales","column":"Amount"},"summarization":"average"}}]}]}}
    """#

    func testADesktopModelBimReadsItsPolicyAndAggregations() throws {
        let (model, _, warnings) = TMSLConverter.convert(try json(desktopBim))
        let policy = try XCTUnwrap(model.table("Sales")?.incrementalRefresh)
        XCTAssertEqual(policy.dateColumn, "OrderDate", "the column the source compares with RangeStart")
        XCTAssertEqual(policy.archiveCount, 24)
        XCTAssertEqual(policy.archiveUnit, "month")
        XCTAssertEqual(policy.refreshCount, 7)
        XCTAssertEqual(policy.refreshUnit, "day")
        XCTAssertFalse(policy.onlyCompletePeriods)
        XCTAssertFalse(policy.realTimeDirectQuery)
        XCTAssertEqual(policy.detectChangesColumn, "LastUpdated")

        XCTAssertEqual(model.aggregations.map(\.aggColumn), ["Total", "Day", "Lines"], "in column order")
        XCTAssertEqual(model.aggregations.map(\.summarization), [.sum, .none, .count])
        XCTAssertEqual(model.aggregations.map(\.detailColumn), ["Amount", "OrderDate", ""])
        XCTAssertEqual(Set(model.aggregations.map(\.detailTable)), ["Sales"])
        XCTAssertTrue(warnings.contains { $0.message.contains("“average” isn't supported") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.message.contains("futureOption") }, "\(warnings)")
    }

    func testATemplateCarriesBothThroughItsDataModelSchema() throws {
        let (model, queries) = document()
        var doc = FacetDocument()
        doc.model = model
        doc.queries = queries
        let url = Fixtures.tempDir("pbit-policy").appendingPathComponent("Sales.pbit")
        try PBIXPackage.writeTemplate(doc, to: url)
        let (read, _) = try PBIXPackage.read(from: url)
        XCTAssertEqual(read.model.table("Sales")?.incrementalRefresh, model.tables[0].incrementalRefresh)
        XCTAssertEqual(read.model.aggregations, model.aggregations)
    }

    func testAProjectWithAModelBimReadsBoth() throws {
        let (model, queries) = document()
        var doc = FacetDocument()
        doc.model = model
        doc.queries = queries
        let dir = Fixtures.tempDir("bim-project")
        try PBIPProject.write(document: doc, to: dir, name: "Sales")
        // Power BI Desktop's older project layout: model.bim instead of a TMDL definition folder.
        let modelDir = dir.appendingPathComponent("Sales.SemanticModel")
        try FileManager.default.removeItem(at: modelDir.appendingPathComponent("definition"))
        try TMSLWriter.document(model: model, queries: queries).serialized().write(to: modelDir.appendingPathComponent("model.bim"))
        let (read, _) = try PBIPProject.read(from: dir)
        XCTAssertEqual(read.model.table("Sales")?.incrementalRefresh, model.tables[0].incrementalRefresh)
        XCTAssertEqual(read.model.aggregations, model.aggregations)
    }

    func testPublishedDefinitionsCarryBoth() throws {
        // Publish sends the semantic model as TMDL definition parts.
        let (model, queries) = document()
        var doc = FacetDocument()
        doc.model = model
        doc.queries = queries
        let parts = PBIPProject.definitionParts(for: doc, name: "Sales").model
        let text = parts.map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
        XCTAssertTrue(text.contains("refreshPolicy"), text)
        XCTAssertTrue(text.contains("alternateOf"), text)
        XCTAssertTrue(text.contains("baseColumn: Sales.Amount") || text.contains("baseColumn: 'Sales'.Amount"), text)
    }
}
