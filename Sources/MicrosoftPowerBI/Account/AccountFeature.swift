import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetDesign

/// The Microsoft account features: sign-in, publish to the Power BI service, and saving to OneDrive.
@MainActor
enum AccountFeature {
    static func register() {
        AppCommands.register { commands }
        if !SettingsSections.extra.contains(where: { $0.title == "Microsoft account" }) {
            SettingsSections.extra.append(SettingsSections.Section(
                title: "Microsoft account", symbol: "person.crop.circle",
                view: { AnyView(MicrosoftAccountSettingsView()) }))
        }
    }

    static var commands: [AppCommand] {
        [
            AppCommand(id: "account.signIn", title: "Sign in with Microsoft…", menu: .account, symbol: "person.crop.circle",
                       isEnabled: { _ in !MicrosoftRuntime.shared.isConfigured || MicrosoftRuntime.shared.manager.accounts.isEmpty }) { store in
                if MicrosoftRuntime.shared.clientID.isEmpty {
                    store.present { EntraClientIDSheet() }
                } else {
                    signIn(store)
                }
            },
            AppCommand(id: "account.signOut", title: "Sign Out", menu: .account,
                       isEnabled: { _ in !MicrosoftRuntime.shared.manager.accounts.isEmpty }) { store in
                MicrosoftRuntime.shared.manager.removeAll()
                store.status = StatusMessage(kind: .info, text: "Signed out of Microsoft.")
            },
            AppCommand(id: "account.publish", title: "Publish to Power BI…", menu: .account, symbol: "square.and.arrow.up",
                       separatorBefore: true,
                       isEnabled: { _ in MicrosoftRuntime.shared.manager.accounts.isEmpty == false && MicrosoftRuntime.shared.storeSaved }) { store in
                publish(store)
            },
            AppCommand(id: "account.saveToOneDrive", title: "Save to OneDrive…", menu: .account, symbol: "cloud",
                       isEnabled: { _ in true }) { store in
                saveToOneDrive(store)
            },
            AppCommand(id: "account.catalog", title: "OneLake Catalog…", menu: .account, symbol: "books.vertical",
                       isEnabled: { _ in true }) { store in
                store.present { OneLakeCatalogSheet() }
            },
        ]
    }

    private static func signIn(_ store: DocumentStore) {
        store.status = StatusMessage(kind: .info, text: "Opening Microsoft sign-in in your browser…")
        Task {
            do {
                let account = try await MicrosoftRuntime.shared.manager.signIn()
                store.status = StatusMessage(kind: .success, text: "Signed in as \(account.displayName).")
            } catch {
                store.status = StatusMessage(kind: .error, text: "Microsoft sign-in failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }

    private static func publish(_ store: DocumentStore) {
        guard let fileURL = store.fileURL else {
            store.status = StatusMessage(kind: .error, text: "Save the document first, then publish.")
            return
        }
        store.status = StatusMessage(kind: .info, text: "Publishing to the Power BI service…")
        Task {
            do {
                let client = MicrosoftRuntime.shared.powerBIClient
                let importResult = try await client.importFile(at: fileURL, displayName: store.displayName)
                let state = importResult.importState ?? "Publishing"
                if state == "Failed" {
                    store.status = StatusMessage(kind: .warning,
                        text: "The service could not import the document (it reads .pbix files; the .facet file was sent to your workspace \"\(importResult.name ?? store.displayName)\").")
                } else {
                    store.status = StatusMessage(kind: .success,
                        text: "Published \"\(importResult.name ?? store.displayName)\" — import \(state).")
                }
            } catch {
                store.status = StatusMessage(kind: .error, text: "Publish failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }

    private static func saveToOneDrive(_ store: DocumentStore) {
        guard let fileURL = store.fileURL else {
            store.status = StatusMessage(kind: .error, text: "Save the document first, then save to OneDrive.")
            return
        }
        store.status = StatusMessage(kind: .info, text: "Uploading to OneDrive…")
        Task {
            do {
                let client = MicrosoftRuntime.shared.graphClient
                try await client.upload(fileAt: fileURL, named: fileURL.lastPathComponent)
                store.status = StatusMessage(kind: .success, text: "Saved \(fileURL.lastPathComponent) to your OneDrive.")
            } catch {
                store.status = StatusMessage(kind: .error, text: "OneDrive upload failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
}

// MARK: - Runtime

/// The per-app Microsoft account stack: one manager, one Power BI client and one Graph client,
/// built on top of the user's Entra app registration (client ID persisted in defaults).
@MainActor
final class MicrosoftRuntime: ObservableObject {
    static let shared = MicrosoftRuntime()
    static let clientIDKey = "com.facet.entraClientID"

    let manager: MicrosoftAccountManager
    private(set) var powerBIClient: PowerBIClient
    private(set) var graphClient: GraphClient

    var isConfigured: Bool { !clientID.isEmpty }
    var clientID: String { UserDefaults.standard.string(forKey: Self.clientIDKey) ?? "" }
    var storeSaved: Bool { true }   // the publish command checks the document's own state

    private init() {
        manager = MicrosoftAccountManager(
            configuration: MicrosoftAuthConfiguration(clientID: UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""),
            openURL: { url in NSWorkspace.shared.open(url) })
        powerBIClient = PowerBIClient(tokenProvider: manager)
        graphClient = GraphClient(tokenProvider: manager)
    }

    func setClientID(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.clientIDKey)
        // Rebuild the manager so the next sign-in uses the new registration.
        powerBIClient = PowerBIClient(tokenProvider: manager)
        graphClient = GraphClient(tokenProvider: manager)
    }
}

// MARK: - Entra app registration sheet

struct EntraClientIDSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = UserDefaults.standard.string(forKey: MicrosoftRuntime.clientIDKey) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Microsoft account").font(Design.Typeface.headline)
            Text("Sign-in uses your own (free) Microsoft Entra app registration. Register an app in the Entra admin center with \"Accounts in any organizational directory and personal Microsoft accounts\", enable the public-client flow, and paste its Application (client) ID here.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Application (client) ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    MicrosoftRuntime.shared.setClientID(clientID.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }
}

// MARK: - Settings tab

struct MicrosoftAccountSettingsView: View {
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @State private var clientID = UserDefaults.standard.string(forKey: MicrosoftRuntime.clientIDKey) ?? ""
    @State private var signInError: String?

    var body: some View {
        Form {
            Section("Entra app registration") {
                LabeledContent("Application (client) ID") {
                    TextField("00000000-0000-0000-0000-000000000000", text: $clientID)
                        .frame(width: 280)
                }
                Button("Save Registration") {
                    MicrosoftRuntime.shared.setClientID(clientID.trimmingCharacters(in: .whitespaces))
                }
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Register a free app in the Entra admin center, enable the public-client flow, and allow \"Accounts in any organizational directory and personal Microsoft accounts\".")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            Section("Account") {
                if runtime.manager.accounts.isEmpty {
                    Text("No Microsoft account is signed in.")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Button("Sign in with Microsoft…") {
                        Task {
                            do { _ = try await runtime.manager.signIn() }
                            catch { signInError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
                        }
                    }
                    .disabled(!runtime.isConfigured)
                } else {
                    ForEach(runtime.manager.accounts) { account in
                        LabeledContent(account.displayName, value: account.username)
                    }
                    Button("Sign Out", role: .destructive) { runtime.manager.removeAll() }
                }
                if let signInError {
                    Text(signInError).font(Design.Typeface.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - OneLake catalog

/// The OneLake catalog: browse the signed-in user's cloud files (OneDrive) and open them.
struct OneLakeCatalogSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DriveItem] = []
    @State private var working = true
    @State private var listError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OneLake catalog").font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if MicrosoftRuntime.shared.manager.accounts.isEmpty {
                EmptyState(systemImage: "person.crop.circle", title: "Sign in required",
                           message: "Sign in with a Microsoft account (Account menu) to browse your cloud files.")
            } else if let listError {
                EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't list files", message: listError)
            } else if items.isEmpty && working {
                ProgressView("Loading files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items.filter { !$0.isFolder }) { item in
                        HStack(spacing: Design.Space.xs) {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if let url = item.downloadURL {
                                Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
                            }
                        }
                    }
                    ForEach(items.filter { $0.isFolder }) { item in
                        HStack(spacing: Design.Space.xs) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420)
        .task { await load() }
    }

    private func load() async {
        working = true
        listError = nil
        do {
            let page = try await MicrosoftRuntime.shared.graphClient.children(of: .myRoot)
            items = page.items
        } catch {
            listError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        working = false
    }
}
