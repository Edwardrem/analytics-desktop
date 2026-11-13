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

    static func commands() -> [AppCommand] {
        let inView: @MainActor (DocumentStore) -> Bool = {
            $0.view == .tmdl && TMDLViewSession.hasObjects($0.model)
        }
        return [
            AppCommand(id: "tmdl.newTab", title: "New Script Tab", menu: .modeling, symbol: "plus.square.on.square",
                       separatorBefore: true, isEnabled: inView) { s in
                s.view = .tmdl
                TMDLViewSession.of(s).addTab()
            },
            AppCommand(id: "tmdl.script", title: "Script Selected Object", menu: .modeling, symbol: "arrow.down.doc",
                       isEnabled: { inView($0) && TMDLViewSession.of($0).selectedRef != nil }) {
                TMDLViewSession.of($0).scriptSelection()
            },
            AppCommand(id: "tmdl.validate", title: "Validate Script", menu: .modeling, symbol: "checkmark.seal",
                       shortcut: .init("v", modifiers: [.option, .shift]), isEnabled: inView) {
                TMDLViewSession.of($0).validate()
            },
            AppCommand(id: "tmdl.apply", title: "Apply Script with Preview…", menu: .modeling, symbol: "arrow.up.doc",
                       shortcut: .init("a", modifiers: [.option, .shift]), isEnabled: inView) { s in
                let session = TMDLViewSession.of(s)
                guard !session.activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    s.status = StatusMessage(kind: .info, text: "The script tab is empty; script an object first.")
                    return
                }
                do {
                    // Compute the preview now so failures surface before the sheet opens.
                    _ = try session.previewApply()
                    s.present { TMDLApplySheet(session: session, isPresented: sheetBinding(s)) }
                } catch let e as TMDLError {
                    session.report(e)
                } catch {
                    session.report(TMDLError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
            },
        ]
    }

    /// A binding that closes the sheet the store is showing.
    private static func sheetBinding(_ store: DocumentStore) -> Binding<Bool> {
        Binding(get: { store.sheet != nil }, set: { shown in if !shown { store.dismissSheet() } })
    }
}
