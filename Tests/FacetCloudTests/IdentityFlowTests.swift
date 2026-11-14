import XCTest
@testable import FacetCloud

/// The Microsoft sign-in flow, end to end, against `StubIdentityServer`. Nothing leaves this machine.
@MainActor
final class IdentityFlowTests: XCTestCase {
    private var server = StubIdentityServer()
    private var secrets = InMemorySecretStore()
    private var defaults = UserDefaults.standard
    private var suite = ""

    override func setUp() async throws {
        server = StubIdentityServer()
        server.install()
        secrets = InMemorySecretStore()
        (defaults, suite) = scratchDefaults()
    }

    override func tearDown() async throws {
        SelfCheckURLProtocol.handler = nil
        CloudLog.handler = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeManager(clientID: String = StubIdentityServer.clientID, tenant: String = "organizations") -> MicrosoftAccountManager {
        let m = MicrosoftAccountManager(configuration: MicrosoftAuthConfiguration(clientID: clientID, tenant: tenant),
                                        secrets: secrets, defaults: defaults,
                                        sessionConfiguration: SelfCheckURLProtocol.configuration(), openURL: server.browser())
        m.pollSleeper = { _ in }
        return m
    }

    private func refreshToken(_ accountID: String) throws -> String {
        try XCTUnwrap(try secrets.getString(account: "rt." + accountID))
    }

    func testSignInUsesPKCEAndStoresOnlyTheRefreshTokenInTheSecretStore() async throws {
        let log = LogCapture()
        log.start()
        let manager = makeManager()
        let account = try await manager.signIn()

        XCTAssertEqual(account.id, "oid-ana.tid-contoso")
        XCTAssertEqual(account.displayName, "Ana Müller")
        XCTAssertEqual(account.username, "ana@contoso.com")
        XCTAssertFalse(account.isPersonal)
        XCTAssertEqual(manager.activeAccount?.id, account.id)
        XCTAssertEqual(manager.signInState, .idle)

        // The browser was sent to the Microsoft authority with a loopback redirect, S256 PKCE, state and nonce.
        let q = try XCTUnwrap(server.authorizeQueries.first)
        XCTAssertEqual(q["_scheme"], "https")
        XCTAssertEqual(q["_host"], "login.microsoftonline.com")
        XCTAssertEqual(q["_path"], "/organizations/oauth2/v2.0/authorize")
        XCTAssertEqual(q["client_id"], StubIdentityServer.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertTrue(EndpointPolicy.isLoopbackRedirect(q["redirect_uri"] ?? ""), "redirect URI is http://localhost:<port>")
        XCTAssertGreaterThanOrEqual(q["state"]?.count ?? 0, 32)
        XCTAssertGreaterThanOrEqual(q["nonce"]?.count ?? 0, 32)
        // 32 random bytes → 43 base64url characters; the challenge is SHA-256 → also 43.
        XCTAssertEqual(q["code_challenge"]?.count, 43)
        let scopes = Set((q["scope"] ?? "").split(separator: " ").map(String.init))
        XCTAssertEqual(scopes, ["openid", "profile", "offline_access", "User.Read", "Files.ReadWrite.All", "Sites.Read.All"])

        // The server only issued tokens because the verifier matched the challenge (it rejects otherwise).
        XCTAssertEqual(server.rejectedExchanges, [])
        let form = try XCTUnwrap(server.tokenForms.first)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code_verifier"]?.count, 43)
        XCTAssertNil(form["client_secret"], "public client: no secret is ever sent")

        // Only the refresh token and the account record are persisted, and only in the secret store.
        let stored = try refreshToken(account.id)
        XCTAssertTrue(server.isCurrentRefreshToken(stored))
        XCTAssertEqual(try secrets.list().sorted(), ["accounts", "rt.oid-ana.tid-contoso"])
        let accessToken = try await manager.accessToken(for: .graph)
        XCTAssertEqual(server.tokenForms.count, 1, "the sign-in token is served from memory")
        let persisted = defaults.dictionaryRepresentation().description
        XCTAssertFalse(persisted.contains(stored))
        XCTAssertFalse(persisted.contains(accessToken))
        let record = String(decoding: try XCTUnwrap(try secrets.get(account: "accounts")), as: UTF8.self)
        XCTAssertFalse(record.contains(accessToken), "access tokens are never written anywhere")

        // Nothing secret reached the debug log.
        let lines = log.stop()
        XCTAssertFalse(lines.isEmpty)
        for secret in [stored, accessToken, form["code"] ?? "?", form["code_verifier"] ?? "?"] {
            XCTAssertFalse(lines.contains(secret), "a secret was logged")
        }
    }

    func testRefreshRotatesTheTokenAndExpiredTokensAreRenewed() async throws {
        let manager = makeManager()
        server.expiresIn = 3600
        let account = try await manager.signIn()
        let first = try refreshToken(account.id)
        let token1 = try await manager.accessToken(for: .graph)

        // A forced refresh redeems the stored refresh token against the account's home tenant and stores the rotated one.
        let token2 = try await manager.accessToken(for: .graph, forceRefresh: true)
        XCTAssertNotEqual(token1, token2)
        let second = try refreshToken(account.id)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(server.isCurrentRefreshToken(first))
        XCTAssertTrue(server.isCurrentRefreshToken(second))
        XCTAssertEqual(server.tokenForms.last?["grant_type"], "refresh_token")
        XCTAssertEqual(server.tokenForms.last?["client_id"], StubIdentityServer.clientID)

        // A token with less than the five-minute leeway left is not reused.
        server.expiresIn = 120
        let token3 = try await manager.accessToken(for: .graph, forceRefresh: true)
        let before = server.tokenForms.count
        let token4 = try await manager.accessToken(for: .graph)
        XCTAssertEqual(server.tokenForms.count, before + 1)
        XCTAssertNotEqual(token3, token4)

        // A different resource gets its own token with that resource's scope.
        server.expiresIn = 3600
        _ = try await manager.accessToken(for: .powerBI)
        XCTAssertEqual(server.tokenForms.last?["scope"], "https://analysis.windows.net/powerbi/api/.default offline_access")
    }

    func testRevokedRefreshTokenAsksTheUserToSignInAgain() async throws {
        let manager = makeManager()
        let account = try await manager.signIn()
        server.revokeAllRefreshTokens = true
        do {
            _ = try await manager.accessToken(for: .graph, forceRefresh: true)
            XCTFail("a revoked refresh token was accepted")
        } catch let error as MicrosoftAuthError {
            guard case .interactionRequired(let who, _) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(who, "ana@contoso.com")
        }
        XCTAssertEqual(manager.accounts.first { $0.id == account.id }?.needsSignIn, true)
    }

    func testForgedRedirectsNeitherCompleteNorAbortTheSignIn() async throws {
        // Another local process hits the listener first: wrong state, no state, wrong path, an OAuth error with a wrong state.
        server.forgedRedirects = ["/?code=attacker-code&state=guessed", "/?code=attacker-code", "/callback?code=x&state=y",
                                  "/?error=access_denied&state=guessed"]
        let manager = makeManager()
        let account = try await manager.signIn()
        XCTAssertEqual(account.username, "ana@contoso.com")
        XCTAssertEqual(server.forgedStatuses, [400, 400, 404, 400])
        XCTAssertEqual(server.tokenForms.count, 1)
        XCTAssertNotEqual(server.tokenForms.first?["code"], "attacker-code", "only the code that came with the right state is redeemed")
    }

    func testIDTokenForAnotherApplicationOrAuthorityIsRejected() async throws {
        let manager = makeManager()
        server.audienceOverride = "99999999-0000-0000-0000-000000000000"
        do { _ = try await manager.signIn(); XCTFail("wrong audience accepted") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .invalidIDToken("it was issued to a different application")) }

        server.audienceOverride = nil
        server.issuerOverride = "https://login.evil.example/tid-contoso/v2.0"
        do { _ = try await manager.signIn(); XCTFail("wrong issuer accepted") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .invalidIDToken("it was issued by an unexpected authority")) }

        server.issuerOverride = "https://login.microsoftonline.com/another-tenant/v2.0"
        do { _ = try await manager.signIn(); XCTFail("issuer for another tenant accepted") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .invalidIDToken("its issuer does not match its tenant")) }

        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertEqual(try secrets.list(), [], "a rejected sign-in stores nothing")
    }

    func testAccountSwitchingAndSignOut() async throws {
        let manager = makeManager()
        let ana = try await manager.signIn()
        server.user = .init(oid: "oid-ben", tid: "tid-fabrikam", name: "Ben", upn: "ben@fabrikam.com")
        let ben = try await manager.signIn()
        XCTAssertEqual(manager.accounts.map(\.username), ["ana@contoso.com", "ben@fabrikam.com"])
        XCTAssertEqual(manager.activeAccount?.id, ben.id, "the newest account becomes active")

        manager.setActive(ana)
        XCTAssertEqual(manager.activeAccount?.id, ana.id)
        let anaToken = try await manager.accessToken(for: .graph)
        let benToken = try await manager.accessToken(for: .graph, account: ben)
        XCTAssertTrue(anaToken.hasSuffix("oid-ana"))
        XCTAssertTrue(benToken.hasSuffix("oid-ben"))

        manager.signOut(ana)
        XCTAssertEqual(manager.accounts.map(\.id), [ben.id])
        XCTAssertEqual(manager.activeAccount?.id, ben.id)
        XCTAssertNil(try secrets.getString(account: "rt." + ana.id), "signing out deletes the refresh token")
        do { _ = try await manager.accessToken(for: .graph, account: ana); XCTFail("token issued for a signed-out account") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .accountNotFound) }

        // A new manager (next launch) restores the remaining account from the secret store and can refresh silently.
        let relaunched = makeManager()
        XCTAssertEqual(relaunched.accounts.map(\.id), [ben.id])
        let silent = try await relaunched.accessToken(for: .graph)
        XCTAssertTrue(silent.hasSuffix("oid-ben"))

        relaunched.removeAll()
        XCTAssertEqual(try secrets.list(), [])
        do { _ = try await relaunched.accessToken(for: .graph); XCTFail("token issued with no account") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .noActiveAccount) }
    }

    func testDeviceCodeFlowPollsUntilTheUserFinishes() async throws {
        let manager = makeManager()
        var waits: [TimeInterval] = []
        var prompts: [DeviceCodePrompt] = []
        manager.pollSleeper = { interval in
            waits.append(interval)
            if case .deviceCode(let p) = manager.signInState { prompts.append(p) }
        }
        let account = try await manager.startDeviceCodeSignIn()
        XCTAssertEqual(account.username, "ana@contoso.com")
        XCTAssertEqual(prompts.first?.userCode, "ABCD-EFGH")
        XCTAssertEqual(prompts.first?.verificationURL.absoluteString, "https://microsoft.com/devicelogin")
        // interval 5 s; `slow_down` on the first poll adds 5 s (RFC 8628 §3.5); then pending; then success.
        XCTAssertEqual(waits, [5, 10, 10])
        XCTAssertTrue(server.isCurrentRefreshToken(try refreshToken(account.id)))
    }

    func testDeviceCodePageOutsideMicrosoftIsRefused() async throws {
        server.deviceVerificationURI = "https://login.evil.example/device"
        let manager = makeManager()
        do { _ = try await manager.startDeviceCodeSignIn(); XCTFail("an untrusted device sign-in page was accepted") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .invalidResponse("the device sign-in address is not a Microsoft page")) }
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testOversizedTokenResponseIsNotRead() async throws {
        server.oversizedTokenResponse = true
        let manager = makeManager()
        do { _ = try await manager.signIn(); XCTFail("a 2 MB token response was accepted") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .invalidResponse("the response was too large")) }
    }

    func testMissingClientIDExplainsTheRegistration() async throws {
        let manager = makeManager(clientID: "  ")
        do { _ = try await manager.signIn(); XCTFail("sign-in started without a client id") }
        catch {
            XCTAssertEqual(error as? MicrosoftAuthError, .clientIDMissing)
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            for needle in ["http://localhost", "Allow public client flows", "User.Read", "Files.ReadWrite.All", "Sites.Read.All",
                           "offline_access", "Power BI Service"] {
                XCTAssertTrue(text.contains(needle), "registration instructions do not mention \(needle)")
            }
        }
        XCTAssertTrue(server.authorizeQueries.isEmpty, "the browser was not opened")
        XCTAssertTrue(server.requestedHosts.isEmpty)
    }

    func testIdentityCallsOnlyReachTheAuthority() async throws {
        let manager = makeManager()
        _ = try await manager.signIn()
        _ = try await manager.accessToken(for: .graph, forceRefresh: true)
        XCTAssertTrue(server.requestedHosts.subtracting(["login.microsoftonline.com", "graph.microsoft.com"]).isEmpty,
                      "unexpected hosts: \(server.requestedHosts)")
    }
}

/// The loopback listener on its own.
final class LoopbackListenerSecurityTests: XCTestCase {
    private func status(_ url: String) async -> Int {
        guard let u = URL(string: url) else { return -1 }
        return ((try? await URLSession(configuration: .ephemeral).data(from: u))?.1 as? HTTPURLResponse)?.statusCode ?? 0
    }

    func testListensOnIPv4LoopbackOnlyAndClosesAfterTheValidRedirect() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected-state")
        let port = try await listener.start()
        XCTAssertEqual(listener.redirectURI, "http://localhost:\(port)")
        let overIPv6 = await status("http://[::1]:\(port)/?code=c&state=expected-state")
        XCTAssertEqual(overIPv6, 0, "nothing listens on ::1")
        async let code = listener.waitForCode(timeout: 10)
        let ok = await status("http://127.0.0.1:\(port)/?code=the-code&state=expected-state")
        XCTAssertEqual(ok, 200)
        let delivered = try await code
        XCTAssertEqual(delivered, "the-code")
        try await Task.sleep(nanoseconds: 700_000_000)
        let replay = await status("http://127.0.0.1:\(port)/?code=second&state=expected-state")
        XCTAssertEqual(replay, 0, "the listener is closed after one accepted redirect")
    }

    func testGivesUpAfterTooManyUnexpectedRequests() async throws {
        let listener = LoopbackRedirectListener(expectedState: "expected-state")
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCode(timeout: 20) }
        for _ in 0..<LoopbackRedirectListener.maxRejectedRequests {
            _ = await status("http://127.0.0.1:\(port)/?code=guess&state=wrong")
        }
        do { _ = try await waiter.value; XCTFail("the listener kept waiting") }
        catch { XCTAssertEqual(error as? MicrosoftAuthError, .listenerFailed("too many unexpected requests reached the sign-in listener")) }
    }

    func testRedirectEvaluationRejectsEverythingButTheSignInResponse() {
        func eval(_ line: String) -> LoopbackRedirectListener.Evaluation {
            LoopbackRedirectListener.evaluate(requestLine: line, expectedState: "S")
        }
        XCTAssertEqual(eval("GET /?code=abc&state=S HTTP/1.1"), .complete(.code("abc")))
        XCTAssertEqual(eval("GET /?error=access_denied&state=S HTTP/1.1"), .complete(.failure(.userDeclined)))
        for bad in ["POST /?code=abc&state=S HTTP/1.1", "GET /x?code=abc&state=S HTTP/1.1", "GET /?code=abc&state=s HTTP/1.1",
                    "GET /?code=abc HTTP/1.1", "GET /?state=S HTTP/1.1", "GET /?code=&state=S HTTP/1.1", "GET / HTTP/1.1", "garbage"] {
            guard case .reject = eval(bad) else { return XCTFail("accepted: \(bad)") }
        }
    }
}
