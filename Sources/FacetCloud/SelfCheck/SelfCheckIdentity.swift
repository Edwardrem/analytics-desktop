import Foundation
import Combine

extension FacetCloudSelfCheck {
    private static func scratchDefaults() -> (UserDefaults, String) {
        let suite = "com.facet.selfcheck." + UUID().uuidString
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    private static let personalTenant = IDTokenClaims.personalTenantID

    @MainActor
    static func checkTokenRefresh(_ c: Checker) async throws {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let work = MicrosoftAccount(id: "oid-1.tid-work", displayName: "Ana", username: "ana@contoso.com", tenantID: "tid-work", isPersonal: false)
        let personal = MicrosoftAccount(id: "sub-9.\(personalTenant)", displayName: "Pat", username: "pat@outlook.com", tenantID: personalTenant, isPersonal: true)
        try secrets.setCodable([work, personal], account: "accounts")
        try secrets.setString("RT-1", account: "rt." + work.id)
        try secrets.setString("RT-P", account: "rt." + personal.id)
        let manager = MicrosoftAccountManager(configuration: MicrosoftAuthConfiguration(clientID: "client-1", tenant: "common"), secrets: secrets, defaults: defaults,
                                              sessionConfiguration: SelfCheckURLProtocol.configuration(), openURL: { _ in false })
        c.equal(manager.accounts.map(\.id), [work.id, personal.id], "accounts restored from secret store")
        c.equal(manager.activeAccount?.id, work.id, "first account is active by default")

        let calls = Recorder<[[String: String]]>([])
        let mode = Recorder("ok")
        SelfCheckURLProtocol.handler = { req, body in
            guard let path = req.url?.path, path.hasSuffix("/oauth2/v2.0/token") else { return .json("{}", status: 404) }
            var form = SelfCheckFixtures.formBody(body)
            form["_path"] = path
            calls.update { $0.append(form) }
            let n = calls.value.count
            Thread.sleep(forTimeInterval: 0.05) // keep the request in flight so concurrent callers overlap
            switch mode.value {
            case "short": return .json(#"{"access_token":"AT-\#(n)","expires_in":120,"token_type":"Bearer"}"#)
            case "invalid_grant": return .json(#"{"error":"invalid_grant","error_description":"AADSTS50173: The provided grant has expired due to it being revoked.","error_codes":[50173]}"#, status: 400)
            case "consent": return .json(#"{"error":"invalid_grant","error_description":"AADSTS65001: The user or administrator has not consented to use the application.","error_codes":[65001],"suberror":"consent_required"}"#, status: 400)
            default: return .json(#"{"access_token":"AT-\#(n)","expires_in":3600,"refresh_token":"RT-\#(n + 1)","token_type":"Bearer"}"#)
            }
        }

        // Single flight: five concurrent callers share one refresh.
        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<5 { group.addTask { try await manager.accessToken(for: .powerBI) } }
            var out: [String] = []
            for try await t in group { out.append(t) }
            return out
        }
        c.equal(tokens, Array(repeating: "AT-1", count: 5), "concurrent callers get the same token")
        c.equal(calls.value.count, 1, "single-flight: one token request for five callers")
        let first = calls.value.first ?? [:]
        c.equal(first["grant_type"], "refresh_token", "refresh grant used")
        c.equal(first["refresh_token"], "RT-1", "stored refresh token redeemed")
        c.equal(first["scope"], "https://analysis.windows.net/powerbi/api/.default offline_access", "Power BI scope requested")
        c.equal(first["client_id"], "client-1", "client id sent")
        c.equal(first["_path"], "/tid-work/oauth2/v2.0/token", "work account refreshes against its home tenant")
        c.equal(try secrets.getString(account: "rt." + work.id), "RT-2", "rotated refresh token stored")

        _ = try await manager.accessToken(for: .powerBI)
        c.equal(calls.value.count, 1, "cached token reused")
        c.equal(try await manager.accessToken(resource: "https://analysis.windows.net/powerbi/api"), "AT-1", "AccessTokenProviding maps a bare resource URL to the cached token")
        c.equal(try await manager.accessToken(for: .graph), "AT-2", "each resource has its own token")
        c.equal(calls.value.last?["refresh_token"], "RT-2", "rotated refresh token used next")
        c.equal(calls.value.last?["scope"], "User.Read Files.ReadWrite.All Sites.Read.All offline_access", "Graph scopes")
        c.equal(try await manager.accessToken(for: .powerBI, forceRefresh: true), "AT-3", "forceRefresh bypasses the cache")

        mode.update { $0 = "short" }
        _ = try await manager.accessToken(for: .fabric)
        _ = try await manager.accessToken(for: .fabric)
        c.equal(calls.value.count, 5, "token with under five minutes left is refreshed, not reused")

        mode.update { $0 = "consent" }
        do { _ = try await manager.accessToken(for: .storage); c.fail("consent error not thrown") }
        catch let e as MicrosoftAuthError {
            if case .consentRequired = e { c.expect(manager.accounts.first?.needsSignIn == false, "missing consent does not flag the account") }
            else { c.fail("expected consentRequired, got \(e)") }
        }

        mode.update { $0 = "invalid_grant" }
        do { _ = try await manager.accessToken(for: .custom(scope: "api://facet-test/.default")); c.fail("invalid_grant not thrown") }
        catch let e as MicrosoftAuthError {
            if case .interactionRequired(let account, let detail) = e {
                c.expect(account == "ana@contoso.com" && detail.contains("AADSTS50173"), "typed interactionRequired error with detail")
            } else { c.fail("expected interactionRequired, got \(e)") }
        }
        c.equal(manager.accounts.first?.needsSignIn, true, "account flipped to needs sign-in")
        c.equal((try secrets.getCodable([MicrosoftAccount].self, account: "accounts"))?.first?.needsSignIn, true, "needs-sign-in state persisted")

        mode.update { $0 = "ok" }
        _ = try await manager.accessToken(for: .dataverse(orgURL: "https://contoso.crm.dynamics.com"))
        c.equal(calls.value.last?["scope"], "https://contoso.crm.dynamics.com/.default offline_access", "Dataverse scope")
        c.equal(manager.accounts.first?.needsSignIn, false, "successful refresh clears needs sign-in")

        let before = calls.value.count
        do { _ = try await manager.accessToken(for: .powerBI, account: personal); c.fail("personal Power BI not rejected") }
        catch let e as MicrosoftAuthError {
            c.equal(e, .personalAccountUnsupported(resource: "Power BI"), "personal accounts get a clear Power BI error")
            c.expect(e.errorDescription?.contains("work or school") == true, "error explains the account type")
        }
        c.equal(calls.value.count, before, "no network call for an unsupported personal-account resource")
        _ = try await manager.accessToken(for: .graph, account: personal)
        c.equal(calls.value.last?["_path"], "/common/oauth2/v2.0/token", "personal account refreshes against the configured tenant")
        c.equal(calls.value.last?["refresh_token"], "RT-P", "per-account refresh tokens")

        manager.signOut(work)
        c.expect(try secrets.get(account: "rt." + work.id) == nil, "sign-out removes the refresh token")
        c.equal(manager.accounts.map(\.id), [personal.id], "sign-out removes the account")
        c.equal(manager.activeAccount?.id, personal.id, "active account moves on")
        do { _ = try await manager.accessToken(for: .graph, account: work); c.fail("signed-out account still usable") }
        catch { c.equal(error as? MicrosoftAuthError, .accountNotFound, "signed-out account is rejected") }
        manager.removeAll()
        c.equal(try secrets.list(), [], "removeAll clears every stored item")
        do { _ = try await manager.accessToken(for: .graph); c.fail("no account not reported") }
        catch { c.equal(error as? MicrosoftAuthError, .noActiveAccount, "no active account") }

        let empty = MicrosoftAccountManager(configuration: MicrosoftAuthConfiguration(), secrets: InMemorySecretStore(), defaults: defaults,
                                            sessionConfiguration: SelfCheckURLProtocol.configuration(), openURL: { _ in true })
        do { _ = try await empty.signIn(); c.fail("missing client ID not reported") }
        catch { c.equal(error as? MicrosoftAuthError, .clientIDMissing, "sign-in without a client ID throws clientIDMissing") }
        if case .failed(let message) = empty.signInState { c.expect(message.contains("Entra admin center"), "state explains how to register an app") }
        else { c.fail("signInState not failed") }
    }

    @MainActor
    static func checkInteractiveSignIn(_ c: Checker) async throws {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let seen = Recorder<[String: String]>([:])
        let behaviour = Recorder("redirect")
        let manager = MicrosoftAccountManager(
            configuration: MicrosoftAuthConfiguration(clientID: "client-1", tenant: "organizations"), secrets: secrets, defaults: defaults,
            sessionConfiguration: SelfCheckURLProtocol.configuration(),
            openURL: { url in
                // Plays the role of the browser + Microsoft: reads the authorize URL and calls the loopback redirect.
                let q = LoopbackRedirectListener.parseQuery(url.absoluteString)
                seen.update { $0 = q; $0["_host"] = url.host; $0["_path"] = url.path }
                guard behaviour.value != "fail-open" else { return false }
                guard behaviour.value != "never-redirect", let redirect = q["redirect_uri"], let state = q["state"] else { return true }
                Task.detached {
                    guard let u = URL(string: "\(redirect)/?code=auth-code-1&state=\(state)") else { return }
                    _ = try? await URLSession(configuration: .ephemeral).data(from: u)
                }
                return true
            })
        let exchanges = Recorder<[[String: String]]>([])
        SelfCheckURLProtocol.handler = { req, body in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/oauth2/v2.0/token") {
                let form = SelfCheckFixtures.formBody(body)
                exchanges.update { $0.append(form) }
                let nonce = behaviour.value == "bad-nonce" ? "someone-elses-nonce" : (seen.value["nonce"] ?? "")
                let id = SelfCheckFixtures.jwt(["sub": "sub-1", "oid": "OID-1", "tid": "TID-1", "name": "Ana Müller", "preferred_username": "ana@contoso.com", "nonce": .string(nonce),
                                                "aud": "client-1", "iss": "https://login.microsoftonline.com/TID-1/v2.0"])
                return .json(#"{"token_type":"Bearer","expires_in":3600,"access_token":"AT-signin","refresh_token":"RT-signin","id_token":"\#(id)"}"#)
            }
            if path.hasSuffix("/me/photo/$value") { return SelfCheckURLProtocol.Response(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF])) }
            return .json("{}", status: 404)
        }

        let account = try await manager.signIn()
        c.equal(account.id, "oid-1.tid-1", "account id from oid + tid")
        c.equal(account.displayName, "Ana Müller", "display name from ID token")
        c.equal(account.username, "ana@contoso.com", "username from ID token")
        c.equal(account.isPersonal, false, "work account")
        c.equal(seen.value["_host"], "login.microsoftonline.com", "browser opened at the authority")
        c.equal(seen.value["_path"], "/organizations/oauth2/v2.0/authorize", "tenant used in authorize URL")
        c.expect(seen.value["redirect_uri"]?.hasPrefix("http://localhost:") == true, "loopback redirect URI with ephemeral port")
        let form = exchanges.value.first ?? [:]
        c.equal(form["code"], "auth-code-1", "authorization code redeemed")
        c.equal(form["redirect_uri"], seen.value["redirect_uri"], "same redirect URI at the token endpoint")
        c.equal(PKCEPair(verifier: form["code_verifier"] ?? "").challenge, seen.value["code_challenge"], "PKCE verifier matches the challenge sent to the browser")
        c.equal(try secrets.getString(account: "rt.oid-1.tid-1"), "RT-signin", "refresh token stored in the secret store")
        c.equal(manager.activeAccount?.id, account.id, "new account becomes active")
        c.equal(manager.signInState, .idle, "state returns to idle")
        c.equal(try await manager.accessToken(for: .graph), "AT-signin", "Graph token from sign-in is cached")
        c.equal(exchanges.value.count, 1, "no extra token request after sign-in")
        let storedDefaults = defaults.dictionaryRepresentation().description
        c.expect(!storedDefaults.contains("RT-signin") && !storedDefaults.contains("AT-signin"), "no tokens in UserDefaults")
        for _ in 0..<50 where manager.accounts.first?.avatar == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        c.equal(manager.accounts.first?.avatar, Data([0xFF, 0xD8, 0xFF]), "avatar fetched from Graph")

        behaviour.update { $0 = "bad-nonce" }
        do { _ = try await manager.signIn(); c.fail("nonce mismatch not detected") }
        catch { c.equal(error as? MicrosoftAuthError, .nonceMismatch, "ID token with the wrong nonce is rejected") }
        c.equal(manager.accounts.count, 1, "rejected sign-in adds no account")

        behaviour.update { $0 = "fail-open" }
        do { _ = try await manager.signIn(); c.fail("browser failure not reported") }
        catch { c.equal(error as? MicrosoftAuthError, .browserFailed, "browser failure reported") }

        behaviour.update { $0 = "never-redirect" }
        let pending = Task { @MainActor in try await manager.signIn() }
        for _ in 0..<100 where manager.signInState != .waitingForBrowser { try await Task.sleep(nanoseconds: 10_000_000) }
        c.equal(manager.signInState, .waitingForBrowser, "state shows waiting for the browser")
        do { _ = try await manager.signIn(); c.fail("second sign-in allowed") }
        catch { c.equal(error as? MicrosoftAuthError, .signInAlreadyInProgress, "concurrent sign-in rejected") }
        manager.cancelSignIn()
        do { _ = try await pending.value; c.fail("cancel did not stop sign-in") }
        catch { c.equal(error as? MicrosoftAuthError, .cancelled, "cancelSignIn cancels the flow") }
        c.equal(manager.signInState, .idle, "cancelled sign-in returns to idle")
    }

    @MainActor
    static func checkDeviceCodeSignIn(_ c: Checker) async throws {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MicrosoftAccountManager(configuration: MicrosoftAuthConfiguration(clientID: "client-1"), secrets: InMemorySecretStore(),
                                              defaults: defaults, sessionConfiguration: SelfCheckURLProtocol.configuration(), openURL: { _ in false })
        let sleeps = Recorder<[TimeInterval]>([])
        manager.pollSleeper = { s in sleeps.update { $0.append(s) } }
        let script = Recorder<[String]>(["authorization_pending", "slow_down", "authorization_pending", "ok"])
        SelfCheckURLProtocol.handler = { req, body in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/devicecode") {
                return .json(#"{"user_code":"ABCD-EFGH","device_code":"DEVICE-1","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5,"message":"Enter the code"}"#)
            }
            if path.hasSuffix("/token") {
                guard SelfCheckFixtures.formBody(body)["device_code"] == "DEVICE-1" else { return .json(#"{"error":"bad_verification_code"}"#, status: 400) }
                var step = "ok"
                script.update { if !$0.isEmpty { step = $0.removeFirst() } }
                if step != "ok" { return .json(#"{"error":"\#(step)","error_description":"\#(step)"}"#, status: 400) }
                let id = SelfCheckFixtures.jwt(["sub": "SUB-P", "tid": .string(IDTokenClaims.personalTenantID), "name": "Pat", "email": "pat@outlook.com",
                                                "aud": "client-1", "iss": .string("https://login.microsoftonline.com/" + IDTokenClaims.personalTenantID + "/v2.0")])
                return .json(#"{"expires_in":3600,"access_token":"AT-dc","refresh_token":"RT-dc","id_token":"\#(id)"}"#)
            }
            return .json("{}", status: 404)
        }
        var states: [MicrosoftSignInState] = []
        let sub = manager.$signInState.sink { states.append($0) }
        let account = try await manager.startDeviceCodeSignIn()
        sub.cancel()
        c.equal(account.isPersonal, true, "personal account recognised")
        c.equal(account.username, "pat@outlook.com", "email claim used as username")
        c.equal(sleeps.value, [5, 5, 10, 10], "polling honours interval; slow_down adds five seconds")
        let prompt = states.compactMap { s -> DeviceCodePrompt? in if case .deviceCode(let p) = s { return p }; return nil }.first
        c.equal(prompt?.userCode, "ABCD-EFGH", "user code published")
        c.equal(prompt?.verificationURL.absoluteString, "https://microsoft.com/devicelogin", "verification URL published")

        script.update { $0 = ["authorization_pending", "authorization_declined"] }
        do { _ = try await manager.startDeviceCodeSignIn(); c.fail("declined not reported") }
        catch { c.equal(error as? MicrosoftAuthError, .userDeclined, "declined device code") }
        script.update { $0 = ["expired_token"] }
        do { _ = try await manager.startDeviceCodeSignIn(); c.fail("expiry not reported") }
        catch { c.equal(error as? MicrosoftAuthError, .deviceCodeExpired, "expired device code") }
    }
}
