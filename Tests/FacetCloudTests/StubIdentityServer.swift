import Foundation
import XCTest
@testable import FacetCloud

/// A local stand-in for the Microsoft identity platform, used to drive the whole sign-in flow without a network.
///
/// It behaves like the real service where it matters for security: an authorization code is single-use and
/// bound to the redirect URI, the client id and the PKCE challenge it was issued for; refresh tokens rotate and
/// the previous one stops working. The "browser" half calls the app's real loopback listener over 127.0.0.1.
final class StubIdentityServer: @unchecked Sendable {
    struct User { var oid: String; var tid: String; var name: String; var upn: String }
    struct Grant { var challenge: String; var redirect: String; var clientID: String; var nonce: String; var user: User }

    static let clientID = "11111111-aaaa-bbbb-cccc-222222222222"
    private let lock = NSLock()
    private var codes: [String: Grant] = [:]
    private var refreshTokens: [String: User] = [:]
    private var counter = 0
    private var devicePolls = 0

    // Behaviour switches (set before the call under test).
    var user = User(oid: "oid-ana", tid: "tid-contoso", name: "Ana Müller", upn: "ana@contoso.com")
    /// Requests the browser makes to the loopback listener before the genuine redirect.
    var forgedRedirects: [String] = []
    var audienceOverride: String?
    var issuerOverride: String?
    var expiresIn = 3600
    var revokeAllRefreshTokens = false
    var devicePendingPolls = 2
    var deviceVerificationURI = "https://microsoft.com/devicelogin"
    var oversizedTokenResponse = false
    /// Scopes the user has not consented to yet: refreshing for one fails with AADSTS65001 until an interactive
    /// sign-in requests it.
    var scopesNeedingConsent: Set<String> = []

    // What the server saw.
    private(set) var authorizeQueries: [[String: String]] = []
    private(set) var tokenForms: [[String: String]] = []
    private(set) var rejectedExchanges: [String] = []
    private(set) var forgedStatuses: [Int] = []
    private(set) var requestedHosts: Set<String> = []

    private func next(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)-\(UUID().uuidString.prefix(8))"
    }

    func install() {
        SelfCheckURLProtocol.handler = { [weak self] request, body in
            self?.handle(request, body) ?? .json("{}", status: 500)
        }
    }

    /// The `openURL` closure given to the account manager: plays the browser and the authorize endpoint.
    func browser() -> (URL) -> Bool {
        { [weak self] url in
            guard let self else { return false }
            let q = LoopbackRedirectListener.parseQuery(url.absoluteString)
            self.lock.lock()
            self.authorizeQueries.append(q.merging(["_host": url.host ?? "", "_path": url.path, "_scheme": url.scheme ?? ""]) { a, _ in a })
            let code = self.next("code")
            self.codes[code] = Grant(challenge: q["code_challenge"] ?? "", redirect: q["redirect_uri"] ?? "",
                                     clientID: q["client_id"] ?? "", nonce: q["nonce"] ?? "", user: self.user)
            let forged = self.forgedRedirects
            self.lock.unlock()
            guard let redirect = q["redirect_uri"], let state = q["state"] else { return true }
            Task.detached {
                let session = URLSession(configuration: .ephemeral)
                for path in forged {
                    guard let u = URL(string: redirect + path) else { continue }
                    let status = ((try? await session.data(from: u))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                    self.recordForged(status)
                }
                guard let u = URL(string: "\(redirect)/?code=\(code)&state=\(state)") else { return }
                _ = try? await session.data(from: u)
            }
            return true
        }
    }

    private func recordForged(_ status: Int) {
        lock.lock(); forgedStatuses.append(status); lock.unlock()
    }

    private func idToken(for user: User, nonce: String?) -> String {
        var claims: JSONValue = [
            "sub": .string("sub-" + user.oid), "oid": .string(user.oid), "tid": .string(user.tid),
            "name": .string(user.name), "preferred_username": .string(user.upn),
            "aud": .string(audienceOverride ?? Self.clientID),
            "iss": .string(issuerOverride ?? "https://login.microsoftonline.com/\(user.tid)/v2.0"),
            "exp": .double(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ]
        if let nonce { claims = claims.setting("nonce", to: .string(nonce)) }
        return SelfCheckFixtures.jwt(claims)
    }

    private func tokens(for user: User, nonce: String?, includeID: Bool) -> SelfCheckURLProtocol.Response {
        let refresh = next("RT")
        refreshTokens[refresh] = user
        var json: JSONValue = [
            "token_type": "Bearer", "expires_in": .int(Int64(expiresIn)),
            "access_token": .string(next("AT") + "-" + user.oid), "refresh_token": .string(refresh),
        ]
        if includeID { json = json.setting("id_token", to: .string(idToken(for: user, nonce: nonce))) }
        return .json(json.serialized())
    }

    private func oauthError(_ code: String, _ description: String) -> SelfCheckURLProtocol.Response {
        .json(#"{"error":"\#(code)","error_description":"\#(description)"}"#, status: 400)
    }

    private func handle(_ request: URLRequest, _ body: Data) -> SelfCheckURLProtocol.Response {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? ""
        requestedHosts.insert(request.url?.host ?? "")
        if path.hasSuffix("/oauth2/v2.0/devicecode") {
            devicePolls = 0
            return .json(#"{"user_code":"ABCD-EFGH","device_code":"DEVICE-CODE-1","verification_uri":"\#(deviceVerificationURI)","expires_in":900,"interval":5,"message":"Go sign in."}"#)
        }
        if path.hasSuffix("/oauth2/v2.0/token") {
            let form = SelfCheckFixtures.formBody(body)
            tokenForms.append(form)
            if oversizedTokenResponse {
                return SelfCheckURLProtocol.Response(status: 200, body: Data(repeating: 0x20, count: 2 * 1024 * 1024))
            }
            switch form["grant_type"] ?? "" {
            case "authorization_code":
                guard let code = form["code"], let grant = codes.removeValue(forKey: code) else {
                    rejectedExchanges.append("unknown code")
                    return oauthError("invalid_grant", "AADSTS70008: The provided authorization code is invalid or already redeemed.")
                }
                guard form["client_id"] == grant.clientID, form["redirect_uri"] == grant.redirect else {
                    rejectedExchanges.append("redirect or client mismatch")
                    return oauthError("invalid_grant", "AADSTS50011: redirect mismatch.")
                }
                guard PKCEPair(verifier: form["code_verifier"] ?? "").challenge == grant.challenge else {
                    rejectedExchanges.append("pkce mismatch")
                    return oauthError("invalid_grant", "AADSTS501481: The Code_Verifier does not match the code_challenge.")
                }
                for scope in (form["scope"] ?? "").split(separator: " ") { scopesNeedingConsent.remove(String(scope)) }
                return tokens(for: grant.user, nonce: grant.nonce, includeID: true)
            case "refresh_token":
                if (form["scope"] ?? "").split(separator: " ").contains(where: { scopesNeedingConsent.contains(String($0)) }) {
                    return .json(#"{"error":"invalid_grant","error_description":"AADSTS65001: The user or administrator has not consented to use the application.","error_codes":[65001],"suberror":"consent_required"}"#, status: 400)
                }
                guard !revokeAllRefreshTokens, let token = form["refresh_token"], let user = refreshTokens.removeValue(forKey: token) else {
                    return oauthError("invalid_grant", "AADSTS700082: The refresh token has expired due to inactivity.")
                }
                return tokens(for: user, nonce: nil, includeID: false)
            case "urn:ietf:params:oauth:grant-type:device_code":
                guard form["device_code"] == "DEVICE-CODE-1" else { return oauthError("invalid_grant", "unknown device code") }
                devicePolls += 1
                if devicePolls == 1, devicePendingPolls > 1 { return oauthError("slow_down", "polling too fast") }
                if devicePolls <= devicePendingPolls { return oauthError("authorization_pending", "waiting for the user") }
                return tokens(for: user, nonce: nil, includeID: true)
            default:
                return oauthError("unsupported_grant_type", "unsupported")
            }
        }
        if path.hasSuffix("/me/photo/$value") { return .json("{}", status: 404) }
        return .json(#"{"error":{"code":"notFound","message":"not stubbed"}}"#, status: 404)
    }

    func isCurrentRefreshToken(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refreshTokens[token] != nil
    }
}

/// Collects FacetCloud debug log lines for the "nothing secret is logged" checks.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func start() { CloudLog.handler = { [weak self] line in self?.lock.lock(); self?.lines.append(line); self?.lock.unlock() } }
    func stop() -> String {
        CloudLog.handler = nil
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

func scratchDefaults() -> (UserDefaults, String) {
    let suite = "facet.tests." + UUID().uuidString
    return (UserDefaults(suiteName: suite) ?? .standard, suite)
}
