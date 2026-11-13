import XCTest
import FacetCore
@testable import FacetQuery

/// Privacy levels and the data privacy firewall, the query engine (previews, refresh, diagnostics, DirectQuery),
/// data profiling and the table functions the UI transforms do not reach.
final class EngineAndPrivacyTests: TransformTestCase {
    private func combine(_ a: String = "a.csv", _ b: String = "b.csv") -> String {
        "Table.Combine({Csv.Document(File.Contents(\"\(a)\")), Csv.Document(File.Contents(\"\(b)\"))})"
    }
    private func levels(_ a: PrivacyLevel, _ b: PrivacyLevel) throws {
        env.privacyLevels = ["File:" + dir.appendingPathComponent("a.csv").path: a, "File:" + dir.appendingPathComponent("b.csv").path: b]
    }

    func testFirewallBlocksIncompatiblePrivacyLevels() throws {
        try write("a.csv", "1\n"); try write("b.csv", "2\n")
        env.enforcePrivacyFirewall = true
        // Private data may not be combined with any other source; Organizational not with Public
        for (a, b) in [(PrivacyLevel.private, PrivacyLevel.public), (.public, .private), (.private, .organizational), (.private, .private), (.organizational, .public)] {
            try levels(a, b)
            let e = try XCTUnwrap(failure(combine()), "\(a) + \(b)")
            XCTAssertEqual(e.reason, "Formula.Firewall")
            XCTAssertTrue(e.message.contains("a.csv") && e.message.contains("b.csv"), e.message)
        }
        try levels(.private, .public)
        let message = try XCTUnwrap(failure(combine())).message
        XCTAssertTrue(message.contains("Public source") && message.contains("Private source"), message)
    }
    func testFirewallAllowsCompatibleLevelsAndCanBeTurnedOff() throws {
        try write("a.csv", "1\n"); try write("b.csv", "2\n")
        env.enforcePrivacyFirewall = true
        for (a, b) in [(PrivacyLevel.public, PrivacyLevel.public), (.organizational, .organizational), (.none, .private), (.public, .none), (.none, .none)] {
            try levels(a, b)
            XCTAssertEqual(try rows(combine()), [["1"], ["2"]], "\(a) + \(b)")
        }
        // one source used twice is still one source
        try levels(.private, .private)
        XCTAssertEqual(try rows(combine("a.csv", "a.csv")), [["1"], ["1"]])
        env.enforcePrivacyFirewall = false
        try levels(.private, .public)
        XCTAssertEqual(try rows(combine()), [["1"], ["2"]])
    }
    func testPrivacyLevelLookup() throws {
        var e = QueryEnvironment()
        e.privacyLevels = ["File:/data/sales/2024.csv": .public, "/data/sales": .organizational, "/data": .private, "SQLite:/db/shop.db": .organizational]
        XCTAssertEqual(e.privacyLevel(kind: "File", location: "/data/sales/2024.csv"), .public) // exact kind:location
        XCTAssertEqual(e.privacyLevel(kind: "File", location: "/data/sales/2023.csv"), .organizational) // longest prefix
        XCTAssertEqual(e.privacyLevel(kind: "File", location: "/data/other.csv"), .private)
        XCTAssertEqual(e.privacyLevel(kind: "SQLite", location: "/db/shop.db"), .organizational)
        XCTAssertEqual(e.privacyLevel(kind: "File", location: "/db/shop.db"), .none) // the key names another kind
        XCTAssertEqual(e.privacyLevel(kind: "Web", location: "https://example.com"), .none)
    }
    func testFirewallAcrossQueriesAndSourceKinds() async throws {
        try write("a.csv", "1\n"); try write("b.csv", "2\n")
        try TestSQLite.create(at: dir.appendingPathComponent("p.db").path, ["create table t (x integer)", "insert into t values (7)"])
        env.enforcePrivacyFirewall = true
        try levels(.private, .public)
        let queries = [("A", "Csv.Document(File.Contents(\"a.csv\"))"), ("B", "Csv.Document(File.Contents(\"b.csv\"))"), ("C", "Table.Combine({A, B})")]
        do { _ = try await engine(queries).evaluate("C"); XCTFail("expected the firewall") } catch { XCTAssertEqual(MError.wrap(error).reason, "Formula.Firewall") }
        // each query alone is fine; the combining query fails in a refresh too
        let results = await engine(queries).refreshAll()
        XCTAssertNoThrow(try results["A"]?.get()); XCTAssertNoThrow(try results["B"]?.get())
        XCTAssertThrowsError(try results["C"]?.get()) { XCTAssertEqual(MError.wrap($0).reason, "Formula.Firewall") }
        // a database and a file are checked the same way
        env.privacyLevels["SQLite:" + dir.appendingPathComponent("p.db").path] = .organizational
        let mixed = "Table.RowCount(Csv.Document(File.Contents(\"b.csv\"))) + Table.RowCount(Sqlite.Database(\"p.db\"){[Name = \"t\"]}[Data])"
        XCTAssertEqual(try XCTUnwrap(failure(mixed)).reason, "Formula.Firewall") // Public file + Organizational database
        env.privacyLevels["SQLite:" + dir.appendingPathComponent("p.db").path] = .public
        XCTAssertEqual(try eval(mixed).numberValue, 2)
    }
    func testFilesOfAPrivateFolderCombineWithEachOther() throws {
        try write("data/a.csv", "k\n1\n"); try write("data/b.csv", "k\n2\n"); try write("other.csv", "k\n3\n")
        env.enforcePrivacyFirewall = true
        env.privacyLevels = [dir.appendingPathComponent("data").path: .private]
        let combined = MScript.appending(.combineFiles(.csv(delimiter: ",", promoteHeaders: true)), to: "let\n    Source = Folder.Files(\"data\")\nin\n    Source")
        XCTAssertEqual(try rows(combined), [["1", "a.csv"], ["2", "b.csv"]]) // the folder is one source
        env.privacyLevels[dir.appendingPathComponent("other.csv").path] = .public
        let leak = "Table.Combine({\(combined), Csv.Document(File.Contents(\"other.csv\"))})"
        XCTAssertEqual(try XCTUnwrap(failure(leak)).reason, "Formula.Firewall")
    }

    // MARK: Engine
    func testPreviewKeepsErrorsStructuredCellsAndTruncation() async throws {
        let q = "#table(type table [n = Int64.Type, v = any], {{1, [a = 1]}, {2, {1, 2}}, {3, #table({\"x\"}, {})}, {4, #binary({1})}, {5, (x) => x}, {6, \"plain\"}})"
        let e = engine([("Q", "let Source = \(q), Typed = Table.TransformColumnTypes(Source, {{\"v\", Int64.Type}}) in Typed"), ("L", "{1, 2, 3}"), ("R", "[a = 1, b = \"x\"]"), ("S", "42")])
        var p = try await e.evaluatePreview("Q", upToStep: 0)
        XCTAssertEqual(p.structuredCells[1], [0: "Record", 1: "List", 2: "Table", 3: "Binary", 4: "Function"])
        XCTAssertEqual(p.columnTypes, [.int64, .any])
        XCTAssertEqual(p.valueKind, "table")
        XCTAssertFalse(p.isTruncated)
        XCTAssertEqual(p.table.column("v")?.values.last, .string("plain"))
        p = try await e.evaluatePreview("Q", upToStep: 0, rowLimit: 4)
        XCTAssertTrue(p.isTruncated)
        XCTAssertEqual(p.table.rowCount, 4)
        p = try await e.evaluatePreview("Q") // structured values and text can't become whole numbers: six cell errors
        XCTAssertEqual(p.cellErrors[1]?.count, 6)
        XCTAssertNil(p.cellErrors[0])
        p = try await e.evaluatePreview("L")
        XCTAssertEqual(p.valueKind, "list"); XCTAssertEqual(p.table.columnNames, ["Value"]); XCTAssertEqual(p.table.rowCount, 3)
        p = try await e.evaluatePreview("R")
        XCTAssertEqual(p.valueKind, "record"); XCTAssertEqual(p.table.columnNames, ["Name", "Value"])
        XCTAssertEqual(p.table.column("Name")?.values, [.string("a"), .string("b")])
        let s = try await e.evaluate("S")
        XCTAssertEqual(s.columnNames, ["S"]); XCTAssertEqual(s.row(0), [.int(42)])
        let x = try await e.evaluateExpression("List.Sum(L) + S")
        XCTAssertEqual(x.numberValue, 48)
    }
    func testRefreshAllProgressAndDiagnostics() async throws {
        final class Log: @unchecked Sendable { let lock = NSLock(); var events: [String] = []
            func add(_ s: String) { lock.lock(); events.append(s); lock.unlock() } }
        var staging = QueryDefinition(name: "Staging", mScript: "let Source = #table({\"k\"}, {{1}, {2}, {3}}), T = Diagnostics.Trace(TraceLevel.Information, \"staging read\", Source) in T")
        staging.loadEnabled = false
        var skipped = QueryDefinition(name: "Manual", mScript: "#table({\"k\"}, {{0}})")
        skipped.includeInRefresh = false
        let queries = [staging, skipped,
                       QueryDefinition(name: "Big", mScript: "let Source = Staging, F = Table.SelectRows(Source, each [k] > 1) in F"),
                       QueryDefinition(name: "Small", mScript: "let Source = Staging, F = Table.SelectRows(Source, each [k] = 1) in F"),
                       QueryDefinition(name: "Broken", mScript: "let Source = Staging, F = Table.RemoveColumns(Source, {\"zz\"}) in F")]
        let e = QueryEngine(queries: queries, environment: env)
        let log = Log()
        let results = await e.refreshAll { p in
            switch p.phase {
            case .started: log.add("start \(p.query)")
            case .finished(let rows, _): log.add("done \(p.query) \(rows) of \(p.total)")
            case .failed(let message, _): log.add("fail \(p.query) \(message.contains("zz"))")
            }
        }
        // only load-enabled queries that are included in refresh are loaded
        XCTAssertEqual(results.keys.sorted(), ["Big", "Broken", "Small"])
        XCTAssertEqual(try results["Big"]?.get().column("k")?.values, [.int(2), .int(3)])
        XCTAssertEqual(try results["Small"]?.get().rowCount, 1)
        XCTAssertThrowsError(try results["Broken"]?.get())
        XCTAssertEqual(Set(log.events), ["start Big", "start Small", "start Broken", "done Big 2 of 3", "done Small 1 of 3", "fail Broken true"])
        XCTAssertTrue(e.traceMessages.contains("staging read"))
        let big = e.diagnostics.filter { $0.query == "Big" }
        XCTAssertEqual(big.map(\.step), ["Source", "F"])
        XCTAssertEqual(big.map(\.rowCount), [3, 2])
        XCTAssertEqual(big.map(\.valueKind), ["table", "table"])
        XCTAssertEqual(e.diagnostics.first { $0.query == "Broken" && $0.step == "F" }?.error?.contains("zz"), true)
        let only = await e.refreshAll(only: ["Manual", "Nope"])
        XCTAssertEqual(try only["Manual"]?.get().rowCount, 1)
        XCTAssertThrowsError(try only["Nope"]?.get())
    }
    func testDirectQueryFoldsViewTimeSteps() async throws {
        try TestSQLite.create(at: dir.appendingPathComponent("dq.db").path, [
            "create table sales (id integer, region text, amount real)",
            "insert into sales values (1, 'North', 10), (2, 'South', 25), (3, 'North', 40), (4, 'East', 5)"])
        let e = engine([("Sales", "let db = Sqlite.Database(\"dq.db\"), t = db{[Name = \"sales\"]}[Data], f = Table.SelectRows(t, each [amount] > 6) in f"),
                        ("Local", "#table({\"a\"}, {{1}, {2}})")])
        let dq = try e.directQuery("Sales")
        XCTAssertEqual(dq.queryName, "Sales")
        let base = try await dq.nativeQuery()
        XCTAssertEqual(base, "select \"id\", \"region\", \"amount\" from \"sales\" where (\"amount\" > 6)")
        let view: [Transform] = [.filterRows(.compare(column: "region", .equals, .string("North"))), .sortRows([("amount", true)]), .chooseColumns(["id", "amount"]), .keepTopRows(1)]
        let sql = try await dq.nativeQuery(applying: view)
        XCTAssertEqual(sql, "select \"id\", \"amount\" from \"sales\" where (\"amount\" > 6) and (\"region\" is 'North') order by \"amount\" desc limit 1")
        let top = try await dq.fetch(applying: view, rowLimit: nil)
        XCTAssertEqual(top.row(0), [.int(3), .double(40)])
        let all = try await dq.fetch(rowLimit: 2)
        XCTAssertEqual(all.column("id")?.values, [.int(1), .int(2)])
        // nothing is cached: new rows are seen by the next fetch
        try TestSQLite.create(at: dir.appendingPathComponent("dq.db").path, ["insert into sales values (5, 'North', 99)"])
        let again = try await dq.fetch(applying: view, rowLimit: nil)
        XCTAssertEqual(again.row(0), [.int(5), .double(99)])
        // a query without a foldable source still works, locally
        let local = try e.directQuery("Local")
        let none = try await local.nativeQuery()
        XCTAssertNil(none)
        let rows = try await local.fetch(applying: [.filterRows(.compare(column: "a", .greaterThan, .int(1)))], rowLimit: nil)
        XCTAssertEqual(rows.column("a")?.values, [.int(2)])
        XCTAssertThrowsError(try e.directQuery("Nope"))
    }

    // MARK: Profiling and table functions
    func testTableProfile() throws {
        let v = try m("Table.Profile(\(sales))")
        XCTAssertEqual(columnNames(v), ["Column", "Min", "Max", "Average", "StandardDeviation", "Count", "NullCount", "DistinctCount"])
        let r = try tableRows(v)
        XCTAssertEqual(r[0], ["Region", "East", "South", "null", "null", "5", "0", "3"])
        XCTAssertEqual(r[1], ["Product", "Apple", "Pear", "null", "null", "5", "0", "2"])
        XCTAssertEqual(Array(r[2].prefix(4)) + Array(r[2].suffix(3)), ["Qty", "3", "10", "6.25", "5", "1", "5"]) // the null is a distinct value
        XCTAssertEqual(try mNum("Table.Profile(\(sales)){2}[StandardDeviation]"), (26.75 / 3).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try mNum("Table.Profile(\(sales)){3}[Average]"), 1.7, accuracy: 1e-12)
        XCTAssertEqual(Array(r[3].suffix(3)), ["5", "0", "2"])
        XCTAssertEqual(try tableRows(try m("Table.SelectColumns(Table.Schema(\(sales)), {\"Name\", \"TypeName\", \"Kind\"})")),
                       [["Region", "Text.Type", "text"], ["Product", "Text.Type", "text"], ["Qty", "Int64.Type", "number"], ["Price", "Number.Type", "number"]])
    }
    func testTableConstructionAndConversion() throws {
        func t(_ e: String) throws -> [[String]] { try tableRows(try m(e)) }
        XCTAssertEqual(try t("Table.FromRecords({[a = 1, b = 2], [b = 4, a = 3]})"), [["1", "2"], ["3", "4"]])
        XCTAssertNotNil(mErr("Table.FromRecords({[a = 1, b = 2], [a = 3]})"))
        XCTAssertEqual(try t("Table.FromRecords({[a = 1, b = 2], [a = 3]}, null, MissingField.UseNull)"), [["1", "2"], ["3", "null"]])
        XCTAssertEqual(try t("Table.FromRecords({[a = 1, b = 2]}, {\"b\", \"c\"}, MissingField.UseNull)"), [["2", "null"]])
        XCTAssertEqual(columnNames(try m("Table.FromRows({{1, 2}})")), ["Column1", "Column2"])
        XCTAssertEqual(try t("Table.FromRows({{1, \"x\"}, {2, \"y\"}}, {\"n\", \"t\"})"), [["1", "x"], ["2", "y"]])
        XCTAssertNotNil(mErr("Table.FromRows({{1, 2}, {3}}, {\"a\", \"b\"})"))
        XCTAssertEqual(try t("Table.FromColumns({{1, 2, 3}, {\"x\"}}, {\"n\", \"t\"})"), [["1", "x"], ["2", "null"], ["3", "null"]])
        XCTAssertEqual(try t("Table.FromList({\"a,b\", \"c\"})"), [["a", "b"], ["c", "null"]])
        XCTAssertEqual(try t("Table.FromList({1, 2}, Splitter.SplitByNothing(), {\"n\"})"), [["1"], ["2"]])
        XCTAssertEqual(try t("Table.FromValue(5)"), [["5"]])
        XCTAssertEqual(show(try m("Table.ToRecords(#table({\"a\", \"b\"}, {{1, 2}}))")), "{[a=1,b=2]}")
        XCTAssertEqual(show(try m("Table.ToRows(#table({\"a\", \"b\"}, {{1, 2}, {3, 4}}))")), "{{1,2},{3,4}}")
        XCTAssertEqual(show(try m("Table.ToColumns(#table({\"a\", \"b\"}, {{1, 2}, {3, 4}}))")), "{{1,3},{2,4}}")
        XCTAssertEqual(show(try m("Table.Column(#table({\"a\", \"b\"}, {{1, 2}, {3, 4}}), \"b\")")), "{2,4}")
        XCTAssertEqual(show(try m("Table.ToList(#table({\"a\", \"b\"}, {{1, \"x\"}}))")), "{1,x}")
        XCTAssertEqual(try t("Table.Combine({#table({\"a\"}, {{1}}), #table({\"b\"}, {{2}})}, {\"b\"})"), [["null"], ["2"]])
        XCTAssertEqual(try t("#table({\"a\"}, {{1}}) & #table({\"a\"}, {{2}})"), [["1"], ["2"]])
        XCTAssertNotNil(mErr("#table({\"a\", \"a\"}, {})"))
    }
    func testTableRowAndColumnFunctions() throws {
        func t(_ e: String) throws -> [[String]] { try tableRows(try m(e)) }
        let s = "#table({\"k\", \"v\"}, {{\"a\", 3}, {\"b\", 1}, {\"c\", 2}})"
        XCTAssertEqual(show(try m("Table.Max(\(s), \"v\")")), "[k=a,v=3]")
        XCTAssertEqual(show(try m("Table.Min(\(s), \"v\")")), "[k=b,v=1]")
        XCTAssertEqual(try t("Table.MaxN(\(s), \"v\", 2)"), [["a", "3"], ["c", "2"]])
        XCTAssertEqual(try t("Table.MinN(\(s), \"v\", 2)"), [["b", "1"], ["c", "2"]])
        XCTAssertEqual(show(try m("Table.First(\(s))")), "[k=a,v=3]")
        XCTAssertEqual(show(try m("Table.Last(\(s))")), "[k=c,v=2]")
        XCTAssertTrue(try m("Table.First(#table({\"a\"}, {}))").isNull)
        XCTAssertEqual(try mText("Table.FirstValue(\(s))"), "a")
        XCTAssertEqual(try t("Table.FirstN(\(s), each [v] > 2)"), [["a", "3"]])
        XCTAssertEqual(try t("Table.Skip(\(s), each [v] > 2)"), [["b", "1"], ["c", "2"]])
        XCTAssertEqual(try t("Table.RemoveRows(\(s), 1)"), [["a", "3"], ["c", "2"]])
        XCTAssertEqual(try t("Table.InsertRows(\(s), 1, {[k = \"z\", v = 0]})"), [["a", "3"], ["z", "0"], ["b", "1"], ["c", "2"]])
        XCTAssertEqual(try t("Table.Repeat(Table.FirstN(\(s), 1), 2)"), [["a", "3"], ["a", "3"]])
        XCTAssertEqual(try t("Table.FindText(\(s), \"b\")"), [["b", "1"]])
        XCTAssertTrue(try mBool("Table.Contains(\(s), [k = \"b\"])"))
        XCTAssertFalse(try mBool("Table.Contains(\(s), [k = \"b\", v = 9])"))
        XCTAssertTrue(try mBool("Table.MatchesAllRows(\(s), each [v] > 0)"))
        XCTAssertFalse(try mBool("Table.MatchesAnyRows(\(s), each [v] > 5)"))
        XCTAssertTrue(try mBool("Table.IsDistinct(\(s))"))
        XCTAssertFalse(try mBool("Table.IsDistinct(#table({\"a\"}, {{1}, {1}}))"))
        XCTAssertTrue(try mBool("Table.IsEmpty(#table({\"a\"}, {}))"))
        XCTAssertTrue(try mBool("Table.HasColumns(\(s), {\"k\", \"v\"})"))
        XCTAssertFalse(try mBool("Table.HasColumns(\(s), \"zz\")"))
        XCTAssertEqual(try mNum("Table.ColumnCount(\(s))"), 2)
        XCTAssertEqual(columnNames(try m("Table.TransformColumnNames(\(s), Text.Upper)")), ["K", "V"])
        XCTAssertEqual(columnNames(try m("Table.PrefixColumns(\(s), \"t\")")), ["t.k", "t.v"])
        XCTAssertEqual(show(try m("Table.TransformRows(\(s), each [k] & Text.From([v]))")), "{a3,b1,c2}")
        XCTAssertEqual(try t("Table.SelectColumns(\(s), {\"v\", \"zz\"}, MissingField.UseNull)"), [["3", "null"], ["1", "null"], ["2", "null"]])
        XCTAssertEqual(columnNames(try m("Table.SelectColumns(\(s), {\"v\", \"zz\"}, MissingField.Ignore)")), ["v"])
        XCTAssertEqual(try t("Table.TransformColumns(\(s), {{\"v\", each _ * 2}, {\"k\", Text.Upper}})"), [["A", "6"], ["B", "2"], ["C", "4"]])
        XCTAssertEqual(try t("Table.TransformColumns(\(s), {}, each Text.From(_) & \"!\")"), [["a!", "3!"], ["b!", "1!"], ["c!", "2!"]])
        XCTAssertEqual(try t("Table.Sort(\(s), each [v])"), [["b", "1"], ["c", "2"], ["a", "3"]])
        XCTAssertEqual(try t("Table.Sort(\(s), (x, y) => Value.Compare(y[v], x[v]))"), [["a", "3"], ["c", "2"], ["b", "1"]])
        XCTAssertEqual(try t("Table.Distinct(#table({\"k\", \"v\"}, {{\"a\", 1}, {\"A\", 2}}), {\"k\", Comparer.OrdinalIgnoreCase})"), [["a", "1"]])
        // consecutive (local) groups versus global groups
        let g = "#table({\"k\"}, {{\"a\"}, {\"a\"}, {\"b\"}, {\"a\"}})"
        XCTAssertEqual(try t("Table.Group(\(g), \"k\", {\"n\", Table.RowCount}, GroupKind.Local)"), [["a", "2"], ["b", "1"], ["a", "1"]])
        XCTAssertEqual(try t("Table.Group(\(g), \"k\", {\"n\", Table.RowCount})"), [["a", "3"], ["b", "1"]])
    }
    func testTableJoin() throws {
        func t(_ e: String) throws -> [[String]] { try tableRows(try m(e)) }
        let l = "#table({\"id\", \"l\"}, {{1, \"a\"}, {2, \"b\"}, {3, \"c\"}})", r = "#table({\"key\", \"r\"}, {{2, \"x\"}, {2, \"y\"}, {4, \"z\"}})"
        XCTAssertEqual(columnNames(try m("Table.Join(\(l), \"id\", \(r), \"key\")")), ["id", "l", "key", "r"])
        XCTAssertEqual(try t("Table.Join(\(l), \"id\", \(r), \"key\")"), [["2", "b", "2", "x"], ["2", "b", "2", "y"]]) // inner by default
        XCTAssertEqual(try t("Table.Join(\(l), \"id\", \(r), \"key\", JoinKind.LeftOuter)"),
                       [["1", "a", "null", "null"], ["2", "b", "2", "x"], ["2", "b", "2", "y"], ["3", "c", "null", "null"]])
        XCTAssertEqual(try t("Table.Join(\(l), \"id\", \(r), \"key\", JoinKind.FullOuter)").last, ["null", "null", "4", "z"])
        XCTAssertEqual(try t("Table.Join(\(l), \"id\", \(r), \"key\", JoinKind.LeftAnti)"), [["1", "a", "null", "null"], ["3", "c", "null", "null"]])
        XCTAssertEqual(try t("Table.Join(\(l), \"id\", \(r), \"key\", JoinKind.RightAnti)"), [["null", "null", "4", "z"]])
        // columns that share a name on both sides are an error unless they are the join keys
        let clash = try XCTUnwrap(mErr("Table.Join(\(l), \"id\", #table({\"key\", \"l\"}, {}), \"key\")"))
        XCTAssertTrue(clash.contains("duplicate column names"), clash)
        XCTAssertEqual(try t("Table.Join(\(l), \"id\", #table({\"id\", \"r\"}, {{3, \"q\"}}), \"id\")"), [["3", "c", "q"]])
    }
}
