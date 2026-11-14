import Foundation
import FacetCore

/// Power BI REST API client (`/v1.0/myorg`).
///
/// Requires a work or school account; the token provider throws
/// `MicrosoftAuthError.personalAccountUnsupported` for personal accounts.
/// All methods are `async`, cancellable, and throw `CloudAPIError` with Power BI's message and request id.
public final class PowerBIClient {
    public let cloud: MicrosoftCloud
    let rest: RESTClient
    let transferConfiguration: URLSessionConfiguration?
    private var baseURL: URL { cloud.powerBIEndpoint.appendingPathComponent("v1.0/myorg") }

    public init(tokenProvider: AccessTokenProviding, cloud: MicrosoftCloud = .public, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.cloud = cloud
        self.transferConfiguration = sessionConfiguration
        let policy = EndpointPolicy(cloud: cloud)
        let session = RESTClient.makeSession(sessionConfiguration)
        self.rest = RESTClient(service: "Power BI", scope: MicrosoftResource.powerBI.scopeString(cloud: cloud),
                               tokenProvider: tokenProvider, session: session, policy: policy)
    }

    private func url(_ pathAndQuery: String) throws -> URL { try rest.url(baseURL, pathAndQuery) }
    private func seg(_ s: String) -> String { HTTPHelpers.encodePathSegment(s) }

    private func list<T: Decodable>(_ type: T.Type, _ path: String) async throws -> [T] {
        try await rest.getJSON(PowerBIList<T>.self, try url(path)).value
    }

    // MARK: Workspaces and content

    /// Shared workspaces the user can access, following `$top`/`$skip` paging.
    /// - Parameter includeMyWorkspace: prepend the synthetic "My workspace" entry.
    public func workspaces(includeMyWorkspace: Bool = true) async throws -> [PowerBIWorkspace] {
        var out: [PowerBIWorkspace] = includeMyWorkspace ? [.myWorkspace] : []
        let pageSize = 1000
        var skip = 0
        while true {
            let page = try await list(PowerBIWorkspace.self, "/groups?$top=\(pageSize)&$skip=\(skip)")
            out.append(contentsOf: page)
            if page.count < pageSize { break }
            skip += pageSize
        }
        return out
    }

    public func reports(in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> [PowerBIReport] {
        try await list(PowerBIReport.self, workspace.pathPrefix + "/reports")
    }

    /// Semantic models (datasets) in a workspace.
    public func datasets(in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> [PowerBIDataset] {
        try await list(PowerBIDataset.self, workspace.pathPrefix + "/datasets")
    }

    public func dashboards(in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> [PowerBIDashboard] {
        try await list(PowerBIDashboard.self, workspace.pathPrefix + "/dashboards")
    }

    /// Dataflows in a shared workspace (the API has no "My workspace" form).
    public func dataflows(inGroup groupID: String) async throws -> [PowerBIDataflow] {
        try await list(PowerBIDataflow.self, "/groups/\(seg(groupID))/dataflows")
    }

    /// Capacities the user has access to. Use `PowerBICapacity.isFabricOrPremium` together with a workspace's
    /// `capacityId` to tell whether it sits on a capacity that can host Fabric/Copilot workloads.
    public func capacities() async throws -> [PowerBICapacity] {
        try await list(PowerBICapacity.self, "/capacities")
    }

    // MARK: Dataset details

    public func parameters(ofDataset datasetID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> [PowerBIDatasetParameter] {
        try await list(PowerBIDatasetParameter.self, workspace.pathPrefix + "/datasets/\(seg(datasetID))/parameters")
    }

    public func datasources(ofDataset datasetID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> [PowerBIDatasource] {
        try await list(PowerBIDatasource.self, workspace.pathPrefix + "/datasets/\(seg(datasetID))/datasources")
    }

    /// Runs a DAX query against a semantic model and returns the first result table.
    ///
    /// - Parameters:
    ///   - dax: a complete DAX query (`EVALUATE …`).
    ///   - impersonatedUserName: UPN to evaluate RLS as (requires permissions on the model).
    ///   - stripTablePrefixes: reduce `Table[Column]` result keys to `Column`.
    /// - Note: the service limits a query to 100,000 rows / 1,000,000 values and 15 MB per response.
    public func executeQuery(_ dax: String, datasetID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace,
                             impersonatedUserName: String? = nil, stripTablePrefixes: Bool = true,
                             resultName: String = "Query") async throws -> DataTable {
        var body: JSONValue = [
            "queries": [["query": .string(dax)]],
            "serializerSettings": ["includeNulls": true],
        ]
        if let impersonatedUserName, !impersonatedUserName.isEmpty {
            body = body.setting("impersonatedUserName", to: .string(impersonatedUserName))
        }
        let target = try url(workspace.pathPrefix + "/datasets/\(seg(datasetID))/executeQueries")
        let (data, http) = try await rest.send(rest.request("POST", target, json: body))
        do {
            return try DAXResultParser.dataTable(from: data, name: resultName, stripTablePrefixes: stripTablePrefixes)
        } catch var e as CloudAPIError {
            e.requestID = http.value(forHTTPHeaderField: "RequestId") ?? http.value(forHTTPHeaderField: "x-ms-request-id")
            throw e
        }
    }

    /// Reads a semantic model's tables, columns, measures and relationships with the `INFO.VIEW.*` DAX functions
    /// and returns them as a FacetCore `SemanticModel` whose tables use `.live` storage mode.
    /// Requires Build permission on the model (INFO functions are not available to read-only users).
    public func liveModel(datasetID: String, name: String, in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> SemanticModel {
        @Sendable func run(_ q: String, _ n: String) async throws -> DataTable {
            try await executeQuery(q, datasetID: datasetID, in: workspace, resultName: n)
        }
        async let tables = run(LiveModelBuilder.tablesQuery, "Tables")
        async let columns = run(LiveModelBuilder.columnsQuery, "Columns")
        async let measures = run(LiveModelBuilder.measuresQuery, "Measures")
        async let relationships = run(LiveModelBuilder.relationshipsQuery, "Relationships")
        return LiveModelBuilder.build(name: name, tables: try await tables, columns: try await columns,
                                      measures: try await measures, relationships: try await relationships)
    }

    // MARK: Refresh

    /// Starts a refresh of a semantic model. Returns the service request id of the refresh, when provided.
    @discardableResult
    public func refreshDataset(_ datasetID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> String? {
        let target = try url(workspace.pathPrefix + "/datasets/\(seg(datasetID))/refreshes")
        let (_, http) = try await rest.send(rest.request("POST", target, json: ["notifyOption": "NoNotification"]))
        return http.value(forHTTPHeaderField: "x-ms-request-id") ?? http.value(forHTTPHeaderField: "RequestId")
    }

    /// Refresh history, most recent first.
    public func refreshHistory(ofDataset datasetID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace, top: Int = 20) async throws -> [PowerBIRefresh] {
        try await list(PowerBIRefresh.self, workspace.pathPrefix + "/datasets/\(seg(datasetID))/refreshes?$top=\(max(1, top))")
    }

    // MARK: Export and publish

    /// Downloads a report as a .pbix file (`GET /reports/{id}/Export`).
    public func exportReport(_ reportID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace, suggestedName: String = "Report.pbix",
                             destination: URL? = nil, progress: TransferProgressHandler? = nil) async throws -> URL {
        var request = URLRequest(url: try url(workspace.pathPrefix + "/reports/\(seg(reportID))/Export"))
        guard rest.policy.allowsCredentials(for: request.url) else {
            throw CloudAPIError(service: rest.service, kind: .badRequest, statusCode: 0, message: "Refused to send your sign-in to an address that is not Power BI.")
        }
        let token = try await rest.tokenProvider.accessToken(resource: rest.scope)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await FileDownloader.download(request, service: rest.service, suggestedName: suggestedName, destination: destination,
                                                 configuration: transferConfiguration, progress: progress)
    }

    /// Publishes a file (.pbix, .xlsx, .json dataflow model…) to a workspace as a multipart import and returns the
    /// created import, whose state starts as `Publishing`. Use `waitForImport` to follow it.
    ///
    /// Files are sent in one request (the service accepts up to 1 GB this way; the temporary-upload-location flow
    /// for larger files is not implemented).
    public func importFile(at fileURL: URL, displayName: String? = nil, to workspace: PowerBIWorkspaceRef = .myWorkspace,
                           conflict: PowerBIImportConflict = .createOrOverwrite) async throws -> PowerBIImport {
        let limit: Int64 = 1_073_741_824
        guard try LocalFile.size(of: fileURL, service: rest.service) <= limit else {
            throw CloudAPIError(service: rest.service, kind: .badRequest, statusCode: 0,
                                message: "Files larger than 1 GB cannot be published from Facet yet.")
        }
        let name = displayName ?? fileURL.lastPathComponent
        var form = MultipartFormData()
        form.addFile(name: "file", filename: fileURL.lastPathComponent, contentType: "application/octet-stream",
                     data: try LocalFile.read(fileURL, limit: limit, service: rest.service))
        let query = "?datasetDisplayName=\(seg(name))&nameConflict=\(conflict.rawValue)"
        var request = rest.request("POST", try url(workspace.pathPrefix + "/imports" + query))
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        request.timeoutInterval = 3600
        let (data, _) = try await rest.send(request)
        // The 202 response carries only the import id.
        struct Created: Decodable { let id: String }
        let created = try rest.decode(Created.self, from: data)
        return PowerBIImport(id: created.id, importState: "Publishing", name: name, reports: nil, datasets: nil, error: nil)
    }

    public func importStatus(_ importID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace) async throws -> PowerBIImport {
        try await rest.getJSON(PowerBIImport.self, try url(workspace.pathPrefix + "/imports/\(seg(importID))"))
    }

    /// Polls an import until it succeeds or fails. Throws `CloudAPIError` if the import fails or `timeout` elapses.
    public func waitForImport(_ importID: String, in workspace: PowerBIWorkspaceRef = .myWorkspace,
                              pollInterval: TimeInterval = 2, timeout: TimeInterval = 1800) async throws -> PowerBIImport {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = try await importStatus(importID, in: workspace)
            if status.importState == "Succeeded" { return status }
            if status.importState == "Failed" {
                let detail = status.error?["message"]?.stringValue ?? status.error?["code"]?.stringValue ?? status.error?.serialized()
                throw CloudAPIError(service: rest.service, kind: .other, statusCode: 0, code: status.error?["code"]?.stringValue,
                                    message: "Publishing failed" + (detail.map { ": \($0)" } ?? "."))
            }
            guard Date() < deadline else {
                throw CloudAPIError(service: rest.service, kind: .other, statusCode: 0, message: "Publishing is taking longer than expected; check the workspace in Power BI.")
            }
            try await rest.sleeper(pollInterval)
        }
    }
}
