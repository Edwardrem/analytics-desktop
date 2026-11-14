import Foundation

/// The data source location each cloud connector records (and asks for credentials and native query approval under),
/// so the host app names a source exactly as the engine does. Nil when the address isn't one the connector accepts.
public enum CloudSourceLocations {
    /// `AzureStorage.Blobs`: `https://<account>.blob.core.windows.net`.
    public static func azureBlobs(_ account: String) -> String? {
        (try? AzureStorageSource.blobHost(account)).map { "https://" + $0.host }
    }

    /// `AzureStorage.DataLake`: `https://<account>.dfs.core.windows.net`, or OneLake plus its workspace.
    public static func azureDataLake(_ url: String) -> String? {
        guard let (host, path) = try? CloudSource.parse(url, function: "AzureStorage.DataLake"), AzureStorageSource.isDataLakeHost(host) else { return nil }
        return AzureStorageSource.dataLakeLocation(host: host, path: path)
    }

    /// `AzureDataExplorer.Contents`: `https://<cluster>.kusto.windows.net`.
    public static func azureDataExplorer(_ cluster: String) -> String? {
        (try? KustoSource.clusterHost(cluster)).map { "https://" + $0 }
    }

    /// The location a hand-written Kusto query is approved under: the cluster and the database.
    public static func azureDataExplorerQuery(cluster: String, database: String) -> String? {
        (try? KustoSource.clusterHost(cluster)).map { KustoSource.queryLocation(host: $0, database: database) }
    }

    /// `CommonDataService.Database`: the environment's host.
    public static func dataverse(_ server: String) -> String? {
        guard let (host, _) = try? CloudSource.parse(server, function: "CommonDataService.Database"), DataverseSource.isEnvironmentHost(host) else { return nil }
        return host
    }

    /// `SharePoint.Files` / `SharePoint.Tables`: the site address, `https://<tenant>.sharepoint.com/sites/<site>`.
    public static func sharePoint(_ site: String) -> String? {
        guard let (host, path) = try? CloudSource.parse(site, function: "SharePoint"), SharePointSource.isSharePointHost(host) else { return nil }
        return SharePointSource.siteLocation(host: host, path: path)
    }

    /// `AnalysisServices.Database` with a Power BI workspace address: the address as typed, trimmed.
    public static func semanticModel(_ server: String) -> String? {
        let t = server.trimmingCharacters(in: .whitespacesAndNewlines)
        do { _ = try PowerBIModelSource.workspaceName(t); return t } catch { return nil }
    }
}
