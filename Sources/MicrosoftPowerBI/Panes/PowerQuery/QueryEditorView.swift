import SwiftUI
import AppKit
import FacetCore
import FacetDesign
import FacetQuery

/// Registers the Power Query Editor window's content.
@MainActor
enum PowerQueryFeature {
    static func register() {
        Features.queryEditorBuilder = { store in AnyView(QueryEditorView(store: store)) }
    }
}

/// The Power Query Editor: ribbon, queries pane, formula bar, data preview with profiling, query settings with
/// applied steps, and a status line. Changes stay in this window until Close & Apply or Apply.
struct QueryEditorView: View {
    @StateObject private var session: QueryEditorSession

    init(store: DocumentStore) { _session = StateObject(wrappedValue: QueryEditorSession(store: store)) }

    /// Data view unless the new editor's views are turned on in Settings.
    private var centre: QueryEditorSession.CentreView { session.newEditorViews ? session.centreView : .data }

    var body: some View {
        VStack(spacing: 0) {
            EditorRibbonView(session: session)
            Hairline()
            HStack(spacing: 0) {
                QueriesPane(session: session).frame(width: 230)
                Hairline(vertical: true)
                VStack(spacing: 0) {
                    if session.newEditorViews, session.showDiagram {
                        QueryDiagramView(session: session).frame(minHeight: 140, idealHeight: 220, maxHeight: 300)
                        Hairline()
                    }
                    if session.showFormulaBar, centre != .script, session.selectedQuery.map({ $0.kind != .parameter }) ?? false {
                        StepFormulaBar(session: session)
                        Hairline()
                    }
                    switch centre {
                    case .data: PreviewArea(session: session)
                    case .schema: SchemaView(session: session)
                    case .script: QueryScriptView(session: session)
                    }
                    if session.showProfile, centre == .data, session.preview != nil {
                        Hairline()
                        ColumnProfilePanel(session: session).frame(height: 200)
                    }
                }
                .frame(minWidth: 320)
                if session.showQuerySettings {
                    Hairline(vertical: true)
                    QuerySettingsPane(session: session).frame(width: 270)
                }
            }
            Hairline()
            EditorStatusBar(session: session)
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(Design.Palette.surface)
        .sheet(item: $session.dialog) { EditorDialogHost(session: session, dialog: $0) }
        .background(EditorWindowController(session: session))
        .onAppear { session.refreshPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .facetOpenQueryEditor)) { note in
            if ShellNotifications.isAddressed(note, to: session.store) { session.takeRoutedSelection() }
        }
    }
}

// MARK: - Window

/// Closes the editor window for Close & Apply / Close, and asks before a window with pending changes closes.
private struct EditorWindowController: NSViewRepresentable {
    @ObservedObject var session: QueryEditorSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.window == nil { DispatchQueue.main.async { coordinator.attach(to: nsView.window) } }
        nsView.window?.isDocumentEdited = session.hasPendingChanges
        if let request = session.closeRequest {
            DispatchQueue.main.async {
                session.closeRequest = nil
                coordinator.close(request)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    final class Coordinator: NSObject, NSWindowDelegate {
        let session: QueryEditorSession
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        init(session: QueryEditorSession) { self.session = session }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

        @MainActor func close(_ request: QueryEditorSession.CloseRequest) {
            switch request {
            case .apply: session.applyChanges(); window?.close()
            case .discard: session.discardChanges(); window?.close()
            case .ask: if confirm() { window?.close() }
            }
        }

        /// Apply / Discard / Cancel, as Power BI asks; true when the window may close.
        @MainActor func confirm() -> Bool {
            guard session.hasPendingChanges else { return true }
            let alert = NSAlert()
            alert.messageText = "Apply query changes?"
            alert.informativeText = "The queries have changes that are not applied to the model yet."
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: session.applyChanges(); return true
            case .alertSecondButtonReturn: session.discardChanges(); return true
            default: return false
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard MainActor.assumeIsolated({ confirm() }) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
    }
}

// MARK: - Formula bar

private struct StepFormulaBar: View {
    @ObservedObject var session: QueryEditorSession
    @State private var draft = ""
    @State private var problem: String?
    @State private var expanded = false

    private var key: String { "\(session.selectedQueryID?.uuidString ?? "")|\(session.currentStep?.name ?? "")|\(session.currentStep?.expression ?? "")" }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(alignment: .top, spacing: Design.Space.xs) {
                IconButton("xmark", help: "Discard the edit") { reset() }.disabled(draft == session.currentStep.map { "= " + $0.expression })
                IconButton("checkmark", help: "Commit the formula (Return)") { commit() }
                IconButton("function", help: "Insert a step after the selected one") { session.insertCustomStep() }
                TextField("= ", text: $draft, axis: .vertical)
                    .font(Design.Typeface.mono)
                    .textFieldStyle(.plain)
                    .lineLimit(expanded ? 4...14 : 1...3)
                    .onSubmit { commit() }
                    .padding(.vertical, Design.Space.xs)
                IconButton(expanded ? "chevron.up" : "chevron.down", help: expanded ? "Collapse the formula bar" : "Expand the formula bar") { expanded.toggle() }
            }
            if let problem {
                Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).textSelection(.enabled)
            }
        }
        .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.xxs)
        .onAppear { reset() }
        .onChange(of: key) { _, _ in reset() }
    }

    private func reset() { draft = session.currentStep.map { "= " + $0.expression } ?? ""; problem = nil }
    private func commit() { problem = session.setStepExpression(draft) }
}

// MARK: - Status bar

private struct EditorStatusBar: View {
    @ObservedObject var session: QueryEditorSession
    private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    var body: some View {
        HStack(spacing: Design.Space.m) {
            if let preview = session.preview {
                Text("\(preview.table.columnCount) column\(preview.table.columnCount == 1 ? "" : "s"), \(preview.table.rowCount)\(preview.isTruncated ? "+" : "") row\(preview.table.rowCount == 1 ? "" : "s")")
                Menu(session.profileWholeDataset ? "Column profiling based on entire data set" : "Column profiling based on top \(QueryEditorSession.previewRows) rows") {
                    Button("Column profiling based on top \(QueryEditorSession.previewRows) rows") { session.profileWholeDataset = false }
                    Button("Column profiling based on entire data set") { session.profileWholeDataset = true }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Profile the first \(QueryEditorSession.previewRows) rows or the whole data set")
            }
            if session.isEvaluating { ProgressView().controlSize(.mini) }
            if session.isRecordingDiagnostics { Label("Recording diagnostics", systemImage: "record.circle").foregroundStyle(Design.Palette.negative) }
            if let message = session.message {
                Text(message.text).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(message.kind == .error ? Design.Palette.negative : message.kind == .warning ? Design.Palette.caution : .secondary)
                    .help(message.text)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if session.hasPendingChanges { Text("Changes not applied").foregroundStyle(Design.Palette.caution) }
            if let time = session.previewTime { Text("Preview downloaded at \(Self.time.string(from: time))") }
        }
        .font(Design.Typeface.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Design.Space.m).frame(height: 24)
    }
}
