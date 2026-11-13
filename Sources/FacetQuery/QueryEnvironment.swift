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
    /// Ask the provider for an OAuth token for the resource (`CredentialProvider.accessToken(resource:)`).
    case oauth(resource: String)
}

/// Supplies credentials to the query engine. The app implements this on top of the Keychain / its sign-in flow.
public protocol CredentialProvider: Sendable {
    /// Stored credential for a source, e.g. kind "Web" + location "https://api.example.com", kind "PostgreSQL" + "host/db".
    /// Implementations should match on the longest location prefix.
    func credential(kind: String, location: String) -> SourceCredential?
    /// An OAuth bearer token for a resource such as "https://analysis.windows.net/powerbi/api" or "https://graph.microsoft.com".
    func accessToken(resource: String) async throws -> String
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
    /// Largest file (or decompressed archive entry) a file connector will read, in bytes. Larger inputs fail with a clear error.
    public var maxSourceBytes: Int = 4 << 30

    public init(baseDirectory: URL? = nil, credentials: CredentialProvider? = nil) {
        self.baseDirectory = baseDirectory; self.credentials = credentials
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
