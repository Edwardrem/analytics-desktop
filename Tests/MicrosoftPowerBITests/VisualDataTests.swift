import XCTest
import FacetCore
@testable import FacetDAX
@testable import MicrosoftPowerBI

/// `LiveCalculation.visualData`: the queries behind visuals — grouping, Top N, relative dates,
/// cross-highlight baselines, drill, totals and visual calculations.
///
/// Fixture (hand-computed):
/// ```
/// Product: Widget (Tools, Red), Gadget (Tools, Blue), Gizmo (Toys, Red), Doohickey (Toys, Blue)
/// Sales:   date        product    region  qty  amount
///          2024-03-01  Widget     East     1     10
///          2024-03-05  Gadget     East     2     40
///          2024-03-10  Gizmo      West     3     90
///          2024-03-14  Doohickey  West     1     20
///          2024-03-15  Widget     West     2     20
///          2024-03-15  Gizmo      East     1     30
///          2024-02-20  Gadget     West     5    100
///          2024-01-10  Doohickey  East     4     80
/// ```
/// Amount 390, quantity 19. By product: Widget 30 (3), Gadget 140 (7), Gizmo 120 (4),
/// Doohickey 100 (5). By category: Tools 170 (10), Toys 220 (9). East 160, West 230.
/// `Avg Price` = amount / quantity: Widget 10, Gadget 20, Gizmo 30, Doohickey 20; Tools 17,
/// Toys 220/9; overall 390/19.
final class VisualDataTests: XCTestCase {
    private var service: LiveCalculation!
    private var savedClock: (() -> Date)?

    private let category = FieldRef.column("Product", "Category")
    private let product = FieldRef.column("Product", "Product")
    private let region = FieldRef.column("Sales", "Region")
    private let amount = FieldRef.measure("Sales", "Total Amount")
    private let price = FieldRef.measure("Sales", "Avg Price")

    override func setUpWithError() throws {
        func day(_ s: String) throws -> Value { .date(try XCTUnwrap(DateParsing.parse(s), s)) }
        var productTable = ModelTable(name: "Product", columns: [
            ModelColumn(name: "Product", dataType: .text), ModelColumn(name: "Category", dataType: .text),
            ModelColumn(name: "Color", dataType: .text),
        ])
        productTable.measures = []
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "Date", dataType: .date), ModelColumn(name: "Product", dataType: .text),
            ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Qty", dataType: .integer),
            ModelColumn(name: "Amount", dataType: .integer),
        ])
        sales.measures = [
            Measure(name: "Total Amount", expression: "SUM(Sales[Amount])", formatString: "#,0"),
            Measure(name: "Avg Price", expression: "DIVIDE(SUM(Sales[Amount]), SUM(Sales[Qty]))", formatString: "0.00"),
        ]
        // A measure whose format follows the region in context.
        var dynamic = Measure(name: "Amount Auto", expression: "SUM(Sales[Amount])", formatString: "0")
        dynamic.formatExpression = "IF(SELECTEDVALUE(Sales[Region]) = \"East\", \"€#,0\", \"$#,0\")"
        sales.measures.append(dynamic)
        // A calculation group: Units (as is) and Share (of all products, formatted as a percentage).
        var scale = CalculationGroup(name: "Scale")
        scale.columnName = "Scale"
        var share = CalculationItem(name: "Share", expression: "DIVIDE(SELECTEDMEASURE(), CALCULATE(SELECTEDMEASURE(), REMOVEFILTERS(Product)))")
        share.formatExpression = "\"0.0%\""
        share.ordinal = 1
        scale.items = [CalculationItem(name: "Units", expression: "SELECTEDMEASURE()"), share]
        var model = SemanticModel()
        model.calculationGroups = [scale]
        model.tables = [productTable, sales]
        model.relationships = [Relationship(fromTable: "Sales", fromColumn: "Product", toTable: "Product", toColumn: "Product")]
        // Field parameters, installed the way the Parameters dialog does.
        ParameterLogic.install(fieldParameter: "Metric", fields: [.measure("Sales", "Total Amount"), .measure("Sales", "Avg Price"),
                                                                 .column("Sales", "Qty", .sum)], into: &model)
        ParameterLogic.install(fieldParameter: "Axis", fields: [category, region, .column("Product", "Color")], into: &model)
        let products = DataTable(name: "Product", columnNames: ["Product", "Category", "Color"], rows: [
            ["Widget", "Tools", "Red"], ["Gadget", "Tools", "Blue"], ["Gizmo", "Toys", "Red"], ["Doohickey", "Toys", "Blue"],
        ], types: [.text, .text, .text])
        let facts = DataTable(name: "Sales", columnNames: ["Date", "Product", "Region", "Qty", "Amount"], rows: [
            [try day("2024-03-01"), "Widget", "East", 1, 10], [try day("2024-03-05"), "Gadget", "East", 2, 40],
            [try day("2024-03-10"), "Gizmo", "West", 3, 90], [try day("2024-03-14"), "Doohickey", "West", 1, 20],
            [try day("2024-03-15"), "Widget", "West", 2, 20], [try day("2024-03-15"), "Gizmo", "East", 1, 30],
            [try day("2024-02-20"), "Gadget", "West", 5, 100], [try day("2024-01-10"), "Doohickey", "East", 4, 80],
        ], types: [.date, .text, .text, .integer, .integer])
        service = LiveCalculation()
        let errors = service.load(model: model, data: DataStore(tables: ["Product": products, "Sales": facts]), roles: [], userName: "")
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        // Friday 15 March 2024, 10:30 UTC.
        let pinned = try XCTUnwrap(DateParsing.parse("2024-03-15T10:30:00Z"))
        savedClock = PureDate.now
        PureDate.now = { pinned }
    }

    override func tearDown() {
        if let savedClock { PureDate.now = savedClock }
        super.tearDown()
    }

    // MARK: Helpers

    private func visual(_ type: VisualType, _ wells: [Well: [FieldRef]]) -> VisualSpec {
        var spec = VisualSpec(type: type, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        for (well, fields) in wells { spec.setFields(well, fields) }
        return spec
    }
    private func run(_ spec: VisualSpec, _ request: VisualRequest = VisualRequest(), file: StaticString = #filePath, line: UInt = #line) -> VisualData {
        let data = service.visualData(spec: spec, request: request)
        XCTAssertNil(data.error, "query failed: \(data.daxQuery)", file: file, line: line)
        return data
    }
    /// Rows keyed by their grouping columns joined with "/", mapped to one column's value (nil = blank).
    private func rows(_ table: DataTable, keys: Int = 1, value: Int) -> [String: Double?] {
        var out: [String: Double?] = [:]
        for r in 0..<table.rowCount {
            let key = (0..<keys).map { table[r, $0].isNull ? "(blank)" : table[r, $0].asString }.joined(separator: "/")
            out[key] = table[r, value].isNull ? nil : table[r, value].asDouble
        }
        return out
    }
    /// One value of `rows(…)`; NaN when the row is missing or blank.
    private func number(_ values: [String: Double?], _ key: String) -> Double {
        guard let found = values[key], let value = found else { return .nan }
        return value
    }
    private func topN(_ field: FieldRef, _ count: Int, by: FieldRef, bottom: Bool = false) -> FilterSpec {
        var f = FilterSpec(field: field, kind: .topN)
        f.topN.count = count; f.topN.by = by; f.topN.isBottom = bottom
        return f
    }
    private func relative(_ field: FieldRef, _ direction: RelativeDateFilter.Direction, _ count: Int, _ unit: RelativeDateFilter.Unit) -> FilterSpec {
        var f = FilterSpec(field: field, kind: .relativeDate)
        f.relative.direction = direction; f.relative.count = count; f.relative.unit = unit
        return f
    }
    private func request(filters: [FilterSpec] = [], crossFilters: [[DataPointSelection]] = [], highlights: [[DataPointSelection]] = []) -> VisualRequest {
        var r = VisualRequest()
        r.filters = filters; r.crossFilters = crossFilters; r.highlights = highlights
        return r
    }

    // MARK: Grouping, roles and totals

    func testGroupedVisual() {
        let data = run(visual(.clusteredColumn, [.category: [category], .values: [amount]]))
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 170, "Toys": 220])
        XCTAssertEqual(data.indices(.category), [0])
        XCTAssertEqual(data.indices(.values), [1])
        XCTAssertEqual(data.fields.map { $0?.name }, ["Category", "Total Amount"])
        XCTAssertEqual(data.formats, ["", "#,0"])
        XCTAssertTrue(data.daxQuery.contains("SUMMARIZECOLUMNS"))
        XCTAssertNil(data.baseline)
        // The grand total is evaluated on its own, not summed from the rows.
        XCTAssertTrue(data.totals[0].isNull)
        XCTAssertEqual(data.totals[1].asDouble, 390)
    }

    func testImplicitMeasuresAndSeveralValues() {
        let data = run(visual(.table, [.values: [product, .column("Sales", "Amount", .sum), .column("Sales", "Amount", .max), .column("Sales", "Qty")]]))
        XCTAssertEqual(data.table.columnNames.suffix(3), ["Sum of Amount", "Maximum of Amount", "Qty"])
        XCTAssertEqual(rows(data.table, value: 1), ["Widget": 30, "Gadget": 140, "Gizmo": 120, "Doohickey": 100])
        XCTAssertEqual(rows(data.table, value: 2), ["Widget": 20, "Gadget": 100, "Gizmo": 90, "Doohickey": 80])
        // A numeric column dropped into a value well is summed.
        XCTAssertEqual(rows(data.table, value: 3), ["Widget": 3, "Gadget": 7, "Gizmo": 4, "Doohickey": 5])
        XCTAssertEqual(data.totals.dropFirst().map { $0.asDouble }, [390, 100, 19])
    }

    func testTotalsOfANonAdditiveMeasure() {
        let data = run(visual(.clusteredColumn, [.category: [category], .values: [price]]))
        let byCategory = rows(data.table, value: 1)
        XCTAssertEqual(number(byCategory, "Tools"), 17, accuracy: 1e-12)
        XCTAssertEqual(number(byCategory, "Toys"), 220.0 / 9.0, accuracy: 1e-12)
        // 390 / 19, not 17 + 220/9.
        XCTAssertEqual(data.totals[1].asDouble ?? .nan, 390.0 / 19.0, accuracy: 1e-12)
        // Totals respect the visual's filters: red products are Widget and Gizmo → 150 / 7.
        var red = FilterSpec(field: .column("Product", "Color"))
        red.values = ["Red"]
        let filtered = run(visual(.clusteredColumn, [.category: [category], .values: [price]]), request(filters: [red]))
        XCTAssertEqual(filtered.totals[1].asDouble ?? .nan, 150.0 / 7.0, accuracy: 1e-12)
    }

    func testCardWithoutGroups() {
        let data = run(visual(.card, [.values: [amount]]))
        XCTAssertEqual(data.table.rowCount, 1)
        XCTAssertEqual(data.table[0, 0].asDouble, 390)
    }

    func testEmptyVisualAndQueryErrors() {
        XCTAssertTrue(service.visualData(spec: visual(.clusteredColumn, [:]), request: VisualRequest()).isEmpty)
        let broken = service.visualData(spec: visual(.card, [.values: [.measure("Sales", "No Such Measure")]]), request: VisualRequest())
        XCTAssertNotNil(broken.error)
        XCTAssertFalse(broken.daxQuery.isEmpty)
    }

    func testRowLimit() {
        var limited = VisualRequest()
        limited.rowLimit = 3
        XCTAssertEqual(run(visual(.table, [.values: [product, amount]]), limited).table.rowCount, 3)
        XCTAssertEqual(run(visual(.table, [.values: [product, amount]])).table.rowCount, 4)
    }

    // MARK: Aggregations

    func testEveryAggregationGeneratesValidDAX() throws {
        // Quantities are 1, 2, 3, 1, 2, 1, 5, 4: nineteen in eight rows, five distinct values.
        let expected: [(Aggregation, String, Double)] = [
            (.sum, "SUM('Sales'[Qty])", 19), (.average, "AVERAGE('Sales'[Qty])", 19.0 / 8.0),
            (.min, "MIN('Sales'[Qty])", 1), (.max, "MAX('Sales'[Qty])", 5),
            (.count, "COUNTA('Sales'[Qty])", 8), (.distinctCount, "DISTINCTCOUNT('Sales'[Qty])", 5),
            (.median, "MEDIAN('Sales'[Qty])", 2),
            (.first, "FIRSTNONBLANK('Sales'[Qty], 1)", 1), (.last, "LASTNONBLANK('Sales'[Qty], 1)", 5),
        ]
        let model = SemanticModel()
        for (aggregation, dax, value) in expected {
            let field = FieldRef.column("Sales", "Qty", aggregation)
            XCTAssertEqual(ModelDAX.aggregate(field, model: model), dax)
            XCTAssertEqual(try service.scalar(dax, filters: []).asDouble ?? .nan, value, accuracy: 1e-12, "\(aggregation)")
            // And through a visual.
            let data = run(visual(.card, [.values: [field]]))
            XCTAssertEqual(data.table[0, 0].asDouble ?? .nan, value, accuracy: 1e-12, "\(aggregation)")
        }
        // Sample variance and standard deviation: Σ(x − 2.375)² = 15.875 over 7.
        XCTAssertEqual(try service.scalar(ModelDAX.aggregate(.column("Sales", "Qty", .variance), model: model), filters: []).asDouble ?? .nan,
                       15.875 / 7.0, accuracy: 1e-12)
        XCTAssertEqual(try service.scalar(ModelDAX.aggregate(.column("Sales", "Qty", .stdDev), model: model), filters: []).asDouble ?? .nan,
                       (15.875 / 7.0).squareRoot(), accuracy: 1e-12)
    }

    func testFirstAndLastOfATextColumn() {
        // First and last in sort order within each category.
        let data = run(visual(.table, [.values: [category, .column("Product", "Product", .first), .column("Product", "Product", .last)]]))
        var first: [String: String] = [:], last: [String: String] = [:]
        for r in 0..<data.table.rowCount {
            first[data.table[r, 0].asString] = data.table[r, 1].asString
            last[data.table[r, 0].asString] = data.table[r, 2].asString
        }
        XCTAssertEqual(first, ["Tools": "Gadget", "Toys": "Doohickey"])
        XCTAssertEqual(last, ["Tools": "Widget", "Toys": "Gizmo"])
        // As the by-field of a Top N filter too: the category whose last product name sorts highest is Tools (Widget).
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount]])
        let top = topN(category, 1, by: .column("Product", "Product", .last))
        XCTAssertEqual(rows(run(byCategory, request(filters: [top])).table, value: 1), ["Tools": 170])
    }

    // MARK: Format strings

    func testCalculationItemFormatStringReachesTheVisual() {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount, .column("Sales", "Qty", .sum)]])
        XCTAssertEqual(run(byCategory).formats, ["", "#,0", ""])
        // The Share item is selected by a slicer on the calculation group.
        var state = SlicerState()
        state.selected = ["Share"]
        var sliced = VisualRequest()
        sliced.slicers = [.init(fields: [.column("Scale", "Scale")], state: state, type: .slicer)]
        let data = run(byCategory, sliced)
        // The measure takes the item's format and value (170 / 390, 220 / 390); the implicit measure is untouched.
        XCTAssertEqual(data.formats, ["", "0.0%", ""])
        XCTAssertEqual(number(rows(data.table, value: 1), "Tools"), 170.0 / 390.0, accuracy: 1e-12)
        XCTAssertEqual(number(rows(data.table, value: 2), "Tools"), 10)
        XCTAssertEqual(data.formatted(row: 0, col: 1).hasSuffix("%"), true)
        // An item without a format expression keeps the measure's format; so does a filter.
        var units = FilterSpec(field: .column("Scale", "Scale"))
        units.values = ["Units"]
        XCTAssertEqual(run(byCategory, request(filters: [units])).formats, ["", "#,0", ""])
        var shareFilter = units
        shareFilter.values = ["Share"]
        XCTAssertEqual(run(byCategory, request(filters: [shareFilter])).formats, ["", "0.0%", ""])
    }

    func testDynamicFormatStringFollowsTheVisualsFilters() {
        let card = visual(.card, [.values: [.measure("Sales", "Amount Auto")]])
        XCTAssertEqual(run(card).formats, ["$#,0"])
        var east = FilterSpec(field: region)
        east.values = ["East"]
        XCTAssertEqual(run(card, request(filters: [east])).formats, ["€#,0"])
        let selection = [DataPointSelection(fields: [region], values: ["East"])]
        XCTAssertEqual(run(card, request(crossFilters: [selection])).formats, ["€#,0"])
        var west = east
        west.values = ["West"]
        XCTAssertEqual(run(card, request(filters: [west])).formats, ["$#,0"])
    }

    // MARK: Field parameters

    private let metric = FieldRef.column("Metric", "Metric")
    private let axis = FieldRef.column("Axis", "Axis")
    private func parameterSlicer(_ field: FieldRef, _ selected: Value...) -> VisualRequest {
        var state = SlicerState()
        state.selected = selected
        var r = VisualRequest()
        r.slicers = [.init(fields: [field], state: state, type: .slicer)]
        return r
    }

    func testUnfilteredFieldParameterShowsAllItsFieldsInOrder() {
        let data = run(visual(.clusteredColumn, [.category: [category], .values: [metric]]))
        XCTAssertEqual(data.fields.map { $0?.caption }, ["Category", "Total Amount", "Avg Price", "Sum of Qty"])
        XCTAssertEqual(data.indices(.values), [1, 2, 3])
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 170, "Toys": 220])
        XCTAssertEqual(number(rows(data.table, value: 2), "Tools"), 17, accuracy: 1e-12)
        XCTAssertEqual(rows(data.table, value: 3), ["Tools": 10, "Toys": 9])
        XCTAssertEqual(data.formats, ["", "#,0", "0.00", ""])
        XCTAssertEqual(data.totals[3].asDouble, 19)
    }

    func testSlicerOnAFieldParameterSwapsTheMeasures() {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [metric]])
        let one = run(byCategory, parameterSlicer(metric, "Avg Price"))
        XCTAssertEqual(one.fields.map { $0?.caption }, ["Category", "Avg Price"])
        XCTAssertEqual(number(rows(one.table, value: 1), "Toys"), 220.0 / 9.0, accuracy: 1e-12)
        // Two selected, listed in parameter order whatever the order they were picked in.
        let two = run(byCategory, parameterSlicer(metric, "Sum of Qty", "Total Amount"))
        XCTAssertEqual(two.fields.map { $0?.caption }, ["Category", "Total Amount", "Sum of Qty"])
        XCTAssertEqual(rows(two.table, value: 2), ["Tools": 10, "Toys": 9])
        // A filter on the parameter works like the slicer.
        var filter = FilterSpec(field: metric)
        filter.values = ["Total Amount"]
        XCTAssertEqual(run(byCategory, request(filters: [filter])).fields.map { $0?.caption }, ["Category", "Total Amount"])
    }

    func testFieldParameterOnTheAxisSwapsColumns() {
        let chart = visual(.clusteredColumn, [.category: [axis], .values: [amount]])
        let byRegion = run(chart, parameterSlicer(axis, "Region"))
        XCTAssertEqual(byRegion.fields.map { $0?.name }, ["Region", "Total Amount"])
        XCTAssertEqual(rows(byRegion.table, value: 1), ["East": 160, "West": 230])
        let byColor = run(chart, parameterSlicer(axis, "Color"))
        XCTAssertEqual(rows(byColor.table, value: 1), ["Red": 150, "Blue": 240])
        // Unfiltered, the three columns form the axis hierarchy: the first level shows until drilled.
        let all = run(chart)
        XCTAssertEqual(all.fields.map { $0?.name }, ["Category", "Total Amount"])
        var expanded = chart
        expanded.drillLevel = 1; expanded.expandedAllLevels = true
        XCTAssertEqual(run(expanded).fields.map { $0?.name }, ["Category", "Region", "Total Amount"])
        // In a table every selected column is shown.
        let table = run(visual(.table, [.values: [axis, amount]]), parameterSlicer(axis, "Category", "Color"))
        XCTAssertEqual(table.fields.map { $0?.name }, ["Category", "Color", "Total Amount"])
        XCTAssertEqual(rows(table.table, keys: 2, value: 2), ["Tools/Red": 30, "Tools/Blue": 140, "Toys/Red": 120, "Toys/Blue": 100])
    }

    func testBothParametersAndOtherFiltersTogether() {
        var east = FilterSpec(field: region)
        east.values = ["East"]
        var r = parameterSlicer(axis, "Color")
        var metricState = SlicerState()
        metricState.selected = ["Sum of Qty"]
        r.slicers.append(.init(fields: [metric], state: metricState, type: .slicer))
        r.filters = [east]
        let data = run(visual(.clusteredBar, [.category: [axis], .values: [metric]]), r)
        XCTAssertEqual(data.fields.map { $0?.caption }, ["Color", "Sum of Qty"])
        // East: Widget 1 + Gizmo 1 (Red), Gadget 2 + Doohickey 4 (Blue).
        XCTAssertEqual(rows(data.table, value: 1), ["Red": 2, "Blue": 6])
    }

    func testFieldParameterSlicerListsTheChoices() {
        let data = run(visual(.slicer, [.field: [metric]]))
        XCTAssertEqual(Set(data.table.columns[0].values), ["Total Amount", "Avg Price", "Sum of Qty"])
    }

    // MARK: Filters, slicers and cross-filtering

    func testTopNFilter() throws {
        let byProduct = visual(.clusteredBar, [.category: [product], .values: [amount]])
        // By a column (summed per product): Gadget 140 and Gizmo 120.
        let top2 = topN(product, 2, by: .column("Sales", "Amount"))
        let data = run(byProduct, request(filters: [top2]))
        XCTAssertEqual(rows(data.table, value: 1), ["Gadget": 140, "Gizmo": 120])
        XCTAssertEqual(data.totals[1].asDouble, 260)
        XCTAssertEqual(rows(run(byProduct, request(filters: [topN(product, 1, by: .column("Sales", "Amount"), bottom: true)])).table, value: 1), ["Widget": 30])
        // By a measure: the highest average price is Gizmo's 30.
        XCTAssertEqual(rows(run(byProduct, request(filters: [topN(product, 1, by: price)])).table, value: 1), ["Gizmo": 120])
        // Ties at the boundary are kept: Gadget and Doohickey both average 20.
        XCTAssertEqual(rows(run(byProduct, request(filters: [topN(product, 2, by: price)])).table, value: 1),
                       ["Gizmo": 120, "Gadget": 140, "Doohickey": 100])
        // An explicit aggregation on the by-field: the largest single sale is Gadget's 100.
        XCTAssertEqual(rows(run(byProduct, request(filters: [topN(product, 1, by: .column("Sales", "Amount", .max))])).table, value: 1), ["Gadget": 140])
        // The ranking ignores the visual's other filters: the top 2 overall, then East only.
        var east = FilterSpec(field: region)
        east.values = ["East"]
        XCTAssertEqual(rows(run(byProduct, request(filters: [top2, east])).table, value: 1), ["Gadget": 40, "Gizmo": 30])
        // The engine's own filter path (used for scalars and slicer lists) keeps the same values.
        XCTAssertEqual(try service.scalar("[Total Amount]", filters: [top2]).asDouble, 260)
        XCTAssertEqual(try service.scalar("[Total Amount]", filters: [topN(product, 2, by: price)]).asDouble, 360)
        XCTAssertEqual(try service.scalar("[Total Amount]", filters: [top2, east]).asDouble, 70)
    }

    func testRelativeDateFilter() throws {
        let byRegion = visual(.clusteredBar, [.category: [region], .values: [amount]])
        let date = FieldRef.column("Sales", "Date")
        // The last 7 days including today are 9–15 March: 90 + 20 (West) + 20 (West) + 30 (East).
        let week = relative(date, .last, 7, .days)
        let data = run(byRegion, request(filters: [week]))
        XCTAssertEqual(rows(data.table, value: 1), ["East": 30, "West": 130])
        XCTAssertEqual(data.totals[1].asDouble, 160)
        // The last calendar month is February: Gadget, West, 100.
        XCTAssertEqual(rows(run(byRegion, request(filters: [relative(date, .last, 1, .calendarMonths)])).table, value: 1), ["West": 100])
        // This month: everything in March → East 80, West 130.
        XCTAssertEqual(rows(run(byRegion, request(filters: [relative(date, .this, 1, .months)])).table, value: 1), ["East": 80, "West": 130])
        // Nothing lies in the next 7 days after today.
        var next = relative(date, .next, 7, .days)
        next.relative.includeToday = false
        XCTAssertTrue(run(byRegion, request(filters: [next])).isEmpty)
        // The engine's own filter path agrees.
        XCTAssertEqual(try service.scalar("[Total Amount]", filters: [week]).asDouble, 160)
        // A relative date slicer filters the same way.
        var state = SlicerState()
        state.relative = week.relative
        var sliced = VisualRequest()
        sliced.slicers = [.init(fields: [date], state: state, type: .slicer)]
        XCTAssertEqual(rows(run(byRegion, sliced).table, value: 1), ["East": 30, "West": 130])
    }

    func testBasicAdvancedAndSlicerFilters() {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount]])
        var notEast = FilterSpec(field: region)
        notEast.values = ["East"]; notEast.isInverted = true
        XCTAssertEqual(rows(run(byCategory, request(filters: [notEast])).table, value: 1), ["Tools": 120, "Toys": 110])
        // Amount ≥ 80: Gizmo 90 and Doohickey 80 (Toys), Gadget 100 (Tools).
        var large = FilterSpec(field: .column("Sales", "Amount"), kind: .advanced)
        large.conditions = [FilterCondition(op: .greaterOrEqual, value: 80)]
        XCTAssertEqual(rows(run(byCategory, request(filters: [large])).table, value: 1), ["Tools": 100, "Toys": 170])
        var state = SlicerState()
        state.selected = ["Widget", "Gizmo"]
        var sliced = VisualRequest()
        sliced.slicers = [.init(fields: [product], state: state, type: .slicer)]
        XCTAssertEqual(rows(run(byCategory, sliced).table, value: 1), ["Tools": 30, "Toys": 120])
    }

    func testSlicerValues() {
        let slicer = visual(.slicer, [.field: [product]])
        XCTAssertEqual(Set(run(slicer).table.columns[0].values), ["Widget", "Gadget", "Gizmo", "Doohickey"])
        var tools = FilterSpec(field: category)
        tools.values = ["Tools"]
        XCTAssertEqual(Set(run(slicer, request(filters: [tools])).table.columns[0].values), ["Widget", "Gadget"])
    }

    // MARK: Cross-filter and cross-highlight

    func testCrossFilterRemovesRows() {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount]])
        let widget = [DataPointSelection(fields: [product], values: ["Widget"])]
        let data = run(byCategory, request(crossFilters: [widget]))
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 30])
        XCTAssertNil(data.baseline)
        XCTAssertEqual(data.totals[1].asDouble, 30)
    }

    func testHighlightKeepsEveryRowAndAddsABaseline() throws {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount]])
        let east = [DataPointSelection(fields: [region], values: ["East"])]
        let data = run(byCategory, request(highlights: [east]))
        let baseline = try XCTUnwrap(data.baseline)
        // The baseline is the visual without the selection; the table is the highlighted part.
        XCTAssertEqual(rows(baseline, value: 1), ["Tools": 170, "Toys": 220])
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 50, "Toys": 110])
        // Both have the same rows in the same order, as the renderers require.
        XCTAssertEqual(data.table.rowCount, baseline.rowCount)
        XCTAssertEqual(data.table.columnCount, baseline.columnCount)
        XCTAssertEqual(data.table.columns[0].values, baseline.columns[0].values)
        // Totals stay those of the whole visual.
        XCTAssertEqual(data.totals[1].asDouble, 390)
    }

    func testHighlightWithNothingInAGroupIsBlankThere() throws {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount, price]])
        let widget = [DataPointSelection(fields: [product], values: ["Widget"])]
        let data = run(byCategory, request(highlights: [widget]))
        let baseline = try XCTUnwrap(data.baseline)
        XCTAssertEqual(rows(baseline, value: 1), ["Tools": 170, "Toys": 220])
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 30, "Toys": nil])
        XCTAssertEqual(rows(data.table, value: 2), ["Tools": 10, "Toys": nil])
        XCTAssertEqual(data.table.rowCount, 2)
    }

    func testHighlightCombinesWithFiltersAndSeveralSelections() throws {
        let byCategory = visual(.clusteredColumn, [.category: [category], .values: [amount]])
        var march = FilterSpec(field: .column("Sales", "Date"), kind: .relativeDate)
        march.relative.direction = .this; march.relative.unit = .months
        // March only: Tools 10 + 40 + 20 = 70, Toys 90 + 20 + 30 = 140. Highlighting East and red
        // products (two selections intersect): Widget East 10 and Gizmo East 30.
        let east = [DataPointSelection(fields: [region], values: ["East"])]
        let red = [DataPointSelection(fields: [.column("Product", "Color")], values: ["Red"])]
        let data = run(byCategory, request(filters: [march], highlights: [east, red]))
        XCTAssertEqual(rows(try XCTUnwrap(data.baseline), value: 1), ["Tools": 70, "Toys": 140])
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 10, "Toys": 30])
    }

    func testHighlightOnAVisualWithoutGroupsFilters() {
        let east = [DataPointSelection(fields: [region], values: ["East"])]
        let data = run(visual(.card, [.values: [amount]]), request(highlights: [east]))
        XCTAssertEqual(data.table[0, 0].asDouble, 160)
        XCTAssertNil(data.baseline)
    }

    // MARK: Drill

    private func hierarchy(level: Int = 0, path: [Value] = [], expanded: Bool = false) -> VisualSpec {
        var spec = visual(.clusteredColumn, [.category: [category, product], .values: [amount]])
        spec.drillLevel = level; spec.drillPath = path; spec.expandedAllLevels = expanded
        return spec
    }

    func testUndrilledHierarchyShowsTheFirstLevel() {
        let data = run(hierarchy())
        XCTAssertEqual(data.indices(.category), [0])
        XCTAssertEqual(data.fields.first??.name, "Category")
        XCTAssertEqual(rows(data.table, value: 1), ["Tools": 170, "Toys": 220])
    }

    func testDrillDownIntoAPoint() {
        let data = run(hierarchy(level: 1, path: ["Tools"]))
        XCTAssertEqual(data.indices(.category), [0])
        XCTAssertEqual(data.fields.first??.name, "Product")
        XCTAssertEqual(rows(data.table, value: 1), ["Widget": 30, "Gadget": 140])
        // Totals are those of the drilled-into member.
        XCTAssertEqual(data.totals[1].asDouble, 170)
        XCTAssertEqual(rows(run(hierarchy(level: 1, path: ["Toys"])).table, value: 1), ["Gizmo": 120, "Doohickey": 100])
    }

    func testGoToNextLevelShowsEveryMember() {
        let data = run(hierarchy(level: 1))
        XCTAssertEqual(data.fields.first??.name, "Product")
        XCTAssertEqual(rows(data.table, value: 1), ["Widget": 30, "Gadget": 140, "Gizmo": 120, "Doohickey": 100])
        XCTAssertEqual(data.totals[1].asDouble, 390)
    }

    func testExpandAllShowsBothLevels() {
        let data = run(hierarchy(level: 1, expanded: true))
        XCTAssertEqual(data.indices(.category), [0, 1])
        XCTAssertEqual(data.indices(.values), [2])
        XCTAssertEqual(rows(data.table, keys: 2, value: 2),
                       ["Tools/Widget": 30, "Tools/Gadget": 140, "Toys/Gizmo": 120, "Toys/Doohickey": 100])
    }

    func testDrillPlan() {
        // The level is clamped to the hierarchy.
        XCTAssertEqual(LiveCalculation.drillPlan(hierarchy(level: 9)).category.map(\.name), ["Product"])
        XCTAssertEqual(LiveCalculation.drillPlan(hierarchy(level: -1)).category.map(\.name), ["Category"])
        let drilled = LiveCalculation.drillPlan(hierarchy(level: 1, path: ["Tools"]))
        XCTAssertEqual(drilled.path.map(\.field.name), ["Category"])
        XCTAssertEqual(drilled.path.map(\.value), ["Tools"])
        // A single field has nothing to drill, whatever the stored state says.
        var single = visual(.clusteredColumn, [.category: [category], .values: [amount]])
        single.drillLevel = 1
        XCTAssertEqual(LiveCalculation.drillPlan(single).category.map(\.name), ["Category"])
        XCTAssertTrue(LiveCalculation.drillPlan(single).path.isEmpty)
        // A sunburst draws every level at once.
        let sunburst = visual(.sunburst, [.category: [category, product], .values: [amount]])
        XCTAssertEqual(LiveCalculation.drillPlan(sunburst).category.map(\.name), ["Category", "Product"])
    }

    func testDrillWithFiltersAndHighlight() throws {
        let east = [DataPointSelection(fields: [region], values: ["East"])]
        let data = run(hierarchy(level: 1, path: ["Toys"]), request(highlights: [east]))
        XCTAssertEqual(rows(try XCTUnwrap(data.baseline), value: 1), ["Gizmo": 120, "Doohickey": 100])
        XCTAssertEqual(rows(data.table, value: 1), ["Gizmo": 30, "Doohickey": 80])
    }

    // MARK: Visual calculations

    func testVisualCalculationsUseRealSubtotals() {
        var matrix = visual(.matrix, [.rows: [category, product], .values: [price, amount]])
        var share = VisualCalculation(name: "Price vs category", expression: "DIVIDE([Avg Price], COLLAPSE([Avg Price], ROWS))")
        share.formatString = "0%"
        matrix.visualCalculations = [
            share,
            VisualCalculation(name: "Share of total", expression: "DIVIDE([Total Amount], COLLAPSEALL([Total Amount], ROWS))"),
            VisualCalculation(name: "Category amount", expression: "LOOKUPWITHTOTALS([Total Amount], [Category], [Category])"),
            VisualCalculation(name: "Doubled share", expression: "[Share of total] * 2"),
        ]
        let data = run(matrix)
        XCTAssertEqual(data.table.columnNames.suffix(4), ["Price vs category", "Share of total", "Category amount", "Doubled share"])
        XCTAssertEqual(data.formats.suffix(4), ["0%", "", "", ""])
        XCTAssertEqual(data.fields.suffix(4).map { $0 == nil }, [true, true, true, true])
        // The category's own average price (Tools 17, Toys 220/9) is the parent, not the sum of its products' averages.
        let ratio = rows(data.table, keys: 2, value: 4)
        XCTAssertEqual(number(ratio, "Tools/Widget"), 10.0 / 17.0, accuracy: 1e-12)
        XCTAssertEqual(number(ratio, "Tools/Gadget"), 20.0 / 17.0, accuracy: 1e-12)
        XCTAssertEqual(number(ratio, "Toys/Gizmo"), 30.0 / (220.0 / 9.0), accuracy: 1e-12)
        XCTAssertEqual(number(ratio, "Toys/Doohickey"), 20.0 / (220.0 / 9.0), accuracy: 1e-12)
        let share2 = rows(data.table, keys: 2, value: 5)
        XCTAssertEqual(number(share2, "Tools/Gadget"), 140.0 / 390.0, accuracy: 1e-12)
        XCTAssertEqual(rows(data.table, keys: 2, value: 6),
                       ["Tools/Widget": 170, "Tools/Gadget": 170, "Toys/Gizmo": 220, "Toys/Doohickey": 220])
        // A calculation can use an earlier one.
        XCTAssertEqual(number(rows(data.table, keys: 2, value: 7), "Tools/Gadget"), 280.0 / 390.0, accuracy: 1e-12)
    }

    func testAlignedRelaysValuesOnTheShapeRows() {
        let shape = DataTable(name: "", columnNames: ["K", "V"], rows: [["a", 1], ["b", 2], ["c", 3]])
        let source = DataTable(name: "", columnNames: ["K", "V"], rows: [["c", 30], ["a", 10]])
        let out = LiveCalculation.aligned(source, to: shape, keys: 1)
        XCTAssertEqual(out.columns[0].values, ["a", "b", "c"])
        XCTAssertEqual(out.columns[1].values, [10, .null, 30])
    }
}
