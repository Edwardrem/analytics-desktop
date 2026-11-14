import Foundation

/// The product's own name, in one place. Use it wherever text means this app. "Power BI" stays only
/// where it names Microsoft's service, its REST API or its file formats (.pbix, .pbit, .pbip).
public enum AppIdentity {
    public static let name = "Analytics Desktop"

    /// The bundle identifier. `Resources/Info.plist` carries the same value (a test keeps the two equal).
    public static let bundleIdentifier = "io.github.edwardrem.AnalyticsDesktop"
    /// The identifier builds before 0.9.0 used: their settings and Keychain items are moved on first launch.
    public static let legacyBundleIdentifier = "com.facet.app"

    /// The marketing version (`CFBundleShortVersionString`), set from the release tag. "0.0.0" when the
    /// code runs outside an app bundle (tests, `swift run`), so every published release counts as newer.
    public static var version: String { version(in: Bundle.main.infoDictionary) }
    /// The build number (`CFBundleVersion`).
    public static var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev" }

    public static func version(in info: [String: Any]?) -> String {
        let v = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? "0.0.0" : v
    }

    /// The Keychain service for one kind of secret, under this app's identifier.
    public static func keychainService(_ purpose: String) -> String { bundleIdentifier + "." + purpose }

    /// Keychain services used before the identifier changed, by purpose (see `keychainService(_:)`).
    public static let legacyKeychainServices: [String: String] = [
        "assistant": "com.facet.assistant",
        "microsoft": "com.facet.microsoft",
        "datasources": "com.facet.datasources",
    ]
}
