import XCTest
import FacetCore
import FacetQuery
import FacetCloud
@testable import MicrosoftPowerBI

/// Get Data for SQL Server, Azure SQL, Synapse and Fabric warehouses: M generation, the form's rules and sign-in.
final class SQLServerGetDataTests: XCTestCase {
    private func request(_ server: String, _ database: String, sql: String = "") -> SourceRequest {
        var r = SourceRequest(kind: .sqlServer, location: server)
        r.database = database
        r.nativeQuery = sql
        return r
    }

    func testSourceStepIsSqlDatabaseAndReadsBack() {
        XCTAssertEqual(SourcePlanner.sourceExpression(request("sql01,1433", "Sales")), "Sql.Database(\"sql01,1433\", \"Sales\")")
        let native = request("x.database.windows.net", "db", sql: "select 1 as \"n\"")
        XCTAssertEqual(SourcePlanner.sourceExpression(native), "Sql.Database(\"x.database.windows.net\", \"db\", [Query = \"select 1 as \"\"n\"\"\"])")
        // The native query lives in the Query option, as Power BI writes it: no separate step.
        XCTAssertEqual(SourcePlanner.sourceSteps(native).map(\.name), ["Source"])
        XCTAssertEqual(SourcePlanner.request(fromSource: SourcePlanner.sourceExpression(native)), native)
        XCTAssertEqual(SourcePlanner.queryName(request("s", "Sales"), item: nil), "Sales")
        XCTAssertEqual(SourcePlanner.dataSource(request("s", "Sales")), QueryDataSource(kind: "SQL", location: "s;Sales"))
    }

    func testFormRules() {
        let user = SQLServerSignIn(method: .database, user: "sa", password: "pw")
        XCTAssertEqual(SQLServerConnection.validationMessage(server: " ", database: "d", signIn: user, hasStoredCredential: false), "Type the server name.")
        XCTAssertNotNil(SQLServerConnection.validationMessage(server: "a b", database: "d", signIn: user, hasStoredCredential: false))
        XCTAssertNotNil(SQLServerConnection.validationMessage(server: "s", database: "", signIn: user, hasStoredCredential: false))
        XCTAssertNil(SQLServerConnection.validationMessage(server: "s", database: "d", signIn: user, hasStoredCredential: false))
        XCTAssertEqual(SQLServerConnection.validationMessage(server: "s", database: "d", signIn: SQLServerSignIn(method: .database), hasStoredCredential: false),
                       "Type the database user name and password.")
        XCTAssertNil(SQLServerConnection.validationMessage(server: "s", database: "d", signIn: SQLServerSignIn(method: .database), hasStoredCredential: true))
        // Windows authentication is not available on macOS, and the form says so instead of trying.
        let windows = SQLServerConnection.validationMessage(server: "s", database: "d", signIn: SQLServerSignIn(method: .windows), hasStoredCredential: true)
        XCTAssertEqual(windows, SQLServerConnection.windowsUnavailable)
        XCTAssertTrue(windows?.contains("macOS") ?? false)
    }

    func testHostsLocationsAndDefaultSignIn() {
        XCTAssertEqual(SQLServerConnection.host("tcp:SQL01.corp.example,1500"), "sql01.corp.example")
        XCTAssertEqual(SQLServerConnection.host(".\\SQLEXPRESS"), "localhost")
        XCTAssertEqual(SQLServerConnection.location(server: " s ", database: "db"), "s;db")
        XCTAssertEqual(SQLServerConnection.defaultMethod(for: "contoso.database.windows.net"), .microsoftAccount)
        XCTAssertEqual(SQLServerConnection.defaultMethod(for: "abc.datawarehouse.fabric.microsoft.com"), .microsoftAccount)
        XCTAssertEqual(SQLServerConnection.defaultMethod(for: "database.windows.net.example.com"), .database)
    }

    func testSignInIsStoredPerServerAndDatabase() throws {
        let store = DataSourceCredentialStore(store: InMemorySecretStore())
        try SQLServerConnection.save(SQLServerSignIn(method: .database, user: "sa", password: "pw"), server: "s", database: "db", store: store)
        XCTAssertEqual(try store.credential(kind: "SQL", location: "s;db"), .usernamePassword("sa", "pw"))
        XCTAssertTrue(SQLServerConnection.hasStoredCredential(server: "s", database: "db", store: store))
        try SQLServerConnection.save(SQLServerSignIn(method: .microsoftAccount), server: "s", database: "db", store: store)
        XCTAssertEqual(try store.credential(kind: "SQL", location: "s;db")?.kind, .microsoftAccount)
        // An empty user name keeps what is stored; Windows stores nothing.
        XCTAssertNil(SQLServerConnection.credential(for: SQLServerSignIn(method: .database)))
        XCTAssertNil(SQLServerConnection.credential(for: SQLServerSignIn(method: .windows)))
    }

    func testDatabaseNavigatorUsesSchemaAndItem() throws {
        let t = MTable(names: ["A"], rows: [[.number(1)]])
        let nav = MTable(names: ["Name", "Data", "Schema", "Item", "Kind"], types: [.text, .anyTable, .text, .text, .text],
                         rows: [[.text("Sales"), .table(t), .text("dbo"), .text("Sales"), .text("Table")],
                                [.text("Sales"), .table(t), .text("archive"), .text("Sales"), .text("View")]])
        let items = try XCTUnwrap(try SourcePlanner.navigatorItems(from: .table(nav)))
        XCTAssertEqual(items.map(\.name), ["dbo.Sales", "archive.Sales"])
        XCTAssertEqual(items.map(\.selector), ["{[Schema = \"dbo\", Item = \"Sales\"]}[Data]", "{[Schema = \"archive\", Item = \"Sales\"]}[Data]"])
        XCTAssertEqual(items[0].stepName, "dbo_Sales")
    }

    func testDirectQueryCountsFetchesPerServer() {
        XCTAssertEqual(DirectQuerySession.sourceKey("let S = Sql.Database(\"SQL01\", \"db\") in S", query: "Q"), "sql:sql01")
    }
}
