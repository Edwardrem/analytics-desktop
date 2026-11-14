import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Get Data for Parquet and the cloud connectors: the M each writes, the source it records, and form validation.
final class CloudGetDataTests: XCTestCase {
    private func request(_ kind: SourceKind, _ location: String, database: String = "", query: String = "") -> SourceRequest {
        var r = SourceRequest(kind: kind, location: location)
        r.database = database
        r.nativeQuery = query
        return r
    }

    func testSourceStepsUsePowerBIFunctionNames() {
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.parquet, "/data/t.parquet")), #"Parquet.Document(File.Contents("/data/t.parquet"))"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.sharePointFolder, "https://contoso.sharepoint.com/sites/Sales")),
                       #"SharePoint.Files("https://contoso.sharepoint.com/sites/Sales", [ApiVersion = 15])"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.sharePointList, "https://contoso.sharepoint.com/sites/Sales")),
                       #"SharePoint.Tables("https://contoso.sharepoint.com/sites/Sales", [ApiVersion = 15])"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.dataverse, "contoso.crm.dynamics.com")), #"CommonDataService.Database("contoso.crm.dynamics.com")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.dynamics365, "contoso.crm.dynamics.com")), #"CommonDataService.Database("contoso.crm.dynamics.com")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.azureBlobs, "acct")), #"AzureStorage.Blobs("acct")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.lakehouse, "https://onelake.dfs.fabric.microsoft.com/W/L.Lakehouse/Files")),
                       #"AzureStorage.DataLake("https://onelake.dfs.fabric.microsoft.com/W/L.Lakehouse/Files")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.kusto, "help")), #"AzureDataExplorer.Contents("help")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.kusto, "help", database: "Samples", query: "Storms | take 5")),
                       #"AzureDataExplorer.Contents("help", "Samples", "Storms | take 5")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.semanticModel, "powerbi://api.powerbi.com/v1.0/myorg/Sales", database: "Revenue")),
                       #"AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/Sales", "Revenue")"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.semanticModel, "powerbi://api.powerbi.com/v1.0/myorg/Sales", database: "Revenue", query: "EVALUATE T")),
                       #"AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/Sales", "Revenue", [Query = "EVALUATE T"])"#)
        XCTAssertEqual(SourcePlanner.sourceExpression(request(.oneDriveFile, "https://contoso-my.sharepoint.com/a.xlsx")).hasPrefix("Csv.Document(Web.Contents("), true)
    }

    func testSourceStepsReadBack() {
        let cases: [SourceRequest] = [
            request(.parquet, "/data/t.parquet"),
            request(.sharePointFolder, "https://contoso.sharepoint.com/sites/Sales"),
            request(.sharePointList, "https://contoso.sharepoint.com/sites/Sales"),
            request(.dataverse, "contoso.crm.dynamics.com"),
            request(.azureBlobs, "acct"),
            request(.azureDataLake, "https://acct.dfs.core.windows.net/fs"),
            request(.lakehouse, "https://onelake.dfs.fabric.microsoft.com/W/L.Lakehouse/Files"),
            request(.kusto, "help", database: "Samples", query: "Storms"),
            request(.semanticModel, "powerbi://api.powerbi.com/v1.0/myorg/Sales", database: "Revenue", query: "EVALUATE T"),
        ]
        for r in cases {
            let back = SourcePlanner.request(fromSource: SourcePlanner.sourceExpression(r))
            XCTAssertEqual(back?.kind, r.kind, "\(r.kind)")
            XCTAssertEqual(back?.location, r.location, "\(r.kind)")
            XCTAssertEqual(back?.database, r.database, "\(r.kind)")
            XCTAssertEqual(back?.nativeQuery, r.nativeQuery, "\(r.kind)")
        }
    }

    func testDataSourcesAreNamedAsTheEngineNamesThem() {
        func source(_ r: SourceRequest) -> String? { SourcePlanner.dataSource(r).map { "\($0.kind) \($0.location)" } }
        XCTAssertEqual(source(request(.sharePointFolder, "https://Contoso.sharepoint.com/sites/Sales/")), "SharePoint https://contoso.sharepoint.com/sites/Sales")
        XCTAssertEqual(source(request(.dataverse, "https://contoso.crm4.dynamics.com/")), "CommonDataService contoso.crm4.dynamics.com")
        XCTAssertEqual(source(request(.azureBlobs, "acct")), "AzureBlobs https://acct.blob.core.windows.net")
        XCTAssertEqual(source(request(.azureDataLake, "https://acct.dfs.core.windows.net/fs/dir")), "AzureDataLakeStorage https://acct.dfs.core.windows.net")
        XCTAssertEqual(source(request(.lakehouse, "https://onelake.dfs.fabric.microsoft.com/W/L.Lakehouse/Files")),
                       "AzureDataLakeStorage https://onelake.dfs.fabric.microsoft.com/W")
        XCTAssertEqual(source(request(.kusto, "help")), "AzureDataExplorer https://help.kusto.windows.net")
        XCTAssertEqual(source(request(.oneDriveFile, "https://contoso-my.sharepoint.com/personal/a/x.csv")), "Web https://contoso-my.sharepoint.com")
        XCTAssertEqual(source(request(.parquet, "/data/t.parquet")), "File /data/t.parquet")
    }

    func testHandWrittenQueriesAreApprovedUnderTheEnginesLocation() {
        XCTAssertNil(CloudSourcePlanner.nativeQuerySource(request(.kusto, "help", database: "Samples")))
        let k = CloudSourcePlanner.nativeQuerySource(request(.kusto, "help", database: "Samples", query: "Storms"))
        XCTAssertEqual(k?.kind, "AzureDataExplorer")
        XCTAssertEqual(k?.location, "https://help.kusto.windows.net;Samples")
        let m = CloudSourcePlanner.nativeQuerySource(request(.semanticModel, " powerbi://api.powerbi.com/v1.0/myorg/Sales ", database: "Revenue", query: "EVALUATE T"))
        XCTAssertEqual(m?.kind, "AnalysisServices")
        XCTAssertEqual(m?.location, "powerbi://api.powerbi.com/v1.0/myorg/Sales")
    }

    func testValidationRefusesLookAlikeHosts() {
        XCTAssertNil(SourcePlanner.validationMessage(request(.sharePointFolder, "https://contoso.sharepoint.com/sites/Sales")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.sharePointFolder, "https://contoso.sharepoint.com.evil.com/sites/Sales")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.oneDriveFile, "https://evilsharepoint.com/a.csv")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.oneDriveFile, "http://contoso.sharepoint.com/a.csv")))
        XCTAssertNil(SourcePlanner.validationMessage(request(.oneDriveFile, "https://contoso-my.sharepoint.com/a.csv")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.dataverse, "contoso.crm.dynamics.com.evil.com")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.azureBlobs, "https://acct.blob.core.windows.net.evil.com")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.azureDataLake, "https://acct.blob.core.windows.net/fs")))
        XCTAssertNotNil(SourcePlanner.validationMessage(request(.kusto, "https://help.kusto.windows.net.evil.com")))
        XCTAssertEqual(SourcePlanner.validationMessage(request(.semanticModel, "powerbi://api.powerbi.com/v1.0/myorg/Sales")), "Type the semantic model's name.")
        XCTAssertEqual(SourcePlanner.validationMessage(request(.kusto, "help", query: "Storms")), "Choose the database the query runs in.")
    }

    func testCloudListingsCombineWithoutSampling() {
        let plan = SourcePlanner.combinePlan(extensions: [".parquet", ".parquet", ".csv"]) { _ in XCTFail("not sampled"); return nil }
        XCTAssertEqual(plan?.extension, ".parquet")
        XCTAssertTrue(SourceKind.lakehouse.listsFiles && SourceKind.sharePointFolder.listsFiles && !SourceKind.azureBlobs.listsFiles)
        XCTAssertTrue(SourceKind.oneDriveFile.readsWebContents)
    }

    func testCatalogNamesAndMarksTheCloudConnectors() {
        for (id, kind) in [("parquet", SourceKind.parquet), ("sharepoint-folder", .sharePointFolder), ("sharepoint-list", .sharePointList),
                           ("onedrive-file", .oneDriveFile), ("dataverse", .dataverse), ("dynamics365", .dynamics365), ("azure-blob", .azureBlobs),
                           ("azure-adls2", .azureDataLake), ("fabric-lakehouses", .lakehouse), ("azure-adx", .kusto), ("fabric-models", .semanticModel)] {
            XCTAssertEqual(DataConnector.connector(id)?.kind, kind, id)
        }
        XCTAssertTrue(DataConnector.connector("fabric-warehouses")?.unavailableReason?.contains("SQL endpoint") ?? false)
    }
}
