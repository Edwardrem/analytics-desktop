import SwiftUI
import FacetCore
import FacetQuery
import FacetCloud
import FacetDesign

/// Connection fields for the SharePoint, OneDrive, Dataverse, Azure Storage, OneLake, Azure Data Explorer and Power BI
/// semantic model connectors, as Power BI's dialogs ask for them.
struct CloudSourceForm: View {
    @Binding var request: SourceRequest
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @State private var showAdvanced = false
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            switch request.kind {
            case .sharePointFolder, .sharePointList:
                field("Site URL", "https://contoso.sharepoint.com/sites/Sales")
                note(request.kind == .sharePointFolder
                     ? "Lists every file in the site's document libraries. Combine them, or pick one and transform it."
                     : "Lists the site's lists; pick the ones to load.")
            case .oneDriveFile:
                field("File URL", "https://contoso-my.sharepoint.com/personal/me/Documents/Sales.xlsx")
                note("Paste a file's address (Copy link or the address bar in the browser). Excel, CSV, JSON and XML are recognised from the content.")
            case .dataverse, .dynamics365:
                field("Environment domain", "contoso.crm.dynamics.com")
                note("Tables come from the environment's Web API. Lookup columns appear as their _<name>_value ids.")
            case .azureBlobs:
                field("Account name or URL", "contoso or https://contoso.blob.core.windows.net")
                note("Uses your organizational account. To use an account key or a shared access signature instead, set it in Data source settings ▸ Edit Permissions.")
            case .azureDataLake, .lakehouse:
                if request.kind == .lakehouse {
                    field("OneLake URL", "https://onelake.dfs.fabric.microsoft.com/<workspace>/<lakehouse>.Lakehouse/Files")
                    note("Copy the URL from the lakehouse's Files folder properties in Fabric. CSV, Excel, JSON and Parquet files can be combined; Delta tables are read through the SQL analytics endpoint, which this connector doesn't use.")
                } else {
                    field("URL", "https://contoso.dfs.core.windows.net/container/folder")
                    note("Lists the files below the address. OneLake addresses (onelake.dfs.fabric.microsoft.com) work too.")
                }
            case .kusto:
                field("Cluster", "https://help.kusto.windows.net")
                LabeledContent("Database (optional)") { TextField("", text: $request.database, prompt: Text("Samples")).textFieldStyle(.roundedBorder) }
                query("Table name or Azure Data Explorer query (optional)")
            case .semanticModel:
                field("Workspace", "powerbi://api.powerbi.com/v1.0/myorg/Sales")
                LabeledContent("Semantic model") { TextField("", text: $request.database, prompt: Text("Sales Analytics")).textFieldStyle(.roundedBorder) }
                query("DAX query (optional)")
                note("Imports a snapshot of the model's tables (up to 100,000 rows per table or query) through the Power BI executeQueries API; refresh to update it. The workspace address is in the workspace's settings, under Premium ▸ Workspace connection.")
            default:
                EmptyView()
            }
            account
        }
        .sheet(isPresented: $signingIn) { SignInSheet() }
    }

    private func field(_ label: String, _ prompt: String) -> some View {
        LabeledContent(label) { TextField("", text: $request.location, prompt: Text(prompt)).textFieldStyle(.roundedBorder) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func query(_ title: String) -> some View {
        DisclosureGroup("Advanced options", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(title).font(Design.Typeface.caption).foregroundStyle(.secondary)
                TextEditor(text: $request.nativeQuery)
                    .font(Design.Typeface.mono)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            }
            .padding(.top, Design.Space.xs)
        }
    }

    /// The organizational account the connector signs in with.
    @ViewBuilder private var account: some View {
        HStack(spacing: Design.Space.s) {
            if let a = runtime.activeAccount, !a.isPersonal {
                AccountAvatar(account: a, size: 18)
                Text("Signed in as \(a.username.isEmpty ? a.displayName : a.username)").font(Design.Typeface.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.secondary)
                Text(runtime.isConfigured ? "Sign in with a work or school account to connect." : MicrosoftAuthConfiguration.missingRegistration)
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Sign In…") { signingIn = true }
                    .disabled(!runtime.isConfigured)
                    .help(runtime.isConfigured ? "Sign in with your work or school account" : "Set the app registration in Settings ▸ Microsoft account first")
            }
        }
        .padding(.top, Design.Space.xs)
    }
}
