import Foundation
import FacetCore

/// A stored credential for a data source. Secrets come from the app's Keychain-backed `CredentialProvider`.
public enum SourceCredential: Sendable {
    case anonymous
    /// HTTP basic auth, or database user/password.
    case basic(username: String, password: String)
    /// API key sent as a header (default `Authorization` is NOT assumed: `headerName` is required) or as a query parameter.
    case apiKey(key: String, headerName: String?, queryParameter: String?)
    /// A ready-made bearer token.
    case bearer(token: String)
    /// Azure storage shared key.
    case accountKey(String)
    /// Azure storage SAS token (query string, with or without the leading `?`).
    case sasToken(String)
    /// Organizational account: ask the provider for an Entra token for the resource
    /// (`AccessTokenProvider.accessToken(resource:host:)`).
    case oauth(resource: String)
}

/// Microsoft Entra resources (token audiences, as `/.default` scopes) that connectors ask for.
/// These are the global-cloud identifiers; the app's provider maps them for national clouds.
public enum EntraResource {
    public static let graph = "https://graph.microsoft.com/.default"
    public static let powerBI = "https://analysis.windows.net/powerbi/api/.default"
    /// Azure SQL Database, Synapse SQL and Fabric warehouse / SQL analytics endpoints.
    public static let azureSQL = "https://database.windows.net/.default"
    /// Azure Blob Storage, ADLS Gen2 and OneLake.
    public static let storage = "https://storage.azure.com/.default"
    /// Azure Database for PostgreSQL and MySQL (flexible server).
    public static let ossRDBMS = "https://ossrdbms-aad.database.windows.net/.default"
    /// A Dataverse environment, e.g. `https://contoso.crm.dynamics.com`.
    public static func dataverse(_ environmentURL: String) -> String { origin(environmentURL) + "/.default" }
    /// An Azure Data Explorer cluster, e.g. `https://help.kusto.windows.net`.
    public static func kusto(_ clusterURL: String) -> String { origin(clusterURL) + "/.default" }
    /// A SharePoint Online tenant, e.g. `https://contoso.sharepoint.com`.
    public static func sharePoint(_ siteURL: String) -> String { origin(siteURL) + "/.default" }

    /// `https://host` of an address (scheme and host, lower-cased; no path, port, query or user).
    public static func origin(_ url: String) -> String {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let host = URLComponents(string: withScheme)?.host?.lowercased(), !host.isEmpty else { return text.lowercased() }
        return "https://" + host
    }
}

/// Supplies Microsoft Entra access tokens to connectors. The app implements it on top of its Microsoft sign-in.
///
/// Every caller names the host the token will be sent to. Implementations must refuse (throw) when that host is not
/// on their allow-list for the resource, so a token can never be handed to a look-alike or unrelated host.
/// Never log, trace or put the token in an error message.
public protocol AccessTokenProvider: Sendable {
    /// An access token for `resource` (an `EntraResource` value or any `<resource>/.default` scope), to be sent only
    /// to `host` over https.
    func accessToken(resource: String, host: String) async throws -> String
}

/// Supplies stored data-source credentials and Entra tokens to the query engine. The app implements this on top of
/// the Keychain and its Microsoft sign-in.
public protocol CredentialProvider: AccessTokenProvider {
    /// Stored credential for a source, e.g. kind "Web" + location "https://api.example.com", kind "PostgreSQL" + "host/db".
    /// Implementations match on the longest location prefix that ends at a host or path boundary.
    func credential(kind: String, location: String) -> SourceCredential?
}

/// A request to approve a hand-written native database query.
public struct NativeQueryRequest: Sendable {
    public var query: String
    public var sourceKind: String
    public var sourceLocation: String
    public init(query: String, sourceKind: String, sourceLocation: String) {
        self.query = query; self.sourceKind = sourceKind; self.sourceLocation = sourceLocation
    }
}

/// Everything the engine needs from its host: file base, credentials, privacy and security settings, culture, clock.
public struct QueryEnvironment: Sendable {
    /// Relative file paths in M resolve against this directory.
    public var baseDirectory: URL?
    public var credentials: CredentialProvider?
    /// Privacy level per source. Keys are `"Kind:location"` or a bare location / location prefix (longest match wins).
    public var privacyLevels: [String: PrivacyLevel] = [:]
    public var enforcePrivacyFirewall = false
    public var requireNativeQueryApproval = false
    /// Called when `requireNativeQueryApproval` is on and a native query is about to run; return true to allow.
    public var approveNativeQuery: (@Sendable (NativeQueryRequest) -> Bool)?
    /// Python/R scripts only run when true (the app shows its security prompt first).
    public var allowScripts = false
    public var pythonPath: String?
    public var rPath: String?
    /// Default culture for conversions and formatting, e.g. "en-US".
    public var culture = "en-US"
    /// Clock used by `DateTime.LocalNow` and the `IsInCurrent*` family (injectable for tests).
    public var now: @Sendable () -> Date = { Date() }
    /// Time zone for "local" date-times.
    public var timeZone: TimeZone = .current
    /// Default network timeout in seconds for web sources.
    public var networkTimeout: TimeInterval = 100
    /// Extra directories searched for command-line database clients (psql, mysql, sqlcmd, isql) before PATH and Homebrew.
    public var toolSearchPaths: [String] = []
    /// Database servers (lower-cased host names) whose TLS certificate is not verified ("Trust server certificate",
    /// set per source by the user after a warning). Every other server's certificate must be valid for its name.
    public var trustServerCertificateHosts: Set<String> = []
    /// Largest file (or decompressed archive entry) a file connector will read, in bytes. Larger inputs fail with a clear error.
    public var maxSourceBytes: Int = 4 << 30

    public init(baseDirectory: URL? = nil, credentials: CredentialProvider? = nil) {
        self.baseDirectory = baseDirectory; self.credentials = credentials
    }

    /// An Entra access token for `resource`, to be sent only to `host` (see `AccessTokenProvider`).
    /// Database connectors (Azure SQL, Fabric SQL endpoints, Azure PostgreSQL / MySQL) call this with
    /// `EntraResource.azureSQL` or `.ossRDBMS` and the server's host name.
    public func accessToken(resource: String, host: String) async throws -> String {
        guard let credentials else {
            throw MError.dataSource("Sign in with a Microsoft account to access '\(host)'; no credential provider is configured.")
        }
        return try await credentials.accessToken(resource: resource, host: host)
    }

    /// The privacy level configured for a source (`.none` when unclassified).
    public func privacyLevel(kind: String, location: String) -> PrivacyLevel {
        if let l = privacyLevels["\(kind):\(location)"] { return l }
        if let l = privacyLevels[location] { return l }
        var best: (Int, PrivacyLevel)?
        for (key, level) in privacyLevels {
            let k = key.hasPrefix("\(kind):") ? String(key.dropFirst(kind.count + 1)) : key
            if !k.isEmpty, location.hasPrefix(k), k.count > (best?.0 ?? 0) { best = (k.count, level) }
        }
        return best?.1 ?? .none
    }

    /// "Local now" as a wall-clock `datetime` (the instant shifted into `timeZone`, stored as UTC).
    public func localNow() -> Date {
        let n = now()
        return n.addingTimeInterval(Double(timeZone.secondsFromGMT(for: n)))
    }
}
