import SwiftUI
import AppKit
import FacetCore
import FacetCloud
import FacetDesign

/// The OneLake catalog: Fabric workspaces and their items (Power BI workspaces when Fabric isn't available), with
/// type, endorsement and sensitivity. Semantic models can be imported as a snapshot (tables, measures, relationships
/// and up to 100,000 rows per table); lakehouse files can be loaded through Power Query; reports open in the browser.
struct OneLakeCatalogSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @StateObject private var catalog = CloudCatalogModel(fabric: MicrosoftRuntime.shared.services.fabric,
                                                         powerBI: MicrosoftRuntime.shared.services.powerBI)
    @State private var selectedItem: CloudCatalogModel.Item.ID?
    @State private var working: String?
    @State private var failure: String?
    @State private var lakeFiles: [OneLakePath] = []
    @State private var selectedFile: OneLakePath.ID?

    private var item: CloudCatalogModel.Item? { catalog.visibleItems.first { $0.id == selectedItem } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OneLake catalog").font(Design.Typeface.headline)
                if catalog.isUsingPowerBIFallback {
                    Text("Power BI workspaces").font(Design.Typeface.caption).foregroundStyle(.secondary)
                        .help("Fabric isn't available to this account, so Power BI workspaces and their models and reports are shown")
                }
                Spacer()
                TextField("Search", text: $catalog.searchText).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            .padding(Design.Space.l)
            Hairline()
            if !runtime.hasWorkAccount {
                EmptyState(systemImage: "building.2", title: "Work or school account needed",
                           message: "The OneLake catalog lists Fabric and Power BI items, which personal Microsoft accounts can't use. Sign in with a work or school account.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    workspaces.frame(width: 200)
                    Hairline(vertical: true)
                    VStack(spacing: 0) {
                        filters
                        Hairline()
                        items
                    }
                    Hairline(vertical: true)
                    details.frame(width: 240)
                }
            }
            Hairline()
            HStack {
                if let working { ProgressView().controlSize(.small); Text(working).font(Design.Typeface.caption).foregroundStyle(.secondary) }
                if let failure { Text(failure).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).lineLimit(3) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Design.Space.l)
        }
        .frame(width: 900, height: 540)
        .onAppear { if runtime.hasWorkAccount { catalog.loadWorkspaces() } }
        .onChange(of: selectedItem) { _, _ in lakeFiles = []; selectedFile = nil; failure = nil }
    }

    private var workspaces: some View {
        Group {
            if catalog.isLoadingWorkspaces { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(selection: $catalog.selectedWorkspaceID) {
                    ForEach(catalog.workspaces) { ws in
                        Label(ws.name, systemImage: ws.isPersonal ? "person" : "square.grid.2x2").tag(ws.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: Design.Space.xs) {
            ForEach(FabricItemType.dataItemTypes + [.report], id: \.self) { type in
                let on = catalog.typeFilter.contains(type)
                Button(type.displayName) {
                    if on { catalog.typeFilter.remove(type) } else { catalog.typeFilter.insert(type) }
                }
                .buttonStyle(.plain).font(Design.Typeface.caption)
                .foregroundStyle(on ? Design.Palette.accent : .secondary)
                .help(on ? "Hide \(type.displayName.lowercased())s" : "Show \(type.displayName.lowercased())s")
            }
            Spacer()
            Toggle("Endorsed", isOn: $catalog.endorsedOnly).toggleStyle(.checkbox).font(Design.Typeface.caption)
                .help("Show only promoted and certified items")
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
    }

    @ViewBuilder private var items: some View {
        if catalog.isLoadingItems { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if let error = catalog.lastError {
            EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't load the catalog", message: AccountMessages.describe(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if catalog.visibleItems.isEmpty {
            EmptyState(systemImage: "tray", title: "No items", message: "Nothing of the chosen types in this workspace.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(catalog.visibleItems, selection: $selectedItem) { item in
                HStack(spacing: Design.Space.s) {
                    Image(systemName: Self.symbol(item.itemType)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        Text(item.typeDisplayName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let e = item.endorsement, !e.isEmpty, e != "None" {
                        Image(systemName: e == "Certified" ? "checkmark.seal.fill" : "seal").foregroundStyle(Design.Palette.accent).help(e)
                    }
                }
                .tag(item.id)
            }
            .listStyle(.inset)
        }
    }

    static func symbol(_ type: FabricItemType?) -> String {
        switch type {
        case .lakehouse: return "house"
        case .warehouse: return "building.columns"
        case .semanticModel: return "cube"
        case .report: return "chart.bar.doc.horizontal"
        case .sqlDatabase, .mirroredDatabase, .sqlEndpoint: return "cylinder"
        case .kqlDatabase: return "waveform.path.ecg"
        case .dataflow: return "arrow.triangle.branch"
        case nil: return "doc"
        }
    }

    @ViewBuilder private var details: some View {
        if let item {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Text(item.name).font(Design.Typeface.bodyStrong)
                Text(item.typeDisplayName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                if !item.description.isEmpty { Text(item.description).font(Design.Typeface.caption).fixedSize(horizontal: false, vertical: true) }
                if let e = item.endorsement, !e.isEmpty, e != "None" { Label(e, systemImage: "checkmark.seal").font(Design.Typeface.caption) }
                if let label = item.sensitivityLabelName ?? item.sensitivityLabelID {
                    Label(label, systemImage: "lock.doc").font(Design.Typeface.caption)
                }
                Hairline()
                actions(for: item)
                Spacer()
            }
            .padding(Design.Space.m)
        } else {
            EmptyState(systemImage: "info.circle", title: "Select an item").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func actions(for item: CloudCatalogModel.Item) -> some View {
        switch item.itemType {
        case .semanticModel:
            Text("Imports the model's tables, measures and relationships with up to 100,000 rows per table, as a snapshot you can model and report on here. It isn't kept in sync with the service.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Import Tables") { importModel(item) }.disabled(working != nil)
        case .lakehouse:
            Text("Load a CSV, JSON, Excel or Parquet file from the lakehouse's Files. Delta tables need the SQL analytics endpoint, which this sheet doesn't use; Get Data ▸ Lakehouses reads and combines the Files folder in place.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if lakeFiles.isEmpty {
                Button("Browse Files") { listFiles(item) }.disabled(working != nil)
            } else {
                List(lakeFiles.filter { !$0.isDirectory }, selection: $selectedFile) { f in
                    Text(f.name).font(Design.Typeface.caption).tag(f.id)
                }
                .frame(minHeight: 140)
                Button("Load File") { if let f = lakeFiles.first(where: { $0.id == selectedFile }) { load(f, from: item) } }
                    .disabled(working != nil || selectedFile == nil)
            }
        case .report:
            Button("Open in Power BI") { openReport(item) }
        default:
            Text("\(item.typeDisplayName)s are reached through a SQL or KQL endpoint, which \(AppIdentity.name) can't connect to yet.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspaceRef: PowerBIWorkspaceRef { catalog.selectedWorkspace?.powerBIRef ?? .myWorkspace }

    private func importModel(_ item: CloudCatalogModel.Item) {
        let powerBI = MicrosoftRuntime.shared.services.powerBI
        let ref = workspaceRef
        working = "Reading “\(item.name)”…"
        failure = nil
        Task { @MainActor in
            do {
                var model = try await powerBI.liveModel(datasetID: item.id, name: item.name, in: ref)
                var tables: [DataTable] = []
                var truncated: [String] = []
                for i in model.tables.indices {
                    let name = model.tables[i].name
                    working = "Importing \(name) (\(i + 1) of \(model.tables.count))…"
                    let quoted = "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
                    var t = try await powerBI.executeQuery("EVALUATE TOPN(\(Self.rowLimit), \(quoted))", datasetID: item.id, in: ref, resultName: name)
                    t.name = name
                    if t.rowCount >= Self.rowLimit { truncated.append(name) }
                    tables.append(t)
                    model.tables[i].storageMode = .import
                }
                let imported = model
                store.mutate("Import “\(item.name)”", invalidates: .model) { d in
                    for t in imported.tables {
                        d.model.tables.removeAll { $0.name.caseInsensitiveCompare(t.name) == .orderedSame }
                        d.model.tables.append(t)
                    }
                    d.model.relationships.append(contentsOf: imported.relationships.filter { r in
                        !d.model.relationships.contains { $0.fromTable == r.fromTable && $0.fromColumn == r.fromColumn && $0.toTable == r.toTable && $0.toColumn == r.toColumn }
                    })
                    for t in tables { d.data[t.name] = t }
                }
                working = nil
                store.status = StatusMessage(kind: truncated.isEmpty ? .success : .warning,
                    text: "Imported \(tables.count) table\(tables.count == 1 ? "" : "s") from “\(item.name)”."
                        + (truncated.isEmpty ? "" : " \(truncated.joined(separator: ", ")) reached the 100,000-row limit and may be incomplete."))
                dismiss()
            } catch {
                working = nil
                failure = AccountMessages.describe(error)
            }
        }
    }

    static let rowLimit = 100_000

    private func listFiles(_ item: CloudCatalogModel.Item) {
        let fabric = MicrosoftRuntime.shared.services.fabric
        working = "Listing files…"
        failure = nil
        Task { @MainActor in
            do {
                lakeFiles = try await fabric.oneLakePaths(workspaceID: item.workspaceID, directory: "\(item.id)/Files", recursive: true)
                    .filter { $0.isDirectory || LakeFile.mScript(for: URL(fileURLWithPath: $0.name)) != nil }
                if lakeFiles.allSatisfy(\.isDirectory) { failure = "No CSV, JSON, Excel or Parquet files in this lakehouse's Files." }
            } catch {
                failure = AccountMessages.describe(error)
            }
            working = nil
        }
    }

    private func load(_ file: OneLakePath, from item: CloudCatalogModel.Item) {
        let fabric = MicrosoftRuntime.shared.services.fabric
        working = "Downloading \(file.name)…"
        failure = nil
        Task { @MainActor in
            do {
                let folder = LakeFile.downloadsFolder.appendingPathComponent(CloudDocumentSync.safeFileName(item.name), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let local = try await fabric.downloadOneLakeFile(workspaceID: item.workspaceID, path: file.path,
                                                                 destination: folder.appendingPathComponent(CloudDocumentSync.safeFileName(file.name)))
                guard let script = LakeFile.mScript(for: local) else { throw CocoaError(.fileReadUnsupportedScheme) }
                let name = LakeFile.queryName(for: local, existing: Set(store.doc.queries.map(\.name)))
                store.mutate("Load \(file.name)", invalidates: .layout) { $0.queries.append(QueryDefinition(name: name, mScript: script)) }
                store.refreshData(only: [name])
                working = nil
                dismiss()
            } catch {
                working = nil
                failure = AccountMessages.describe(error)
            }
        }
    }

    private func openReport(_ item: CloudCatalogModel.Item) {
        let powerBI = MicrosoftRuntime.shared.services.powerBI
        let ref = workspaceRef
        Task { @MainActor in
            if let web = (try? await powerBI.reports(in: ref))?.first(where: { $0.id == item.id })?.webUrl,
               let url = ServiceLinks.openable(URL(string: web)) {
                NSWorkspace.shared.open(url)
            } else {
                failure = "The service didn't return an address for “\(item.name)”."
            }
        }
    }
}

/// Files downloaded from OneLake become ordinary Power Query file sources.
enum LakeFile {
    static var downloadsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppIdentity.name, isDirectory: true).appendingPathComponent("OneLake", isDirectory: true)
    }

    /// The M query that reads a downloaded file, or nil for types Power Query here can't read.
    static func mScript(for url: URL) -> String? {
        let path = "\"" + url.path.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let source: String
        switch url.pathExtension.lowercased() {
        case "csv", "txt":
            return "let\n    Source = Csv.Document(File.Contents(\(path)), [Delimiter = \",\", Encoding = 65001]),\n    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true])\nin\n    Promoted"
        case "tsv":
            return "let\n    Source = Csv.Document(File.Contents(\(path)), [Delimiter = \"#(tab)\", Encoding = 65001]),\n    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true])\nin\n    Promoted"
        case "json": source = "Table.FromRecords(Json.Document(File.Contents(\(path))))"
        case "xlsx", "xlsm": source = "Excel.Workbook(File.Contents(\(path)), null, true){0}[Data]"
        case "parquet": source = "Parquet.Document(File.Contents(\(path)))"
        default: return nil
        }
        return "let\n    Source = \(source)\nin\n    Source"
    }

    /// A query name from the file name that doesn't clash with the document's queries.
    static func queryName(for url: URL, existing: Set<String>) -> String {
        let base = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces)
        var name = base.isEmpty ? "Query" : base
        var n = 2
        while existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) (\(n))"; n += 1 }
        return name
    }
}
