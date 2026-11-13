import SwiftUI
import FacetCore
import FacetDesign
import FacetInterop

/// The TMDL view workspace: script tabs, a code editor over the active script, an error strip with
/// line numbers, and the model tree on the right. Applying goes through the diff-preview sheet and
/// `DocumentStore.mutate`, so every apply is one undoable model edit. Toolbar buttons run the same
/// commands the menu registers (`tmdl.*`), so behaviour never forks.
struct TMDLView: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: TMDLViewSession
    @AppStorage("tmdl.treeVisible") private var treeVisible = true

    var body: some View {
        if !TMDLViewFeature.hasContent(store) {
            VStack(spacing: Design.Space.m) {
                EmptyState(systemImage: "curlybraces", title: "Nothing to script yet",
                           message: "Add data to the model, then script and edit it here as TMDL.")
                    .frame(maxHeight: 150)
                Button("Get Data…") { AppCommands.run("data.get", store) }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Design.Palette.surface)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TMDLTabBar(session: session)
                    Hairline()
                    TMDLToolbar(session: session, treeVisible: $treeVisible)
                    Hairline()
                    editor
                }
                if treeVisible {
                    Hairline(vertical: true)
                    TMDLObjectTree(session: session).frame(width: 280)
                }
            }
            .background(Design.Palette.elevated)
            .onAppear { session.ensureTabs() }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let tab = session.activeTab {
                CodeEditor(text: Binding(get: { session.activeText }, set: { session.setText($0, for: tab.id) }),
                           language: .tmdl, model: store.model, issues: session.issues,
                           showsLineNumbers: true, onCommit: nil,
                           // A tree row arrives under its own pasteboard type and is handled by the
                           // text view itself, so it is scripted and never inserted as text.
                           objectDrop: CodeEditor.ObjectDrop(type: TMDLDragPayload.pasteboardType, onDrop: { data in
                               guard let ref = TMDLDragPayload.decode(data) else { return false }
                               session.selectedRef = ref
                               session.script(ref)
                               return true
                           }, onTargeted: { session.dropTargeted = $0 }))
                    .id(tab.id)
            } else {
                EmptyState(systemImage: "curlybraces", title: "No script tab",
                           message: "New Script creates a tab; select an object in the tree to script it.")
            }
            TMDLErrorStrip(session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if session.dropTargeted { Color.accentColor.opacity(0.06).allowsHitTesting(false) }
        }
    }
}

// MARK: - Tabs

private struct TMDLTabBar: View {
    @ObservedObject var session: TMDLViewSession
    @State private var renaming: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Design.Space.xxs) {
                ForEach(session.tabs) { tab in
                    TMDLTabChip(session: session, tab: tab, isActive: session.activeTab?.id == tab.id,
                                canClose: session.tabs.count > 1, renaming: $renaming)
                }
                IconButton("plus", help: "New script tab") { session.addTab() }
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
        }
    }
}

private struct TMDLTabChip: View {
    @ObservedObject var session: TMDLViewSession
    let tab: TMDLViewSession.ScriptTab
    let isActive: Bool
    let canClose: Bool
    @Binding var renaming: UUID?
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            if renaming == tab.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Design.Typeface.body)
                    .frame(width: 120)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: focused) { _, now in if !now, renaming == tab.id { commit() } }
                    .onAppear { draft = tab.name; focused = true }
            } else {
                Text(tab.name).font(Design.Typeface.body).lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            if canClose, renaming != tab.id {
                Button { session.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || isActive ? 1 : 0)
                .help("Close tab")
                .accessibilityLabel("Close \(tab.name)")
            }
        }
        .padding(.leading, Design.Space.m)
        .padding(.trailing, canClose ? Design.Space.s : Design.Space.m)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(isActive ? Design.Palette.fillStrong : (hovering ? Design.Palette.fill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { session.setActive(tab.id); renaming = tab.id }
        .onTapGesture { session.setActive(tab.id) }
        .contextMenu {
            Button("Rename") { session.setActive(tab.id); renaming = tab.id }
            Divider()
            Button("Close") { session.close(tab.id) }.disabled(!canClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Script tab \(tab.name)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func commit() {
        session.rename(tab.id, to: draft)
        renaming = nil
    }
}

// MARK: - Toolbar

private struct TMDLToolbar: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: TMDLViewSession
    @Binding var treeVisible: Bool

    var body: some View {
        let hasSelection = session.selectedRef != nil
        let hasScript = session.hasScript
        HStack(spacing: Design.Space.xs) {
            Button { AppCommands.run("tmdl.script", store) } label: { Label("Script", systemImage: "arrow.down.doc") }
                .help(hasSelection ? "Script the object selected in the tree into this tab"
                                   : "Select an object in the model tree to script it")
                .disabled(!hasSelection)
            IconButton("shippingbox", help: "Replace this tab with a fresh script of the whole model") {
                AppCommands.run("tmdl.scriptModel", store)
            }
            IconButton("checkmark.seal", help: hasScript ? "Check this script for syntax and semantic problems (⌥⇧V)"
                                                         : "Nothing to check: this tab is empty") {
                AppCommands.run("tmdl.validate", store)
            }
            .disabled(!hasScript)
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, Design.Space.xs)
            Button { AppCommands.run("tmdl.apply", store) } label: { Label("Apply…", systemImage: "arrow.up.doc") }
                .help(hasScript ? "Preview the difference, then update the model (⌥⇧A)"
                                : "Nothing to apply: this tab is empty")
                .disabled(!hasScript)

            Spacer(minLength: Design.Space.s)

            IconButton("sidebar.right", help: treeVisible ? "Hide model tree" : "Show model tree", isOn: treeVisible) {
                withAnimation(Design.Motion.quick) { treeVisible.toggle() }
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
    }
}

// MARK: - Error strip

/// Quiet strip under the editor: the last error with its line number, cleared with ✕.
private struct TMDLErrorStrip: View {
    @ObservedObject var session: TMDLViewSession

    var body: some View {
        if let error = session.error {
            VStack(spacing: 0) {
                Hairline()
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Design.Palette.negative)
                    Text(error.errorDescription ?? error.message).font(Design.Typeface.caption)
                        .foregroundStyle(.primary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Design.Space.s)
                    if let line = error.line {
                        Button("Show line \(line)") { session.revealError() }.buttonStyle(.link).font(Design.Typeface.caption)
                    }
                    IconButton("xmark", help: "Clear error") { session.clearError() }
                }
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.s)
                .background(Design.Palette.negative.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture { session.revealError() }
            }
        }
    }
}
