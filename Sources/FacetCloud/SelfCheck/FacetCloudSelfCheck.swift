import Foundation
import FacetCore

/// Offline self-test for FacetCloud. Exercises everything that does not need a live Microsoft or Anthropic
/// service: PKCE, OAuth request building, token/JWT parsing, the loopback redirect listener (against a real
/// local HTTP request), Graph / Power BI / Fabric JSON decoding against sample payloads, the HTTP retry layer,
/// token refresh and sign-in flows against an in-process stub server, and the assistant's SSE parsing, request
/// building and tool loop. No request leaves the machine.
public enum FacetCloudSelfCheck {
    public struct Report: Sendable {
        public let passed: Int
        public let failures: [String]
        /// Checks that could not run in this environment (e.g. no usable Keychain), with the reason.
        public let skipped: [String]
    }

    /// Runs every check and returns the failures. **An empty array means everything passed.**
    /// Safe to call from the main thread (it services the main run loop while waiting).
    public static func run() -> [String] { runReportBlocking().failures }

    /// Blocking variant of `runReport()`.
    public static func runReportBlocking() -> Report {
        let box = ResultBox()
        Task.detached {
            let r = await runReport()
            box.set(r)
        }
        if Thread.isMainThread {
            while box.value == nil { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        } else {
            while box.value == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        return box.value ?? Report(passed: 0, failures: ["self-check did not produce a result"], skipped: [])
    }

    /// Runs every check.
    public static func runReport() async -> Report {
        let c = Checker()
        await c.section("JSON") { checkJSON(c) }
        await c.section("HTTP helpers") { checkHTTPHelpers(c) }
        await c.section("PKCE") { checkPKCE(c) }
        await c.section("OAuth URLs") { checkOAuthRequests(c) }
        await c.section("Token responses") { try checkTokenParsing(c) }
        await c.section("JWT claims") { try checkJWT(c) }
        await c.section("Redirect evaluation") { checkRedirectEvaluation(c) }
        await c.section("Loopback listener") { try await checkLoopbackListener(c) }
        await c.section("Graph decoding") { try checkGraphDecoding(c) }
        await c.section("Power BI decoding") { try checkPowerBIDecoding(c) }
        await c.section("Fabric decoding") { try checkFabricDecoding(c) }
        await c.section("Credential stores") { try checkCredentialStores(c) }
        await c.section("Keychain") { checkKeychain(c) }
        await c.section("REST retry layer") { try await checkRESTClient(c) }
        await c.section("Graph client (stubbed)") { try await checkGraphClientStubbed(c) }
        await c.section("Power BI / Fabric clients (stubbed)") { try await checkPowerBIFabricStubbed(c) }
        await c.section("Token refresh (stubbed)") { try await checkTokenRefresh(c) }
        await c.section("Interactive sign-in (stubbed)") { try await checkInteractiveSignIn(c) }
        await c.section("Device code sign-in (stubbed)") { try await checkDeviceCodeSignIn(c) }
        await c.section("SSE parser") { checkSSE(c) }
        await c.section("Assistant stream") { try checkAssistantAccumulator(c) }
        await c.section("Assistant request") { try checkAssistantRequest(c) }
        await c.section("Assistant history") { checkAssistantHistory(c) }
        await c.section("Assistant tool loop (stubbed)") { try await checkAssistantSession(c) }
        return Report(passed: c.passed, failures: c.failures, skipped: c.skipped)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: FacetCloudSelfCheck.Report?
    var value: FacetCloudSelfCheck.Report? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: FacetCloudSelfCheck.Report) { lock.lock(); _value = v; lock.unlock() }
}

/// Collects check results.
final class Checker: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private(set) var skipped: [String] = []
    private var current = ""

    func section(_ name: String, _ body: () async throws -> Void) async {
        lock.lock(); current = name; lock.unlock()
        do { try await body() }
        catch { fail("threw \(error)") }
    }
    func expect(_ condition: Bool, _ what: String) {
        if condition { lock.lock(); passed += 1; lock.unlock() } else { fail(what) }
    }
    func equal<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        if a == b { lock.lock(); passed += 1; lock.unlock() } else { fail("\(what): got \(a), expected \(b)") }
    }
    func fail(_ what: String) {
        lock.lock(); failures.append("[\(current)] \(what)"); lock.unlock()
    }
    func skip(_ why: String) {
        lock.lock(); skipped.append("[\(current)] \(why)"); lock.unlock()
    }
}

/// In-process stand-in for remote servers: every request made through a session using
/// `SelfCheckURLProtocol.configuration()` is answered by the current handler. Nothing touches the network.
final class SelfCheckURLProtocol: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, b in b }, body: Data(text.utf8))
        }
    }
    typealias Handler = @Sendable (URLRequest, Data) -> Response

    private static let lock = NSLock()
    private static var _handler: Handler?
    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SelfCheckURLProtocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
        }
        let r = Self.handler?(request, body) ?? Response.json(#"{"error":{"code":"noHandler","message":"no stub handler"}}"#, status: 500)
        guard let url = request.url, let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Thread-safe mutable box for stub handlers to record what they saw.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// A token provider with scripted tokens, counting calls.
final class StubTokenProvider: RefreshableAccessTokenProviding, @unchecked Sendable {
    let calls = Recorder<[(resource: String, forced: Bool)]>([])
    func accessToken(resource: String) async throws -> String {
        calls.update { $0.append((resource, false)) }
        return calls.value.contains { $0.forced } ? "fresh-token" : "stale-token"
    }
    func accessToken(resource: String, forceRefresh: Bool) async throws -> String {
        calls.update { $0.append((resource, forceRefresh)) }
        return "fresh-token"
    }
}

enum SelfCheckFixtures {
    /// An unsigned JWT with the given claims (signature segment is a placeholder; Facet never validates it).
    static func jwt(_ claims: JSONValue) -> String {
        let header = HTTPHelpers.base64URLEncode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        return header + "." + HTTPHelpers.base64URLEncode(claims.serializedData()) + ".c2lnbmF0dXJl"
    }

    static func formBody(_ data: Data) -> [String: String] {
        LoopbackRedirectListener.parseQuery("/?" + String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Pure checks

extension FacetCloudSelfCheck {
    static func checkJSON(_ c: Checker) {
        let text = #"{"b":1,"a":[true,null,2.5,"x\né😀"],"c":{"z":-3,"y":1e3}}"#
        guard let v = try? JSONValue.parse(text) else { c.fail("parse failed"); return }
        c.equal(v.members?.map(\.key) ?? [], ["b", "a", "c"], "object key order preserved")
        c.equal(v["b"], .int(1), "integer stays integer")
        c.equal(v["a"]?[2], .double(2.5), "decimal")
        c.equal(v["a"]?[3]?.stringValue, "x\né😀", "escapes and surrogate pairs")
        c.equal(v["c"]?["y"], .double(1000), "exponent is a double")
        c.equal(try? JSONValue.parse(v.serialized()), v, "serialise/parse round trip")
        c.expect((try? JSONValue.parse(#"{"a":1,}"#)) == nil, "trailing comma rejected")
        c.expect((try? JSONValue.parse(#"{"a":1} x"#)) == nil, "trailing garbage rejected")
        c.expect((try? JSONValue.parse(#"{"a":"unterminated"#)) == nil, "truncated input rejected")
        c.equal(JSONValue.string("a\"b\\c\u{01}").serialized(), #""a\"b\\c\u0001""#, "string escaping")
    }

    static func checkHTTPHelpers(_ c: Checker) {
        c.expect(HTTPHelpers.constantTimeEquals("abc", "abc"), "constant-time equal")
        c.expect(!HTTPHelpers.constantTimeEquals("abc", "abd"), "constant-time differ")
        c.expect(!HTTPHelpers.constantTimeEquals("abc", "abcd"), "constant-time length differ")
        c.equal(HTTPHelpers.base64URLDecode(HTTPHelpers.base64URLEncode(Data([0xfb, 0xff, 0xfe, 0x01]))), Data([0xfb, 0xff, 0xfe, 0x01]), "base64url round trip")
        c.expect(!HTTPHelpers.base64URLEncode(Data([0xfb, 0xff, 0xfe])).contains(where: { "+/=".contains($0) }), "base64url alphabet")
        c.equal(String(decoding: HTTPHelpers.formEncode([("a b", "c&d=e/é")]), as: UTF8.self), "a%20b=c%26d%3De%2F%C3%A9", "form encoding")
        let url = URL(string: "https://example.com")!
        let r1 = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7"])!
        c.equal(HTTPHelpers.retryAfter(from: r1), 7, "Retry-After seconds")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r2 = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "Tue, 14 Nov 2023 22:13:50 GMT"])!
        c.equal(HTTPHelpers.retryAfter(from: r2, now: now).map { Int($0.rounded()) }, 30, "Retry-After HTTP date")
        c.equal(HTTPHelpers.backoffDelay(attempt: 3, retryAfter: nil, jitter: 0), 8, "exponential backoff")
        c.equal(HTTPHelpers.backoffDelay(attempt: 10, retryAfter: nil, jitter: 0.25), 30, "backoff cap")
        c.equal(HTTPHelpers.backoffDelay(attempt: 0, retryAfter: 500), 120, "Retry-After cap")
        c.expect(HTTPHelpers.parseISODate("2024-03-05T10:20:30.123Z") != nil && HTTPHelpers.parseISODate("2024-03-05T10:20:30Z") != nil
                 && HTTPHelpers.parseISODate("2024-03-05T10:20:30") != nil, "ISO date variants")

        var req = URLRequest(url: URL(string: "https://login.example/token?code=SECRETCODE&client_id=abc&state=S")!)
        req.setValue("Bearer SECRETTOKEN", forHTTPHeaderField: "Authorization")
        req.setValue("sk-ant-SECRET", forHTTPHeaderField: "x-api-key")
        let d = CloudLog.redactedDescription(of: req)
        c.expect(!d.contains("SECRETTOKEN") && !d.contains("SECRETCODE") && !d.contains("sk-ant-SECRET"), "log redaction hides secrets: \(d)")
        c.expect(d.contains("client_id=abc") && d.contains("<redacted>"), "log redaction keeps non-secrets")

        var form = MultipartFormData(boundary: "B")
        form.addFile(name: "file", filename: "a\"b.pbix", contentType: "application/octet-stream", data: Data("DATA".utf8))
        let body = String(decoding: form.finalized(), as: UTF8.self)
        c.equal(body, "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a_b.pbix\"\r\nContent-Type: application/octet-stream\r\n\r\nDATA\r\n--B--\r\n", "multipart body")
    }

    static func checkPKCE(_ c: Checker) {
        // RFC 7636 Appendix B test vector.
        let known = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        c.equal(known.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 S256 vector")
        c.equal(known.method, "S256", "challenge method")
        let a = PKCEPair.generate(), b = PKCEPair.generate()
        c.equal(a.verifier.count, 43, "verifier length")
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        c.expect(a.verifier.allSatisfy { allowed.contains($0) }, "verifier uses unreserved characters")
        c.expect(a.verifier != b.verifier, "verifiers are random")
        c.equal(PKCEPair(verifier: a.verifier).challenge, a.challenge, "challenge is deterministic")
        c.equal(a.challenge.count, 43, "challenge length")
    }

    static func checkOAuthRequests(_ c: Checker) {
        let cfg = MicrosoftAuthConfiguration(clientID: "11111111-2222-3333-4444-555555555555")
        let b = OAuthRequestBuilder(configuration: cfg)
        let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = b.authorizationURL(redirectURI: "http://localhost:53124", state: "st+ate", nonce: "n-1", pkce: pkce, loginHint: "ana@contoso.com")
        c.equal(url.scheme, "https", "authorize scheme")
        c.equal(url.host, "login.microsoftonline.com", "authorize host")
        c.equal(url.path, "/common/oauth2/v2.0/authorize", "authorize path")
        let q = LoopbackRedirectListener.parseQuery(url.absoluteString.replacingOccurrences(of: "%20", with: "+"))
        c.equal(q["client_id"], cfg.clientID, "client_id")
        c.equal(q["response_type"], "code", "response_type")
        c.equal(q["redirect_uri"], "http://localhost:53124", "redirect_uri")
        c.equal(q["code_challenge"], pkce.challenge, "code_challenge")
        c.equal(q["code_challenge_method"], "S256", "code_challenge_method")
        c.equal(q["scope"], "openid profile offline_access User.Read Files.ReadWrite.All Sites.Read.All", "sign-in scopes")
        c.equal(q["login_hint"], "ana@contoso.com", "login_hint")
        c.equal(q["prompt"], "select_account", "prompt")
        c.equal(q["nonce"], "n-1", "nonce")
        c.expect(url.absoluteString.contains("state=st%2Bate"), "state is percent-encoded")
        c.expect(!url.absoluteString.contains(pkce.verifier), "verifier never appears in the browser URL")

        let gov = MicrosoftAuthConfiguration(clientID: "x", tenant: "contoso.onmicrosoft.us", cloud: .usGovernment)
        c.equal(gov.endpoint("token").absoluteString, "https://login.microsoftonline.us/contoso.onmicrosoft.us/oauth2/v2.0/token", "US Gov token endpoint")
        c.equal(MicrosoftAuthConfiguration(clientID: "x", tenant: "", cloud: .china).endpoint("devicecode").absoluteString,
                "https://login.chinacloudapi.cn/common/oauth2/v2.0/devicecode", "China device code endpoint, default tenant")
        c.equal(MicrosoftCloud.usGovernment.graphEndpoint.host, "graph.microsoft.us", "US Gov Graph")
        c.equal(MicrosoftCloud.china.powerBIEndpoint.host, "api.powerbi.cn", "China Power BI")
        c.expect(MicrosoftResource.graph.scopes(cloud: .usGovernment).contains("https://graph.microsoft.us/User.Read"), "national-cloud Graph scopes are qualified")

        c.equal(MicrosoftResource.powerBI.scopeString(cloud: .public), "https://analysis.windows.net/powerbi/api/.default", "Power BI scope")
        c.equal(MicrosoftResource.fabric.scopeString(cloud: .public), "https://api.fabric.microsoft.com/.default", "Fabric scope")
        c.equal(MicrosoftResource.storage.scopeString(cloud: .public), "https://storage.azure.com/.default", "Storage scope")
        c.equal(MicrosoftResource.dataverse(orgURL: "https://contoso.crm.dynamics.com/").scopeString(cloud: .public), "https://contoso.crm.dynamics.com/.default", "Dataverse scope")
        c.equal(MicrosoftResource.from(resourceString: "https://api.fabric.microsoft.com", cloud: .public), .fabric, "bare resource URL maps to Fabric")
        c.equal(MicrosoftResource.from(resourceString: "https://database.windows.net/", cloud: .public), .custom(scope: "https://database.windows.net/.default"), "bare URL gets /.default")
        c.equal(MicrosoftResource.from(resourceString: "https://analysis.windows.net/powerbi/api/.default", cloud: .public), .powerBI, "scope string maps to Power BI")
        c.expect(!MicrosoftResource.powerBI.supportsPersonalAccounts && MicrosoftResource.graph.supportsPersonalAccounts, "personal account support flags")

        let exchange = b.codeExchangeRequest(code: "C0DE", redirectURI: "http://localhost:53124", verifier: pkce.verifier)
        let ef = SelfCheckFixtures.formBody(exchange.httpBody ?? Data())
        c.equal(exchange.httpMethod, "POST", "token request is POST")
        c.equal(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded", "token content type")
        c.equal(ef["grant_type"], "authorization_code", "code grant")
        c.equal(ef["code_verifier"], pkce.verifier, "code_verifier sent to token endpoint")
        c.expect(ef["client_secret"] == nil, "public client sends no secret")

        let refresh = b.refreshRequest(refreshToken: "RT", scope: "https://analysis.windows.net/powerbi/api/.default", tenant: "tenant-guid")
        let rf = SelfCheckFixtures.formBody(refresh.httpBody ?? Data())
        c.equal(rf["grant_type"], "refresh_token", "refresh grant")
        c.equal(rf["scope"], "https://analysis.windows.net/powerbi/api/.default offline_access", "refresh scope adds offline_access")
        c.equal(refresh.url?.path, "/tenant-guid/oauth2/v2.0/token", "refresh pinned to home tenant")

        let poll = b.deviceCodePollRequest(deviceCode: "DC")
        c.equal(SelfCheckFixtures.formBody(poll.httpBody ?? Data())["grant_type"], "urn:ietf:params:oauth:grant-type:device_code", "device code grant")
        c.expect(MicrosoftAuthError.clientIDMissing.errorDescription?.contains("App registrations") == true
                 && MicrosoftAuthError.clientIDMissing.errorDescription?.contains("http://localhost") == true, "missing client ID explains registration")
    }

    static func checkTokenParsing(_ c: Checker) throws {
        let ok = try OAuthTokenResponse.parse(Data(#"{"token_type":"Bearer","scope":"User.Read","expires_in":3599,"access_token":"AT","refresh_token":"RT","id_token":"a.b.c"}"#.utf8), statusCode: 200)
        c.equal(ok.accessToken, "AT", "access token")
        c.equal(ok.refreshToken, "RT", "refresh token")
        c.equal(ok.expiresIn, 3599, "expires_in")
        let stringExpiry = try OAuthTokenResponse.parse(Data(#"{"access_token":"AT","expires_in":"1200"}"#.utf8), statusCode: 200)
        c.equal(stringExpiry.expiresIn, 1200, "string expires_in")

        func error(_ body: String) -> OAuthProtocolError? {
            do { _ = try OAuthTokenResponse.parse(Data(body.utf8), statusCode: 400); return nil }
            catch { return error as? OAuthProtocolError }
        }
        let grant = error(#"{"error":"invalid_grant","error_description":"AADSTS700082: The refresh token has expired due to inactivity.\r\nTrace ID: 1\r\nCorrelation ID: 2","error_codes":[700082],"correlation_id":"corr-1"}"#)
        c.equal(grant?.code, "invalid_grant", "invalid_grant code")
        c.equal(grant?.requiresInteraction, true, "invalid_grant requires interaction")
        c.equal(grant?.isConsentIssue, false, "expired token is not a consent issue")
        c.equal(grant?.description, "AADSTS700082: The refresh token has expired due to inactivity.", "description keeps first line only")
        c.equal(grant?.correlationID, "corr-1", "correlation id")
        let consent = error(#"{"error":"invalid_grant","error_description":"AADSTS65001: The user or administrator has not consented.","error_codes":[65001],"suberror":"consent_required"}"#)
        c.equal(consent?.isConsentIssue, true, "consent_required detected")
        c.equal(error(#"{"error":"interaction_required","error_description":"MFA"}"#)?.requiresInteraction, true, "interaction_required")
        c.equal(error(#"{"error":"invalid_client","error_description":"bad"}"#)?.requiresInteraction, false, "invalid_client is not interaction")
        c.expect((try? OAuthTokenResponse.parse(Data("<html>".utf8), statusCode: 502)) == nil, "non-JSON body rejected")
        c.expect((try? OAuthTokenResponse.parse(Data(#"{"token_type":"Bearer"}"#.utf8), statusCode: 200)) == nil, "missing access_token rejected")

        let device = try DeviceCodeResponse.parse(Data(#"{"user_code":"ABCD-EFGH","device_code":"DC","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5,"message":"To sign in, use a web browser…"}"#.utf8), statusCode: 200)
        c.equal(device.userCode, "ABCD-EFGH", "user code")
        c.equal(device.verificationURL.absoluteString, "https://microsoft.com/devicelogin", "verification URL")
        c.equal(device.interval, 5, "poll interval")

        func perr(_ code: String) -> OAuthProtocolError { OAuthProtocolError(code: code, description: "", subError: nil, correlationID: nil, errorCodes: []) }
        c.equal(DeviceCodePollOutcome.evaluate(error: perr("authorization_pending"), currentInterval: 5), .keepPolling(interval: 5), "authorization_pending keeps polling")
        c.equal(DeviceCodePollOutcome.evaluate(error: perr("slow_down"), currentInterval: 5), .keepPolling(interval: 10), "slow_down adds 5 seconds")
        c.equal(DeviceCodePollOutcome.evaluate(error: perr("authorization_declined"), currentInterval: 5), .fail(.userDeclined), "declined is terminal")
        c.equal(DeviceCodePollOutcome.evaluate(error: perr("expired_token"), currentInterval: 5), .fail(.deviceCodeExpired), "expired is terminal")
    }

    static func checkJWT(_ c: Checker) throws {
        let work = SelfCheckFixtures.jwt([
            "sub": "sub-1", "oid": "0A0B0C0D-1111-2222-3333-444444444444", "tid": "72F988BF-86F1-41AF-91AB-2D7CD011DB47",
            "name": "Ana Müller ✓", "preferred_username": "ana@contoso.com", "nonce": "N1", "exp": 1_900_000_000, "iss": "https://login.microsoftonline.com/x/v2.0",
        ])
        let claims = try IDTokenClaims.decode(jwt: work)
        c.equal(claims.name, "Ana Müller ✓", "name claim (UTF-8)")
        c.equal(claims.preferredUsername, "ana@contoso.com", "preferred_username")
        c.equal(claims.nonce, "N1", "nonce")
        c.equal(claims.accountID, "0a0b0c0d-1111-2222-3333-444444444444.72f988bf-86f1-41af-91ab-2d7cd011db47", "account id is oid.tid, lower-cased")
        c.equal(claims.isPersonalAccount, false, "work account")
        c.equal(claims.expiresAt, Date(timeIntervalSince1970: 1_900_000_000), "exp")
        let personal = try IDTokenClaims.decode(jwt: SelfCheckFixtures.jwt(["sub": "AAAA", "tid": "9188040d-6c67-4c5b-b112-36a304b66dad", "email": "p@outlook.com"]))
        c.equal(personal.isPersonalAccount, true, "personal tenant detected")
        c.equal(personal.accountID, "aaaa.9188040d-6c67-4c5b-b112-36a304b66dad", "personal account id falls back to sub")
        c.expect((try? IDTokenClaims.decode(jwt: "not-a-jwt")) == nil, "malformed JWT rejected")
        c.expect((try? IDTokenClaims.decode(jwt: "a.!!!.c")) == nil, "bad base64 rejected")
        c.expect((try? IDTokenClaims.decode(jwt: SelfCheckFixtures.jwt(["name": "No Subject"]))) == nil, "missing sub rejected")
    }

    static func checkRedirectEvaluation(_ c: Checker) {
        typealias L = LoopbackRedirectListener
        c.equal(L.evaluate(requestLine: "GET /?code=abc%2Fdef&state=S1 HTTP/1.1", expectedState: "S1"), .complete(.code("abc/def")), "valid redirect")
        func rejected(_ line: String, _ status: String) -> Bool {
            if case .reject(let s, _) = L.evaluate(requestLine: line, expectedState: "S1") { return s.hasPrefix(status) }
            return false
        }
        c.expect(rejected("GET /?code=abc&state=WRONG HTTP/1.1", "400"), "state mismatch rejected")
        c.expect(rejected("GET /?code=abc HTTP/1.1", "400"), "missing state rejected")
        c.expect(rejected("GET /favicon.ico HTTP/1.1", "404"), "unexpected path rejected")
        c.expect(rejected("GET /callback?code=abc&state=S1 HTTP/1.1", "404"), "other path with code rejected")
        c.expect(rejected("POST /?code=abc&state=S1 HTTP/1.1", "405"), "non-GET rejected")
        c.expect(rejected("GET / HTTP/1.1", "400"), "bare request rejected")
        c.expect(rejected("garbage", "400"), "malformed request rejected")
        c.equal(L.evaluate(requestLine: "GET /?error=access_denied&error_description=The+user+cancelled&state=S1 HTTP/1.1", expectedState: "S1"),
                .complete(.failure(.userDeclined)), "access_denied maps to userDeclined")
        c.equal(L.evaluate(requestLine: "GET /?error=server_error&error_description=Something+broke%21&state=S1 HTTP/1.1", expectedState: "S1"),
                .complete(.failure(.service(code: "server_error", description: "Something broke!", correlationID: nil))), "error with description")
        c.expect(SignInPages.success().contains("You're signed in") && SignInPages.success().contains("Return to \(AppIdentity.name)"), "success page copy")
        c.expect(!SignInPages.error(title: "<script>", detail: "<img onerror=x>").contains("<script>"), "error page escapes HTML")
    }

    static func checkLoopbackListener(_ c: Checker) async throws {
        let listener = LoopbackRedirectListener(expectedState: "state-123")
        let port = try await listener.start()
        c.expect(port > 0, "listener bound to an ephemeral port")
        c.equal(listener.redirectURI, "http://localhost:\(port)", "redirect URI")
        let session = URLSession(configuration: .ephemeral)
        func get(_ path: String) async throws -> (Int, String) {
            let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        c.equal(try await get("/other").0, 404, "unexpected path → 404")
        c.equal(try await get("/?code=evil&state=wrong").0, 400, "forged state → 400 and flow continues")
        async let waited: String = listener.waitForCode(timeout: 10)
        let (status, html) = try await get("/?code=the-code&state=state-123")
        c.equal(status, 200, "valid redirect → 200")
        c.expect(html.contains("You're signed in"), "success page served")
        c.equal(try await waited, "the-code", "code delivered to waiter")

        let timed = LoopbackRedirectListener(expectedState: "s")
        _ = try await timed.start()
        do { _ = try await timed.waitForCode(timeout: 0.2); c.fail("timeout did not fire") }
        catch { c.equal(error as? MicrosoftAuthError, .timedOut, "times out") }

        let cancelled = LoopbackRedirectListener(expectedState: "s")
        _ = try await cancelled.start()
        let task = Task { try await cancelled.waitForCode(timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; c.fail("cancellation did not stop the wait") }
        catch { c.equal(error as? MicrosoftAuthError, .cancelled, "cancellation") }
    }

    static func checkCredentialStores(_ c: Checker) throws {
        let mem = InMemorySecretStore()
        let store = DataSourceCredentialStore(store: mem)
        let cred = DataSourceCredential(kind: .usernamePassword, username: "sa", secret: "p@ss", properties: ["database": "Sales"])
        try store.save(cred, kind: "PostgreSQL", location: "DB.Example.com:5432/")
        c.equal(try store.credential(kind: "postgresql", location: "db.example.com:5432"), cred, "credential round trip, case/trailing-slash insensitive")
        c.equal(try store.storedSources().map(\.location), ["db.example.com:5432"], "stored sources listing")
        try store.save(.apiKey("K"), kind: "web", location: "https://api.example.com")
        c.equal(try mem.list().count, 2, "two entries")
        try store.remove(kind: "PostgreSQL", location: "db.example.com:5432")
        c.expect(try store.credential(kind: "postgresql", location: "db.example.com:5432") == nil, "removed")
        try store.removeAll()
        c.equal(try mem.list(), [], "removeAll")
    }

    static func checkKeychain(_ c: Checker) {
        let store = KeychainStore(service: "com.facet.selfcheck." + UUID().uuidString)
        do {
            try store.setString("first", account: "a")
            try store.setString("second", account: "a")
            c.equal(try store.getString(account: "a"), "second", "Keychain update in place")
            try store.set(Data([1, 2, 3]), account: "b")
            c.equal(try store.list(), ["a", "b"], "Keychain list")
            try store.delete(account: "a")
            c.expect(try store.get(account: "a") == nil, "Keychain delete")
            try store.delete(account: "missing")
            try store.removeAll()
            c.equal(try store.list(), [], "Keychain removeAll")
        } catch let e as KeychainError {
            try? store.removeAll()
            // -25308 interaction not allowed, -25307 no default keychain, -34018 missing entitlement, -25293 auth failed (locked/headless).
            if [-25308, -25307, -34018, -25293, -60008].contains(Int(e.status)) {
                c.skip("Keychain is not usable in this environment (\(e.localizedDescription))")
            } else {
                c.fail("Keychain error: \(e.localizedDescription)")
            }
        } catch {
            c.fail("Keychain error: \(error)")
        }
    }
}
