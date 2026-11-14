import XCTest
import FacetCore
import FacetQuery
import FacetCloud
@testable import MicrosoftPowerBI

/// The app's credential provider and the credentials dialog's logic. Every password, key and token is an obvious fake;
/// credentials live in an in-memory store, never the Keychain.
final class DataSourceCredentialsTests: XCTestCase {
    private final class TokenLog: @unchecked Sendable {
        var calls: [(String, String)] = []
    }

    private func provider(_ log: TokenLog = TokenLog()) -> AppCredentials {
        AppCredentials(store: DataSourceCredentialStore(store: InMemorySecretStore())) { resource, host in
            log.calls.append((resource, host))
            return "FAKE-TOKEN"
        }
    }

    private func basic(_ c: SourceCredential?) -> (String, String)? {
        if case .basic(let u, let p)? = c { return (u, p) }
        return nil
    }
    private func oauth(_ c: SourceCredential?) -> String? {
        if case .oauth(let r)? = c { return r }
        return nil
    }

    // MARK: Key convention shared with the database connectors

    func testSQLUserAndPasswordMapToBasic() throws {
        let p = provider()
        try p.save(.usernamePassword("sa", "FAKE-PASSWORD"), kind: "SQL", location: "srv.contoso.com;Sales")
        let c = basic(p.credential(kind: "SQL", location: "srv.contoso.com;Sales"))
        XCTAssertEqual(c?.0, "sa")
        XCTAssertEqual(c?.1, "FAKE-PASSWORD")
        // Another database on the same server has no credential of its own.
        XCTAssertNil(p.credential(kind: "SQL", location: "srv.contoso.com;HR"))
        // Kinds don't mix.
        XCTAssertNil(p.credential(kind: "PostgreSQL", location: "srv.contoso.com;Sales"))
    }

    func testServerCredentialCoversItsDatabasesButNotLookAlikeServers() throws {
        let p = provider()
        try p.save(.usernamePassword("u", "FAKE-PASSWORD"), kind: "SQL", location: "srv")
        XCTAssertNotNil(basic(p.credential(kind: "SQL", location: "srv")))
        XCTAssertNotNil(basic(p.credential(kind: "SQL", location: "srv;Sales")))
        XCTAssertNil(p.credential(kind: "SQL", location: "srv2;Sales"))
        XCTAssertNil(p.credential(kind: "SQL", location: "srv.evil.com"))
    }

    func testLongestMatchingLocationWins() throws {
        let p = provider()
        try p.save(.usernamePassword("server-user", "FAKE-1"), kind: "SQL", location: "srv")
        try p.save(.usernamePassword("db-user", "FAKE-2"), kind: "SQL", location: "srv;Sales")
        XCTAssertEqual(basic(p.credential(kind: "SQL", location: "srv;Sales"))?.0, "db-user")
        XCTAssertEqual(basic(p.credential(kind: "SQL", location: "srv;HR"))?.0, "server-user")
    }

    func testOrganizationalAccountMapsToTheKindsResource() throws {
        let p = provider()
        let account = DataSourceCredential(kind: .microsoftAccount, username: "account-id")
        try p.save(account, kind: "SQL", location: "contoso.database.windows.net;Sales")
        try p.save(account, kind: "PostgreSQL", location: "pg.postgres.database.azure.com;app")
        try p.save(account, kind: "MySQL", location: "my.mysql.database.azure.com;app")
        try p.save(account, kind: "AzureBlobs", location: "https://acct.blob.core.windows.net")
        try p.save(account, kind: "Web", location: "https://contoso.example.com")
        XCTAssertEqual(oauth(p.credential(kind: "SQL", location: "contoso.database.windows.net;Sales")), "https://database.windows.net/.default")
        XCTAssertEqual(oauth(p.credential(kind: "PostgreSQL", location: "pg.postgres.database.azure.com;app")), "https://ossrdbms-aad.database.windows.net/.default")
        XCTAssertEqual(oauth(p.credential(kind: "MySQL", location: "my.mysql.database.azure.com;app")), "https://ossrdbms-aad.database.windows.net/.default")
        XCTAssertEqual(oauth(p.credential(kind: "AzureBlobs", location: "https://acct.blob.core.windows.net")), "https://storage.azure.com/.default")
        XCTAssertEqual(oauth(p.credential(kind: "Web", location: "https://contoso.example.com/api")), "https://contoso.example.com/.default")
    }

    func testWebLocationsMatchOnlyAtPathBoundaries() throws {
        let p = provider()
        try p.save(DataSourceCredential(kind: .apiKey, secret: "FAKE-KEY", properties: ["headerName": "X-API-Key"]), kind: "Web", location: "https://api.example.com/v1")
        guard case .apiKey(let key, let header, let parameter)? = p.credential(kind: "Web", location: "https://api.example.com/v1/items?x=1") else {
            return XCTFail("the key covers paths below it")
        }
        XCTAssertEqual(key, "FAKE-KEY"); XCTAssertEqual(header, "X-API-Key"); XCTAssertNil(parameter)
        XCTAssertNil(p.credential(kind: "Web", location: "https://api.example.com/v10"))
        XCTAssertNil(p.credential(kind: "Web", location: "https://api.example.com.evil.com/v1"))
        XCTAssertNil(p.credential(kind: "Web", location: "https://api.example.com"))
    }

    func testRemovingACredentialTakesItAwayAtOnce() throws {
        let p = provider()
        try p.save(.usernamePassword("u", "FAKE-PASSWORD"), kind: "Web", location: "https://a.example.com")
        XCTAssertNotNil(p.credential(kind: "Web", location: "https://a.example.com"))
        XCTAssertEqual(p.storedSources.map(\.location), ["https://a.example.com"])
        p.remove(kind: "Web", location: "https://a.example.com")
        XCTAssertNil(p.credential(kind: "Web", location: "https://a.example.com"))
        XCTAssertTrue(p.storedSources.isEmpty)
    }

    func testTokensAreAskedForTheRequestedHost() async throws {
        let log = TokenLog()
        let p = provider(log)
        _ = try await p.accessToken(resource: EntraResource.storage, host: "acct.blob.core.windows.net")
        XCTAssertEqual(log.calls.first?.0, "https://storage.azure.com/.default")
        XCTAssertEqual(log.calls.first?.1, "acct.blob.core.windows.net")
    }

    func testMethodsOfferedPerKind() {
        XCTAssertEqual(CredentialMethod.offered(forKind: "SQL"), [.basic, .organizational])
        XCTAssertEqual(CredentialMethod.offered(forKind: "PostgreSQL"), [.basic, .organizational])
        XCTAssertEqual(CredentialMethod.offered(forKind: "Web"), [.anonymous, .basic, .apiKey, .organizational])
        XCTAssertEqual(CredentialMethod.offered(forKind: "AzureBlobs").first, .organizational)
        XCTAssertEqual(provider().methodTitle(kind: "SharePoint", location: "https://contoso.sharepoint.com"), "Organizational account")
        XCTAssertEqual(provider().methodTitle(kind: "Web", location: "https://x.example.com"), "Anonymous")
    }

    // MARK: Credentials dialog

    func testLevelsRunFromTheHostDownToTheAddress() {
        XCTAssertEqual(CredentialForm.levels(for: "https://api.example.com/v1/items"),
                       ["https://api.example.com", "https://api.example.com/v1", "https://api.example.com/v1/items"])
        XCTAssertEqual(CredentialForm.levels(for: "srv;Sales"), ["srv;Sales"])
    }

    func testFormProblems() {
        var v = CredentialForm.Values()
        XCTAssertNil(CredentialForm.problem(v, signedIn: false))
        v.method = .basic
        XCTAssertEqual(CredentialForm.problem(v, signedIn: false), "Enter a user name.")
        v.username = "me"
        XCTAssertNil(CredentialForm.problem(v, signedIn: false))
        v.method = .apiKey
        XCTAssertEqual(CredentialForm.problem(v, signedIn: false), "Enter the key.")
        v.secret = "FAKE-KEY"
        XCTAssertNotNil(CredentialForm.problem(v, signedIn: false), "a header or query parameter is needed")
        v.queryParameter = "api_key"
        XCTAssertNil(CredentialForm.problem(v, signedIn: false))
        v.method = .accountKey
        v.secret = "not base64!"
        XCTAssertNotNil(CredentialForm.problem(v, signedIn: false))
        v.secret = "RkFLRS1LRVk="
        XCTAssertNil(CredentialForm.problem(v, signedIn: false))
        v.method = .organizational
        XCTAssertNotNil(CredentialForm.problem(v, signedIn: false))
        XCTAssertNil(CredentialForm.problem(v, signedIn: true))
    }

    func testFormValuesBecomeStoredCredentials() {
        var v = CredentialForm.Values(method: .apiKey, secret: "FAKE-KEY", headerName: " X-Key ", queryParameter: "ignored")
        let key = CredentialForm.credential(v, accountID: nil)
        XCTAssertEqual(key.kind, .apiKey)
        XCTAssertEqual(key.properties, ["headerName": "X-Key"])
        v = CredentialForm.Values(method: .basic, username: " me ", secret: "FAKE-PASSWORD")
        XCTAssertEqual(CredentialForm.credential(v, accountID: nil), .usernamePassword("me", "FAKE-PASSWORD"))
        v = CredentialForm.Values(method: .organizational)
        XCTAssertEqual(CredentialForm.credential(v, accountID: "acct-1"), DataSourceCredential(kind: .microsoftAccount, username: "acct-1"))
    }
}
