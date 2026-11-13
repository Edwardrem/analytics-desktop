import Foundation

/// A Power BI workspace reference: the personal "My workspace" or a shared workspace (group).
public enum PowerBIWorkspaceRef: Hashable, Sendable {
    case myWorkspace
    case group(id: String)

    /// Path prefix under `/v1.0/myorg` ("" for My workspace).
    var pathPrefix: String {
        switch self {
        case .myWorkspace: return ""
        case .group(let id): return "/groups/\(HTTPHelpers.encodePathSegment(id))"
        }
    }
}

public struct PowerBIWorkspace: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isReadOnly: Bool?
    public let isOnDedicatedCapacity: Bool?
    public let capacityId: String?
    public let type: String?

    /// Synthetic entry representing the signed-in user's personal workspace.
    public static let myWorkspace = PowerBIWorkspace(id: "me", name: "My workspace", isReadOnly: false, isOnDedicatedCapacity: nil, capacityId: nil, type: "PersonalGroup")

    public var ref: PowerBIWorkspaceRef { id == "me" && type == "PersonalGroup" ? .myWorkspace : .group(id: id) }
}

public struct PowerBIReport: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let webUrl: String?
    public let embedUrl: String?
    public let datasetId: String?
    public let reportType: String?
    public let description: String?
}

/// A semantic model (dataset).
public struct PowerBIDataset: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let configuredBy: String?
    public let isRefreshable: Bool?
    public let isEffectiveIdentityRequired: Bool?
    public let isEffectiveIdentityRolesRequired: Bool?
    public let targetStorageMode: String?
    public let createdDate: Date?
    public let webUrl: String?
    public let description: String?
}

public struct PowerBIDashboard: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String?
    public let webUrl: String?
    public let isReadOnly: Bool?
}

public struct PowerBIDataflow: Decodable, Identifiable, Sendable, Equatable {
    public let objectId: String
    public let name: String?
    public let description: String?
    public let configuredBy: String?
    public var id: String { objectId }
}

public struct PowerBIRefresh: Decodable, Identifiable, Sendable, Equatable {
    public let requestId: String?
    public let refreshType: String?
    public let startTime: Date?
    public let endTime: Date?
    /// `Completed`, `Failed`, `Disabled`, `Cancelled` or `Unknown` (in progress).
    public let status: String?
    public let serviceExceptionJson: String?
    public var id: String { requestId ?? "\(startTime?.timeIntervalSince1970 ?? 0)" }
    public var isInProgress: Bool { status == "Unknown" || status == "InProgress" }
}

public struct PowerBIDatasetParameter: Decodable, Identifiable, Sendable, Equatable {
    public let name: String
    public let type: String?
    public let isRequired: Bool?
    public let currentValue: String?
    public let suggestedValues: [String]?
    public var id: String { name }
}

public struct PowerBIDatasource: Decodable, Identifiable, Sendable, Equatable {
    public let datasourceType: String?
    public let datasourceId: String?
    public let gatewayId: String?
    /// Connection properties as returned by the service (`server`, `database`, `url`, `path`…).
    public let connectionDetails: [String: String]?
    public var id: String { datasourceId ?? "\(datasourceType ?? "")|\(connectionDetails?.description ?? "")" }

    private enum CodingKeys: String, CodingKey { case datasourceType, datasourceId, gatewayId, connectionDetails }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        datasourceType = try c.decodeIfPresent(String.self, forKey: .datasourceType)
        datasourceId = try c.decodeIfPresent(String.self, forKey: .datasourceId)
        gatewayId = try c.decodeIfPresent(String.self, forKey: .gatewayId)
        // Values are usually strings but are not guaranteed to be; stringify anything else.
        if let raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .connectionDetails) {
            connectionDetails = raw.mapValues { $0.stringValue ?? $0.serialized() }
        } else {
            connectionDetails = nil
        }
    }
}

public struct PowerBICapacity: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String?
    /// e.g. `F64`, `P1`, `A4`, `EM3`, `FT1` (trial).
    public let sku: String?
    public let state: String?
    public let region: String?
    public let capacityUserAccessRight: String?

    /// Whether the SKU is a Fabric (F) or Premium (P) capacity — the capacity types Microsoft documents as able
    /// to host Fabric workloads. (Copilot additionally requires F2+/P1+ and tenant enablement, which this API cannot confirm.)
    public var isFabricOrPremium: Bool {
        guard let s = sku?.uppercased(), let first = s.first else { return false }
        return (first == "F" || first == "P") && s.dropFirst().first?.isNumber == true
    }
}

public struct PowerBIImport: Decodable, Identifiable, Sendable, Equatable {
    public struct Ref: Decodable, Sendable, Equatable {
        public let id: String
        public let name: String?
        public let webUrl: String?
    }
    public let id: String
    /// `Publishing`, `Succeeded` or `Failed`.
    public let importState: String?
    public let name: String?
    public let reports: [Ref]?
    public let datasets: [Ref]?
    public let error: JSONValue?

    public var isFinished: Bool { importState == "Succeeded" || importState == "Failed" }
}

/// How an import treats an existing item with the same name.
public enum PowerBIImportConflict: String, Sendable {
    case abort = "Abort"
    case createOrOverwrite = "CreateOrOverwrite"
    case overwrite = "Overwrite"
    case ignore = "Ignore"
    case generateUniqueName = "GenerateUniqueName"
}

/// Envelope for Power BI's `{"value": [...]}` collections.
struct PowerBIList<T: Decodable>: Decodable {
    let value: [T]
}
