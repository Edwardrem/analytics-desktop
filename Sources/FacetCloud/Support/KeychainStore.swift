import Foundation
import FacetCore
import Security

/// A failure reported by the macOS Keychain.
public struct KeychainError: LocalizedError, Equatable {
    public let status: OSStatus
    public let operation: String
    public var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(detail)"
    }
}

/// Minimal secret storage abstraction so token logic can be exercised against an in-memory store.
public protocol SecretStoring: AnyObject {
    func set(_ data: Data, account: String) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
    /// All account names stored under this store's service.
    func list() throws -> [String]
}

public extension SecretStoring {
    func setString(_ value: String, account: String) throws { try set(Data(value.utf8), account: account) }
    func getString(account: String) throws -> String? {
        try get(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }
    func setCodable<T: Encodable>(_ value: T, account: String) throws {
        try set(JSONEncoder().encode(value), account: account)
    }
    func getCodable<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try get(account: account) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    /// Deletes every item stored under this store's service.
    func removeAll() throws { for a in try list() { try delete(account: a) } }
}

/// Generic-password Keychain storage scoped to one service name.
///
/// Items are stored in the user's login keychain, readable only by this app (and by the user through
/// Keychain Access). Values are never written to disk in plain text by this type and never logged.
public final class KeychainStore: SecretStoring {
    public let service: String

    public init(service: String) { self.service = service }

    private func baseQuery(account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func set(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Facet (\(service))"
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "write") }
    }

    public func get(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "read") }
        return out as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    public func list() throws -> [String] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "list") }
        let items = (out as? [[String: Any]]) ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// Process-local secret storage. Used by the self-check and available to previews/tests; nothing is persisted.
public final class InMemorySecretStore: SecretStoring {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func set(_ data: Data, account: String) throws { lock.lock(); items[account] = data; lock.unlock() }
    public func get(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func delete(account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    public func list() throws -> [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
}

// MARK: - Data source credentials

/// A stored credential for a data source. The whole value is kept in the Keychain as one JSON blob.
public struct DataSourceCredential: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case anonymous, usernamePassword, apiKey, accountKey, connectionString
        /// Azure Storage shared access signature (the query string).
        case sasToken
        /// Uses a signed-in Microsoft account; `username` holds the account id, there is no secret.
        case microsoftAccount
    }
    public var kind: Kind
    public var username: String?
    /// Password, API key, account key, or the secret-bearing connection string, depending on `kind`.
    public var secret: String?
    /// Non-secret extras (e.g. "database", "role", "headerName").
    public var properties: [String: String]

    public init(kind: Kind, username: String? = nil, secret: String? = nil, properties: [String: String] = [:]) {
        self.kind = kind; self.username = username; self.secret = secret; self.properties = properties
    }
    public static func usernamePassword(_ username: String, _ password: String) -> DataSourceCredential {
        DataSourceCredential(kind: .usernamePassword, username: username, secret: password)
    }
    public static func apiKey(_ key: String) -> DataSourceCredential { DataSourceCredential(kind: .apiKey, secret: key) }
    public static func accountKey(_ key: String) -> DataSourceCredential { DataSourceCredential(kind: .accountKey, secret: key) }
    public static func connectionString(_ s: String) -> DataSourceCredential { DataSourceCredential(kind: .connectionString, secret: s) }
}

/// Keychain-backed credential storage for data sources, keyed by source kind + location
/// (matching `DataSourceRecord.kind` / `.location` in FacetCore).
public final class DataSourceCredentialStore {
    public static let defaultService = AppIdentity.keychainService("datasources")
    private let store: SecretStoring

    public init(store: SecretStoring = KeychainStore(service: DataSourceCredentialStore.defaultService)) {
        self.store = store
    }

    /// The Keychain account name used for a source. Kind and location are case-insensitive; a trailing "/" is ignored.
    public static func key(kind: String, location: String) -> String {
        var loc = location.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while loc.count > 1, loc.hasSuffix("/") { loc.removeLast() }
        return kind.trimmingCharacters(in: .whitespaces).lowercased() + "|" + loc
    }

    public func save(_ credential: DataSourceCredential, kind: String, location: String) throws {
        try store.setCodable(credential, account: Self.key(kind: kind, location: location))
    }
    public func credential(kind: String, location: String) throws -> DataSourceCredential? {
        try store.getCodable(DataSourceCredential.self, account: Self.key(kind: kind, location: location))
    }
    public func remove(kind: String, location: String) throws {
        try store.delete(account: Self.key(kind: kind, location: location))
    }
    /// All stored (kind, location) pairs, for a "Data source settings" list.
    public func storedSources() throws -> [(kind: String, location: String)] {
        try store.list().compactMap { key in
            guard let bar = key.firstIndex(of: "|") else { return nil }
            return (String(key[..<bar]), String(key[key.index(after: bar)...]))
        }
    }
    public func removeAll() throws { try store.removeAll() }
}
