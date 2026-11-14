import XCTest
import FacetCore
@testable import FacetInterop

/// Incremental refresh and aggregations in their Tabular form: `refreshPolicy` on the table and
/// `alternateOf` on aggregation columns, read back from Facet's own files, from files written before
/// these existed (Facet annotations only) and from TMDL in the shape Power BI Desktop writes.
final class TMDLStoragePolicyTests: XCTestCase {
    private let salesM = """
    let
        Source = Csv.Document(File.Contents("/data/sales.csv")),
        Filtered = Table.SelectRows(Source, each [Order Date] >= RangeStart and [Order Date] < RangeEnd)
    in
        Filtered
    """

    private func salesModel(_ policy: IncrementalRefreshPolicy, withQuery: Bool = true) -> (SemanticModel, [QueryDefinition]) {
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Order Date", dataType: .dateTime), ModelColumn(name: "Modified", dataType: .dateTime)])
        sales.incrementalRefresh = policy
        if withQuery { sales.sourceQuery = "Sales" }
        var m = SemanticModel()
        m.tables = [sales]
        return (m, withQuery ? [QueryDefinition(name: "Sales", mScript: salesM)] : [])
    }

    private func text(_ files: [TMDLFile], _ path: String) -> String { files.first { $0.path == path }?.text ?? "" }

    // MARK: refreshPolicy

    func testPolicyIsWrittenAsRefreshPolicy() throws {
        var p = IncrementalRefreshPolicy(dateColumn: "Order Date")
        p.archiveCount = 5; p.archiveUnit = "year"; p.refreshCount = 10; p.refreshUnit = "day"
        p.onlyCompletePeriods = true; p.realTimeDirectQuery = true; p.detectChangesColumn = "Modified"
        let (model, queries) = salesModel(p)
        let files = TMDL.serialize(model: model, queries: queries)
        let sales = text(files, "tables/Sales.tmdl")
        XCTAssertTrue(sales.contains("""
        \trefreshPolicy
        \t\tpolicyType: basic
        \t\trollingWindowGranularity: year
        \t\trollingWindowPeriods: 5
        \t\tincrementalGranularity: day
        \t\tincrementalPeriods: 10
        \t\tincrementalPeriodsOffset: -1
        \t\tmode: hybrid
        \t\tpollingExpression =
        """), sales)
        XCTAssertTrue(sales.contains("MaxValue = List.Max(Source[Modified])"))
        XCTAssertTrue(sales.contains("\t\tsourceExpression =\n\t\t\t\tlet\n"))
        // The partition column is the one the source filters with RangeStart, so nothing else records it.
        XCTAssertFalse(sales.contains("Facet_incrementalRefresh"))
        XCTAssertFalse(sales.contains("Facet_refreshPolicyDateColumn"))

        let back = try TMDL.parseDetailed(files: files)
        XCTAssertTrue(back.warnings.isEmpty, "\(back.warnings)")
        XCTAssertEqual(back.model.table("Sales")?.incrementalRefresh, p)
        XCTAssertEqual(json(back.model), json(model))
    }

    func testPolicyWithoutAFilteringQueryKeepsItsDateColumn() throws {
        var p = IncrementalRefreshPolicy(dateColumn: "Order Date")
        p.detectChangesColumn = "Modified"
        let (model, _) = salesModel(p, withQuery: false)
        let files = TMDL.serialize(model: model)
        let sales = text(files, "tables/Sales.tmdl")
        XCTAssertTrue(sales.contains("annotation Facet_refreshPolicyDateColumn = \"Order Date\""), sales)
        XCTAssertTrue(sales.contains("pollingExpression = List.Max(#\"Sales\"[Modified])"), sales)
        XCTAssertFalse(sales.contains("sourceExpression"))
        let back = try TMDL.parseDetailed(files: files)
        XCTAssertTrue(back.warnings.isEmpty, "\(back.warnings)")
        XCTAssertEqual(back.model.table("Sales")?.incrementalRefresh, p)
    }

    func testOldFilesWithOnlyTheAnnotationStillRead() throws {
        let table = """
        table Sales
        \tcolumn 'Order Date'
        \t\tdataType: dateTime
        \t\tsourceColumn: Order Date

        \tannotation Facet_incrementalRefresh = {"archiveCount":3,"archiveUnit":"quarter","dateColumn":"Order Date","detectChangesColumn":"Order Date","onlyCompletePeriods":true,"realTimeDirectQuery":false,"refreshCount":2,"refreshUnit":"month"}
        """
        let r = try TMDL.parseDetailed(files: [TMDLFile(path: "tables/Sales.tmdl", text: table)])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        var expected = IncrementalRefreshPolicy(dateColumn: "Order Date")
        expected.archiveCount = 3; expected.archiveUnit = "quarter"; expected.refreshCount = 2; expected.refreshUnit = "month"
        expected.detectChangesColumn = "Order Date"; expected.onlyCompletePeriods = true
        XCTAssertEqual(r.model.table("Sales")?.incrementalRefresh, expected)
        // Written again, it is a refreshPolicy.
        let again = text(TMDL.serialize(model: r.model, queries: r.queries), "tables/Sales.tmdl")
        XCTAssertTrue(again.contains("\trefreshPolicy\n"))
        XCTAssertFalse(again.contains("Facet_incrementalRefresh"))
    }

    /// A policy in the shape Power BI Desktop writes: "Archive 3 years, refresh 7 days, only complete
    /// days, detect changes on LastUpdated, real-time data" over a filtered SQL source.
    func testReadsPowerBIAuthoredRefreshPolicy() throws {
        let table = """
        table FactSales
        \tlineageTag: 0a9e4c5d-1b2c-4d3e-8f90-a1b2c3d4e5f6

        \trefreshPolicy
        \t\tpolicyType: basic
        \t\trollingWindowGranularity: year
        \t\trollingWindowPeriods: 3
        \t\tincrementalGranularity: day
        \t\tincrementalPeriods: 7
        \t\tincrementalPeriodsOffset: -1
        \t\tmode: hybrid
        \t\tpollingExpression =
        \t\t\t\tlet
        \t\t\t\t    Source = Sql.Database("server", "db"),
        \t\t\t\t    dbo_Fact = Source{[Schema="dbo",Item="Fact"]}[Data],
        \t\t\t\t    #"Filtered Rows" = Table.SelectRows(dbo_Fact, each [OrderDate] >= RangeStart and [OrderDate] < RangeEnd),
        \t\t\t\t    #"Max LastUpdated" = List.Max(#"Filtered Rows"[LastUpdated])
        \t\t\t\tin
        \t\t\t\t    #"Max LastUpdated"
        \t\tsourceExpression =
        \t\t\t\tlet
        \t\t\t\t    Source = Sql.Database("server", "db"),
        \t\t\t\t    dbo_Fact = Source{[Schema="dbo",Item="Fact"]}[Data],
        \t\t\t\t    #"Filtered Rows" = Table.SelectRows(dbo_Fact, each [OrderDate] >= RangeStart and [OrderDate] < RangeEnd)
        \t\t\t\tin
        \t\t\t\t    #"Filtered Rows"

        \tcolumn OrderDate
        \t\tdataType: dateTime
        \t\tsourceColumn: OrderDate

        \tcolumn LastUpdated
        \t\tdataType: dateTime
        \t\tsourceColumn: LastUpdated
        """
        let r = try TMDL.parseDetailed(files: [TMDLFile(path: "tables/FactSales.tmdl", text: table)])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        let p = try XCTUnwrap(r.model.table("FactSales")?.incrementalRefresh)
        XCTAssertEqual(p.dateColumn, "OrderDate")
        XCTAssertEqual(p.archiveCount, 3); XCTAssertEqual(p.archiveUnit, "year")
        XCTAssertEqual(p.refreshCount, 7); XCTAssertEqual(p.refreshUnit, "day")
        XCTAssertTrue(p.onlyCompletePeriods)
        XCTAssertTrue(p.realTimeDirectQuery)
        XCTAssertEqual(p.detectChangesColumn, "LastUpdated")
    }

    func testColumnNamesInM() {
        XCTAssertEqual(TMDLRefreshPolicy.dateColumn(filteredIn: "each [Order Date] >= RangeStart and [Order Date] < RangeEnd"), "Order Date")
        XCTAssertEqual(TMDLRefreshPolicy.dateColumn(filteredIn: "each [#\"Date \"\"x\"\"\"] >= RangeStart"), "Date \"x\"")
        XCTAssertEqual(TMDLRefreshPolicy.dateColumn(filteredIn: "each [a]]b] >= RangeStart"), "a]b")
        XCTAssertNil(TMDLRefreshPolicy.dateColumn(filteredIn: "each [Order Date] < RangeEnd"))
        XCTAssertEqual(TMDLRefreshPolicy.field("Order Date"), "[Order Date]")
        XCTAssertEqual(TMDLRefreshPolicy.field("Date (UTC)"), "[#\"Date (UTC)\"]")
        XCTAssertEqual(TMDLRefreshPolicy.maxColumn(in: "List.Max(Source[#\"Date (UTC)\"])"), "Date (UTC)")
        XCTAssertNil(TMDLRefreshPolicy.maxColumn(in: "DateTime.LocalNow()"))
    }

    // MARK: alternateOf

    /// Sales Agg summarises Sales: Region groups by Sales[Region], Amount sums Sales[Amount], Rows counts
    /// Sales's rows; Average has no Tabular summarization and stays a Facet annotation only.
    private func aggregationModel() -> SemanticModel {
        let sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal)])
        let agg = ModelTable(name: "Sales Agg", columns: [
            ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Amount", dataType: .decimal),
            ModelColumn(name: "Rows", dataType: .integer), ModelColumn(name: "Average", dataType: .decimal),
        ])
        var m = SemanticModel()
        m.tables = [sales, agg]
        m.aggregations = [
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Average", summarization: .average, detailTable: "Sales", detailColumn: "Amount"),
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Region", summarization: .none, detailTable: "Sales", detailColumn: "Region"),
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Amount", summarization: .sum, detailTable: "Sales", detailColumn: "Amount"),
            AggregationMapping(aggTable: "Sales Agg", aggColumn: "Rows", summarization: .count, detailTable: "Sales", detailColumn: ""),
        ]
        return m
    }

    func testAggregationsAreWrittenAsAlternateOf() throws {
        let model = aggregationModel()
        let files = TMDL.serialize(model: model)
        let agg = text(files, "tables/Sales Agg.tmdl")
        XCTAssertTrue(agg.contains("\t\talternateOf\n\t\t\tbaseColumn: Sales.Region\n\t\t\tsummarization: groupBy\n"), agg)
        XCTAssertTrue(agg.contains("\t\talternateOf\n\t\t\tbaseColumn: Sales.Amount\n\t\t\tsummarization: sum\n"))
        XCTAssertTrue(agg.contains("\t\talternateOf\n\t\t\tbaseTable: Sales\n\t\t\tsummarization: count\n"))
        XCTAssertEqual(agg.components(separatedBy: "alternateOf").count - 1, 3, "Average has no alternateOf")
        let back = try TMDL.parseDetailed(files: files)
        XCTAssertTrue(back.warnings.isEmpty, "\(back.warnings)")
        XCTAssertEqual(json(back.model), json(model), "same mappings, ids and order")
        XCTAssertEqual(TMDL.serialize(model: back.model), files)
    }

    func testTheAlternateOfWinsOverTheAnnotation() throws {
        let model = aggregationModel()
        var files = TMDL.serialize(model: model)
        let i = try XCTUnwrap(files.firstIndex { $0.path == "tables/Sales Agg.tmdl" })
        // Edited outside the app: Amount becomes a Max, and Region's alternateOf is deleted.
        files[i].text = files[i].text
            .replacingOccurrences(of: "baseColumn: Sales.Amount\n\t\t\tsummarization: sum", with: "baseColumn: Sales.Amount\n\t\t\tsummarization: max")
            .replacingOccurrences(of: "\t\talternateOf\n\t\t\tbaseColumn: Sales.Region\n\t\t\tsummarization: groupBy\n", with: "")
        let back = try TMDL.parse(files: files).0
        XCTAssertEqual(back.aggregations.map(\.aggColumn), ["Average", "Amount", "Rows"])
        XCTAssertEqual(back.aggregations[1].summarization, .max)
        XCTAssertEqual(back.aggregations[1].id, model.aggregations[2].id)
    }

    func testFilesBeforeAlternateOfKeepTheirMappings() throws {
        let model = aggregationModel()
        let annotation = try XCTUnwrap(String(data: try JSONEncoder().encode(model.aggregations), encoding: .utf8))
        let old = [
            TMDLFile(path: "model.tmdl", text: "model Model\n\tculture: en-US\n\n\tannotation Facet_aggregations = \(annotation)\n"),
            TMDLFile(path: "tables/Sales.tmdl", text: "table Sales\n\tcolumn Region\n\t\tdataType: string\n\tcolumn Amount\n\t\tdataType: decimal\n"),
            TMDLFile(path: "tables/Sales Agg.tmdl", text: "table 'Sales Agg'\n\tcolumn Region\n\t\tdataType: string\n\tcolumn Amount\n\t\tdataType: decimal\n\tcolumn Rows\n\t\tdataType: int64\n\tcolumn Average\n\t\tdataType: decimal\n"),
        ]
        let back = try TMDL.parse(files: old).0
        XCTAssertEqual(json(back.aggregations), json(model.aggregations))
    }

    func testReadsPowerBIAuthoredAlternateOf() throws {
        let agg = """
        table 'Sales Agg'
        \tisHidden

        \tcolumn CustomerKey
        \t\tdataType: int64
        \t\tsummarizeBy: none
        \t\tsourceColumn: CustomerKey

        \t\talternateOf
        \t\t\tbaseColumn: Sales.CustomerKey
        \t\t\tsummarization: groupBy

        \tcolumn 'Sales Count'
        \t\tdataType: int64
        \t\tsourceColumn: Sales Count

        \t\talternateOf
        \t\t\tbaseTable: Sales
        \t\t\tsummarization: count

        \tcolumn 'Total Amount'
        \t\tdataType: decimal
        \t\tsourceColumn: Total Amount

        \t\talternateOf
        \t\t\tbaseColumn: Sales.'Sales Amount'
        \t\t\tsummarization: sum
        """
        let sales = "table Sales\n\tcolumn CustomerKey\n\t\tdataType: int64\n\tcolumn 'Sales Amount'\n\t\tdataType: decimal\n"
        // Sales Agg is read before Sales; the mappings still follow the model's table order.
        let model = "model Model\n\tculture: en-US\n\nref table Sales\nref table 'Sales Agg'\n"
        let r = try TMDL.parseDetailed(files: [TMDLFile(path: "tables/Sales Agg.tmdl", text: agg), TMDLFile(path: "tables/Sales.tmdl", text: sales),
                                               TMDLFile(path: "model.tmdl", text: model)])
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        XCTAssertEqual(r.model.aggregations.map { "\($0.aggColumn)=\($0.summarization.rawValue)(\($0.detailTable)[\($0.detailColumn)])" },
                       ["CustomerKey=none(Sales[CustomerKey])", "Sales Count=count(Sales[])", "Total Amount=sum(Sales[Sales Amount])"])
    }

    func testScriptsCarryAlternateOf() throws {
        let model = aggregationModel()
        let column = try TMDL.script(for: .column(table: "Sales Agg", name: "Amount"), in: model)
        XCTAssertTrue(column.contains("alternateOf\n\t\t\t\tbaseColumn: Sales.Amount\n\t\t\t\tsummarization: sum"), column)

        var table = try TMDL.script(for: .table("Sales Agg"), in: model)
        XCTAssertTrue(try TMDL.apply(script: table, to: model).1.isEmpty, "scripting a table onto itself changes nothing")
        table = table.replacingOccurrences(of: "\t\t\talternateOf\n\t\t\t\tbaseColumn: Sales.Amount\n\t\t\t\tsummarization: sum\n", with: "")
        let applied = try TMDL.apply(script: table, to: model).0
        XCTAssertEqual(applied.aggregations.map(\.aggColumn), ["Average", "Region", "Rows"], "deleting the alternateOf removes the mapping")
    }

    // MARK: Model options

    func testAutoDateTimeIsPowerBIsTimeIntelligenceAnnotation() throws {
        var m = SemanticModel()
        m.autoDateTime = true
        XCTAssertTrue(text(TMDL.serialize(model: m), "model.tmdl").contains("\tannotation __PBI_TimeIntelligenceEnabled = 1\n"))
        m.autoDateTime = false
        XCTAssertTrue(text(TMDL.serialize(model: m), "model.tmdl").contains("\tannotation __PBI_TimeIntelligenceEnabled = 0\n"))
        // Power BI's annotation decides, over a Facet annotation from an older file.
        let off = "model Model\n\tculture: en-US\n\n\tannotation Facet_autoDateTime = true\n\tannotation __PBI_TimeIntelligenceEnabled = 0\n"
        XCTAssertFalse(try TMDL.parse(files: [TMDLFile(path: "model.tmdl", text: off)]).0.autoDateTime)
        let old = "model Model\n\tculture: en-US\n\n\tannotation Facet_autoDateTime = true\n"
        XCTAssertTrue(try TMDL.parse(files: [TMDLFile(path: "model.tmdl", text: old)]).0.autoDateTime)
    }

    func testTheFilesRelationshipOptionRoundTrips() throws {
        for value in [nil, true, false] as [Bool?] {
            var m = SemanticModel()
            m.autodetectRelationships = value
            XCTAssertEqual(try TMDL.parse(files: TMDL.serialize(model: m)).0.autodetectRelationships, value)
        }
    }
}
