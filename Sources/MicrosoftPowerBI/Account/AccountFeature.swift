import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetDesign

/// The Microsoft account features: sign-in with the user's own Entra app registration, OneDrive and SharePoint
/// documents, the OneLake catalog, publishing to the Power BI service and sensitivity labels.
///
/// None of this has been exercised against live Microsoft services from this build; it is tested against in-process
/// stand-ins for the identity platform, Graph, Power BI and Fabric.
@MainActor
enum AccountFeature {
    static func register() {
        AppCommands.register { commands }
        if !SettingsSections.extra.contains(where: { $0.title == "Microsoft account" }) {
            SettingsSections.extra.append(SettingsSections.Section(
                title: "Microsoft account", symbol: "person.crop.circle",
                view: { AnyView(MicrosoftAccountSettingsView()) }))
        }
        Features.toolbarAccessory = { store in
            AnyView(AccountToolbarAccessory(store: store, files: DocumentFiles.of(store)))
        }
    }

    private static var runtime: MicrosoftRuntime { MicrosoftRuntime.shared }

    static var commands: [AppCommand] {
        [
            AppCommand(id: "account.openFromCloud", title: "Open from OneDrive or SharePoint…", menu: .file, symbol: "icloud.and.arrow.down",
                       separatorBefore: true) { store in
                store.present { CloudFilesPanel(mode: .open, suggestedName: store.displayName) }
            },
            AppCommand(id: "account.saveToOneDrive", title: "Save to OneDrive or SharePoint…", menu: .file, symbol: "icloud.and.arrow.up") { store in
                store.present { CloudFilesPanel(mode: .save, suggestedName: store.displayName + "." + DocumentPackage.fileExtension) }
            },
            AppCommand(id: "account.shareLink", title: "Copy Sharing Link", menu: .file, symbol: "link",
                       isEnabled: { DocumentFiles.of($0).cloud != nil }) { CloudDocuments.copySharingLink($0) },

            AppCommand(id: "account.signIn", title: "Sign In with Microsoft…", menu: .account, symbol: "person.crop.circle") { beginSignIn($0) },
            AppCommand(id: "account.signOut", title: "Sign Out", menu: .account, symbol: "person.crop.circle.badge.xmark",
                       isEnabled: { _ in runtime.isSignedIn }) { store in
                guard let account = runtime.activeAccount else { return }
                runtime.manager.signOut(account)
                store.status = StatusMessage(kind: .info, text: "Signed \(account.displayName) out. Their sign-in was removed from your Keychain.")
            },
            AppCommand(id: "account.settings", title: "Microsoft Account Settings…", menu: .account, symbol: "gearshape") { _ in openSettings() },
            AppCommand(id: "account.catalog", title: "OneLake Catalog…", menu: .account, symbol: "books.vertical", separatorBefore: true) { store in
                guard requireWorkAccount(store, for: "The OneLake catalog") else { return }
                store.present { OneLakeCatalogSheet() }
            },
            AppCommand(id: "account.publish", title: "Publish to Power BI…", menu: .account, symbol: "square.and.arrow.up") { store in
                guard requireWorkAccount(store, for: "Publishing") else { return }
                store.present { PublishSheet() }
            },
            AppCommand(id: "account.sensitivity", title: "Sensitivity…", menu: .account, symbol: "lock.doc") { store in
                store.present { SensitivitySheet() }
            },
        ]
    }

    /// Sign-in starts with the registration when there is none yet.
    static func beginSignIn(_ store: DocumentStore) {
        if runtime.isConfigured {
            store.present { SignInSheet(onSignedIn: { account in
                store.status = StatusMessage(kind: .success, text: "Signed in as \(account.displayName).")
            }) }
        } else {
            store.present { RegistrationSheet(onSaved: { DispatchQueue.main.async { beginSignIn(store) } }) }
        }
    }

    /// Power BI and Fabric refuse personal accounts; say so before opening a sheet that cannot work.
    private static func requireWorkAccount(_ store: DocumentStore, for feature: String) -> Bool {
        if runtime.hasWorkAccount { return true }
        if runtime.isSignedIn {
            store.status = StatusMessage(kind: .warning, text: "\(feature) needs a work or school account; \(runtime.activeAccount?.username ?? "this account") is a personal Microsoft account. Add a work account from the Account menu.")
        } else {
            beginSignIn(store)
        }
        return false
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
