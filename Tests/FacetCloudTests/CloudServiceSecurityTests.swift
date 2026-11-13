import XCTest
@testable import FacetCloud

/// Where credentials may go, how much is read, and the cloud calls behind save-back, publish and labels.
/// Every request is answered in-process by `SelfCheckURLProtocol`.
final class CloudServiceSecurityTests: XCTestCase {
    private let tokens = StubTokenProvider()
    private let seen = Recorder<[(method: String, url: String, headers: [String: String], body: Data)]>([])

    override func tearDown() {
        SelfCheckURLProtocol.handler = nil
        super.tearDown()
    }

    private func stub(_ respond: @escaping @Sendable (URLRequest, Data) -> SelfCheckURLProtocol.Response) {
        let seen = self.seen
        SelfCheckURLProtocol.handler = { request, body in
            seen.update { $0.append((request.httpMethod ?? "GET", request.url?.absoluteString ?? "", request.allHTTPHeaderFields ?? [:], body)) }
            return respond(request, body)
        }
    }

    private func temporaryFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("facet-test-\(UUID().uuidString).facet")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Allow-list

    func testCredentialsAreLimitedToTheMicrosoftServiceHosts() throws {
        let policy = EndpointPolicy(cloud: .public)
        let allowed = ["https://graph.microsoft.com/v1.0/me", "https://api.powerbi.com/v1.0/myorg/groups",
                       "https://api.fabric.microsoft.com/v1/workspaces", "https://onelake.dfs.fabric.microsoft.com/ws/lh/Files",
                       "https://westeurope-onelake.dfs.fabric.microsoft.com/ws"]
        for u in allowed { XCTAssertTrue(policy.allowsCredentials(for: URL(string: u)), u) }
        let refused = ["http://graph.microsoft.com/v1.0/me",                      // not https
                       "https://graph.microsoft.com.evil.example/v1.0/me",        // look-alike suffix
                       "https://evil.example/graph.microsoft.com",                // host in the path
                       "https://user@graph.microsoft.com/v1.0/me",                // userinfo
                       "https://graph.microsoft.com@evil.example/",               // userinfo trick
                       "https://dfs.fabric.microsoft.com/",                       // the bare suffix is not a OneLake host
                       "https://contoso.sharepoint.com/sites/x",                  // pre-authenticated hosts never get the bearer
                       "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                       "ftp://graph.microsoft.com/"]
        for u in refused { XCTAssertFalse(policy.allowsCredentials(for: URL(string: u)), u) }
        XCTAssertFalse(policy.allowsCredentials(for: nil))

        XCTAssertTrue(policy.allowsSignInPage(URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?x=1")))
        XCTAssertTrue(policy.allowsSignInPage(URL(string: "https://microsoft.com/devicelogin")))
        XCTAssertFalse(policy.allowsSignInPage(URL(string: "http://login.microsoftonline.com/common")))
        XCTAssertFalse(policy.allowsSignInPage(URL(string: "https://login.microsoftonline.com.evil.example/")))

        // National clouds use their own hosts and not the global ones.
        let gov = EndpointPolicy(cloud: .usGovernment)
        XCTAssertTrue(gov.allowsCredentials(for: URL(string: "https://graph.microsoft.us/v1.0/me")))
        XCTAssertFalse(gov.allowsCredentials(for: URL(string: "https://graph.microsoft.com/v1.0/me")))
    }

    func testLoopbackRedirectURIs() {
        XCTAssertTrue(EndpointPolicy.isLoopbackRedirect("http://localhost:52011"))
        XCTAssertTrue(EndpointPolicy.isLoopbackRedirect("http://127.0.0.1:52011/"))
        for bad in ["https://localhost:52011", "http://localhost", "http://localhost:80", "http://localhost.evil.example:52011",
                    "http://0.0.0.0:52011", "http://192.168.1.4:52011", "http://localhost:52011/callback", "http://localhost:52011?x=1",
                    "http://u@localhost:52011"] {
            XCTAssertFalse(EndpointPolicy.isLoopbackRedirect(bad), bad)
        }
    }

    func testBearerTokenIsNotSentToAHostOutsideTheAllowList() async throws {
        stub { _, _ in .json(#"{"value":[]}"#) }
        let graph = GraphClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        // A paging link pointing somewhere else (a tampered or malicious response) must not be followed with credentials.
        let page = GraphPage<DriveItem>(items: [], nextLink: URL(string: "https://evil.example/v1.0/me/drive/root/children?$skiptoken=x"))
        do { _ = try await graph.nextPage(after: page); XCTFail("followed a link to another host") }
        catch let e as CloudAPIError { XCTAssertEqual(e.kind, .invalidResponse) }
        // The transport layer refuses on its own, whatever the caller checked.
        do { _ = try await graph.rest.send(URLRequest(url: try XCTUnwrap(URL(string: "https://evil.example/v1.0/me")))); XCTFail("sent credentials to another host") }
        catch let e as CloudAPIError {
            XCTAssertEqual(e.kind, .badRequest)
            XCTAssertTrue(e.message.contains("evil.example"))
        }
        do { _ = try await graph.rest.send(URLRequest(url: try XCTUnwrap(URL(string: "http://graph.microsoft.com/v1.0/me"))), authenticated: false); XCTFail("sent a request over http") }
        catch let e as CloudAPIError { XCTAssertEqual(e.kind, .badRequest) }
        XCTAssertTrue(seen.value.isEmpty, "no request left the client")
        XCTAssertTrue(tokens.calls.value.isEmpty, "no token was even requested")
    }

    func testRedirectsNeverCarryTheTokenToAnotherHostOrOverHTTP() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/1/content")))
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        func proposed(_ u: String) throws -> URLRequest {
            var r = URLRequest(url: try XCTUnwrap(URL(string: u)))
            r.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            return r
        }
        let sameHost = RedirectGuard.nextRequest(original: original, proposed: try proposed("https://graph.microsoft.com/v1.0/other"), followRedirects: true)
        XCTAssertEqual(sameHost?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let otherHost = RedirectGuard.nextRequest(original: original, proposed: try proposed("https://contoso.sharepoint.com/download?tempauth=x"), followRedirects: true)
        XCTAssertNotNil(otherHost)
        XCTAssertNil(otherHost?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(RedirectGuard.nextRequest(original: original, proposed: try proposed("http://graph.microsoft.com/v1.0/other"), followRedirects: true))
        XCTAssertNil(RedirectGuard.nextRequest(original: original, proposed: try proposed("https://graph.microsoft.com/v1.0/other"), followRedirects: false))
    }

    func testOversizedResponseIsRejected() async throws {
        stub { _, _ in SelfCheckURLProtocol.Response(status: 200, body: Data(repeating: 0x20, count: 300_000)) }
        let graph = GraphClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        graph.rest.responseLimit = 100_000
        do { _ = try await graph.me(); XCTFail("read a response over the limit") }
        catch let e as CloudAPIError { XCTAssertEqual(e.kind, .invalidResponse) }
    }

    func testLogRedactionHidesTokensAndCodes() throws {
        var r = URLRequest(url: try XCTUnwrap(URL(string: "https://x.example/cb?code=SECRETCODE&state=SECRETSTATE&keep=1&access_token=AT&sig=SIG")))
        r.setValue("Bearer SECRETBEARER", forHTTPHeaderField: "Authorization")
        r.setValue("k", forHTTPHeaderField: "x-api-key")
        let line = CloudLog.redactedDescription(of: r)
        for secret in ["SECRETCODE", "SECRETSTATE", "SECRETBEARER", "=AT", "SIG"] { XCTAssertFalse(line.contains(secret), secret) }
        XCTAssertTrue(line.contains("keep=1"))
    }

    // MARK: Save back with an eTag

    private static let itemJSON = #"{"id":"ITEM1","name":"Sales.facet","size":12,"eTag":"\"{E2},3\"","file":{"mimeType":"application/octet-stream"},"parentReference":{"driveId":"DRIVE1"}}"#

    func testSaveBackSendsIfMatchAndReportsAConflict() async throws {
        let file = try temporaryFile(bytes: 12)
        let graph = GraphClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        let location = DriveLocation.item(driveID: "DRIVE1", itemID: "ITEM1")

        stub { _, _ in .json(Self.itemJSON) }
        let saved = try await graph.replaceContent(of: location, withFileAt: file, ifMatchETag: "\"{E1},2\"")
        XCTAssertEqual(saved.eTag, "\"{E2},3\"")
        let put = try XCTUnwrap(seen.value.last)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.url, "https://graph.microsoft.com/v1.0/drives/DRIVE1/items/ITEM1/content")
        XCTAssertEqual(put.headers["If-Match"], "\"{E1},2\"")
        XCTAssertEqual(put.body.count, 12)

        // The file changed in the cloud: Graph answers 412 and nothing is overwritten.
        stub { _, _ in .json(#"{"error":{"code":"resourceModified","message":"The resource has changed since the caller last read it."}}"#, status: 412) }
        do { _ = try await graph.replaceContent(of: location, withFileAt: file, ifMatchETag: "\"{E1},2\""); XCTFail("conflict not reported") }
        catch let e as CloudAPIError {
            XCTAssertEqual(e.kind, .preconditionFailed)
            XCTAssertEqual(e.code, "resourceModified")
        }
    }

    func testLargeSaveBackUsesAnUploadSessionGuardedByTheETag() async throws {
        let size = Int(GraphClient.simpleUploadLimit) + 1024
        let file = try temporaryFile(bytes: size)
        let graph = GraphClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        stub { request, _ in
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/createUploadSession") { return .json(#"{"uploadUrl":"https://contoso.sharepoint.com/upload/session-1?tempauth=abc"}"#) }
            return .json(Self.itemJSON, status: 201)
        }
        _ = try await graph.replaceContent(of: .item(driveID: "DRIVE1", itemID: "ITEM1"), withFileAt: file, ifMatchETag: "\"{E1},2\"")
        let create = try XCTUnwrap(seen.value.first)
        XCTAssertEqual(create.method, "POST")
        XCTAssertEqual(create.headers["If-Match"], "\"{E1},2\"")
        XCTAssertEqual(create.headers["Authorization"], "Bearer stale-token")
        let chunk = try XCTUnwrap(seen.value.last)
        XCTAssertEqual(chunk.method, "PUT")
        XCTAssertTrue(chunk.url.hasPrefix("https://contoso.sharepoint.com/upload/session-1"))
        XCTAssertNil(chunk.headers["Authorization"], "the pre-authenticated upload URL must not receive the bearer token")
        XCTAssertEqual(chunk.headers["Content-Range"], "bytes 0-\(size - 1)/\(size)")
    }

    // MARK: Publish (Fabric item definitions)

    func testCreateItemSendsTheDefinitionAndFollowsTheOperation() async throws {
        let fabric = FabricClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        fabric.rest.sleeper = { _ in }
        stub { request, _ in
            let url = request.url?.absoluteString ?? ""
            if request.httpMethod == "POST" {
                return SelfCheckURLProtocol.Response(status: 202, headers: ["Location": "https://api.fabric.microsoft.com/v1/operations/OP1", "x-ms-operation-id": "OP1", "Retry-After": "1"])
            }
            if url.hasSuffix("/operations/OP1") { return .json(#"{"status":"Succeeded"}"#) }
            if url.hasSuffix("/operations/OP1/result") { return .json(#"{"id":"MODEL1","displayName":"Sales","type":"SemanticModel","workspaceId":"WS1"}"#) }
            return .json("{}", status: 404)
        }
        let item = try await fabric.createItem(workspaceID: "WS1", type: .semanticModel, displayName: "Sales",
                                               parts: [FabricDefinitionPart(path: "definition/model.tmdl", text: "model Model")])
        XCTAssertEqual(item.id, "MODEL1")
        let post = try XCTUnwrap(seen.value.first)
        XCTAssertEqual(post.url, "https://api.fabric.microsoft.com/v1/workspaces/WS1/items")
        let body = try JSONValue.parse(post.body)
        XCTAssertEqual(body["displayName"]?.stringValue, "Sales")
        XCTAssertEqual(body["type"]?.stringValue, "SemanticModel")
        let part = try XCTUnwrap(body["definition"]?["parts"]?[0])
        XCTAssertEqual(part["path"]?.stringValue, "definition/model.tmdl")
        XCTAssertEqual(part["payloadType"]?.stringValue, "InlineBase64")
        // "model Model" in base64.
        XCTAssertEqual(part["payload"]?.stringValue, "bW9kZWwgTW9kZWw=")
        XCTAssertEqual(seen.value.map(\.url).suffix(2), ["https://api.fabric.microsoft.com/v1/operations/OP1",
                                                         "https://api.fabric.microsoft.com/v1/operations/OP1/result"])
    }

    func testOperationLocationOnAnotherHostIsNotFollowed() async throws {
        let fabric = FabricClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        fabric.rest.sleeper = { _ in }
        stub { request, _ in
            if request.httpMethod == "POST" { return SelfCheckURLProtocol.Response(status: 202, headers: ["Location": "https://evil.example/operations/OP1"]) }
            return .json(#"{"status":"Succeeded"}"#)
        }
        do {
            try await fabric.updateItemDefinition(workspaceID: "WS1", itemID: "I1", parts: [])
            XCTFail("an operation without a trustworthy location succeeded")
        } catch let e as CloudAPIError { XCTAssertEqual(e.kind, .invalidResponse) }
        XCTAssertFalse(seen.value.contains { $0.url.contains("evil.example") })
    }

    // MARK: Sensitivity labels

    func testSensitivityLabelsComeFromGraphAndMissingConsentIsExplained() async throws {
        let fabric = FabricClient(tokenProvider: tokens, sessionConfiguration: SelfCheckURLProtocol.configuration())
        stub { _, _ in
            .json(##"{"value":[{"id":"L1","name":"General","color":"#0078D4","sensitivity":1,"isActive":true,"tooltip":"Business data"},{"id":"L2","name":"Confidential","sensitivity":3,"isActive":true}]}"##)
        }
        let labels = try await fabric.sensitivityLabels()
        XCTAssertEqual(labels.map(\.name), ["General", "Confidential"])
        XCTAssertEqual(labels.first?.color, "#0078D4")
        XCTAssertEqual(seen.value.first?.url, "https://graph.microsoft.com/beta/me/security/informationProtection/sensitivityLabels")

        stub { _, _ in .json(#"{"error":{"code":"Forbidden","message":"Insufficient privileges"}}"#, status: 403) }
        do { _ = try await fabric.sensitivityLabels(); XCTFail("a 403 was not reported") }
        catch let e as CloudAPIError {
            XCTAssertEqual(e.kind, .forbidden)
            XCTAssertTrue(e.message.contains("InformationProtectionPolicy.Read"))
        }
    }
}
