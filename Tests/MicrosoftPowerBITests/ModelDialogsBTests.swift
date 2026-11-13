import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Calculation groups, functions, incremental refresh, aggregations, perspectives, translations, synonyms and AI prep.
@MainActor
final class ModelDialogsBTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date { DialogFixture.day(y, m, d, hour: hour) }

    // MARK: Calculation groups

    func testCalculationGroupDefaultsAndValidation() {
        let model = DialogFixture.model()
        let first = CalculationGroupLogic.make(model: model, alongside: [])
        XCTAssertEqual(first.name, "Calculation group")
        XCTAssertEqual(first.precedence, 0)
        XCTAssertEqual(first.items.map(\.name), ["Current"])
        XCTAssertEqual(first.items.first?.expression, "SELECTEDMEASURE()")
        let second = CalculationGroupLogic.make(model: model, alongside: [first])
        XCTAssertEqual(second.name, "Calculation group 2")
        XCTAssertEqual(second.precedence, 1)
        XCTAssertEqual(CalculationGroupLogic.makeItem(in: first).name, "Calculation item")
        XCTAssertEqual(CalculationGroupLogic.problems([first, second], model: model), [])
        XCTAssertNil(CalculationGroupLogic.precedenceWarning([first, second]))

        var g = first
        g.name = "sales"
        XCTAssertEqual(CalculationGroupLogic.problems([g], model: model), ["A table named “sales” already exists."])
        g = first; g.items = []
        XCTAssertEqual(CalculationGroupLogic.problems([g], model: model), ["“Calculation group” needs at least one calculation item."])
        g = first; g.items.append(CalculationItem(name: "current", expression: "1"))
        XCTAssertEqual(CalculationGroupLogic.problems([g], model: model), ["In “Calculation group”: Another calculation item is already named “Current”."])
        g = first; g.items[0].expression = "  "
        XCTAssertEqual(CalculationGroupLogic.problems([g], model: model), ["“Current” in “Calculation group” needs an expression."])
        g = first; g.columnName = " "
        XCTAssertEqual(CalculationGroupLogic.problems([g], model: model), ["Name the column of “Calculation group”."])
        var twin = second; twin.name = "Calculation Group"
        XCTAssertEqual(CalculationGroupLogic.problems([first, twin], model: model), ["Another calculation group is already named “Calculation group”."])
        twin = second; twin.precedence = 0
        XCTAssertNotNil(CalculationGroupLogic.precedenceWarning([first, twin]))
    }

    func testCalculationItemsAreNumberedInListOrder() {
        var g = CalculationGroup(name: " Time ")
        var a = CalculationItem(name: " YTD ", expression: "1"); a.ordinal = 7; a.formatExpression = "  "
        var b = CalculationItem(name: "PY", expression: "2"); b.ordinal = 3; b.formatExpression = "\"0%\""
        g.items = [a, b]
        let n = CalculationGroupLogic.normalized([g])[0]
        XCTAssertEqual(n.name, "Time")
        XCTAssertEqual(n.items.map(\.name), ["YTD", "PY"])
        XCTAssertEqual(n.items.map(\.ordinal), [0, 1])
        XCTAssertNil(n.items[0].formatExpression)
        XCTAssertEqual(n.items[1].formatExpression, "\"0%\"")
    }

    func testTimeIntelligenceItems() {
        let items = CalculationGroupLogic.timeIntelligenceItems(dateTable: "Date", dateColumn: "Date", existing: [])
        XCTAssertEqual(items.map(\.name), ["Current", "YTD", "PY", "YoY", "YoY %"])
        XCTAssertEqual(items[1].expression, "CALCULATE(SELECTEDMEASURE(), DATESYTD('Date'[Date]))")
        XCTAssertEqual(items[2].expression, "CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR('Date'[Date]))")
        XCTAssertEqual(items[4].formatExpression, "\"0.0%\"")
        let fewer = CalculationGroupLogic.timeIntelligenceItems(dateTable: "Date", dateColumn: "Date", existing: [CalculationItem(name: "ytd", expression: "1")])
        XCTAssertEqual(fewer.map(\.name), ["Current", "PY", "YoY", "YoY %"])
    }

    func testACalculationItemRewritesAMeasureInTheEngine() throws {
        var model = DialogFixture.model()
        var g = CalculationGroup(name: "Scale")
        g.columnName = "Calculation item"
        g.items = [CalculationItem(name: "Current", expression: "SELECTEDMEASURE()"),
                   CalculationItem(name: "Double", expression: "SELECTEDMEASURE() * 2")]
        model.calculationGroups = CalculationGroupLogic.normalized([g])
        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        XCTAssertEqual(engine.data["Scale"]?.column("Calculation item")?.values, [.string("Current"), .string("Double")])
        func total(_ item: String) throws -> Double? {
            try engine.query("EVALUATE ROW(\"v\", CALCULATE([Total], 'Scale'[Calculation item] = \"\(item)\"))").first?.columns.first?.values.first?.asDouble
        }
        XCTAssertEqual(try total("Current"), 100)      // 10 + 20 + 30 + 40
        XCTAssertEqual(try total("Double"), 200)
    }

    // MARK: Functions

    func testFunctionNamesAndSignature() {
        XCTAssertTrue(FunctionLogic.isIdentifier("AddTax", allowsPeriods: true))
        XCTAssertTrue(FunctionLogic.isIdentifier("Finance.Add_Tax2", allowsPeriods: true))
        XCTAssertFalse(FunctionLogic.isIdentifier("Finance.AddTax", allowsPeriods: false))
        XCTAssertFalse(FunctionLogic.isIdentifier("2x", allowsPeriods: true))
        XCTAssertFalse(FunctionLogic.isIdentifier("Add Tax", allowsPeriods: true))
        XCTAssertFalse(FunctionLogic.isIdentifier("", allowsPeriods: true))
        XCTAssertFalse(FunctionLogic.isIdentifier("A..B", allowsPeriods: true))
        XCTAssertFalse(FunctionLogic.isIdentifier("A.", allowsPeriods: true))

        var rate = FunctionParameter(name: "rate"); rate.type = "double"; rate.defaultExpression = "0.1"
        var rows = FunctionParameter(name: "rows"); rows.type = "table"; rows.mode = "expr"
        let f = UserFunction(name: "AddTax", parameters: [FunctionParameter(name: "amount"), rate, rows], expression: "amount * (1 + rate)")
        XCTAssertEqual(FunctionLogic.signature(f), "(amount, rate : double val = 0.1, rows : table expr)")
        XCTAssertEqual(FunctionLogic.signature(UserFunction(name: "Pi", expression: "3.14")), "()")
        XCTAssertEqual(FunctionLogic.make(alongside: [UserFunction(name: "newfunction", expression: "1")]).name, "NewFunction2")
        XCTAssertEqual(FunctionLogic.makeParameter(in: f).name, "p4")
    }

    func testFunctionValidation() {
        func f(_ name: String, _ params: [FunctionParameter] = [], body: String = "1") -> UserFunction { UserFunction(name: name, parameters: params, expression: body) }
        func p(_ name: String, default d: String? = nil) -> FunctionParameter { var p = FunctionParameter(name: name); p.defaultExpression = d; return p }
        XCTAssertEqual(FunctionLogic.problems([f("AddTax", [p("a"), p("b", default: "0")])], builtIns: ["SUM"]), [])
        XCTAssertEqual(FunctionLogic.problems([f("sum")], builtIns: ["SUM"]), ["“sum” is a built-in DAX function. Choose another name."])
        XCTAssertEqual(FunctionLogic.problems([f("")]), ["Name the function."])
        XCTAssertEqual(FunctionLogic.problems([f("A"), f("a")]), ["Another function is already named “A”."])
        XCTAssertEqual(FunctionLogic.problems([f("Add Tax")]).count, 1)
        XCTAssertEqual(FunctionLogic.problems([f("F", body: " ")]), ["“F” needs a body."])
        XCTAssertEqual(FunctionLogic.problems([f("F", [p("a", default: "1"), p("b")])]),
                       ["In “F”, “b” has no default but follows an optional parameter. Optional parameters go last."])
        XCTAssertEqual(FunctionLogic.problems([f("F", [p("a"), p("A")])]), ["“F” has two parameters named “A”."])
        XCTAssertEqual(FunctionLogic.problems([f("F", [p("")])]), ["Name every parameter of “F”."])
        XCTAssertEqual(FunctionLogic.problems([f("F", [p("my rate")])]), ["“my rate” isn't a valid parameter name in “F”."])
        XCTAssertEqual(FunctionLogic.problems([f("F", (1...256).map { p("p\($0)") })]), [])
        XCTAssertEqual(FunctionLogic.problems([f("F", (1...257).map { p("p\($0)") })]), ["“F” has more than 256 parameters."])
        var blank = f(" F ", [p(" a ", default: "  ")])
        blank = FunctionLogic.normalized([blank])[0]
        XCTAssertEqual(blank.name, "F")
        XCTAssertEqual(blank.parameters[0].name, "a")
        XCTAssertNil(blank.parameters[0].defaultExpression)
    }

    func testAFunctionWithADefaultRunsInTheEngine() throws {
        var model = DialogFixture.model()
        var rate = FunctionParameter(name: "rate"); rate.defaultExpression = "0.1"
        model.functions = [UserFunction(name: "AddTax", parameters: [FunctionParameter(name: "amount"), rate], expression: "amount * (1 + rate)")]
        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        XCTAssertEqual(try XCTUnwrap(engine.scalar("AddTax(100)", filters: []).asDouble), 110, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(engine.scalar("AddTax(100, 0.2)", filters: []).asDouble), 120, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(engine.scalar("AddTax([Total], 0.5)", filters: []).asDouble), 150, accuracy: 1e-9)
    }

    // MARK: Incremental refresh

    func testIncrementalRefreshValidation() throws {
        let sales = try XCTUnwrap(DialogFixture.model().table("Sales"))
        var p = IncrementalRefreshPolicy(dateColumn: "OrderDate")           // 5 years archived, 10 days refreshed
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), [])
        p.dateColumn = "Region"
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), ["Region is text. The partition column must be Date or Date/Time."])
        p.dateColumn = "Shipped"
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), ["“Shipped” is not a column of Sales."])
        p.dateColumn = ""
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), ["Choose the date column that partitions Sales."])
        p.dateColumn = "OrderDate"; p.archiveCount = 0
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), ["Archive at least 1 year."])
        p.archiveCount = 1; p.archiveUnit = "month"; p.refreshCount = 60; p.refreshUnit = "day"   // 60 days against one month
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), ["The refresh period can't be longer than the archive period."])
        p.refreshCount = 30
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), [])
        p.detectChangesColumn = "Amount"
        XCTAssertEqual(IncrementalRefreshLogic.problems(p, table: sales), ["Detect data changes needs a Date/Time column; Amount is decimal number."])
        p.detectChangesColumn = ""
        XCTAssertNil(IncrementalRefreshLogic.normalized(p).detectChangesColumn)
        p.realTimeDirectQuery = true
        XCTAssertTrue(IncrementalRefreshLogic.normalized(p).onlyCompletePeriods)

        var calculated = sales
        calculated.expression = "FILTER(Sales, TRUE())"
        XCTAssertEqual(IncrementalRefreshLogic.problems(IncrementalRefreshPolicy(dateColumn: "OrderDate"), table: calculated).count, 1)
    }

    func testRefreshWindows() {
        let now = day(2026, 11, 13, hour: 10)
        var p = IncrementalRefreshPolicy(dateColumn: "OrderDate")           // archive 5 years, refresh 10 days
        var w = IncrementalRefreshLogic.windows(p, now: now)
        XCTAssertEqual(w.end, day(2026, 11, 14))                            // today is included
        XCTAssertEqual(w.refreshStart, day(2026, 11, 4))                    // 4…13 November is ten days
        XCTAssertEqual(w.archiveStart, day(2021, 1, 1))                     // five whole years before 2026
        p.onlyCompletePeriods = true
        w = IncrementalRefreshLogic.windows(p, now: now)
        XCTAssertEqual(w.end, day(2026, 11, 13))
        XCTAssertEqual(w.refreshStart, day(2026, 11, 3))

        p.refreshCount = 3; p.refreshUnit = "month"; p.archiveCount = 2; p.archiveUnit = "year"
        w = IncrementalRefreshLogic.windows(p, now: now)
        XCTAssertEqual(w.end, day(2026, 11, 1))                             // November is not complete
        XCTAssertEqual(w.refreshStart, day(2026, 8, 1))
        XCTAssertEqual(w.archiveStart, day(2024, 1, 1))

        p.onlyCompletePeriods = false; p.refreshCount = 1; p.refreshUnit = "quarter"; p.archiveCount = 4; p.archiveUnit = "quarter"
        w = IncrementalRefreshLogic.windows(p, now: now)
        XCTAssertEqual(w.end, day(2027, 1, 1))
        XCTAssertEqual(w.refreshStart, day(2026, 10, 1))
        XCTAssertEqual(w.archiveStart, day(2025, 10, 1))
    }

    func testRangeParametersAndFilterStep() {
        XCTAssertEqual(IncrementalRefreshLogic.missingParameters([]), ["RangeStart", "RangeEnd"])
        let start = IncrementalRefreshLogic.parameterQuery("RangeStart", value: day(2026, 11, 4))
        XCTAssertEqual(start.kind, .parameter)
        XCTAssertFalse(start.loadEnabled)
        XCTAssertEqual(start.parameter?.type, .dateTime)
        XCTAssertEqual(start.mScript, "#datetime(2026, 11, 4, 0, 0, 0) meta [IsParameterQuery=true, Type=\"DateTime\", IsParameterQueryRequired=true]")
        XCTAssertEqual(IncrementalRefreshLogic.missingParameters([start]), ["RangeEnd"])
        // A table that happens to be called RangeEnd is not the parameter.
        XCTAssertEqual(IncrementalRefreshLogic.missingParameters([start, QueryDefinition(name: "RangeEnd", mScript: "#table({}, {})")]), ["RangeEnd"])
        XCTAssertEqual(IncrementalRefreshLogic.missingParameters([start, IncrementalRefreshLogic.parameterQuery("rangeend", value: day(2026, 11, 14))]), [])

        XCTAssertEqual(IncrementalRefreshLogic.filterStep(column: "OrderDate"),
                       "Table.SelectRows(Source, each [OrderDate] >= RangeStart and [OrderDate] < RangeEnd)")
        XCTAssertTrue(IncrementalRefreshLogic.queryUsesRange("each [D] >= RangeStart and [D] < RangeEnd"))
        XCTAssertFalse(IncrementalRefreshLogic.queryUsesRange("each [D] >= RangeStart"))
    }

    // MARK: Aggregations

    private func aggregationModel() -> SemanticModel {
        var model = DialogFixture.model()
        model.tables.append(ModelTable(name: "SalesAgg", columns: [
            ModelColumn(name: "ProductID", dataType: .integer), ModelColumn(name: "AmountSum", dataType: .decimal),
            ModelColumn(name: "Rows", dataType: .integer), ModelColumn(name: "Label", dataType: .text),
        ]))
        return model
    }

    func testAggregationMappings() throws {
        var model = aggregationModel()
        let agg = try XCTUnwrap(model.table("SalesAgg"))
        var rows = AggregationLogic.rows(for: agg, model: model)
        XCTAssertEqual(rows.map(\.column), ["ProductID", "AmountSum", "Rows", "Label"])
        XCTAssertTrue(rows.allSatisfy { $0.summarization == .none })
        XCTAssertEqual(AggregationLogic.problems(rows, aggTable: agg, model: model), [])

        rows[0] = .init(column: "ProductID", summarization: .groupBy, detailTable: "Sales", detailColumn: "ProductID")
        rows[1] = .init(column: "AmountSum", summarization: .sum, detailTable: "Sales", detailColumn: "Amount")
        rows[2] = .init(column: "Rows", summarization: .countRows, detailTable: "Sales", detailColumn: "ignored")
        XCTAssertEqual(AggregationLogic.problems(rows, aggTable: agg, model: model), [])
        let mappings = AggregationLogic.mappings(from: rows, aggTable: "SalesAgg")
        XCTAssertEqual(mappings.map(\.aggColumn), ["ProductID", "AmountSum", "Rows"])
        XCTAssertEqual(mappings.map(\.summarization), [Aggregation.none, .sum, .count])
        XCTAssertEqual(mappings.map(\.detailColumn), ["ProductID", "Amount", ""])
        XCTAssertEqual(mappings.map(AggregationLogic.summarization(of:)), [.groupBy, .sum, .countRows])

        AggregationLogic.apply(rows, aggTable: "SalesAgg", to: &model)
        XCTAssertEqual(model.aggregations.count, 3)
        XCTAssertEqual(model.table("SalesAgg")?.isHidden, true)
        // Reopening shows what was saved; applying again replaces rather than appends.
        let reopened = AggregationLogic.rows(for: try XCTUnwrap(model.table("SalesAgg")), model: model)
        XCTAssertEqual(reopened.map(\.summarization), [.groupBy, .sum, .countRows, .none])
        AggregationLogic.apply(Array(reopened.prefix(1)), aggTable: "SalesAgg", to: &model)
        XCTAssertEqual(model.aggregations.map(\.aggColumn), ["ProductID"])
    }

    func testAggregationValidation() throws {
        var model = aggregationModel()
        let agg = try XCTUnwrap(model.table("SalesAgg"))
        func problems(_ row: AggregationLogic.Row) -> [String] { AggregationLogic.problems([row], aggTable: agg, model: model) }
        XCTAssertEqual(problems(.init(column: "AmountSum", summarization: .sum, detailTable: "Sales", detailColumn: "OrderID")),
                       ["AmountSum is decimal number but Sales[OrderID] is whole number. Sum needs matching data types."])
        XCTAssertEqual(problems(.init(column: "AmountSum", summarization: .count, detailTable: "Sales", detailColumn: "Region")),
                       ["AmountSum must be a whole number to hold a count."])
        XCTAssertEqual(problems(.init(column: "Rows", summarization: .count, detailTable: "Sales", detailColumn: "Region")), [])
        XCTAssertEqual(problems(.init(column: "Label", summarization: .countRows, detailTable: "Sales")), ["Label must be a whole number to count table rows."])
        XCTAssertEqual(problems(.init(column: "Label", summarization: .sum, detailTable: "Sales", detailColumn: "Region")),
                       ["Sum needs a number column; Label is text."])
        XCTAssertEqual(problems(.init(column: "Label", summarization: .max, detailTable: "Sales", detailColumn: "Region")), [])
        XCTAssertEqual(problems(.init(column: "Label", summarization: .groupBy, detailTable: "", detailColumn: "")), ["Choose a detail table for Label."])
        XCTAssertEqual(problems(.init(column: "Label", summarization: .groupBy, detailTable: "Sales", detailColumn: "")), ["Choose a detail column for Label."])
        XCTAssertEqual(problems(.init(column: "Label", summarization: .groupBy, detailTable: "SalesAgg", detailColumn: "Label")),
                       ["SalesAgg can't aggregate itself. Choose another detail table."])
        XCTAssertEqual(AggregationLogic.problems([
            .init(column: "ProductID", summarization: .groupBy, detailTable: "Sales", detailColumn: "ProductID"),
            .init(column: "Label", summarization: .groupBy, detailTable: "Product", detailColumn: "Name"),
        ], aggTable: agg, model: model), ["All rows must map to the same detail table."])
        XCTAssertEqual(AggregationLogic.problems([
            .init(column: "ProductID", summarization: .min, detailTable: "Sales", detailColumn: "ProductID"),
            .init(column: "Rows", summarization: .min, detailTable: "Sales", detailColumn: "ProductID"),
        ], aggTable: agg, model: model), ["Two columns map the same summarization of the same detail column."])
        // Sales is itself an aggregation of something: it can't also be a detail table.
        model.aggregations = [AggregationMapping(aggTable: "Sales", aggColumn: "Amount", summarization: .sum, detailTable: "Product", detailColumn: "ProductID")]
        XCTAssertEqual(problems(.init(column: "ProductID", summarization: .groupBy, detailTable: "Sales", detailColumn: "ProductID")),
                       ["Sales is itself an aggregation table. Aggregations can't be chained."])
    }

    // MARK: Perspectives

    func testPerspectiveMembership() throws {
        let model = DialogFixture.model()
        let product = try XCTUnwrap(model.table("Product"))
        XCTAssertEqual(PerspectiveLogic.members(of: product), ["Product[ProductID]", "Product[Name]", "Product[Category]"])
        XCTAssertEqual(PerspectiveLogic.inclusion(of: product, in: []), .none)
        XCTAssertEqual(PerspectiveLogic.inclusion(of: product, in: ["product"]), .all)
        XCTAssertEqual(PerspectiveLogic.inclusion(of: product, in: ["Product[Name]"]), .some)
        XCTAssertEqual(PerspectiveLogic.inclusion(of: product, in: PerspectiveLogic.members(of: product)), .all)
        XCTAssertTrue(PerspectiveLogic.isIncluded("Product[Name]", in: ["Product"]))
        XCTAssertFalse(PerspectiveLogic.isIncluded("Product[Name]", in: ["Product[Category]", "Sales"]))

        var members = PerspectiveLogic.toggle("Product[Name]", in: [], model: model)
        XCTAssertEqual(members, ["Product[Name]"])
        members = PerspectiveLogic.toggle("Product", in: members, model: model)           // partly included → all
        XCTAssertEqual(members, ["Product"])
        members = PerspectiveLogic.toggle("Product[Name]", in: members, model: model)     // remove one field from a whole table
        XCTAssertEqual(members, ["Product[ProductID]", "Product[Category]"])
        XCTAssertEqual(PerspectiveLogic.state(of: "Product", in: members, model: model), .some)
        XCTAssertEqual(PerspectiveLogic.state(of: "Product[Name]", in: members, model: model), PerspectiveLogic.Inclusion.none)
        members = PerspectiveLogic.toggle("Product", in: members, model: model)
        members = PerspectiveLogic.toggle("Product", in: members, model: model)           // all → none
        XCTAssertEqual(members, [])
        XCTAssertEqual(PerspectiveLogic.toggle("Nowhere[X]", in: ["Sales"], model: model), ["Sales"])

        var p = Perspective(name: " Finance ")
        p.members = ["Sales", "Product[Name]", "Product[Colour]", "Gone"]
        let cleaned = PerspectiveLogic.cleaned([p], model: model)[0]
        XCTAssertEqual(cleaned.name, "Finance")
        XCTAssertEqual(cleaned.members, ["Sales", "Product[Name]"])
        XCTAssertEqual(PerspectiveLogic.problems([Perspective(name: "A"), Perspective(name: "a"), Perspective(name: "")]),
                       ["Another perspective is already named “A”.", "Name the perspective."])
    }

    // MARK: Translations

    func testCultures() {
        for tag in ["fr", "fr-FR", "pt-BR", "zh-Hans-CN", "fil-PH"] { XCTAssertTrue(TranslationLogic.isCultureTag(tag), tag) }
        for tag in ["", "f", "french!", "fr_FR", "fr-", "1a-BR", "fr-F"] { XCTAssertFalse(TranslationLogic.isCultureTag(tag), tag) }
        XCTAssertEqual(TranslationLogic.canonical(" PT-br "), "pt-BR")
        XCTAssertEqual(TranslationLogic.canonical("ZH-hans-cn"), "zh-Hans-CN")
        XCTAssertEqual(TranslationLogic.displayName("fr-FR"), "French (France)")
        XCTAssertNil(TranslationLogic.cultureProblem("fr-fr", existing: ["de-DE"], modelCulture: "en-US"))
        XCTAssertEqual(TranslationLogic.cultureProblem("fr-fr", existing: ["fr-FR"], modelCulture: "en-US"), "fr-FR has already been added.")
        XCTAssertEqual(TranslationLogic.cultureProblem("en-us", existing: [], modelCulture: "en-US"), "en-US is the model's own language; its names are the captions.")
        XCTAssertEqual(TranslationLogic.cultureProblem("French", existing: [], modelCulture: "en-US"), "“French” isn't a culture. Use a language tag such as fr-FR or pt-BR.")
        XCTAssertEqual(TranslationLogic.cultureProblem("  ", existing: [], modelCulture: "en-US"), "Enter a culture such as fr-FR.")
    }

    func testCaptions() {
        var model = DialogFixture.model()
        model.tables[1].hierarchies = [Hierarchy(name: "Products", levels: ["Category", "Name"])]
        let objects = TranslationLogic.objects(model)
        // Sales: itself, 5 columns, 1 measure. Product: itself, 3 columns, 1 hierarchy. Date: itself, 3 columns.
        XCTAssertEqual(objects.count, 16)
        XCTAssertEqual(objects.first?.identifier, "Sales")
        XCTAssertEqual(objects.filter { $0.kind == .measure }.map(\.identifier), ["Sales[Total]"])
        XCTAssertEqual(objects.filter { $0.kind == .hierarchy }.map(\.identifier), ["Product[Products]"])

        var fr = Translation(culture: "FR-fr")
        TranslationLogic.set(" Ventes ", for: "Sales", in: &fr)
        TranslationLogic.set("Montant", for: "Sales[Amount]", in: &fr)
        TranslationLogic.set("Disparu", for: "Sales[Gone]", in: &fr)
        XCTAssertEqual(TranslationLogic.caption("sales", in: fr), "Ventes")
        XCTAssertEqual(TranslationLogic.coverage(fr, objects: objects).translated, 2)
        XCTAssertEqual(TranslationLogic.coverage(fr, objects: objects).total, 16)
        TranslationLogic.set("", for: "SALES", in: &fr)                                   // clearing removes the entry
        XCTAssertEqual(fr.captions.keys.sorted(), ["Sales[Amount]", "Sales[Gone]"])
        let cleaned = TranslationLogic.cleaned([fr], model: model)[0]
        XCTAssertEqual(cleaned.culture, "fr-FR")
        XCTAssertEqual(cleaned.captions, ["Sales[Amount]": "Montant"])

        XCTAssertNil(TranslationLogic.duplicateCaptions(fr, objects: objects))
        TranslationLogic.set("montant", for: "Sales[Region]", in: &fr)
        XCTAssertEqual(TranslationLogic.duplicateCaptions(fr, objects: objects),
                       "In FR-fr, “Amount” and “Region” in Sales would both be shown as “montant”.")
        // The same caption in different tables is fine.
        var de = Translation(culture: "de-DE")
        TranslationLogic.set("Nummer", for: "Sales[ProductID]", in: &de)
        TranslationLogic.set("Nummer", for: "Product[ProductID]", in: &de)
        XCTAssertNil(TranslationLogic.duplicateCaptions(de, objects: objects))
    }

    // MARK: Synonyms

    func testSynonyms() throws {
        XCTAssertEqual(SynonymLogic.parse("rev, turnover; Revenue ,rev,, Total\nincome", ownName: "Total"), ["rev", "turnover", "Revenue", "income"])
        XCTAssertEqual(SynonymLogic.parse("  ,; "), [])

        var model = DialogFixture.model()
        var terms = SynonymLogic.terms(model)
        XCTAssertEqual(terms.count, 15)                                 // 3 tables, 11 columns, 1 measure
        func term(_ id: String) throws -> SynonymLogic.Term { try XCTUnwrap(terms.first { $0.identifier == id }) }
        SynonymLogic.set(["orders"], for: try term("Sales"), in: &model)
        SynonymLogic.set(["revenue"], for: try term("Sales[Amount]"), in: &model)
        SynonymLogic.set(["Revenue", "turnover"], for: try term("Sales[Total]"), in: &model)
        XCTAssertEqual(model.table("Sales")?.synonyms, ["orders"])
        XCTAssertEqual(model.table("Sales")?.column("Amount")?.synonyms, ["revenue"])
        XCTAssertEqual(model.qnaSynonyms, ["Sales[Total]": ["Revenue", "turnover"]])

        terms = SynonymLogic.terms(model)
        XCTAssertEqual(try term("Sales[Total]").synonyms, ["Revenue", "turnover"])
        let conflicts = SynonymLogic.conflicts(terms)
        XCTAssertEqual(conflicts.map { $0.word.lowercased() }, ["revenue"])
        XCTAssertEqual(conflicts.first?.objects, ["Sales[Amount]", "Sales[Total]"])
        // ProductID is a column of two tables, but nobody made it a synonym: not reported.
        XCTAssertFalse(conflicts.contains { $0.word.lowercased() == "productid" })
        // A synonym that is another field's own name is ambiguous too.
        SynonymLogic.set(["Category"], for: try term("Product[Name]"), in: &model)
        XCTAssertTrue(SynonymLogic.conflicts(SynonymLogic.terms(model)).contains { $0.word == "Category" && $0.objects == ["Product[Name]", "Product[Category]"] })

        SynonymLogic.set([], for: try term("Sales[Total]"), in: &model)
        XCTAssertEqual(model.qnaSynonyms, [:])
        model.qnaSynonyms = ["Sales[Total]": ["net"], "Sales[Gone]": ["x"], "Sales[Amount]": []]
        XCTAssertEqual(SynonymLogic.pruned(model), ["Sales[Total]": ["net"]])
    }

    // MARK: Prep data for AI

    func testAIDataSchema() {
        let model = DialogFixture.model()
        XCTAssertTrue(AIPrepLogic.isIncluded("Sales[Amount]", excluded: []))
        var excluded = AIPrepLogic.toggle("Sales[Amount]", excluded: [], model: model)
        XCTAssertEqual(excluded, ["Sales[Amount]"])
        XCTAssertFalse(AIPrepLogic.isIncluded("Sales[Amount]", excluded: excluded))
        XCTAssertTrue(AIPrepLogic.isIncluded("Sales[Region]", excluded: excluded))
        XCTAssertEqual(AIPrepLogic.state(of: "Sales", excluded: excluded, model: model), .some)
        XCTAssertEqual(AIPrepLogic.state(of: "Sales[Amount]", excluded: excluded, model: model), PerspectiveLogic.Inclusion.none)
        XCTAssertEqual(AIPrepLogic.state(of: "Product", excluded: excluded, model: model), .all)
        excluded = AIPrepLogic.toggle("Sales", excluded: excluded, model: model)           // partly excluded → fully available
        XCTAssertEqual(excluded, [])
        excluded = AIPrepLogic.toggle("Sales", excluded: excluded, model: model)           // available → excluded as a whole
        XCTAssertEqual(excluded, ["Sales"])
        XCTAssertFalse(AIPrepLogic.isIncluded("Sales[Region]", excluded: excluded))
        XCTAssertEqual(AIPrepLogic.state(of: "Sales", excluded: excluded, model: model), PerspectiveLogic.Inclusion.none)
        excluded = AIPrepLogic.toggle("Sales", excluded: excluded, model: model)
        XCTAssertEqual(excluded, [])
    }

    func testVerifiedAnswersAndInstructions() {
        XCTAssertNil(AIPrepLogic.instructionsProblem(String(repeating: "a", count: 10_000)))
        XCTAssertNotNil(AIPrepLogic.instructionsProblem(String(repeating: "a", count: 10_001)))

        let visual = UUID()
        var good = VerifiedAnswer(question: " What were sales? ")
        good.visualID = visual
        XCTAssertEqual(AIPrepLogic.problems([good], visualIDs: [visual]), [])
        XCTAssertEqual(AIPrepLogic.cleaned([good])[0].question, "What were sales?")
        XCTAssertEqual(AIPrepLogic.problems([VerifiedAnswer(question: " ")], visualIDs: [visual]), ["Every verified answer needs a question."])
        XCTAssertEqual(AIPrepLogic.problems([VerifiedAnswer(question: "Top product?")], visualIDs: [visual]), ["Choose the visual that answers “Top product?”."])
        var stale = VerifiedAnswer(question: "Top product?")
        stale.visualID = UUID()
        XCTAssertEqual(AIPrepLogic.problems([stale], visualIDs: [visual]), ["The visual that answered “Top product?” was deleted. Choose another."])
        var twin = good
        twin.id = UUID(); twin.question = "what were sales?"
        XCTAssertEqual(AIPrepLogic.problems([good, twin], visualIDs: [visual]).count, 1)
    }
}
