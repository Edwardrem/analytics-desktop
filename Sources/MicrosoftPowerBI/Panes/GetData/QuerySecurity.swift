import Foundation
import FacetCore
import FacetQuery

/// A source the user connected to recently (Recent Sources).
struct RecentSource: Codable, Identifiable, Hashable {
    var kind: SourceKind
    var location: String
    var lastUsed: Date
    var id: String { kind.rawValue + "|" + location }

    var displayName: String {
        switch kind {
        case .web, .odata: return location
        case .python, .r: return location.split(whereSeparator: \.isNewline).first.map(String.init) ?? location
        default: return (location as NSString).lastPathComponent
        }
    }
}

/// Per-user data source permissions, as Power BI keeps them outside the report file: privacy levels, approved
/// native database queries, the script permission and the recent sources list. Backed by `UserDefaults`.
final class QuerySecurity: @unchecked Sendable {
    static let shared = QuerySecurity()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private enum Key {
        static let privacy = "query.privacyLevels"
        static let ignorePrivacy = "query.ignorePrivacyLevels"
        static let nativeQueries = "query.approvedNativeQueries"
        static let scripts = "query.allowScripts"
        static let recent = "query.recentSources"
    }
    static let maxRecentSources = 20

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func sourceKey(kind: String, location: String) -> String { "\(kind):\(location)" }

    // MARK: Privacy

    /// Privacy level per source, keyed `"Kind:location"`.
    var privacyLevels: [String: PrivacyLevel] {
        get {
            lock.lock(); defer { lock.unlock() }
            let raw = defaults.dictionary(forKey: Key.privacy) as? [String: String] ?? [:]
            return raw.compactMapValues(PrivacyLevel.init(rawValue:))
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(newValue.filter { $0.value != .none }.mapValues(\.rawValue), forKey: Key.privacy)
        }
    }
    func privacyLevel(kind: String, location: String) -> PrivacyLevel {
        privacyLevels[Self.sourceKey(kind: kind, location: location)] ?? .none
    }
    func setPrivacyLevel(_ level: PrivacyLevel, kind: String, location: String) {
        var all = privacyLevels
        all[Self.sourceKey(kind: kind, location: location)] = level == .none ? nil : level
        privacyLevels = all
    }
    /// "Ignore the Privacy Levels and potentially improve performance".
    var ignorePrivacyLevels: Bool {
        get { defaults.bool(forKey: Key.ignorePrivacy) }
        set { defaults.set(newValue, forKey: Key.ignorePrivacy) }
    }

    // MARK: Native queries

    private static func queryKey(_ query: String, kind: String, location: String) -> String {
        sourceKey(kind: kind, location: location) + "\n" + query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var approvedQueries: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return Set(defaults.stringArray(forKey: Key.nativeQueries) ?? []) }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue.sorted(), forKey: Key.nativeQueries) }
    }
    func isApproved(query: String, kind: String, location: String) -> Bool {
        approvedQueries.contains(Self.queryKey(query, kind: kind, location: location))
    }
    func approve(query: String, kind: String, location: String) {
        approvedQueries.insert(Self.queryKey(query, kind: kind, location: location))
    }
    func approvedQueryCount(kind: String, location: String) -> Int {
        let prefix = Self.sourceKey(kind: kind, location: location) + "\n"
        return approvedQueries.filter { $0.hasPrefix(prefix) }.count
    }

    // MARK: Scripts

    /// Python and R steps run only after the user allowed script execution.
    var allowScripts: Bool {
        get { defaults.bool(forKey: Key.scripts) }
        set { defaults.set(newValue, forKey: Key.scripts) }
    }

    // MARK: Clearing

    /// Forget the privacy level and approved native queries of one source.
    func clearPermissions(kind: String, location: String) {
        setPrivacyLevel(.none, kind: kind, location: location)
        let prefix = Self.sourceKey(kind: kind, location: location) + "\n"
        approvedQueries = approvedQueries.filter { !$0.hasPrefix(prefix) }
    }
    func clearAllPermissions() {
        privacyLevels = [:]
        approvedQueries = []
        allowScripts = false
    }
    /// Sources that have a stored permission (privacy level or approved query).
    var sourcesWithPermissions: [QueryDataSource] {
        var keys = Set(privacyLevels.keys)
        for q in approvedQueries { if let k = q.split(separator: "\n", maxSplits: 1).first { keys.insert(String(k)) } }
        return keys.sorted().compactMap { key in
            guard let colon = key.firstIndex(of: ":") else { return nil }
            return QueryDataSource(kind: String(key[..<colon]), location: String(key[key.index(after: colon)...]))
        }
    }

    // MARK: Recent sources

    var recentSources: [RecentSource] {
        get {
            lock.lock(); defer { lock.unlock() }
            guard let data = defaults.data(forKey: Key.recent) else { return [] }
            return (try? JSONDecoder().decode([RecentSource].self, from: data)) ?? []
        }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.recent)
        }
    }
    /// Put a source at the top of the recent list (one entry per source, newest first, capped).
    func noteRecent(kind: SourceKind, location: String, at date: Date = Date()) {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .blank, !trimmed.isEmpty else { return }
        let entry = RecentSource(kind: kind, location: trimmed, lastUsed: date)
        var list = recentSources.filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        recentSources = Array(list.prefix(Self.maxRecentSources))
    }
    func removeRecent(_ source: RecentSource) { recentSources = recentSources.filter { $0.id != source.id } }

    // MARK: Environment

    /// The engine environment for this user: privacy levels with the firewall, native queries limited to the
    /// approved ones, scripts only when allowed.
    func environment(baseDirectory: URL?) -> QueryEnvironment {
        var env = QueryEnvironment(baseDirectory: baseDirectory)
        env.privacyLevels = privacyLevels
        env.enforcePrivacyFirewall = !ignorePrivacyLevels
        env.requireNativeQueryApproval = true
        let approved = approvedQueries
        env.approveNativeQuery = { request in
            approved.contains(Self.queryKey(request.query, kind: request.sourceKind, location: request.sourceLocation))
        }
        env.allowScripts = allowScripts
        return env
    }

}

extension QueryEnvironment {
    /// The environment every evaluation in the app uses (see `QuerySecurity.environment`).
    static func app(baseDirectory: URL?) -> QueryEnvironment { QuerySecurity.shared.environment(baseDirectory: baseDirectory) }
}
