import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetDesign

/// Settings ▸ Microsoft account: the user's own Entra app registration, and the signed-in accounts.
struct MicrosoftAccountSettingsView: View {
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @State private var signingIn: SignInRequest?

    struct SignInRequest: Identifiable { let id = UUID(); var loginHint: String? }

    var body: some View {
        Form {
            Section("App registration") {
                RegistrationForm(runtime: runtime)
            }
            Section("Accounts") {
                if runtime.accounts.isEmpty {
                    Text(runtime.isConfigured ? "No Microsoft account is signed in." : "Sign-in needs an application ID; see App registration above.")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(runtime.accounts) { account in
                        AccountRow(account: account, isActive: account.id == runtime.activeAccount?.id,
                                   use: { runtime.manager.setActive(account) },
                                   signInAgain: { signingIn = SignInRequest(loginHint: account.username) },
                                   signOut: { runtime.manager.signOut(account) })
                    }
                }
                HStack {
                    Button(runtime.accounts.isEmpty ? "Sign In…" : "Add Account…") { signingIn = SignInRequest() }
                        .disabled(!runtime.isConfigured)
                        .help(runtime.isConfigured ? "Sign in with a work or school Microsoft account" : MicrosoftAuthConfiguration.missingRegistration)
                    if runtime.accounts.count > 1 {
                        Button("Sign Out of All", role: .destructive) { runtime.manager.removeAll() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $signingIn) { request in SignInSheet(loginHint: request.loginHint) }
        .task { await runtime.manager.refreshAvatars() }
    }
}

private struct AccountRow: View {
    let account: MicrosoftAccount
    let isActive: Bool
    let use: () -> Void
    let signInAgain: () -> Void
    let signOut: () -> Void

    var body: some View {
        HStack(spacing: Design.Space.s) {
            AccountAvatar(account: account, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Design.Space.xs) {
                    Text(account.displayName).font(Design.Typeface.bodyStrong)
                    if isActive { Text("In use").font(Design.Typeface.caption).foregroundStyle(Design.Palette.accent) }
                }
                Text("\(account.username) · \(account.isPersonal ? "Personal account" : "Work or school account")")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
                if account.needsSignIn {
                    Text("Needs to sign in again").font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution)
                }
            }
            Spacer()
            if account.needsSignIn { Button("Sign In…", action: signInAgain) }
            else if !isActive { Button("Use", action: use) }
            Button("Sign Out", role: .destructive, action: signOut)
        }
    }
}

/// The account's photo, or its initials on a quiet disc.
struct AccountAvatar: View {
    let account: MicrosoftAccount?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let data = account?.avatar, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let account {
                Text(AccountMessages.initials(account.displayName))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Design.Palette.fillStrong)
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: size * 0.8)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(account?.displayName ?? "Not signed in")
    }
}

/// The trailing title-bar items: the document's sensitivity label, where a cloud document stands, and the account.
struct AccountToolbarAccessory: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var files: DocumentFiles
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: Design.Space.s) {
            let label = store.report.settings.sensitivityLabel
            if !label.isEmpty {
                Button { AppCommands.run("account.sensitivity", store) } label: {
                    Label(label, systemImage: "lock.doc").labelStyle(.titleAndIcon).font(Design.Typeface.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Sensitivity: \(label). Click to change it.")
            }
            if files.cloud != nil { cloudStatus }
            accountMenu
        }
    }

    @ViewBuilder private var cloudStatus: some View {
        switch files.cloudState {
        case .uploading:
            ProgressView().controlSize(.small).help("Saving to \(files.cloudPlace)…")
        case .failed(let message):
            Button { AppCommands.run("file.save", store) } label: { Image(systemName: "exclamationmark.icloud") }
                .foregroundStyle(Design.Palette.caution)
                .help("Not saved to \(files.cloudPlace): \(message) Click to try again.")
        case .idle, .uploaded:
            Menu {
                if let url = files.cloudWebURL { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
                Button("Copy Sharing Link") { AppCommands.run("account.shareLink", store) }
            } label: {
                Image(systemName: store.isDirty ? "icloud" : "checkmark.icloud")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(store.isDirty ? "Saved in \(files.cloudPlace); unsaved changes stay on this Mac until you save" : "Saved in \(files.cloudPlace)")
        }
    }

    private var accountMenu: some View {
        Menu {
            if runtime.accounts.isEmpty {
                Button("Sign In with Microsoft…") { AppCommands.run("account.signIn", store) }
            } else {
                ForEach(runtime.accounts) { account in
                    Toggle(isOn: Binding(get: { account.id == runtime.activeAccount?.id },
                                         set: { if $0 { runtime.manager.setActive(account) } })) {
                        Text(account.needsSignIn ? "\(account.displayName) (sign in again)" : account.displayName)
                    }
                }
                Divider()
                Button("Add Account…") { AppCommands.run("account.signIn", store) }
                if let active = runtime.activeAccount {
                    Button("Sign Out \(active.displayName)") { runtime.manager.signOut(active) }
                }
            }
            Divider()
            Button("Microsoft Account Settings…") { openSettings() }
        } label: {
            AccountAvatar(account: runtime.activeAccount, size: 20)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(runtime.activeAccount.map { "Signed in as \($0.username.isEmpty ? $0.displayName : $0.username)" } ?? "Sign in with a Microsoft account")
    }
}
