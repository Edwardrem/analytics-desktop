import Foundation

/// A workspace to publish into.
public struct PublishWorkspace: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isPersonal: Bool
    public init(id: String, name: String, isPersonal: Bool) { self.id = id; self.name = name; self.isPersonal = isPersonal }
    /// The Power BI REST reference (`/myorg` for My workspace).
    public var powerBIRef: PowerBIWorkspaceRef { isPersonal && id == PowerBIWorkspace.myWorkspace.id ? .myWorkspace : .group(id: id) }
}

/// What a publish created or replaced in the service.
public struct PublishOutcome: Sendable, Equatable {
    public var semanticModelID: String?
    public var reportID: String?
    public var reportURL: URL?
    /// True when items of the same name already existed and their definitions were replaced.
    public var replacedExisting: Bool
}

public enum PublishError: LocalizedError, Equatable {
    case alreadyExists(name: String, workspace: String)
    case workspaceNotInFabric(String)
    case emptyDefinition(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name, let ws):
            return "“\(ws)” already has a semantic model or report named “\(name)”. Choose Replace to publish over it, or use another name."
        case .workspaceNotInFabric(let ws):
            return "“\(ws)” couldn't be reached through the Fabric item API, which publishing a model definition needs. Choose a shared workspace, or check that your app registration has the Fabric Item.ReadWrite.All permission."
        case .emptyDefinition(let what):
            return "There is nothing to publish: the \(what) definition is empty."
        }
    }
}

/// Publishes to the Power BI service.
///
/// Two routes, because the service does not read `.facet` documents:
/// - `publishDefinition`: the semantic model as TMDL and the report as PBIR (the Power BI project formats) are created or
///   updated as Fabric items. No data is uploaded; the service loads it when the semantic model is refreshed from
///   sources it can reach (cloud sources, or on-premises ones through a gateway).
/// - `publishFile`: a file the import API accepts (`.pbix`, `.xlsx`, `.rdl`) is uploaded as-is.
public final class PowerBIPublisher {
    public let fabric: FabricClient
    public let powerBI: PowerBIClient

    public init(fabric: FabricClient, powerBI: PowerBIClient) { self.fabric = fabric; self.powerBI = powerBI }

    /// The `definition.pbir` that binds a report to a semantic model already in the service (the only binding the item
    /// API accepts; a project's relative `byPath` reference has no meaning there).
    public static func reportBinding(workspaceName: String, modelName: String, modelID: String, cloud: MicrosoftCloud) -> Data {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let source = cloud.powerBIEndpoint.host.map { h -> String in
            // api.powerbi.com → powerbi://api.powerbi.com/v1.0/myorg/<workspace>
            "powerbi://\(h)/v1.0/myorg/\(workspaceName)"
        } ?? "powerbi://api.powerbi.com/v1.0/myorg/\(workspaceName)"
        let connection = "Data Source=\(quoted(source));Initial Catalog=\(quoted(modelName));Integrated Security=ClaimsToken;semanticmodelid=\(modelID)"
        let json: JSONValue = [
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json",
            "version": "4.0",
            "datasetReference": ["byConnection": ["connectionString": .string(connection)]],
        ]
        return json.serializedData()
    }

    /// Creates or updates a semantic model and a report named `name` in `workspace` from their definition parts
    /// (paths relative to the `.SemanticModel` / `.Report` folder). The report's `definition.pbir` is replaced by a
    /// binding to the published model.
    /// - Parameter replaceExisting: when false and an item of that name exists, nothing is changed and
    ///   `PublishError.alreadyExists` is thrown.
    public func publishDefinition(name: String, workspace: PublishWorkspace, modelParts: [FabricDefinitionPart],
                                  reportParts: [FabricDefinitionPart], replaceExisting: Bool,
                                  progress: @escaping (String) -> Void = { _ in }) async throws -> PublishOutcome {
        guard modelParts.contains(where: { $0.path.hasPrefix("definition/") || $0.path == "model.bim" }) else { throw PublishError.emptyDefinition("semantic model") }
        guard reportParts.contains(where: { $0.path.hasPrefix("definition/") }) else { throw PublishError.emptyDefinition("report") }
        guard !(workspace.isPersonal && workspace.id == PowerBIWorkspace.myWorkspace.id) else { throw PublishError.workspaceNotInFabric(workspace.name) }
        progress("Checking \(workspace.name)…")
        let models: [FabricItem], reports: [FabricItem]
        do {
            models = try await fabric.items(inWorkspace: workspace.id, type: .semanticModel)
            reports = try await fabric.items(inWorkspace: workspace.id, type: .report)
        } catch let e as CloudAPIError where e.kind == .notFound || e.kind == .badRequest {
            throw PublishError.workspaceNotInFabric(workspace.name)
        }
        func same(_ i: FabricItem) -> Bool { i.displayName.caseInsensitiveCompare(name) == .orderedSame }
        let existingModel = models.first(where: same), existingReport = reports.first(where: same)
        if (existingModel != nil || existingReport != nil) && !replaceExisting {
            throw PublishError.alreadyExists(name: name, workspace: workspace.name)
        }

        let modelID: String
        if let existingModel {
            progress("Replacing the semantic model “\(name)”…")
            try await fabric.updateItemDefinition(workspaceID: workspace.id, itemID: existingModel.id, parts: modelParts)
            modelID = existingModel.id
        } else {
            progress("Creating the semantic model “\(name)”…")
            modelID = try await fabric.createItem(workspaceID: workspace.id, type: .semanticModel, displayName: name, parts: modelParts).id
        }

        let binding = FabricDefinitionPart(path: "definition.pbir",
                                           content: Self.reportBinding(workspaceName: workspace.name, modelName: name, modelID: modelID, cloud: fabric.cloud))
        let parts = reportParts.filter { $0.path != "definition.pbir" } + [binding]
        let reportID: String
        if let existingReport {
            progress("Replacing the report “\(name)”…")
            try await fabric.updateItemDefinition(workspaceID: workspace.id, itemID: existingReport.id, parts: parts)
            reportID = existingReport.id
        } else {
            progress("Creating the report “\(name)”…")
            reportID = try await fabric.createItem(workspaceID: workspace.id, type: .report, displayName: name, parts: parts).id
        }
        let url = (try? await powerBI.reports(in: workspace.powerBIRef))?.first { $0.id == reportID }?.webUrl.flatMap(URL.init(string:))
        return PublishOutcome(semanticModelID: modelID, reportID: reportID, reportURL: url,
                              replacedExisting: existingModel != nil || existingReport != nil)
    }

    /// File types the Power BI import API accepts.
    public static let importableExtensions: Set<String> = ["pbix", "xlsx", "rdl"]

    /// Uploads a `.pbix` (or `.xlsx` / `.rdl`) with the import API and waits for the service to finish importing it.
    public func publishFile(at fileURL: URL, name: String, workspace: PublishWorkspace, replaceExisting: Bool,
                            pollInterval: TimeInterval = 2, progress: @escaping (String) -> Void = { _ in }) async throws -> PublishOutcome {
        let ext = fileURL.pathExtension.lowercased()
        guard Self.importableExtensions.contains(ext) else {
            throw CloudAPIError(service: "Power BI", kind: .badRequest, statusCode: 0,
                                message: "The Power BI service imports .pbix, .xlsx and .rdl files, not .\(ext).")
        }
        let display = name.lowercased().hasSuffix("." + ext) ? name : name + "." + ext
        progress("Uploading “\(fileURL.lastPathComponent)” to \(workspace.name)…")
        let started = try await powerBI.importFile(at: fileURL, displayName: display, to: workspace.powerBIRef,
                                                   conflict: replaceExisting ? .createOrOverwrite : .abort)
        progress("Waiting for the service to import it…")
        let done = try await powerBI.waitForImport(started.id, in: workspace.powerBIRef, pollInterval: pollInterval)
        let report = done.reports?.first
        return PublishOutcome(semanticModelID: done.datasets?.first?.id, reportID: report?.id,
                              reportURL: report?.webUrl.flatMap(URL.init(string:)), replacedExisting: replaceExisting)
    }
}
