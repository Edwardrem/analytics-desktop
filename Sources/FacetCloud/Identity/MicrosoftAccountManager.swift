import Foundation
import FacetCore
import AppKit
import Combine

/// A Microsoft account signed in to Facet.
public struct MicrosoftAccount: Identifiable, Codable, Equatable, Sendable {
    /// `<oid or sub>.<tid>`, lower-cased.
    public let id: String
    public var displayName: String
    /// Sign-in name (UPN or email).
    public var username: String
    public var tenantID: String
    /// True for consumer accounts (outlook.com, hotmail.com, live.com…).
    public var isPersonal: Bool
    /// True when the stored refresh token no longer works and the user must sign in again.
    public var needsSignIn: Bool = false
    /// Profile photo bytes (JPEG/PNG) from Graph, when available. Held in memory only.
    public var avatar: Data?

    private enum CodingKeys: String, CodingKey { case id, displayName, username, tenantID, isPersonal, needsSignIn }

    public init(id: String, displayName: String, username: String, tenantID: String, isPersonal: Bool) {
        self.id = id; self.displayName = displayName; self.username = username; self.tenantID = tenantID; self.isPersonal = isPersonal
    }
}

/// Progress of an interactive sign-in, for the UI.
public enum MicrosoftSignInState: Equatable {
    case idle
    /// The system browser is open; waiting for the user to finish there.
    case waitingForBrowser
    /// Device-code flow: show the code and the URL.
    case deviceCode(DeviceCodePrompt)
    /// Exchanging the authorization code for tokens.
    case redeeming
    case failed(String)
}

/// Signs users in with the Microsoft identity platform (Entra ID work/school and personal accounts) and
/// issues access tokens for Microsoft Graph, Power BI, Fabric, OneLake, Dataverse and arbitrary resources.
///
/// Implements OAuth 2.0 authorization-code + PKCE with a loopback redirect, and the device-code flow,
/// directly on `URLSession` (no MSAL). Refresh tokens and account records live in the Keychain
/// (service `AppIdentity.keychainService("microsoft")`); access tokens are held in memory only. Nothing secret is logged.
@MainActor
public final class MicrosoftAccountManager: ObservableObject, RefreshableAccessTokenProviding {
    public nonisolated static let keychainService = AppIdentity.keychainService("microsoft")
    private static let accountsKey = "accounts"
    private static let activeAccountDefaultsKey = "com.facet.microsoft.activeAccountID"
    /// Tokens are refreshed this long before they expire.
    public static let refreshLeeway: TimeInterval = 300

    @Published public private(set) var accounts: [MicrosoftAccount] = []
    @Published public var activeAccountID: String? {
        didSet { defaults.set(activeAccountID, forKey: Self.activeAccountDefaultsKey) }
    }
    @Published public private(set) var signInState: MicrosoftSignInState = .idle
    /// Changing the configuration persists it to `UserDefaults`.
    @Published public var configuration: MicrosoftAuthConfiguration {
        didSet { if configuration != oldValue { configuration.save(to: defaults) } }
    }

    public var activeAccount: MicrosoftAccount? {
        accounts.first { $0.id == activeAccountID } ?? accounts.first
    }

    private let secrets: SecretStoring
    private let defaults: UserDefaults
    private let authSession: URLSession
    private let openURL: (URL) -> Bool

    private struct CachedToken { let token: String; let expiresAt: Date }
    private var tokenCache: [String: CachedToken] = [:]
    private var inflight: [String: Task<String, Error>] = [:]
    private var signInTask: Task<MicrosoftAccount, Error>?
    /// Interactive consent sign-ins in progress, per scope.
    private var consentTasks: [String: Task<Void, Error>] = [:]
    /// Waits between device-code polls; replaceable so the self-check does not wait in real time.
    var pollSleeper: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    /// - Parameters:
    ///   - secrets: where refresh tokens and account records are stored (Keychain by default).
    ///   - sessionConfiguration: URL session configuration for identity calls; ephemeral (no cookies, no cache) by default.
    ///   - openURL: opens the system browser; defaults to `NSWorkspace.shared.open`.
    public init(configuration: MicrosoftAuthConfiguration? = nil,
                secrets: SecretStoring = KeychainStore(service: MicrosoftAccountManager.keychainService),
                defaults: UserDefaults = .standard,
                sessionConfiguration: URLSessionConfiguration? = nil,
                openURL: ((URL) -> Bool)? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        self.configuration = configuration ?? MicrosoftAuthConfiguration.load(from: defaults)
        let cfg = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 120
            c.httpCookieStorage = nil
            c.urlCache = nil
            return c
        }()
        self.authSession = URLSession(configuration: cfg, delegate: RedirectGuard(followRedirects: false), delegateQueue: nil)
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        self.accounts = ((try? secrets.getCodable([MicrosoftAccount].self, account: Self.accountsKey)) ?? nil) ?? []
        let storedActive = defaults.string(forKey: Self.activeAccountDefaultsKey)
        self.activeAccountID = accounts.contains { $0.id == storedActive } ? storedActive : accounts.first?.id
    }

    // MARK: - Interactive sign-in

    /// Signs in through the system browser (authorization code + PKCE, loopback redirect).
    ///
    /// - Parameters:
    ///   - loginHint: pre-fills the account name (used when re-authenticating an existing account).
    ///   - resource: the resource whose scopes are consented to during this sign-in. Use `.graph` (default) to add
    ///     an account; pass e.g. `.powerBI` to obtain consent for another resource after a consent error.
    /// - Throws: `MicrosoftAuthError` — `.clientIDMissing` (with registration instructions) when no client ID is set,
    ///   `.timedOut` after 5 minutes, `.cancelled` when the task is cancelled or `cancelSignIn()` is called.
    @discardableResult
    public func signIn(loginHint: String? = nil, resource: MicrosoftResource = .graph) async throws -> MicrosoftAccount {
        try await runSignIn { [self] in
            let builder = OAuthRequestBuilder(configuration: configuration)
            let state = OAuthRandom.urlSafeToken(byteCount: 24)
            let nonce = OAuthRandom.urlSafeToken(byteCount: 24)
            let pkce = PKCEPair.generate()
            let listener = LoopbackRedirectListener(expectedState: state)
            try await listener.start()
            defer { listener.stop() }
            let redirect = listener.redirectURI
            guard EndpointPolicy.isLoopbackRedirect(redirect) else { throw MicrosoftAuthError.listenerFailed("the redirect address is not a loopback address") }
            let scopes = builder.signInScopes(for: resource)
            let url = builder.authorizationURL(redirectURI: redirect, state: state, nonce: nonce, pkce: pkce,
                                               loginHint: loginHint, scopes: scopes)
            guard policy.allowsSignInPage(url) else { throw MicrosoftAuthError.invalidResponse("the sign-in address is not a Microsoft sign-in page") }
            signInState = .waitingForBrowser
            guard openURL(url) else { throw MicrosoftAuthError.browserFailed }
            let code = try await listener.waitForCode(timeout: 300)
            signInState = .redeeming
            let response = try await tokenCall(builder.codeExchangeRequest(code: code, redirectURI: redirect,
                                                                           verifier: pkce.verifier, scopes: scopes))
            return try completeSignIn(response, expectedNonce: nonce, resource: resource)
        }
    }

    /// Signs in with the device-code flow (fallback when a browser redirect is not possible).
    /// Publishes `.deviceCode(prompt)` in `signInState` with the user code and verification URL, then polls
    /// until the user completes sign-in, declines, the code expires, or the sign-in is cancelled.
    @discardableResult
    public func startDeviceCodeSignIn() async throws -> MicrosoftAccount {
        try await runSignIn { [self] in
            let builder = OAuthRequestBuilder(configuration: configuration)
            let device = try await deviceCodeCall(builder.deviceCodeRequest())
            guard policy.allowsSignInPage(device.verificationURL) else {
                throw MicrosoftAuthError.invalidResponse("the device sign-in address is not a Microsoft page")
            }
            let expiresAt = Date().addingTimeInterval(device.expiresIn)
            signInState = .deviceCode(DeviceCodePrompt(userCode: device.userCode, verificationURL: device.verificationURL,
                                                       expiresAt: expiresAt, message: device.message))
            var interval = device.interval
            while Date() < expiresAt {
                try await pollSleeper(interval)
                do {
                    let response = try await tokenCall(builder.deviceCodePollRequest(deviceCode: device.deviceCode))
                    signInState = .redeeming
                    return try completeSignIn(response, expectedNonce: nil, resource: .graph)
                } catch let e as OAuthProtocolError {
                    switch DeviceCodePollOutcome.evaluate(error: e, currentInterval: interval) {
                    case .keepPolling(let next): interval = next
                    case .fail(let err): throw err
                    }
                }
            }
            throw MicrosoftAuthError.deviceCodeExpired
        }
    }

    /// Cancels a sign-in in progress (either flow). The pending `signIn()` call throws `.cancelled`.
    public func cancelSignIn() {
        signInTask?.cancel()
    }

    private func runSignIn(_ operation: @escaping @MainActor () async throws -> MicrosoftAccount) async throws -> MicrosoftAccount {
        guard configuration.isConfigured else {
            signInState = .failed(MicrosoftAuthError.clientIDMissing.errorDescription ?? "")
            throw MicrosoftAuthError.clientIDMissing
        }
        guard signInTask == nil else { throw MicrosoftAuthError.signInAlreadyInProgress }
        let task = Task { @MainActor in try await operation() }
        signInTask = task
        defer { signInTask = nil }
        do {
            let account = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            signInState = .idle
            return account
        } catch {
            let mapped = Self.mapSignInError(error)
            signInState = mapped == .cancelled ? .idle : .failed(mapped.errorDescription ?? "Sign-in failed.")
            throw mapped
        }
    }

    private static func mapSignInError(_ error: Error) -> MicrosoftAuthError {
        if let e = error as? MicrosoftAuthError { return e }
        if error is CancellationError { return .cancelled }
        if let e = error as? OAuthProtocolError { return e.asAuthError }
        if let e = error as? URLError { return e.code == .cancelled ? .cancelled : .network(e.localizedDescription) }
        return .invalidResponse(error.localizedDescription)
    }

    private func completeSignIn(_ response: OAuthTokenResponse, expectedNonce: String?, resource: MicrosoftResource) throws -> MicrosoftAccount {
        guard let idToken = response.idToken else { throw MicrosoftAuthError.invalidResponse("no ID token was returned") }
        let claims = try IDTokenClaims.decode(jwt: idToken)
        try claims.validate(clientID: configuration.effectiveClientID,
                            authorityHost: configuration.cloud.authorityHost.host)
        if let expectedNonce {
            guard let nonce = claims.nonce, HTTPHelpers.constantTimeEquals(nonce, expectedNonce) else {
                throw MicrosoftAuthError.nonceMismatch
            }
        }
        guard let refresh = response.refreshToken, !refresh.isEmpty else {
            throw MicrosoftAuthError.invalidResponse("no refresh token was returned; the offline_access permission may be missing from the app registration")
        }
        let username = claims.preferredUsername ?? claims.email ?? ""
        var account = MicrosoftAccount(id: claims.accountID, displayName: claims.name ?? (username.isEmpty ? "Microsoft account" : username),
                                       username: username, tenantID: claims.tenantID ?? "", isPersonal: claims.isPersonalAccount)
        try secrets.setString(refresh, account: Self.refreshTokenKey(account.id))
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            account.avatar = accounts[i].avatar
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        try persistAccounts()
        cache(response, accountID: account.id, scope: resource.scopeString(cloud: configuration.cloud))
        activeAccountID = account.id
        let id = account.id
        Task { [weak self] in await self?.refreshAvatar(for: id) }
        return account
    }

    // MARK: - Tokens

    /// Returns an access token for `resource`, from the in-memory cache when it has more than five minutes left,
    /// otherwise by silently redeeming the account's refresh token. Concurrent calls for the same account and
    /// resource share one refresh.
    ///
    /// - Throws: `MicrosoftAuthError.interactionRequired` when the user must sign in again (the account is flagged
    ///   `needsSignIn`), `.personalAccountUnsupported` for resources consumer accounts cannot use.
    public func accessToken(for resource: MicrosoftResource, account: MicrosoftAccount? = nil, forceRefresh: Bool = false) async throws -> String {
        guard let account = account.flatMap({ a in accounts.first { $0.id == a.id } }) ?? (account == nil ? activeAccount : nil) else {
            throw account == nil ? MicrosoftAuthError.noActiveAccount : MicrosoftAuthError.accountNotFound
        }
        guard configuration.isConfigured else { throw MicrosoftAuthError.clientIDMissing }
        if account.isPersonal, !resource.supportsPersonalAccounts {
            throw MicrosoftAuthError.personalAccountUnsupported(resource: resource.displayName)
        }
        let scope = resource.scopeString(cloud: configuration.cloud)
        let key = Self.cacheKey(account.id, scope)
        if !forceRefresh, let c = tokenCache[key], c.expiresAt.timeIntervalSinceNow > Self.refreshLeeway {
            return c.token
        }
        if let running = inflight[key] { return try await running.value }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            return try await self.redeemRefreshToken(accountID: account.id, scope: scope)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    /// `AccessTokenProviding`: `resource` may be a scope list, a `/.default` scope, or a bare resource URL.
    public func accessToken(resource: String) async throws -> String {
        try await accessToken(for: MicrosoftResource.from(resourceString: resource, cloud: configuration.cloud))
    }
    public func accessToken(resource: String, forceRefresh: Bool) async throws -> String {
        try await accessToken(for: MicrosoftResource.from(resourceString: resource, cloud: configuration.cloud), forceRefresh: forceRefresh)
    }

    /// A token for a data source: `resource` is a `/.default` scope (`EntraResource` in the query engine) and `host` the
    /// server it will be sent to. The host must pass `TokenAudiencePolicy` for the resource, otherwise nothing is
    /// requested and `.hostNotAllowed` is thrown.
    ///
    /// Incremental consent: when the account has not consented to the resource yet (or must sign in again, or no account
    /// is signed in) and `interactive` is true, the browser sign-in opens once for that resource's scope, then the token
    /// is returned. Concurrent requests for the same scope share that one sign-in.
    public func accessToken(resource: String, host: String, interactive: Bool = true) async throws -> String {
        guard TokenAudiencePolicy.allows(resource: resource, host: host, cloud: configuration.cloud) else {
            throw MicrosoftAuthError.hostNotAllowed(host: host, resource: Self.resourceLabel(resource))
        }
        let target = MicrosoftResource.from(resourceString: Self.mapToCloud(resource, configuration.cloud), cloud: configuration.cloud)
        do {
            return try await accessToken(for: target)
        } catch let e as MicrosoftAuthError where interactive && Self.needsInteractiveConsent(e) {
            let scope = target.scopeString(cloud: configuration.cloud).lowercased()
            if let running = consentTasks[scope] {
                try await running.value
            } else {
                let hint = activeAccount?.username
                let task = Task { @MainActor [weak self] () throws -> Void in
                    guard let self else { throw CancellationError() }
                    _ = try await self.signIn(loginHint: hint, resource: target)
                }
                consentTasks[scope] = task
                defer { consentTasks[scope] = nil }
                try await task.value
            }
            return try await accessToken(for: target)
        }
    }

    static func needsInteractiveConsent(_ e: MicrosoftAuthError) -> Bool {
        switch e {
        case .consentRequired, .interactionRequired, .noActiveAccount: return true
        default: return false
        }
    }

    /// The well-known global resources mapped to the configured national cloud (Graph, Power BI).
    static func mapToCloud(_ resource: String, _ cloud: MicrosoftCloud) -> String {
        guard cloud != .public else { return resource }
        let lower = resource.lowercased()
        if lower.hasPrefix("https://graph.microsoft.com") { return cloud.graphEndpoint.absoluteString + "/.default" }
        if lower.hasPrefix("https://analysis.windows.net/powerbi/api") { return cloud.powerBIResource + "/.default" }
        return resource
    }

    /// A short, readable name for a resource in messages.
    static func resourceLabel(_ resource: String) -> String {
        let host = TokenAudiencePolicy.audienceHost(of: resource) ?? resource
        switch host {
        case "database.windows.net": return "Azure SQL"
        case "storage.azure.com": return "Azure Storage"
        case "ossrdbms-aad.database.windows.net": return "Azure Database for PostgreSQL and MySQL"
        case "analysis.windows.net": return "Power BI"
        case "graph.microsoft.com": return "Microsoft Graph"
        default: return host
        }
    }

    private func redeemRefreshToken(accountID: String, scope: String) async throws -> String {
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw MicrosoftAuthError.accountNotFound }
        let label = account.username.isEmpty ? account.displayName : account.username
        guard let refresh = try secrets.getString(account: Self.refreshTokenKey(accountID)), !refresh.isEmpty else {
            setNeedsSignIn(accountID, true)
            throw MicrosoftAuthError.interactionRequired(account: label, detail: "Its saved sign-in is no longer available.")
        }
        let builder = OAuthRequestBuilder(configuration: configuration)
        do {
            let response = try await tokenCall(builder.refreshRequest(refreshToken: refresh, scope: scope, tenant: refreshTenant(for: account)))
            if let rotated = response.refreshToken, !rotated.isEmpty, rotated != refresh {
                try secrets.setString(rotated, account: Self.refreshTokenKey(accountID))
            }
            cache(response, accountID: accountID, scope: scope)
            if account.needsSignIn { setNeedsSignIn(accountID, false) }
            return response.accessToken
        } catch let e as OAuthProtocolError {
            if e.isConsentIssue {
                throw MicrosoftAuthError.consentRequired(resource: scope, detail: e.description)
            }
            if e.requiresInteraction {
                setNeedsSignIn(accountID, true)
                tokenCache = tokenCache.filter { !$0.key.hasPrefix(accountID + "|") }
                throw MicrosoftAuthError.interactionRequired(account: label, detail: e.description)
            }
            throw e.asAuthError
        } catch let e as URLError {
            throw e.code == .cancelled ? MicrosoftAuthError.cancelled : MicrosoftAuthError.network(e.localizedDescription)
        }
    }

    /// Work/school accounts refresh against their home tenant unless a specific tenant is configured.
    private func refreshTenant(for account: MicrosoftAccount) -> String? {
        let generic = ["common", "organizations", "consumers"]
        guard generic.contains(configuration.effectiveTenant.lowercased()) else { return nil }
        return account.isPersonal || account.tenantID.isEmpty ? nil : account.tenantID
    }

    private func cache(_ response: OAuthTokenResponse, accountID: String, scope: String) {
        tokenCache[Self.cacheKey(accountID, scope)] =
            CachedToken(token: response.accessToken, expiresAt: Date().addingTimeInterval(response.expiresIn))
    }

    private static func cacheKey(_ accountID: String, _ scope: String) -> String { accountID + "|" + scope.lowercased() }
    private static func refreshTokenKey(_ accountID: String) -> String { "rt." + accountID }

    /// Hosts tokens and sign-in pages are limited to, for the configured cloud.
    public var policy: EndpointPolicy { EndpointPolicy(cloud: configuration.cloud) }

    /// Identity-platform call with a bounded response. Only ever sent to the configured authority over https.
    private func identityCall(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.scheme == "https", url.host?.lowercased() == configuration.cloud.authorityHost.host?.lowercased() else {
            throw MicrosoftAuthError.invalidResponse("the sign-in service address is not the Microsoft authority")
        }
        do { return try await BoundedHTTP.data(for: request, session: authSession, limit: BoundedHTTP.identityLimit) }
        catch is BoundedHTTP.TooLarge { throw MicrosoftAuthError.invalidResponse("the response was too large") }
    }

    private func tokenCall(_ request: URLRequest) async throws -> OAuthTokenResponse {
        CloudLog.log("→ " + CloudLog.redactedDescription(of: request))
        let (data, response) = try await identityCall(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        CloudLog.log("← \(status) token endpoint")
        return try OAuthTokenResponse.parse(data, statusCode: status)
    }

    private func deviceCodeCall(_ request: URLRequest) async throws -> DeviceCodeResponse {
        CloudLog.log("→ " + CloudLog.redactedDescription(of: request))
        let (data, response) = try await identityCall(request)
        return try DeviceCodeResponse.parse(data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Account management

    /// Signs an account out of Facet: removes its refresh token from the Keychain and forgets its cached tokens.
    public func signOut(_ account: MicrosoftAccount) {
        try? secrets.delete(account: Self.refreshTokenKey(account.id))
        tokenCache = tokenCache.filter { !$0.key.hasPrefix(account.id + "|") }
        for (k, t) in inflight where k.hasPrefix(account.id + "|") { t.cancel() }
        accounts.removeAll { $0.id == account.id }
        try? persistAccounts()
        if activeAccountID == account.id || activeAccountID == nil { activeAccountID = accounts.first?.id }
    }

    /// Signs every account out and deletes all of Facet's Microsoft items from the Keychain.
    public func removeAll() {
        cancelSignIn()
        for t in inflight.values { t.cancel() }
        tokenCache.removeAll()
        accounts.removeAll()
        try? secrets.removeAll()
        activeAccountID = nil
    }

    /// Makes `account` the active account used by default for tokens.
    public func setActive(_ account: MicrosoftAccount) {
        if accounts.contains(where: { $0.id == account.id }) { activeAccountID = account.id }
    }

    private func persistAccounts() throws {
        try secrets.setCodable(accounts, account: Self.accountsKey)
    }

    private func setNeedsSignIn(_ accountID: String, _ value: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }), accounts[i].needsSignIn != value else { return }
        accounts[i].needsSignIn = value
        try? persistAccounts()
    }

    /// Fetches the account's profile photo from Graph (`/me/photo/$value`). Accounts without a photo keep `avatar == nil`.
    public func refreshAvatar(for accountID: String) async {
        guard let account = accounts.first(where: { $0.id == accountID }),
              let token = try? await accessToken(for: .graph, account: account) else { return }
        var request = URLRequest(url: configuration.cloud.graphEndpoint.appendingPathComponent("v1.0/me/photo/$value"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard policy.allowsCredentials(for: request.url),
              let (data, response) = try? await BoundedHTTP.data(for: request, session: authSession, limit: BoundedHTTP.photoLimit),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty,
              let i = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[i].avatar = data
    }

    /// Fetches profile photos for all signed-in accounts that do not have one loaded yet.
    public func refreshAvatars() async {
        for a in accounts where a.avatar == nil && !a.needsSignIn { await refreshAvatar(for: a.id) }
    }
}
