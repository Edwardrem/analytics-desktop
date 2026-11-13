import Foundation

// MARK: - Models

public struct FabricWorkspace: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String?
    /// `Workspace`, `Personal` or `AdminWorkspace`.
    public let type: String?
    public let capacityId: String?
}

/// Fabric item types Facet surfaces in the OneLake catalog. Unknown types are preserved in `FabricItem.type`.
public enum FabricItemType: String, CaseIterable, Sendable {
    case lakehouse = "Lakehouse"
    case warehouse = "Warehouse"
    case semanticModel = "SemanticModel"
    case sqlDatabase = "SQLDatabase"
    case mirroredDatabase = "MirroredDatabase"
    case kqlDatabase = "KQLDatabase"
    case dataflow = "Dataflow"
    case sqlEndpoint = "SQLEndpoint"
    case report = "Report"

    public var displayName: String {
        switch self {
        case .lakehouse: return "Lakehouse"
        case .warehouse: return "Warehouse"
        case .semanticModel: return "Semantic model"
        case .sqlDatabase: return "SQL database"
        case .mirroredDatabase: return "Mirrored database"
        case .kqlDatabase: return "KQL database"
        case .dataflow: return "Dataflow"
        case .sqlEndpoint: return "SQL analytics endpoint"
        case .report: return "Report"
        }
    }
    /// The types that hold data Facet can connect to.
    public static let dataItemTypes: [FabricItemType] = [.lakehouse, .warehouse, .semanticModel, .sqlDatabase, .mirroredDatabase, .kqlDatabase, .dataflow]
}

public struct FabricItem: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String?
    /// Raw item type string from the service (see `FabricItemType`).
    public let type: String
    public let workspaceId: String?
    /// `Promoted`, `Certified` or `MasterData`, when the API returned endorsement details.
    public let endorsement: String?
    public let certifiedBy: String?
    /// Sensitivity label id, when the API returned one. Resolve names with `FabricClient.sensitivityLabels()`.
    public let sensitivityLabelID: String?

    public var itemType: FabricItemType? { FabricItemType(rawValue: type) }

    private enum CodingKeys: String, CodingKey { case id, displayName, description, type, workspaceId, endorsementDetails, endorsement, sensitivityLabel }
    private struct Endorsement: Decodable { let endorsement: String?; let certifiedBy: String? }
    private struct Label: Decodable {
        let id: String?
        let sensitivityLabelId: String?
        let labelId: String?
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        let details = try? c.decodeIfPresent(Endorsement.self, forKey: .endorsementDetails)
        endorsement = details?.endorsement ?? (try? c.decodeIfPresent(String.self, forKey: .endorsement))
        certifiedBy = details?.certifiedBy
        let label = try? c.decodeIfPresent(Label.self, forKey: .sensitivityLabel)
        sensitivityLabelID = label?.id ?? label?.sensitivityLabelId ?? label?.labelId
    }
}

public struct LakehouseTable: Decodable, Identifiable, Sendable, Equatable {
    public let name: String
    /// `Managed` or `External`.
    public let type: String?
    /// e.g. `abfss://<workspace>@onelake.dfs.fabric.microsoft.com/<lakehouse>/Tables/<name>`
    public let location: String?
    /// e.g. `Delta`.
    public let format: String?
    public var id: String { name }
}

/// One file of an item definition (e.g. a TMDL file of a semantic model).
public struct FabricDefinitionPart: Sendable, Equatable {
    /// Path within the definition, e.g. `definition/tables/Sales.tmdl`.
    public var path: String
    public var content: Data

    public init(path: String, content: Data) { self.path = path; self.content = content }
    public init(path: String, text: String) { self.path = path; self.content = Data(text.utf8) }
    /// The content as UTF-8 text (TMDL, JSON), when it is text.
    public var text: String? { String(data: content, encoding: .utf8) }
}

/// A file or folder in OneLake.
public struct OneLakePath: Identifiable, Sendable, Equatable {
    /// Path relative to the workspace, e.g. `<itemId>/Files/raw/sales.csv`.
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let lastModified: Date?
    public let eTag: String?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// A Microsoft Purview sensitivity label available to the signed-in user.
public struct SensitivityLabel: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let description: String?
    public let color: String?
    public let sensitivity: Int?
    public let tooltip: String?
    public let isActive: Bool?
}

// MARK: - Client

/// Microsoft Fabric REST client (`https://api.fabric.microsoft.com/v1`) plus OneLake DFS file access
/// and Purview sensitivity-label lookup.
public final class FabricClient {
    public let cloud: MicrosoftCloud
    let rest: RESTClient
    let oneLake: RESTClient
    let labels: RESTClient
    let transferConfiguration: URLSessionConfiguration?
    private let fabricBase: URL?
    private let oneLakeBase: URL?

    /// - Parameters:
    ///   - fabricEndpoint / oneLakeEndpoint: override the cloud defaults (needed outside the global cloud, where Facet has no built-in endpoints).
    public init(tokenProvider: AccessTokenProviding, cloud: MicrosoftCloud = .public, fabricEndpoint: URL? = nil,
                oneLakeEndpoint: URL? = nil, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.cloud = cloud
        self.transferConfiguration = sessionConfiguration
        self.fabricBase = (fabricEndpoint ?? cloud.fabricEndpoint)?.appendingPathComponent("v1")
        self.oneLakeBase = oneLakeEndpoint ?? cloud.oneLakeEndpoint
        let policy = EndpointPolicy(cloud: cloud, extraHosts: [fabricEndpoint?.host, oneLakeEndpoint?.host].compactMap { $0 })
        let session = RESTClient.makeSession(sessionConfiguration)
        self.rest = RESTClient(service: "Fabric", scope: MicrosoftResource.fabric.scopeString(cloud: cloud), tokenProvider: tokenProvider, session: session, policy: policy)
        self.oneLake = RESTClient(service: "OneLake", scope: MicrosoftResource.storage.scopeString(cloud: cloud), tokenProvider: tokenProvider, session: session, policy: policy)
        self.labels = RESTClient(service: "Microsoft Graph", scope: cloud.graphEndpoint.absoluteString + "/InformationProtectionPolicy.Read",
                                 tokenProvider: tokenProvider, session: session, policy: policy)
    }

    private func url(_ pathAndQuery: String) throws -> URL {
        guard let base = fabricBase else {
            throw CloudAPIError(service: "Fabric", kind: .badRequest, statusCode: 0,
                                message: "Facet has no Fabric endpoint for the \(cloud.displayName) cloud. Fabric browsing is available in the global cloud.")
        }
        return try rest.url(base, pathAndQuery)
    }
    private func seg(_ s: String) -> String { HTTPHelpers.encodePathSegment(s) }

    private struct Page<T: Decodable>: Decodable {
        let value: [T]?
        let data: [T]?
        let continuationUri: String?
        let continuationToken: String?
    }

    /// Follows Fabric's `continuationUri` paging to the end.
    private func listAll<T: Decodable>(_ type: T.Type, _ path: String) async throws -> [T] {
        var out: [T] = []
        var next: URL? = try url(path)
        var pages = 0
        while let u = next, pages < 500 {
            let page = try await rest.getJSON(Page<T>.self, u)
            out.append(contentsOf: page.value ?? page.data ?? [])
            pages += 1
            if let s = page.continuationUri, let n = URL(string: s), n.scheme == "https", n.host?.lowercased() == fabricBase?.host?.lowercased() {
                next = n
            } else if let token = page.continuationToken, !token.isEmpty, page.continuationUri == nil {
                next = try url(path + (path.contains("?") ? "&" : "?") + "continuationToken=\(seg(token))")
            } else {
                next = nil
            }
        }
        return out
    }

    // MARK: Catalog

    public func workspaces() async throws -> [FabricWorkspace] {
        try await listAll(FabricWorkspace.self, "/workspaces")
    }

    /// Items in a workspace, optionally restricted to one type.
    public func items(inWorkspace workspaceID: String, type: FabricItemType? = nil) async throws -> [FabricItem] {
        let q = type.map { "?type=\($0.rawValue)" } ?? ""
        return try await listAll(FabricItem.self, "/workspaces/\(seg(workspaceID))/items\(q)")
    }

    /// Delta tables of a lakehouse.
    public func lakehouseTables(workspaceID: String, lakehouseID: String) async throws -> [LakehouseTable] {
        try await listAll(LakehouseTable.self, "/workspaces/\(seg(workspaceID))/lakehouses/\(seg(lakehouseID))/tables")
    }

    // MARK: Semantic model definition

    /// Fetches a semantic model's definition (TMDL parts by default), polling the long-running operation if the
    /// service answers 202.
    public func semanticModelDefinition(workspaceID: String, modelID: String, format: String = "TMDL") async throws -> [FabricDefinitionPart] {
        let target = try url("/workspaces/\(seg(workspaceID))/semanticModels/\(seg(modelID))/getDefinition?format=\(seg(format))")
        let data = try await runOperation(rest.request("POST", target), wantsResult: true)
        return try Self.parseDefinition(data)
    }

    /// Replaces a semantic model's definition ("live edit" save-back). Waits for the operation to finish.
    /// - Parameter updateMetadata: also apply the `.platform` part (display name/description) when present.
    public func updateSemanticModelDefinition(workspaceID: String, modelID: String, parts: [FabricDefinitionPart],
                                              updateMetadata: Bool = false) async throws {
        let target = try url("/workspaces/\(seg(workspaceID))/semanticModels/\(seg(modelID))/updateDefinition?updateMetadata=\(updateMetadata)")
        _ = try await runOperation(rest.request("POST", target, json: Self.definitionBody(parts)), wantsResult: false)
    }

    /// Creates an item (semantic model, report…) from its definition parts and returns it. Waits for the operation to finish.
    public func createItem(workspaceID: String, type: FabricItemType, displayName: String, description: String? = nil,
                           parts: [FabricDefinitionPart]) async throws -> FabricItem {
        var body: JSONValue = ["displayName": .string(displayName), "type": .string(type.rawValue)]
        if let description, !description.isEmpty { body = body.setting("description", to: .string(description)) }
        if let definition = Self.definitionBody(parts)["definition"] { body = body.setting("definition", to: definition) }
        let data = try await runOperation(rest.request("POST", try url("/workspaces/\(seg(workspaceID))/items"), json: body), wantsResult: true)
        return try rest.decode(FabricItem.self, from: data)
    }

    /// Replaces the definition of any item (used to publish over an item that already exists).
    public func updateItemDefinition(workspaceID: String, itemID: String, parts: [FabricDefinitionPart]) async throws {
        let target = try url("/workspaces/\(seg(workspaceID))/items/\(seg(itemID))/updateDefinition")
        _ = try await runOperation(rest.request("POST", target, json: Self.definitionBody(parts)), wantsResult: false)
    }

    static func definitionBody(_ parts: [FabricDefinitionPart]) -> JSONValue {
        ["definition": ["parts": .array(parts.map { p in
            ["path": .string(p.path), "payload": .string(p.content.base64EncodedString()), "payloadType": "InlineBase64"]
        })]]
    }

    static func parseDefinition(_ data: Data) throws -> [FabricDefinitionPart] {
        guard let json = try? JSONValue.parse(data), let parts = json["definition"]?["parts"]?.arrayValue else {
            throw CloudAPIError(service: "Fabric", kind: .invalidResponse, statusCode: 0, message: "The definition response did not contain any parts.")
        }
        return try parts.map { p in
            guard let path = p["path"]?.stringValue, let payload = p["payload"]?.stringValue else {
                throw CloudAPIError(service: "Fabric", kind: .invalidResponse, statusCode: 0, message: "A definition part was missing its path or payload.")
            }
            let type = p["payloadType"]?.stringValue ?? "InlineBase64"
            guard type == "InlineBase64", let content = Data(base64Encoded: payload) else {
                throw CloudAPIError(service: "Fabric", kind: .invalidResponse, statusCode: 0, message: "Definition part \(path) uses an unsupported payload type (\(type)).")
            }
            return FabricDefinitionPart(path: path, content: content)
        }
    }

    /// Sends a request that may complete synchronously (200/201) or as a long-running operation (202 + `Location`).
    /// For LROs, polls `/operations/{id}` honouring `Retry-After` until it succeeds or fails, then optionally fetches `/result`.
    func runOperation(_ request: URLRequest, wantsResult: Bool, timeout: TimeInterval = 1800) async throws -> Data {
        let (data, http) = try await rest.send(request)
        guard http.statusCode == 202 else { return data }
        let operationID = http.value(forHTTPHeaderField: "x-ms-operation-id")
        var statusURL: URL
        if let loc = http.value(forHTTPHeaderField: "Location"), let u = URL(string: loc), u.scheme == "https",
           u.host?.lowercased() == fabricBase?.host?.lowercased() {
            statusURL = u
        } else if let operationID {
            statusURL = try url("/operations/\(seg(operationID))")
        } else {
            throw CloudAPIError(service: "Fabric", kind: .invalidResponse, statusCode: 202, message: "The service started an operation but did not say where to track it.")
        }
        var wait = min(HTTPHelpers.retryAfter(from: http) ?? 2, 30)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try await rest.sleeper(wait)
            let (body, poll) = try await rest.send(rest.request("GET", statusURL))
            let json = (try? JSONValue.parse(body)) ?? .null
            let status = (json["status"]?.stringValue ?? "").lowercased()
            if status == "succeeded" {
                guard wantsResult else { return body }
                let resultURL: URL
                if let loc = poll.value(forHTTPHeaderField: "Location"), let u = URL(string: loc), u.scheme == "https",
                   u.host?.lowercased() == fabricBase?.host?.lowercased() {
                    resultURL = u
                } else {
                    resultURL = statusURL.appendingPathComponent("result")
                }
                return try await rest.send(rest.request("GET", resultURL)).0
            }
            if status == "failed" || status == "undefined" && json["error"] != nil {
                let err = json["error"]
                throw CloudAPIError(service: "Fabric", kind: .other, statusCode: 0, code: err?["errorCode"]?.stringValue,
                                    message: err?["message"]?.stringValue ?? "The operation failed.",
                                    requestID: poll.value(forHTTPHeaderField: "requestId") ?? poll.value(forHTTPHeaderField: "x-ms-request-id") ?? operationID)
            }
            guard Date() < deadline else {
                throw CloudAPIError(service: "Fabric", kind: .other, statusCode: 0, message: "The operation is still running after \(Int(timeout / 60)) minutes.", requestID: operationID)
            }
            wait = min(HTTPHelpers.retryAfter(from: poll) ?? min(wait * 1.5, 15), 30)
        }
    }

    // MARK: OneLake files

    private func oneLakeURL(_ pathAndQuery: String) throws -> URL {
        guard let base = oneLakeBase else {
            throw CloudAPIError(service: "OneLake", kind: .badRequest, statusCode: 0, message: "Facet has no OneLake endpoint for the \(cloud.displayName) cloud.")
        }
        return try oneLake.url(base, pathAndQuery)
    }

    /// Lists files and folders in OneLake.
    /// - Parameters:
    ///   - workspaceID: workspace GUID (or name).
    ///   - directory: path below the workspace, e.g. `<lakehouseId>/Files` or `<lakehouseId>/Tables/sales`.
    public func oneLakePaths(workspaceID: String, directory: String, recursive: Bool = false) async throws -> [OneLakePath] {
        var out: [OneLakePath] = []
        var continuation: String?
        var pages = 0
        repeat {
            var q = "?resource=filesystem&recursive=\(recursive)&directory=\(seg(directory))"
            if let continuation { q += "&continuation=\(seg(continuation))" }
            let request = oneLake.request("GET", try oneLakeURL("/\(seg(workspaceID))\(q)"), headers: ["x-ms-version": "2023-11-03"])
            let (data, http) = try await oneLake.send(request)
            out.append(contentsOf: try Self.parseOneLakeListing(data))
            continuation = http.value(forHTTPHeaderField: "x-ms-continuation").flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while continuation != nil && pages < 1000
        return out
    }

    static func parseOneLakeListing(_ data: Data) throws -> [OneLakePath] {
        guard let json = try? JSONValue.parse(data), let paths = json["paths"]?.arrayValue else {
            throw CloudAPIError(service: "OneLake", kind: .invalidResponse, statusCode: 0, message: "The file listing could not be read.")
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return paths.compactMap { p in
            guard let name = p["name"]?.stringValue else { return nil }
            // The DFS API returns booleans and sizes as strings.
            let isDir = p["isDirectory"]?.boolValue ?? (p["isDirectory"]?.stringValue?.lowercased() == "true")
            let size = p["contentLength"]?.intValue ?? p["contentLength"]?.stringValue.flatMap(Int64.init) ?? 0
            let modified = p["lastModified"]?.stringValue.flatMap { df.date(from: $0) ?? HTTPHelpers.parseISODate($0) }
            return OneLakePath(path: name, isDirectory: isDir, size: size, lastModified: modified, eTag: p["etag"]?.stringValue)
        }
    }

    /// Downloads a OneLake file to disk.
    /// - Parameter path: path below the workspace, as returned in `OneLakePath.path`.
    public func downloadOneLakeFile(workspaceID: String, path: String, destination: URL? = nil,
                                    progress: TransferProgressHandler? = nil) async throws -> URL {
        var request = URLRequest(url: try oneLakeURL("/\(seg(workspaceID))/\(HTTPHelpers.encodePath(path))"))
        request.setValue("2023-11-03", forHTTPHeaderField: "x-ms-version")
        let token = try await oneLake.tokenProvider.accessToken(resource: oneLake.scope)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await FileDownloader.download(request, service: "OneLake", suggestedName: (path as NSString).lastPathComponent,
                                                 destination: destination, configuration: transferConfiguration, progress: progress)
    }

    // MARK: Sensitivity labels

    /// Sensitivity labels the signed-in user may apply (Microsoft Graph beta).
    ///
    /// Requires the delegated `InformationProtectionPolicy.Read` permission on the app registration.
    /// - Throws: `CloudAPIError` with kind `.forbidden` and an explanatory message when the permission is missing or not consented.
    public func sensitivityLabels() async throws -> [SensitivityLabel] {
        let base = cloud.graphEndpoint.appendingPathComponent("beta")
        let notPermitted = CloudAPIError(
            service: "Microsoft Graph", kind: .forbidden, statusCode: 403,
            message: "Listing sensitivity labels is not permitted for this account. The app registration needs the delegated Microsoft Graph permission InformationProtectionPolicy.Read (an administrator may need to grant consent).")
        do {
            do {
                return try await labels.getJSON(GraphPage<SensitivityLabel>.self, try labels.url(base, "/me/security/informationProtection/sensitivityLabels")).items
            } catch let e as CloudAPIError where e.kind == .notFound || e.kind == .badRequest {
                return try await labels.getJSON(GraphPage<SensitivityLabel>.self, try labels.url(base, "/security/informationProtection/sensitivityLabels")).items
            }
        } catch let e as CloudAPIError where e.kind == .forbidden || e.kind == .unauthorized {
            var err = notPermitted
            err.requestID = e.requestID
            throw err
        } catch let e as MicrosoftAuthError {
            switch e {
            case .consentRequired, .service, .personalAccountUnsupported: throw notPermitted
            default: throw e
            }
        }
    }
}
