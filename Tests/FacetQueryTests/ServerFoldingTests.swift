import XCTest
import FacetCore
@testable import FacetQuery

/// Query folding to PostgreSQL and MySQL SQL: which steps fold and the statement sent. A recording database stands in
/// for the server (no network); it answers with no rows.
final class ServerFoldingTests: XCTestCase {
    final class Recorder: RemoteDatabase {
        let dialect: SQLDialect
        let connectionKey: String
        var statements: [String] = []
        init(_ dialect: SQLDialect, key: String = "server") { self.dialect = dialect; self.connectionKey = key }
        var kind: String { "Test" }
        var location: String { "server;db" }
        func describe(_ sql: String, parameters: [MValue]) throws -> [RemoteColumn] { [] }
        func query(_ sql: String, parameters: [MValue], limit: Int?) throws -> RemoteResult {
            statements.append(sql)
            let names = RemoteSQLSourceTestNames.columns(in: sql)
            return RemoteResult(columns: names.map { RemoteColumn(name: $0, type: .any) }, cells: names.map { _ in [] })
        }
    }

    private func table(_ db: RemoteDatabase, _ from: String, _ columns: [String], _ ctx: MInterpreter) -> MValue {
        .table(MTable(source: RemoteSQLSource(database: db, query: .init(from: from, columns: columns, types: columns.map { _ in .any }), interpreter: ctx)))
    }

    /// The SQL a step over `Orders` (id, customer, amount, qty) and `Customers` (name, region) folds to, or nil.
    private func sql(_ step: String, _ dialect: SQLDialect, otherServer: Bool = false) throws -> String? {
        let db = Recorder(dialect), other = otherServer ? Recorder(dialect, key: "elsewhere") : db
        let ctx = MInterpreter()
        let env = MEnv(parent: nil, vars: [
            "Orders": table(db, dialect.qualified("sales", "orders"), ["id", "customer", "amount", "qty"], ctx),
            "Customers": table(other, dialect.qualified("public", "customers"), ["name", "region"], ctx),
            "Limit": .number(100),
        ])
        guard case .table(let t) = try ctx.evaluate(step, env: env), t.isLazy else { return nil }
        return t.source?.nativeQuery
    }

    func testFilterSortAndLimitPostgres() throws {
        XCTAssertEqual(try sql("Table.FirstN(Table.Sort(Table.SelectRows(Orders, each [amount] >= Limit and [customer] <> null), {{\"amount\", Order.Descending}}), 10)", .postgres),
                       #"SELECT "id", "customer", "amount", "qty" FROM "sales"."orders" WHERE (("amount" >= 100) AND ("customer" IS NOT NULL)) ORDER BY "amount" DESC LIMIT 10"#)
        XCTAssertEqual(try sql("Table.SelectRows(Orders, each [customer] = \"O'Hara\" or [customer] <> \"Bob\")", .postgres),
                       #"SELECT "id", "customer", "amount", "qty" FROM "sales"."orders" WHERE (("customer" IS NOT DISTINCT FROM 'O''Hara') OR (NOT ("customer" IS NOT DISTINCT FROM 'Bob')))"#)
        XCTAssertEqual(try sql(#"Table.SelectRows(Orders, each Text.StartsWith([customer], "A\", Comparer.OrdinalIgnoreCase))"#, .postgres),
                       #"SELECT "id", "customer", "amount", "qty" FROM "sales"."orders" WHERE (LEFT(LOWER("customer"), CHAR_LENGTH(LOWER(E'A\\'))) = LOWER(E'A\\'))"#)
        XCTAssertEqual(try sql("Table.Skip(Table.SelectColumns(Orders, {\"id\"}), 5)", .postgres), #"SELECT "id" FROM "sales"."orders" OFFSET 5"#)
        XCTAssertEqual(try sql("Table.SelectRows(Orders, each List.Contains({1, 2}, [id]))", .postgres),
                       #"SELECT "id", "customer", "amount", "qty" FROM "sales"."orders" WHERE ("id" IS NOT NULL AND "id" IN (1, 2))"#)
        // Division and conditionals don't fold.
        XCTAssertNil(try sql("Table.SelectRows(Orders, each [amount] / 2 > 1)", .postgres))
    }

    func testFilterSortAndLimitMySQL() throws {
        XCTAssertEqual(try sql("Table.FirstN(Table.Sort(Table.SelectRows(Orders, each [customer] = \"Ann\" and Text.Contains([customer], \"n\")), {\"id\"}), 3)", .mysql),
                       "SELECT `id`, `customer`, `amount`, `qty` FROM `sales`.`orders` WHERE ((`customer` <=> 'Ann') AND (LOCATE('n', `customer`) > 0)) ORDER BY `id` LIMIT 3")
        XCTAssertEqual(try sql("Table.Skip(Orders, 2)", .mysql), "SELECT `id`, `customer`, `amount`, `qty` FROM `sales`.`orders` LIMIT 2, 18446744073709551615")
        // A backslash is sent as hex so it means the same with or without NO_BACKSLASH_ESCAPES.
        XCTAssertEqual(try sql("Table.SelectRows(Orders, each [customer] = \"a\\b\")", .mysql),
                       "SELECT `id`, `customer`, `amount`, `qty` FROM `sales`.`orders` WHERE (`customer` <=> CONVERT(X'615c62' USING utf8mb4))")
        XCTAssertEqual(try sql("Table.SelectRows(Orders, each [customer] & \"!\" = \"Ann!\")", .mysql),
                       "SELECT `id`, `customer`, `amount`, `qty` FROM `sales`.`orders` WHERE (CONCAT(`customer`, '!') <=> 'Ann!')")
    }

    func testRedshiftNullSafeEquality() throws {
        XCTAssertEqual(try sql("Table.SelectRows(Orders, each [id] = 1)", .redshift),
                       #"SELECT "id", "customer", "amount", "qty" FROM "sales"."orders" WHERE (("id" = 1) OR ("id" IS NULL AND 1 IS NULL))"#)
    }

    func testGroupBy() throws {
        let group = "Table.Group(Orders, {\"customer\"}, {{\"Rows\", each Table.RowCount(_), Int64.Type}, {\"Total\", each List.Sum([amount]), type number}, "
            + "{\"Distinct\", each List.Count(List.Distinct([qty])), Int64.Type}, {\"Max\", each List.Max([amount]), type number}})"
        XCTAssertEqual(try sql(group, .postgres),
                       #"SELECT "customer", "Rows", "Total", "Distinct", "Max" FROM (SELECT "customer", COUNT(*) AS "Rows", SUM("amount") AS "Total", "#
                       + #"(COUNT(DISTINCT "qty") + MAX(CASE WHEN "qty" IS NULL THEN 1 ELSE 0 END)) AS "Distinct", MAX("amount") AS "Max" "#
                       + #"FROM "sales"."orders" GROUP BY "customer") AS "_""#)
        XCTAssertEqual(try sql("Table.SelectRows(Table.Group(Table.SelectRows(Orders, each [qty] > 1), {\"customer\"}, {{\"n\", Table.RowCount, Int64.Type}}), each [n] > 2)", .mysql),
                       "SELECT `customer`, `n` FROM (SELECT `customer`, COUNT(*) AS `n` FROM `sales`.`orders` WHERE (`qty` > 1) GROUP BY `customer`) AS `_` WHERE (`n` > 2)")
        // Medians, local grouping and comparers run here.
        XCTAssertNil(try sql("Table.Group(Orders, {\"customer\"}, {{\"m\", each List.Median([amount])}})", .postgres))
        XCTAssertNil(try sql("Table.Group(Orders, {\"customer\"}, {{\"n\", each Table.RowCount(_)}}, GroupKind.Local)", .postgres))
        XCTAssertNil(try sql("Table.Group(Orders, {\"customer\"}, {{\"n\", each Table.RowCount(_)}}, GroupKind.Global, Comparer.OrdinalIgnoreCase)", .postgres))
    }

    func testJoins() throws {
        let expanded = "Table.ExpandTableColumn(Table.NestedJoin(Orders, {\"customer\"}, Customers, {\"name\"}, \"C\", JoinKind.LeftOuter), \"C\", {\"region\"}, {\"C.region\"})"
        XCTAssertEqual(try sql(expanded, .postgres),
                       #"SELECT "id", "customer", "amount", "qty", "C.region" FROM (SELECT "_l"."id" AS "id", "_l"."customer" AS "customer", "_l"."amount" AS "amount", "#
                       + #""_l"."qty" AS "qty", "_r"."region" AS "C.region" FROM (SELECT "id", "customer", "amount", "qty" FROM "sales"."orders") AS "_l" "#
                       + #"LEFT OUTER JOIN (SELECT "name", "region" FROM "public"."customers") AS "_r" ON ("_l"."customer" IS NOT DISTINCT FROM "_r"."name")) AS "_""#)
        XCTAssertEqual(try sql("Table.Join(Orders, {\"customer\"}, Customers, {\"name\"}, JoinKind.Inner)", .mysql),
                       "SELECT `id`, `customer`, `amount`, `qty`, `name`, `region` FROM (SELECT `_l`.`id` AS `id`, `_l`.`customer` AS `customer`, `_l`.`amount` AS `amount`, "
                       + "`_l`.`qty` AS `qty`, `_r`.`name` AS `name`, `_r`.`region` AS `region` FROM (SELECT `id`, `customer`, `amount`, `qty` FROM `sales`.`orders`) AS `_l` "
                       + "INNER JOIN (SELECT `name`, `region` FROM `public`.`customers`) AS `_r` ON (`_l`.`customer` <=> `_r`.`name`)) AS `_`")
        // MySQL has no FULL OUTER JOIN; tables on different servers can't join in one query; anti joins run here.
        XCTAssertNil(try sql("Table.Join(Orders, {\"customer\"}, Customers, {\"name\"}, JoinKind.FullOuter)", .mysql))
        XCTAssertNotNil(try sql("Table.Join(Orders, {\"customer\"}, Customers, {\"name\"}, JoinKind.FullOuter)", .postgres))
        XCTAssertNil(try sql(expanded, .postgres, otherServer: true))
        XCTAssertNil(try sql("Table.ExpandTableColumn(Table.NestedJoin(Orders, {\"customer\"}, Customers, {\"name\"}, \"C\", JoinKind.LeftAnti), \"C\", {\"region\"})", .postgres))
    }

    func testPendingNestedJoinLoadsLikeM() throws {
        // Without an expand, the nested tables are built here from the two folded queries.
        let db = Recorder(.postgres), ctx = MInterpreter()
        let env = MEnv(parent: nil, vars: ["Orders": table(db, "\"o\"", ["id", "customer"], ctx), "Customers": table(db, "\"c\"", ["name", "region"], ctx)])
        let v = try ctx.evaluate("Table.NestedJoin(Orders, {\"customer\"}, Customers, {\"name\"}, \"C\", JoinKind.Inner)", env: env)
        XCTAssertEqual(columnNames(v), ["id", "customer", "C"])
        XCTAssertEqual(try tableRows(v), [])
        XCTAssertEqual(db.statements, [#"SELECT "id", "customer" FROM "o""#, #"SELECT "name", "region" FROM "c""#])
    }

    func testNativeParameters() throws {
        let pg = try NativeParameters.bind("select * from t where a = @a and b = @b or a = @a -- @c\n and s = '@a'", .record(MRecord(names: ["a", "b"], values: [.number(1), .text("x")])), dialect: .postgres)
        XCTAssertEqual(pg.sql, "select * from t where a = $1 and b = $2 or a = $1 -- @c\n and s = '@a'")
        XCTAssertEqual(pg.values.map(show), ["1", "x"])
        let my = try NativeParameters.bind("select @a, @b, @a, @@version", .record(MRecord(names: ["a", "b"], values: [.number(1), .number(2)])), dialect: .mysql)
        XCTAssertEqual(my.sql, "select ?, ?, ?, @@version")
        XCTAssertEqual(my.values.map(show), ["1", "2", "1"])
        XCTAssertThrowsError(try NativeParameters.bind("select 1", .record(MRecord(names: ["x"], values: [.number(1)])), dialect: .postgres))
        XCTAssertEqual(try NativeParameters.bind("select $1", .list([.text("a")]), dialect: .postgres).values.map(show), ["a"])
    }

    func testOptionsAndCredentials() throws {
        let s = try ServerSource(product: .postgres, server: "db.example.com", database: "sales",
                                 options: MRecord(names: ["CommandTimeout", "TrustServerCertificate"], values: [.duration(90), .logical(true)]), maxBytes: 1 << 20)
        XCTAssertEqual(s.limits.commandTimeout, 90)
        XCTAssertTrue(s.trustServerCertificate)
        XCTAssertTrue(s.encrypt, "encrypted unless turned off")
        XCTAssertEqual(s.location, "db.example.com;sales")
        XCTAssertEqual(s.address.port, 5432)
        XCTAssertEqual(try ServerSource(product: .redshift, server: "c.redshift.amazonaws.com", database: "dev", options: nil, maxBytes: 1).address.port, 5439)
        XCTAssertThrowsError(try ServerSource(product: .mysql, server: "db", database: " ", options: nil, maxBytes: 1))
        // No stored credential: a clear DataSource.Error naming the source.
        let failure = try XCTUnwrap(failureOf("PostgreSQL.Database(\"db.example.com\", \"sales\")"))
        XCTAssertEqual(failure.reason, "DataSource.Error")
        XCTAssertTrue(failure.message.contains("db.example.com;sales"), failure.message)
        // {"upn":"ann@contoso.com"} as a JWT payload (the signature isn't checked here: the server does that).
        let payload = Data(#"{"upn":"ann@contoso.com"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try ServerSource.tokenUser("eyJhbGciOiJub25lIn0.\(payload).sig"), "ann@contoso.com")
        XCTAssertThrowsError(try ServerSource.tokenUser("not-a-token"))
    }

    private func failureOf(_ m: String) -> MError? {
        do { _ = try MInterpreter().evaluate(m); return nil } catch { return MError.wrap(error) }
    }
}

/// The output column names of a statement the folding code built (`SELECT "a", "b" FROM …`, outermost list).
enum RemoteSQLSourceTestNames {
    static func columns(in sql: String) -> [String] {
        guard let from = sql.range(of: " FROM ") else { return [] }
        let list = sql[sql.index(sql.startIndex, offsetBy: 7)..<from.lowerBound]
        return list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"`")) }
    }
}
