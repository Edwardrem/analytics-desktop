import Foundation
import FacetCore

/// A Microsoft national cloud, with its sign-in authority and service endpoints.
public enum MicrosoftCloud: String, Codable, CaseIterable, Sendable {
    /// Global Azure / Microsoft 365.
    case `public`
    /// Azure US Government (`login.microsoftonline.us`; GCC High endpoints).
    case usGovernment
    /// Microsoft Azure operated by 21Vianet (China).
    case china

    public var displayName: String {
        switch self {
        case .public: return "Global"
        case .usGovernment: return "US Government"
        case .china: return "China (21Vianet)"
        }
    }

    /// Sign-in authority host, without tenant.
    public var authorityHost: URL {
        switch self {
        case .public: return URL(string: "https://login.microsoftonline.com")!
        case .usGovernment: return URL(string: "https://login.microsoftonline.us")!
        case .china: return URL(string: "https://login.chinacloudapi.cn")!
        }
    }
    /// Microsoft Graph root (no version segment).
    public var graphEndpoint: URL {
        switch self {
        case .public: return URL(string: "https://graph.microsoft.com")!
        case .usGovernment: return URL(string: "https://graph.microsoft.us")!
        case .china: return URL(string: "https://microsoftgraph.chinacloudapi.cn")!
        }
    }
    /// Power BI REST root (no `/v1.0/myorg`).
    public var powerBIEndpoint: URL {
        switch self {
        case .public: return URL(string: "https://api.powerbi.com")!
        case .usGovernment: return URL(string: "https://api.high.powerbigov.us")!
        case .china: return URL(string: "https://api.powerbi.cn")!
        }
    }
    /// Resource identifier used for Power BI tokens.
    public var powerBIResource: String {
        switch self {
        case .public: return "https://analysis.windows.net/powerbi/api"
        case .usGovernment: return "https://high.analysis.usgovcloudapi.net/powerbi/api"
        case .china: return "https://analysis.chinacloudapi.cn/powerbi/api"
        }
    }
    /// Fabric REST root. Fabric's public REST API is only documented for the global cloud; `nil` elsewhere.
    public var fabricEndpoint: URL? {
        self == .public ? URL(string: "https://api.fabric.microsoft.com") : nil
    }
    /// OneLake DFS endpoint; `nil` outside the global cloud.
    public var oneLakeEndpoint: URL? {
        self == .public ? URL(string: "https://onelake.dfs.fabric.microsoft.com") : nil
    }
    /// Azure Storage resource identifier (used for OneLake).
    public var storageResource: String { "https://storage.azure.com" }
}

/// Settings for signing in with the Microsoft identity platform. Persisted in `UserDefaults` (no secrets).
///
/// The app ships with a default multi-tenant app registration whose client ID is read from the bundle's Info.plist
/// (`AnalyticsEntraClientID`); it is never written in code. `clientID` and `tenant` hold the user's optional override
/// from Settings ▸ Microsoft account; empty means "use the app's default".
public struct MicrosoftAuthConfiguration: Codable, Equatable, Sendable {
    /// Info.plist key holding the default Entra application (client) ID.
    public static let bundleClientIDKey = "AnalyticsEntraClientID"
    /// The authority used when no tenant is set: any work or school account.
    public static let defaultTenant = "organizations"

    /// Application (client) ID override. Empty uses `defaultClientID`.
    public var clientID: String
    /// Tenant override: `organizations`, `common`, `consumers`, or a tenant ID / verified domain. Empty uses `defaultTenant`.
    public var tenant: String
    public var cloud: MicrosoftCloud
    /// The app's own client ID from Info.plist (not persisted with the override).
    public var defaultClientID: String = ""

    private enum CodingKeys: String, CodingKey { case clientID, tenant, cloud }

    public init(clientID: String = "", tenant: String = "", cloud: MicrosoftCloud = .public, defaultClientID: String = "") {
        self.clientID = clientID; self.tenant = tenant; self.cloud = cloud; self.defaultClientID = defaultClientID
    }

    /// The client ID sign-in uses: the override when set, else the app's default.
    public var effectiveClientID: String {
        let own = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? defaultClientID.trimmingCharacters(in: .whitespacesAndNewlines) : own
    }
    public var isConfigured: Bool { !effectiveClientID.isEmpty }
    /// True when sign-in runs on the app's own registration (no override).
    public var usesDefaultRegistration: Bool {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !defaultClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var effectiveTenant: String {
        let t = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Self.defaultTenant : t
    }

    /// The default client ID shipped in a bundle's Info.plist, or "" when the key is missing or empty.
    public static func bundledClientID(_ bundle: Bundle = .main) -> String {
        ((bundle.object(forInfoDictionaryKey: bundleClientIDKey) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/<endpoint>`
    public func endpoint(_ name: String, tenantOverride: String? = nil) -> URL {
        let t = HTTPHelpers.encodePathSegment(tenantOverride ?? effectiveTenant)
        return cloud.authorityHost.appendingPathComponent(t).appendingPathComponent("oauth2/v2.0").appendingPathComponent(name)
    }

    // MARK: Persistence

    public static let defaultsKey = "com.facet.microsoft.authConfiguration"

    /// The saved override, with the default client ID from `bundle` (pass nil for none).
    public static func load(from defaults: UserDefaults = .standard, bundle: Bundle? = .main) -> MicrosoftAuthConfiguration {
        var c = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(MicrosoftAuthConfiguration.self, from: $0) }
            ?? MicrosoftAuthConfiguration()
        c.defaultClientID = bundle.map { bundledClientID($0) } ?? ""
        return c
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// What is missing when no client ID is available anywhere.
    public static let missingRegistration = """
    This copy of \(AppIdentity.name) has no Microsoft application ID: the \(bundleClientIDKey) key in its Info.plist is empty, \
    and no application ID is entered in Settings ▸ Microsoft account. Ask whoever gave you the app for a build with one, \
    or enter your organization's own.
    """

    /// Step-by-step instructions for creating an Entra app registration of your own.
    public static let registrationInstructions = """
    To use your organization's own app registration, register a (free) app once and paste its Application (client) ID \
    into Settings ▸ Microsoft account:
    1. Open the Microsoft Entra admin center (https://entra.microsoft.com) → Identity → Applications → App registrations → New registration.
    2. Name it (for example "\(AppIdentity.name)"), and under Supported account types choose "Accounts in any organizational directory" (multi-tenant).
    3. Under Redirect URI choose the platform "Mobile and desktop applications" (public client/native) and enter http://localhost — then Register.
    4. In Authentication → Advanced settings, turn on "Allow public client flows" (needed for device-code sign-in).
    5. In API permissions → Add a permission, add these delegated permissions:
       • Microsoft Graph: User.Read, Files.ReadWrite.All, Sites.Read.All, offline_access (plus openid and profile)
       • Power BI Service: Workspace.Read.All, Report.Read.All, Dataset.ReadWrite.All, Dashboard.Read.All, Dataflow.Read.All, Capacity.Read.All (add Workspace.ReadWrite.All / Content.Create to publish)
       • Data sources (each: user_impersonation): Azure SQL Database, Azure Storage (Blob, ADLS Gen2, OneLake), Dynamics CRM (Dataverse), Azure Data Explorer, Azure OSSRDBMS Database (PostgreSQL / MySQL); SharePoint: AllSites.Read
       • Optional — Microsoft Fabric (Power BI Service → Fabric scopes): Workspace.Read.All, Item.ReadWrite.All, OneLake.Read.All; Microsoft Graph InformationProtectionPolicy.Read (sensitivity labels)
       Some organisations require an administrator to grant consent.
    6. Copy the Application (client) ID from the Overview page into \(AppIdentity.name).
    """
}

/// A resource Facet can request tokens for.
public enum MicrosoftResource: Hashable, Sendable {
    case graph
    case powerBI
    case fabric
    /// Azure Storage, used for OneLake DFS.
    case storage
    /// A Dataverse environment, e.g. `https://contoso.crm.dynamics.com`.
    case dataverse(orgURL: String)
    /// Any scope string (space-separated scopes, or a single `<resource>/.default`).
    case custom(scope: String)

    /// The scopes requested for this resource in the given cloud (without `offline_access`/OIDC scopes, except Graph).
    public func scopes(cloud: MicrosoftCloud) -> [String] {
        switch self {
        case .graph:
            let names = ["User.Read", "Files.ReadWrite.All", "Sites.Read.All"]
            // Short names resolve to global Graph; national clouds need fully-qualified scopes.
            let qualified = cloud == .public ? names : names.map { cloud.graphEndpoint.absoluteString + "/" + $0 }
            return qualified + ["offline_access"]
        case .powerBI: return [cloud.powerBIResource + "/.default"]
        case .fabric: return ["https://api.fabric.microsoft.com/.default"]
        case .storage: return [cloud.storageResource + "/.default"]
        case .dataverse(let org):
            var o = org.trimmingCharacters(in: .whitespacesAndNewlines)
            while o.hasSuffix("/") { o.removeLast() }
            return [o + "/.default"]
        case .custom(let scope):
            return scope.split(separator: " ").map(String.init)
        }
    }

    public func scopeString(cloud: MicrosoftCloud) -> String { scopes(cloud: cloud).joined(separator: " ") }

    public var displayName: String {
        switch self {
        case .graph: return "Microsoft Graph"
        case .powerBI: return "Power BI"
        case .fabric: return "Microsoft Fabric"
        case .storage: return "OneLake"
        case .dataverse: return "Dataverse"
        case .custom(let s): return s
        }
    }

    /// Whether personal Microsoft accounts (outlook.com, hotmail.com…) can obtain tokens for this resource.
    public var supportsPersonalAccounts: Bool {
        switch self {
        case .graph, .custom: return true
        case .powerBI, .fabric, .storage, .dataverse: return false
        }
    }

    /// Interprets a free-form resource string (as used by `AccessTokenProviding`): a scope list, a
    /// `/.default` scope, or a bare resource URL (to which `/.default` is appended).
    public static func from(resourceString raw: String, cloud: MicrosoftCloud) -> MicrosoftResource {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower == "graph" || lower == MicrosoftResource.graph.scopeString(cloud: cloud).lowercased() { return .graph }
        if lower == "powerbi" { return .powerBI }
        if lower == "fabric" { return .fabric }
        if lower == "storage" || lower == "onelake" { return .storage }
        if s.contains(" ") || lower.hasSuffix("/.default") {
            let known: [MicrosoftResource] = [.powerBI, .fabric, .storage]
            return known.first { $0.scopeString(cloud: cloud).lowercased() == lower } ?? .custom(scope: s)
        }
        if lower.hasPrefix("https://") || lower.hasPrefix("api://") {
            while s.hasSuffix("/") { s.removeLast() }
            // A bare URL with a path beyond the host that isn't a known resource is treated as a full scope
            // only when it looks like one (Graph-style "https://graph.microsoft.com/User.Read").
            if let u = URL(string: s), u.host?.lowercased() == cloud.graphEndpoint.host?.lowercased(), !u.path.isEmpty, u.path != "/" {
                return .custom(scope: s)
            }
            return MicrosoftResource.from(resourceString: s + "/.default", cloud: cloud)
        }
        return .custom(scope: s)
    }
}

/// Errors from Microsoft sign-in and token acquisition.
public enum MicrosoftAuthError: LocalizedError, Equatable {
    /// No client ID configured. The message explains how to register an app.
    case clientIDMissing
    case noActiveAccount
    case accountNotFound
    /// The refresh token is missing, expired or revoked, or the service demands interaction (MFA, consent, password change).
    /// The account has been flipped to "needs sign-in".
    case interactionRequired(account: String, detail: String)
    /// The account is signed in, but consent for this resource has not been granted. The account is not flagged;
    /// call `signIn(loginHint:resource:)` to request consent, or ask an administrator.
    case consentRequired(resource: String, detail: String)
    /// Personal Microsoft accounts cannot use this resource (e.g. Power BI, Fabric).
    case personalAccountUnsupported(resource: String)
    /// The identity platform returned an OAuth error.
    case service(code: String, description: String, correlationID: String?)
    case stateMismatch
    case nonceMismatch
    case invalidIDToken(String)
    case invalidResponse(String)
    case timedOut
    case cancelled
    case userDeclined
    case deviceCodeExpired
    case listenerFailed(String)
    case browserFailed
    case signInAlreadyInProgress
    case network(String)
    /// A token for `resource` was asked for a host that is not on the allow-list for it. Nothing was sent.
    case hostNotAllowed(host: String, resource: String)

    public var errorDescription: String? {
        switch self {
        case .clientIDMissing:
            return "Microsoft sign-in is not set up. " + MicrosoftAuthConfiguration.missingRegistration + "\n" + MicrosoftAuthConfiguration.registrationInstructions
        case .noActiveAccount:
            return "No Microsoft account is signed in. Add an account first."
        case .accountNotFound:
            return "That Microsoft account is no longer signed in to \(AppIdentity.name)."
        case .interactionRequired(let account, let detail):
            return "\(account) needs to sign in again. \(detail)"
        case .consentRequired(let resource, let detail):
            return "\(AppIdentity.name) has not been granted access to \(resource) for this account. Sign in again to grant it, or ask your administrator to consent to the app's permissions. \(detail)"
        case .personalAccountUnsupported(let resource):
            return "\(resource) is only available to work or school accounts. Personal Microsoft accounts (outlook.com, hotmail.com, live.com) can use OneDrive files in \(AppIdentity.name), but not \(resource). Add a work or school account to continue."
        case .service(let code, let description, let correlationID):
            var s = "Microsoft sign-in failed: \(description.isEmpty ? code : description)"
            if !description.isEmpty { s += " (\(code))" }
            if let correlationID { s += " Correlation ID: \(correlationID)." }
            return s
        case .stateMismatch:
            return "The sign-in response did not match this sign-in attempt and was rejected. Please try again."
        case .nonceMismatch:
            return "The identity token did not match this sign-in attempt and was rejected. Please try again."
        case .invalidIDToken(let why):
            return "Microsoft returned an identity token \(AppIdentity.name) could not read (\(why))."
        case .invalidResponse(let why):
            return "Microsoft returned an unexpected sign-in response (\(why))."
        case .timedOut:
            return "Sign-in timed out because it was not completed in the browser within 5 minutes."
        case .cancelled:
            return "Sign-in was cancelled."
        case .userDeclined:
            return "Sign-in was declined."
        case .deviceCodeExpired:
            return "The sign-in code expired before it was used. Start again to get a new code."
        case .listenerFailed(let why):
            return "\(AppIdentity.name) could not start the local sign-in listener (\(why)). Try device-code sign-in instead."
        case .browserFailed:
            return "\(AppIdentity.name) could not open your web browser. Try device-code sign-in instead."
        case .signInAlreadyInProgress:
            return "A sign-in is already in progress. Finish or cancel it first."
        case .network(let why):
            return "Could not reach Microsoft sign-in: \(why)"
        case .hostNotAllowed(let host, let resource):
            return "\(AppIdentity.name) won't send your Microsoft sign-in for \(resource) to “\(host)”, because that isn't one of the Microsoft service addresses it is allowed to reach. Check the server or address."
        }
    }
}
