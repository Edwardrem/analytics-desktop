import XCTest
import FacetCore
@testable import FacetInterop

final class TMDLTests: XCTestCase {
    func testFolderLayoutAndGrammar() throws {
        let (model, queries) = Fixtures.richModel()
        let files = TMDL.serialize(model: model, queries: queries)
        let paths = Set(files.map(\.path))
        for p in ["database.tmdl", "model.tmdl", "relationships.tmdl", "expressions.tmdl", "functions.tmdl", "tables/Sales.tmdl",
                  "tables/Customer.tmdl", "tables/Date.tmdl", "tables/Time Intelligence.tmdl", "roles/Sales West.tmdl",
                  "perspectives/Executive.tmdl", "cultures/fr-FR.tmdl"] {
            XCTAssertTrue(paths.contains(p), "missing \(p)")
        }
        func text(_ p: String) -> String { files.first { $0.path == p }?.text ?? "" }
        let sales = text("tables/Sales.tmdl")
        XCTAssertTrue(sales.hasPrefix("/// Fact table.\n///\n/// One row per order line.\ntable Sales\n"))
        XCTAssertTrue(sales.contains("\tmeasure 'Total Sales' = SUM(Sales[Amount])\n\t\tformatString: $#,0\n\t\tdisplayFolder: KPIs\n"))
        XCTAssertTrue(sales.contains("\tmeasure 'YoY %' =\n\t\t\tVAR Prev = CALCULATE("))
        XCTAssertTrue(sales.contains("\t\tformatStringDefinition = IF([Total Sales] > 1000000, \"0.0%\", \"0.00%\")"))
        XCTAssertTrue(sales.contains("\tmeasure 'It''s = odd: name' = ```\n"))
        XCTAssertTrue(sales.contains("\tcolumn 'Customer Key'\n\t\tdataType: int64\n\t\tisNullable: false\n"))
        XCTAssertTrue(sales.contains("\tcolumn 'Margin %' = DIVIDE(Sales[Amount] - Sales[Cost], Sales[Amount])\n"))
        XCTAssertTrue(sales.contains("\t\tsummarizeBy: sum\n\t\tsourceColumn: Amount\n"))
        XCTAssertTrue(sales.contains("\tpartition Sales = m\n\t\tmode: import\n\t\tqueryGroup: Facts\n\t\tsource =\n\t\t\t\tlet\n"))
        XCTAssertTrue(sales.contains("annotation Facet_summarizeBy = \"median\""))
        XCTAssertTrue(text("tables/Date.tmdl").contains("\tpartition Date = calculated\n\t\tmode: import\n\t\tsource = CALENDAR("))
        XCTAssertTrue(text("tables/Date.tmdl").contains("\tdataCategory: Time\n"))
        let customer = text("tables/Customer.tmdl")
        XCTAssertTrue(customer.contains("\thierarchy Geography\n"))
        XCTAssertTrue(customer.contains("\t\tlevel Country\n\t\t\tcolumn: Country\n"))
        XCTAssertTrue(customer.contains("\t\tsortByColumn: Country\n"))
        XCTAssertTrue(customer.contains("\t\tdataCategory: City\n"))
        XCTAssertTrue(customer.contains("\t\tmode: dual\n"))
        let rel = text("relationships.tmdl")
        XCTAssertTrue(rel.contains("relationship \(model.relationships[0].id.uuidString.lowercased())\n\tfromColumn: Sales.'Customer Key'\n\ttoColumn: Customer.'Customer Key'\n\tcrossFilteringBehavior: bothDirections\n"))
        XCTAssertTrue(rel.contains("\tisActive: false\n"))
        XCTAssertTrue(rel.contains("\ttoCardinality: many\n"))
        XCTAssertTrue(rel.contains("\tfromCardinality: one\n"))
        let role = text("roles/Sales West.tmdl")
        XCTAssertTrue(role.hasPrefix("/// Western region\nrole 'Sales West'\n\tmodelPermission: read\n"))
        XCTAssertTrue(role.contains("\ttablePermission Customer = [Country] = \"US\"\n\t\tcolumnPermission Email = none\n"))
        XCTAssertTrue(role.contains("\ttablePermission 'Remote ''Live'' Table'\n\t\tmetadataPermission: none\n"))
        let cg = text("tables/Time Intelligence.tmdl")
        XCTAssertTrue(cg.contains("\tcalculationGroup\n\t\tprecedence: 10\n"))
        XCTAssertTrue(cg.contains("\t\tcalculationItem YTD = CALCULATE(SELECTEDMEASURE(), DATESYTD('Date'[Date]))\n\t\t\tordinal: 0\n"))
        XCTAssertTrue(cg.contains("\t\t\tformatStringDefinition = \"#,0\"\n"))
        XCTAssertTrue(text("perspectives/Executive.tmdl").contains("\tperspectiveTable Sales\n\t\tincludeAll\n\t\tperspectiveMeasure 'Total Sales'\n"))
        XCTAssertTrue(text("perspectives/Executive.tmdl").contains("\t\tperspectiveHierarchy Geography\n"))
        let fr = text("cultures/fr-FR.tmdl")
        XCTAssertTrue(fr.contains("cultureInfo fr-FR\n"))
        XCTAssertTrue(fr.contains("\t\t\ttable Sales\n\t\t\t\tcaption: Ventes\n\t\t\t\tcolumn Amount\n\t\t\t\t\tcaption: Montant\n"))
        XCTAssertTrue(text("functions.tmdl").contains("/// Adds tax\nfunction AddTax = (amount : scalar val, rate : anyref expr) => amount * (1 + rate)\n"))
        XCTAssertTrue(text("expressions.tmdl").contains("expression BasePath = \"/data/\" meta [IsParameterQuery=true"))
        XCTAssertTrue(text("model.tmdl").contains("model Model\n\tculture: en-GB\n"))
        XCTAssertTrue(text("model.tmdl").contains("ref table Sales\nref table Customer\n"))
        XCTAssertTrue(text("database.tmdl").hasPrefix("database 'Contoso Sales'\n"))
    }

    func testLosslessRoundTrip() throws {
        let (model, queries) = Fixtures.richModel()
        let files = TMDL.serialize(model: model, queries: queries)
        let result = try TMDL.parseDetailed(files: files)
        XCTAssertEqual(json(result.model), json(model))
        XCTAssertEqual(json(result.queries), json(queries))
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        // Spot checks on the decoded structure.
        XCTAssertEqual(result.model.tables.map(\.name), ["Sales", "Customer", "Date", "Remote 'Live' Table"])
        XCTAssertEqual(result.model.table("Sales")?.measure("YoY %")?.expression, model.table("Sales")?.measure("YoY %")?.expression)
        XCTAssertEqual(result.model.table("Sales")?.measure("It's = odd: name")?.expression, "\n\t  1 + 1  \n")
        XCTAssertEqual(result.model.roles[0].hiddenColumns, ["Sales[Cost]", "Customer[Email]"])
        XCTAssertEqual(result.model.roles[0].tableFilters["Sales"], "Sales[Amount] > 0\n    && TRUE()")
        XCTAssertEqual(result.model.perspectives[1].members, ["Customer[City]", "Sales[Amount]", "Customer[Country]", "Date"])
        XCTAssertEqual(result.model.translations[0].captions["weird key"], " padded ")
        XCTAssertEqual(result.model.functions[1].parameters.first?.defaultExpression, "0")
        XCTAssertEqual(result.model.calculationGroups[0].items[1].formatExpression, "\"#,0\"")
        XCTAssertEqual(result.queries.map(\.name), ["BasePath", "Sales", "fnClean", "Customer Source"])
        // Serialising again is byte-stable.
        let again = TMDL.serialize(model: result.model, queries: result.queries)
        XCTAssertEqual(again, files)
        // Parsing files in a different order gives the same model.
        let shuffled = try TMDL.parse(files: files.reversed())
        XCTAssertEqual(json(shuffled.0), json(model))
        XCTAssertEqual(json(shuffled.1), json(queries))
    }

    func testAwkwardExpressionsSurvive() throws {
        var m = SemanticModel()
        var t = ModelTable(name: "T")
        let cases = ["", " leading", "trailing ", "a\n\nb", "\tall\n\tindented", "  two\n  spaces", "x\n", "\nx", "line\n   \nafter",
                     "a\r\nb", "IF(1,\n\t\"deep\",\n\t\t\"deeper\")", "```odd", "\"quoted\" = 'x'", "   "]
        for (i, c) in cases.enumerated() { t.measures.append(Measure(name: "m\(i)", expression: c)) }
        var col = ModelColumn(name: "c", dataType: .text)
        col.formatString = "  spaced \"q\" "
        col.displayFolder = "A\\B"
        col.description = " indented description\nsecond line\n"
        t.columns = [col]
        m.tables = [t]
        let back = try TMDL.parse(files: TMDL.serialize(model: m, queries: [])).0
        for (i, c) in cases.enumerated() {
            XCTAssertEqual(back.tables[0].measures[i].expression, c, "case \(i): \(c.debugDescription)")
        }
        XCTAssertEqual(back.tables[0].columns[0].formatString, "  spaced \"q\" ")
        XCTAssertEqual(back.tables[0].columns[0].description, " indented description\nsecond line\n")
        XCTAssertEqual(json(back), json(m))
    }

    func testParsesPowerBIAuthoredTMDL() throws {
        // Hand-written in the style Power BI Desktop emits (spaces after descriptions, ``` blocks, unknown properties).
        let table = """
        table Product
        \tlineageTag: 6bfd7976-09ca-7046-4a83-0c3085609e3c

        \t/// Sum of quantity
        \tmeasure 'Total Qty' = ```
        \t\t\t
        \t\t\tSUM ( Product[Qty] )
        \t\t\t```
        \t\tformatString: #,0
        \t\tlineageTag: 3a2b9e5c-7f6a-4f0e-9d5e-1c2b3a4d5e6f

        \tcolumn 'Product Name'
        \t\tdataType: string
        \t\tlineageTag: 1a2b9e5c-7f6a-4f0e-9d5e-1c2b3a4d5e6f
        \t\tsummarizeBy: none
        \t\tsourceColumn: Product Name
        \t\tsourceLineageTag: xyz

        \t\tannotation SummarizationSetBy = Automatic

        \tcolumn Qty
        \t\tdataType: int64
        \t\tformatString: 0
        \t\tsummarizeBy: sum
        \t\tsourceColumn: Qty

        \tpartition Product = m
        \t\tmode: import
        \t\tsource =
        \t\t\t\tlet
        \t\t\t\t    Source = Excel.Workbook(File.Contents("C:\\\\data.xlsx"), null, true)
        \t\t\t\tin
        \t\t\t\t    Source

        \tannotation PBI_ResultType = Table
        """
        let model = """
        model Model
        \tculture: en-US
        \tdefaultPowerBIDataSourceVersion: powerBI_V3
        \tdiscourageImplicitMeasures

        \tannotation __PBI_TimeIntelligenceEnabled = 1

        ref table Product
        """
        let rel = "relationship AutoDetected_1\n\tfromColumn: Product.Qty\n\ttoColumn: Product.'Product Name'\n"
        let expr = "expression Server = \"localhost\" meta [IsParameterQuery=true, Type=\"Text\", IsParameterQueryRequired=true]\n\tlineageTag: 9a2b9e5c-7f6a-4f0e-9d5e-1c2b3a4d5e6f\n\tqueryGroup: Parameters\n"
        let r = try TMDL.parseDetailed(files: [
            TMDLFile(path: "tables/Product.tmdl", text: table.replacingOccurrences(of: "\n", with: "\r\n")),
            TMDLFile(path: "model.tmdl", text: model), TMDLFile(path: "relationships.tmdl", text: rel),
            TMDLFile(path: "expressions.tmdl", text: expr),
        ])
        let t = try XCTUnwrap(r.model.table("Product"))
        XCTAssertEqual(t.id, UUID(uuidString: "6bfd7976-09ca-7046-4a83-0c3085609e3c"))
        XCTAssertEqual(t.measures.first?.name, "Total Qty")
        XCTAssertEqual(t.measures.first?.expression, "\nSUM ( Product[Qty] )")
        XCTAssertEqual(t.measures.first?.description, "Sum of quantity")
        XCTAssertEqual(t.columns.map(\.name), ["Product Name", "Qty"])
        XCTAssertEqual(t.columns[1].dataType, .integer)
        XCTAssertEqual(t.columns[1].summarizeBy, .sum)
        XCTAssertEqual(t.sourceQuery, "Product")
        XCTAssertTrue(r.model.autoDateTime)
        XCTAssertEqual(r.model.relationships.count, 1)
        XCTAssertEqual(r.model.relationships[0].toColumn, "Product Name")
        let q = try XCTUnwrap(r.queries.first { $0.name == "Product" })
        XCTAssertTrue(q.mScript.hasPrefix("let\n    Source = Excel.Workbook"))
        XCTAssertTrue(q.mScript.hasSuffix("in\n    Source"))
        XCTAssertTrue(q.loadEnabled)
        let p = try XCTUnwrap(r.queries.first { $0.name == "Server" })
        XCTAssertEqual(p.kind, .parameter)
        XCTAssertEqual(p.parameter?.currentValue, .string("localhost"))
        XCTAssertEqual(p.group, "Parameters")
        XCTAssertFalse(p.loadEnabled)
        XCTAssertTrue(r.warnings.contains { $0.message.contains("sourceLineageTag") })

        // Space-indented TMDL is accepted too.
        let spaced = "table S\n    column A\n        dataType: string\n    measure M =\n            1 +\n              2\n        formatString: 0\n"
        let s = try TMDL.parse(files: [TMDLFile(path: "tables/S.tmdl", text: spaced)]).0
        XCTAssertEqual(s.tables[0].measures[0].expression, "1 +\n  2")
        XCTAssertEqual(s.tables[0].measures[0].formatString, "0")
    }

    func testSyntaxErrorsAreReportedWithLocation() {
        XCTAssertThrowsError(try TMDL.parse(files: [TMDLFile(path: "tables/X.tmdl", text: "table X\n\tmeasure 'unterminated = 1\n")])) {
            let e = $0 as? TMDLError
            XCTAssertEqual(e?.line, 2)
            XCTAssertEqual(e?.file, "tables/X.tmdl")
            XCTAssertTrue(e?.errorDescription?.contains("tables/X.tmdl:2") == true)
        }
        XCTAssertThrowsError(try TMDL.parse(files: [TMDLFile(path: "r.tmdl", text: "relationship abc\n\tfromColumn: OnlyTable\n")]))
        XCTAssertThrowsError(try TMDL.parseScript("createOrReplace\n\n\tmeasure X = ```\n\t\t1\n"))
        XCTAssertThrowsError(try TMDL.parseScript("   \n"))
    }

    func testScriptEditApplyAndChangeSummary() throws {
        let (model, queries) = Fixtures.richModel()
        // Script a measure, edit it, add another, and apply.
        let script = try TMDL.script(for: .measure(table: "Sales", name: "Total Sales"), in: model, queries: queries)
        XCTAssertTrue(script.hasPrefix("createOrReplace\n\n\tref table Sales\n\n\t\t/// Sum of line amounts\n\t\tmeasure 'Total Sales' = SUM(Sales[Amount])\n"))
        let edited = script.replacingOccurrences(of: "SUM(Sales[Amount])", with: "SUMX(Sales, Sales[Amount])")
            + "\n\t\tmeasure 'Order Count' = COUNTROWS(Sales)\n\t\t\tformatString: #,0\n"
        let parsed = try TMDL.parseScript(edited)
        XCTAssertEqual(parsed.objects.map(\.name), ["Total Sales", "Order Count"])
        XCTAssertEqual(parsed.objects.first?.table, "Sales")
        let result = try TMDL.apply(script: edited, to: model, queries: queries)
        XCTAssertEqual(result.model.table("Sales")?.measure("Total Sales")?.expression, "SUMX(Sales, Sales[Amount])")
        XCTAssertEqual(result.model.table("Sales")?.measure("Total Sales")?.id, model.table("Sales")?.measure("Total Sales")?.id)
        XCTAssertEqual(result.model.table("Sales")?.measure("Order Count")?.formatString, "#,0")
        XCTAssertEqual(result.summary.added, [TMDLChange(kind: .added, objectType: "measure", name: "Sales[Order Count]")])
        XCTAssertEqual(result.summary.changed, [TMDLChange(kind: .changed, objectType: "measure", name: "Sales[Total Sales]")])
        XCTAssertTrue(result.summary.removed.isEmpty)
        XCTAssertTrue(result.summary.text.hasPrefix("1 added, 1 changed, 0 removed"))
        XCTAssertEqual(result.fileDiffs.map(\.path), ["tables/Sales.tmdl"])
        let stats = TextDiff.stats(result.fileDiffs[0].hunks)
        XCTAssertEqual(stats.removed, 1)
        XCTAssertGreaterThanOrEqual(stats.added, 3)
        // The original is untouched.
        XCTAssertEqual(model.table("Sales")?.measure("Total Sales")?.expression, "SUM(Sales[Amount])")

        // Applying an unmodified script changes nothing, for every kind of object.
        let refs: [TMDLObjectRef] = [.model, .modelProperties, .table("Sales"), .table("Time Intelligence"), .column(table: "Customer", name: "City"),
                                     .hierarchy(table: "Customer", name: "Geography"), .calculationGroup("Time Intelligence"),
                                     .relationship(model.relationships[1].id), .relationships, .role("Sales West"), .perspective("Executive"),
                                     .culture("fr-FR"), .function("AddTax"), .expression("BasePath")]
        for ref in refs {
            let s = try TMDL.script(for: ref, in: model, queries: queries)
            let r = try TMDL.apply(script: s, to: model, queries: queries)
            XCTAssertTrue(r.summary.isEmpty, "\(ref): \(r.summary.text)")
            XCTAssertEqual(json(r.model), json(model), "\(ref)")
            XCTAssertEqual(json(r.queries), json(queries), "\(ref)")
        }
    }

    func testScriptReplacingATableRemovesMissingChildren() throws {
        let (model, queries) = Fixtures.richModel()
        let script = """
        createOrReplace

        \ttable Customer
        \t\tcolumn 'Customer Key'
        \t\t\tdataType: int64
        \t\t\tsummarizeBy: none
        \t\tcolumn Region
        \t\t\tdataType: string

        \ttable Budget
        \t\tcolumn Amount
        \t\t\tdataType: double

        \trole Auditor
        \t\tmodelPermission: read
        \t\ttablePermission Budget = [Amount] > 0
        """
        let (after, summary) = try TMDL.apply(script: script, to: model)
        XCTAssertEqual(after.table("Customer")?.columns.map(\.name), ["Customer Key", "Region"])
        XCTAssertEqual(after.table("Customer")?.id, model.table("Customer")?.id, "ids are kept when the script carries none")
        XCTAssertEqual(after.table("Customer")?.column("Customer Key")?.id, model.table("Customer")?.column("Customer Key")?.id)
        XCTAssertNotNil(after.table("Budget"))
        XCTAssertEqual(after.roles.last?.tableFilters, ["Budget": "[Amount] > 0"])
        XCTAssertTrue(summary.added.contains(TMDLChange(kind: .added, objectType: "table", name: "Budget")))
        XCTAssertTrue(summary.added.contains(TMDLChange(kind: .added, objectType: "column", name: "Customer[Region]")))
        XCTAssertTrue(summary.added.contains(TMDLChange(kind: .added, objectType: "role", name: "Auditor")))
        XCTAssertTrue(summary.removed.contains(TMDLChange(kind: .removed, objectType: "column", name: "Customer[City]")))
        XCTAssertTrue(summary.removed.contains(TMDLChange(kind: .removed, objectType: "hierarchy", name: "Customer[Geography]")))
        XCTAssertTrue(summary.changed.contains(TMDLChange(kind: .changed, objectType: "table", name: "Customer")))
        XCTAssertFalse(summary.changes.contains { $0.name.hasPrefix("Sales") })
        _ = queries

        // Scripts that would corrupt the model are refused.
        XCTAssertThrowsError(try TMDL.apply(script: "createOrReplace\n\tref table Nope\n\t\tmeasure A = 1\n", to: model))
        XCTAssertThrowsError(try TMDL.apply(script: "createOrReplace\n\tref table Customer\n\t\tmeasure 'Total Sales' = 1\n", to: model)) {
            XCTAssertTrue(($0 as? TMDLError)?.message.contains("unique") == true)
        }
    }

    func testObjectRefParsing() {
        XCTAssertEqual(TMDLObjectRef(parsing: "model"), .model)
        XCTAssertEqual(TMDLObjectRef(parsing: "table:Sales"), .table("Sales"))
        XCTAssertEqual(TMDLObjectRef(parsing: "measure:Sales[Total Sales]"), .measure(table: "Sales", name: "Total Sales"))
        XCTAssertEqual(TMDLObjectRef(parsing: "column: 'My Table'[Col]"), .column(table: "My Table", name: "Col"))
        XCTAssertEqual(TMDLObjectRef(parsing: "role:Sales West"), .role("Sales West"))
        XCTAssertNil(TMDLObjectRef(parsing: "measure:NoBrackets"))
        XCTAssertNil(TMDLObjectRef(parsing: "widget:x"))
    }

    func testObjectRefDescriptionRoundTrips() {
        let refs: [TMDLObjectRef] = [.model, .modelProperties, .table("Sales"), .column(table: "Sales", name: "Amount"),
                                     .measure(table: "Sales", name: "Total Sales"), .hierarchy(table: "Customer", name: "Geography"),
                                     .calculationGroup("Time"), .relationship(UUID()), .relationships, .role("Sales West"),
                                     .perspective("Executive"), .culture("fr-FR"), .function("AddTax"), .expression("BasePath")]
        for ref in refs {
            XCTAssertEqual(TMDLObjectRef(parsing: ref.description), ref, "\(ref.description) didn't round-trip")
        }
        XCTAssertEqual(TMDLObjectRef(parsing: "measure:Sales[Total Sales]")?.description, "measure:Sales[Total Sales]")
    }

    func testObjectRefAwkwardNamesRoundTrip() {
        // Written form: quoted only when needed, with '' for a quote inside a quoted name.
        XCTAssertEqual(TMDLObjectRef.table("Sales [2024]").description, "table:'Sales [2024]'")
        XCTAssertEqual(TMDLObjectRef.measure(table: "Sales [2024]", name: "Total [All]").description,
                       "measure:'Sales [2024]'['Total [All]']")
        XCTAssertEqual(TMDLObjectRef.table("'Quoted").description, "table:'''Quoted'")
        XCTAssertEqual(TMDLObjectRef.table(" Padded ").description, "table:' Padded '")
        XCTAssertEqual(TMDLObjectRef.column(table: "It's", name: "Don't").description, "column:It's[Don't]")

        let awkward: [TMDLObjectRef] = [
            .table("Sales [2024]"), .table(" Padded "), .table("'Quoted"), .table("'Quoted'"), .table("URL: home"),
            .table("a]b"), .table("It's"), .table("Tab\tEnd\t"),
            .column(table: "Sales [2024]", name: "Amount"),
            .column(table: "'Quoted", name: "It's = odd"),
            .column(table: "It's", name: "Don't"),
            .measure(table: "Sales [2024]", name: "Total [All]"),
            .measure(table: "URL: home", name: " A[b]c "),
            .measure(table: "Sales", name: "'x'"),
            .measure(table: " T ", name: "]"),
            .hierarchy(table: "Geo [old]", name: "'H"),
            .calculationGroup("Time [Calc]"), .role(" West "), .perspective("'P'"), .culture("[x]"),
            .function("f[1]"), .expression("'Base Path'"),
        ]
        for ref in awkward {
            XCTAssertEqual(TMDLObjectRef(parsing: ref.description), ref, "\(ref.description) didn't round-trip")
        }
        // The plain forms keep parsing, with spaces around the argument ignored.
        XCTAssertEqual(TMDLObjectRef(parsing: "table: Sales "), .table("Sales"))
        XCTAssertEqual(TMDLObjectRef(parsing: "table:'My Table'"), .table("My Table"))
        XCTAssertEqual(TMDLObjectRef(parsing: "column: 'My Table'[Col]"), .column(table: "My Table", name: "Col"))
        XCTAssertNil(TMDLObjectRef(parsing: "table:"))
        XCTAssertNil(TMDLObjectRef(parsing: "measure:Sales"))
        XCTAssertNil(TMDLObjectRef(parsing: "measure:[Total]"))
        XCTAssertNil(TMDLObjectRef(parsing: "measure:Sales[]"))
        XCTAssertNil(TMDLObjectRef(parsing: "measure:Sales[Total"))
    }

    func testSharedExpressionsExcludesTablePartitions() {
        let (model, queries) = Fixtures.richModel()
        let shared = TMDL.sharedExpressions(model: model, queries: queries)
        // Sales and Customer Source are loaded as table partitions; BasePath and fnClean are shared.
        XCTAssertEqual(shared.map(\.name), ["BasePath", "fnClean"])
        // Every shared expression scripts.
        for q in shared {
            XCTAssertNoThrow(try TMDL.script(for: .expression(q.name), in: model, queries: queries))
        }
        XCTAssertThrowsError(try TMDL.script(for: .expression("Nope"), in: model, queries: queries))
    }

    func testTextDiff() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...20).map { "line \($0)" }
        lines[4] = "line five"
        lines.remove(at: 14)
        lines.append("line 21")
        let new = lines.joined(separator: "\n")
        let hunks = TextDiff.diff(old: old, new: new, context: 2)
        XCTAssertEqual(hunks.count, 3)
        XCTAssertEqual(hunks[0].header, "@@ -3,5 +3,5 @@")
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.context, .context, .removed, .added, .context, .context])
        XCTAssertEqual(hunks[0].lines[2].text, "line 5")
        XCTAssertEqual(hunks[0].lines[2].oldNumber, 5)
        XCTAssertNil(hunks[0].lines[2].newNumber)
        XCTAssertEqual(hunks[0].lines[3].text, "line five")
        XCTAssertEqual(hunks[0].lines[3].newNumber, 5)
        XCTAssertEqual(hunks[1].header, "@@ -13,5 +13,4 @@")
        XCTAssertEqual(hunks[2].lines.last?.text, "line 21")
        XCTAssertEqual(TextDiff.stats(hunks), TextDiff.Stats(added: 2, removed: 2))
        XCTAssertTrue(TextDiff.diff(old: old, new: old).isEmpty)
        XCTAssertEqual(TextDiff.unified(old: "a\nb\n", new: "a\nc\n"), "--- before\n+++ after\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n")
        XCTAssertEqual(TextDiff.diff(old: "", new: "x\ny")[0].header, "@@ -0,0 +1,2 @@")

        // Applying the edit script reconstructs the new text for random inputs (minimality aside, it must be correct).
        var g = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let a = (0..<Int.random(in: 0...40, using: &g)).map { _ in String(Int.random(in: 0...6, using: &g)) }
            let b = (0..<Int.random(in: 0...40, using: &g)).map { _ in String(Int.random(in: 0...6, using: &g)) }
            let merged = TextDiff.lines(old: a.joined(separator: "\n"), new: b.joined(separator: "\n"))
            XCTAssertEqual(merged.filter { $0.kind != .added }.map(\.text), a)
            XCTAssertEqual(merged.filter { $0.kind != .removed }.map(\.text), b)
        }
        // Myers finds the shortest script: ABCABBA → CBABAC needs 5 edits.
        let ops = TextDiff.script(Array("ABCABBA"), Array("CBABAC"))
        XCTAssertEqual(ops.filter { $0 != .equal }.count, 5)
    }
}
