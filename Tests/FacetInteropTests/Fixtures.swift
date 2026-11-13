import Foundation
import XCTest
import FacetCore
@testable import FacetInterop

enum Fixtures {
    /// A model exercising every FacetCore modelling feature.
    static func richModel() -> (SemanticModel, [QueryDefinition]) {
        var m = SemanticModel()
        m.name = "Contoso Sales"
        m.culture = "en-GB"
        m.autoDateTime = true
        m.aiInstructions = "Prefer fiscal periods.\nNever show cost."
        m.aiExcludedFields = ["Sales[Cost]"]
        m.qnaSynonyms = ["revenue": ["sales", "turnover"]]

        var sales = ModelTable(name: "Sales")
        sales.description = "Fact table.\n\nOne row per order line."
        var amount = ModelColumn(name: "Amount", dataType: .decimal)
        amount.formatString = "#,0.00"
        amount.description = "Line amount"
        var cost = ModelColumn(name: "Cost", dataType: .currency)
        cost.isHidden = true
        cost.summarizeBy = .median
        var custKey = ModelColumn(name: "Customer Key", dataType: .integer)
        custKey.summarizeBy = .none
        custKey.isNullable = false
        var orderDate = ModelColumn(name: "Order Date", dataType: .date)
        orderDate.formatString = "Short Date"
        orderDate.formatLocale = "en-GB"
        var margin = ModelColumn(name: "Margin %", dataType: .decimal, expression: "DIVIDE(Sales[Amount] - Sales[Cost], Sales[Amount])")
        margin.formatString = "0.0%"
        margin.displayFolder = "Calculated"
        var band = ModelColumn(name: "Amount (bins)", dataType: .decimal)
        var grouping = ColumnGrouping(kind: .binSize, sourceColumn: "Amount")
        grouping.binValue = 250
        band.grouping = grouping
        band.synonyms = ["bucket", "band"]
        sales.columns = [amount, cost, custKey, orderDate, margin, band]

        var total = Measure(name: "Total Sales", expression: "SUM(Sales[Amount])", formatString: "$#,0")
        total.description = "Sum of line amounts"
        total.displayFolder = "KPIs"
        var yoy = Measure(name: "YoY %", expression: """
        VAR Prev = CALCULATE([Total Sales], SAMEPERIODLASTYEAR('Date'[Date]))
        RETURN
            DIVIDE([Total Sales] - Prev, Prev)
        """)
        yoy.formatString = "0.0%"
        yoy.formatExpression = "IF([Total Sales] > 1000000, \"0.0%\", \"0.00%\")"
        var odd = Measure(name: "It's = odd: name", expression: "\n\t  1 + 1  \n")
        odd.isHidden = true
        odd.dataCategory = .webURL
        sales.measures = [total, yoy, odd]
        sales.sourceQuery = "Sales"
        sales.synonyms = ["orders"]
        sales.isFeatured = true
        var policy = IncrementalRefreshPolicy(dateColumn: "Order Date")
        policy.archiveCount = 3
        sales.incrementalRefresh = policy

        var customer = ModelTable(name: "Customer")
        var cKey = ModelColumn(name: "Customer Key", dataType: .integer)
        cKey.isKey = true
        var country = ModelColumn(name: "Country", dataType: .text)
        country.dataCategory = .country
        var city = ModelColumn(name: "City", dataType: .text)
        city.dataCategory = .city
        city.sortByColumn = "Country"
        var secret = ModelColumn(name: "Email", dataType: .text)
        secret.dataCategory = .webURL
        customer.columns = [cKey, country, city, secret]
        var geo = Hierarchy(name: "Geography", levels: ["Country", "City"])
        geo.isHidden = true
        customer.hierarchies = [geo]
        customer.sourceQuery = "Customer Source"
        customer.storageMode = .dual
        customer.rowLabelColumn = "City"
        customer.keyColumn = "Customer Key"

        var date = ModelTable(name: "Date")
        date.expression = "CALENDAR(DATE(2020, 1, 1), DATE(2026, 12, 31))"
        var d = ModelColumn(name: "Date", dataType: .dateTime)
        d.isKey = true
        date.columns = [d, ModelColumn(name: "Year", dataType: .integer)]
        date.dateColumn = "Date"
        var cal = CalendarDefinition(name: "Fiscal", columnsByUnit: ["year": "Year", "date": "Date"])
        cal.fiscalYearStartMonth = 7
        date.calendars = [cal]

        var live = ModelTable(name: "Remote 'Live' Table")
        live.storageMode = .live
        live.isHidden = true
        live.columns = [ModelColumn(name: "Any", dataType: .any), ModelColumn(name: "Dur", dataType: .duration),
                        ModelColumn(name: "T", dataType: .time), ModelColumn(name: "Flag", dataType: .boolean),
                        ModelColumn(name: "Blob", dataType: .binary)]
        m.tables = [sales, customer, date, live]

        var r1 = Relationship(fromTable: "Sales", fromColumn: "Customer Key", toTable: "Customer", toColumn: "Customer Key")
        r1.crossFilter = .both
        r1.securityFilterBothDirections = true
        var r2 = Relationship(fromTable: "Sales", fromColumn: "Order Date", toTable: "Date", toColumn: "Date")
        r2.isActive = false
        r2.assumeReferentialIntegrity = true
        var r3 = Relationship(fromTable: "Customer", fromColumn: "Country", toTable: "Remote 'Live' Table", toColumn: "Any")
        r3.cardinality = .manyToMany
        var r4 = Relationship(fromTable: "Date", fromColumn: "Year", toTable: "Sales", toColumn: "Amount")
        r4.cardinality = .oneToMany
        var r5 = Relationship(fromTable: "Date", fromColumn: "Date", toTable: "Customer", toColumn: "City")
        r5.cardinality = .oneToOne
        m.relationships = [r1, r2, r3, r4, r5]

        var cg = CalculationGroup(name: "Time Intelligence")
        cg.columnName = "Calculation"
        cg.precedence = 10
        var ytd = CalculationItem(name: "YTD", expression: "CALCULATE(SELECTEDMEASURE(), DATESYTD('Date'[Date]))")
        ytd.ordinal = 0
        var py = CalculationItem(name: "Prior Year", expression: "CALCULATE(\n    SELECTEDMEASURE(),\n    SAMEPERIODLASTYEAR('Date'[Date])\n)")
        py.ordinal = 1
        py.formatExpression = "\"#,0\""
        cg.items = [ytd, py]
        m.calculationGroups = [cg]

        var p1 = FunctionParameter(name: "amount")
        p1.type = "scalar"
        var p2 = FunctionParameter(name: "rate")
        p2.type = "anyref"; p2.mode = "expr"
        var fn = UserFunction(name: "AddTax", parameters: [p1, p2], expression: "amount * (1 + rate)")
        fn.description = "Adds tax"
        var p3 = FunctionParameter(name: "x")
        p3.defaultExpression = "0"
        let fn2 = UserFunction(name: "Twice", parameters: [p3], expression: "VAR y = x\nRETURN y * 2")
        m.functions = [fn, fn2]

        var west = SecurityRole(name: "Sales West")
        west.description = "Western region"
        west.tableFilters = ["Customer": "[Country] = \"US\"", "Sales": "Sales[Amount] > 0\n    && TRUE()"]
        west.hiddenTables = ["Remote 'Live' Table"]
        west.hiddenColumns = ["Sales[Cost]", "Customer[Email]"]
        let plain = SecurityRole(name: "Everyone")
        m.roles = [west, plain]

        var persp = Perspective(name: "Executive")
        persp.members = ["Sales", "Sales[Total Sales]", "Customer[Country]", "Customer[Geography]"]
        var mixed = Perspective(name: "Mixed order")
        mixed.members = ["Customer[City]", "Sales[Amount]", "Customer[Country]", "Date"]
        m.perspectives = [persp, mixed]

        var fr = Translation(culture: "fr-FR")
        fr.captions = ["Sales": "Ventes", "Sales[Amount]": "Montant", "Sales[Total Sales]": "Ventes totales",
                       "Customer[Geography]": "Géographie", "weird key": " padded "]
        let de = Translation(culture: "de-DE")
        m.translations = [fr, de]

        m.fieldParameters = [FieldParameter(name: "Metric", fields: [.measure("Sales", "Total Sales"), .column("Customer", "Country")])]
        m.whatIfParameters = [WhatIfParameter(name: "Discount", minimum: 0, maximum: 0.5, increment: 0.05, defaultValue: 0.1)]
        m.aggregations = [AggregationMapping(aggTable: "Sales Agg", aggColumn: "Amount", summarization: .sum, detailTable: "Sales", detailColumn: "Amount")]
        var layout = ModelLayout(name: "Star")
        layout.cards = ["Sales": ModelLayout.Card(x: 10, y: 20)]
        m.layouts.append(layout)
        var va = VerifiedAnswer(question: "What were sales last year?")
        va.answer = "See the trend chart."
        m.verifiedAnswers = [va]

        var qSales = QueryDefinition(name: "Sales", mScript: """
        let
            Source = Csv.Document(File.Contents(BasePath & "sales.csv"), [Delimiter = ","]),
            Promoted = Table.PromoteHeaders(Source)
        in
            Promoted
        """)
        qSales.description = "Loads sales"
        qSales.group = "Facts"
        var qCust = QueryDefinition(name: "Customer Source", mScript: "Sql.Database(\"srv\", \"db\"){[Schema=\"dbo\",Item=\"Customer\"]}[Data]")
        qCust.includeInRefresh = false
        var qParam = QueryDefinition(name: "BasePath", mScript: "\"/data/\" meta [IsParameterQuery=true, Type=\"Text\", IsParameterQueryRequired=true]")
        qParam.kind = .parameter
        qParam.loadEnabled = false
        var prm = QueryParameter()
        prm.currentValue = "/data/"
        prm.suggestedValues = ["/data/", "/archive/"]
        qParam.parameter = prm
        var qFn = QueryDefinition(name: "fnClean", mScript: "(t as table) as table =>\n    Table.Distinct(t)")
        qFn.kind = .function
        qFn.loadEnabled = false
        qFn.group = "Helpers"
        return (m, [qParam, qSales, qFn, qCust])
    }

    /// A report with pages, visuals in many wells, filters and bookmarks, over the rich model.
    static func richDocument() -> FacetDocument {
        var doc = FacetDocument()
        let (m, q) = richModel()
        doc.model = m
        doc.queries = q
        var rec = DataSourceRecord(kind: "sqlServer", location: "srv;db", displayName: "srv: db")
        rec.privacy = .organizational
        doc.dataSources = [rec]

        var page = Page(name: "Overview")
        var bar = VisualSpec(type: .clusteredColumn, frame: Frame(x: 20, y: 30, width: 400, height: 300), name: "Sales by country")
        bar.setFields(.category, [.column("Customer", "Country")])
        bar.setFields(.values, [.measure("Sales", "Total Sales"), .column("Sales", "Amount", .average)])
        bar.setFields(.legend, [.column("Customer", "City")])
        bar.setFields(.tooltips, [.column("Sales", "Cost", .median)])
        bar.setFmt("title", "text", .string("Sales by country"))
        bar.setFmt("title", "show", .bool(true))
        bar.setFmt("title", "fontColor", .string("#112233"))
        bar.setFmt("legend", "position", .string("Top"))
        bar.setFmt("labels", "fontSize", .number(11))
        bar.setFmt("custom", "stops", .array([.number(1), .number(2)]))
        bar.sort = [SortSpec(field: .measure("Sales", "Total Sales"), descending: true)]
        bar.zIndex = 2; bar.tabOrder = 1
        var vf = FilterSpec(field: .column("Customer", "Country"))
        vf.values = ["US", "FR"]
        vf.isLocked = true
        var adv = FilterSpec(field: .column("Sales", "Amount", .sum), kind: .advanced)
        adv.conditions = [FilterCondition(op: .greaterThan, value: 100), FilterCondition(op: .lessOrEqual, value: 5000.5)]
        var top = FilterSpec(field: .column("Customer", "City"), kind: .topN)
        top.topN.count = 5
        top.topN.by = .measure("Sales", "Total Sales")
        bar.filters = [vf, adv, top]
        var trend = AnalyticsItem(kind: .trendLine)
        trend.name = "Trend"
        bar.analytics = [trend]
        bar.visualCalculations = [VisualCalculation(name: "Running", expression: "RUNNINGSUM([Total Sales])")]
        bar.conditionalFormats = [ConditionalFormat(target: .dataPointColor)]

        var slicer = VisualSpec(type: .slicer, frame: Frame(x: 440, y: 30, width: 200, height: 120))
        slicer.setFields(.field, [.column("Customer", "Country")])
        var st = SlicerState()
        st.selected = ["US"]
        slicer.slicerState = st
        slicer.syncGroup = "country"

        var matrix = VisualSpec(type: .matrix, frame: Frame(x: 20, y: 350, width: 600, height: 300))
        matrix.setFields(.rows, [.column("Customer", "Country"), .column("Customer", "City")])
        matrix.setFields(.columns, [.column("Date", "Year")])
        matrix.setFields(.values, [.measure("Sales", "Total Sales"), .measure("Sales", "YoY %")])
        matrix.expandedPaths = ["US"]

        var text = VisualSpec(type: .textBox, frame: Frame(x: 660, y: 30, width: 300, height: 80))
        text.content = "# Heading\nSome **bold** text"
        text.isHidden = true
        let groupID = UUID()
        text.groupID = groupID

        var sankey = VisualSpec(type: .sankey, frame: Frame(x: 660, y: 130, width: 300, height: 200))
        sankey.setFields(.source, [.column("Customer", "Country")])
        sankey.setFields(.destination, [.column("Customer", "City")])
        sankey.setFields(.values, [.column("Sales", "Amount", .sum)])

        var button = VisualSpec(type: .button, frame: Frame(x: 980, y: 30, width: 120, height: 40))
        var action = ActionSpec()
        action.kind = .webURL
        action.url = "https://example.com"
        button.action = action
        button.imageData = Data([0x89, 0x50, 0x4E, 0x47])

        var kpi = VisualSpec(type: .kpi, frame: Frame(x: 980, y: 100, width: 200, height: 150))
        kpi.setFields(.values, [.measure("Sales", "Total Sales")])
        kpi.setFields(.trendAxis, [.column("Date", "Year")])
        kpi.setFields(.target, [.measure("Sales", "YoY %")])

        page.visuals = [bar, slicer, matrix, text, sankey, button, kpi]
        page.groups = [groupID: "Header group"]
        page.interactions = [bar.id: [matrix.id: .filter, slicer.id: .none]]
        var pf = FilterSpec(field: .column("Date", "Year"), kind: .advanced)
        pf.conditions = [FilterCondition(op: .greaterOrEqual, value: 2022)]
        var rel = FilterSpec(field: .column("Sales", "Order Date"), kind: .relativeDate)
        rel.relative.count = 3
        rel.relative.unit = .months
        var blank = FilterSpec(field: .column("Customer", "City"), kind: .advanced)
        blank.conditions = [FilterCondition(op: .isNotBlank), FilterCondition(op: .contains, value: "ville")]
        blank.conditionsUseOr = true
        page.filters = [pf, rel, blank]
        page.background.color = "#F5F5F7"
        page.background.transparency = 10

        var detail = Page(name: "Customer detail")
        detail.size = .letter
        detail.isHidden = true
        var df = FilterSpec(field: .column("Customer", "Country"))
        df.kind = .basic
        detail.drillthroughFilters = [df]
        var table = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 500, height: 400))
        table.setFields(.values, [.column("Customer", "City"), .column("Sales", "Amount", .sum), .column("Sales", "Amount", .distinctCount)])
        detail.visuals = [table]

        var tip = Page(name: "Tip")
        tip.size = .tooltip
        tip.isTooltipPage = true
        var card = VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        card.setFields(.values, [.measure("Sales", "Total Sales")])
        tip.visuals = [card]

        doc.report.pages = [page, detail, tip]
        doc.report.landingPageID = page.id
        var rf = FilterSpec(field: .column("Customer", "Country"))
        rf.values = ["US"]
        rf.isInverted = true
        rf.isHidden = true
        doc.report.filters = [rf]
        doc.report.theme = .midnight
        doc.report.settings.allowExportData = "underlying"
        doc.report.settings.hideVisualHeaders = true

        var bm = Bookmark(name: "US only", pageID: page.id)
        bm.group = "Regions"
        bm.state.slicerStates = [slicer.id: st]
        bm.state.hiddenVisuals = [matrix.id]
        bm.appliesDisplay = false
        var bm2 = Bookmark(name: "Reset", pageID: detail.id)
        bm2.selectedVisualIDs = [table.id]
        doc.report.bookmarks = [bm, bm2]
        doc.report.daxQueries = [DAXQueryTab(name: "Q1", text: "EVALUATE Sales")]

        doc.data["Sales"] = DataTable(name: "Sales", columnNames: ["Amount", "Cost"], rows: [[100.5, 40], [200, 80]])
        return doc
    }

    static func tempDir(_ name: String = "t") -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("facet-interop-tests/\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

func json<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self)
}
