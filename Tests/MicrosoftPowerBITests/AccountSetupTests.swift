import XCTest
import FacetCore
@testable import FacetCloud
@testable import MicrosoftPowerBI

/// Settings ▸ Microsoft account: the registration the user enters, and the guidance shown when sign-in fails.
@MainActor
final class AccountSetupTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "account-setup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func runtime() -> MicrosoftRuntime {
        MicrosoftRuntime(manager: MicrosoftAccountManager(secrets: InMemorySecretStore(), defaults: defaults), defaults: defaults)
    }

    func testClientIDsAreGUIDsAndTenantsAreKnownFormsOrDomains() {
        XCTAssertTrue(EntraRegistration.isClientID("1950a258-227b-4e31-a9cf-717495945fc2"))
        XCTAssertTrue(EntraRegistration.isClientID("  1950A258-227B-4E31-A9CF-717495945FC2 "))
        XCTAssertFalse(EntraRegistration.isClientID("1950a258227b4e31a9cf717495945fc2"), "the hyphens are part of the id")
        XCTAssertFalse(EntraRegistration.isClientID("my-app"))
        for ok in ["", "common", "Organizations", "consumers", "72f988bf-86f1-41af-91ab-2d7cd011db47", "contoso.onmicrosoft.com", "fabrikam.co.za"] {
            XCTAssertTrue(EntraRegistration.isTenant(ok), ok)
        }
        for bad in ["contoso", "contoso..com", "-contoso.com", "contoso.com/../x", "con toso.com", "contoso.com?x=1", "ex%61mple.com"] {
            XCTAssertFalse(EntraRegistration.isTenant(bad), bad)
        }
        XCTAssertEqual(EntraRegistration.normalizedTenant("  Contoso.OnMicrosoft.com "), "contoso.onmicrosoft.com")
        XCTAssertEqual(EntraRegistration.normalizedTenant(""), "common")
        XCTAssertEqual(EntraRegistration.problems(clientID: "x", tenant: "contoso").count, 2)
    }

    func testTheRegistrationIsStoredAsPreferencesNotSecrets() throws {
        let rt = runtime()
        XCTAssertFalse(rt.isConfigured)
        XCTAssertThrowsError(try rt.updateRegistration(clientID: "not-a-guid", tenant: "common", cloud: .public))
        XCTAssertFalse(rt.isConfigured)
        try rt.updateRegistration(clientID: " 1950a258-227b-4e31-a9cf-717495945fc2 ", tenant: "Contoso.com", cloud: .usGovernment)
        XCTAssertTrue(rt.isConfigured)
        let saved = MicrosoftAuthConfiguration.load(from: defaults)
        XCTAssertEqual(saved, MicrosoftAuthConfiguration(clientID: "1950a258-227b-4e31-a9cf-717495945fc2", tenant: "contoso.com", cloud: .usGovernment))
        // The clients follow the cloud.
        XCTAssertEqual(rt.services.graph.cloud, .usGovernment)
        XCTAssertEqual(rt.services.powerBI.cloud, .usGovernment)
    }

    func testAnEarlierBuildsClientIDIsMovedOnce() {
        defaults.set("1950a258-227b-4e31-a9cf-717495945fc2", forKey: MicrosoftRuntime.legacyClientIDKey)
        let rt = runtime()
        XCTAssertEqual(rt.manager.configuration.clientID, "1950a258-227b-4e31-a9cf-717495945fc2")
        XCTAssertNil(defaults.string(forKey: MicrosoftRuntime.legacyClientIDKey))
        // A malformed leftover is not adopted.
        defaults.set("garbage", forKey: MicrosoftRuntime.legacyClientIDKey)
        defaults.removeObject(forKey: MicrosoftAuthConfiguration.defaultsKey)
        XCTAssertFalse(runtime().isConfigured)
    }

    func testRegistrationMistakesComeWithTheFix() {
        let redirect = MicrosoftAuthError.service(code: "invalid_request",
            description: "AADSTS50011: The redirect URI 'http://localhost:51234' specified in the request does not match.", correlationID: "c1")
        XCTAssertTrue(AccountMessages.describe(redirect).contains("Mobile and desktop applications"))
        let publicClient = MicrosoftAuthError.service(code: "invalid_client",
            description: "AADSTS7000218: The request body must contain the following parameter: 'client_assertion' or 'client_secret'.", correlationID: nil)
        XCTAssertTrue(AccountMessages.describe(publicClient).contains("Allow public client flows"))
        XCTAssertTrue(AccountMessages.describe(MicrosoftAuthError.clientIDMissing).contains("http://localhost"))
        XCTAssertTrue(AccountMessages.describe(MicrosoftAuthError.clientIDMissing).contains("Files.ReadWrite.All"))
        let forbidden = CloudAPIError(service: "Power BI", kind: .forbidden, statusCode: 403, message: "Unauthorized")
        XCTAssertTrue(AccountMessages.describe(forbidden).contains("Power BI and Fabric delegated permissions"))
        let plain = CloudAPIError(service: "Microsoft Graph", kind: .notFound, statusCode: 404, message: "Item not found")
        XCTAssertEqual(AccountMessages.describe(plain), plain.errorDescription)
    }

    func testInitialsForAccountsWithoutAPhoto() {
        XCTAssertEqual(AccountMessages.initials("Rufaro Mutepfa"), "RM")
        XCTAssertEqual(AccountMessages.initials("ana.lopes@contoso.com"), "AL")
        XCTAssertEqual(AccountMessages.initials("Prince"), "P")
        XCTAssertEqual(AccountMessages.initials("  "), "?")
    }

    func testAccountCommandsAndTheToolbarAreRegistered() {
        Features.registerAll()
        for id in ["account.signIn", "account.signOut", "account.settings", "account.openFromCloud", "account.saveToOneDrive",
                   "account.shareLink", "account.catalog", "account.publish", "account.sensitivity"] {
            XCTAssertNotNil(AppCommands.command(id), id)
        }
        let store = DocumentStore(services: .live())
        XCTAssertEqual(AppCommands.command("account.shareLink")?.isEnabled(store), false, "a local document has no link to share")
    }
}
