import XCTest
import FacetCore
@testable import FacetDAX

final class CatalogFormatterTests: XCTestCase {

    // MARK: Catalog

    func testCatalogIsSortedAndUnique() {
        let names = DAXCatalog.functions.map(\.name)
        XCTAssertGreaterThan(names.count, 300)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names, names.sorted())
        for f in DAXCatalog.functions {
            XCTAssertEqual(f.name, f.name.uppercased())
            XCTAssertTrue(f.signature.hasPrefix(f.name + "("), f.name)
            XCTAssertFalse(f.description.isEmpty, f.name)
            XCTAssertGreaterThanOrEqual(f.minArgs, 0)
            if let m = f.maxArgs { XCTAssertGreaterThanOrEqual(m, f.minArgs, f.name) }
        }
    }

    func testCatalogArityAndKinds() {
        func check(_ name: String, _ min: Int, _ max: Int?, table: Bool, file: StaticString = #filePath, line: UInt = #line) {
            guard let f = DAXCatalog.function(named: name) else { return XCTFail("missing \(name)", file: file, line: line) }
            XCTAssertEqual(f.minArgs, min, name, file: file, line: line)
            XCTAssertEqual(f.maxArgs, max, name, file: file, line: line)
            XCTAssertEqual(f.returnsTable, table, name, file: file, line: line)
        }
        check("calculate", 1, nil, table: false)
        check("CALCULATETABLE", 1, nil, table: true)
        check("SUM", 1, 1, table: false)
        check("SUMX", 2, 2, table: false)
        check("FILTER", 2, 2, table: true)
        check("ALL", 0, nil, table: true)
        check("VALUES", 1, 1, table: true)
        check("SUMMARIZECOLUMNS", 1, nil, table: true)
        check("TOTALYTD", 2, 4, table: false)
        check("DATESYTD", 1, 2, table: true)
        check("RANKX", 2, 5, table: false)
        check("TOPN", 2, nil, table: true)
        check("SWITCH", 3, nil, table: false)
        check("OFFSET", 1, 7, table: true)
        check("WINDOW", 2, 10, table: true)
        check("RANK", 0, 7, table: false)
        check("ROWNUMBER", 0, 6, table: false)
        check("COUNTROWS", 0, 1, table: false)
        check("SELECTEDVALUE", 1, 2, table: false)
        check("DIVIDE", 2, 3, table: false)
        check("INFO.VIEW.TABLES", 0, 0, table: true)
        check("TEXTSEARCH", 2, 2, table: false)
        check("RUNNINGSUM", 1, 4, table: false)
        check("MOVINGAVERAGE", 2, 6, table: false)
        check("RANGE", 1, 5, table: true)
        check("TABLEOF", 1, 1, table: true)
        check("GENERATESERIES", 2, 3, table: true)
        check("XIRR", 3, 5, table: false)
    }

    func testCatalogCoversRequiredFunctions() {
        let required = """
        SUM AVERAGE MIN MAX COUNT COUNTA COUNTBLANK COUNTROWS DISTINCTCOUNT DISTINCTCOUNTNOBLANK APPROXIMATEDISTINCTCOUNT MEDIAN PRODUCT
        STDEV.S STDEV.P VAR.S VAR.P PERCENTILE.INC PERCENTILE.EXC GEOMEAN SUMX AVERAGEX MINX MAXX COUNTX COUNTAX MEDIANX PRODUCTX
        STDEVX.S STDEVX.P VARX.S VARX.P PERCENTILEX.INC PERCENTILEX.EXC CONCATENATEX RANKX GEOMEANX FIRSTNONBLANK LASTNONBLANK
        FIRSTNONBLANKVALUE LASTNONBLANKVALUE CALCULATE CALCULATETABLE FILTER ALL ALLEXCEPT ALLSELECTED ALLNOBLANKROW REMOVEFILTERS
        KEEPFILTERS VALUES DISTINCT SELECTEDVALUE HASONEVALUE HASONEFILTER ISFILTERED ISCROSSFILTERED ISINSCOPE EARLIER EARLIEST
        LOOKUPVALUE TREATAS USERELATIONSHIP CROSSFILTER FILTERS RELATED RELATEDTABLE SUMMARIZE SUMMARIZECOLUMNS ADDCOLUMNS SELECTCOLUMNS
        GROUPBY CURRENTGROUP ROW DATATABLE UNION INTERSECT EXCEPT CROSSJOIN NATURALINNERJOIN NATURALLEFTOUTERJOIN GENERATE GENERATEALL
        GENERATESERIES TOPN SAMPLE CALENDAR CALENDARAUTO ADDMISSINGITEMS ROLLUP ROLLUPGROUP ROLLUPADDISSUBTOTAL ROLLUPISSUBTOTAL ISSUBTOTAL
        IGNORE NONVISUAL TABLEOF NAMEOF DETAILROWS TOCSV TOJSON OFFSET INDEX WINDOW RANK ROWNUMBER ORDERBY PARTITIONBY MATCHBY
        TOTALYTD TOTALQTD TOTALMTD DATESYTD DATESQTD DATESMTD SAMEPERIODLASTYEAR DATEADD PARALLELPERIOD PREVIOUSDAY PREVIOUSMONTH
        PREVIOUSQUARTER PREVIOUSYEAR NEXTDAY NEXTMONTH NEXTQUARTER NEXTYEAR DATESBETWEEN DATESINPERIOD STARTOFMONTH STARTOFQUARTER
        STARTOFYEAR ENDOFMONTH ENDOFQUARTER ENDOFYEAR FIRSTDATE LASTDATE OPENINGBALANCEMONTH OPENINGBALANCEQUARTER OPENINGBALANCEYEAR
        CLOSINGBALANCEMONTH CLOSINGBALANCEQUARTER CLOSINGBALANCEYEAR IF IF.EAGER SWITCH AND OR NOT TRUE FALSE BLANK COALESCE IFERROR
        ISERROR ERROR ISBLANK ISNUMBER ISTEXT ISLOGICAL ISNONTEXT ISEVEN ISODD ISEMPTY CONTAINS CONTAINSROW CONTAINSSTRING
        CONTAINSSTRINGEXACT USERNAME USERPRINCIPALNAME USERCULTURE USEROBJECTID CUSTOMDATA SELECTEDMEASURE SELECTEDMEASURENAME
        SELECTEDMEASUREFORMATSTRING ISSELECTEDMEASURE COLUMNSTATISTICS INFO.TABLES INFO.COLUMNS INFO.MEASURES INFO.RELATIONSHIPS
        INFO.FUNCTIONS INFO.CALCULATIONGROUPS INFO.CALCULATIONITEMS INFO.ROLES INFO.VIEW.TABLES INFO.VIEW.COLUMNS INFO.VIEW.MEASURES
        INFO.VIEW.RELATIONSHIPS PATH PATHITEM PATHLENGTH PATHCONTAINS PATHITEMREVERSE ABS ROUND ROUNDUP ROUNDDOWN MROUND INT TRUNC
        CEILING FLOOR ISO.CEILING MOD QUOTIENT DIVIDE POWER SQRT SQRTPI EXP LN LOG LOG10 SIGN PI RAND RANDBETWEEN FACT GCD LCM EVEN ODD
        COMBIN PERMUT SIN COS TAN COT ASIN ACOS ATAN ACOT SINH COSH TANH ASINH ACOSH ATANH DEGREES RADIANS CONVERT CURRENCY CONCATENATE
        LEFT RIGHT MID LEN UPPER LOWER TRIM SUBSTITUTE REPLACE SEARCH FIND FORMAT VALUE FIXED REPT EXACT UNICHAR UNICODE COMBINEVALUES
        TEXTSEARCH DATE TIME DATEVALUE TIMEVALUE YEAR MONTH DAY HOUR MINUTE SECOND QUARTER WEEKDAY WEEKNUM TODAY NOW UTCNOW UTCTODAY
        EOMONTH EDATE DATEDIFF YEARFRAC NETWORKDAYS PMT PV FV NPER RATE XNPV XIRR IPMT PPMT SLN DB DDB EFFECT NOMINAL CUMIPMT CUMPRINC
        SYD ISPMT RRI PDURATION RUNNINGSUM MOVINGAVERAGE PREVIOUS NEXT FIRST LAST COLLAPSE COLLAPSEALL EXPAND EXPANDALL RANGE LOOKUP
        LOOKUPWITHTOTALS ISATLEVEL
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let missing = required.filter { DAXCatalog.function(named: $0) == nil }
        XCTAssertEqual(missing, [])
    }

    func testCatalogLookupAndCompletions() {
        XCTAssertNil(DAXCatalog.function(named: "NOPE"))
        XCTAssertEqual(DAXCatalog.function(named: "sumx")?.category, .aggregation)
        XCTAssertEqual(DAXCatalog.function(named: "DATEADD")?.category, .timeIntelligence)
        let c = DAXCatalog.completions(prefix: "calc").map(\.name)
        XCTAssertEqual(c, ["CALCULATE", "CALCULATETABLE"])
        XCTAssertEqual(DAXCatalog.completions(prefix: "").count, DAXCatalog.functions.count)
        XCTAssertTrue(DAXCatalog.keywords.contains("RETURN"))
        XCTAssertFalse(DAXCatalog.functions(in: .financial).isEmpty)
    }

    // MARK: Formatter

    /// Token texts ignoring whitespace, comments and case.
    private func signature(_ s: String) -> [String] {
        var lx = Lexer(s)
        return lx.lexAll().filter { $0.kind != .eof && $0.kind != .docComment }.map { "\($0.kind)|\($0.text.uppercased())" }
    }
    private func comments(_ s: String) -> [String] {
        var lx = Lexer(s)
        let u = Array(s.utf16)
        return lx.lexAll(keepComments: true).filter { $0.kind == .comment || $0.kind == .docComment }
            .map { String(utf16CodeUnits: Array(u[$0.range]), count: $0.range.count).trimmingCharacters(in: .whitespaces) }.sorted()
    }

    private let samples: [String] = [
        "sum(Sales[Amount])",
        "calculate(sum(Sales[Amount]),filter(all('Product'),'Product'[Color]=\"Red\"&&'Product'[Price]>10),Customer[Country] in {\"US\",\"UK\"})",
        "var a=1 var b = a*-2 return if(a>b,a,b)",
        "VAR total = CALCULATE([Sales], ALL(Sales)) // grand total\nVAR x = [Sales]\n-- ratio\nRETURN DIVIDE(x, total, 0)",
        "DEFINE /// Total sales\n measure Sales[Total] = sum(Sales[Amount]) var t = 5 evaluate summarizecolumns('Product'[Color], \"Total\", [Total], \"Share\", divide([Total], calculate([Total], all('Product')))) order by [Total] desc, 'Product'[Color] start at 100",
        "IF(a, /* inline */ b, c)",
        "SUMX(Sales, Sales[Qty] * Sales[Price]) / CALCULATE(COUNTROWS(Sales), REMOVEFILTERS())",
        "{ (1, \"a\"\"b\"), (2, \"c\") }",
        "'It''s'[Col]]umn] + -1 ^ 2 & \"x\"",
        "SWITCH(TRUE(), [x] < 0, \"neg\", // negative\n [x] = 0, \"zero\", \"pos\")",
        "OFFSET(-1, , ORDERBY([Sales], DESC BLANKS LAST), , PARTITIONBY('Date'[Year]))",
        "'Date'[Date].[Year] = 2024 && NOT ISBLANK([x])",
        "DEFINE FUNCTION AddTax = (amount : NUMERIC, rate : SCALAR VAL = 0.1) => amount * (1 + rate) EVALUATE ROW(\"v\", AddTax(100))",
        "CALCULATE([Sales], 'Product'[Color] = \"Red\", USERELATIONSHIP(Sales[ShipDate], 'Date'[Date]), KEEPFILTERS(Customer[Segment] = \"Corporate\"), DATESYTD('Date'[Date]))",
        "// leading comment\nSUM(Sales[Amount]) // trailing",
        "CALCULATE(SUM(Sales[Amount]) // total\n, ALL(Sales))",
    ]

    func testFormatterPreservesTokensAndIsIdempotent() {
        for s in samples {
            let f = DAXFormatter.format(s)
            XCTAssertEqual(signature(f), signature(s), "tokens changed for: \(s)\n→ \(f)")
            XCTAssertEqual(comments(f), comments(s), "comments changed for: \(s)\n→ \(f)")
            XCTAssertEqual(DAXFormatter.format(f), f, "not idempotent for: \(s)\n→ \(f)")
            for line in f.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertFalse(line.hasSuffix(" "), "trailing space in: \(f)")
            }
        }
    }

    func testFormatterLayout() {
        XCTAssertEqual(DAXFormatter.format("sum( Sales[Amount] )"), "SUM(Sales[Amount])")
        XCTAssertEqual(DAXFormatter.format("divide(sum(Sales[a]),sum(Sales[b]))"), "DIVIDE(SUM(Sales[a]), SUM(Sales[b]))")
        XCTAssertEqual(DAXFormatter.format("1+2*-3"), "1 + 2 * -3")
        XCTAssertEqual(DAXFormatter.format("Sales [Amount]>=10&&not isblank( [M] )"), "Sales[Amount] >= 10 && NOT ISBLANK([M])")
        XCTAssertEqual(DAXFormatter.format("var a = 1 return a + 1"), "VAR a = 1\nRETURN\n    a + 1")
        XCTAssertEqual(DAXFormatter.format("calculate(sum(Sales[Amount]),filter(all(Sales),Sales[Qty]>1))"),
                       "CALCULATE(\n    SUM(Sales[Amount]),\n    FILTER(ALL(Sales), Sales[Qty] > 1)\n)")
        XCTAssertEqual(DAXFormatter.format("evaluate Sales order by Sales[Amount] desc"),
                       "EVALUATE\n    Sales\nORDER BY\n    Sales[Amount] desc")
        XCTAssertEqual(DAXFormatter.format("define measure Sales[T] = sum(Sales[A]) evaluate row(\"t\", [T])"),
                       "DEFINE\n    MEASURE Sales[T] = SUM(Sales[A])\nEVALUATE\n    ROW(\"t\", [T])")
        XCTAssertEqual(DAXFormatter.format("x in {1,2}"), "x IN {1, 2}")
        XCTAssertEqual(DAXFormatter.format("'Date'[Date].[Year]"), "'Date'[Date].[Year]")
        XCTAssertEqual(DAXFormatter.format(""), "")
        let long = DAXFormatter.format("SUMX(VeryLongTableNameNumberOne, VeryLongTableNameNumberOne[FirstQuantityColumn] * VeryLongTableNameNumberOne[SecondPriceColumn])")
        XCTAssertTrue(long.contains("\n    VeryLongTableNameNumberOne,\n"))
        XCTAssertTrue(long.split(separator: "\n").allSatisfy { $0.count <= 100 })
    }

    func testFormatterSurvivesMalformedInput() {
        for s in ["SUM(", "((", ")", "CALCULATE(,,", "\"unterminated", "'t", "[col", "VAR", "RETURN RETURN", "1 +", "/* open", "{1,", "a ) b ( c"] {
            let f = DAXFormatter.format(s)
            XCTAssertEqual(DAXFormatter.format(f), f, "not idempotent for malformed: \(s)")
        }
    }

    func testFormattedOutputStillParses() throws {
        for s in samples where !s.uppercased().contains("EVALUATE") {
            XCTAssertNoThrow(try Parser.parseExpression(DAXFormatter.format(s)), s)
        }
        for s in samples where s.uppercased().contains("EVALUATE") {
            XCTAssertNoThrow(try Parser.parseQuery(DAXFormatter.format(s)), s)
        }
    }

    // MARK: Quick measures

    private func sampleArgs(for t: QuickMeasureTemplate) -> [String: QuickMeasureArgument] {
        var args: [String: QuickMeasureArgument] = [:]
        for (i, p) in t.parameters.enumerated() where p.defaultValue == nil {
            switch p.kind {
            case .value: args[p.name] = i % 2 == 0 ? .field(.measure("Sales", "Total Sales")) : .field(.column("Sales", "Amount", .average))
            case .category: args[p.name] = .field(.column("Product", "Color"))
            case .date: args[p.name] = .field(.column("Date", "Date"))
            case .number: args[p.name] = .number(3)
            case .text: args[p.name] = .text("Red")
            }
        }
        return args
    }

    func testEveryQuickMeasureGeneratesParsableDAX() throws {
        XCTAssertGreaterThanOrEqual(QuickMeasures.templates.count, 25)
        XCTAssertEqual(Set(QuickMeasures.templates.map(\.id)).count, QuickMeasures.templates.count)
        for t in QuickMeasures.templates {
            XCTAssertTrue(QuickMeasures.categories.contains(t.category), t.id)
            let dax = try t.dax(sampleArgs(for: t))
            XCTAssertNoThrow(try Parser.parseExpression(dax), "\(t.id): \(dax)")
            XCTAssertFalse(t.suggestedName(sampleArgs(for: t)).isEmpty)
            let node = try Parser.parseExpression(dax)
            node.walk { n in
                if let name = n.callName, name != "__TUPLE" { XCTAssertNotNil(DAXCatalog.function(named: name), "\(t.id) uses unknown \(name)") }
            }
        }
    }

    func testQuickMeasureDetails() throws {
        let ytd = try XCTUnwrap(QuickMeasures.template(id: "yearToDateTotal"))
        let args: [String: QuickMeasureArgument] = ["base": .field(.column("Sales", "Amount", .sum)), "date": .field(.column("Date", "Date"))]
        XCTAssertEqual(try ytd.dax(args), "TOTALYTD(SUM('Sales'[Amount]), 'Date'[Date])")
        XCTAssertEqual(ytd.suggestedName(args), "Amount YTD")
        XCTAssertThrowsError(try ytd.dax(["base": .field(.measure("Sales", "Total"))]))
        XCTAssertThrowsError(try ytd.dax(["base": .field(.measure("Sales", "Total")), "date": .field(.measure("Sales", "Total"))]))
        let filtered = try XCTUnwrap(QuickMeasures.template(id: "filteredValue"))
        let d = try filtered.dax(["base": .field(.measure("Sales", "Total")), "filter": .field(.column("Product", "Color")), "value": .text("Red")])
        XCTAssertEqual(d, "CALCULATE([Total], 'Product'[Color] IN {\"Red\"})")
        let first = try XCTUnwrap(QuickMeasures.template(id: "addition"))
        XCTAssertEqual(try first.dax(["base": .field(.column("Sales", "Name", .first)), "other": .field(.column("Sales", "Qty"))]),
                       "FIRSTNONBLANK('Sales'[Name], 1) + SUM('Sales'[Qty])")
        let yoy = try XCTUnwrap(QuickMeasures.template(id: "yearOverYearChange"))
        XCTAssertTrue(try yoy.dax(["base": .field(.measure("Sales", "Total")), "date": .field(.column("Date", "Date"))]).contains("DATEADD('Date'[Date], -1, YEAR)"))
        XCTAssertNil(QuickMeasures.template(id: "nope"))
    }

    // MARK: Visual calculation templates

    func testVisualCalcTemplates() throws {
        XCTAssertEqual(VisualCalcTemplates.all.map(\.id), ["runningSum", "movingAverage", "percentOfParent", "percentOfGrandTotal",
                                                           "averageOfChildren", "versusPrevious", "versusNext", "versusFirst", "versusLast"])
        func e(_ id: String, axis: String = "ROWS", window: Int = 3) -> String {
            VisualCalcTemplates.template(id: id)?.expression(field: "Sales", axis: axis, window: window) ?? ""
        }
        XCTAssertEqual(e("runningSum"), "RUNNINGSUM([Sales])")
        XCTAssertEqual(e("runningSum", axis: "COLUMNS"), "RUNNINGSUM([Sales], COLUMNS)")
        XCTAssertEqual(e("movingAverage"), "MOVINGAVERAGE([Sales], 3)")
        XCTAssertEqual(e("movingAverage", axis: "columns", window: 5), "MOVINGAVERAGE([Sales], 5, TRUE, COLUMNS)")
        XCTAssertEqual(e("percentOfParent"), "DIVIDE([Sales], COLLAPSE([Sales], ROWS))")
        XCTAssertEqual(e("percentOfGrandTotal"), "DIVIDE([Sales], COLLAPSEALL([Sales], ROWS))")
        XCTAssertEqual(e("averageOfChildren"), "EXPAND(AVERAGE([Sales]), ROWS)")
        XCTAssertEqual(e("versusPrevious"), "[Sales] - PREVIOUS([Sales])")
        XCTAssertEqual(e("versusNext", axis: "ROWS COLUMNS"), "[Sales] - NEXT([Sales], 1, ROWS COLUMNS)")
        XCTAssertEqual(e("versusFirst"), "[Sales] - FIRST([Sales])")
        XCTAssertEqual(e("versusLast"), "[Sales] - LAST([Sales])")
        XCTAssertEqual(VisualCalcTemplates.template(id: "runningSum")?.expression(field: "a]b"), "RUNNINGSUM([a]]b])")
        XCTAssertEqual(VisualCalcTemplates.template(id: "runningSum")?.suggestedName(field: "Sales"), "Sales running sum")
        for t in VisualCalcTemplates.all {
            for axis in ["ROWS", "COLUMNS", "ROWS COLUMNS"] {
                let x = t.expression(field: "Total Sales", axis: axis)
                let node = try Parser.parseExpression(x)
                node.walk { n in
                    if let name = n.callName { XCTAssertNotNil(DAXCatalog.function(named: name), name) }
                }
            }
        }
    }
}
