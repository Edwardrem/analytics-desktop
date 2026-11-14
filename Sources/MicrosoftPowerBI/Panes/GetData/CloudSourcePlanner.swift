import Foundation
import FacetCore
import FacetQuery

/// Get Data for the Parquet, SharePoint, Dataverse, Azure Storage, OneLake, Azure Data Explorer and Power BI semantic
/// model connectors: the M each writes (Power BI's own function names), the data source it records, and what the
/// form needs before it can connect.
extension SourceKind {
    /// Sources read through the Microsoft account or Azure (not the file system).
    var isCloud: Bool {
        [.sharePointFolder, .sharePointList, .oneDriveFile, .dataverse, .dynamics365, .azureBlobs, .azureDataLake, .lakehouse, .kusto, .semanticModel].contains(self)
    }
    /// Sources whose bytes come from `Web.Contents` and are recognised from their content.
    var readsWebContents: Bool { self == .web || self == .oneDriveFile }
    /// Sources that list files with `Folder.Files` columns (the combine step applies).
    var listsFiles: Bool { [.folder, .sharePointFolder, .azureDataLake, .lakehouse].contains(self) }
}

enum CloudSourcePlanner {
    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The `Source` step for the cloud kinds and Parquet (nil for the others).
    static func sourceExpression(_ r: SourceRequest) -> String? {
        let location = MSyntax.text(trimmed(r.location))
        let database = trimmed(r.database), query = trimmed(r.nativeQuery)
        switch r.kind {
        case .parquet: return "Parquet.Document(File.Contents(\(location)))"
        case .sharePointFolder: return "SharePoint.Files(\(location), [ApiVersion = 15])"
        case .sharePointList: return "SharePoint.Tables(\(location), [ApiVersion = 15])"
        case .dataverse, .dynamics365: return "CommonDataService.Database(\(location))"
        case .azureBlobs: return "AzureStorage.Blobs(\(location))"
        case .azureDataLake, .lakehouse: return "AzureStorage.DataLake(\(location))"
        case .kusto:
            if database.isEmpty { return "AzureDataExplorer.Contents(\(location))" }
            return "AzureDataExplorer.Contents(\(location), \(MSyntax.text(database)), \(query.isEmpty ? "null" : MSyntax.text(query)))"
        case .semanticModel:
            let options = query.isEmpty ? "" : ", [Query = \(MSyntax.text(query))]"
            return "AnalysisServices.Database(\(location), \(MSyntax.text(database))\(options))"
        default: return nil
        }
    }

    /// The data source a request reads, named as the engine names it.
    static func dataSource(_ r: SourceRequest) -> QueryDataSource? {
        let l = trimmed(r.location)
        func make(_ kind: String, _ location: String?) -> QueryDataSource? { location.map { QueryDataSource(kind: kind, location: $0) } }
        switch r.kind {
        case .parquet: return make("File", (l as NSString).expandingTildeInPath)
        case .sharePointFolder, .sharePointList: return make("SharePoint", CloudSourceLocations.sharePoint(l))
        case .dataverse, .dynamics365: return make("CommonDataService", CloudSourceLocations.dataverse(l))
        case .azureBlobs: return make("AzureBlobs", CloudSourceLocations.azureBlobs(l))
        case .azureDataLake, .lakehouse: return make("AzureDataLakeStorage", CloudSourceLocations.azureDataLake(l))
        case .kusto: return make("AzureDataExplorer", CloudSourceLocations.azureDataExplorer(l))
        case .semanticModel: return make("AnalysisServices", CloudSourceLocations.semanticModel(l))
        default: return nil
        }
    }

    /// The hand-written query of a request and the source it is approved under (nil when there is none).
    static func nativeQuerySource(_ r: SourceRequest) -> QueryDataSource? {
        guard !trimmed(r.nativeQuery).isEmpty else { return nil }
        switch r.kind {
        case .kusto:
            return CloudSourceLocations.azureDataExplorerQuery(cluster: trimmed(r.location), database: trimmed(r.database))
                .map { QueryDataSource(kind: "AzureDataExplorer", location: $0) }
        case .semanticModel:
            return CloudSourceLocations.semanticModel(r.location).map { QueryDataSource(kind: "AnalysisServices", location: $0) }
        default: return nil
        }
    }

    /// Why a request cannot be started yet (nil when it can).
    static func validationMessage(_ r: SourceRequest) -> String? {
        let l = trimmed(r.location)
        switch r.kind {
        case .parquet: return l.isEmpty ? "Choose a file." : nil
        case .sharePointFolder, .sharePointList:
            if l.isEmpty { return "Type the SharePoint site address." }
            return CloudSourceLocations.sharePoint(l) == nil ? "Type a SharePoint Online site address, such as https://contoso.sharepoint.com/sites/Sales." : nil
        case .oneDriveFile:
            if l.isEmpty { return "Paste the file's address." }
            guard let host = URLComponents(string: l)?.host?.lowercased(), l.lowercased().hasPrefix("https://"),
                  host.hasSuffix(".sharepoint.com"), !host.dropLast(".sharepoint.com".count).contains(".") else {
                return "Paste the address of a file in OneDrive for work or school or SharePoint (https://contoso-my.sharepoint.com/… or https://contoso.sharepoint.com/…)."
            }
            return nil
        case .dataverse, .dynamics365:
            if l.isEmpty { return "Type the environment domain." }
            return CloudSourceLocations.dataverse(l) == nil ? "Type a Dataverse environment domain, such as contoso.crm.dynamics.com." : nil
        case .azureBlobs:
            if l.isEmpty { return "Type the account name or URL." }
            return CloudSourceLocations.azureBlobs(l) == nil ? "Type a storage account name, or an address such as https://contoso.blob.core.windows.net." : nil
        case .azureDataLake, .lakehouse:
            if l.isEmpty { return "Type the URL." }
            return CloudSourceLocations.azureDataLake(l) == nil
                ? "Type an address such as https://contoso.dfs.core.windows.net/container, or a OneLake address (https://onelake.dfs.fabric.microsoft.com/<workspace>/<item>)." : nil
        case .kusto:
            if l.isEmpty { return "Type the cluster." }
            if CloudSourceLocations.azureDataExplorer(l) == nil { return "Type a cluster such as https://help.kusto.windows.net." }
            return !trimmed(r.nativeQuery).isEmpty && trimmed(r.database).isEmpty ? "Choose the database the query runs in." : nil
        case .semanticModel:
            if l.isEmpty { return "Type the workspace address." }
            if CloudSourceLocations.semanticModel(l) == nil { return "Type a workspace address such as powerbi://api.powerbi.com/v1.0/myorg/Sales." }
            return trimmed(r.database).isEmpty ? "Type the semantic model's name." : nil
        default: return nil
        }
    }

    /// The query name for a single-table source (the navigator item's name is used otherwise).
    static func queryName(_ r: SourceRequest) -> String? {
        let l = trimmed(r.location)
        switch r.kind {
        case .parquet: return ((l as NSString).lastPathComponent as NSString).deletingPathExtension
        case .sharePointFolder, .sharePointList, .azureDataLake, .lakehouse, .azureBlobs:
            let parts = URLComponents(string: l.contains("://") ? l : "https://" + l)
            let last = ((parts?.path ?? "") as NSString).lastPathComponent
            return last.isEmpty || last == "/" ? (parts?.host ?? l) : last
        case .dataverse, .dynamics365: return l
        case .kusto, .semanticModel:
            let d = trimmed(r.database)
            return d.isEmpty ? "Query1" : d
        default: return nil
        }
    }

    /// The connection details of a `Source` step these connectors write (the Source step's settings gear).
    static func request(fromSource expression: String) -> SourceRequest? {
        guard let ast = try? MParser.parse(expression), case .invoke(.identifier(let fn, _), let args) = ast else { return nil }
        func text(_ e: MExpr?) -> String? { if case .literal(.text(let t))? = e { return t }; return nil }
        func make(_ kind: SourceKind) -> SourceRequest? { text(args.first).map { SourceRequest(kind: kind, location: $0) } }
        switch fn {
        case "Parquet.Document":
            guard case .invoke(.identifier("File.Contents", _), let inner)? = args.first, let path = text(inner.first) else { return nil }
            return SourceRequest(kind: .parquet, location: path)
        case "SharePoint.Files": return make(.sharePointFolder)
        case "SharePoint.Tables": return make(.sharePointList)
        case "CommonDataService.Database": return make(.dataverse)
        case "AzureStorage.Blobs": return make(.azureBlobs)
        case "AzureStorage.DataLake":
            return make((text(args.first) ?? "").lowercased().contains("onelake.dfs.fabric.microsoft.com") ? .lakehouse : .azureDataLake)
        case "AzureDataExplorer.Contents":
            var r = make(.kusto)
            r?.database = text(args[safe: 1]) ?? ""
            r?.nativeQuery = text(args[safe: 2]) ?? ""
            return r
        case "AnalysisServices.Database":
            var r = make(.semanticModel)
            r?.database = text(args[safe: 1]) ?? ""
            if case .record(let fields)? = args[safe: 2] {
                for (name, value) in fields where name == "Query" { r?.nativeQuery = text(value) ?? "" }
            }
            return r
        default: return nil
        }
    }
}
