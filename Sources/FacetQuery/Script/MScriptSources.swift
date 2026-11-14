import Foundation
import FacetCore

public extension MScript {
    /// The data sources a query script names, found without running it (the Query Dependencies view, Data source
    /// settings): connector calls whose location argument is a text literal. Kinds and locations are the ones the engine
    /// records when the connector runs: `File.Contents` → ("File", path), `Folder.Files` / `Folder.Contents` → "Folder",
    /// `Sqlite.Database` → "SQLite", `Web.Contents` → ("Web", "scheme://host"), `OData.Feed` → ("OData", "scheme://host").
    /// Connectors this build does not implement are reported under their product name ("SQL Server", "PostgreSQL",
    /// "SharePoint list", …) with the literal location, a second text argument joined with ";" (`server;database`).
    /// Paths are taken literally. No duplicates, in order of appearance.
    static func sourceReferences(in script: String) -> [QueryDataSource] {
        guard let all = StepFragment(script) else { return [] }
        let t = all.tokens
        var out: [QueryDataSource] = []
        for i in t.indices where t[i].kind == .identifier {
            guard let kind = SourceCatalog.kinds[t[i].text], i + 1 < t.endIndex, t[i + 1].kind == .punctuation, t[i + 1].text == "(",
                  let close = all.closing(i + 1), let args = all.split((i + 2)..<close),
                  let location = args.first?.textValue?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else { continue }
            let source: QueryDataSource
            switch kind {
            case "Web", "OData":
                guard let parts = URLComponents(string: location), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      let host = parts.host, !host.isEmpty else { continue }
                source = QueryDataSource(kind: kind, location: "\(scheme)://\(host)")
            case "File", "Folder", "SQLite":
                source = QueryDataSource(kind: kind, location: location)
            default:
                let second = args.count > 1 ? args[1].textValue : nil
                source = QueryDataSource(kind: kind, location: second.map { "\(location);\($0)" } ?? location)
            }
            if !out.contains(source) { out.append(source) }
        }
        return out
    }
}

private enum SourceCatalog {
    /// Connector function → the kind it is recorded under.
    static let kinds: [String: String] = [
        "File.Contents": "File", "Folder.Files": "Folder", "Folder.Contents": "Folder", "Sqlite.Database": "SQLite",
        "Web.Contents": "Web", "Web.BrowserContents": "Web", "OData.Feed": "OData",
        "Sql.Database": "SQL Server", "Sql.Databases": "SQL Server", "PostgreSQL.Database": "PostgreSQL", "MySQL.Database": "MySQL",
        "Oracle.Database": "Oracle", "Odbc.DataSource": "ODBC", "Odbc.Query": "ODBC", "OleDb.DataSource": "OLE DB",
        "AnalysisServices.Database": "Analysis Services", "Snowflake.Databases": "Snowflake", "GoogleBigQuery.Database": "Google BigQuery",
        "SharePoint.Files": "SharePoint folder", "SharePoint.Contents": "SharePoint folder", "SharePoint.Tables": "SharePoint list",
        "AzureStorage.Blobs": "Azure Blob Storage", "AzureStorage.DataLake": "Azure Data Lake Storage",
        "Exchange.Contents": "Exchange", "ActiveDirectory.Domains": "Active Directory", "Hdfs.Files": "Hadoop (HDFS)",
    ]
}
