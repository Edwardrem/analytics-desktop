import Foundation
import FacetCore
import FacetQuery
import FacetCloud

/// How a data source signs in, as Power BI's credential dialog names it.
enum CredentialMethod: String, CaseIterable, Identifiable, Sendable {
    case anonymous, basic, apiKey, organizational, accountKey, sasToken
    var id: String { rawValue }

    var title: String {
        switch self {
        case .anonymous: return "Anonymous"
        case .basic: return "Basic"
        case .apiKey: return "Web API"
        case .organizational: return "Organizational account"
        case .accountKey: return "Account key"
        case .sasToken: return "Shared access signature (SAS)"
        }
    }

    /// The methods offered for a source kind (as the engine records kinds).
    static func offered(forKind kind: String) -> [CredentialMethod] {
        switch kind {
        case "Web", "OData": return [.anonymous, .basic, .apiKey, .organizational]
        case "AzureBlobs", "AzureDataLakeStorage": return [.organizational, .accountKey, .sasToken, .anonymous]
        case "SharePoint", "CommonDataService", "AzureDataExplorer", "AnalysisServices": return [.organizational]
        case "SQL", "PostgreSQL", "MySQL": return [.basic, .organizational]
        default: return [.anonymous, .basic, .organizational]
        }
    }

    init(_ kind: DataSourceCredential.Kind) {
        switch kind {
        case .anonymous: self = .anonymous
        case .usernamePassword: self = .basic
        case .apiKey: self = .apiKey
        case .microsoftAccount: self = .organizational
        case .accountKey: self = .accountKey
        case .sasToken: self = .sasToken
        case .connectionString: self = .basic
        }
    }
}

/// The app's `CredentialProvider`: data source credentials from the Keychain (service `com.facet.datasources`, one
/// item per kind + location), and Entra tokens from the Microsoft account manager, which checks every host against
/// its allow-list. Secrets are never logged; they stay in the Keychain and in this process's memory.
///
/// Key convention shared with the database connectors: kind as the engine records it ("Web", "SQL", "PostgreSQL"…)
/// and its location ("https://host/path", "server;database", "server"). A stored location also covers longer
/// locations that continue it at a boundary (`/`, `?`, `#`, `;`), and the longest match wins.
final class AppCredentials: CredentialProvider, @unchecked Sendable {
    static let shared = AppCredentials()

    private let store: DataSourceCredentialStore
    private let tokens: @Sendable (String, String) async throws -> String
    private let lock = NSLock()
    private var cache: [String: DataSourceCredential]?

    init(store: DataSourceCredentialStore = DataSourceCredentialStore(),
         tokens: (@Sendable (String, String) async throws -> String)? = nil) {
        self.store = store
        self.tokens = tokens ?? { resource, host in
            let manager = await MainActor.run { MicrosoftRuntime.shared.manager }
            return try await manager.accessToken(resource: resource, host: host)
        }
    }

    // MARK: CredentialProvider

    func credential(kind: String, location: String) -> SourceCredential? {
        guard let (_, stored) = bestMatch(kind: kind, location: location) else { return nil }
        return Self.engineCredential(stored, kind: kind, location: location)
    }

    func accessToken(resource: String, host: String) async throws -> String {
        try await tokens(resource, host)
    }

    /// The engine's view of a stored credential.
    static func engineCredential(_ c: DataSourceCredential, kind: String, location: String) -> SourceCredential? {
        switch c.kind {
        case .anonymous: return .anonymous
        case .usernamePassword: return .basic(username: c.username ?? "", password: c.secret ?? "")
        case .apiKey:
            let header = c.properties["headerName"].flatMap { $0.isEmpty ? nil : $0 }
            let parameter = c.properties["queryParameter"].flatMap { $0.isEmpty ? nil : $0 }
            return .apiKey(key: c.secret ?? "", headerName: header, queryParameter: header == nil ? parameter : nil)
        case .accountKey: return .accountKey(c.secret ?? "")
        case .sasToken: return .sasToken(c.secret ?? "")
        case .microsoftAccount: return .oauth(resource: c.properties["resource"] ?? defaultResource(kind: kind, location: location))
        case .connectionString: return nil
        }
    }

    /// The Entra resource an organizational account uses for a kind of source.
    static func defaultResource(kind: String, location: String) -> String {
        switch kind {
        case "SQL": return EntraResource.azureSQL
        case "PostgreSQL", "MySQL": return EntraResource.ossRDBMS
        case "AzureBlobs", "AzureDataLakeStorage": return EntraResource.storage
        case "CommonDataService": return EntraResource.dataverse(location)
        case "AzureDataExplorer": return EntraResource.kusto(location)
        case "AnalysisServices": return EntraResource.powerBI
        default: return EntraResource.origin(location) + "/.default"
        }
    }

    // MARK: Matching

    /// Whether a stored location covers a requested one (equal, or continued at a boundary). Case-insensitive.
    static func covers(_ stored: String, _ requested: String) -> Bool {
        let s = normalized(stored), r = normalized(requested)
        guard !s.isEmpty else { return false }
        if s == r { return true }
        guard r.hasPrefix(s) else { return false }
        if s.hasSuffix("/") { return true }
        let next = r[r.index(r.startIndex, offsetBy: s.count)]
        return "/?#;".contains(next)
    }

    static func normalized(_ location: String) -> String {
        var l = location.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while l.count > 1, l.hasSuffix("/") { l.removeLast() }
        return l
    }

    private func all() -> [String: DataSourceCredential] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        var loaded: [String: DataSourceCredential] = [:]
        for (kind, location) in (try? store.storedSources()) ?? [] {
            if let c = try? store.credential(kind: kind, location: location) {
                loaded[DataSourceCredentialStore.key(kind: kind, location: location)] = c
            }
        }
        cache = loaded
        return loaded
    }

    private func bestMatch(kind: String, location: String) -> (location: String, credential: DataSourceCredential)? {
        let wanted = kind.trimmingCharacters(in: .whitespaces).lowercased()
        var best: (String, DataSourceCredential)?
        for (key, c) in all() {
            guard let bar = key.firstIndex(of: "|"), key[..<bar] == wanted else { continue }
            let stored = String(key[key.index(after: bar)...])
            if Self.covers(stored, location), stored.count > (best?.0.count ?? -1) { best = (stored, c) }
        }
        return best
    }

    // MARK: Editing (Data source settings)

    /// The credential stored for exactly this source, or the one that covers it.
    func stored(kind: String, location: String) -> DataSourceCredential? { bestMatch(kind: kind, location: location)?.credential }

    func save(_ credential: DataSourceCredential, kind: String, location: String) throws {
        var c = credential
        c.properties["sourceKind"] = kind
        c.properties["sourceLocation"] = location
        try store.save(c, kind: kind, location: location)
        lock.lock(); cache = nil; lock.unlock()
    }

    func remove(kind: String, location: String) {
        try? store.remove(kind: kind, location: location)
        lock.lock(); cache = nil; lock.unlock()
    }

    func removeAll() {
        try? store.removeAll()
        lock.lock(); cache = nil; lock.unlock()
    }

    /// Every stored source (kind and location as stored, lower-cased), for Global permissions.
    var storedSources: [QueryDataSource] {
        all().sorted { $0.key < $1.key }.compactMap { key, c in
            guard let bar = key.firstIndex(of: "|") else { return nil }
            return QueryDataSource(kind: c.properties["sourceKind"] ?? String(key[..<bar]),
                                   location: c.properties["sourceLocation"] ?? String(key[key.index(after: bar)...]))
        }
    }

    /// "Basic", "Organizational account"…, or "Anonymous" when nothing is stored.
    func methodTitle(kind: String, location: String) -> String {
        if let c = stored(kind: kind, location: location) { return CredentialMethod(c.kind).title }
        return CredentialMethod.offered(forKind: kind).first == .organizational ? CredentialMethod.organizational.title : CredentialMethod.anonymous.title
    }
}
