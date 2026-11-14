import SwiftUI
import FacetCore
import FacetQuery
import FacetCloud
import FacetDesign

/// Pure logic behind the credentials dialog: the levels a credential can apply to, and what a form value saves.
enum CredentialForm {
    /// "Select which level to apply these settings to": the address and each shorter path above it, down to the host.
    static func levels(for location: String) -> [String] {
        let t = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t), let scheme = c.scheme, let host = c.host, !host.isEmpty else { return [t] }
        var out = ["\(scheme)://\(host)"]
        var path = ""
        for segment in c.path.split(separator: "/") {
            path += "/" + segment
            out.append("\(scheme)://\(host)\(path)")
        }
        return out
    }

    struct Values: Equatable {
        var method: CredentialMethod = .anonymous
        var username = ""
        var secret = ""
        var headerName = ""
        var queryParameter = ""
    }

    /// Why the values can't be saved yet (nil when they can).
    static func problem(_ v: Values, signedIn: Bool, hasSavedSecret: Bool = false) -> String? {
        switch v.method {
        case .anonymous: return nil
        case .basic: return v.username.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a user name." : nil
        case .apiKey:
            if v.secret.isEmpty, !hasSavedSecret { return "Enter the key." }
            if v.headerName.trimmingCharacters(in: .whitespaces).isEmpty && v.queryParameter.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Name the header (for example X-API-Key) or the query parameter the key is sent in."
            }
            return nil
        case .accountKey where v.secret.isEmpty && hasSavedSecret: return nil
        case .sasToken where v.secret.isEmpty && hasSavedSecret: return nil
        case .accountKey: return Data(base64Encoded: v.secret.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ? "Paste the account key (Base64) from the storage account's Access keys." : nil
        case .sasToken: return v.secret.trimmingCharacters(in: .whitespaces).isEmpty ? "Paste the SAS token (the part after ?)." : nil
        case .organizational: return signedIn ? nil : "Sign in with your work or school account first."
        }
    }

    static func credential(_ v: Values, accountID: String?) -> DataSourceCredential {
        switch v.method {
        case .anonymous: return DataSourceCredential(kind: .anonymous)
        case .basic: return .usernamePassword(v.username.trimmingCharacters(in: .whitespaces), v.secret)
        case .apiKey:
            var props: [String: String] = [:]
            let header = v.headerName.trimmingCharacters(in: .whitespaces), parameter = v.queryParameter.trimmingCharacters(in: .whitespaces)
            if !header.isEmpty { props["headerName"] = header } else { props["queryParameter"] = parameter }
            return DataSourceCredential(kind: .apiKey, secret: v.secret, properties: props)
        case .accountKey: return .accountKey(v.secret.trimmingCharacters(in: .whitespacesAndNewlines))
        case .sasToken: return DataSourceCredential(kind: .sasToken, secret: v.secret.trimmingCharacters(in: .whitespacesAndNewlines))
        case .organizational: return DataSourceCredential(kind: .microsoftAccount, username: accountID)
        }
    }
}

/// Power BI's credentials dialog for one source: the sign-in method, its details and the level it applies to.
/// Secrets go straight to the Keychain; they are never shown again or written into documents.
struct CredentialsSheet: View {
    let kind: String
    let location: String
    var credentials: AppCredentials = .shared
    var onSaved: () -> Void = {}
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @Environment(\.dismiss) private var dismiss
    @State private var values = CredentialForm.Values()
    @State private var level = ""
    @State private var failure: String?
    @State private var signingIn = false
    @State private var loaded = false

    private var methods: [CredentialMethod] { CredentialMethod.offered(forKind: kind) }
    private var levels: [String] { CredentialForm.levels(for: location) }
    private var signedInWork: Bool { runtime.activeAccount.map { !$0.isPersonal } ?? false }
    private var problem: String? {
        let saved = credentials.stored(kind: kind, location: location).map { CredentialMethod($0.kind) == values.method && !($0.secret ?? "").isEmpty } ?? false
        return CredentialForm.problem(values, signedIn: signedInWork, hasSavedSecret: saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Credentials for \(kind)").font(Design.Typeface.headline)
            Text(location).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Hairline()
            if methods.count > 1 {
                Picker("Sign in with", selection: $values.method) {
                    ForEach(methods) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 360)
            }
            fields
            if levels.count > 1 {
                Picker("Apply these settings to", selection: $level) {
                    ForEach(levels, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 460)
                .help("The credentials are used for this address and every address below it")
            }
            if let message = failure ?? problem {
                Text(message).font(Design.Typeface.caption).foregroundStyle(failure == nil ? Color.secondary : Design.Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if credentials.stored(kind: kind, location: location) != nil {
                    Button("Clear Credentials", role: .destructive) {
                        credentials.remove(kind: kind, location: storedLevel)
                        onSaved(); dismiss()
                    }
                    .help("Remove the saved credentials for this source from your Keychain")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
            Text("Passwords, keys and tokens are kept in your Keychain, never in the report file.")
                .font(Design.Typeface.caption).foregroundStyle(.tertiary)
        }
        .padding(Design.Space.xl)
        .frame(width: 520)
        .sheet(isPresented: $signingIn) { SignInSheet() }
        .onAppear(perform: load)
    }

    /// The level the stored credential was saved at (to clear the right one).
    private var storedLevel: String { levels.last { credentials.stored(kind: kind, location: $0) != nil && AppCredentials.covers($0, location) } ?? location }

    @ViewBuilder private var fields: some View {
        switch values.method {
        case .anonymous:
            Text("The source is read without signing in.").font(Design.Typeface.caption).foregroundStyle(.secondary)
        case .basic:
            LabeledContent("User name") { TextField("", text: $values.username).frame(maxWidth: 300) }
            LabeledContent("Password") { SecureField("", text: $values.secret).frame(maxWidth: 300) }
        case .apiKey:
            LabeledContent("Key") { SecureField("", text: $values.secret).frame(maxWidth: 300) }
            LabeledContent("Header name") { TextField("", text: $values.headerName, prompt: Text("X-API-Key")).frame(maxWidth: 300) }
            LabeledContent("or query parameter") { TextField("", text: $values.queryParameter, prompt: Text("api_key")).frame(maxWidth: 300) }
        case .accountKey:
            LabeledContent("Account key") { SecureField("", text: $values.secret).frame(maxWidth: 300) }
        case .sasToken:
            LabeledContent("SAS token") { SecureField("", text: $values.secret).frame(maxWidth: 300) }
        case .organizational:
            HStack(spacing: Design.Space.s) {
                AccountAvatar(account: runtime.activeAccount, size: 22)
                if let account = runtime.activeAccount, !account.isPersonal {
                    Text("Signed in as \(account.username.isEmpty ? account.displayName : account.username)").font(Design.Typeface.body)
                    Spacer()
                    Button("Switch Account…") { signingIn = true }
                } else {
                    Text(runtime.isConfigured ? "You aren't signed in with a work or school account." : MicrosoftAuthConfiguration.missingRegistration)
                        .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sign In…") { signingIn = true }.disabled(!runtime.isConfigured)
                }
            }
            Text("Each Microsoft service asks for your consent in the browser the first time it is used.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        level = levels.first ?? location
        if let stored = credentials.stored(kind: kind, location: location) {
            values.method = CredentialMethod(stored.kind)
            values.username = stored.kind == .usernamePassword ? stored.username ?? "" : ""
            values.headerName = stored.properties["headerName"] ?? ""
            values.queryParameter = stored.properties["queryParameter"] ?? ""
            if let at = stored.properties["sourceLocation"], levels.contains(at) { level = at }
        } else if let first = methods.first {
            values.method = first
        }
        if !methods.contains(values.method), let first = methods.first { values.method = first }
    }

    private func save() {
        do {
            var v = values
            // A secret is never shown again; leaving it empty keeps the saved one for the same method.
            if v.secret.isEmpty, let stored = credentials.stored(kind: kind, location: location), CredentialMethod(stored.kind) == v.method {
                v.secret = stored.secret ?? ""
            }
            try credentials.save(CredentialForm.credential(v, accountID: runtime.activeAccount?.id), kind: kind, location: level.isEmpty ? location : level)
            onSaved()
            dismiss()
        } catch {
            failure = "The credentials couldn't be saved in your Keychain: \(error.localizedDescription)"
        }
    }
}

extension QueryDataSource: Identifiable {
    public var id: String { kind + "|" + location }
}
