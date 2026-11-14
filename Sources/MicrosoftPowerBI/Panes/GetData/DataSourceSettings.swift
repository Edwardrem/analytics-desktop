import SwiftUI
import AppKit
import FacetCore
import FacetQuery
import FacetDesign

/// Data source settings: privacy levels, stored permissions (approved native queries, script execution) and
/// Change Source for the sources of the current file; global permissions for every source the user has classified.
struct DataSourceSettingsSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var scope = Scope.file
    @State private var revision = 0
    @State private var ignorePrivacy = QuerySecurity.shared.ignorePrivacyLevels
    @State private var allowScripts = QuerySecurity.shared.allowScripts

    enum Scope: String, CaseIterable { case file = "Data sources in current file", global = "Global permissions" }

    private var security: QuerySecurity { .shared }
    private var sources: [QueryDataSource] {
        _ = revision
        switch scope {
        case .file: return store.doc.dataSources.map { QueryDataSource(kind: $0.kind, location: $0.location) }
        case .global: return security.sourcesWithPermissions
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Data Source Settings").font(Design.Typeface.headline)
                Spacer()
                Picker("", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(Design.Space.m)
            Hairline()
            if sources.isEmpty {
                EmptyState(systemImage: "lock.shield", title: scope == .file ? "This file has no data sources" : "No stored permissions",
                           message: scope == .file ? "Sources appear here after you load data with Get Data."
                                                   : "Privacy levels and approved native queries you set are listed here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(sources, id: \.self) { row($0); Hairline() } }
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Toggle("Ignore privacy levels when combining data (faster, but data from one source may be sent to another)", isOn: $ignorePrivacy)
                    .onChange(of: ignorePrivacy) { _, on in security.ignorePrivacyLevels = on }
                Toggle("Allow Python and R scripts to run on this Mac", isOn: $allowScripts)
                    .onChange(of: allowScripts) { _, on in security.allowScripts = on }
                HStack {
                    Button("Clear All Permissions") {
                        security.clearAllPermissions()
                        allowScripts = false
                        store.mutate("Clear Permissions", invalidates: .model) { d in
                            for i in d.dataSources.indices { d.dataSources[i].privacy = .none }
                        }
                        revision += 1
                    }
                    .help("Forget every privacy level, approved native query and the script permission")
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .font(Design.Typeface.caption)
            .padding(Design.Space.m)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 440)
    }

    private func row(_ source: QueryDataSource) -> some View {
        let approved = security.approvedQueryCount(kind: source.kind, location: source.location)
        return HStack(spacing: Design.Space.s) {
            Image(systemName: symbol(source.kind)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.location).lineLimit(1).truncationMode(.middle).help(source.location)
                Text(approved == 0 ? "\(source.kind) · Anonymous" : "\(source.kind) · Anonymous · \(approved) approved native quer\(approved == 1 ? "y" : "ies")")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Design.Space.s)
            Picker("Privacy level", selection: Binding(
                get: { security.privacyLevel(kind: source.kind, location: source.location) },
                set: { setPrivacy($0, source) })) {
                Text("None").tag(PrivacyLevel.none)
                Text("Public").tag(PrivacyLevel.public)
                Text("Organizational").tag(PrivacyLevel.organizational)
                Text("Private").tag(PrivacyLevel.private)
            }
            .labelsHidden().frame(width: 140)
            .help("Privacy level: Private data is never combined with other sources; Organizational data never with Public sources")
            Menu {
                if scope == .file, ["File", "Folder", "SQLite"].contains(source.kind) {
                    Button("Change Source…") { changeSource(source) }
                }
                Button("Clear Permissions") {
                    security.clearPermissions(kind: source.kind, location: source.location)
                    mirrorPrivacy(.none, source)
                    revision += 1
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Change the source or clear its permissions")
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "Folder": return "folder"
        case "SQLite", "PostgreSQL", "MySQL", "MariaDB", "AmazonRedshift": return "cylinder"
        case "SQL": return "cylinder.split.1x2"
        case "Web", "OData": return "globe"
        default: return "doc"
        }
    }

    private func setPrivacy(_ level: PrivacyLevel, _ source: QueryDataSource) {
        security.setPrivacyLevel(level, kind: source.kind, location: source.location)
        mirrorPrivacy(level, source)
        revision += 1
    }

    /// The document remembers the level too, so the file shows it on another Mac's Data source settings.
    private func mirrorPrivacy(_ level: PrivacyLevel, _ source: QueryDataSource) {
        guard store.doc.dataSources.contains(where: { $0.kind == source.kind && $0.location == source.location && $0.privacy != level }) else { return }
        store.mutate("Change Privacy Level", invalidates: .model) { d in
            for i in d.dataSources.indices where d.dataSources[i].kind == source.kind && d.dataSources[i].location == source.location {
                d.dataSources[i].privacy = level
            }
        }
    }

    private func changeSource(_ source: QueryDataSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = source.kind == "Folder"
        panel.canChooseFiles = source.kind != "Folder"
        panel.directoryURL = URL(fileURLWithPath: source.location).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, url.path != source.location else { return }
        let old = source.location, new = url.path
        var changed = 0
        store.mutate("Change Source", invalidates: .model) { d in
            for i in d.queries.indices {
                let updated = SourcePlanner.replacingLocation(old, with: new, in: d.queries[i].mScript)
                if updated != d.queries[i].mScript { d.queries[i].mScript = updated; changed += 1 }
            }
            for i in d.dataSources.indices where d.dataSources[i].kind == source.kind && d.dataSources[i].location == old {
                d.dataSources[i].location = new
                d.dataSources[i].displayName = url.lastPathComponent
            }
        }
        store.status = StatusMessage(kind: changed > 0 ? .success : .warning,
                                     text: changed > 0 ? "Changed the source of \(changed) quer\(changed == 1 ? "y" : "ies"). Refresh to load the new data."
                                                       : "No query refers to \(old) literally; edit the source step in the Power Query Editor.")
        revision += 1
    }
}
