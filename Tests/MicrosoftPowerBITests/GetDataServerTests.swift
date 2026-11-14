import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Get Data for database servers (PostgreSQL, MySQL, MariaDB, Amazon Redshift): the M written, reading it back,
/// the data source recorded, validation, navigation keys, folding indicators and DirectQuery source counting.
@MainActor
final class GetDataServerTests: XCTestCase {
    private func request(_ kind: SourceKind, _ server: String, _ database: String) -> SourceRequest {
        var r = SourceRequest(kind: kind, location: server)
        r.database = database
        return r
    }

    func testSourceExpressions() {
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.postgresql, "db.example.com", "sales")), #"PostgreSQL.Database("db.example.com", "sales")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.mysql, "my:3307", "shop")), #"MySQL.Database("my:3307", "shop")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.mariadb, "m", "d")), #"MariaDB.Contents("m", "d")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.redshift, "c", "dev")), #"AmazonRedshift.Database("c", "dev")"#)
        var plain = request(.postgresql, "localhost", "d")
        plain.encrypt = false
        XCTAssertEqual(SourcePlanner.sourceExpression(plain), #"PostgreSQL.Database("localhost", "d", [EncryptConnection = false])"#)
        // A typed statement becomes a folding native query, as for SQLite.
        var sql = request(.mysql, "h", "d")
        sql.nativeQuery = "select 1"
        XCTAssertEqual(SourcePlanner.sourceSteps(sql).last?.expression, #"Value.NativeQuery(Source, "select 1", null, [EnableFolding = true])"#)
    }

    func testRequestReadBackFromSource() throws {
        let r = try XCTUnwrap(SourcePlanner.request(fromSource: #"PostgreSQL.Database("db:5433", "sales", [CommandTimeout = #duration(0, 0, 5, 0)])"#))
        XCTAssertEqual(r.kind, .postgresql)
        XCTAssertEqual(r.location, "db:5433")
        XCTAssertEqual(r.database, "sales")
        XCTAssertTrue(r.encrypt)
        XCTAssertEqual(SourcePlanner.request(fromSource: #"MariaDB.Contents("m", "d", [EncryptConnection = false])"#)?.encrypt, false)
        XCTAssertNil(SourcePlanner.request(fromSource: #"MySQL.Database("only-server")"#))
    }

    func testCertificateTrustIsKeptPerHost() {
        // The key "Trust server certificate" stores, matching what the connectors look up: the host without port, lower-cased.
        XCTAssertEqual(ServerDatabaseHost.name("DB.Example.com:5433"), "db.example.com")
        XCTAssertEqual(ServerDatabaseHost.name("db.example.com,3307"), "db.example.com")
        XCTAssertEqual(ServerDatabaseHost.name("[::1]:5432"), "::1")
        XCTAssertNil(ServerDatabaseHost.name("  "))
        XCTAssertNil(ServerDatabaseHost.name("db:notaport"))
    }

    func testDataSourceValidationAndName() {
        XCTAssertEqual(SourcePlanner.dataSource(request(.postgresql, " db ", "sales")), QueryDataSource(kind: "PostgreSQL", location: "db;sales"))
        XCTAssertEqual(SourcePlanner.dataSource(request(.redshift, "c", "dev"))?.kind, "AmazonRedshift")
        XCTAssertEqual(SourcePlanner.validationMessage(request(.mysql, "", "d")), "Type the server name.")
        XCTAssertEqual(SourcePlanner.validationMessage(request(.mysql, "h", " ")), "Type the database name.")
        XCTAssertNil(SourcePlanner.validationMessage(request(.mysql, "h", "d")))
        XCTAssertEqual(SourcePlanner.queryName(request(.postgresql, "h", "sales"), item: nil), "sales")
        XCTAssertTrue(SourceKind.postgresql.isDatabase && SourceKind.sqlite.isDatabase && !SourceKind.sqlite.isServer)
    }

    func testNavigatorUsesSchemaAndItem() throws {
        // A server navigation table (as PostgreSQL.Database returns it): objects are keyed by schema and name.
        let nav = MTable(names: ["Name", "Data", "Schema", "Item", "Kind"], types: [.text, .anyTable, .text, .text, .text],
                         rows: [[.text("sales.orders"), .table(.empty), .text("sales"), .text("orders"), .text("Table")],
                                [.text("public.orders"), .table(.empty), .text("public"), .text("orders"), .text("View")]])
        nav.meta = MRecord(names: ["Facet.ServerDatabase"], values: [.record(MRecord(names: [], values: []))])
        XCTAssertTrue(nav.isServerDatabaseNavigation)
        let items = try XCTUnwrap(try SourcePlanner.navigatorItems(from: .table(nav)))
        XCTAssertEqual(items.map(\.selector), [#"{[Schema = "sales", Item = "orders"]}[Data]"#, #"{[Schema = "public", Item = "orders"]}[Data]"#])
        XCTAssertEqual(items.map(\.stepName), ["sales_orders", "public_orders"])
        XCTAssertEqual(items.map(\.kind), ["Table", "View"])
    }

    func testFoldingIndicatorsAndDirectQuerySources() {
        let q = QueryDefinition(name: "Q", mScript: #"let S = PostgreSQL.Database("db", "sales") in S"#)
        XCTAssertTrue(QueryEditorSession.mayFold(q, in: [q]))
        XCTAssertEqual(DirectQuerySession.sourceKey(#"let S = PostgreSQL.Database( "DB.example.com", "sales") in S"#, query: "Q"), "postgresql.database:db.example.com")
        XCTAssertEqual(DirectQuerySession.sourceKey(#"MySQL.Database("h", "d")"#, query: "Q"), "mysql.database:h")
        XCTAssertEqual(DirectQuerySession.sourceKey("Csv.Document(File.Contents(\"x.csv\"))", query: "Q"), "query:Q")
    }

    func testRecentServerReopensWithItsDatabase() throws {
        let store = DocumentStore(services: .live())
        let s = GetDataSession(store: store, security: QuerySecurity(defaults: try XCTUnwrap(UserDefaults(suiteName: "GetDataServerTests-\(UUID())"))))
        s.choose(try XCTUnwrap(DataConnector.connector("postgresql")), location: "db.example.com;sales")
        XCTAssertEqual(s.request.location, "db.example.com")
        XCTAssertEqual(s.request.database, "sales")
        XCTAssertEqual(s.stage, .form)
    }
}
