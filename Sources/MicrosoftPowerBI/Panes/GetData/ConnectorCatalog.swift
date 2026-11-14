import Foundation

/// What a connector reads, for the ones this app implements.
enum SourceKind: String, Codable, CaseIterable, Sendable {
    case csv, excel, json, xml, folder, sqlite, sqlServer, web, odata, python, r, blank
}

/// One entry of the Get Data catalog. The catalog lists everything Power BI Desktop offers; an entry is either
/// backed by the query engine (`kind`) or unavailable, with the reason shown in the list.
struct DataConnector: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case file = "File", database = "Database", fabric = "Microsoft Fabric", powerPlatform = "Power Platform"
        case azure = "Azure", onlineServices = "Online Services", other = "Other"
        var id: String { rawValue }
    }
    let id: String
    let name: String
    let category: Category
    let symbol: String
    /// Set for connectors that work.
    let kind: SourceKind?
    /// Why the connector cannot be used (nil when it works).
    let unavailableReason: String?

    var isAvailable: Bool { kind != nil }

    static func connector(_ id: String) -> DataConnector? { all.first { $0.id == id } }
    static func connector(for kind: SourceKind) -> DataConnector? { all.first { $0.kind == kind } }

    /// Catalog entries matching a search (name or category, case-insensitive) and an optional category.
    static func matching(_ search: String, in category: Category?) -> [DataConnector] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { c in
            (category == nil || c.category == category)
                && (needle.isEmpty || c.name.lowercased().contains(needle) || c.category.rawValue.lowercased().contains(needle))
        }
    }

    // MARK: Reasons

    enum Missing {
        static let driver = "Needs a database driver, which this app does not include."
        static let parquet = "Needs a Parquet reader, which this app does not include."
        static let pdf = "Needs PDF table extraction, which this app does not include."
        static let legacyExcel = "Needs a reader for the binary .xls and .xlsb formats; save the workbook as .xlsx."
        static let sharePoint = "Needs the SharePoint API with a Microsoft 365 sign-in, which the query engine does not have."
        static let fabric = "Needs the Microsoft Fabric service, which the query engine cannot connect to."
        static let powerPlatform = "Needs the Power Platform service, which the query engine cannot connect to."
        static let azure = "Needs the Azure service and its sign-in, which the query engine cannot connect to."
        static let service = "Needs this online service's API and sign-in, which the query engine does not have."
        static let windowsOnly = "Relies on a Windows-only data provider."
        static let cluster = "Needs a cluster client, which this app does not include."
        static let customConnector = "Needs the Power Query SDK runtime for .mez and .pqx extensions, which this app does not include."
    }

    private static func works(_ id: String, _ name: String, _ category: Category, _ symbol: String, _ kind: SourceKind) -> DataConnector {
        DataConnector(id: id, name: name, category: category, symbol: symbol, kind: kind, unavailableReason: nil)
    }
    private static func missing(_ id: String, _ name: String, _ category: Category, _ symbol: String, _ reason: String) -> DataConnector {
        DataConnector(id: id, name: name, category: category, symbol: symbol, kind: nil, unavailableReason: reason)
    }

    static let all: [DataConnector] = [
        // File
        works("excel", "Excel workbook", .file, "tablecells", .excel),
        works("csv", "Text/CSV", .file, "doc.plaintext", .csv),
        works("xml", "XML", .file, "chevron.left.forwardslash.chevron.right", .xml),
        works("json", "JSON", .file, "curlybraces", .json),
        works("folder", "Folder", .file, "folder", .folder),
        missing("excel-legacy", "Excel 97–2003 or binary workbook (.xls, .xlsb)", .file, "tablecells", Missing.legacyExcel),
        missing("pdf", "PDF", .file, "doc.richtext", Missing.pdf),
        missing("parquet", "Parquet", .file, "square.stack.3d.up", Missing.parquet),
        missing("sharepoint-folder", "SharePoint folder", .file, "folder.badge.gearshape", Missing.sharePoint),
        // Database
        works("sqlite", "SQLite database", .database, "cylinder", .sqlite),
        works("sqlserver", "SQL Server database", .database, "cylinder.split.1x2", .sqlServer),
        missing("access", "Access database", .database, "cylinder", Missing.windowsOnly),
        missing("ssas", "SQL Server Analysis Services database", .database, "cube", Missing.driver),
        missing("oracle", "Oracle database", .database, "cylinder", Missing.driver),
        missing("db2", "IBM Db2 database", .database, "cylinder", Missing.driver),
        missing("informix", "IBM Informix database", .database, "cylinder", Missing.driver),
        missing("netezza", "IBM Netezza", .database, "cylinder", Missing.driver),
        missing("mysql", "MySQL database", .database, "cylinder", Missing.driver),
        missing("postgresql", "PostgreSQL database", .database, "cylinder", Missing.driver),
        missing("sybase", "Sybase database", .database, "cylinder", Missing.driver),
        missing("teradata", "Teradata database", .database, "cylinder", Missing.driver),
        missing("saphana", "SAP HANA database", .database, "cylinder", Missing.driver),
        missing("sapbw", "SAP Business Warehouse", .database, "cube", Missing.driver),
        missing("redshift", "Amazon Redshift", .database, "cylinder", Missing.driver),
        missing("impala", "Impala", .database, "cylinder", Missing.driver),
        missing("bigquery", "Google BigQuery", .database, "cylinder", Missing.driver),
        missing("vertica", "Vertica", .database, "cylinder", Missing.driver),
        missing("snowflake", "Snowflake", .database, "snowflake", Missing.driver),
        missing("essbase", "Essbase", .database, "cube", Missing.driver),
        missing("mariadb", "MariaDB", .database, "cylinder", Missing.driver),
        missing("athena", "Amazon Athena", .database, "cylinder", Missing.driver),
        missing("databricks", "Databricks", .database, "cylinder", Missing.driver),
        // Microsoft Fabric
        missing("fabric-models", "Power BI semantic models", .fabric, "chart.bar.doc.horizontal", Missing.fabric),
        missing("fabric-dataflows", "Dataflows", .fabric, "arrow.triangle.branch", Missing.fabric),
        missing("fabric-datamarts", "Datamarts", .fabric, "building.columns", Missing.fabric),
        works("fabric-warehouses", "Warehouses", .fabric, "building.2", .sqlServer),
        missing("fabric-lakehouses", "Lakehouses", .fabric, "water.waves", Missing.fabric),
        missing("fabric-sql", "SQL databases", .fabric, "cylinder", Missing.fabric),
        missing("fabric-mirrored", "Mirrored databases", .fabric, "cylinder.split.1x2", Missing.fabric),
        missing("fabric-kql", "KQL databases", .fabric, "magnifyingglass", Missing.fabric),
        // Power Platform
        missing("dataverse", "Dataverse", .powerPlatform, "circle.hexagongrid", Missing.powerPlatform),
        missing("pp-dataflows", "Power Platform dataflows", .powerPlatform, "arrow.triangle.branch", Missing.powerPlatform),
        // Azure
        works("azure-sql", "Azure SQL database", .azure, "cylinder", .sqlServer),
        works("azure-synapse", "Azure Synapse Analytics SQL", .azure, "cylinder.split.1x2", .sqlServer),
        missing("azure-as", "Azure Analysis Services database", .azure, "cube", Missing.azure),
        missing("azure-postgres", "Azure Database for PostgreSQL", .azure, "cylinder", Missing.azure),
        missing("azure-blob", "Azure Blob Storage", .azure, "shippingbox", Missing.azure),
        missing("azure-table", "Azure Table Storage", .azure, "tablecells", Missing.azure),
        missing("azure-cosmos", "Azure Cosmos DB", .azure, "globe", Missing.azure),
        missing("azure-adx", "Azure Data Explorer (Kusto)", .azure, "magnifyingglass", Missing.azure),
        missing("azure-adls2", "Azure Data Lake Storage Gen2", .azure, "water.waves", Missing.azure),
        missing("azure-hdinsight", "Azure HDInsight (HDFS)", .azure, "server.rack", Missing.azure),
        missing("azure-hdinsight-spark", "Azure HDInsight Spark", .azure, "sparkles", Missing.azure),
        missing("azure-databricks", "Azure Databricks", .azure, "cylinder", Missing.azure),
        missing("azure-cost", "Azure Cost Management", .azure, "creditcard", Missing.azure),
        missing("azure-resource-graph", "Azure Resource Graph", .azure, "point.3.connected.trianglepath.dotted", Missing.azure),
        // Online services
        missing("sharepoint-list", "SharePoint Online list", .onlineServices, "list.bullet.rectangle", Missing.sharePoint),
        missing("exchange-online", "Microsoft Exchange Online", .onlineServices, "envelope", Missing.service),
        missing("outlook-mail", "Outlook Mail", .onlineServices, "envelope.open", Missing.service),
        missing("dynamics365", "Dynamics 365 (Dataverse)", .onlineServices, "circle.hexagongrid", Missing.service),
        missing("dynamics-bc", "Dynamics 365 Business Central", .onlineServices, "briefcase", Missing.service),
        missing("dynamics-nav", "Dynamics NAV", .onlineServices, "briefcase", Missing.service),
        missing("salesforce-objects", "Salesforce objects", .onlineServices, "cloud", Missing.service),
        missing("salesforce-reports", "Salesforce reports", .onlineServices, "cloud", Missing.service),
        missing("google-analytics", "Google Analytics", .onlineServices, "chart.line.uptrend.xyaxis", Missing.service),
        missing("adobe-analytics", "Adobe Analytics", .onlineServices, "chart.line.uptrend.xyaxis", Missing.service),
        missing("github", "GitHub", .onlineServices, "chevron.left.forwardslash.chevron.right", Missing.service),
        missing("linkedin", "LinkedIn Sales Navigator", .onlineServices, "person.2", Missing.service),
        missing("zendesk", "Zendesk", .onlineServices, "bubble.left.and.bubble.right", Missing.service),
        missing("azure-devops", "Azure DevOps", .onlineServices, "hammer", Missing.service),
        // Other
        works("web", "Web", .other, "globe", .web),
        works("odata", "OData feed", .other, "antenna.radiowaves.left.and.right", .odata),
        works("python", "Python script", .other, "terminal", .python),
        works("r", "R script", .other, "terminal", .r),
        works("blank", "Blank query", .other, "doc", .blank),
        missing("odbc", "ODBC", .other, "cable.connector", Missing.driver),
        missing("oledb", "OLE DB", .other, "cable.connector", Missing.windowsOnly),
        missing("spark", "Spark", .other, "sparkles", Missing.cluster),
        missing("hdfs", "Hadoop File (HDFS)", .other, "server.rack", Missing.cluster),
        missing("active-directory", "Active Directory", .other, "person.3", Missing.windowsOnly),
        missing("exchange", "Microsoft Exchange", .other, "envelope", Missing.service),
        missing("sharepoint-onprem", "SharePoint list", .other, "list.bullet.rectangle", Missing.sharePoint),
        missing("custom-connector", "Custom connector (.mez, .pqx)", .other, "puzzlepiece.extension", Missing.customConnector),
    ]
}
