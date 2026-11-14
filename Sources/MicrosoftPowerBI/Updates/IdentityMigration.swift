import Foundation
import FacetCore
import FacetCloud

/// Moves what builds before 0.9.0 stored under the old bundle identifier (`com.facet.app`) to the new one:
/// the user defaults domain, and the Keychain items kept under the old service names. Runs once, at launch,
/// before any setting or secret is read; it runs again on a later launch if anything failed to move.
enum IdentityMigration {
    /// Set in the new defaults once everything has moved.
    static let doneKey = "identityMigration.fromComFacetApp"

    struct Outcome: Equatable {
        var settings = 0
        var secrets = 0
        var problems: [String] = []
    }

    /// The real migration, only when running as the bundled app under the new identifier: tests and
    /// `swift run` never touch the user's preferences or Keychain.
    static func runAtLaunch() {
        guard Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier else { return }
        let stores = AppIdentity.legacyKeychainServices.map { purpose, old in
            (old: KeychainStore(service: old) as SecretStoring, new: KeychainStore(service: AppIdentity.keychainService(purpose)) as SecretStoring)
        }
        _ = migrate(into: AppIdentity.bundleIdentifier, from: AppIdentity.legacyBundleIdentifier, secrets: stores)
    }

    /// Copies the legacy defaults domain into the new one (values already saved there win; registered
    /// defaults don't count), moves each legacy Keychain item to its new service (an item already under the
    /// new service wins), then removes the old copies. `domains` reads and writes persistent domains by name.
    @discardableResult
    static func migrate(into newDomain: String, from legacyDomain: String,
                        secrets: [(old: SecretStoring, new: SecretStoring)],
                        domains: UserDefaults = UserDefaults()) -> Outcome {
        var outcome = Outcome()
        var current = domains.persistentDomain(forName: newDomain) ?? [:]
        guard (current[doneKey] as? Bool) != true else { return outcome }

        if let old = domains.persistentDomain(forName: legacyDomain), !old.isEmpty {
            for (key, value) in old where current[key] == nil {
                current[key] = value
                outcome.settings += 1
            }
            domains.setPersistentDomain(current, forName: newDomain)
            domains.removePersistentDomain(forName: legacyDomain)
        }

        for pair in secrets {
            do { outcome.secrets += try moveSecrets(from: pair.old, to: pair.new) }
            catch { outcome.problems.append(error.localizedDescription) }
        }
        if outcome.problems.isEmpty {
            current[doneKey] = true
            domains.setPersistentDomain(current, forName: newDomain)
        }
        return outcome
    }

    /// Moves every item of one store into another. Returns how many were copied.
    static func moveSecrets(from old: SecretStoring, to new: SecretStoring) throws -> Int {
        var copied = 0
        for account in try old.list() {
            guard let data = try old.get(account: account) else { continue }
            if try new.get(account: account) == nil {
                try new.set(data, account: account)
                copied += 1
            }
            try old.delete(account: account)
        }
        return copied
    }
}
