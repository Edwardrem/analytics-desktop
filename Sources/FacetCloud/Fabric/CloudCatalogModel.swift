import Foundation
import Combine

/// View model for the OneLake catalog / workspace browser: lists Fabric workspaces and their items,
/// with type filtering and search. Falls back to Power BI workspaces and semantic models/reports when
/// the Fabric API is unavailable (for example in national clouds, or tenants without Fabric).
@MainActor
public final class CloudCatalogModel: ObservableObject {
    /// A workspace row, from Fabric or (as a fallback) Power BI.
    public struct Workspace: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let isPersonal: Bool
        public let capacityID: String?
        /// The Power BI reference for this workspace (for `PowerBIClient` calls).
        public var powerBIRef: PowerBIWorkspaceRef { isPersonal ? .myWorkspace : .group(id: id) }
    }

    /// An item row.
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let description: String
        /// Raw type string (`Lakehouse`, `SemanticModel`, `Report`…).
        public let type: String
        public let workspaceID: String
        public let endorsement: String?
        public let sensitivityLabelID: String?
        /// Resolved label name when labels could be listed.
        public var sensitivityLabelName: String?
        public var itemType: FabricItemType? { FabricItemType(rawValue: type) }
        public var typeDisplayName: String { itemType?.displayName ?? type }
    }

    @Published public private(set) var workspaces: [Workspace] = []
    @Published public private(set) var items: [Item] = []
    @Published public var selectedWorkspaceID: String? {
        didSet { if selectedWorkspaceID != oldValue { reloadItems() } }
    }
    @Published public private(set) var isLoadingWorkspaces = false
    @Published public private(set) var isLoadingItems = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastError: Error?
    /// True when the listing came from the Power BI API because Fabric was unavailable.
    @Published public private(set) var isUsingPowerBIFallback = false
    /// Item types to show; empty = all types returned.
    @Published public var typeFilter: Set<FabricItemType> = Set(FabricItemType.dataItemTypes)
    @Published public var searchText = ""
    /// Whether to show only endorsed (promoted/certified) items.
    @Published public var endorsedOnly = false

    public let fabric: FabricClient
    public let powerBI: PowerBIClient
    private var labelNames: [String: String]?
    private var workspaceTask: Task<Void, Never>?
    private var itemsTask: Task<Void, Never>?
    private var itemsGeneration = 0

    public init(fabric: FabricClient, powerBI: PowerBIClient) {
        self.fabric = fabric
        self.powerBI = powerBI
    }

    public var selectedWorkspace: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }

    /// `items` after the type, endorsement and search filters, sorted by name.
    public var visibleItems: [Item] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            if !typeFilter.isEmpty {
                guard let t = item.itemType, typeFilter.contains(t) else { return false }
            }
            if endorsedOnly, (item.endorsement ?? "").isEmpty || item.endorsement == "None" { return false }
            return q.isEmpty || item.name.lowercased().contains(q) || item.description.lowercased().contains(q)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Loads the workspace list (Fabric first, Power BI as a fallback) and selects the first workspace if none is selected.
    public func loadWorkspaces() {
        workspaceTask?.cancel()
        isLoadingWorkspaces = true
        errorMessage = nil
        lastError = nil
        workspaceTask = Task { [weak self, fabric, powerBI] in
            var result: [Workspace] = []
            var fallback = false
            var failure: Error?
            do {
                result = try await fabric.workspaces().map {
                    Workspace(id: $0.id, name: $0.displayName, isPersonal: $0.type == "Personal", capacityID: $0.capacityId)
                }
            } catch is CancellationError {
                return
            } catch let fabricError {
                if case MicrosoftAuthError.personalAccountUnsupported = fabricError { failure = fabricError }
                else if case MicrosoftAuthError.interactionRequired = fabricError { failure = fabricError }
                else {
                    do {
                        result = try await powerBI.workspaces(includeMyWorkspace: true).map {
                            Workspace(id: $0.id, name: $0.name, isPersonal: $0.ref == .myWorkspace, capacityID: $0.capacityId)
                        }
                        fallback = true
                    } catch is CancellationError {
                        return
                    } catch {
                        failure = error
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isLoadingWorkspaces = false
            self.isUsingPowerBIFallback = fallback
            if let failure {
                self.workspaces = []
                self.items = []
                self.lastError = failure
                self.errorMessage = failure.localizedDescription
                return
            }
            self.workspaces = result.sorted {
                if $0.isPersonal != $1.isPersonal { return $0.isPersonal }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if self.selectedWorkspace == nil { self.selectedWorkspaceID = self.workspaces.first?.id }
            else { self.reloadItems() }
        }
    }

    /// Reloads the items of the selected workspace.
    public func reloadItems() {
        itemsTask?.cancel()
        itemsGeneration += 1
        let gen = itemsGeneration
        guard let workspace = selectedWorkspace else { items = []; isLoadingItems = false; return }
        let fallback = isUsingPowerBIFallback
        isLoadingItems = true
        errorMessage = nil
        lastError = nil
        itemsTask = Task { [weak self, fabric, powerBI] in
            do {
                var loaded: [Item]
                if fallback {
                    loaded = try await Self.powerBIItems(workspace, powerBI)
                } else {
                    loaded = try await fabric.items(inWorkspace: workspace.id).map {
                        Item(id: $0.id, name: $0.displayName, description: $0.description ?? "", type: $0.type, workspaceID: workspace.id,
                             endorsement: $0.endorsement, sensitivityLabelID: $0.sensitivityLabelID, sensitivityLabelName: nil)
                    }
                }
                guard let self, gen == self.itemsGeneration, !Task.isCancelled else { return }
                if loaded.contains(where: { $0.sensitivityLabelID != nil }) {
                    let names = await self.resolveLabelNames()
                    for i in loaded.indices { loaded[i].sensitivityLabelName = loaded[i].sensitivityLabelID.flatMap { names[$0] } }
                    guard gen == self.itemsGeneration else { return }
                }
                self.items = loaded
                self.isLoadingItems = false
            } catch {
                guard let self, gen == self.itemsGeneration else { return }
                self.isLoadingItems = false
                if error is CancellationError || Task.isCancelled { return }
                self.items = []
                self.lastError = error
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private static func powerBIItems(_ workspace: Workspace, _ powerBI: PowerBIClient) async throws -> [Item] {
        async let datasets = powerBI.datasets(in: workspace.powerBIRef)
        async let reports = powerBI.reports(in: workspace.powerBIRef)
        let models = try await datasets.map {
            Item(id: $0.id, name: $0.name ?? "Semantic model", description: $0.description ?? "", type: FabricItemType.semanticModel.rawValue,
                 workspaceID: workspace.id, endorsement: nil, sensitivityLabelID: nil, sensitivityLabelName: nil)
        }
        let reportItems = try await reports.map {
            Item(id: $0.id, name: $0.name ?? "Report", description: $0.description ?? "", type: FabricItemType.report.rawValue,
                 workspaceID: workspace.id, endorsement: nil, sensitivityLabelID: nil, sensitivityLabelName: nil)
        }
        return models + reportItems
    }

    /// Label id → name, fetched once. Empty when the account may not list labels.
    private func resolveLabelNames() async -> [String: String] {
        if let labelNames { return labelNames }
        var names: [String: String] = [:]
        if let labels = try? await fabric.sensitivityLabels() {
            for l in labels { names[l.id] = l.name ?? l.id }
        }
        labelNames = names
        return names
    }
}
