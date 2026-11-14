import SwiftUI
import Combine
import FacetCore
import FacetCloud

/// The cloud clients for one Microsoft cloud, all drawing tokens from the account manager.
struct CloudServices {
    let graph: GraphClient
    let powerBI: PowerBIClient
    let fabric: FabricClient
    var sync: CloudDocumentSync { CloudDocumentSync(graph: graph) }
    var publisher: PowerBIPublisher { PowerBIPublisher(fabric: fabric, powerBI: powerBI) }

    init(cloud: MicrosoftCloud, tokens: AccessTokenProviding, session: URLSessionConfiguration? = nil) {
        graph = GraphClient(tokenProvider: tokens, cloud: cloud, sessionConfiguration: session)
        powerBI = PowerBIClient(tokenProvider: tokens, cloud: cloud, sessionConfiguration: session)
        fabric = FabricClient(tokenProvider: tokens, cloud: cloud, sessionConfiguration: session)
    }
}

/// The app's Microsoft account stack: one account manager (sign-in, tokens in the Keychain) built on the user's own
/// Entra app registration, and the Graph / Power BI / Fabric clients for the configured cloud.
@MainActor
final class MicrosoftRuntime: ObservableObject {
    static let shared = MicrosoftRuntime()
    /// Where an earlier build kept the client id; read once and moved into the manager's configuration.
    static let legacyClientIDKey = "com.facet.entraClientID"

    let manager: MicrosoftAccountManager
    @Published private(set) var services: CloudServices
    private var observers: Set<AnyCancellable> = []

    init(manager: MicrosoftAccountManager? = nil, defaults: UserDefaults = .standard) {
        let m = manager ?? MicrosoftAccountManager(defaults: defaults)
        if !m.configuration.isConfigured, let legacy = defaults.string(forKey: Self.legacyClientIDKey),
           EntraRegistration.isClientID(legacy) {
            m.configuration.clientID = legacy
            defaults.removeObject(forKey: Self.legacyClientIDKey)
        }
        self.manager = m
        services = CloudServices(cloud: m.configuration.cloud, tokens: m)
        m.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        m.$configuration.map(\.cloud).removeDuplicates().dropFirst().sink { [weak self, weak m] cloud in
            guard let self, let m else { return }
            self.services = CloudServices(cloud: cloud, tokens: m)
        }.store(in: &observers)
    }

    var isConfigured: Bool { manager.configuration.isConfigured }
    var accounts: [MicrosoftAccount] { manager.accounts }
    var activeAccount: MicrosoftAccount? { manager.activeAccount }
    var isSignedIn: Bool { activeAccount != nil }
    /// Power BI, Fabric and sensitivity labels need a work or school account.
    var hasWorkAccount: Bool { activeAccount.map { !$0.isPersonal } ?? false }

    /// Validates and stores the app registration. Signing in again is needed only when the client or tenant changed.
    func updateRegistration(clientID: String, tenant: String, cloud: MicrosoftCloud) throws {
        let problems = EntraRegistration.problems(clientID: clientID, tenant: tenant)
        guard problems.isEmpty else { throw EntraRegistration.Invalid(problems: problems) }
        manager.configuration = MicrosoftAuthConfiguration(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           tenant: EntraRegistration.normalizedTenant(tenant), cloud: cloud)
    }
}

/// Checks on the Entra app registration the user types in. These are user defaults, never secrets.
enum EntraRegistration {
    struct Invalid: LocalizedError, Equatable {
        let problems: [String]
        var errorDescription: String? { problems.joined(separator: " ") }
    }

    static let redirectURI = "http://localhost"
    static let adminCenter = URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")

    /// An application (client) id is a GUID.
    static func isClientID(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count == 36 && UUID(uuidString: t) != nil
    }

    /// `common`, `organizations`, `consumers`, a tenant GUID, or a verified domain such as `contoso.onmicrosoft.com`.
    static func isTenant(_ s: String) -> Bool {
        let t = normalizedTenant(s)
        if ["common", "organizations", "consumers"].contains(t) { return true }
        if t.count == 36, UUID(uuidString: t) != nil { return true }
        let labels = t.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, t.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        }
    }

    static func normalizedTenant(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? "common" : t
    }

    static func problems(clientID: String, tenant: String) -> [String] {
        var out: [String] = []
        if !isClientID(clientID) {
            out.append("The application (client) ID is a GUID such as 00000000-0000-0000-0000-000000000000; copy it from the app's Overview page.")
        }
        if !isTenant(tenant) {
            out.append("The tenant is “common”, “organizations”, “consumers”, a tenant ID or a domain such as contoso.onmicrosoft.com.")
        }
        return out
    }
}

/// Turns sign-in and cloud errors into text that says what to do.
enum AccountMessages {
    /// Guidance for identity-platform error codes people meet while setting up their own app registration.
    static let guidance: [(code: String, advice: String)] = [
        ("AADSTS50011", "Add the redirect URI \(EntraRegistration.redirectURI) to the app registration under Authentication ▸ Mobile and desktop applications."),
        ("AADSTS7000218", "Turn on “Allow public client flows” under Authentication ▸ Advanced settings in the app registration."),
        ("AADSTS700016", "The application ID wasn't found in that tenant. Check the client ID, and set the tenant to “common” for an app that accepts any account."),
        ("AADSTS90002", "That tenant doesn't exist. Check the tenant in Settings ▸ Microsoft account."),
        ("AADSTS50020", "This account isn't in the app's tenant. Use the tenant “common”, or sign in with an account from that tenant."),
        ("AADSTS65001", "The app hasn't been granted the permissions it asks for. Sign in again and accept, or ask an administrator to grant consent."),
        ("AADSTS70011", "The app registration is missing a permission. Add the Microsoft Graph and Power BI delegated permissions listed in the registration steps."),
        ("AADSTS50076", "Your organization requires multi-factor authentication; finish it in the browser."),
        ("AADSTS53003", "A Conditional Access policy blocked the sign-in. Ask your administrator which devices or locations are allowed."),
    ]

    static func describe(_ error: Error) -> String {
        let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case MicrosoftAuthError.service(_, let description, _) = error,
           let hit = guidance.first(where: { description.contains($0.code) }) {
            return base + " " + hit.advice
        }
        if let api = error as? CloudAPIError {
            switch api.kind {
            case .unauthorized:
                return base + " Sign in again from the Account menu."
            case .forbidden where api.service == "Power BI" || api.service == "Fabric":
                return base + " Check that the app registration has the Power BI and Fabric delegated permissions, and that you have access to the workspace."
            default: break
            }
        }
        return base
    }

    /// Two-letter initials for an account without a photo.
    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" }.filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
