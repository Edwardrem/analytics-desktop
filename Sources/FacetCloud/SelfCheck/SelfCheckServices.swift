import Foundation
import FacetCore

// Sample payloads modelled on the public Microsoft Graph, Power BI and Fabric REST documentation.
private enum Samples {
    static let driveChildren = #"""
    {"@odata.context":"https://graph.microsoft.com/v1.0/$metadata#users('1')/drive/root/children",
     "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=abc",
     "value":[
      {"id":"01FOLDER","name":"Reports","size":1048576,"createdDateTime":"2024-01-10T09:00:00Z","lastModifiedDateTime":"2024-03-05T10:20:30.123Z",
       "eTag":"\"{F1},2\"","cTag":"\"c:{F1},0\"","webUrl":"https://contoso-my.sharepoint.com/personal/ana/Documents/Reports",
       "folder":{"childCount":7},"parentReference":{"driveId":"b!drive1","driveType":"business","id":"01ROOT","path":"/drive/root:"}},
      {"id":"01FILE","name":"Sales Q1.PBIX","size":5242880,"lastModifiedDateTime":"2024-03-06T08:00:00Z","eTag":"\"{F2},5\"",
       "@microsoft.graph.downloadUrl":"https://contoso-my.sharepoint.com/download?tempauth=xyz",
       "file":{"mimeType":"application/octet-stream","hashes":{"quickXorHash":"abc="}},
       "lastModifiedBy":{"user":{"displayName":"Ana Müller"}},
       "parentReference":{"driveId":"b!drive1","id":"01ROOT","path":"/drive/root:"}},
      {"id":"01SHARED","lastModifiedDateTime":"2024-02-01T00:00:00Z",
       "remoteItem":{"id":"REMOTE1","name":"Budget.xlsx","size":2048,"file":{"mimeType":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
                     "parentReference":{"driveId":"b!otherdrive","id":"P1"},"webUrl":"https://contoso.sharepoint.com/Budget.xlsx"}}
     ]}
    """#
    static let graphError = #"{"error":{"code":"itemNotFound","message":"The resource could not be found.","innerError":{"date":"2024-03-05T10:20:30","request-id":"req-123","client-request-id":"c-1"}}}"#
    static let item = #"{"id":"NEW1","name":"Model.facet","size":12,"eTag":"\"e1\"","file":{"mimeType":"application/octet-stream"},"parentReference":{"driveId":"b!drive1","id":"01ROOT"}}"#

    static let executeQueries = #"""
    {"results":[{"tables":[{"rows":[
      {"Sales[Region]":"West","Sales[Order Date]":"2024-01-31T00:00:00","[Total Sales]":1234.5,"[Orders]":10,"[Is Top]":true,"Product[Name]":"Bike","Sales[Name]":"S1"},
      {"Sales[Region]":"East","Sales[Order Date]":"2024-02-29T00:00:00","[Total Sales]":99,"[Orders]":3,"[Is Top]":false,"Product[Name]":null,"Sales[Name]":"S2"}
    ]}]}]}
    """#
    static let pbiError = #"{"error":{"code":"DatasetExecuteQueriesError","pbi.error":{"code":"DatasetExecuteQueriesError","parameters":{},"details":[{"code":"DetailsMessage","detail":{"type":1,"value":"Failed to resolve name 'Salez'."}},{"code":"AnalysisServicesErrorCode","detail":{"type":1,"value":"3241803779"}}]}}}"#
    static let viewTables = #"{"results":[{"tables":[{"rows":[{"[ID]":1,"[Name]":"Sales","[Description]":"Fact table","[IsHidden]":false,"[StorageMode]":"Import"},{"[ID]":2,"[Name]":"Date","[Description]":null,"[IsHidden]":false}]}]}]}"#
    static let viewColumns = ##"{"results":[{"tables":[{"rows":[{"[Table]":"Sales","[Name]":"Amount","[DataType]":"Double","[FormatString]":"#,0.00","[IsHidden]":false,"[SummarizeBy]":"Sum","[DataCategory]":null},{"[Table]":"Sales","[Name]":"City","[DataType]":"String","[DataCategory]":"City","[SummarizeBy]":"None","[IsHidden]":true},{"[Table]":"Date","[Name]":"Date","[DataType]":"DateTime","[IsKey]":true,"[IsNullable]":false},{"[Table]":"Sales","[Name]":"RowNumber-2662979B","[DataType]":"Int64"}]}]}]}"##
    static let viewMeasures = #"{"results":[{"tables":[{"rows":[{"[Table]":"Sales","[Name]":"Total Sales","[Expression]":"SUM(Sales[Amount])","[FormatString]":"$#,0","[DisplayFolder]":"KPIs","[Description]":"All sales"}]}]}]}"#
    static let viewRelationships = #"{"results":[{"tables":[{"rows":[{"[FromTable]":"Sales","[FromColumn]":"Order Date","[FromCardinality]":"Many","[ToTable]":"Date","[ToColumn]":"Date","[ToCardinality]":"One","[IsActive]":true,"[CrossFilteringBehavior]":"BothDirections"}]}]}]}"#
    static let groups = #"{"value":[{"id":"g1","isReadOnly":false,"isOnDedicatedCapacity":true,"capacityId":"cap1","type":"Workspace","name":"Finance"}]}"#
    static let datasets = #"{"value":[{"id":"d1","name":"Sales model","configuredBy":"ana@contoso.com","isRefreshable":true,"targetStorageMode":"PremiumFiles","createdDate":"2024-01-01T10:00:00.123Z","webUrl":"https://app.powerbi.com/x"}]}"#
    static let refreshes = #"{"value":[{"requestId":"r1","refreshType":"ViaApi","startTime":"2024-03-01T01:00:00.000Z","endTime":"2024-03-01T01:05:00Z","status":"Completed"},{"requestId":"r2","refreshType":"Scheduled","startTime":"2024-03-02T01:00:00Z","status":"Unknown"}]}"#
    static let capacities = #"{"value":[{"id":"cap1","displayName":"Fabric F64","sku":"F64","state":"Active","region":"West Europe","capacityUserAccessRight":"Admin"},{"id":"cap2","displayName":"Embedded","sku":"A2","state":"Active"}]}"#
    static let datasources = #"{"value":[{"datasourceType":"Sql","datasourceId":"ds1","gatewayId":"gw1","connectionDetails":{"server":"sql.contoso.com","database":"Sales"}}]}"#

    static let fabricItems = #"{"value":[{"id":"i1","displayName":"Lake","description":"Raw data","type":"Lakehouse","workspaceId":"w1","sensitivityLabel":{"id":"lab1"},"endorsementDetails":{"endorsement":"Certified","certifiedBy":"Data Office"}},{"id":"i2","displayName":"Mystery","type":"FutureThing","workspaceId":"w1"}],"continuationUri":"https://api.fabric.microsoft.com/v1/workspaces/w1/items?continuationToken=tok2","continuationToken":"tok2"}"#
    static let fabricItemsPage2 = #"{"value":[{"id":"i3","displayName":"Model","type":"SemanticModel","workspaceId":"w1"}]}"#
    static let oneLakeListing = #"{"paths":[{"name":"lake1/Files/raw","isDirectory":"true","contentLength":"0","lastModified":"Tue, 05 Mar 2024 10:20:30 GMT","etag":"0x1"},{"name":"lake1/Files/sales.csv","contentLength":"2048","lastModified":"Tue, 05 Mar 2024 11:00:00 GMT"}]}"#
}

extension FacetCloudSelfCheck {
    // MARK: Decoding

    static func checkGraphDecoding(_ c: Checker) throws {
        let page = try HTTPHelpers.makeDecoder().decode(GraphPage<DriveItem>.self, from: Data(Samples.driveChildren.utf8))
        c.equal(page.items.count, 3, "three drive items")
        c.equal(page.nextLink?.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=abc", "@odata.nextLink")
        let folder = page.items[0], file = page.items[1], shared = page.items[2]
        c.expect(folder.isFolder && folder.childCount == 7 && folder.mimeType == nil, "folder facet")
        c.equal(folder.modified, HTTPHelpers.parseISODate("2024-03-05T10:20:30.123Z"), "fractional-second date")
        c.equal(folder.eTag, "\"{F1},2\"", "eTag")
        c.equal(folder.parentReference?.driveId, "b!drive1", "parentReference")
        c.expect(!file.isFolder && file.size == 5_242_880 && file.mimeType == "application/octet-stream", "file facet")
        c.equal(file.fileExtension, "pbix", "extension is lower-cased")
        c.equal(file.downloadURL?.host, "contoso-my.sharepoint.com", "@microsoft.graph.downloadUrl")
        c.equal(file.lastModifiedBy, "Ana Müller", "lastModifiedBy")
        c.equal(file.location, .item(driveID: "b!drive1", itemID: "01FILE"), "item location")
        c.equal(shared.name, "Budget.xlsx", "remote item name")
        c.equal(shared.location, .item(driveID: "b!otherdrive", itemID: "REMOTE1"), "remote item resolves to its own drive")

        c.equal(DriveLocation.myRoot.subresource("children"), "/me/drive/root/children", "root children path")
        c.equal(DriveLocation.myPath("Reports/2024 Q1/a&b.facet").resourcePath, "/me/drive/root:/Reports/2024%20Q1/a%26b.facet:", "path addressing is encoded")
        c.equal(DriveLocation.myPath("Reports").subresource("children"), "/me/drive/root:/Reports:/children", "path children")
        c.equal(DriveLocation.item(driveID: "b!d", itemID: "01X").childPath(named: "New File.facet"), "/drives/b%21d/items/01X:/New%20File.facet:", "child by name under item")
        c.equal(DriveLocation.myPath("Reports").childPath(named: "x.csv"), "/me/drive/root:/Reports/x.csv:", "child by name under path")
        c.equal(DriveLocation.myRoot.childPath(named: "x.csv"), "/me/drive/root:/x.csv:", "child by name under root")
        c.equal(GraphClient.nextOffset(from: ["26214400-", "52428800-"]), 26_214_400, "nextExpectedRanges")
        c.expect(GraphClient.uploadChunkSize % 327_680 == 0 && (5...10).contains(GraphClient.uploadChunkSize / 1_048_576), "chunk size is a 320 KiB multiple within 5–10 MiB")

        let http = HTTPURLResponse(url: URL(string: "https://graph.microsoft.com/v1.0/x")!, statusCode: 404, httpVersion: nil, headerFields: ["request-id": "hdr-9"])!
        let err = GraphError.from(service: "Microsoft Graph", response: http, data: Data(Samples.graphError.utf8))
        c.equal(err.kind, .notFound, "error kind")
        c.equal(err.code, "itemNotFound", "error code")
        c.equal(err.message, "The resource could not be found.", "error message")
        c.equal(err.requestID, "req-123", "request id from innerError")
        c.expect(err.errorDescription?.contains("req-123") == true && err.errorDescription?.contains("Microsoft Graph") == true, "error description carries service and request id")
        let bare = GraphError.from(service: "Microsoft Graph", response: http, data: Data("<html>".utf8))
        c.equal(bare.requestID, "hdr-9", "request id falls back to header")
    }

    static func checkPowerBIDecoding(_ c: Checker) throws {
        let t = try DAXResultParser.dataTable(from: Data(Samples.executeQueries.utf8))
        c.equal(t.columnNames, ["Region", "Order Date", "Total Sales", "Orders", "Is Top", "Name", "Sales[Name]"], "column order and prefix stripping (collision keeps full name)")
        c.equal(t.rowCount, 2, "row count")
        c.equal(t.columns.map(\.type), [.text, .date, .decimal, .integer, .boolean, .text, .text], "inferred types")
        c.equal(t[0, 2], .double(1234.5), "decimal value")
        c.equal(t[1, 2], .int(99), "whole number in a decimal column keeps its value")
        c.equal(t[1, 5], .null, "null preserved")
        c.equal(t[0, 1], .date(HTTPHelpers.parseISODate("2024-01-31T00:00:00Z")!), "date parsed")
        let raw = try DAXResultParser.dataTable(from: Data(Samples.executeQueries.utf8), stripTablePrefixes: false)
        c.equal(raw.columnNames.first, "Sales[Region]", "prefixes kept on request")
        c.equal(DAXResultParser.displayName(forResultKey: "'My [odd] Table'[Col]]umn]"), "Col]umn", "quoted table and escaped bracket")
        c.equal(DAXResultParser.displayName(forResultKey: "Plain"), "Plain", "plain key untouched")
        c.expect(!DAXResultParser.looksLikeISODateTime("2024-01-31") && !DAXResultParser.looksLikeISODateTime("Order 2024-01-31T00:00"), "text is not mistaken for dates")
        do { _ = try DAXResultParser.dataTable(from: Data(Samples.pbiError.utf8)); c.fail("error body not detected") }
        catch let e as CloudAPIError {
            c.equal(e.code, "DatasetExecuteQueriesError", "DAX error code")
            c.expect(e.message.contains("Failed to resolve name 'Salez'."), "DAX error detail surfaced")
        }
        let http = HTTPURLResponse(url: URL(string: "https://api.powerbi.com/x")!, statusCode: 400, httpVersion: nil, headerFields: ["RequestId": "pbi-req-1"])!
        let e = CloudAPIError.from(service: "Power BI", response: http, data: Data(Samples.pbiError.utf8))
        c.expect(e.message.contains("Failed to resolve name") && e.requestID == "pbi-req-1" && e.kind == .badRequest, "Power BI HTTP error parsed")

        func table(_ s: String) throws -> DataTable { try DAXResultParser.dataTable(from: Data(s.utf8)) }
        let model = LiveModelBuilder.build(name: "Sales model", tables: try table(Samples.viewTables), columns: try table(Samples.viewColumns),
                                           measures: try table(Samples.viewMeasures), relationships: try table(Samples.viewRelationships))
        c.equal(model.tables.map(\.name), ["Sales", "Date"], "model tables")
        c.expect(model.tables.allSatisfy { $0.storageMode == .live }, "tables are live-connected")
        let sales = model.table("Sales")
        c.equal(sales?.columns.map(\.name), ["Amount", "City"], "columns (internal RowNumber column skipped)")
        c.equal(sales?.column("Amount")?.dataType, .decimal, "column type")
        c.equal(sales?.column("Amount")?.formatString, "#,0.00", "column format")
        c.equal(sales?.column("City")?.dataCategory, .city, "data category")
        c.equal(sales?.column("City")?.isHidden, true, "hidden column")
        c.equal(sales?.column("City")?.summarizeBy, Aggregation.none, "summarizeBy")
        c.equal(model.table("Date")?.column("Date")?.isKey, true, "key column")
        c.equal(model.table("Date")?.column("Date")?.isNullable, false, "nullable")
        c.equal(model.measure("Total Sales")?.measure.expression, "SUM(Sales[Amount])", "measure expression")
        c.equal(model.measure("Total Sales")?.measure.displayFolder, "KPIs", "measure folder")
        c.equal(model.relationships.count, 1, "relationship count")
        c.expect(model.relationships.first?.cardinality == .manyToOne && model.relationships.first?.crossFilter == .both
                 && model.relationships.first?.toTable == "Date", "relationship details")

        let d = HTTPHelpers.makeDecoder()
        let groups = try d.decode(PowerBIList<PowerBIWorkspace>.self, from: Data(Samples.groups.utf8)).value
        c.expect(groups.first?.name == "Finance" && groups.first?.isOnDedicatedCapacity == true && groups.first?.ref == .group(id: "g1"), "workspace decoding")
        c.equal(PowerBIWorkspace.myWorkspace.ref, .myWorkspace, "My workspace reference")
        c.equal(PowerBIWorkspaceRef.group(id: "g 1").pathPrefix, "/groups/g%201", "workspace path prefix")
        let datasets = try d.decode(PowerBIList<PowerBIDataset>.self, from: Data(Samples.datasets.utf8)).value
        c.expect(datasets.first?.isRefreshable == true && datasets.first?.createdDate != nil, "dataset decoding")
        let refreshes = try d.decode(PowerBIList<PowerBIRefresh>.self, from: Data(Samples.refreshes.utf8)).value
        c.expect(refreshes.count == 2 && refreshes[0].status == "Completed" && refreshes[0].endTime != nil && refreshes[1].isInProgress, "refresh history decoding")
        let caps = try d.decode(PowerBIList<PowerBICapacity>.self, from: Data(Samples.capacities.utf8)).value
        c.expect(caps[0].isFabricOrPremium && !caps[1].isFabricOrPremium, "capacity SKU classification")
        let sources = try d.decode(PowerBIList<PowerBIDatasource>.self, from: Data(Samples.datasources.utf8)).value
        c.equal(sources.first?.connectionDetails?["server"], "sql.contoso.com", "datasource connection details")
    }

    static func checkFabricDecoding(_ c: Checker) throws {
        struct Page: Decodable { let value: [FabricItem] }
        let items = try HTTPHelpers.makeDecoder().decode(Page.self, from: Data(Samples.fabricItems.utf8)).value
        c.expect(items[0].itemType == .lakehouse && items[0].endorsement == "Certified" && items[0].certifiedBy == "Data Office"
                 && items[0].sensitivityLabelID == "lab1", "item with endorsement and sensitivity label")
        c.expect(items[1].itemType == nil && items[1].type == "FutureThing" && items[1].endorsement == nil, "unknown item type preserved")
        let parts = [FabricDefinitionPart(path: "definition/model.tmdl", text: "model Model\n\tculture: en-US\n"),
                     FabricDefinitionPart(path: "definition.pbism", text: "{\"version\":\"4.0\"}")]
        let body = FabricClient.definitionBody(parts)
        c.equal(body["definition"]?["parts"]?[0]?["payloadType"]?.stringValue, "InlineBase64", "definition payload type")
        c.equal(try FabricClient.parseDefinition(body.serializedData()), parts, "definition round trip")
        c.equal(parts[0].text, "model Model\n\tculture: en-US\n", "TMDL text")
        c.expect((try? FabricClient.parseDefinition(Data(#"{"definition":{"parts":[{"path":"a","payload":"x","payloadType":"Other"}]}}"#.utf8))) == nil, "unsupported payload type rejected")
        let paths = try FabricClient.parseOneLakeListing(Data(Samples.oneLakeListing.utf8))
        c.expect(paths.count == 2 && paths[0].isDirectory && !paths[1].isDirectory && paths[1].size == 2048 && paths[1].name == "sales.csv"
                 && paths[0].lastModified != nil, "OneLake listing (string-typed fields)")
    }

    // MARK: Stubbed HTTP

    static func checkRESTClient(_ c: Checker) async throws {
        let provider = StubTokenProvider()
        let rest = RESTClient(service: "Microsoft Graph", scope: "scope-x", tokenProvider: provider,
                              session: RESTClient.makeSession(SelfCheckURLProtocol.configuration()),
                              policy: EndpointPolicy(cloud: .public, extraHosts: ["graph.example"]))
        let sleeps = Recorder<[TimeInterval]>([])
        rest.sleeper = { s in sleeps.update { $0.append(s) } }
        let seen = Recorder<[String]>([])
        let url = URL(string: "https://graph.example/v1.0/me")!

        // 401 → one forced refresh → retry with the new token.
        SelfCheckURLProtocol.handler = { req, _ in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.update { $0.append(auth) }
            return auth == "Bearer fresh-token" ? .json(#"{"id":"u1"}"#) : .json(#"{"error":{"code":"InvalidAuthenticationToken","message":"expired"}}"#, status: 401)
        }
        let (data, _) = try await rest.send(rest.request("GET", url))
        c.equal(String(decoding: data, as: UTF8.self), #"{"id":"u1"}"#, "401 recovered")
        c.equal(seen.value, ["Bearer stale-token", "Bearer fresh-token"], "retried once with refreshed token")
        c.equal(provider.calls.value.filter(\.forced).count, 1, "exactly one forced refresh")

        // A second 401 after refreshing is surfaced, not retried forever.
        SelfCheckURLProtocol.handler = { _, _ in .json(#"{"error":{"code":"InvalidAuthenticationToken","message":"still bad"}}"#, status: 401) }
        do { _ = try await rest.send(rest.request("GET", url)); c.fail("persistent 401 not thrown") }
        catch let e as CloudAPIError { c.equal(e.kind, .unauthorized, "persistent 401 thrown") }

        // 429 with Retry-After, then 503 without, then success.
        let count = Recorder(0)
        SelfCheckURLProtocol.handler = { _, _ in
            count.update { $0 += 1 }
            switch count.value {
            case 1: return .json("{}", status: 429, headers: ["Retry-After": "3"])
            case 2: return .json("{}", status: 503)
            default: return .json(#"{"ok":true}"#)
            }
        }
        _ = try await rest.send(rest.request("GET", url))
        c.equal(count.value, 3, "throttling retried until success")
        c.equal(sleeps.value.first, 3, "Retry-After honoured")
        c.expect((sleeps.value.dropFirst().first ?? 0) >= 2 && (sleeps.value.dropFirst().first ?? 99) <= 2.5, "exponential backoff used without Retry-After")

        // Retries are capped.
        sleeps.update { $0 = [] }
        SelfCheckURLProtocol.handler = { _, _ in .json(#"{"error":{"code":"activityLimitReached","message":"slow down"}}"#, status: 429, headers: ["Retry-After": "1"]) }
        do { _ = try await rest.send(rest.request("GET", url)); c.fail("endless throttling not thrown") }
        catch let e as CloudAPIError {
            c.expect(e.kind == .throttled && e.retryAfter == 1 && e.code == "activityLimitReached", "throttling error after retries")
            c.equal(sleeps.value.count, rest.maxRetries, "retry cap respected")
        }

        // Unauthenticated sends carry no bearer token.
        SelfCheckURLProtocol.handler = { req, _ in .json(req.value(forHTTPHeaderField: "Authorization") == nil ? "{}" : #"{"leak":true}"#) }
        let (plain, _) = try await rest.send(URLRequest(url: url), authenticated: false)
        c.equal(String(decoding: plain, as: UTF8.self), "{}", "pre-signed URLs get no Authorization header")

        // Cancellation.
        let task = Task { () -> Bool in
            do { _ = try await rest.send(rest.request("GET", url)); return false } catch { return error is CancellationError }
        }
        task.cancel()
        c.expect(await task.value, "cancelled task throws CancellationError")
    }

    static func checkGraphClientStubbed(_ c: Checker) async throws {
        let provider = StubTokenProvider()
        let graph = GraphClient(tokenProvider: provider, sessionConfiguration: SelfCheckURLProtocol.configuration())
        graph.rest.sleeper = { _ in }
        let requests = Recorder<[(method: String, url: String, auth: Bool, range: String?, bytes: Int)]>([])
        let chunkFailures = Recorder(0)
        let chunk = Int64(GraphClient.uploadChunkSize)
        let total = chunk * 2 + 1234
        SelfCheckURLProtocol.handler = { req, body in
            let url = req.url?.absoluteString ?? ""
            requests.update { $0.append((req.httpMethod ?? "GET", url, req.value(forHTTPHeaderField: "Authorization") != nil, req.value(forHTTPHeaderField: "Content-Range"), body.count)) }
            if url.contains("$skiptoken=abc") { return .json(#"{"value":[{"id":"LAST","name":"last.csv","file":{}}]}"#) }
            if url.hasSuffix("/me/drive/root/children?$top=200") { return .json(Samples.driveChildren) }
            if url.contains("/search(") { return .json(#"{"value":[]}"#) }
            if url.contains("createUploadSession") { return .json(#"{"uploadUrl":"https://upload.example/session/1","expirationDateTime":"2030-01-01T00:00:00Z","nextExpectedRanges":["0-"]}"#) }
            if url.hasPrefix("https://upload.example/session/1") {
                guard req.httpMethod == "PUT", let range = req.value(forHTTPHeaderField: "Content-Range") else { return .json("{}") }
                let start = Int64(range.dropFirst(6).split(separator: "-").first ?? "") ?? -1
                if start == chunk, chunkFailures.value == 0 {
                    chunkFailures.update { $0 += 1 }
                    return .json(#"{"error":{"code":"serviceNotAvailable","message":"busy"}}"#, status: 503)
                }
                if start + Int64(body.count) >= total { return .json(Samples.item, status: 201) }
                return .json(#"{"nextExpectedRanges":["\#(start + Int64(body.count))-"]}"#, status: 202)
            }
            if url.contains("/content?@microsoft.graph.conflictBehavior=rename"), req.httpMethod == "PUT" { return .json(Samples.item, status: 201) }
            if url.hasSuffix("/createLink") { return .json(#"{"id":"perm1","roles":["read"],"link":{"type":"view","scope":"organization","webUrl":"https://contoso.sharepoint.com/:u:/s/abc"}}"#, status: 201) }
            if url.hasSuffix("/content") { return SelfCheckURLProtocol.Response(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data("FILE-BYTES".utf8)) }
            if url.contains("/me/photo/") { return .json(#"{"error":{"code":"ImageNotFound","message":"no photo"}}"#, status: 404) }
            return .json(Samples.graphError, status: 404)
        }

        let all = try await graph.allChildren(of: .myRoot)
        c.equal(all.map(\.id), ["01FOLDER", "01FILE", "01SHARED", "LAST"], "paging follows @odata.nextLink")
        _ = try await graph.search("O'Brien & co")
        c.expect(requests.value.last?.url.contains("/me/drive/root/search(q='O%27%27Brien%20%26%20co')") == true, "search literal is escaped: \(requests.value.last?.url ?? "")")
        c.expect(try await graph.myPhoto() == nil, "missing photo → nil")
        do { _ = try await graph.item(at: .myItem(id: "missing")); c.fail("404 not thrown") }
        catch let e as GraphError { c.expect(e.kind == .notFound && e.requestID == "req-123", "typed GraphError from service JSON") }

        let small = try await graph.upload(data: Data("hello".utf8), to: .myPath("Reports"), named: "Model.facet", conflict: .rename)
        c.equal(small.id, "NEW1", "simple upload returns the item")
        c.expect(requests.value.last?.url.hasSuffix("/me/drive/root:/Reports/Model.facet:/content?@microsoft.graph.conflictBehavior=rename") == true
                 && requests.value.last?.method == "PUT" && requests.value.last?.bytes == 5, "simple upload request")

        let link = try await graph.createSharingLink(for: .myItem(id: "01FILE"), type: .view, scope: .organization)
        c.equal(link.webURL.absoluteString, "https://contoso.sharepoint.com/:u:/s/abc", "sharing link")

        // Resumable upload: 2 full chunks + remainder, with one 503 on the second chunk.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facet-selfcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(total))
        try handle.close()
        requests.update { $0 = [] }
        let progress = Recorder<[Int64]>([])
        let uploaded = try await graph.upload(fileAt: big, to: .myRoot, conflict: .replace) { p in progress.update { $0.append(p.completedBytes) } }
        c.equal(uploaded.id, "NEW1", "resumable upload returns the item")
        let puts = requests.value.filter { $0.url.hasPrefix("https://upload.example") && $0.method == "PUT" }
        c.equal(puts.map { $0.range ?? "" }, [
            "bytes 0-\(chunk - 1)/\(total)", "bytes \(chunk)-\(2 * chunk - 1)/\(total)", "bytes \(chunk)-\(2 * chunk - 1)/\(total)", "bytes \(2 * chunk)-\(total - 1)/\(total)",
        ], "chunk ranges, with the failed chunk retried")
        c.expect(puts.allSatisfy { !$0.auth }, "upload-session requests carry no bearer token")
        c.equal(progress.value.last, total, "progress reaches the total")
        c.expect(progress.value == progress.value.sorted(), "progress is monotonic")

        // Download to disk.
        let dest = dir.appendingPathComponent("out.bin")
        let file = try await graph.download(.myItem(id: "01FILE"), suggestedName: "x.bin", destination: dest)
        c.equal(try Data(contentsOf: file), Data("FILE-BYTES".utf8), "download streamed to file")
    }

    static func checkPowerBIFabricStubbed(_ c: Checker) async throws {
        let provider = StubTokenProvider()
        let pbi = PowerBIClient(tokenProvider: provider, sessionConfiguration: SelfCheckURLProtocol.configuration())
        let fabric = FabricClient(tokenProvider: provider, sessionConfiguration: SelfCheckURLProtocol.configuration())
        pbi.rest.sleeper = { _ in }
        let waits = Recorder<[TimeInterval]>([])
        fabric.rest.sleeper = { s in waits.update { $0.append(s) } }
        let log = Recorder<[(method: String, url: String, body: String, contentType: String)]>([])
        let importPolls = Recorder(0), opPolls = Recorder(0)
        SelfCheckURLProtocol.handler = { req, body in
            let url = req.url?.absoluteString ?? ""
            let text = String(decoding: body, as: UTF8.self)
            log.update { $0.append((req.httpMethod ?? "GET", url, text, req.value(forHTTPHeaderField: "Content-Type") ?? "")) }
            if url.contains("/groups?$top=") { return .json(Samples.groups) }
            if url.hasSuffix("/executeQueries") {
                if text.contains("INFO.VIEW.TABLES") { return .json(Samples.viewTables) }
                if text.contains("INFO.VIEW.COLUMNS") { return .json(Samples.viewColumns) }
                if text.contains("INFO.VIEW.MEASURES") { return .json(Samples.viewMeasures) }
                if text.contains("INFO.VIEW.RELATIONSHIPS") { return .json(Samples.viewRelationships) }
                if text.contains("Salez") { return .json(Samples.pbiError, status: 400, headers: ["RequestId": "pbi-req-7"]) }
                return .json(Samples.executeQueries)
            }
            if url.contains("/imports?") { return .json(#"{"id":"imp1"}"#, status: 202) }
            if url.hasSuffix("/imports/imp1") {
                importPolls.update { $0 += 1 }
                return importPolls.value < 3 ? .json(#"{"id":"imp1","importState":"Publishing","name":"Sales"}"#)
                    : .json(#"{"id":"imp1","importState":"Succeeded","name":"Sales","reports":[{"id":"rep1","name":"Sales","webUrl":"https://app.powerbi.com/r"}],"datasets":[{"id":"ds1","name":"Sales"}]}"#)
            }
            if url.hasSuffix("/refreshes"), req.httpMethod == "POST" { return .json("", status: 202, headers: ["x-ms-request-id": "refresh-1"]) }
            if url.contains("/refreshes?$top=") { return .json(Samples.refreshes) }
            if url.hasSuffix("/v1/workspaces/w1/items") { return .json(Samples.fabricItems) }
            if url.contains("items?continuationToken=tok2") { return .json(Samples.fabricItemsPage2) }
            if url.contains("/getDefinition") {
                return .json("", status: 202, headers: ["Location": "https://api.fabric.microsoft.com/v1/operations/op1", "x-ms-operation-id": "op1", "Retry-After": "4"])
            }
            if url.hasSuffix("/v1/operations/op1") {
                opPolls.update { $0 += 1 }
                return opPolls.value < 2 ? .json(#"{"status":"Running","percentComplete":40}"#, headers: ["Retry-After": "2"])
                    : .json(#"{"status":"Succeeded","percentComplete":100}"#, headers: ["Location": "https://api.fabric.microsoft.com/v1/operations/op1/result"])
            }
            if url.hasSuffix("/v1/operations/op1/result") {
                return .json(FabricClient.definitionBody([FabricDefinitionPart(path: "definition/model.tmdl", text: "model Model")]).serialized())
            }
            if url.contains("/updateDefinition") { return .json("", status: 202, headers: ["x-ms-operation-id": "op2"]) }
            if url.hasSuffix("/v1/operations/op2") { return .json(#"{"status":"Failed","error":{"errorCode":"InvalidDefinition","message":"TMDL syntax error at line 3"}}"#) }
            if url.contains("onelake.dfs.fabric.microsoft.com/w1?") {
                return url.contains("continuation=next1") ? .json(#"{"paths":[{"name":"lake1/Files/z.parquet","contentLength":"9"}]}"#)
                    : .json(Samples.oneLakeListing, headers: ["x-ms-continuation": "next1"])
            }
            if url.contains("sensitivityLabels") { return .json(#"{"error":{"code":"Forbidden","message":"Insufficient privileges"}}"#, status: 403) }
            return .json(#"{"error":{"code":"NotFound","message":"unexpected \#(url)"}}"#, status: 404)
        }

        let workspaces = try await pbi.workspaces()
        c.equal(workspaces.map(\.name), ["My workspace", "Finance"], "workspaces include My workspace")

        let table = try await pbi.executeQuery("EVALUATE Sales", datasetID: "d1", in: .group(id: "g1"), impersonatedUserName: "bob@contoso.com")
        c.equal(table.rowCount, 2, "executeQueries → DataTable")
        let q = log.value.last
        let sent = try JSONValue.parse(q?.body ?? "")
        c.expect(q?.url.hasSuffix("/v1.0/myorg/groups/g1/datasets/d1/executeQueries") == true && q?.method == "POST", "executeQueries URL")
        c.equal(sent["queries"]?[0]?["query"]?.stringValue, "EVALUATE Sales", "DAX sent")
        c.equal(sent["serializerSettings"]?["includeNulls"], .bool(true), "includeNulls")
        c.equal(sent["impersonatedUserName"]?.stringValue, "bob@contoso.com", "impersonation")
        do { _ = try await pbi.executeQuery("EVALUATE Salez", datasetID: "d1"); c.fail("DAX error not thrown") }
        catch let e as CloudAPIError { c.expect(e.message.contains("Salez") && e.requestID == "pbi-req-7", "DAX error carries message and request id") }

        let model = try await pbi.liveModel(datasetID: "d1", name: "Sales model")
        c.expect(model.tables.count == 2 && model.allMeasures.count == 1 && model.relationships.count == 1, "live model built from INFO.VIEW queries")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facet-selfcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pbix = dir.appendingPathComponent("Sales & Margin.pbix")
        try Data("PK-fake".utf8).write(to: pbix)
        let started = try await pbi.importFile(at: pbix, to: .group(id: "g1"))
        let post = log.value.last
        c.expect(post?.url.hasSuffix("/groups/g1/imports?datasetDisplayName=Sales%20%26%20Margin.pbix&nameConflict=CreateOrOverwrite") == true, "import URL: \(post?.url ?? "")")
        c.expect(post?.contentType.hasPrefix("multipart/form-data; boundary=") == true && post?.body.contains("PK-fake") == true
                 && post?.body.contains("filename=\"Sales & Margin.pbix\"") == true, "import is multipart with the file")
        let done = try await pbi.waitForImport(started.id, in: .group(id: "g1"))
        c.expect(done.importState == "Succeeded" && done.reports?.first?.id == "rep1" && importPolls.value == 3, "import polled to completion")
        c.equal(try await pbi.refreshDataset("d1"), "refresh-1", "refresh started")
        c.equal(try await pbi.refreshHistory(ofDataset: "d1").count, 2, "refresh history")

        let items = try await fabric.items(inWorkspace: "w1")
        c.equal(items.map(\.id), ["i1", "i2", "i3"], "Fabric continuation paging")
        let parts = try await fabric.semanticModelDefinition(workspaceID: "w1", modelID: "i3")
        c.equal(parts.first?.text, "model Model", "definition fetched through long-running operation")
        c.equal(waits.value.prefix(2).map { $0 }, [4, 2], "LRO polling honours Retry-After")
        c.expect(log.value.contains { $0.url.hasSuffix("/semanticModels/i3/getDefinition?format=TMDL") && $0.method == "POST" }, "getDefinition request")
        do {
            try await fabric.updateSemanticModelDefinition(workspaceID: "w1", modelID: "i3", parts: parts)
            c.fail("failed operation not thrown")
        } catch let e as CloudAPIError {
            c.expect(e.code == "InvalidDefinition" && e.message.contains("TMDL syntax error") && e.requestID == "op2", "failed LRO surfaces the service error")
        }
        let update = log.value.first { $0.url.contains("/updateDefinition") }
        c.equal((try? JSONValue.parse(update?.body ?? ""))?["definition"]?["parts"]?[0]?["path"]?.stringValue, "definition/model.tmdl", "updateDefinition body")

        let paths = try await fabric.oneLakePaths(workspaceID: "w1", directory: "lake1/Files")
        c.equal(paths.map(\.name), ["raw", "sales.csv", "z.parquet"], "OneLake listing follows x-ms-continuation")
        do { _ = try await fabric.sensitivityLabels(); c.fail("403 not thrown") }
        catch let e as CloudAPIError { c.expect(e.kind == .forbidden && e.message.contains("InformationProtectionPolicy.Read"), "sensitivity labels: clear not-permitted error") }
        let gov = FabricClient(tokenProvider: provider, cloud: .china, sessionConfiguration: SelfCheckURLProtocol.configuration())
        do { _ = try await gov.workspaces(); c.fail("missing endpoint not reported") }
        catch let e as CloudAPIError { c.expect(e.message.contains("no Fabric endpoint"), "clear error where Fabric has no endpoint") }
    }
}
