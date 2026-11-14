import SwiftUI
import AppKit
import FacetCore
import FacetDesign
import FacetVisuals

/// The Source card of a paginated report, Power Apps, Power Automate or Metrics visual: an ID or
/// https address (a scorecard also takes its workspace ID), checked before it is stored, with what
/// the service needs said in place.
struct FormatEmbedRows: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    @State private var entry = ""
    @State private var workspace = ""
    @State private var problem: String?

    var body: some View {
        let type = spec.type
        VStack(alignment: .leading, spacing: Design.Space.s) {
            PaneNote(EmbedSetup.requirement(type))
            PropertyRow(EmbedSetup.entryLabel(type)) {
                TextField(EmbedSetup.placeholder(type), text: $entry)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(apply)
                    .accessibilityLabel(EmbedSetup.entryLabel(type))
            }
            if type == .metrics {
                PropertyRow("Workspace ID") {
                    TextField("Needed with a scorecard ID", text: $workspace)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit(apply)
                        .accessibilityLabel("Workspace ID")
                }
            }
            if let problem {
                Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Design.Space.s) {
                Button("Apply", action: apply)
                    .controlSize(.small)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Check the \(EmbedSetup.entryLabel(type).lowercased()) and show it in the visual")
                if type != .powerAutomate, let url = EmbedAddress.httpsURL(from: spec.content) {
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(Design.Typeface.caption)
                        .help("Open \(url.host ?? "the page") in your browser")
                }
            }
            status
        }
        .onAppear { entry = spec.content }
        .onChange(of: spec.content) { _, content in entry = content; problem = nil }
    }

    @ViewBuilder private var status: some View {
        if let url = EmbedAddress.httpsURL(from: spec.content) {
            if spec.type == .powerAutomate {
                let rows = store.visualData[spec.id]?.table.rowCount ?? 0
                PaneNote("Connected to a flow at \(url.host ?? "its address"). The button sends the visual's \(rows) \(rows == 1 ? "row" : "rows"); add fields to Values to choose what it sends.")
            } else {
                PaneNote("Showing \(url.host ?? url.absoluteString).")
            }
        } else if !spec.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("The stored address isn't https, so the visual shows nothing. Enter an https:// address or an ID.")
                .font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apply() {
        switch EmbedSetup.url(for: spec.type, entry: entry, workspace: workspace) {
        case .success(let url):
            problem = nil
            entry = url.absoluteString
            guard url.absoluteString != spec.content else { return }
            store.updateVisuals([spec.id], name: "Set Source") { $0.content = url.absoluteString }
        case .failure(let p):
            problem = p.message
        }
    }
}
