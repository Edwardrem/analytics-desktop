import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// In-app updates from GitHub Releases: Help ▸ Check for Updates…, Help ▸ What's New, the Updates settings tab,
/// and the automatic checks.
@MainActor
enum UpdatesFeature {
    static let checkCommand = "help.checkForUpdates"
    static let whatsNewCommand = "help.whatsNew"
    private static var launchObserver: NSObjectProtocol?

    static func register() {
        AppCommands.register {
            [
                AppCommand(id: checkCommand, title: "Check for Updates…", menu: .help, symbol: "arrow.down.circle",
                           separatorBefore: true, help: "Asks GitHub whether a newer \(AppIdentity.name) has been released.") { _ in
                    Task { await UpdateController.shared.check(manual: true) }
                },
                AppCommand(id: whatsNewCommand, title: "What's New", menu: .help, symbol: "sparkles",
                           help: "Release notes for this version, or for the update on offer.") { _ in
                    Task { await UpdateController.shared.whatsNew() }
                },
            ]
        }
        SettingsSections.extra.append(.init(title: "Updates", symbol: "arrow.down.circle") { AnyView(UpdatesSettings()) })
        // Checks start once the app is running, never during tests (which don't finish launching an app).
        guard launchObserver == nil else { return }
        launchObserver = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateController.shared.start() }
        }
    }
}

/// Settings ▸ Updates.
struct UpdatesSettings: View {
    @ObservedObject private var updates = UpdateController.shared
    @AppStorage(AppSettings.Key.checkForUpdates.rawValue) private var automatic = true
    @AppStorage(AppSettings.Key.includeBetaUpdates.rawValue) private var beta = false

    var body: some View {
        Form {
            Section("Updates") {
                Toggle(isOn: $automatic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates automatically")
                        Text("A minute after \(AppIdentity.name) opens, then once a day.")
                            .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                }
                .managed(.checkForUpdates)
                Toggle(isOn: $beta) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include beta releases")
                        Text("Betas get new features first and may have rough edges.")
                            .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                }
                .managed(.includeBetaUpdates)
                LabeledContent("Installed") { Text("\(AppIdentity.version) (\(AppIdentity.build))").foregroundStyle(.secondary) }
                LabeledContent("Last checked") {
                    Text(updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check Now") { Task { await updates.check(manual: true) } }
                        .disabled(updates.phase == .checking)
                    if updates.phase == .checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(status).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Section("Privacy") {
                Text("Update checks send nothing beyond the request itself: a plain, unauthenticated request to GitHub's public release list (api.github.com), naming only \(AppIdentity.name) and its version as HTTP requires. No identifier, usage data or document information is sent. Updates are downloaded from GitHub and installed only when their signature matches the publisher's key.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch updates.phase {
        case .idle, .checking: return ""
        case .upToDate: return "You have the newest version."
        case .available(let u): return "\(u.version) is available."
        case .downloading(let u, _, _): return "Downloading \(u.version)…"
        case .ready(let u): return "\(u.version) installs when you quit."
        case .failed(let message): return message
        }
    }
}
