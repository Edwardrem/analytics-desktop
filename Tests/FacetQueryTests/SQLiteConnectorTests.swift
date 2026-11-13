import XCTest
import FacetCore
@testable import FacetQuery

/// SQLite connector: navigation, tables, views, native queries and query folding (which steps fold and the SQL sent).
///
/// orders: (1, Ann, 120.5, 2, rush) (2, Bob, 80, 1, NULL) (3, ann, 300, 5, Gift wrap) (4, Cid, NULL, 3, rush order) (5, Bob, 100, 1, '')
final class SQLiteConnectorTests: FixtureTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try TestSQLite.create(at: dir.appendingPathComponent("shop.db").path, [
            "create table orders (id integer primary key, customer text, amount real, qty integer, note text)",
            "insert into orders values (1, 'Ann', 120.5, 2, 'rush'), (2, 'Bob', 80, 1, NULL), (3, 'ann', 300, 5, 'Gift wrap'), (4, 'Cid', NULL, 3, 'rush order'), (5, 'Bob', 100, 1, '')",
            "create view big_orders as select id, customer, amount from orders where amount >= 100",
        ])
    }
    private let orders = "Sqlite.Database(\"shop.db\"){[Name = \"orders\"]}[Data]"
    private let allColumns = "\"id\", \"customer\", \"amount\", \"qty\", \"note\""

    /// Ids returned by a step over `orders`, plus the native query when the step folded.
    private func ids(_ step: String) async throws -> (ids: [Int], sql: String?) {
        let e = engine([("Q", "let Source = Sqlite.Database(\"shop.db\"), orders = Source{[Name = \"orders\"]}[Data], Step = \(step) in Step")])
        let sql = try await e.nativeQuery(for: "Q")
        let t = try await e.evaluate("Q")
        return (t.column("id")?.values.compactMap { $0.asInt.map(Int.init) } ?? [], sql)
    }

    func testNavigationTablesAndViews() throws {
        XCTAssertEqual(try rows("Table.SelectColumns(Sqlite.Database(\"shop.db\"), {\"Name\", \"Kind\"})"), [["big_orders", "View"], ["orders", "Table"]])
        let t = try eval(orders)
        XCTAssertEqual(columnNames(t), ["id", "customer", "amount", "qty", "note"])
        XCTAssertEqual(t.tableValue?.columnTypes, [.nullable(.int64), .nullable(.text), .nullable(.plainNumber), .nullable(.int64), .nullable(.text)])
        XCTAssertEqual(try tableRows(t), [["1", "Ann", "120.5", "2", "rush"], ["2", "Bob", "80", "1", "null"], ["3", "ann", "300", "5", "Gift wrap"],
                                          ["4", "Cid", "null", "3", "rush order"], ["5", "Bob", "100", "1", ""]])
        XCTAssertEqual(try rows("Sqlite.Database(\"shop.db\"){[Schema = \"main\", Item = \"big_orders\"]}[Data]"),
                       [["1", "Ann", "120.5"], ["3", "ann", "300"], ["5", "Bob", "100"]])
    }
    func testLoadsIntoTypedModelTable() async throws {
        let t = try await engine([("Orders", "let Source = Sqlite.Database(\"shop.db\"), T = Source{[Name = \"orders\"]}[Data] in T")]).evaluate("Orders")
        XCTAssertEqual(t.columns.map(\.type), [.integer, .text, .decimal, .integer, .text])
        XCTAssertEqual(t.column("amount")?.values, [.double(120.5), .double(80), .double(300), .null, .double(100)])
        XCTAssertEqual(t.column("id")?.values, [.int(1), .int(2), .int(3), .int(4), .int(5)])
    }
    func testNativeQueryWithParameters() throws {
        let db = "Sqlite.Database(\"shop.db\")"
        // text sorts by code point in SQLite: upper case before lower case
        XCTAssertEqual(try rows("Value.NativeQuery(\(db), \"select customer, sum(qty) as total from orders group by customer order by customer\")"),
                       [["Ann", "2"], ["Bob", "2"], ["Cid", "3"], ["ann", "5"]])
        XCTAssertEqual(try rows("Value.NativeQuery(\(db), \"select id from orders where amount > ? and customer = ?\", {90, \"Bob\"})"), [["5"]])
        XCTAssertEqual(try rows("Value.NativeQuery(\(db), \"select id from orders where qty >= @min and note is :note\", [min = 3, note = null])"), [])
        XCTAssertEqual(try rows("Value.NativeQuery(\(db), \"select id from orders where qty >= @min order by id\", [min = 3])"), [["3"], ["4"]])
        XCTAssertNotNil(failure("Value.NativeQuery(\(db), \"select id from orders where qty >= @min\", [other = 3])"))
        let syntax = try XCTUnwrap(failure("Value.NativeQuery(\(db), \"selec nothing\")"))
        XCTAssertEqual(syntax.reason, "DataSource.Error")
        XCTAssertTrue(syntax.message.contains("syntax error"), syntax.message)
        // the database is opened read-only
        let write = try XCTUnwrap(failure("Value.NativeQuery(\(db), \"delete from orders\")"))
        XCTAssertTrue(write.message.contains("readonly"), write.message)
        XCTAssertEqual(try rows("Value.NativeQuery(\(db), \"select count(*) from orders\")"), [["5"]])
        XCTAssertNotNil(failure("Value.NativeQuery(#table({\"a\"}, {}), \"select 1\")"))
    }
    func testNativeQueryApproval() throws {
        final class Seen: @unchecked Sendable { var requests: [NativeQueryRequest] = [] }
        let seen = Seen()
        env.requireNativeQueryApproval = true
        let call = "Value.NativeQuery(Sqlite.Database(\"shop.db\"), \"select 1 as one\")"
        let denied = try XCTUnwrap(failure(call)) // no approver configured
        XCTAssertEqual(denied.reason, "DataSource.Error")
        XCTAssertTrue(denied.message.contains("Permission is required"), denied.message)
        env.approveNativeQuery = { seen.requests.append($0); return $0.query.hasPrefix("select") }
        XCTAssertEqual(try rows(call), [["1"]])
        XCTAssertEqual(seen.requests.map(\.query), ["select 1 as one"])
        XCTAssertEqual(seen.requests.first?.sourceKind, "SQLite")
        XCTAssertTrue(seen.requests.first?.sourceLocation.hasSuffix("/shop.db") ?? false)
        XCTAssertNotNil(failure("Value.NativeQuery(Sqlite.Database(\"shop.db\"), \"drop table orders\")"))
    }
    func testFoldingIndicatorsAndTheSqlOfEachStep() async throws {
        let script = """
        let
            Source = Sqlite.Database("shop.db"),
            orders = Source{[Name = "orders"]}[Data],
            Filtered = Table.SelectRows(orders, each [amount] >= 100 and [customer] <> "Bob"),
            Cols = Table.SelectColumns(Filtered, {"id", "customer", "amount"}),
            Sorted = Table.Sort(Cols, {{"amount", Order.Descending}}),
            Top = Table.FirstN(Sorted, 2),
            Added = Table.AddColumn(Top, "double", each [amount] * 2),
            Final = Table.SelectRows(Added, each [double] > 300)
        in
            Final
        """
        let e = engine([("Q", script)])
        let filter = "where ((\"amount\" >= 100) and (\"customer\" is not 'Bob'))"
        let folding = try await e.stepFolding(for: "Q")
        XCTAssertEqual(folding.map(\.step), ["Source", "orders", "Filtered", "Cols", "Sorted", "Top", "Added", "Final"])
        XCTAssertEqual(folding.map(\.indicator), [.notApplicable, .folded, .folded, .folded, .folded, .folded, .notFolded, .notFolded])
        XCTAssertEqual(folding.map(\.nativeQuery), [
            nil,
            "select \(allColumns) from \"orders\"",
            "select \(allColumns) from \"orders\" \(filter)",
            "select \"id\", \"customer\", \"amount\" from \"orders\" \(filter)",
            "select \"id\", \"customer\", \"amount\" from \"orders\" \(filter) order by \"amount\" desc",
            "select \"id\", \"customer\", \"amount\" from \"orders\" \(filter) order by \"amount\" desc limit 2",
            nil, nil,
        ])
        // amount >= 100 and not Bob: orders 1 (120.5) and 3 (300); doubled 241 and 600; only 600 > 300
        let t = try await e.evaluate("Q")
        XCTAssertEqual(t.columnNames, ["id", "customer", "amount", "double"])
        XCTAssertEqual(t.row(0), [.int(3), .string("ann"), .double(300), .int(600)])
        XCTAssertEqual(t.rowCount, 1)
        // exactly one query reached the database: the last folded step
        XCTAssertEqual(e.nativeQueriesSent, ["select \"id\", \"customer\", \"amount\" from \"orders\" \(filter) order by \"amount\" desc limit 2"])
        let last = try await e.nativeQuery(for: "Q")
        XCTAssertNil(last) // the result itself is computed locally
        let top = try await e.nativeQuery(for: "Q", upToStep: 5)
        XCTAssertEqual(top, "select \"id\", \"customer\", \"amount\" from \"orders\" \(filter) order by \"amount\" desc limit 2")
        let previewRows = try await e.evaluate("Q", upToStep: 4)
        XCTAssertEqual(previewRows.column("id")?.values, [.int(3), .int(1)])
    }
    func testFoldedFiltersKeepMNullSemantics() async throws {
        // in M, null <> "rush" is true and null = "rush" is false
        var r = try await ids("Table.SelectRows(orders, each [note] <> \"rush\")")
        XCTAssertEqual(r.ids, [2, 3, 4, 5]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (\"note\" is not 'rush')")
        r = try await ids("Table.SelectRows(orders, each not ([note] = \"rush\"))")
        XCTAssertEqual(r.ids, [2, 3, 4, 5]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (not (\"note\" is 'rush'))")
        r = try await ids("Table.SelectRows(orders, each [note] = null)")
        XCTAssertEqual(r.ids, [2]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (\"note\" is null)")
        r = try await ids("Table.SelectRows(orders, each [note] <> null and [qty] > 1)")
        XCTAssertEqual(r.ids, [1, 3, 4]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where ((\"note\" is not null) and (\"qty\" > 1))")
        // a comparison with null is null, so the row is dropped (order 4 has no amount) — also under "not"
        r = try await ids("Table.SelectRows(orders, each [amount] < 110)")
        XCTAssertEqual(r.ids, [2, 5]); XCTAssertNotNil(r.sql)
        r = try await ids("Table.SelectRows(orders, each not ([amount] < 110))")
        XCTAssertEqual(r.ids, [1, 3]); XCTAssertNotNil(r.sql)
        r = try await ids("Table.SelectRows(orders, each [amount] < 110 or [qty] = 3)")
        XCTAssertEqual(r.ids, [2, 4, 5]); XCTAssertNotNil(r.sql)
    }
    func testFoldedTextAndListPredicates() async throws {
        var r = try await ids("Table.SelectRows(orders, each Text.StartsWith([note], \"rush\"))")
        XCTAssertEqual(r.ids, [1, 4]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (substr(\"note\", 1, length('rush')) = 'rush')")
        r = try await ids("Table.SelectRows(orders, each Text.EndsWith([note], \"order\"))")
        XCTAssertEqual(r.ids, [4]); XCTAssertNotNil(r.sql)
        // Text.Contains is case-sensitive unless a comparer says otherwise
        r = try await ids("Table.SelectRows(orders, each Text.Contains([note], \"gift\"))")
        XCTAssertEqual(r.ids, []); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (instr(\"note\", 'gift') > 0)")
        r = try await ids("Table.SelectRows(orders, each Text.Contains([note], \"gift\", Comparer.OrdinalIgnoreCase))")
        XCTAssertEqual(r.ids, [3]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (instr(lower(\"note\"), lower('gift')) > 0)")
        r = try await ids("Table.SelectRows(orders, each List.Contains({\"Ann\", \"Cid\"}, [customer]))")
        XCTAssertEqual(r.ids, [1, 4]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where (\"customer\" is not null and \"customer\" in ('Ann', 'Cid'))")
        r = try await ids("Table.SelectRows(orders, each [customer] = \"O'Neil\" or [qty] * 2 + 1 = 11)")
        XCTAssertEqual(r.ids, [3]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" where ((\"customer\" is 'O''Neil') or (((\"qty\" * 2) + 1) is 11))")
        r = try await ids("Table.SelectRows(orders, (row) => row[qty] = 1)")
        XCTAssertEqual(r.ids, [2, 5]); XCTAssertNotNil(r.sql)
    }
    func testStepsThatDoNotFoldRunLocallyWithTheSameResult() async throws {
        var r = try await ids("Table.SelectRows(orders, each Text.Upper([customer]) = \"ANN\")")
        XCTAssertEqual(r.ids, [1, 3]); XCTAssertNil(r.sql)
        r = try await ids("Table.SelectRows(orders, each [amount] / [qty] > 60)") // division is not folded: SQL integer division differs
        XCTAssertEqual(r.ids, [1, 2, 5]); XCTAssertNil(r.sql)
        r = try await ids("Table.SelectRows(orders, each if [qty] > 2 then true else false)")
        XCTAssertEqual(r.ids, [3, 4]); XCTAssertNil(r.sql)
        r = try await ids("Table.LastN(orders, 2)")
        XCTAssertEqual(r.ids, [4, 5]); XCTAssertNil(r.sql)
    }
    func testFoldingTopSkipDistinctColumnsAndCount() async throws {
        var r = try await ids("Table.FirstN(Table.Skip(orders, 1), 2)")
        XCTAssertEqual(r.ids, [2, 3]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" limit 2 offset 1")
        r = try await ids("Table.Skip(Table.FirstN(orders, 3), 1)")
        XCTAssertEqual(r.ids, [2, 3]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" limit 2 offset 1")
        r = try await ids("Table.Skip(orders, 3)")
        XCTAssertEqual(r.ids, [4, 5]); XCTAssertEqual(r.sql, "select \(allColumns) from \"orders\" limit -1 offset 3")
        // a filter after "keep top rows" applies to those rows only, so the top query becomes a sub-select
        r = try await ids("Table.SelectRows(Table.FirstN(orders, 3), each [qty] > 1)")
        XCTAssertEqual(r.ids, [1, 3]); XCTAssertEqual(r.sql, "select \(allColumns) from (select \(allColumns) from \"orders\" limit 3) as \"_\" where (\"qty\" > 1)")
        r = try await ids("Table.RemoveColumns(Table.Sort(orders, {{\"customer\", Order.Ascending}, {\"id\", Order.Descending}}), {\"note\", \"qty\"})")
        XCTAssertEqual(r.ids, [1, 5, 2, 4, 3]); XCTAssertEqual(r.sql, "select \"id\", \"customer\", \"amount\" from \"orders\" order by \"customer\", \"id\" desc")
        r = try await ids("Table.SelectColumns(orders, {\"id\"})")
        XCTAssertEqual(r.sql, "select \"id\" from \"orders\"")

        let e = engine([("D", "let o = \(orders), c = Table.Distinct(Table.SelectColumns(o, {\"customer\"})) in c"),
                        ("N", "let o = \(orders), f = Table.SelectRows(o, each [qty] = 1), n = Table.RowCount(f) in n")])
        let distinctSQL = try await e.nativeQuery(for: "D")
        XCTAssertEqual(distinctSQL, "select distinct \"customer\" from \"orders\"")
        let customers = try await e.evaluate("D")
        XCTAssertEqual(Set(customers.column("customer")?.values.map(\.asString) ?? []), ["Ann", "Bob", "ann", "Cid"])
        XCTAssertEqual(customers.rowCount, 4)
        let n = try await e.evaluate("N")
        XCTAssertEqual(n.row(0), [.int(2)])
        XCTAssertEqual(e.nativeQueriesSent, ["select count(*) as \"Count\" from \"orders\" where (\"qty\" is 1)"])
    }
    func testParametersAndRowLimitsArePushedDown() async throws {
        var p = QueryDefinition(name: "MinAmount", mScript: "100 meta [IsParameterQuery = true]")
        p.kind = .parameter
        var value = QueryParameter(); value.type = .decimal; value.currentValue = .int(100)
        p.parameter = value
        let q = QueryDefinition(name: "Q", mScript: "let o = \(orders), f = Table.SelectRows(o, each [amount] > MinAmount) in f")
        let e = QueryEngine(queries: [p, q], environment: env)
        let sql = try await e.nativeQuery(for: "Q")
        XCTAssertEqual(sql, "select \(allColumns) from \"orders\" where (\"amount\" > 100)")
        let t = try await e.evaluate("Q", rowLimit: 1)
        XCTAssertEqual(t.column("id")?.values, [.int(1)])
        XCTAssertEqual(e.nativeQueriesSent, ["select \(allColumns) from \"orders\" where (\"amount\" > 100) limit 1"])
        // dynamic M parameter: the override reaches the folded query
        let overridden = try await e.evaluate("Q", parameterOverrides: ["MinAmount": .int(250)])
        XCTAssertEqual(overridden.column("id")?.values, [.int(3)])
        XCTAssertEqual(e.nativeQueriesSent, ["select \(allColumns) from \"orders\" where (\"amount\" > 250)"])
    }
    func testFoldingOverNativeQuery() async throws {
        let base = "select customer, sum(qty) as total from orders group by customer"
        let e = engine([
            ("Folded", "let db = Sqlite.Database(\"shop.db\"), q = Value.NativeQuery(db, \"\(base);\", null, [EnableFolding = true]), f = Table.SelectRows(q, each [total] > 2) in f"),
            ("Plain", "let db = Sqlite.Database(\"shop.db\"), q = Value.NativeQuery(db, \"\(base)\"), f = Table.SelectRows(q, each [total] > 2) in f"),
        ])
        let folded = try await e.nativeQuery(for: "Folded")
        XCTAssertEqual(folded, "select \"customer\", \"total\" from (\(base)) as \"_\" where (\"total\" > 2)")
        let plain = try await e.nativeQuery(for: "Plain")
        XCTAssertNil(plain) // without EnableFolding later steps run locally
        for name in ["Folded", "Plain"] {
            let t = try await e.evaluate(name)
            XCTAssertEqual(Set(t.column("customer")?.values.map(\.asString) ?? []), ["Cid", "ann"], name)
        }
    }
    func testViewsFoldToo() async throws {
        let e = engine([("V", "let v = Sqlite.Database(\"shop.db\"){[Name = \"big_orders\"]}[Data], f = Table.SelectRows(v, each [customer] = \"Bob\") in f")])
        let sql = try await e.nativeQuery(for: "V")
        XCTAssertEqual(sql, "select \"id\", \"customer\", \"amount\" from \"big_orders\" where (\"customer\" is 'Bob')")
        let t = try await e.evaluate("V")
        XCTAssertEqual(t.column("id")?.values, [.int(5)])
    }
    func testErrors() throws {
        let missing = try XCTUnwrap(failure("Sqlite.Database(\"nope.db\")"))
        XCTAssertEqual(missing.reason, "DataSource.Error")
        XCTAssertTrue(missing.message.contains("nope.db"), missing.message)
        try write("fake.db", "this is plain text, not a database file, but long enough to be read as a header")
        let fake = try XCTUnwrap(failure("Sqlite.Database(\"fake.db\")"))
        XCTAssertEqual(fake.reason, "DataSource.Error")
        XCTAssertTrue(fake.message.contains("not a database"), fake.message)
        XCTAssertNotNil(failure("Sqlite.Database(\"shop.db\"){[Name = \"nothing\"]}[Data]"))
        XCTAssertNotNil(failure("Table.SelectColumns(\(orders), {\"nope\"})"))
    }
}
