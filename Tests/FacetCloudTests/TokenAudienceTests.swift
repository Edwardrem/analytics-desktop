import XCTest
@testable import FacetCloud

/// Data-source tokens: each resource's token reaches only its own hosts, and a new resource asks for consent once.
@MainActor
final class TokenAudienceTests: XCTestCase {
    private let sql = "https://database.windows.net/.default"
    private let storage = "https://storage.azure.com/.default"
    private let oss = "https://ossrdbms-aad.database.windows.net/.default"

    func testEachResourceReachesOnlyItsOwnHosts() {
        let allowed: [(String, String)] = [
            (sql, "contoso.database.windows.net"),
            (sql, "abc123.datawarehouse.fabric.microsoft.com"),
            (sql, "ws.sql.azuresynapse.net"),
            (storage, "acct.blob.core.windows.net"),
            (storage, "acct.dfs.core.windows.net"),
            (storage, "onelake.dfs.fabric.microsoft.com"),
            (oss, "pg1.postgres.database.azure.com"),
            (oss, "my1.mysql.database.azure.com"),
            ("https://contoso.crm.dynamics.com/.default", "contoso.crm.dynamics.com"),
            ("https://contoso.crm4.dynamics.com/.default", "contoso.crm4.dynamics.com"),
            ("https://help.kusto.windows.net/.default", "help.kusto.windows.net"),
            ("https://contoso.sharepoint.com/.default", "contoso.sharepoint.com"),
            ("https://graph.microsoft.com/.default", "graph.microsoft.com"),
            ("https://analysis.windows.net/powerbi/api/.default", "api.powerbi.com"),
        ]
        for (r, h) in allowed { XCTAssertTrue(TokenAudiencePolicy.allows(resource: r, host: h), "\(r) → \(h)") }
    }

    func testLookAlikeHostsAreRefused() {
        let refused: [(String, String)] = [
            (sql, "database.windows.net"),                         // no server label
            (sql, "contoso.database.windows.net.evil.com"),        // suffix in the middle
            (sql, "evildatabase.windows.net"),                     // no dot boundary
            (sql, "contoso.database.windows.net."),                // trailing dot
            (sql, "contoso..database.windows.net"),                // empty label
            (sql, "acct.blob.core.windows.net"),                   // another service's host
            (storage, "acct.blob.core.windows.net.attacker.io"),
            (storage, "acctblob.core.windows.net"),
            (storage, "contoso.database.windows.net"),
            (oss, "pg1.postgres.database.azure.com.evil.net"),
            (oss, "postgres.database.azure.com"),
            ("https://contoso.crm.dynamics.com/.default", "contoso.crm.dynamics.com.evil.com"),
            ("https://contoso.crm.dynamics.com/.default", "fabrikam.crm.dynamics.com"),   // other tenant's org
            ("https://evilcrm.dynamics.com/.default", "evilcrm.dynamics.com"),
            ("https://contoso.crmx.dynamics.com/.default", "contoso.crmx.dynamics.com"),
            ("https://crm.dynamics.com/.default", "crm.dynamics.com"),
            ("https://help.kusto.windows.net/.default", "help.kusto.windows.net.evil.com"),
            ("https://evil.com/.default", "evil.com"),                                     // unknown audience
            ("https://contoso.sharepoint.com/.default", "contoso.sharepoint.com.evil.com"),
            ("https://a.b.sharepoint.com/.default", "a.b.sharepoint.com"),
            ("https://contoso.sharepoint.com/.default", "fabrikam.sharepoint.com"),
            ("https://graph.microsoft.com/.default", "graph.microsoft.com.evil.com"),
            ("https://analysis.windows.net/powerbi/api/.default", "contoso.database.windows.net"),
            (sql, "10.0.0.1"),
            ("http://contoso.crm.dynamics.com/.default", "contoso.crm.dynamics.com"),     // non-https audience
        ]
        for (r, h) in refused { XCTAssertFalse(TokenAudiencePolicy.allows(resource: r, host: h), "\(r) → \(h)") }
    }

    func testNationalCloudsOnlyMapTheirOwnServices() {
        XCTAssertTrue(TokenAudiencePolicy.allows(resource: "https://graph.microsoft.us/.default", host: "graph.microsoft.us", cloud: .usGovernment))
        XCTAssertFalse(TokenAudiencePolicy.allows(resource: sql, host: "contoso.database.windows.net", cloud: .usGovernment))
    }

    // MARK: Manager

    private var server = StubIdentityServer()
    private var suite = ""
    private var defaults = UserDefaults.standard

    override func setUp() async throws {
        server = StubIdentityServer(); server.install()
        (defaults, suite) = scratchDefaults()
    }
    override func tearDown() async throws { SelfCheckURLProtocol.handler = nil; defaults.removePersistentDomain(forName: suite) }

    private func manager() -> MicrosoftAccountManager {
        MicrosoftAccountManager(configuration: MicrosoftAuthConfiguration(clientID: StubIdentityServer.clientID),
                                secrets: InMemorySecretStore(), defaults: defaults,
                                sessionConfiguration: SelfCheckURLProtocol.configuration(), openURL: server.browser())
    }

    func testARefusedHostNeverReachesTheTokenEndpoint() async throws {
        let m = manager()
        _ = try await m.signIn()
        let before = server.tokenForms.count
        do { _ = try await m.accessToken(resource: sql, host: "contoso.database.windows.net.evil.com"); XCTFail("expected a refusal") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .hostNotAllowed(host: "contoso.database.windows.net.evil.com", resource: "Azure SQL")) }
        XCTAssertEqual(server.tokenForms.count, before)
    }

    func testANewResourceOpensTheBrowserOnceForConsent() async throws {
        let m = manager()
        _ = try await m.signIn()
        XCTAssertEqual(server.authorizeQueries.count, 1)
        server.scopesNeedingConsent = [sql]
        let token = try await m.accessToken(resource: sql, host: "contoso.database.windows.net")
        XCTAssertTrue(token.hasPrefix("AT-"))
        XCTAssertEqual(server.authorizeQueries.count, 2, "one interactive sign-in for the new scope")
        XCTAssertTrue((server.authorizeQueries.last?["scope"] ?? "").contains(sql))
        // Consent is remembered: the next token comes silently.
        _ = try await m.accessToken(resource: sql, host: "other.database.windows.net")
        XCTAssertEqual(server.authorizeQueries.count, 2)
    }

    func testWithoutInteractionConsentIsReportedNotPrompted() async throws {
        let m = manager()
        _ = try await m.signIn()
        server.scopesNeedingConsent = [storage]
        do { _ = try await m.accessToken(resource: storage, host: "acct.blob.core.windows.net", interactive: false); XCTFail("expected consent error") }
        catch { guard case MicrosoftAuthError.consentRequired = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(server.authorizeQueries.count, 1)
    }

    func testTheDefaultClientIDComesFromInfoPlistAndTheOverrideWins() {
        var c = MicrosoftAuthConfiguration(defaultClientID: "00000000-0000-0000-0000-00000000fake")
        XCTAssertTrue(c.isConfigured)
        XCTAssertTrue(c.usesDefaultRegistration)
        XCTAssertEqual(c.effectiveClientID, "00000000-0000-0000-0000-00000000fake")
        XCTAssertEqual(c.endpoint("authorize").path, "/organizations/oauth2/v2.0/authorize", "multi-tenant work or school authority")
        c.clientID = "11111111-0000-0000-0000-00000000fake"
        XCTAssertEqual(c.effectiveClientID, "11111111-0000-0000-0000-00000000fake")
        XCTAssertFalse(c.usesDefaultRegistration)
        XCTAssertFalse(MicrosoftAuthConfiguration().isConfigured)
        XCTAssertTrue(MicrosoftAuthError.clientIDMissing.errorDescription?.contains("AnalyticsEntraClientID") ?? false)
        // The override is what is saved; the bundled default is not.
        let data = (try? JSONEncoder().encode(c)) ?? Data()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("00000000-0000-0000-0000-00000000fake"))
    }
}
