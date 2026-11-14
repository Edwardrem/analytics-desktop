import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

final class GetDataCatalogTests: XCTestCase {
    func testCatalogCoversEveryPowerBICategory() {
        XCTAssertEqual(DataConnector.Category.allCases.map(\.rawValue),
                       ["File", "Database", "Microsoft Fabric", "Power Platform", "Azure", "Online Services", "Other"])
        for category in DataConnector.Category.allCases {
            XCTAssertFalse(DataConnector.matching("", in: category).isEmpty, "\(category.rawValue) is empty")
        }
        XCTAssertEqual(Set(DataConnector.all.map(\.id)).count, DataConnector.all.count, "connector ids repeat")
    }

    func testOnlyEngineBackedConnectorsCanBeStarted() {
        let available = Set(DataConnector.all.filter(\.isAvailable).map(\.id))
        XCTAssertEqual(available, ["excel", "csv", "xml", "json", "folder", "sqlite", "web", "odata", "python", "r", "blank",
                                   "parquet", "sharepoint-folder", "onedrive-file", "sharepoint-list", "fabric-models", "fabric-lakehouses",
                                   "dataverse", "dynamics365", "azure-blob", "azure-adls2", "azure-adx"])
        // Every kind the session implements is offered exactly once.
        for kind in SourceKind.allCases { XCTAssertEqual(DataConnector.all.filter { $0.kind == kind }.count, 1, "\(kind)") }
    }

    func testUnavailableConnectorsSayWhatIsMissing() {
        for c in DataConnector.all where !c.isAvailable {
            XCTAssertNotNil(c.unavailableReason, c.name)
            XCTAssertFalse((c.unavailableReason ?? "").isEmpty, c.name)
        }
        XCTAssertEqual(DataConnector.connector("sqlserver")?.unavailableReason, "Needs a database driver, which this app does not include.")
        XCTAssertEqual(DataConnector.connector("postgresql")?.isAvailable, false)
        XCTAssertNil(DataConnector.connector("parquet")?.unavailableReason)
        XCTAssertEqual(DataConnector.connector("fabric-warehouses")?.isAvailable, false)
        XCTAssertEqual(DataConnector.connector("sharepoint-onprem")?.isAvailable, false)
        XCTAssertNil(DataConnector.connector("csv")?.unavailableReason)
    }

    func testSearchMatchesNameWithinCategory() {
        XCTAssertEqual(DataConnector.matching("sqlite", in: nil).map(\.id), ["sqlite"])
        XCTAssertEqual(DataConnector.matching("SQL server", in: .database).map(\.id), ["sqlserver", "ssas"])
        XCTAssertTrue(DataConnector.matching("excel", in: .database).isEmpty)
    }
}

final class SourcePlannerTests: XCTestCase {
    func testSourceExpressions() {
        var csv = SourceRequest(kind: .csv, location: "/data/sales \"2024\".csv")
        csv.delimiter = ";"
        XCTAssertEqual(SourcePlanner.sourceExpression(csv),
                       "Csv.Document(File.Contents(\"/data/sales \"\"2024\"\".csv\"), [Delimiter = \";\", Encoding = 65001, QuoteStyle = QuoteStyle.Csv])")
        XCTAssertEqual(SourcePlanner.sourceExpression(SourceRequest(kind: .excel, location: "/b.xlsx")), "Excel.Workbook(File.Contents(\"/b.xlsx\"), null, true)")
        XCTAssertEqual(SourcePlanner.sourceExpression(SourceRequest(kind: .folder, location: " /in ")), "Folder.Files(\"/in\")")
        var web = SourceRequest(kind: .web, location: "https://example.com/t")
        web.webContent = .html
        XCTAssertEqual(SourcePlanner.sourceExpression(web), "Web.Page(Web.Contents(\"https://example.com/t\"))")
        web.webContent = .json
        XCTAssertEqual(SourcePlanner.sourceExpression(web), "Json.Document(Web.Contents(\"https://example.com/t\"))")
    }

    func testNativeQueryAddsAFoldingQueryStep() {
        var r = SourceRequest(kind: .sqlite, location: "/db.sqlite")
        XCTAssertEqual(SourcePlanner.sourceSteps(r).map(\.name), ["Source"])
        r.nativeQuery = "  select * from t where a = 'x'  "
        let steps = SourcePlanner.sourceSteps(r)
        XCTAssertEqual(steps.map(\.name), ["Source", "Query"])
        XCTAssertEqual(steps[1].expression, "Value.NativeQuery(Source, \"select * from t where a = 'x'\", null, [EnableFolding = true])")
    }

    func testNavigatorItemsOfWorkbookAndDatabaseShapes() throws {
        let sheet = MTable(names: ["A"], rows: [[.text("x")]])
        let workbook = MTable(names: ["Name", "Data", "Item", "Kind", "Hidden"], types: [.text, .anyTable, .text, .text, .logical],
                              rows: [[.text("Sales"), .table(sheet), .text("Sales"), .text("Sheet"), .logical(false)],
                                     [.text("Totals"), .table(sheet), .text("Totals"), .text("Table"), .logical(false)]])
        let items = try XCTUnwrap(try SourcePlanner.navigatorItems(from: .table(workbook)))
        XCTAssertEqual(items.map(\.name), ["Sales", "Totals"])
        XCTAssertEqual(items.map(\.kind), ["Sheet", "Table"])
        XCTAssertEqual(items[0].selector, "{[Item = \"Sales\", Kind = \"Sheet\"]}[Data]")
        XCTAssertEqual(items[0].stepName, "Sales_Sheet")

        let xml = MTable(names: ["Name", "Table"], types: [.text, .anyTable], rows: [[.text("book"), .table(sheet)]])
        XCTAssertEqual(try SourcePlanner.navigatorItems(from: .table(xml))?.first?.selector, "{[Name = \"book\"]}[Table]")

        // HTML tables without captions are addressed by position.
        let page = MTable(names: ["Caption", "Source", "ClassName", "Id", "Data"], types: [.text, .text, .text, .text, .anyTable],
                          rows: [[.null, .text("Table"), .null, .null, .table(sheet)], [.null, .text("Table"), .null, .null, .table(sheet)]])
        let tables = try XCTUnwrap(try SourcePlanner.navigatorItems(from: .table(page)))
        XCTAssertEqual(tables.map(\.name), ["Table 1", "Table 2"])
        XCTAssertEqual(tables.map(\.selector), ["{0}[Data]", "{1}[Data]"])
    }

    func testOrdinaryTablesAreNotNavigation() throws {
        let data = MTable(names: ["Name", "Value"], rows: [[.text("a"), .text("1")]])
        XCTAssertNil(try SourcePlanner.navigatorItems(from: .table(data)))
        XCTAssertNil(try SourcePlanner.navigatorItems(from: .list([.number(1)])))
    }

    func testBaseStepsNavigateFromTheLastSourceStep() {
        let item = NavigatorItem(name: "Sales", kind: "Sheet", selector: "{[Item = \"Sales\", Kind = \"Sheet\"]}[Data]", stepName: "Sales_Sheet")
        let steps = SourcePlanner.baseSteps(SourceRequest(kind: .excel, location: "/b.xlsx"), item: item)
        XCTAssertEqual(MScript.script(from: steps), """
        let
            Source = Excel.Workbook(File.Contents("/b.xlsx"), null, true),
            Sales_Sheet = Source{[Item = "Sales", Kind = "Sheet"]}[Data]
        in
            Sales_Sheet
        """)
    }

    func testTableConversionOfJsonShapes() {
        let ann = MRecord([("id", .number(1)), ("name", .text("Ann"))]), bob = MRecord([("id", .number(2)), ("city", .text("Oslo"))])
        XCTAssertEqual(SourcePlanner.tableConversion(of: .list([.record(ann), .record(bob)]), previous: "Source").map(\.expression),
                       ["Table.FromRecords(Source, {\"id\", \"name\", \"city\"}, MissingField.UseNull)"])
        XCTAssertEqual(SourcePlanner.tableConversion(of: .list([.number(1), .number(2)]), previous: "Source").map(\.expression),
                       ["Table.FromColumns({Source}, {\"Value\"})"])
        XCTAssertEqual(SourcePlanner.tableConversion(of: .record(ann), previous: "Source").map(\.expression), ["Record.ToTable(Source)"])
        XCTAssertEqual(SourcePlanner.tableConversion(of: .text("x"), previous: "Source").map(\.expression), ["#table({\"Value\"}, {{Source}})"])
        XCTAssertTrue(SourcePlanner.tableConversion(of: .table(MTable(names: ["A"], rows: [])), previous: "Source").isEmpty)
    }

    func testHeaderRowDetection() {
        func table(_ names: [String], _ rows: [[String]]) -> DataTable {
            DataTable(columnNames: names, rows: rows.map { $0.map { Value.string($0) } }, types: names.map { _ in .text })
        }
        XCTAssertTrue(SourcePlanner.looksLikeHeaderRow(table(["Column1", "Column2"], [["Region", "Sales"], ["North", "10"]])))
        XCTAssertFalse(SourcePlanner.looksLikeHeaderRow(table(["Column1", "Column2"], [["2023", "Sales"], ["North", "10"]])), "a number is not a header")
        XCTAssertFalse(SourcePlanner.looksLikeHeaderRow(table(["Column1", "Column2"], [["Region", "Region"], ["North", "10"]])), "headers must differ")
        XCTAssertFalse(SourcePlanner.looksLikeHeaderRow(table(["Column1", "Column2"], [["Region", "Sales"]])), "no data below")
        XCTAssertFalse(SourcePlanner.looksLikeHeaderRow(table(["Region", "Sales"], [["A", "B"], ["North", "10"]])), "already has headers")
    }

    func testDelimiterDetection() {
        XCTAssertEqual(SourcePlanner.detectDelimiter("a,b,c\n1,2,3\n"), ",")
        XCTAssertEqual(SourcePlanner.detectDelimiter("a;b;c\n1,5;2;3\n"), ";")
        XCTAssertEqual(SourcePlanner.detectDelimiter("a\tb\n1\t2\n"), "\t")
        XCTAssertEqual(SourcePlanner.detectDelimiter("name|note\n\"x|y\"|z\n"), "|")
        XCTAssertEqual(SourcePlanner.detectDelimiter("single column\nvalue\n"), ",")
        XCTAssertEqual(SourcePlanner.detectDelimiter(""), ",")
    }

    func testWebContentSniffing() {
        func kind(_ text: String, _ address: String = "https://h/data") -> WebContentKind { SourcePlanner.sniffWeb(Data(text.utf8), address: address) }
        XCTAssertEqual(kind("  [{\"a\":1}]"), .json)
        XCTAssertEqual(kind("<!DOCTYPE html><html><body></body></html>"), .html)
        XCTAssertEqual(kind("<?xml version=\"1.0\"?><rows><row/></rows>"), .xml)
        XCTAssertEqual(kind("a,b\n1,2"), .csv)
        XCTAssertEqual(kind("a,b\n1,2", "https://h/report.json"), .json)
        XCTAssertEqual(SourcePlanner.sniffWeb(Data([0x50, 0x4B, 0x03, 0x04, 0x00]), address: "https://h/x"), .excel)
    }

    func testNamesAndUniqueness() {
        XCTAssertEqual(SourcePlanner.queryName(SourceRequest(kind: .csv, location: "/data/sales.2024.csv"), item: nil), "sales.2024")
        XCTAssertEqual(SourcePlanner.queryName(SourceRequest(kind: .folder, location: "/data/invoices"), item: nil), "invoices")
        XCTAssertEqual(SourcePlanner.queryName(SourceRequest(kind: .web, location: "https://example.com/files/prices.csv?x=1"), item: nil), "prices")
        XCTAssertEqual(SourcePlanner.queryName(SourceRequest(kind: .web, location: "https://example.com"), item: nil), "example.com")
        XCTAssertEqual(SourcePlanner.uniqueName("Sales", taken: []), "Sales")
        XCTAssertEqual(SourcePlanner.uniqueName("Sales", taken: ["Sales", "Sales (2)"]), "Sales (3)")
        XCTAssertEqual(SourcePlanner.uniqueName("  ", taken: []), "Query")
    }

    func testValidation() {
        XCTAssertEqual(SourcePlanner.validationMessage(SourceRequest(kind: .csv)), "Choose a file.")
        XCTAssertEqual(SourcePlanner.validationMessage(SourceRequest(kind: .web, location: "example.com/x")), "The address must start with http:// or https://.")
        XCTAssertNil(SourcePlanner.validationMessage(SourceRequest(kind: .odata, location: "https://example.com/svc")))
        XCTAssertNotNil(SourcePlanner.validationMessage(SourceRequest(kind: .excel, location: "/old.xls")), ".xls is refused before connecting")
        XCTAssertNil(SourcePlanner.validationMessage(SourceRequest(kind: .excel, location: "/new.xlsx")))
        XCTAssertNil(SourcePlanner.validationMessage(SourceRequest(kind: .blank)))
    }

    func testDataSourceMatchesWhatTheEngineRecords() {
        XCTAssertEqual(SourcePlanner.dataSource(SourceRequest(kind: .sqlite, location: "/db/a.sqlite")), QueryDataSource(kind: "SQLite", location: "/db/a.sqlite"))
        XCTAssertEqual(SourcePlanner.dataSource(SourceRequest(kind: .web, location: "https://example.com/a/b.csv")), QueryDataSource(kind: "Web", location: "https://example.com"))
        XCTAssertNil(SourcePlanner.dataSource(SourceRequest(kind: .blank)))
    }

    func testCombinePlanPicksTheMostCommonSupportedFormat() {
        let plan = SourcePlanner.combinePlan(extensions: [".CSV", ".csv", ".json", ".png"]) { _ in "a;b\n1;2\n" }
        XCTAssertEqual(plan?.extension, ".csv")
        guard case .csv(let delimiter, let promote)? = plan?.format else { return XCTFail("expected csv") }
        XCTAssertEqual(delimiter, ";")
        XCTAssertTrue(promote)
        XCTAssertNil(SourcePlanner.combinePlan(extensions: [".png", ".pdf"]) { _ in nil })
        let steps = SourcePlanner.combineSteps(extension: ".csv", format: .csv(delimiter: ";", promoteHeaders: true))
        XCTAssertEqual(steps.map(\.name), ["Filtered Files", "Combined Files"])
        XCTAssertEqual(steps[0].expression, "Table.SelectRows(Source, each Text.Lower([Extension]) = \".csv\")")
        XCTAssertTrue(steps[1].expression.hasPrefix("Table.Combine(List.Transform(Table.ToRecords(Table.SelectRows(#\"Filtered Files\","))
    }

    func testChangeSourceReplacesOnlyWholeLiterals() {
        let script = "let Source = Csv.Document(File.Contents(\"/a/b.csv\")), Other = \"/a/b.csv.bak\" in Source"
        XCTAssertEqual(SourcePlanner.replacingLocation("/a/b.csv", with: "/c/d.csv", in: script),
                       "let Source = Csv.Document(File.Contents(\"/c/d.csv\")), Other = \"/a/b.csv.bak\" in Source")
    }
}

final class EnteredTableTests: XCTestCase {
    func testParsesTabSeparatedPasteAndPadsShortRows() {
        let t = EnteredTable.parse("Name\tQty\t\nPen\t3\tx\n\nInk\n")
        XCTAssertEqual(t?.header, ["Name", "Qty", "Column3"])
        XCTAssertEqual(t?.rows, [["Pen", "3", "x"], ["Ink", "", ""]])
    }

    func testCommaSeparatedWithQuotesAndDuplicateHeaders() {
        let t = EnteredTable.parse("City,City\n\"Oslo, NO\",Rome")
        XCTAssertEqual(t?.header, ["City", "City 2"])
        XCTAssertEqual(t?.rows, [["Oslo, NO", "Rome"]])
        XCTAssertNil(EnteredTable.parse("  \n"))
    }

    func testScriptKeepsEveryRowAndTypesColumns() async throws {
        let t = try XCTUnwrap(EnteredTable.parse("Name\tQty\nPen\t3\nInk\t\nCap\t10"))
        XCTAssertEqual(MScript.steps(of: t.script).map(\.name), ["Source", "Changed Type"])
        XCTAssertEqual(MScript.steps(of: t.script).first?.expression,
                       "#table({\"Name\", \"Qty\"}, {{\"Pen\", \"3\"}, {\"Ink\", null}, {\"Cap\", \"10\"}})")
        let engine = QueryEngine(queries: [QueryDefinition(name: "T", mScript: t.script)], environment: QueryEnvironment())
        let table = try await engine.evaluate("T")
        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(table.column("Qty")?.type, .integer)
        XCTAssertEqual(table.column("Qty")?.values, [.int(3), .null, .int(10)])
        XCTAssertEqual(table.column("Name")?.values, [.string("Pen"), .string("Ink"), .string("Cap")])
    }
}

final class QuerySecurityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "QuerySecurityTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testPrivacyLevelsReachTheEnvironmentAndTheFirewallIsOnByDefault() {
        let security = QuerySecurity(defaults: defaults)
        security.setPrivacyLevel(.private, kind: "File", location: "/a.csv")
        security.setPrivacyLevel(.public, kind: "Web", location: "https://example.com")
        let env = security.environment(baseDirectory: nil)
        XCTAssertTrue(env.enforcePrivacyFirewall)
        XCTAssertEqual(env.privacyLevel(kind: "File", location: "/a.csv"), .private)
        XCTAssertEqual(env.privacyLevel(kind: "Web", location: "https://example.com"), .public)
        XCTAssertEqual(env.privacyLevel(kind: "File", location: "/other.csv"), PrivacyLevel.none)
        security.ignorePrivacyLevels = true
        XCTAssertFalse(security.environment(baseDirectory: nil).enforcePrivacyFirewall)
    }

    func testNativeQueriesRunOnlyAfterApprovalForThatSource() {
        let security = QuerySecurity(defaults: defaults)
        func allowed(_ sql: String, _ location: String) -> Bool {
            let env = security.environment(baseDirectory: nil)
            XCTAssertTrue(env.requireNativeQueryApproval)
            return env.approveNativeQuery?(NativeQueryRequest(query: sql, sourceKind: "SQLite", sourceLocation: location)) ?? false
        }
        XCTAssertFalse(allowed("select 1", "/a.db"))
        security.approve(query: " select 1\n", kind: "SQLite", location: "/a.db")
        XCTAssertTrue(allowed("select 1", "/a.db"))
        XCTAssertFalse(allowed("select 2", "/a.db"), "another statement needs its own approval")
        XCTAssertFalse(allowed("select 1", "/b.db"), "approval is per database")
        XCTAssertEqual(security.approvedQueryCount(kind: "SQLite", location: "/a.db"), 1)
    }

    func testClearPermissionsForgetsOneSource() {
        let security = QuerySecurity(defaults: defaults)
        security.setPrivacyLevel(.organizational, kind: "SQLite", location: "/a.db")
        security.setPrivacyLevel(.public, kind: "File", location: "/b.csv")
        security.approve(query: "select 1", kind: "SQLite", location: "/a.db")
        XCTAssertEqual(security.sourcesWithPermissions, [QueryDataSource(kind: "File", location: "/b.csv"), QueryDataSource(kind: "SQLite", location: "/a.db")])
        security.clearPermissions(kind: "SQLite", location: "/a.db")
        XCTAssertEqual(security.privacyLevel(kind: "SQLite", location: "/a.db"), PrivacyLevel.none)
        XCTAssertFalse(security.isApproved(query: "select 1", kind: "SQLite", location: "/a.db"))
        XCTAssertEqual(security.sourcesWithPermissions, [QueryDataSource(kind: "File", location: "/b.csv")])
        security.allowScripts = true
        security.clearAllPermissions()
        XCTAssertTrue(security.sourcesWithPermissions.isEmpty)
        XCTAssertFalse(security.environment(baseDirectory: nil).allowScripts)
    }

    /// The privacy, native query, scripting and import locale options in Settings are the ones the engine runs with.
    func testSettingsOptionsReachTheEnvironment() {
        let security = QuerySecurity(defaults: defaults)
        var env = security.environment(baseDirectory: nil)
        XCTAssertTrue(env.enforcePrivacyFirewall)
        XCTAssertTrue(env.requireNativeQueryApproval, "asking is on until Settings turns it off")
        XCTAssertFalse(env.allowScripts)
        XCTAssertNil(env.pythonPath)
        XCTAssertEqual(env.culture, "en-US")

        defaults.set("ignore", forKey: AppSettings.Key.privacyMode.rawValue)
        defaults.set(false, forKey: AppSettings.Key.requireNativeQueryApproval.rawValue)
        defaults.set(true, forKey: AppSettings.Key.allowScripts.rawValue)
        defaults.set("/opt/homebrew/bin/python3", forKey: AppSettings.Key.pythonPath.rawValue)
        defaults.set("  ", forKey: AppSettings.Key.rPath.rawValue)
        defaults.set("de-DE", forKey: AppSettings.Key.importLocale.rawValue)
        env = security.environment(baseDirectory: nil)
        XCTAssertTrue(security.ignorePrivacyLevels)
        XCTAssertFalse(env.enforcePrivacyFirewall)
        XCTAssertFalse(env.requireNativeQueryApproval)
        XCTAssertTrue(env.allowScripts)
        XCTAssertEqual(env.pythonPath, "/opt/homebrew/bin/python3")
        XCTAssertNil(env.rPath, "a blank path means the usual places")
        XCTAssertEqual(env.culture, "de-DE")

        // Turning the toggle back writes the Settings choice.
        security.ignorePrivacyLevels = false
        XCTAssertEqual(defaults.string(forKey: AppSettings.Key.privacyMode.rawValue), "combine")
        defaults.set("file", forKey: AppSettings.Key.privacyMode.rawValue)
        XCTAssertTrue(security.environment(baseDirectory: nil).enforcePrivacyFirewall, "per-file combining still applies privacy levels")
    }

    func testRecentSourcesAreNewestFirstWithoutDuplicates() {
        let security = QuerySecurity(defaults: defaults)
        security.noteRecent(kind: .csv, location: "/a.csv", at: Date(timeIntervalSince1970: 1))
        security.noteRecent(kind: .sqlite, location: "/b.db", at: Date(timeIntervalSince1970: 2))
        security.noteRecent(kind: .csv, location: " /a.csv ", at: Date(timeIntervalSince1970: 3))
        security.noteRecent(kind: .blank, location: "")
        XCTAssertEqual(security.recentSources.map(\.location), ["/a.csv", "/b.db"])
        XCTAssertEqual(security.recentSources.first?.lastUsed, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(security.recentSources.first?.displayName, "a.csv")
        for i in 0..<30 { security.noteRecent(kind: .json, location: "/f\(i).json") }
        XCTAssertEqual(security.recentSources.count, QuerySecurity.maxRecentSources)
        XCTAssertEqual(security.recentSources.first?.location, "/f29.json")
    }
}

final class EditParametersTests: XCTestCase {
    private func parameter(_ name: String, _ value: Value, type: DataType, list: [Value] = []) -> QueryDefinition {
        var p = QueryParameter()
        p.type = type; p.currentValue = value; p.suggestedValues = list
        var q = QueryDefinition(name: name, mScript: MScript.parameterScript(p))
        q.kind = .parameter
        q.parameter = p
        return q
    }

    func testTypedValuesReplaceTheCurrentValues() throws {
        let year = parameter("Year", .int(2024), type: .integer)
        let region = parameter("Region", .string("North"), type: .text, list: [.string("North"), .string("South")])
        let sales = QueryDefinition(name: "Sales", mScript: "let\n    Source = Year\nin\n    Source")
        let after = try XCTUnwrap(EditParametersSheet.applying([year.id: "2025", region.id: "South"], to: [year, region, sales]))
        XCTAssertEqual(after[0].parameter?.currentValue, .int(2025))
        XCTAssertEqual(after[0].mScript, "2025 meta [IsParameterQuery=true, Type=\"Number\", IsParameterQueryRequired=true]")
        XCTAssertEqual(after[1].parameter?.currentValue, .string("South"))
        XCTAssertEqual(after[1].parameter?.suggestedValues, [.string("North"), .string("South")])
        XCTAssertEqual(after[2], sales)
        XCTAssertNil(EditParametersSheet.applying([year.id: "next year"], to: [year]), "a whole number parameter refuses text")
        XCTAssertNil(EditParametersSheet.applying([year.id: ""], to: [year]), "a required parameter needs a value")
    }

    func testParameterDraftReadsAndWritesAParameter() {
        let q = parameter("Cutoff", .double(2.5), type: .decimal, list: [.double(2.5), .double(5)])
        let draft = ParameterDraft(q)
        XCTAssertTrue(draft.listMode)
        XCTAssertEqual(draft.list, "2.5\n5")
        XCTAssertEqual(draft.current, "2.5")
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.parameter, q.parameter)
        var empty = ParameterDraft()
        empty.listMode = true
        empty.current = "x"
        XCTAssertEqual(empty.problem, "Add at least one suggested value, one per line.")
    }
}
