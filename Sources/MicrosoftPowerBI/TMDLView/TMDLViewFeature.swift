import SwiftUI
import FacetCore
import FacetInterop

/// The TMDL view: script and edit the whole semantic model as Tabular Model Definition Language code.
@MainActor
enum TMDLViewFeature {
    static func register() {
        Features.workspaceBuilders[.tmdl] = { store in
            AnyView(TMDLView(session: TMDLViewSession.of(store)))
        }
        AppCommands.register(commands)
    }

    /// True when the document has anything to script: the same condition the workspace uses to show
    /// its editor, so no command is enabled over an empty state or disabled over a live one.
    static func hasContent(_ store: DocumentStore) -> Bool {
        TMDLViewSession.hasContent(model: store.model, queries: store.doc.queries)
    }

    /// The commands, in the order the ribbon's TMDL tab and the Modeling menu list them.
    static func commands() -> [AppCommand] {
        let inView: @MainActor (DocumentStore) -> Bool = { $0.view == .tmdl && hasContent($0) }
        let hasScript: @MainActor (DocumentStore) -> Bool = { inView($0) && TMDLViewSession.of($0).hasScript }
        return [
            AppCommand(id: "tmdl.script", title: "Script as TMDL", menu: .modeling, symbol: "arrow.down.doc",
                       separatorBefore: true, help: "Script the selected object as TMDL",
                       isEnabled: { s in
                           s.view == .tmdl ? inView(s) && TMDLViewSession.of(s).selectedRef != nil
                                           : TMDLViewSession.ref(table: FieldPaneContext.table, field: FieldPaneContext.field) != nil
                       }) { scriptTarget($0) },
            AppCommand(id: "tmdl.scriptModel", title: "Script Whole Model", menu: .modeling, symbol: "shippingbox",
                       help: "Replace the active tab with a fresh script of the whole model", isEnabled: inView) {
                TMDLViewSession.of($0).scriptWholeModel()
            },
            AppCommand(id: "tmdl.newTab", title: "New Script Tab", menu: .modeling, symbol: "plus.square.on.square",
                       isEnabled: hasContent) { s in
                s.view = .tmdl
                TMDLViewSession.of(s).addTab()
            },
            AppCommand(id: "tmdl.validate", title: "Validate Script", menu: .modeling, symbol: "checkmark.seal",
                       shortcut: .init("v", modifiers: [.option, .shift]), isEnabled: hasScript) {
                TMDLViewSession.of($0).validate()
            },
            AppCommand(id: "tmdl.apply", title: "Apply Script with Preview…", menu: .modeling, symbol: "arrow.up.doc",
                       shortcut: .init("a", modifiers: [.option, .shift]), isEnabled: hasScript) { previewApply($0) },
        ]
    }

    /// `tmdl.script`. In the TMDL view it scripts the tree selection into the active tab. From any
    /// other view it scripts the table or field a Data-pane context menu set in `FieldPaneContext`
    /// into a tab of its own and switches to the TMDL view. The context is used once, then cleared.
    static func scriptTarget(_ store: DocumentStore) {
        let session = TMDLViewSession.of(store)
        if store.view == .tmdl {
            session.scriptSelection()
            return
        }
        let target = TMDLViewSession.ref(table: FieldPaneContext.table, field: FieldPaneContext.field)
        FieldPaneContext.table = nil
        FieldPaneContext.field = nil
        guard let target else {
            store.status = StatusMessage(kind: .info, text: "Right-click a table or field in the Data pane and choose Script as TMDL.")
            return
        }
        session.selectedRef = target
        session.script(target, inNewTab: true)
        store.view = .tmdl
    }

    /// `tmdl.apply`: opens the preview sheet at once and works out the difference in the background.
    static func previewApply(_ store: DocumentStore) {
        let session = TMDLViewSession.of(store)
        guard let tab = session.activeTab, session.hasScript else {
            store.status = StatusMessage(kind: .info, text: "The script tab is empty; script an object first.")
            return
        }
        let preview = TMDLApplyPreview()
        preview.start(script: tab.text, model: store.model, queries: store.doc.queries) { [weak session] error in
            // The line is underlined in the tab the preview was made from.
            session?.report(error, tab: tab.id)
        }
        store.present {
            TMDLApplySheet(session: session, preview: preview, tab: tab.id, isPresented: sheetBinding(store))
        }
    }

    /// A binding that closes the sheet the store is showing.
    private static func sheetBinding(_ store: DocumentStore) -> Binding<Bool> {
        Binding(get: { store.sheet != nil }, set: { shown in if !shown { store.dismissSheet() } })
    }
}

/// The difference an apply would make, computed once off the main actor and shown by `TMDLApplySheet`.
@MainActor
final class TMDLApplyPreview: ObservableObject {
    enum State {
        case computing
        case ready(TMDLApplyResult)
        case failed(TMDLError)
    }
    @Published private(set) var state: State = .computing
    private var task: Task<Void, Never>?

    /// Starts the computation; `onFailure` runs on the main actor if the script can't be applied.
    func start(script: String, model: SemanticModel, queries: [QueryDefinition],
               onFailure: @escaping @MainActor (TMDLError) -> Void = { _ in }) {
        task?.cancel()
        state = .computing
        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                TMDLViewSession.computeApply(script: script, model: model, queries: queries)
            }.value
            guard !Task.isCancelled, let self else { return }
            switch outcome {
            case .success(let result): self.state = .ready(result)
            case .failure(let error): self.state = .failed(error); onFailure(error)
            }
        }
    }

    /// Waits for the computation started by `start` (used by tests).
    func finish() async { await task?.value }

    func cancel() { task?.cancel() }
}
