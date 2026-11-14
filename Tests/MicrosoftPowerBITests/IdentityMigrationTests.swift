import XCTest
import FacetCore
import FacetCloud
@testable import MicrosoftPowerBI

/// The bundle identifier moved from `com.facet.app` to `io.github.edwardrem.AnalyticsDesktop`: settings and
/// Keychain items stored under the old one move to the new one, once, without overwriting newer values.
final class IdentityMigrationTests: XCTestCase {
    private var oldSuite = "", newSuite = ""

    override func setUp() {
        oldSuite = "IdentityMigrationTests.old.\(UUID().uuidString)"
        newSuite = "IdentityMigrationTests.new.\(UUID().uuidString)"
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: oldSuite)
        UserDefaults().removePersistentDomain(forName: newSuite)
    }

    func testInfoPlistAndAppIdentityAgreeOnTheIdentifier() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(AppIdentity.bundleIdentifier, "io.github.edwardrem.AnalyticsDesktop")
        XCTAssertEqual(AppIdentity.version(in: info), "0.9.0")
        XCTAssertEqual(AppIdentity.version(in: nil), "0.0.0", "outside a bundle every release counts as newer")
    }

    func testKeychainServicesLiveUnderTheNewIdentifier() {
        XCTAssertEqual(AssistantClient.keychainService, "io.github.edwardrem.AnalyticsDesktop.assistant")
        XCTAssertEqual(MicrosoftAccountManager.keychainService, "io.github.edwardrem.AnalyticsDesktop.microsoft")
        XCTAssertEqual(DataSourceCredentialStore.defaultService, "io.github.edwardrem.AnalyticsDesktop.datasources")
        XCTAssertEqual(Set(AppIdentity.legacyKeychainServices.values), ["com.facet.assistant", "com.facet.microsoft", "com.facet.datasources"])
    }

    func testSettingsAndSecretsMoveOnceAndNewerValuesWin() throws {
        let old = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        old.set("dark", forKey: "appearance")
        old.set(25, forKey: "autoRecoveryMinutes")
        old.set("old-config", forKey: "com.facet.assistant.configuration")
        let new = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        new.set(5, forKey: "autoRecoveryMinutes")       // already chosen in the new build
        new.register(defaults: ["appearance": "system"]) // a registered default is not a choice

        let oldAssistant = InMemorySecretStore(), newAssistant = InMemorySecretStore()
        try oldAssistant.setString("sk-old", account: "anthropic")
        let oldAccounts = InMemorySecretStore(), newAccounts = InMemorySecretStore()
        try oldAccounts.setString("refresh-old", account: "user-1")
        try oldAccounts.setString("refresh-stale", account: "user-2")
        try newAccounts.setString("refresh-new", account: "user-2")

        let outcome = IdentityMigration.migrate(into: newSuite, from: oldSuite,
                                                secrets: [(oldAssistant, newAssistant), (oldAccounts, newAccounts)])
        XCTAssertEqual(outcome, .init(settings: 2, secrets: 2, problems: []))
        let saved = UserDefaults().persistentDomain(forName: newSuite) ?? [:]
        XCTAssertEqual(saved["appearance"] as? String, "dark")
        XCTAssertEqual(saved["autoRecoveryMinutes"] as? Int, 5)
        XCTAssertEqual(saved["com.facet.assistant.configuration"] as? String, "old-config")
        XCTAssertEqual(UserDefaults().persistentDomain(forName: oldSuite)?.count ?? 0, 0, "the old domain is removed")

        XCTAssertEqual(try newAssistant.getString(account: "anthropic"), "sk-old")
        XCTAssertEqual(try newAccounts.getString(account: "user-1"), "refresh-old")
        XCTAssertEqual(try newAccounts.getString(account: "user-2"), "refresh-new")
        XCTAssertEqual(try oldAssistant.list(), [], "no secret lingers under the old service")
        XCTAssertEqual(try oldAccounts.list(), [])
        XCTAssertEqual(saved[IdentityMigration.doneKey] as? Bool, true)

        // A second launch does nothing, even if something reappeared under the old name.
        try oldAssistant.setString("sk-again", account: "anthropic")
        XCTAssertEqual(IdentityMigration.migrate(into: newSuite, from: oldSuite, secrets: [(oldAssistant, newAssistant)]), .init())
        XCTAssertEqual(try newAssistant.getString(account: "anthropic"), "sk-old")
    }

    func testAFailedMoveIsRetriedNextLaunch() throws {
        struct Refused: Error {}
        final class Locked: SecretStoring {
            func set(_ data: Data, account: String) throws { throw Refused() }
            func get(account: String) throws -> Data? { nil }
            func delete(account: String) throws {}
            func list() throws -> [String] { [] }
        }
        let old = InMemorySecretStore()
        try old.setString("secret", account: "a")
        let outcome = IdentityMigration.migrate(into: newSuite, from: oldSuite, secrets: [(old, Locked())])
        XCTAssertEqual(outcome.problems.count, 1)
        XCTAssertNil(UserDefaults().persistentDomain(forName: newSuite)?[IdentityMigration.doneKey])
        XCTAssertEqual(try old.getString(account: "a"), "secret", "nothing is deleted when the copy failed")
    }
}
