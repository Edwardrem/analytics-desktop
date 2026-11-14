import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetDesign

/// Signs in with the system browser (authorization code + PKCE on a loopback redirect) or with a device code,
/// and shows where the sign-in is: waiting for the browser, the code to type, redeeming, or what went wrong.
struct SignInSheet: View {
    @ObservedObject var runtime = MicrosoftRuntime.shared
    @Environment(\.dismiss) private var dismiss
    /// Re-authenticates this account instead of adding one.
    var loginHint: String?
    var onSignedIn: (MicrosoftAccount) -> Void = { _ in }
    @State private var task: Task<Void, Never>?
    @State private var failure: String?

    private var state: MicrosoftSignInState { runtime.manager.signInState }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(loginHint == nil ? "Sign in with Microsoft" : "Sign in again").font(Design.Typeface.headline)
            }
            content
            if let failure {
                Text(failure).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Text("Tokens are kept in your Keychain. \(AppIdentity.name) never sees your password.")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(task == nil ? "Close" : "Cancel") {
                    runtime.manager.cancelSignIn()
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 460)
        .onDisappear { if task != nil { runtime.manager.cancelSignIn(); task?.cancel() } }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .waitingForBrowser:
            progress("Finish signing in in your browser. This window updates when you're done.")
        case .redeeming:
            progress("Completing sign-in…")
        case .deviceCode(let prompt):
            DeviceCodeView(prompt: prompt)
        case .idle, .failed:
            if task != nil {
                progress("Starting…")
            } else {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    Text("Sign in with your work or school Microsoft account to open and save files in OneDrive and SharePoint, publish, use the OneLake catalog and sensitivity labels, and connect to SharePoint, Dataverse, Azure and Fabric data. Each service asks for your consent the first time.")
                        .font(Design.Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Continue in Browser") { start(deviceCode: false) }.keyboardShortcut(.defaultAction)
                        Button("Use a Code Instead") { start(deviceCode: true) }
                            .help("Sign in on any device with a short code, for when the browser can't return to \(AppIdentity.name)")
                    }
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Design.Space.s) {
            ProgressView().controlSize(.small)
            Text(text).font(Design.Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start(deviceCode: Bool) {
        failure = nil
        let manager = runtime.manager
        task = Task { @MainActor in
            do {
                let account = deviceCode ? try await manager.startDeviceCodeSignIn() : try await manager.signIn(loginHint: loginHint)
                task = nil
                onSignedIn(account)
                dismiss()
            } catch MicrosoftAuthError.cancelled {
                task = nil
            } catch {
                task = nil
                failure = AccountMessages.describe(error)
            }
        }
    }
}

/// The device-code prompt: the code, a way to copy it, and the page to type it on.
private struct DeviceCodeView: View {
    let prompt: DeviceCodePrompt
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("On any device, open \(prompt.verificationURL.absoluteString) and enter this code:")
                .font(Design.Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.m) {
                Text(prompt.userCode).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                IconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy the code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.userCode, forType: .string)
                    copied = true
                }
            }
            HStack {
                Button("Open Sign-in Page") { NSWorkspace.shared.open(prompt.verificationURL) }
                Spacer()
                Text("Expires \(prompt.expiresAt, style: .relative)").font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Asks for the user's own Entra app registration (client id, tenant, cloud) before the first sign-in.
struct RegistrationSheet: View {
    @ObservedObject var runtime = MicrosoftRuntime.shared
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            Text("Set up Microsoft sign-in").font(Design.Typeface.headline)
            RegistrationForm(runtime: runtime, onSaved: { dismiss(); onSaved() })
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 520)
    }
}

/// Client id, tenant and cloud, with the registration steps. Used in the sheet and in Settings.
struct RegistrationForm: View {
    @ObservedObject var runtime: MicrosoftRuntime
    var onSaved: () -> Void = {}
    @State private var clientID = ""
    @State private var tenant = ""
    @State private var cloud: MicrosoftCloud = .public
    @State private var problem: String?
    @State private var showSteps = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(runtime.hasDefaultRegistration
                 ? "\(AppIdentity.name) signs in with its own Microsoft app registration, so there is nothing to set up. Enter an application ID only if your organization requires its own registration; leave it empty to use the app's. These are stored in your preferences, not in documents."
                 : MicrosoftAuthConfiguration.missingRegistration)
                .font(Design.Typeface.caption).foregroundStyle(runtime.hasDefaultRegistration ? Color.secondary : Design.Palette.caution)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Application (client) ID") {
                TextField("", text: $clientID, prompt: Text(runtime.hasDefaultRegistration ? "The app's own registration" : "00000000-0000-0000-0000-000000000000"))
                    .font(Design.Typeface.mono).frame(maxWidth: 300)
            }
            LabeledContent("Tenant") {
                TextField("", text: $tenant, prompt: Text(MicrosoftAuthConfiguration.defaultTenant)).frame(maxWidth: 300)
                    .help("Empty or “organizations” accepts any work or school account; “common” also accepts personal accounts; a tenant ID or domain allows only that organization")
            }
            LabeledContent("Cloud") {
                Picker("", selection: $cloud) {
                    ForEach(MicrosoftCloud.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            if let problem {
                Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Save Registration") { save() }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty && !runtime.hasDefaultRegistration)
                    .help(runtime.hasDefaultRegistration ? "Save the override; an empty application ID uses the app's own registration"
                                                         : "Enter an application (client) ID first")
                Button(showSteps ? "Hide Steps" : "How to Register…") { showSteps.toggle() }
                Spacer()
            }
            if showSteps { RegistrationSteps() }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let c = runtime.manager.configuration
            clientID = c.clientID; tenant = c.tenant == MicrosoftAuthConfiguration.defaultTenant ? "" : c.tenant; cloud = c.cloud
        }
    }

    private func save() {
        do {
            try runtime.updateRegistration(clientID: clientID, tenant: tenant, cloud: cloud)
            problem = nil
            onSaved()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The registration instructions, with the two values people copy.
struct RegistrationSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(MicrosoftAuthConfiguration.registrationInstructions)
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                if let url = EntraRegistration.adminCenter {
                    Button("Open Entra Admin Center") { NSWorkspace.shared.open(url) }
                }
                Button("Copy Redirect URI") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(EntraRegistration.redirectURI, forType: .string)
                }
                .help("Copies \(EntraRegistration.redirectURI), the redirect URI to add under Mobile and desktop applications")
            }
        }
        .padding(.leading, Design.Space.m)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
    }
}
