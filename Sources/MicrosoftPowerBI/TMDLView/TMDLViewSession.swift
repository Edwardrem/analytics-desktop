import SwiftUI
import AppKit
import ObjectiveC
import FacetCore
import FacetInterop

/// Session state of the TMDL view for one document: the script tabs, the object-tree selection and
/// the last error. Script text is scratch state — only applying a script touches the document, and
/// that goes through `DocumentStore.mutate` so it is one undo step.
@MainActor
final class TMDLViewSession: ObservableObject {
    struct ScriptTab: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var text: String
    }

    private weak var storeRef: DocumentStore?
    @Published var tabs: [ScriptTab] = []
    @Published var activeTabID: UUID?
    /// The object selected in the tree; the Script command acts on it.
    @Published var selectedRef: TMDLObjectRef?
    /// The last scripting, parsing or apply error, shown under the editor and underlined there.
    @Published private(set) var error: TMDLError?
    /// Highlight for the editor while a tree row is dragged over it.
    @Published var dropTargeted = false

    private init(store: DocumentStore) { storeRef = store }

    private static var key: UInt8 = 0
    /// The session belonging to a document; created on first use and released with the store.
    static func of(_ store: DocumentStore) -> TMDLViewSession {
        if let s = objc_getAssociatedObject(store, &key) as? TMDLViewSession { return s }
        let s = TMDLViewSession(store: store)
        objc_setAssociatedObject(store, &key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    // MARK: Tabs

    var activeTab: ScriptTab? { tabs.first { $0.id == activeTabID } ?? tabs.first }
    var activeText: String { activeTab?.text ?? "" }

    @discardableResult
    func addTab(name: String? = nil, text: String = "") -> UUID? {
        let names = Set(tabs.map(\.name))
        var n = tabs.count + 1
        while names.contains("Script \(n)") { n += 1 }
        let tab = ScriptTab(name: name ?? "Script \(n)", text: text)
        tabs.append(tab)
        activeTabID = tab.id
        return tab.id
    }

    func setActive(_ id: UUID) { activeTabID = id }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].name != trimmed else { return }
        tabs[i].name = trimmed
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTab?.id == id
        tabs.remove(at: index)
        if wasActive { activeTabID = tabs[safe: min(index, max(0, tabs.count - 1))]?.id }
    }

    func setText(_ text: String, for id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].text != text else { return }
        tabs[i].text = text
        // The error line no longer lines up once the text changes.
        if error != nil { error = nil }
    }

    // MARK: Scripting

    /// Scripts one object into the active tab (or a new one): appends its TMDL, blank-line separated.
    func script(_ ref: TMDLObjectRef) {
        guard let store = storeRef else { return }
        do {
            let text = try TMDL.script(for: ref, in: store.model, queries: store.doc.queries)
            error = nil
            if let id = activeTab?.id, let i = tabs.firstIndex(where: { $0.id == id }) {
                let trimmed = tabs[i].text.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                tabs[i].text = trimmed.isEmpty ? text : trimmed + "\n\n" + text
            } else {
                addTab(name: TMDLViewSession.tabName(for: ref), text: text)
            }
            store.status = StatusMessage(kind: .info, text: "Scripted \(TMDLViewSession.objectName(ref)).")
        } catch let e as TMDLError {
            fail(e)
        } catch {
            fail(TMDLError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// Scripts the object selected in the tree, or one another pane set in `TMDLScriptingContext`.
    func scriptSelection() {
        guard let ref = selectedRef ?? TMDLScriptingContext.take(storeRef) else {
            storeRef?.status = StatusMessage(kind: .info, text: "Select an object in the tree first.")
            return
        }
        script(ref)
    }

    /// Replaces the active tab with a fresh script of the whole model.
    func scriptWholeModel() {
        guard let store = storeRef else { return }
        do {
            let text = try TMDL.script(for: .model, in: store.model, queries: store.doc.queries)
            error = nil
            if let id = activeTab?.id, let i = tabs.firstIndex(where: { $0.id == id }) {
                tabs[i].text = text
            } else {
                addTab(name: "Model", text: text)
            }
        } catch let e as TMDLError {
            fail(e)
        } catch {
            fail(TMDLError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// Loads the sample model script when the view first appears.
    func ensureTabs() {
        guard tabs.isEmpty else {
            if activeTabID == nil { activeTabID = tabs.first?.id }
            return
        }
        guard let store = storeRef, TMDLViewSession.hasObjects(store.model) else { return }
        if let text = try? TMDL.script(for: .model, in: store.model, queries: store.doc.queries) {
            addTab(name: "Model", text: text)
        } else {
            addTab()
        }
    }

    // MARK: Errors

    private func fail(_ e: TMDLError) {
        error = e
        storeRef?.status = StatusMessage(kind: .error, text: e.errorDescription ?? e.message)
    }

    /// Shows an error under the editor and in the status bar.
    func report(_ e: TMDLError) {
        fail(e)
    }

    /// Selects the error line in the editor and scrolls to it.
    func revealError() {
        guard let error, let line = error.line,
              let range = TMDLViewSession.range(ofLine: line, in: activeText) else { return }
        guard let tv = TMDLViewSession.editorTextView() else { return }
        tv.setSelectedRange(NSRange(location: range.lowerBound, length: 0))
        tv.scrollRangeToVisible(NSRange(location: range.lowerBound, length: range.count))
        tv.window?.makeFirstResponder(tv)
    }

    func clearError() { error = nil }

    /// The TMDL editor's text view, by its accessibility label.
    static func editorTextView() -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, tv.accessibilityLabel() == "TMDL editor" { return tv }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.accessibilityLabel() == "TMDL editor" { return tv }
        guard let content = NSApp.keyWindow?.contentView else { return nil }
        return find(content)
    }

    /// Underlines the error line in the editor.
    var issues: [ExpressionIssue] {
        guard let error, let line = error.line, let range = TMDLViewSession.range(ofLine: line, in: activeText) else { return [] }
        return [ExpressionIssue(message: error.errorDescription ?? error.message, range: range)]
    }

    /// The character range of a 1-based line in `text`, so errors can be underlined.
    static func range(ofLine line: Int, in text: String) -> Range<Int>? {
        guard line >= 1 else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard line <= lines.count else { return nil }
        var location = 0
        for (i, l) in lines.enumerated() {
            if i == line - 1 { return location..<(location + max((l as NSString).length, 1)) }
            location += (l as NSString).length + 1
        }
        return nil
    }

    // MARK: Apply

    /// Parses and applies the script in memory (nothing is written), for the preview sheet.
    func previewApply() throws -> TMDLApplyResult {
        guard let store = storeRef, let text = activeTab?.text else { throw TMDLError("There is no script to apply.") }
        return try TMDL.apply(script: text, to: store.model, queries: store.doc.queries)
    }

    /// Writes a computed apply result to the document as one undoable model edit.
    func apply(_ result: TMDLApplyResult) {
        guard let store = storeRef else { return }
        let s = result.summary
        store.mutate("Apply TMDL Script", invalidates: .model) { d in
            d.model = result.model
            d.queries = result.queries
        }
        error = nil
        store.status = StatusMessage(kind: .success, text: "Applied: \(s.text.split(separator: "\n").first ?? ""). You can undo this.")
    }

    /// Checks the script without applying: syntax and semantic problems land in `error` and the status.
    func validate() {
        guard let store = storeRef, activeTab?.text != nil else { return }
        let text = activeText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.status = StatusMessage(kind: .info, text: "The script is empty.")
            return
        }
        do {
            let result = try TMDL.apply(script: text, to: store.model, queries: store.doc.queries)
            error = nil
            let s = result.summary
            let warnings = result.warnings.filter { $0.severity != .info }
            if warnings.isEmpty {
                store.status = StatusMessage(kind: .success, text: "No problems found: \(s.text.split(separator: "\n").first ?? "").")
            } else {
                store.status = StatusMessage(kind: .warning, text: warnings.map(\.description).joined(separator: "\n"))
            }
        } catch let e as TMDLError {
            fail(e)
        } catch {
            fail(TMDLError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    // MARK: Labels

    static func hasObjects(_ model: SemanticModel) -> Bool {
        !model.tables.isEmpty || !model.calculationGroups.isEmpty || !model.relationships.isEmpty
            || !model.roles.isEmpty || !model.perspectives.isEmpty || !model.translations.isEmpty
            || !model.functions.isEmpty
    }

    static func objectName(_ ref: TMDLObjectRef) -> String {
        switch ref {
        case .model: return "the model"
        case .modelProperties: return "model properties"
        case .table(let t): return "table \(t)"
        case .column(let t, let c): return "column \(t)[\(c)]"
        case .measure(let t, let m): return "measure \(t)[\(m)]"
        case .hierarchy(let t, let h): return "hierarchy \(t)[\(h)]"
        case .calculationGroup(let g): return "calculation group \(g)"
        case .relationship(let id): return "relationship \(id.uuidString.prefix(8))"
        case .relationships: return "relationships"
        case .role(let r): return "role \(r)"
        case .perspective(let p): return "perspective \(p)"
        case .culture(let c): return "culture \(c)"
        case .function(let f): return "function \(f)"
        case .expression(let e): return "expression \(e)"
        }
    }

    static func tabName(for ref: TMDLObjectRef) -> String {
        switch ref {
        case .model, .modelProperties: return "Model"
        case .table(let t), .calculationGroup(let t): return t
        case .column(let t, _), .measure(let t, _), .hierarchy(let t, _): return t
        case .relationship, .relationships: return "Relationships"
        case .role(let r), .perspective(let r), .culture(let r), .function(let r), .expression(let r): return r
        }
    }
}

/// What a scripting command should act on. Other panes set these just before running `tmdl.script`;
/// the command clears them. Without a context, the command uses the tree selection.
@MainActor
enum TMDLScriptingContext {
    static var table: String?
    static var field: FieldRef?

    /// Takes and clears the context, falling back to the tree selection.
    static func take(_ store: DocumentStore?) -> TMDLObjectRef? {
        defer { table = nil; field = nil }
        if let f = field {
            return f.kind == .measure ? .measure(table: f.table, name: f.name) : .column(table: f.table, name: f.name)
        }
        if let t = table { return .table(t) }
        return store.flatMap { TMDLViewSession.of($0).selectedRef }
    }
}
