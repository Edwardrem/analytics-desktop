import XCTest
@testable import FacetQuery

/// Runs against a real SQL Server only when `ANALYTICS_TEST_MSSQL` holds a connection string; skipped otherwise.
///
/// To start one locally (Docker):
///
///     docker run -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='Str0ng!Passw0rd' -p 1433:1433 -d mcr.microsoft.com/azure-sql-edge
///     export ANALYTICS_TEST_MSSQL='Server=localhost,1433;Database=master;User Id=sa;Password=Str0ng!Passw0rd;TrustServerCertificate=True'
///     swift test --filter SQLServerLiveTests
///
/// Add `Encrypt=Strict` to test TDS 8.0 against SQL Server 2022. The test creates and drops one table.
final class SQLServerLiveTests: XCTestCase {
    private struct Settings {
        var server = "", database = "master", user = "", password = ""
        var trust = false, strict = false
    }

    private func settings() throws -> Settings {
        guard let text = ProcessInfo.processInfo.environment["ANALYTICS_TEST_MSSQL"], !text.isEmpty else {
            throw XCTSkip("Set ANALYTICS_TEST_MSSQL to a SQL Server connection string to run the live tests.")
        }
        var s = Settings()
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "server", "data source", "address": s.server = kv[1]
            case "database", "initial catalog": s.database = kv[1]
            case "user id", "uid", "user": s.user = kv[1]
            case "password", "pwd": s.password = kv[1]
            case "trustservercertificate": s.trust = ["true", "yes"].contains(kv[1].lowercased())
            case "encrypt": s.strict = kv[1].lowercased() == "strict"
            default: break
            }
        }
        return s
    }

    private func connect(_ s: Settings) throws -> TDSConnection {
        var o = TDSConnectOptions(address: try TDSServerAddress(s.server), database: s.database, authentication: .sql(user: s.user, password: s.password))
        o.trustServerCertificate = s.trust
        o.strictEncryption = s.strict
        return try TDSConnection.open(o)
    }

    func testTypesRoundTripThroughTDS() throws {
        let c = try connect(try settings())
        defer { c.close() }
        let r = try c.execute("""
            select cast(255 as tinyint) as t, cast(-2 as smallint) as s, 7 as i, cast(9007199254740991 as bigint) as b, cast(1 as bit) as f,
                   cast(12.345 as decimal(10, 3)) as d, cast(-1.5 as money) as m, cast(2.5 as smallmoney) as sm, cast(0.5 as float) as fl, cast(0.25 as real) as r,
                   N'Grüße' as n, 'abc' as v, cast(0x0102 as varbinary(10)) as vb, cast('00112233-4455-6677-8899-AABBCCDDEEFF' as uniqueidentifier) as g,
                   cast('2024-02-29' as date) as dt, cast('13:45:30.1234567' as time(7)) as tm, cast('2024-02-29 13:45:30.123' as datetime) as dtm,
                   cast('2024-02-29 13:45:30.1234567' as datetime2(7)) as dt2, cast('2024-02-29 13:45:30 +02:00' as datetimeoffset(0)) as dto,
                   cast('2024-02-29 13:45' as smalldatetime) as sdt, cast(replicate(cast(N'x' as nvarchar(max)), 10000) as nvarchar(max)) as big,
                   cast('<a>1</a>' as xml) as x, cast(null as int) as nul, cast(42 as sql_variant) as var
            """, timeout: 30)
        let set = try XCTUnwrap(r.resultSets.first)
        func v(_ name: String) throws -> MValue { try XCTUnwrap(set.columns.firstIndex { $0.name == name }.flatMap { set.values[$0].first }) }
        XCTAssertEqual(try v("t").numberValue, 255)
        XCTAssertEqual(try v("s").numberValue, -2)
        XCTAssertEqual(try v("i").numberValue, 7)
        XCTAssertEqual(try v("b").numberValue, 9_007_199_254_740_991)
        XCTAssertEqual(try v("f").logicalValue, true)
        XCTAssertEqual(try v("d").numberValue, 12.345)
        XCTAssertEqual(try v("m").numberValue, -1.5)
        XCTAssertEqual(try v("sm").numberValue, 2.5)
        XCTAssertEqual(try v("fl").numberValue, 0.5)
        XCTAssertEqual(try v("r").numberValue, 0.25)
        XCTAssertEqual(try v("n").textValue, "Grüße")
        XCTAssertEqual(try v("v").textValue, "abc")
        XCTAssertEqual(try v("vb").binaryValue, Data([1, 2]))
        XCTAssertEqual(try v("g").textValue, "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertEqual(try v("big").textValue?.count, 10_000)
        XCTAssertEqual(try v("x").textValue, "<a>1</a>")
        XCTAssertTrue(try v("nul").isNull)
        XCTAssertEqual(try v("var").numberValue, 42)
        // 2024-02-29 is 19 782 days after 1970-01-01.
        let day = 19_782.0 * 86_400
        guard case .date(let dt) = try v("dt"), case .time(let tm) = try v("tm"), case .datetime(let dtm) = try v("dtm"),
              case .datetime(let dt2) = try v("dt2"), case .datetimezone(let dto, let offset) = try v("dto"), case .datetime(let sdt) = try v("sdt") else {
            return XCTFail("date and time columns")
        }
        XCTAssertEqual(dt.timeIntervalSince1970, day)
        XCTAssertEqual(tm, 49_530.123_456_7, accuracy: 1e-7)
        XCTAssertEqual(dtm.timeIntervalSince1970, day + 49_530.123, accuracy: 0.000_5)
        XCTAssertEqual(dt2.timeIntervalSince1970, day + 49_530.123_456_7, accuracy: 1e-6)
        XCTAssertEqual(dto.timeIntervalSince1970, day + 49_530 - 7_200)
        XCTAssertEqual(offset, 120)
        XCTAssertEqual(sdt.timeIntervalSince1970, day + 49_500)
        // A parameterised statement and a server error that leaves the connection usable.
        let p = try c.execute("select @a + 1 as n, @s as s", parameters: [TDSParameter(name: "@a", value: .bigint(41)), TDSParameter(name: "@s", value: .text("é"))], timeout: 30)
        XCTAssertEqual(p.resultSets.first?.values.first?.first?.numberValue, 42)
        XCTAssertEqual(p.resultSets.first?.values.last?.first?.textValue, "é")
        XCTAssertThrowsError(try c.execute("select * from dbo.NoSuchTable_AnalyticsDesktop", timeout: 30))
        XCTAssertEqual(try c.execute("select 1", timeout: 30).resultSets.first?.values.first?.first?.numberValue, 1)
    }

    func testMQueriesFoldAgainstTheServer() throws {
        let s = try settings()
        let table = "AnalyticsDesktopTest_" + UUID().uuidString.prefix(8)
        let c = try connect(s)
        defer { _ = try? c.execute("drop table if exists dbo.[\(table)]", timeout: 30); c.close() }
        _ = try c.execute("""
            create table dbo.[\(table)] (Id int not null primary key, Region nvarchar(20) null, Amount decimal(10, 2) null);
            insert dbo.[\(table)] values (1, N'West', 10), (2, N'East', 20), (3, null, 30), (4, N'West', 5);
            """, timeout: 30)
        let credentials = FakeCredentials()
        let location = s.server + ";" + s.database
        credentials.stored["SQL|" + location] = .basic(username: s.user, password: s.password)
        var env = QueryEnvironment(credentials: credentials)
        if s.trust { env.trustServerCertificateHosts = [try TDSServerAddress(s.server).host.lowercased()] }
        let i = MInterpreter(environment: env)
        let options = s.strict ? ", [Encrypt = \"Strict\"]" : ""
        let source = "Sql.Database(\(MSyntax.text(s.server)), \(MSyntax.text(s.database))\(options)){[Schema = \"dbo\", Item = \(MSyntax.text(table))]}[Data]"
        let filtered = try i.evaluate("Table.Sort(Table.SelectRows(\(source), each [Region] <> \"West\"), {\"Id\"})")
        // M keeps the null region: null <> "West" is true.
        XCTAssertEqual(try tableRows(filtered), [["2", "East", "20"], ["3", "null", "30"]])
        let grouped = try i.evaluate("Table.Sort(Table.Group(\(source), {\"Region\"}, {{\"Total\", each List.Sum([Amount]), type number}}), {\"Total\"})")
        XCTAssertEqual(try tableRows(grouped), [["West", "15"], ["East", "20"], ["null", "30"]])
        XCTAssertTrue(i.nativeQueries.contains { $0.contains("group by [Region]") }, "the group folded")
        let native = try i.evaluate("Value.NativeQuery(Sql.Database(\(MSyntax.text(s.server)), \(MSyntax.text(s.database))\(options)), \"select count(*) as n from dbo.[\(table)] where Amount > @min\", [min = 9])")
        XCTAssertEqual(try tableRows(native), [["3"]])
    }
}
