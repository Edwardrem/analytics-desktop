import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FacetCore
import FacetCloud
import FacetInterop
import FacetDesign

/// What Publish sends for a document, worked out before anything goes up.
///
/// The Power BI service does not read `.facet` documents. The semantic model goes up as TMDL and the report as PBIR
/// (the text formats of a Power BI project) and become a semantic model and a report in the workspace. Table data
/// stays on this Mac; the service loads it when the model is refreshed from sources it can reach.
struct PublishPlan {
    var modelParts: [FabricDefinitionPart]
    var reportParts: [FabricDefinitionPart]
    /// Things that will not work in the service as they do here.
    var notes: [String]

    static func make(for document: FacetDocument, name: String) -> PublishPlan {
        let parts = PBIPProject.definitionParts(for: document, name: name)
        var notes = parts.warnings.map(\.message)
        let local = localSourceQueries(document.queries)
        if !local.isEmpty {
            notes.append("The service can't refresh from files on this Mac (\(local.joined(separator: ", "))). Move them to OneDrive or SharePoint, or set up an on-premises data gateway.")
        }
        let scripted = document.queries.filter { $0.mScript.contains("Python.Execute") || $0.mScript.contains("R.Execute") }.map(\.name)
        if !scripted.isEmpty {
            notes.append("Python and R steps (\(scripted.joined(separator: ", "))) need a personal gateway to refresh in the service.")
        }
        let queryless = document.model.tables.filter { $0.sourceQuery == nil && $0.expression == nil }.map(\.name)
        if !queryless.isEmpty {
            notes.append("Tables without a query (\(queryless.joined(separator: ", "))) arrive empty: entered and sample data aren't uploaded.")
        }
        return PublishPlan(modelParts: parts.model.map { FabricDefinitionPart(path: $0.path, content: $0.data) },
                           reportParts: parts.report.map { FabricDefinitionPart(path: $0.path, content: $0.data) },
                           notes: notes)
    }

    /// Queries that read files or folders on this Mac.
    static func localSourceQueries(_ queries: [QueryDefinition]) -> [String] {
        queries.filter { q in ["File.Contents(", "Folder.Files(", "Folder.Contents("].contains { q.mScript.contains($0) } }.map(\.name)
    }
}

struct PublishSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @StateObject private var catalog = CloudCatalogModel(fabric: MicrosoftRuntime.shared.services.fabric,
                                                         powerBI: MicrosoftRuntime.shared.services.powerBI)
    enum Route: Hashable { case definitions, importedFile, otherFile }
    @State private var name = ""
    @State private var route: Route = .definitions
    @State private var otherFile: URL?
    @State private var replace = true
    @State private var progress: String?
    @State private var failure: String?
    @State private var outcome: PublishOutcome?

    private var importedPBIX: URL? {
        DocumentFiles.of(store).importedFrom.flatMap { u in
            u.pathExtension.lowercased() == "pbix" && FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }
    @State private var notes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Publish to Power BI").font(Design.Typeface.headline)
            if !runtime.hasWorkAccount {
                Text("Publishing needs a work or school Microsoft account with access to a Power BI workspace. Sign in with one from the Account menu.")
                    .font(Design.Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let outcome {
                result(outcome)
            } else {
                form
            }
            HStack {
                if let progress { ProgressView().controlSize(.small); Text(progress).font(Design.Typeface.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(outcome == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if outcome == nil && runtime.hasWorkAccount {
                    Button("Publish") { publish() }.keyboardShortcut(.defaultAction).disabled(!canPublish)
                }
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 560)
        .onAppear {
            name = store.displayName
            notes = PublishPlan.make(for: store.doc, name: name).notes
            if runtime.hasWorkAccount { catalog.loadWorkspaces() }
        }
    }

    private var canPublish: Bool {
        progress == nil && catalog.selectedWorkspace != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (route != .otherFile || otherFile != nil)
    }

    @ViewBuilder private var form: some View {
        LabeledContent("Workspace") {
            if catalog.isLoadingWorkspaces { ProgressView().controlSize(.small) }
            else {
                Picker("", selection: $catalog.selectedWorkspaceID) {
                    ForEach(catalog.workspaces) { ws in Text(ws.name).tag(Optional(ws.id)) }
                }
                .labelsHidden()
            }
        }
        if let error = catalog.lastError {
            Text(AccountMessages.describe(error)).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Name") { TextField("", text: $name) }
        Picker("Send", selection: $route) {
            Text("Semantic model and report").tag(Route.definitions)
            if let importedPBIX { Text("The original \(importedPBIX.lastPathComponent)").tag(Route.importedFile) }
            Text("A Power BI file…").tag(Route.otherFile)
        }
        .pickerStyle(.radioGroup)
        .onChange(of: route) { _, r in if r == .otherFile, otherFile == nil { chooseFile() } }
        Toggle("Replace items with the same name", isOn: $replace)
        Group {
            switch route {
            case .definitions:
                Text("\(AppIdentity.name) documents aren't a format the service reads, so the model is sent as TMDL and the report as PBIR, the formats of a Power BI project. Data stays on this Mac: after publishing, set the data source credentials in the service and refresh the semantic model.")
                ForEach(notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Design.Palette.caution) }
            case .importedFile:
                Text("Uploads the .pbix exactly as it was opened. Changes made here aren't in it.")
            case .otherFile:
                HStack {
                    Text(otherFile?.lastPathComponent ?? "No file chosen")
                    Button("Choose…") { chooseFile() }
                }
                Text("The service imports .pbix reports, Excel workbooks and .rdl paginated reports as they are.")
            }
        }
        .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let failure {
            Text(failure).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func result(_ outcome: PublishOutcome) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Label(outcome.replacedExisting ? "Replaced “\(name)” in \(catalog.selectedWorkspace?.name ?? "the workspace")."
                                            : "Published “\(name)” to \(catalog.selectedWorkspace?.name ?? "the workspace").",
                  systemImage: "checkmark.circle").foregroundStyle(Design.Palette.positive)
            if route == .definitions {
                Text("Next, in the service: open the semantic model's settings, enter data source credentials, and refresh it.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = ServiceLinks.openable(outcome.reportURL) { Button("Open in Power BI") { NSWorkspace.shared.open(url) } }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PowerBIPublisher.importableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a .pbix, .xlsx or .rdl file to publish."
        if panel.runModal() == .OK, let url = panel.url { otherFile = url } else if otherFile == nil { route = .definitions }
    }

    private func publish() {
        guard let ws = catalog.selectedWorkspace else { return }
        let workspace = PublishWorkspace(id: ws.id, name: ws.name, isPersonal: ws.isPersonal)
        let title = name.trimmingCharacters(in: .whitespaces)
        let publisher = MicrosoftRuntime.shared.services.publisher
        let plan = PublishPlan.make(for: store.doc, name: title)
        let file = route == .importedFile ? importedPBIX : otherFile
        let route = self.route
        failure = nil
        progress = "Publishing…"
        Task { @MainActor in
            do {
                let report: (String) -> Void = { text in Task { @MainActor in if progress != nil { progress = text } } }
                if route == .definitions {
                    outcome = try await publisher.publishDefinition(name: title, workspace: workspace, modelParts: plan.modelParts,
                                                                    reportParts: plan.reportParts, replaceExisting: replace, progress: report)
                } else if let file {
                    outcome = try await publisher.publishFile(at: file, name: title, workspace: workspace, replaceExisting: replace, progress: report)
                }
                store.status = StatusMessage(kind: .success, text: "Published “\(title)” to \(ws.name).")
            } catch {
                failure = AccountMessages.describe(error)
            }
            progress = nil
        }
    }
}
