import XCTest
import FacetCore
@testable import FacetQuery

/// SharePoint, OneDrive, Dataverse, Azure Data Explorer and Power BI semantic models against `URLProtocol` stubs.
/// Every token is an obvious fake (`FAKE-TOKEN-for-<resource>`); nothing reaches the network.
final class CloudConnectorTests: CloudStubTestCase {
    private func path(_ r: URLRequest) -> String { r.url?.absoluteString ?? "" }
    private let graphToken = "Bearer FAKE-TOKEN-for-https://graph.microsoft.com/.default"

    // MARK: SharePoint.Files

    private func sharePointSite(_ next: String = "https://graph.microsoft.com/v1.0/drives/d1/root/delta?page=2") {
        CloudStub.handler = { r in
            let u = r.url?.absoluteString ?? ""
            if u.hasPrefix("https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com:/sites/Sales?") { return .json(#"{"id":"site-1","webUrl":"x"}"#) }
            if u.hasPrefix("https://graph.microsoft.com/v1.0/sites/site-1/drives?") { return .json(#"{"value":[{"id":"d1","name":"Documents"}]}"#) }
            if u.hasPrefix("https://graph.microsoft.com/v1.0/drives/d1/root/delta?$select") {
                return .json(#"{"value":[{"id":"root","name":"root","folder":{},"root":{}},"# +
                             #"{"id":"i1","name":"a.csv","file":{},"size":7,"webUrl":"https://contoso.sharepoint.com/sites/Sales/Shared%20Documents/a.csv","lastModifiedDateTime":"2026-01-02T03:04:05Z"},"# +
                             #"{"id":"gone","name":"old.csv","file":{},"deleted":{"state":"deleted"}}],"@odata.nextLink":""# + next + #""}"#)
            }
            if u == "https://graph.microsoft.com/v1.0/drives/d1/root/delta?page=2" {
                return .json(#"{"value":[{"id":"i2","name":"b.json","file":{},"size":2,"webUrl":"https://contoso.sharepoint.com/sites/Sales/Shared%20Documents/Sub/b.json"}]}"#)
            }
            if u == "https://graph.microsoft.com/v1.0/drives/d1/items/i1/content" { return .bytes(Data("x,y\n1,2".utf8)) }
            return CloudStub.Response(status: 404)
        }
    }

    func testSharePointFilesListsEveryPageOfEveryLibrary() throws {
        sharePointSite()
        env.timeZone = TimeZone(identifier: "UTC") ?? .current
        let source = #"SharePoint.Files("https://contoso.sharepoint.com/sites/Sales")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(source), {\"Name\", \"Extension\", \"Folder Path\"})"), [
            ["a.csv", ".csv", "https://contoso.sharepoint.com/sites/Sales/Shared Documents/"],
            ["b.json", ".json", "https://contoso.sharepoint.com/sites/Sales/Shared Documents/Sub/"],
        ])
        XCTAssertEqual(try rows("Table.SelectColumns(Table.SelectRows(\(source), each [Name] = \"a.csv\"), {\"Date modified\"})"), [["#datetime(2026, 1, 2, 3, 4, 5)"]])
        XCTAssertEqual(try eval("Text.FromBinary(\(source){[Name=\"a.csv\"]}[Content])").textValue, "x,y\n1,2")
        // Every request went to Graph with a Graph token, and the token was asked for Graph's own host.
        XCTAssertTrue(CloudStub.requests.allSatisfy { $0.url?.host == "graph.microsoft.com" && bearer($0) == graphToken })
        XCTAssertTrue(creds.calls.allSatisfy { $0.resource == EntraResource.graph && $0.host == "graph.microsoft.com" })
    }

    func testNextLinkToAnotherHostIsNotFollowed() throws {
        sharePointSite("https://evil.example.com/steal")
        let e = try XCTUnwrap(failure(#"SharePoint.Files("https://contoso.sharepoint.com/sites/Sales")"#))
        XCTAssertTrue(e.message.contains("wasn't followed"), e.message)
        XCTAssertFalse(CloudStub.requests.contains { $0.url?.host == "evil.example.com" })
    }

    func testSharePointAddressMustBeASharePointHost() throws {
        CloudStub.handler = { _ in .json("{}") }
        for address in ["https://contoso.sharepoint.com.evil.com/sites/A", "https://evilsharepoint.com/sites/A", "https://a.b.sharepoint.com/sites/A"] {
            let e = try XCTUnwrap(failure("SharePoint.Files(\"\(address)\")"), address)
            XCTAssertTrue(e.message.contains("isn't one"), e.message)
        }
        XCTAssertTrue(CloudStub.requests.isEmpty)
        XCTAssertTrue(creds.calls.isEmpty)
    }

    // MARK: SharePoint.Tables

    func testSharePointTablesReadsVisibleListsAndTheirItems() throws {
        CloudStub.handler = { r in
            let u = r.url?.absoluteString ?? ""
            if u.contains("/sites/contoso.sharepoint.com:/sites/Sales?") { return .json(#"{"id":"site-1"}"#) }
            if u.hasPrefix("https://graph.microsoft.com/v1.0/sites/site-1/lists?") {
                return .json(#"{"value":[{"id":"L1","displayName":"Orders","list":{"hidden":false}},{"id":"L2","displayName":"Hidden","list":{"hidden":true}}]}"#)
            }
            if u == "https://graph.microsoft.com/v1.0/sites/site-1/lists/L1/columns" {
                return .json(#"{"value":[{"name":"Title","displayName":"Title"},{"name":"Qty0","displayName":"Quantity"},{"name":"_Secret","displayName":"S","hidden":true}]}"#)
            }
            if u.hasPrefix("https://graph.microsoft.com/v1.0/sites/site-1/lists/L1/items?") {
                return .json(#"{"value":[{"id":"1","fields":{"Title":"Pens","Qty0":3,"_Secret":"x"}},{"id":"2","fields":{"Title":"Ink"}}]}"#)
            }
            return CloudStub.Response(status: 404)
        }
        let source = #"SharePoint.Tables("https://contoso.sharepoint.com/sites/Sales")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(source), {\"Name\", \"Id\", \"Kind\"})"), [["Orders", "L1", "Table"]])
        XCTAssertEqual(try rows("\(source){[Name=\"Orders\"]}[Data]"), [["1", "Pens", "3"], ["2", "Ink", "null"]])
        XCTAssertEqual(columnNames(try eval("\(source){[Name=\"Orders\"]}[Data]")), ["Id", "Title", "Quantity"])
    }

    // MARK: OneDrive and SharePoint file addresses

    func testWebContentsReadsASharePointFileThroughGraphShares() throws {
        CloudStub.handler = { r in
            // u! + base64url("https://contoso.sharepoint.com/a.csv"), padding removed (worked out by hand with a Base64 table).
            r.url?.absoluteString == "https://graph.microsoft.com/v1.0/shares/u!aHR0cHM6Ly9jb250b3NvLnNoYXJlcG9pbnQuY29tL2EuY3N2/driveItem/content"
                ? .bytes(Data("k\n1".utf8)) : CloudStub.Response(status: 404)
        }
        XCTAssertEqual(try eval(#"Text.FromBinary(Web.Contents("https://contoso.sharepoint.com/a.csv?web=1"))"#).textValue, "k\n1")
        XCTAssertEqual(CloudStub.requests.count, 1)
        XCTAssertEqual(CloudStub.requests.first.flatMap(bearer), graphToken)
        XCTAssertFalse(CloudStub.requests.contains { $0.url?.host == "contoso.sharepoint.com" })
    }

    func testWebContentsRefusalAsksForCredentials() throws {
        CloudStub.handler = { _ in CloudStub.Response(status: 401) }
        let e = try XCTUnwrap(failure(#"Web.Contents("https://api.example.com/v1/items")"#))
        XCTAssertEqual(e.reason, "DataSource.Error")
        XCTAssertEqual(e.credentialSource?.kind, "Web")
        // Web credentials are kept for the address's root, as Power BI's data source path for Web is.
        XCTAssertEqual(e.credentialSource?.location, "https://api.example.com")
    }

    // MARK: Dataverse

    func testDataverseListsPublicEntitiesAndPagesRows() throws {
        CloudStub.handler = { r in
            let u = r.url?.absoluteString ?? ""
            if u.hasPrefix("https://contoso.crm4.dynamics.com/api/data/v9.2/EntityDefinitions?") {
                return .json(#"{"value":[{"LogicalName":"contact","EntitySetName":"contacts","IsPrivate":false},{"LogicalName":"secret","EntitySetName":"secrets","IsPrivate":true},{"LogicalName":"account","EntitySetName":"accounts","IsPrivate":false}]}"#)
            }
            if u == "https://contoso.crm4.dynamics.com/api/data/v9.2/accounts" {
                return .json(#"{"@odata.context":"c","value":[{"@odata.etag":"W/1","name":"Fabrikam","revenue":10}],"@odata.nextLink":"https://contoso.crm4.dynamics.com/api/data/v9.2/accounts?$skiptoken=2"}"#)
            }
            if u == "https://contoso.crm4.dynamics.com/api/data/v9.2/accounts?$skiptoken=2" {
                return .json(#"{"value":[{"name":"Contoso","revenue@OData.Community.Display.V1.FormattedValue":"$20","revenue":20}]}"#)
            }
            return CloudStub.Response(status: 404)
        }
        let source = #"CommonDataService.Database("contoso.crm4.dynamics.com")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(source), {\"Name\", \"Schema\"})"), [["account", "dbo"], ["contact", "dbo"]])
        XCTAssertEqual(try rows("\(source){[Name=\"account\"]}[Data]"), [["Fabrikam", "10"], ["Contoso", "20"]])
        let rowRequest = try XCTUnwrap(CloudStub.requests.first { $0.url?.path.hasSuffix("/accounts") ?? false })
        XCTAssertEqual(rowRequest.value(forHTTPHeaderField: "Prefer"), "odata.maxpagesize=5000")
        XCTAssertEqual(bearer(rowRequest), "Bearer FAKE-TOKEN-for-https://contoso.crm4.dynamics.com/.default")
        XCTAssertTrue(creds.calls.allSatisfy { $0.host == "contoso.crm4.dynamics.com" })
    }

    func testDataverseRefusesHostsOutsideDynamics() throws {
        CloudStub.handler = { _ in .json("{}") }
        for host in ["contoso.crm.dynamics.com.evil.com", "contoso.crmx.dynamics.com", "crm.dynamics.com", "contoso.crm123.dynamics.com"] {
            XCTAssertNotNil(failure("CommonDataService.Database(\"\(host)\")"), host)
        }
        XCTAssertTrue(CloudStub.requests.isEmpty)
    }

    // MARK: Azure Data Explorer

    private func kusto() {
        CloudStub.handler = { r in
            let body = r.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            switch r.url?.absoluteString {
            case "https://help.kusto.windows.net/v1/rest/mgmt"? where body.contains(".show databases"):
                return .json(#"{"Tables":[{"Columns":[{"ColumnName":"DatabaseName","ColumnType":"string"}],"Rows":[["Samples"]]}]}"#)
            case "https://help.kusto.windows.net/v1/rest/mgmt"? where body.contains(".show tables"):
                return .json(#"{"Tables":[{"Columns":[{"ColumnName":"TableName","ColumnType":"string"}],"Rows":[["Storms"]]}]}"#)
            case "https://help.kusto.windows.net/v1/rest/query"?:
                return .json(#"{"Tables":[{"Columns":[{"ColumnName":"State","ColumnType":"string"},{"ColumnName":"Count","ColumnType":"long"},"# +
                             #"{"ColumnName":"Wet","ColumnType":"bool"},{"ColumnName":"Took","ColumnType":"timespan"}],"Rows":[["TX",3,1,"1.02:00:30"],["WA",null,0,null]]}]}"#)
            default: return CloudStub.Response(status: 404)
            }
        }
    }

    func testKustoNavigatesDatabasesAndTables() throws {
        kusto()
        XCTAssertEqual(try rows(#"Table.SelectColumns(AzureDataExplorer.Contents("help"), {"Name", "Kind"})"#), [["Samples", "Database"]])
        let storms = #"AzureDataExplorer.Contents("help", "Samples"){[Name="Storms"]}[Data]"#
        // 1 day 2 hours 30 seconds = #duration(1, 2, 0, 30); Wet 1/0 → true/false.
        XCTAssertEqual(try rows(storms), [["TX", "3", "true", "#duration(1, 2, 0, 30)"], ["WA", "null", "false", "null"]])
        let query = try XCTUnwrap(CloudStub.requests.last { $0.url?.path == "/v1/rest/query" })
        let body = String(data: query.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""db":"Samples""#) && body.contains(#"['Storms']"#), body)
        XCTAssertEqual(bearer(query), "Bearer FAKE-TOKEN-for-https://help.kusto.windows.net/.default")
    }

    func testKustoHandWrittenQueryNeedsApproval() throws {
        kusto()
        env.requireNativeQueryApproval = true
        env.approveNativeQuery = { _ in false }
        let e = try XCTUnwrap(failure(#"AzureDataExplorer.Contents("help", "Samples", "Storms | take 2")"#))
        XCTAssertTrue(e.message.contains("Permission is required"), e.message)
        XCTAssertTrue(CloudStub.requests.isEmpty)
        env.approveNativeQuery = { $0.sourceKind == "AzureDataExplorer" }
        XCTAssertEqual(try rows(#"AzureDataExplorer.Contents("help", "Samples", "Storms | take 2")"#).count, 2)
    }

    func testKustoRefusesLookAlikeClusters() throws {
        CloudStub.handler = { _ in .json("{}") }
        for cluster in ["https://help.kusto.windows.net.evil.com", "https://evilkusto.windows.net", "http://help.kusto.windows.net"] {
            XCTAssertNotNil(failure("AzureDataExplorer.Contents(\"\(cluster)\")"), cluster)
        }
        XCTAssertTrue(CloudStub.requests.isEmpty)
    }

    // MARK: Power BI semantic models

    func testSemanticModelTablesComeFromExecuteQueries() throws {
        CloudStub.handler = { r in
            let u = r.url?.absoluteString ?? ""
            let body = r.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if u.hasPrefix("https://api.powerbi.com/v1.0/myorg/groups?") { return .json(#"{"value":[{"id":"g1","name":"Sales"}]}"#) }
            if u == "https://api.powerbi.com/v1.0/myorg/groups/g1/datasets" { return .json(#"{"value":[{"id":"ds9","name":"Revenue"}]}"#) }
            if u == "https://api.powerbi.com/v1.0/myorg/groups/g1/datasets/ds9/executeQueries" {
                if body.contains("COLUMNSTATISTICS") {
                    return .json(#"{"results":[{"tables":[{"rows":[{"[Table]":"Orders"},{"[Table]":"LocalDateTable_1"},{"[Table]":"Customers"}]}]}]}"#)
                }
                return .json(#"{"results":[{"tables":[{"rows":[{"Orders[Id]":1,"Orders[Amount]":9.5},{"Orders[Id]":2,"Orders[Amount]":null}]}]}]}"#)
            }
            return CloudStub.Response(status: 404)
        }
        let model = #"AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/Sales", "Revenue")"#
        XCTAssertEqual(try rows("Table.SelectColumns(\(model), {\"Name\"})"), [["Customers"], ["Orders"]])
        let orders = try eval("\(model){[Name=\"Orders\"]}[Data]")
        XCTAssertEqual(columnNames(orders), ["Id", "Amount"])
        XCTAssertEqual(try tableRows(orders), [["1", "9.5"], ["2", "null"]])
        let last = try XCTUnwrap(CloudStub.requests.last)
        XCTAssertTrue(String(data: last.httpBody ?? Data(), encoding: .utf8)?.contains("EVALUATE 'Orders'") ?? false)
        XCTAssertEqual(bearer(last), "Bearer FAKE-TOKEN-for-https://analysis.windows.net/powerbi/api/.default")
    }

    func testSemanticModelRefusesOtherServers() throws {
        let e = try XCTUnwrap(failure(#"AnalysisServices.Database("asazure://westus.asazure.windows.net/x", "M")"#))
        XCTAssertTrue(e.message.contains("XMLA"), e.message)
    }
}
