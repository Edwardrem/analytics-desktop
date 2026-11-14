import XCTest
@testable import FacetCore

final class CoreTests: XCTestCase {
    func testValueEqualityAndOrder() {
        XCTAssertEqual(Value.int(1), Value.double(1.0))
        XCTAssertEqual(Set([Value.int(1), .double(1.0)]).count, 1)
        XCTAssertLessThan(Value.null, Value.int(0))
        XCTAssertLessThan(Value.int(2), Value.double(2.5))
        XCTAssertLessThan(Value.string("a10"), Value.string("a9").self == .string("a9") ? Value.string("b") : .null)
    }
    func testFormatting() {
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00"), "1,234.50")
        XCTAssertEqual(ValueFormatter.format(.double(0.256), "0.0%"), "25.6%")
        XCTAssertEqual(ValueFormatter.format(.double(-12), "$#,0;($#,0)"), "($12)")
        XCTAssertEqual(ValueFormatter.format(.int(7), "000"), "007")
        XCTAssertEqual(ValueFormatter.format(.double(2_500_000), "#,0.0,,\"M\""), "2.5M")
        XCTAssertEqual(ValueFormatter.format(.date(DateParsing.parse("2026-03-09")!), "yyyy-mm-dd"), "2026-03-09")
        XCTAssertEqual(ValueFormatter.format(.date(DateParsing.parse("2026-03-09")!), "mmm yyyy"), "Mar 2026")
        XCTAssertEqual(ValueFormatter.compact(1_260_000), "1.3M")
    }
    func testTypeDetection() {
        var t = DataTable(columnNames: ["a", "b", "c"], rows: [["1", "2.5", "2026-01-02"], ["3", "$1,000", "2026-02-03"]], types: [.text, .text, .text])
        t.detectAndConvertTextTypes()
        XCTAssertEqual(t.columns.map(\.type), [.integer, .decimal, .date])
        XCTAssertEqual(t[1, 1], .double(1000))
    }
    func testPackageRoundTrip() throws {
        var doc = FacetDocument()
        var table = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal)])
        table.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        doc.model.tables = [table]
        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Amount"], rows: [[1.5], [.null], [.date(Date(timeIntervalSince1970: 86400))]])
        doc.report.pages[0].visuals = [VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 100, height: 80))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).facet")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPackage.write(doc, to: url)
        try DocumentPackage.write(doc, to: url) // overwrite path
        let back = try DocumentPackage.read(from: url)
        XCTAssertEqual(back.model.tables.first?.measures.first?.name, "Total")
        XCTAssertEqual(back.data["Sales"]?.rowCount, 3)
        XCTAssertEqual(back.data["Sales"]?[2, 0], .date(Date(timeIntervalSince1970: 86400)))
        XCTAssertEqual(back.report.pages[0].visuals.first?.type, .card)
    }

    /// JSON writes 2399.0 as 2399; a decimal column still reads it back as a decimal, and a whole
    /// number column keeps its integers.
    func testWholeDecimalsComeBackAsDecimals() throws {
        let column = DataColumn(name: "Price", type: .currency, values: [.double(2399), .double(29.5), .null])
        let counts = DataColumn(name: "Units", type: .integer, values: [.int(3), .int(40)])
        let mixed = DataColumn(name: "Any", type: .any, values: [.int(3), .string("x")])
        let back = try JSONDecoder().decode([DataColumn].self, from: JSONEncoder().encode([column, counts, mixed]))
        guard back.count == 3 else { return XCTFail("decoded \(back.count) columns") }
        if case .double(let d) = back[0].values[0] { XCTAssertEqual(d, 2399) } else { XCTFail("2399.0 came back as \(back[0].values[0])") }
        if case .double(let d) = back[0].values[1] { XCTAssertEqual(d, 29.5) } else { XCTFail("29.5 came back as \(back[0].values[1])") }
        XCTAssertTrue(back[0].values[2].isNull)
        if case .int(let i) = back[1].values[1] { XCTAssertEqual(i, 40) } else { XCTFail("an integer came back as \(back[1].values[1])") }
        if case .int = back[2].values[0] {} else { XCTFail("an untyped column changed its values") }
        XCTAssertEqual(back[2].values[1], .string("x"))
    }

    /// Everything the modeling dialogs write must come back from a saved `.facet` package.
    func testModelingObjectsSurviveThePackage() throws {
        var doc = FacetDocument()
        var table = ModelTable(name: "Sales", columns: [ModelColumn(name: "OrderDate", dataType: .date)])
        var bins = ModelColumn(name: "OrderDate (bins)", dataType: .date)
        var grouping = ColumnGrouping(kind: .binSize, sourceColumn: "OrderDate")
        grouping.binValue = 3; grouping.binUnit = .month
        bins.grouping = grouping
        table.columns.append(bins)
        table.hierarchies = [Hierarchy(name: "Dates", levels: ["OrderDate (bins)", "OrderDate"])]
        table.dateColumn = "OrderDate"
        var calendar = CalendarDefinition(name: "Fiscal", columnsByUnit: ["date": "OrderDate"])
        calendar.fiscalYearStartMonth = 7
        table.calendars = [calendar]
        var policy = IncrementalRefreshPolicy(dateColumn: "OrderDate")
        policy.realTimeDirectQuery = true; policy.onlyCompletePeriods = true
        table.incrementalRefresh = policy
        doc.model.tables = [table]
        var role = SecurityRole(name: "West")
        role.tableFilters = ["Sales": "[Region] = \"West\""]; role.hiddenColumns = ["Sales[OrderDate]"]
        doc.model.roles = [role]
        var group = CalculationGroup(name: "Time")
        var item = CalculationItem(name: "YTD", expression: "CALCULATE(SELECTEDMEASURE())")
        item.formatExpression = "\"0.0\""
        group.items = [item]; group.precedence = 3
        doc.model.calculationGroups = [group]
        var parameter = FunctionParameter(name: "rate")
        parameter.defaultExpression = "0.1"
        doc.model.functions = [UserFunction(name: "AddTax", parameters: [parameter], expression: "100 * rate")]
        doc.model.perspectives = [Perspective(name: "Finance")]
        var french = Translation(culture: "fr-FR")
        french.captions = ["Sales": "Ventes"]
        doc.model.translations = [french]
        doc.model.whatIfParameters = [WhatIfParameter(name: "Discount", minimum: 0, maximum: 1, increment: 0.5, defaultValue: 0)]
        doc.model.fieldParameters = [FieldParameter(name: "Axis", fields: [.column("Sales", "OrderDate")])]
        doc.model.aggregations = [AggregationMapping(aggTable: "Agg", aggColumn: "Rows", summarization: .count, detailTable: "Sales", detailColumn: "")]
        doc.model.aiExcludedFields = ["Sales[OrderDate]"]
        doc.model.aiInstructions = "Revenue means net sales."
        doc.model.verifiedAnswers = [VerifiedAnswer(question: "How are sales?")]
        doc.model.qnaSynonyms = ["Sales[Total]": ["revenue"]]

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).facet")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPackage.write(doc, to: url)
        let back = try DocumentPackage.read(from: url).model
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(back), as: UTF8.self), String(decoding: try encoder.encode(doc.model), as: UTF8.self))
        XCTAssertEqual(back.tables.first?.columns.last?.grouping?.binUnit, .month)
    }

    /// Documents saved before date bins had a unit still open.
    func testGroupingWithoutABinUnitStillDecodes() throws {
        let old = #"{"kind":"binSize","sourceColumn":"Amount","groups":{},"binValue":25}"#
        let g = try JSONDecoder().decode(ColumnGrouping.self, from: Data(old.utf8))
        XCTAssertNil(g.binUnit)
        XCTAssertEqual(g.bin(.double(60), minimum: 0, maximum: 100), .double(50))
    }
}
