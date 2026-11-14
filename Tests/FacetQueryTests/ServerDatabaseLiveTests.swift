import XCTest
import FacetCore
@testable import FacetQuery

/// Live tests against real servers. They run only when a connection string is set and are skipped otherwise:
///
///     ANALYTICS_TEST_POSTGRES="postgresql://user:password@127.0.0.1:5432/postgres?trust=1"
///     ANALYTICS_TEST_MYSQL="mysql://root:password@127.0.0.1:3306/test?trust=1"
///
/// `trust=1` accepts a self-signed certificate; `encrypt=0` connects without TLS. Servers for them:
///
///     docker run --rm -d --name pg -p 5432:5432 -e POSTGRES_PASSWORD=password postgres:17 -c ssl=on \
///         -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
///     docker run --rm -d --name my -p 3306:3306 -e MYSQL_ROOT_PASSWORD=password -e MYSQL_DATABASE=test mysql:8.4
///     docker run --rm -d --name maria -p 3307:3306 -e MARIADB_ROOT_PASSWORD=password -e MARIADB_DATABASE=test mariadb:11
///
/// Each test creates its own uniquely named table and drops it afterwards.
final class ServerDatabaseLiveTests: XCTestCase {
    struct Target {
        var function: String
        var server: String
        var database: String
        var options: String
        var user: String
        var password: String
        var kind: String
    }

    final class Credentials: CredentialProvider, @unchecked Sendable {
        let user: String, password: String
        init(user: String, password: String) { self.user = user; self.password = password }
        func credential(kind: String, location: String) -> SourceCredential? { .basic(username: user, password: password) }
        func accessToken(resource: String, host: String) async throws -> String { throw MError.dataSource("no tokens in tests") }
    }

    static func target(_ variable: String, function: String, kind: String, port: Int) throws -> Target {
        guard let text = ProcessInfo.processInfo.environment[variable], let url = URLComponents(string: text), let host = url.host else {
            throw XCTSkip("Set \(variable) to run the live \(kind) tests.")
        }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var options: [String] = []
        if q["trust"] == "1" { options.append("TrustServerCertificate = true") }
        if q["encrypt"] == "0" { options.append("EncryptConnection = false") }
        return Target(function: function, server: "\(host):\(url.port ?? port)", database: String(url.path.dropFirst()),
                      options: "[" + options.joined(separator: ", ") + "]", user: url.user ?? "", password: url.password ?? "", kind: kind)
    }

    private func environment(_ t: Target, password: String? = nil) -> QueryEnvironment {
        var env = QueryEnvironment(credentials: Credentials(user: t.user, password: password ?? t.password))
        env.requireNativeQueryApproval = false
        return env
    }
    private func source(_ t: Target, extra: String = "") -> String {
        let opts = extra.isEmpty ? t.options : (t.options == "[]" ? "[\(extra)]" : String(t.options.dropLast()) + ", \(extra)]")
        return "\(t.function)(\(MSyntax.text(t.server)), \(MSyntax.text(t.database)), \(opts))"
    }
    private func eval(_ t: Target, _ m: String) throws -> MValue { try MInterpreter(environment: environment(t)).evaluate(m) }
    private func native(_ t: Target, _ sql: String) throws {
        _ = try eval(t, "Value.NativeQuery(\(source(t)), \(MSyntax.text(sql)))")
    }

    /// Creates `name` with five orders and a customers table, runs `body`, and drops them.
    private func withTables(_ t: Target, mysql: Bool, _ body: (String, String) throws -> Void) throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let orders = "facet_orders_\(suffix)", customers = "facet_customers_\(suffix)"
        let text = mysql ? "varchar(40)" : "text"
        try native(t, "create table \(orders) (id int primary key, customer \(text), amount decimal(10,2), qty int, placed date)")
        try native(t, "create table \(customers) (name \(text), region \(text))")
        defer {
            try? native(t, "drop table \(orders)")
            try? native(t, "drop table \(customers)")
        }
        try native(t, "insert into \(orders) values (1,'Ann',120.50,2,'2024-01-02'),(2,'Bob',80,1,'1999-12-31'),(3,'Cy',300,5,'2024-02-29'),"
                       + "(4,'Cid',null,3,null),(5,'Bob',100,1,null)")
        try native(t, "insert into \(customers) values ('Ann','North'),('Bob','South'),(null,'Nowhere')")
        try body(orders, customers)
    }

    private func check(_ t: Target, mysql: Bool) throws {
        try withTables(t, mysql: mysql) { orders, customers in
            let schema = mysql ? t.database : "public"
            let nav = "\(source(t)){[Schema = \(MSyntax.text(schema)), Item = \(MSyntax.text(orders))]}[Data]"
            let cust = "\(source(t)){[Schema = \(MSyntax.text(schema)), Item = \(MSyntax.text(customers))]}[Data]"
            XCTAssertEqual(columnNames(try eval(t, nav)), ["id", "customer", "amount", "qty", "placed"])
            XCTAssertEqual(try tableRows(try eval(t, "Table.Sort(\(nav), {\"id\"})")).first, ["1", "Ann", "120.5", "2", "#date(2024, 1, 2)"])

            // Folding: filter, sort, top, group, join; then the same rows as M computes.
            let filtered = "Table.FirstN(Table.Sort(Table.SelectRows(\(nav), each [amount] >= 100 or [customer] = null), {{\"amount\", Order.Descending}}), 2)"
            XCTAssertEqual(try tableRows(try eval(t, "Table.SelectColumns(\(filtered), {\"id\"})")), [["3"], ["1"]])
            let engine = QueryEngine(queries: [QueryDefinition(name: "Q", mScript: "let S = \(filtered) in S")], environment: environment(t))
            let sql = try XCTUnwrap(try awaitResult { try await engine.nativeQuery(for: "Q") })
            XCTAssertTrue(sql.contains("ORDER BY") && sql.contains("LIMIT 2"), sql)

            let grouped = "Table.Sort(Table.Group(\(nav), {\"customer\"}, {{\"n\", each Table.RowCount(_), Int64.Type}, {\"total\", each List.Sum([qty]), type number}}), {\"customer\"})"
            XCTAssertEqual(try tableRows(try eval(t, grouped)), [["Ann", "1", "2"], ["Bob", "2", "2"], ["Cid", "1", "3"], ["Cy", "1", "5"]])
            XCTAssertTrue(try eval(t, grouped).tableValue?.isLazy ?? false)

            let joined = "Table.Sort(Table.ExpandTableColumn(Table.NestedJoin(\(nav), {\"customer\"}, \(cust), {\"name\"}, \"C\", JoinKind.LeftOuter), "
                + "\"C\", {\"region\"}, {\"C.region\"}), {\"id\"})"
            XCTAssertEqual(try tableRows(try eval(t, "Table.SelectColumns(\(joined), {\"id\", \"C.region\"})")),
                           [["1", "North"], ["2", "South"], ["3", "null"], ["4", "null"], ["5", "South"]])

            // Native query with parameters by name and by position.
            XCTAssertEqual(try tableRows(try eval(t, "Value.NativeQuery(\(source(t)), \"select id from \(orders) where qty >= @min order by id\", [min = 3])")),
                           [["3"], ["4"]])
            let positional = mysql ? "?" : "$1"
            XCTAssertEqual(try tableRows(try eval(t, "Value.NativeQuery(\(source(t)), \"select count(*) as n from \(orders) where customer = \(positional)\", {\"Bob\"})")),
                           [["2"]])

            // Server errors are DataSource.Error with the server's message.
            do { _ = try eval(t, "Value.NativeQuery(\(source(t)), \"select nope from \(orders)\")"); XCTFail("expected an error") } catch {
                XCTAssertEqual(MError.wrap(error).reason, "DataSource.Error")
                XCTAssertTrue(MError.wrap(error).message.contains("nope"), MError.wrap(error).message)
            }
        }
        // Wrong password.
        do { _ = try MInterpreter(environment: environment(t, password: "wrong-\(UUID())")).evaluate(source(t)); XCTFail("expected an error") } catch {
            XCTAssertEqual(MError.wrap(error).reason, "DataSource.Error")
        }
    }

    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task { do { result = .success(try await body()) } catch { result = .failure(error) }; done.signal() }
        done.wait()
        return try XCTUnwrap(result).get()
    }

    func testPostgreSQL() throws {
        let t = try Self.target("ANALYTICS_TEST_POSTGRES", function: "PostgreSQL.Database", kind: "PostgreSQL", port: 5432)
        try check(t, mysql: false)
        // A statement that outlives CommandTimeout is cancelled.
        let start = Date()
        do { _ = try eval(t, "Value.NativeQuery(\(source(t, extra: "CommandTimeout = #duration(0, 0, 0, 1)")), \"select pg_sleep(30)\")"); XCTFail("expected a timeout") } catch {
            XCTAssertTrue(MError.wrap(error).message.contains("cancelled"), MError.wrap(error).message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
        let sql = "select 1::int2 as a, 2::int8 as b, 1.5::numeric as c, true as d, 'x'::text as e, '\\x01ff'::bytea as f, "
            + "date '2024-01-02' as g, timestamp '2024-01-02 03:04:05.25' as h, '1 day 01:00'::interval as i, "
            + "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid as j, '{\"k\": 1}'::jsonb as k, time '12:30' as l"
        let types = try tableRows(try eval(t, "Value.NativeQuery(\(source(t)), \(MSyntax.text(sql)))"))
        XCTAssertEqual(types, [["1", "2", "1.5", "true", "x", "<binary 2>", "#date(2024, 1, 2)", "#datetime(2024, 1, 2, 3, 4, 5.25)",
                                "#duration(1, 1, 0, 0)", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "{\"k\": 1}", "#time(12, 30, 0)"]])
    }

    func testMySQL() throws {
        let t = try Self.target("ANALYTICS_TEST_MYSQL", function: "MySQL.Database", kind: "MySQL", port: 3306)
        try check(t, mysql: true)
        let types = try tableRows(try eval(t, "Value.NativeQuery(\(source(t)), \"select cast(1 as signed) as a, 1.5 as b, date '2024-01-02' as c, "
            + "timestamp '2024-01-02 03:04:05' as d, 'x' as e, time '12:30:00' as f\")"))
        XCTAssertEqual(types, [["1", "1.5", "#date(2024, 1, 2)", "#datetime(2024, 1, 2, 3, 4, 5)", "x", "#time(12, 30, 0)"]])
        // The same values through the binary protocol (a prepared statement).
        let binary = try tableRows(try eval(t, "Value.NativeQuery(\(source(t)), \"select cast(? as signed) as a, date '2024-01-02' as c, timestamp '2024-01-02 03:04:05' as d\", {1})"))
        XCTAssertEqual(binary, [["1", "#date(2024, 1, 2)", "#datetime(2024, 1, 2, 3, 4, 5)"]])
    }
}
