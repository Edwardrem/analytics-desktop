import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// Settings ▸ Developer: the Modeling MCP server and Power BI project options.
struct DeveloperSettings: View {
    @ObservedObject private var bridge = AgentBridge.shared
    @AppStorage(AppSettings.Key.mcpServerEnabled.rawValue) private var enabled = false
    @AppStorage(AppSettings.Key.pbipDataCache.rawValue) private var dataCache = false
    @State private var revealToken = false
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { on in
                    enabled = on
                    if on { Task { await bridge.start() } } else { bridge.stop() }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modeling MCP server")
                        Text("Lets AI agents and tools on this Mac read open models and run DAX. Every change they make asks you first.")
                            .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                }
                if bridge.isRunning {
                    LabeledContent("Endpoint") {
                        HStack {
                            Text(bridge.endpoint).font(Design.Typeface.mono).textSelection(.enabled)
                            IconButton("doc.on.doc", help: "Copy the endpoint") { copy(bridge.endpoint, "endpoint") }
                        }
                    }
                    LabeledContent("Session token") {
                        HStack {
                            Text(revealToken ? bridge.token : String(repeating: "•", count: 16)).font(Design.Typeface.mono)
                                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            IconButton(revealToken ? "eye.slash" : "eye", help: revealToken ? "Hide the token" : "Show the token") { revealToken.toggle() }
                            IconButton("doc.on.doc", help: "Copy the token") { copy(bridge.token, "token") }
                        }
                    }
                    HStack {
                        Button("Copy Client Configuration") { copy(bridge.clientConfiguration, "configuration") }
                            .help("JSON for an MCP client: the endpoint and an Authorization header with this session's token")
                        if let copied { Text("Copied the \(copied).").font(Design.Typeface.caption).foregroundStyle(.secondary) }
                    }
                    Text("Listens on 127.0.0.1 only. The token changes every time the server starts and is never saved; anyone who has it can read your open models until you turn the server off.")
                        .font(Design.Typeface.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                } else if let error = bridge.lastError {
                    Text(error).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                }
            } header: { Text("Agent bridge") }

            Section("Power BI projects") {
                Toggle(isOn: $dataCache) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep table data in the project")
                        Text("Writes a data cache under .pbi (ignored by Git) so a project reopens without refreshing. Power BI Desktop ignores it.")
                            .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Projects open with File ▸ Open and save with File ▸ Save as Power BI Project. Edits made to an open project in another app reload it.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }
}
