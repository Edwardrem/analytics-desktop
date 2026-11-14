import XCTest
import FacetCore
@testable import FacetQuery

/// The engine side of Microsoft sign-in: connectors ask `QueryEnvironment` for a token and always name the host.
final class AccessTokenProviderTests: CloudStubTestCase {
    func testEnvironmentPassesResourceAndHostToTheProvider() async throws {
        let token = try await env.accessToken(resource: EntraResource.azureSQL, host: "contoso.database.windows.net")
        XCTAssertEqual(token, "FAKE-TOKEN-for-https://database.windows.net/.default")
        XCTAssertEqual(creds.calls.first?.host, "contoso.database.windows.net")
    }

    func testWithoutAProviderTheErrorSaysToSignIn() async {
        let bare = QueryEnvironment()
        do { _ = try await bare.accessToken(resource: EntraResource.storage, host: "x.blob.core.windows.net"); XCTFail("expected an error") }
        catch { XCTAssertTrue(MError.wrap(error).message.contains("Sign in")) }
    }

    func testResourceHelpersKeepOnlyTheOrigin() {
        XCTAssertEqual(EntraResource.dataverse("https://Contoso.crm4.dynamics.com/api/data/v9.2"), "https://contoso.crm4.dynamics.com/.default")
        XCTAssertEqual(EntraResource.kusto("help.kusto.windows.net"), "https://help.kusto.windows.net/.default")
        XCTAssertEqual(EntraResource.sharePoint("https://contoso.sharepoint.com/sites/Sales"), "https://contoso.sharepoint.com/.default")
    }

    func testWebContentsSendsAnOrganizationalTokenForItsOwnHost() throws {
        creds.stored["Web|https://contoso.sharepoint.com"] = .oauth(resource: "https://contoso.sharepoint.com/.default")
        CloudStub.handler = { _ in .json("{\"ok\":true}") }
        _ = try eval("Web.Contents(\"https://contoso.sharepoint.com/_api/web\")")
        XCTAssertEqual(creds.calls.map(\.host), ["contoso.sharepoint.com"])
        XCTAssertEqual(CloudStub.requests.first.flatMap(bearer), "Bearer FAKE-TOKEN-for-https://contoso.sharepoint.com/.default")
    }

    func testWebContentsNeverSendsAnOrganizationalTokenOverHTTP() {
        creds.stored["Web|http://contoso.example"] = .oauth(resource: "https://contoso.example/.default")
        let e = failure("Web.Contents(\"http://contoso.example/data\")")
        XCTAssertTrue(e?.message.contains("only sent over https") ?? false, e?.message ?? "no error")
        XCTAssertTrue(creds.calls.isEmpty)
    }

    func testCloudHTTPRefusesPlainHTTP() {
        let ctx = MInterpreter(environment: env)
        XCTAssertThrowsError(try CloudHTTP.send(ctx, service: "Test", url: URL(string: "http://x.blob.core.windows.net/c")!, auth: .entra(resource: EntraResource.storage)))
        XCTAssertTrue(creds.calls.isEmpty)
    }

    func testCloudHTTPStopsAtTheSizeLimit() {
        CloudStub.handler = { _ in .bytes(Data(repeating: 7, count: 5000)) }
        let ctx = MInterpreter(environment: env)
        XCTAssertThrowsError(try CloudHTTP.send(ctx, service: "Test", url: URL(string: "https://x.blob.core.windows.net/c")!, auth: .none, limit: 1000)) {
            XCTAssertTrue(MError.wrap($0).message.contains("too large"))
        }
    }

    func testErrorsNeverEchoTheQueryString() {
        CloudStub.handler = { _ in .json("{\"error\":{\"message\":\"Denied\"}}", status: 403) }
        let ctx = MInterpreter(environment: env)
        XCTAssertThrowsError(try CloudHTTP.send(ctx, service: "Azure Blob Storage", url: URL(string: "https://x.blob.core.windows.net/c?sig=FAKE-SIGNATURE")!, auth: .none)) {
            let m = MError.wrap($0).message
            XCTAssertTrue(m.contains("Denied"))
            XCTAssertFalse(m.contains("FAKE-SIGNATURE"))
        }
    }
}
