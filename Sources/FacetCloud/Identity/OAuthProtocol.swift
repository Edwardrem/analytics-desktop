import Foundation
import CryptoKit
import Security

/// PKCE (RFC 7636) verifier/challenge pair using the S256 method.
public struct PKCEPair: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// Generates a new high-entropy verifier (32 random bytes → 43 base64url characters) and its challenge.
    public static func generate() -> PKCEPair {
        let v = OAuthRandom.urlSafeToken(byteCount: 32)
        return PKCEPair(verifier: v)
    }
    /// Derives the S256 challenge for an existing verifier.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = HTTPHelpers.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum OAuthRandom {
    /// Cryptographically secure random bytes, base64url encoded.
    static func urlSafeToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return HTTPHelpers.base64URLEncode(Data(bytes))
    }
}

/// Builds the requests of the OAuth 2.0 flows Facet uses against the Microsoft identity platform (v2.0 endpoints).
public struct OAuthRequestBuilder: Sendable {
    public let configuration: MicrosoftAuthConfiguration
    public init(configuration: MicrosoftAuthConfiguration) { self.configuration = configuration }

    /// OIDC scopes plus the Graph scopes, requested at interactive sign-in.
    public var signInScopes: [String] { signInScopes(for: .graph) }

    /// OIDC scopes, `offline_access`, and the scopes of one resource (an authorization request can only
    /// carry scopes for a single resource).
    public func signInScopes(for resource: MicrosoftResource) -> [String] {
        var s = ["openid", "profile", "offline_access"]
        for scope in resource.scopes(cloud: configuration.cloud) where !s.contains(scope) { s.append(scope) }
        return s
    }

    /// The browser URL that starts the authorization-code flow with PKCE.
    public func authorizationURL(redirectURI: String, state: String, nonce: String, pkce: PKCEPair,
                                 loginHint: String? = nil, prompt: String? = "select_account", scopes: [String]? = nil) -> URL {
        var comps = URLComponents(url: configuration.endpoint("authorize"), resolvingAgainstBaseURL: false)!
        var items: [(String, String)] = [
            ("client_id", configuration.effectiveClientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("response_mode", "query"),
            ("scope", (scopes ?? signInScopes).joined(separator: " ")),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
        ]
        if let prompt { items.append(("prompt", prompt)) }
        if let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        comps.percentEncodedQuery = String(decoding: HTTPHelpers.formEncode(items), as: UTF8.self)
        return comps.url!
    }

    private func formRequest(_ endpoint: String, tenant: String? = nil, _ pairs: [(String, String)]) -> URLRequest {
        var r = URLRequest(url: configuration.endpoint(endpoint, tenantOverride: tenant))
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = HTTPHelpers.formEncode(pairs)
        return r
    }

    /// Redeems an authorization code (public client: no secret, PKCE verifier instead).
    public func codeExchangeRequest(code: String, redirectURI: String, verifier: String, scopes: [String]? = nil) -> URLRequest {
        formRequest("token", [
            ("client_id", configuration.effectiveClientID),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
            ("scope", (scopes ?? signInScopes).joined(separator: " ")),
        ])
    }

    /// Redeems a refresh token for an access token for `scope`. `tenant` pins the request to the account's home tenant.
    public func refreshRequest(refreshToken: String, scope: String, tenant: String? = nil) -> URLRequest {
        var scopes = scope.split(separator: " ").map(String.init)
        if !scopes.contains("offline_access") { scopes.append("offline_access") }
        return formRequest("token", tenant: tenant, [
            ("client_id", configuration.effectiveClientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("scope", scopes.joined(separator: " ")),
        ])
    }

    /// Starts the device-code flow.
    public func deviceCodeRequest() -> URLRequest {
        formRequest("devicecode", [
            ("client_id", configuration.effectiveClientID),
            ("scope", signInScopes.joined(separator: " ")),
        ])
    }

    /// Polls the token endpoint during the device-code flow.
    public func deviceCodePollRequest(deviceCode: String) -> URLRequest {
        formRequest("token", [
            ("client_id", configuration.effectiveClientID),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", deviceCode),
        ])
    }
}

/// A successful token-endpoint response.
public struct OAuthTokenResponse: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresIn: TimeInterval
    public let scope: String
    public let tokenType: String

    /// Parses a token-endpoint body. Error bodies (`{"error": ...}`) throw a typed `MicrosoftAuthError`/`OAuthProtocolError`.
    public static func parse(_ data: Data, statusCode: Int) throws -> OAuthTokenResponse {
        guard let json = try? JSONValue.parse(data), json.members != nil else {
            throw MicrosoftAuthError.invalidResponse("HTTP \(statusCode), body was not JSON")
        }
        if let error = json["error"]?.stringValue {
            throw OAuthProtocolError(
                code: error,
                description: OAuthProtocolError.clean(json["error_description"]?.stringValue ?? ""),
                subError: json["suberror"]?.stringValue,
                correlationID: json["correlation_id"]?.stringValue,
                errorCodes: (json["error_codes"]?.arrayValue ?? []).compactMap { $0.intValue.map(Int.init) })
        }
        guard let access = json["access_token"]?.stringValue, !access.isEmpty else {
            throw MicrosoftAuthError.invalidResponse("HTTP \(statusCode), no access_token")
        }
        // expires_in is a number, but some Microsoft endpoints have returned it as a string.
        let expires = json["expires_in"]?.doubleValue ?? json["expires_in"]?.stringValue.flatMap(Double.init) ?? 3600
        return OAuthTokenResponse(accessToken: access, refreshToken: json["refresh_token"]?.stringValue,
                                  idToken: json["id_token"]?.stringValue, expiresIn: expires,
                                  scope: json["scope"]?.stringValue ?? "", tokenType: json["token_type"]?.stringValue ?? "Bearer")
    }
}

/// An OAuth error body from the identity platform.
public struct OAuthProtocolError: Error, Equatable, Sendable {
    public let code: String
    public let description: String
    public let subError: String?
    public let correlationID: String?
    public let errorCodes: [Int]

    /// True when the user must sign in again (expired/revoked refresh token, MFA, consent, password change).
    public var requiresInteraction: Bool {
        code == "interaction_required" || code == "invalid_grant" || code == "consent_required" || code == "login_required"
    }

    /// True when the refresh token is fine but the user (or an admin) has not consented to the requested resource.
    public var isConsentIssue: Bool {
        code == "consent_required" || subError == "consent_required" || errorCodes.contains(65001)
    }

    /// AADSTS descriptions carry trace ids and timestamps on later lines; keep the first line only.
    static func clean(_ s: String) -> String {
        let first = s.components(separatedBy: CharacterSet.newlines).first ?? s
        return first.trimmingCharacters(in: .whitespaces)
    }

    var asAuthError: MicrosoftAuthError {
        switch code {
        case "access_denied", "authorization_declined": return .userDeclined
        case "expired_token", "code_expired": return .deviceCodeExpired
        default: return .service(code: code, description: description, correlationID: correlationID)
        }
    }
}

/// The device-code endpoint response.
public struct DeviceCodeResponse: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: TimeInterval
    public let interval: TimeInterval
    public let message: String

    public static func parse(_ data: Data, statusCode: Int) throws -> DeviceCodeResponse {
        guard let json = try? JSONValue.parse(data), json.members != nil else {
            throw MicrosoftAuthError.invalidResponse("HTTP \(statusCode), body was not JSON")
        }
        if let error = json["error"]?.stringValue {
            throw OAuthProtocolError(code: error, description: OAuthProtocolError.clean(json["error_description"]?.stringValue ?? ""),
                                     subError: nil, correlationID: json["correlation_id"]?.stringValue, errorCodes: [])
        }
        guard let device = json["device_code"]?.stringValue, let user = json["user_code"]?.stringValue,
              let uri = (json["verification_uri"] ?? json["verification_url"])?.stringValue, let url = URL(string: uri) else {
            throw MicrosoftAuthError.invalidResponse("device code response was missing fields")
        }
        return DeviceCodeResponse(deviceCode: device, userCode: user, verificationURL: url,
                                  expiresIn: json["expires_in"]?.doubleValue ?? 900,
                                  interval: max(1, json["interval"]?.doubleValue ?? 5),
                                  message: json["message"]?.stringValue ?? "")
    }
}

/// What the UI shows while a device-code sign-in is pending.
public struct DeviceCodePrompt: Equatable, Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let message: String
}

/// What to do after one device-code poll.
enum DeviceCodePollOutcome: Equatable {
    case keepPolling(interval: TimeInterval)
    case fail(MicrosoftAuthError)

    /// RFC 8628 §3.5: `authorization_pending` → keep polling; `slow_down` → add 5 s to the interval; anything else is terminal.
    static func evaluate(error: OAuthProtocolError, currentInterval: TimeInterval) -> DeviceCodePollOutcome {
        switch error.code {
        case "authorization_pending": return .keepPolling(interval: currentInterval)
        case "slow_down": return .keepPolling(interval: currentInterval + 5)
        case "authorization_declined", "access_denied": return .fail(.userDeclined)
        case "expired_token", "code_expired": return .fail(.deviceCodeExpired)
        default: return .fail(error.asAuthError)
        }
    }
}

/// The claims Facet reads from an ID token. Signatures are not validated client-side: the token is received
/// directly from the token endpoint over TLS, and the `nonce` is checked against the sign-in attempt.
public struct IDTokenClaims: Sendable, Equatable {
    public let subject: String
    public let objectID: String?
    public let tenantID: String?
    public let name: String?
    public let preferredUsername: String?
    public let email: String?
    public let nonce: String?
    public let issuer: String?
    public let expiresAt: Date?
    /// The `aud` claim: the application (client) ID the token was issued to.
    public var audience: String? = nil

    /// Tenant ID that Microsoft uses for all personal (consumer) accounts.
    public static let personalTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"

    public var isPersonalAccount: Bool { tenantID?.lowercased() == Self.personalTenantID }

    /// Stable account identifier: `<oid or sub>.<tid>`.
    public var accountID: String {
        let user = (objectID?.isEmpty == false ? objectID : nil) ?? subject
        return "\(user).\(tenantID ?? "unknown")".lowercased()
    }

    /// Decodes the payload (second segment, base64url) of a JWT.
    public static func decode(jwt: String) throws -> IDTokenClaims {
        let payload = try JWT.payload(of: jwt)
        guard let sub = payload["sub"]?.stringValue, !sub.isEmpty else {
            throw MicrosoftAuthError.invalidIDToken("missing subject")
        }
        return IDTokenClaims(
            subject: sub, objectID: payload["oid"]?.stringValue, tenantID: payload["tid"]?.stringValue,
            name: payload["name"]?.stringValue, preferredUsername: payload["preferred_username"]?.stringValue,
            email: payload["email"]?.stringValue, nonce: payload["nonce"]?.stringValue, issuer: payload["iss"]?.stringValue,
            expiresAt: payload["exp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            audience: payload["aud"]?.stringValue)
    }

    /// Checks the claims that bind the token to this app and authority: the audience must be `clientID`, the issuer must
    /// be the sign-in authority (and name the token's own tenant), and the token must not have expired.
    /// The signature is not checked: the token comes straight from the token endpoint over TLS.
    public func validate(clientID: String, authorityHost: String?, now: Date = Date()) throws {
        guard let audience, audience.caseInsensitiveCompare(clientID) == .orderedSame else {
            throw MicrosoftAuthError.invalidIDToken("it was issued to a different application")
        }
        guard let issuer, let url = URL(string: issuer), url.scheme == "https", let host = url.host?.lowercased(),
              host == authorityHost?.lowercased() else {
            throw MicrosoftAuthError.invalidIDToken("it was issued by an unexpected authority")
        }
        if let tenantID, !tenantID.isEmpty, !url.path.lowercased().contains(tenantID.lowercased()) {
            throw MicrosoftAuthError.invalidIDToken("its issuer does not match its tenant")
        }
        if let expiresAt, expiresAt.timeIntervalSince(now) < -300 {
            throw MicrosoftAuthError.invalidIDToken("it has expired")
        }
    }
}

/// JWT helpers (payload decoding only).
public enum JWT {
    /// The decoded JSON payload of a compact JWT.
    public static func payload(of jwt: String) throws -> JSONValue {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 5 else { throw MicrosoftAuthError.invalidIDToken("not a JWT") }
        guard parts.count == 3 else { throw MicrosoftAuthError.invalidIDToken("encrypted tokens are not supported") }
        guard let data = HTTPHelpers.base64URLDecode(String(parts[1])), let json = try? JSONValue.parse(data), json.members != nil else {
            throw MicrosoftAuthError.invalidIDToken("payload is not valid base64url JSON")
        }
        return json
    }
}
