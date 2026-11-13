import SwiftUI
import AppKit
import ObjectiveC
import FacetCore
import FacetInterop

/// Session state of the TMDL view for one document: the script tabs, the object-tree selection and
/// each tab's last error. Script text is scratch state — only applying a script touches the document, and
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
    /// The last scripting, parsing or apply error of each tab, by tab id. A tab's error is shown
    /// under the editor and underlined there only while that tab is active.
    @Published private(set) var errors: [UUID: TMDLError] = [:]
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
    /// The active tab's error.
    var error: TMDLError? { activeTab.flatMap { errors[$0.id] } }
    /// True when the active tab has something to validate or apply.
    var hasScript: Bool { !activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        errors[id] = nil
        if wasActive { activeTabID = tabs[safe: min(index, max(0, tabs.count - 1))]?.id }
    }

    func setText(_ text: String, for id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].text != text else { return }
        tabs[i].text = text
        // The error line no longer lines up once the text changes.
        if errors[id] != nil { errors[id] = nil }
    }

    // MARK: Scripting

    /// Scripts one object. Into the active tab by default (appended, blank-line separated); into a
    /// tab of its own when `inNewTab` is set or there is no tab yet.
    func script(_ ref: TMDLObjectRef, inNewTab: Bool = false) {
        guard let store = storeRef else { return }
        do {
            let text = try TMDL.script(for: ref, in: store.model, queries: store.doc.queries)
            if !inNewTab, let id = activeTab?.id, let i = tabs.firstIndex(where: { $0.id == id }) {
                let trimmed = tabs[i].text.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                tabs[i].text = trimmed.isEmpty ? text : trimmed + "\n\n" + text
                errors[id] = nil
            } else {
                addTab(name: ref.tabName, text: text)
            }
            store.status = StatusMessage(kind: .info, text: "Scripted \(ref.displayName).")
        } catch {
            fail(TMDLViewSession.tmdlError(error))
        }
    }

    /// Scripts the object selected in the tree.
    func scriptSelection() {
        guard let ref = selectedRef else {
            storeRef?.status = StatusMessage(kind: .info, text: "Select an object in the model tree first.")
            return
        }
        script(ref)
    }

    /// Replaces the active tab with a fresh script of the whole model.
    func scriptWholeModel() {
        guard let store = storeRef else { return }
        do {
            let text = try TMDL.script(for: .model, in: store.model, queries: store.doc.queries)
            if let id = activeTab?.id, let i = tabs.firstIndex(where: { $0.id == id }) {
                tabs[i].text = text
                errors[id] = nil
            } else {
                addTab(name: "Model", text: text)
            }
        } catch {
            fail(TMDLViewSession.tmdlError(error))
        }
    }

    /// Opens a first tab with the whole model's script when the view first appears.
    func ensureTabs() {
        guard tabs.isEmpty else {
            if activeTabID == nil { activeTabID = tabs.first?.id }
            return
        }
        guard let store = storeRef, TMDLViewSession.hasContent(model: store.model, queries: store.doc.queries) else { return }
        if let text = try? TMDL.script(for: .model, in: store.model, queries: store.doc.queries) {
            addTab(name: "Model", text: text)
        } else {
            addTab()
        }
    }

    // MARK: Errors

    /// Records an error against a tab (the active one by default) and shows it in the status bar.
    func report(_ e: TMDLError, tab: UUID? = nil) {
        if let id = tab ?? activeTab?.id, tabs.contains(where: { $0.id == id }) { errors[id] = e }
        storeRef?.status = StatusMessage(kind: .error, text: e.errorDescription ?? e.message)
    }

    private func fail(_ e: TMDLError) { report(e) }

    func clearError() {
        if let id = activeTab?.id { errors[id] = nil }
    }

    nonisolated static func tmdlError(_ error: Error) -> TMDLError {
        (error as? TMDLError) ?? TMDLError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Selects the error line in the editor and scrolls to it.
    func revealError() {
        guard let error, let line = error.line, let tv = TMDLViewSession.editorTextView(),
              let range = TMDLViewSession.range(ofLine: line, in: tv.string) else { return }
        let target = TMDLViewSession.clamped(range, toLength: (tv.string as NSString).length)
        tv.setSelectedRange(NSRange(location: target.location, length: 0))
        tv.scrollRangeToVisible(target)
        tv.window?.makeFirstResponder(tv)
    }

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

    /// Underlines the active tab's error line in the editor.
    var issues: [ExpressionIssue] {
        guard let error, let line = error.line, let range = TMDLViewSession.range(ofLine: line, in: activeText) else { return [] }
        return [ExpressionIssue(message: error.errorDescription ?? error.message, range: range)]
    }

    /// The UTF-16 range of a 1-based line in `text`, without its line break: empty for an empty line,
    /// nil when the text has no such line. The range never reaches past the end of the text.
    static func range(ofLine line: Int, in text: String) -> Range<Int>? {
        guard line >= 1 else { return nil }
        var location = 0
        for (i, l) in text.components(separatedBy: "\n").enumerated() {
            let length = (l as NSString).length
            if i == line - 1 { return location..<(location + length) }
            location += length + 1
        }
        return nil
    }

    /// A range cut down to a text of `length` UTF-16 units, safe to hand to a text view.
    static func clamped(_ range: Range<Int>, toLength length: Int) -> NSRange {
        let lower = min(max(range.lowerBound, 0), max(length, 0))
        let upper = min(max(range.upperBound, lower), max(length, 0))
        return NSRange(location: lower, length: upper - lower)
    }

    // MARK: Apply

    /// Parses and applies a script to a copy of the model: nothing is written. Pure, so the apply
    /// preview can run it off the main actor.
    nonisolated static func computeApply(script: String, model: SemanticModel,
                                         queries: [QueryDefinition]) -> Result<TMDLApplyResult, TMDLError> {
        do { return .success(try TMDL.apply(script: script, to: model, queries: queries)) }
        catch { return .failure(tmdlError(error)) }
    }

    /// Writes a computed apply result to the document as one undoable model edit.
    func apply(_ result: TMDLApplyResult, tab: UUID? = nil) {
        guard let store = storeRef else { return }
        store.mutate("Apply TMDL Script", invalidates: .model) { d in
            d.model = result.model
            d.queries = result.queries
        }
        if let id = tab ?? activeTab?.id { errors[id] = nil }
        store.status = StatusMessage(kind: .success, text: "Applied: \(TMDLViewSession.headline(result.summary)). You can undo this.")
    }

    /// Checks the active script without applying: problems land on the tab and in the status bar.
    func validate() {
        guard let store = storeRef, let tab = activeTab else { return }
        guard hasScript else {
            store.status = StatusMessage(kind: .info, text: "The script is empty.")
            return
        }
        switch TMDLViewSession.computeApply(script: tab.text, model: store.model, queries: store.doc.queries) {
        case .success(let result):
            errors[tab.id] = nil
            let warnings = result.warnings.filter { $0.severity != .info }
            if warnings.isEmpty {
                store.status = StatusMessage(kind: .success, text: "No problems found: \(TMDLViewSession.headline(result.summary)).")
            } else {
                store.status = StatusMessage(kind: .warning, text: warnings.map(\.description).joined(separator: "\n"))
            }
        case .failure(let e):
            report(e, tab: tab.id)
        }
    }

    /// "2 added, 1 changed, 0 removed".
    static func headline(_ summary: TMDLChangeSummary) -> String {
        "\(summary.added.count) added, \(summary.changed.count) changed, \(summary.removed.count) removed"
    }

    // MARK: What the view shows

    static func hasObjects(_ model: SemanticModel) -> Bool {
        !model.tables.isEmpty || !model.calculationGroups.isEmpty || !model.relationships.isEmpty
            || !model.roles.isEmpty || !model.perspectives.isEmpty || !model.translations.isEmpty
            || !model.functions.isEmpty
    }

    /// True when there is anything to script: the workspace shows its editor and tree exactly then,
    /// and the `tmdl.*` commands are enabled on the same condition.
    static func hasContent(model: SemanticModel, queries: [QueryDefinition]) -> Bool {
        hasObjects(model) || !queries.isEmpty
    }

    /// The object a Data-pane context-menu command points at, as a TMDL object.
    static func ref(table: String?, field: FieldRef?) -> TMDLObjectRef? {
        if let f = field {
            return f.kind == .measure ? .measure(table: f.table, name: f.name) : .column(table: f.table, name: f.name)
        }
        return table.map { .table($0) }
    }
}
