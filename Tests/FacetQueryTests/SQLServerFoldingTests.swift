import XCTest
@testable import FacetQuery

/// Query folding to T-SQL. Tables are SQL Server sources whose rows are never loaded, so no server is needed:
/// each test checks the statement the folded steps would send.
final class SQLServerFoldingTests: XCTestCase {
    private var interpreter: MInterpreter!
    private var db: SQLServerDatabase!

    override func setUp() {
        interpreter = MInterpreter()
        db = database("Sales")
    }
    private func database(_ name: String) -> SQLServerDatabase {
        SQLServerDatabase(server: "sql.invalid", database: name, address: TDSServerAddress(host: "sql.invalid"), identity: "sql:test") {
            .sql(user: "test", password: "")
        }
    }
    private func table(_ from: String, _ columns: [(String, MType)], in database: SQLServerDatabase? = nil) -> MValue {
        let q = TSQLQuery(from: from, columns: columns.map(\.0), types: columns.map(\.1))
        return .table(MTable(source: SQLServerSource(database: database ?? db, query: q, interpreter: interpreter)))
    }
    private var sales: MValue {
        table("[dbo].[Sales]", [("Id", .int64), ("Region", .nullable(.text)), ("Amount", .nullable(.number(.decimal))),
                                ("Active", .nullable(.logical)), ("Day", .date)])
    }
    private var regions: MValue { table("[dbo].[Regions]", [("Region", .text), ("Manager", .nullable(.text))]) }
    private let all = "[Id], [Region], [Amount], [Active], [Day]"

    /// The T-SQL of an M expression over `T` (Sales) and `U` (Regions); nil when the result is not folded.
    private func sql(_ m: String, u: MValue? = nil) throws -> String? {
        let env = MEnv(parent: nil, vars: ["T": sales, "U": u ?? regions])
        guard case .table(let t) = try interpreter.evaluate(m, env: env) else { return nil }
        return t.isLazy ? t.source?.nativeQuery : nil
    }
    private func filter(_ condition: String) throws -> String? {
        try sql("Table.SelectRows(T, each \(condition))")
    }
    private func whereClause(_ condition: String) throws -> String? {
        try filter(condition).map { s in s.components(separatedBy: " where ").dropFirst().joined(separator: " where ") }
    }

    func testFilterComparisonsKeepMNullSemantics() throws {
        XCTAssertEqual(try filter("[Amount] > 10 and [Region] = \"West\""),
                       "select \(all) from [dbo].[Sales] where (([Amount] > 10) and ([Region] = N'West'))")
        // M: null <> "West" is true, so rows with no region stay.
        XCTAssertEqual(try whereClause("[Region] <> \"West\""), "([Region] <> N'West' or [Region] is null)")
        XCTAssertEqual(try whereClause("not ([Region] = \"West\")"), "([Region] <> N'West' or [Region] is null)")
        XCTAssertEqual(try whereClause("[Region] = null"), "([Region] is null)")
        XCTAssertEqual(try whereClause("[Region] <> null or not ([Amount] < 5)"), "(([Region] is not null) or (not ([Amount] < 5)))")
        XCTAssertEqual(try whereClause("not ([Amount] > 1 and [Id] = 2)"), "((not ([Amount] > 1)) or ([Id] <> 2))")
        // Two nullable sides: M equality is true for null = null.
        XCTAssertEqual(try whereClause("[Region] = [Region]"), "([Region] = [Region] or ([Region] is null and [Region] is null))")
        XCTAssertEqual(try whereClause("[Active]"), "([Active] = 1)")
        XCTAssertEqual(try whereClause("[Amount] * 2 + 1 >= 7"), "((([Amount] * 2) + 1) >= 7)")
    }

    func testFilterTextFunctionsListsDatesAndParameters() throws {
        XCTAssertEqual(try whereClause("Text.StartsWith([Region], \"W_\")"), "([Region] like N'W[_]%')")
        XCTAssertEqual(try whereClause("Text.Contains([Region], \"50%\", Comparer.OrdinalIgnoreCase)"), "(lower([Region]) like N'%50[%]%')")
        XCTAssertEqual(try whereClause("Text.EndsWith([Region], \"'s\")"), "([Region] like N'%''s')")
        XCTAssertEqual(try whereClause("List.Contains({\"A\", \"B\"}, [Region])"), "([Region] in (N'A', N'B'))")
        XCTAssertEqual(try whereClause("not List.Contains({1, 2}, [Id])"), "(([Id] not in (1, 2)) or [Id] is null)")
        XCTAssertEqual(try whereClause("[Day] >= #date(2024, 1, 31)"), "([Day] >= convert(date, '2024-01-31'))")
        XCTAssertEqual(try sql("let Minimum = 2.5 in Table.SelectRows(T, each [Amount] >= Minimum)"),
                       "select \(all) from [dbo].[Sales] where ([Amount] >= 2.5)")
    }

    func testFiltersThatCannotFoldAreLeftToTheEngine() throws {
        let columns: [String: MType] = ["Region": .text, "Amount": .plainNumber]
        for body in ["Text.Upper([Region]) = \"W\"", "[Amount] / 2 > 1", "if [Amount] > 1 then true else false", "[Missing] = 1"] {
            guard case .function(let f) = try interpreter.evaluate("each " + body) else { return XCTFail() }
            XCTAssertNil(TSQLPredicate(columns: columns, interpreter: interpreter).translate(f), body)
        }
    }

    func testSelectSortTopAndSkip() throws {
        XCTAssertEqual(try sql("Table.FirstN(Table.Sort(Table.SelectColumns(T, {\"Region\", \"Amount\"}), {{\"Amount\", Order.Descending}}), 5)"),
                       "select top (5) [Region], [Amount] from [dbo].[Sales] order by [Amount] desc")
        XCTAssertEqual(try sql("Table.Skip(Table.Sort(T, {\"Id\"}), 10)"),
                       "select \(all) from [dbo].[Sales] order by [Id] offset 10 rows")
        XCTAssertEqual(try sql("Table.FirstN(Table.Skip(T, 10), 5)"),
                       "select \(all) from [dbo].[Sales] order by (select null) offset 10 rows fetch next 5 rows only")
        // A filter after a top applies to the top rows: the top becomes a derived table.
        XCTAssertEqual(try sql("Table.SelectRows(Table.FirstN(T, 3), each [Id] > 1)"),
                       "select \(all) from (select top (3) \(all) from [dbo].[Sales]) as [_] where ([Id] > 1)")
        XCTAssertEqual(try sql("Table.Distinct(Table.RemoveColumns(T, {\"Id\", \"Active\", \"Day\"}))"),
                       "select distinct [Region], [Amount] from [dbo].[Sales]")
    }

    func testGroupBy() throws {
        let group = "Table.Group(T, {\"Region\"}, {{\"Total\", each List.Sum([Amount]), type number}, {\"Rows\", each Table.RowCount(_), Int64.Type}, {\"Mean\", each List.Average([Amount])}})"
        let grouped = "select [Region], sum([Amount]) as [Total], count_big(*) as [Rows], avg(convert(float, [Amount])) as [Mean] from [dbo].[Sales] group by [Region]"
        XCTAssertEqual(try sql(group), grouped)
        XCTAssertEqual(try sql("Table.Sort(Table.SelectRows(\(group), each [Total] > 100), {{\"Total\", Order.Descending}})"),
                       "select [Region], [Total], [Rows], [Mean] from (\(grouped)) as [_] where ([Total] > 100) order by [Total] desc")
        // An aggregation with no T-SQL equivalent stays local.
        guard case .table(let t) = sales, case .function(let rows)? = Optional(try interpreter.evaluate("each _")) else { return XCTFail() }
        XCTAssertNil(t.source?.folding(.group(keys: ["Region"], aggregations: [MGroupAggregation(name: "All", function: rows, type: nil)]), interpreter))
    }

    func testJoins() throws {
        let left = "(select \(all) from [dbo].[Sales]) as [$l]", right = "(select [Region], [Manager] from [dbo].[Regions]) as [$r]"
        let leftItems = "[$l].[Id] as [Id], [$l].[Region] as [Region], [$l].[Amount] as [Amount], [$l].[Active] as [Active], [$l].[Day] as [Day]"
        XCTAssertEqual(try sql("Table.ExpandTableColumn(Table.NestedJoin(T, {\"Region\"}, U, {\"Region\"}, \"U\", JoinKind.LeftOuter), \"U\", {\"Manager\"}, {\"U.Manager\"})"),
                       "select \(leftItems), [$r].[Manager] as [U.Manager] from \(left) left outer join \(right) on [$l].[Region] = [$r].[Region]")
        // Table.Join merges key columns of the same name.
        XCTAssertEqual(try sql("Table.Join(T, \"Region\", U, \"Region\", JoinKind.Inner)"),
                       "select \(leftItems), [$r].[Manager] as [Manager] from \(left) inner join \(right) on [$l].[Region] = [$r].[Region]")
        // A nested join that is not expanded is not one SQL statement.
        XCTAssertNil(try sql("Table.NestedJoin(T, {\"Region\"}, U, {\"Region\"}, \"U\", JoinKind.LeftOuter)"))
        // Anti joins and joins across databases stay local.
        guard case .table(let t) = sales, case .table(let u) = regions else { return XCTFail() }
        XCTAssertNil(t.source?.folding(.nestedJoin(right: u, leftKeys: ["Region"], rightKeys: ["Region"], newColumn: "U", kind: 4), interpreter))
        let elsewhere = table("[dbo].[Regions]", [("Region", .text), ("Manager", .text)], in: database("Other"))
        guard case .table(let other) = elsewhere else { return XCTFail() }
        XCTAssertNil(t.source?.folding(.join(right: other, leftKeys: ["Region"], rightKeys: ["Region"], kind: 0), interpreter))
    }

    func testRowCountAndNativeQueryFolding() throws {
        guard case .table(let t) = sales else { return XCTFail() }
        XCTAssertEqual(t.source?.folding(.rowCount, interpreter)?.nativeQuery, "select count_big(*) as [Count] from [dbo].[Sales]")
        let native = TSQLQuery(from: "(select * from dbo.Sales where Region = @r) as [_]", columns: ["Id"], types: [.int64],
                               parameters: [TDSParameter(name: "@r", value: .text("West"))])
        let source = SQLServerSource(database: db, query: native, interpreter: interpreter)
        XCTAssertEqual(source.folding(.firstN(1), interpreter)?.nativeQuery, "select top (1) [Id] from (select * from dbo.Sales where Region = @r) as [_]")
    }

    func testLiterals() {
        XCTAssertEqual(TSQL.quote("a]b"), "[a]]b]")
        XCTAssertEqual(TSQL.literal(.text("O'Neil")), "N'O''Neil'")
        XCTAssertEqual(TSQL.literal(.number(-3)), "-3")
        XCTAssertNil(TSQL.literal(.number(.infinity)))
        XCTAssertEqual(TSQL.literal(.datetime(Date(timeIntervalSince1970: 86_400 + 3_723.5))), "convert(datetime2, '1970-01-02 01:02:03.5000000')")
        XCTAssertEqual(TSQL.literal(.datetimezone(Date(timeIntervalSince1970: 0), offsetMinutes: -90)), "convert(datetimeoffset, '1969-12-31 22:30:00.0000000 -01:30')")
        XCTAssertEqual(TSQL.literal(.time(45_296.25)), "convert(time, '12:34:56.2500000')")
        XCTAssertNil(TSQL.literal(.duration(1)))
    }

    func testNativeQueryParameters() throws {
        let p = try MLibrary.sqlServerParameters(.record(MRecord([("Region", .text("West")), ("@n", .number(3)), ("x", .number(0.5)),
                                                                  ("d", .date(Date(timeIntervalSince1970: 86_400)))])))
        XCTAssertEqual(p.map(\.name), ["@Region", "@n", "@x", "@d"])
        XCTAssertEqual(p.map(\.value), [.text("West"), .bigint(3), .float(0.5), .date(days: 719_163)])
        XCTAssertEqual(try MLibrary.sqlServerParameter(.datetime(Date(timeIntervalSince1970: 1.5)), name: "t"), .datetime2(days: 719_162, ticks: 15_000_000))
        XCTAssertThrowsError(try MLibrary.sqlServerParameters(.list([.number(1)])))
    }

    func testSignInIsRequiredAndNativeQueriesNeedApproval() throws {
        // No stored credential and not an Azure host: nothing is sent, and the message says what to do.
        let message = MError.wrap(XCTUnwrapError { try MInterpreter().evaluate("Sql.Database(\"db.example.com\", \"Sales\")") }).message
        XCTAssertTrue(message.hasPrefix("Microsoft SQL: 'db.example.com;Sales' needs a sign-in"), message)
        XCTAssertTrue(message.contains("Windows authentication isn't available on macOS"))
        let credentials = FakeCredentials()
        credentials.stored["SQL|db.example.com;Sales"] = .basic(username: "u", password: "p")
        var env = QueryEnvironment(credentials: credentials)
        env.requireNativeQueryApproval = true
        env.approveNativeQuery = { _ in false }
        let denied = MError.wrap(XCTUnwrapError { try MInterpreter(environment: env).evaluate("Sql.Database(\"db.example.com\", \"Sales\", [Query = \"select 1\"])") })
        XCTAssertTrue(denied.message.contains("Permission is required"), denied.message)
        XCTAssertThrowsError(try MInterpreter(environment: env).evaluate("Sql.Database(\"db.example.com\", \"Sales\", [CommandTimeout = 5])"),
                             "CommandTimeout is a duration")
    }

    private func XCTUnwrapError(_ body: () throws -> Any) -> Error {
        do { _ = try body(); XCTFail("expected an error"); return MError("none") } catch { return error }
    }
}
