import SwiftUI
import FacetDesign

/// Options an administrator has set with a configuration profile (managed preferences). macOS reports them as
/// forced; they can't be changed in Settings, so their controls are shown locked, with the reason.
enum ManagedPreferences {
    static let explanation = "Managed by your organization: a configuration profile sets this option, so it can't be changed here."

    static func isForced(_ key: AppSettings.Key, _ defaults: UserDefaults = AppSettings.defaults) -> Bool {
        defaults.objectIsForced(forKey: key.rawValue)
    }

    /// The explanation when any of the keys is managed, else nil.
    static func lockReason(_ keys: [AppSettings.Key], _ defaults: UserDefaults = AppSettings.defaults) -> String? {
        keys.contains { isForced($0, defaults) } ? explanation : nil
    }
}

private struct ManagedLock: ViewModifier {
    let keys: [AppSettings.Key]

    func body(content: Content) -> some View {
        if let reason = ManagedPreferences.lockReason(keys) {
            VStack(alignment: .leading, spacing: 2) {
                content.disabled(true)
                Label(reason, systemImage: "lock.fill")
                    .font(Design.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(reason)
        } else {
            content
        }
    }
}

extension View {
    /// Locks the control when any of these options is set by a configuration profile.
    func managed(_ keys: AppSettings.Key...) -> some View { modifier(ManagedLock(keys: keys)) }
}
