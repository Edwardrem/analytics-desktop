import SwiftUI
import FacetCore
import FacetQuery
import FacetCloud
import FacetDesign

/// How a SQL Server source signs in. Typed into the connection form; the secret goes to the Keychain, never the request.
struct SQLServerSignIn: Equatable {
    enum Method: String, CaseIterable, Identifiable {
        case database = "Database", microsoftAccount = "Microsoft account", windows = "Windows"
        var id: String { rawValue }
    }
    var method = Method.database
    var user = ""
    var password = ""
}

/// Pure logic of the SQL Server family of connectors (SQL Server, Azure SQL, Synapse, Fabric warehouses).
enum SQLServerConnection {
    static let windowsUnavailable = "Windows authentication needs a Windows account and Kerberos, which macOS doesn't provide for SQL Server. Use a database user name and password, or a Microsoft account for Azure SQL, Synapse and Fabric."
    static let trustWarning = "Only for servers you trust on networks you trust: without checking the certificate, someone on the network could pose as the server and read the data and the password."

    /// The host name of a server as typed (`tcp:host,port`, `host\instance`, `.`).
    static func host(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("tcp:") { s = String(s.dropFirst(4)) }
        if let comma = s.lastIndex(of: ",") { s = String(s[..<comma]) }
        if let slash = s.firstIndex(of: "\\") { s = String(s[..<slash]) }
        if [".", "(local)"].contains(s.lowercased()) { s = "localhost" }
        return s.lowercased()
    }

    /// Azure SQL, Synapse and Fabric hosts, which sign in with a Microsoft account.
    static func isMicrosoftCloud(_ server: String) -> Bool {
        let h = host(server)
        return [".database.windows.net", ".sql.azuresynapse.net", ".datawarehouse.fabric.microsoft.com", ".database.fabric.microsoft.com"]
            .contains { h.hasSuffix($0) }
    }

    /// The data source location the engine records: `server;database`.
    static func location(server: String, database: String) -> String {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines), d = database.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? s : s + ";" + d
    }

    /// The default sign-in for a server: a Microsoft account for cloud endpoints, a database user otherwise.
    static func defaultMethod(for server: String) -> SQLServerSignIn.Method { isMicrosoftCloud(server) ? .microsoftAccount : .database }

    static func validationMessage(server: String, database: String, signIn: SQLServerSignIn, hasStoredCredential: Bool) -> String? {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "Type the server name." }
        guard !host(s).isEmpty, !s.contains(where: { $0 == " " || $0 == ";" || $0 == "/" }) else { return "The server name isn't valid." }
        guard !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Type the database name. Browsing all the databases of a server isn't available in the navigator."
        }
        switch signIn.method {
        case .windows: return windowsUnavailable
        case .database:
            if signIn.user.trimmingCharacters(in: .whitespaces).isEmpty, !hasStoredCredential { return "Type the database user name and password." }
        case .microsoftAccount: break
        }
        return nil
    }

    /// The credential to keep in the Keychain for this sign-in (nil keeps what is stored).
    static func credential(for signIn: SQLServerSignIn) -> DataSourceCredential? {
        switch signIn.method {
        case .database:
            let user = signIn.user.trimmingCharacters(in: .whitespaces)
            return user.isEmpty ? nil : .usernamePassword(user, signIn.password)
        case .microsoftAccount: return DataSourceCredential(kind: .microsoftAccount)
        case .windows: return nil
        }
    }

    /// Store the sign-in for the source, so the query engine's credential provider finds it.
    static func save(_ signIn: SQLServerSignIn, server: String, database: String,
                     store: DataSourceCredentialStore = DataSourceCredentialStore()) throws {
        guard let c = credential(for: signIn) else { return }
        try store.save(c, kind: "SQL", location: location(server: server, database: database))
    }
    static func hasStoredCredential(server: String, database: String, store: DataSourceCredentialStore = DataSourceCredentialStore()) -> Bool {
        ((try? store.credential(kind: "SQL", location: location(server: server, database: database))) ?? nil) != nil
    }
}

extension QuerySecurity {
    private static let trustKey = "query.trustServerCertificateHosts"

    /// SQL Server hosts whose certificate the user chose not to verify ("Trust server certificate").
    var trustedServerCertificateHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.trustKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.trustKey) }
    }
    func setTrustServerCertificate(_ on: Bool, server: String) {
        let h = SQLServerConnection.host(server)
        guard !h.isEmpty else { return }
        var all = trustedServerCertificateHosts
        if on { all.insert(h) } else { all.remove(h) }
        trustedServerCertificateHosts = all
    }
}

/// The SQL Server connection form: server, database, connectivity mode, sign-in and the certificate option.
struct SQLServerFields: View {
    @ObservedObject var session: GetDataSession
    @State private var trust = false

    private var server: String { session.request.location }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            TextField("Server (name, name,port or name\\instance)", text: $session.request.location)
                .textFieldStyle(.roundedBorder)
                .onChange(of: session.request.location) { _, s in
                    session.sqlSignIn.method = SQLServerConnection.defaultMethod(for: s)
                    trust = QuerySecurity.shared.trustedServerCertificateHosts.contains(SQLServerConnection.host(s))
                }
            TextField("Database", text: $session.request.database).textFieldStyle(.roundedBorder)
            Picker("Sign in with", selection: $session.sqlSignIn.method) {
                ForEach(SQLServerSignIn.Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            signIn
            Toggle("Trust server certificate", isOn: $trust)
                .onChange(of: trust) { _, on in QuerySecurity.shared.setTrustServerCertificate(on, server: server) }
                .help("Connect without checking that the server's certificate is valid for its name")
            if trust {
                Label(SQLServerConnection.trustWarning, systemImage: "exclamationmark.triangle")
                    .font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
            }
            Text("The connection is always encrypted.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            session.sqlSignIn.method = SQLServerConnection.defaultMethod(for: server)
            trust = QuerySecurity.shared.trustedServerCertificateHosts.contains(SQLServerConnection.host(server))
        }
    }

    @ViewBuilder
    private var signIn: some View {
        switch session.sqlSignIn.method {
        case .database:
            TextField("User name", text: $session.sqlSignIn.user).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $session.sqlSignIn.password).textFieldStyle(.roundedBorder)
            Text("Kept in your Keychain for this server and database.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
        case .microsoftAccount:
            Text("Uses the Microsoft account you signed in with (Settings ▸ Microsoft account), for Azure SQL, Synapse and Fabric.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .windows:
            Text(SQLServerConnection.windowsUnavailable)
                .font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
        }
    }
}
