import SwiftUI
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import FacetCore

/// The outcome of the latest run of one query tab.
struct DAXRunState {
    var results: [DAXResultModel] = []
    var selectedResult = 0
    var error: String?
    var issues: [ExpressionIssue] = []
    var elapsedMilliseconds: Double?
    var isRunning = false
    var hasRun = false
    /// The text that failed and where it starts in the tab (a selection may have run); nil after a success.
    var failedText: String?
    var failedOffset = 0
    /// Identifies the run in flight; a result for any other token is stale and ignored.
    var token: UUID?
}

struct DAXHistoryEntry: Identifiable {
    var id = UUID()
    var date = Date()
    var milliseconds: Double
    /// Total rows returned; nil when the run failed.
    var rows: Int?
    var text: String
}

/// An item selected in the side panel's model tree; quick-query commands fall back to it.
enum DAXModelItem: Hashable {
    case table(String)
    case column(table: String, name: String)
    case measure(table: String, name: String)
    var table: String {
        switch self { case .table(let t): return t; case .column(let t, _): return t; case .measure(let t, _): return t }
    }
}

/// Session state of the DAX query view for one document: the active tab, run results and history.
/// Query text and tabs live in the document (`report.daxQueries`); nothing here is saved.
@MainActor
final class DAXQuerySession: ObservableObject {
    private weak var storeRef: DocumentStore?
    @Published var activeTabID: UUID? { didSet { if oldValue != activeTabID { cachedTextView = nil } } }
    @Published private(set) var runs: [UUID: DAXRunState] = [:]
    @Published private(set) var history: [DAXHistoryEntry] = []
    @Published var selectedItem: DAXModelItem?

    /// A view placed behind the editor; the editor's text view is found relative to it.
    weak var editorAnchor: NSView?
    private weak var cachedTextView: NSTextView?

    private init(store: DocumentStore) { storeRef = store }

    private static var key: UInt8 = 0
    /// The session belonging to a document; created on first use and released with the store.
    static func of(_ store: DocumentStore) -> DAXQuerySession {
        if let s = objc_getAssociatedObject(store, &key) as? DAXQuerySession { return s }
        let s = DAXQuerySession(store: store)
        objc_setAssociatedObject(store, &key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    // MARK: Tabs

    var tabs: [DAXQueryTab] { storeRef?.report.daxQueries ?? [] }
    var activeTab: DAXQueryTab? { tabs.first { $0.id == activeTabID } ?? tabs.first }
    var activeRun: DAXRunState { activeTab.flatMap { runs[$0.id] } ?? DAXRunState() }

    private func uniqueName(_ base: String = "Query") -> String {
        let names = Set(tabs.map(\.name))
        var n = tabs.count + 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Adds a tab after the active one and makes it active.
    @discardableResult
    func addTab(name: String? = nil, text: String = "EVALUATE\n    ", run: Bool = false) -> UUID? {
        guard let store = storeRef else { return nil }
        let tab = DAXQueryTab(name: name ?? uniqueName(), text: text)
        let after = activeTab?.id
        store.mutate("New Query Tab", invalidates: .layout) { d in
            if let i = d.report.daxQueries.firstIndex(where: { $0.id == after }) { d.report.daxQueries.insert(tab, at: i + 1) }
            else { d.report.daxQueries.append(tab) }
        }
        activeTabID = tab.id
        if run { self.run(useSelection: false) }
        return tab.id
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tab = tabs.first(where: { $0.id == id }), tab.name != trimmed else { return }
        storeRef?.mutate("Rename Query", invalidates: .layout) { d in
            if let i = d.report.daxQueries.firstIndex(where: { $0.id == id }) { d.report.daxQueries[i].name = trimmed }
        }
    }

    func duplicate(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        addTab(name: tab.name + " copy", text: tab.text)
    }

    func close(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTab?.id == id
        storeRef?.mutate("Close Query Tab", invalidates: .layout) { d in d.report.daxQueries.removeAll { $0.id == id } }
        runs[id] = nil
        if wasActive { activeTabID = tabs[safe: min(index, tabs.count - 1)]?.id }
    }

    /// Moves a tab so it sits where `target` is.
    func move(_ id: UUID, onto target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        storeRef?.mutate("Reorder Query Tabs", invalidates: .layout) { d in
            let tab = d.report.daxQueries.remove(at: from)
            d.report.daxQueries.insert(tab, at: to)
        }
    }

    /// Writes edited query text back to the document; typing coalesces into one undo step.
    func setText(_ text: String, for id: UUID) {
        guard let store = storeRef, let tab = tabs.first(where: { $0.id == id }), tab.text != text else { return }
        store.mutate("Edit Query", coalesce: "dax-\(id.uuidString)", invalidates: .layout) { d in
            if let i = d.report.daxQueries.firstIndex(where: { $0.id == id }) { d.report.daxQueries[i].text = text }
        }
        // Issue ranges no longer line up once the text changes.
        if let run = runs[id], !run.issues.isEmpty { runs[id]?.issues = [] }
    }

    // MARK: Editor access

    /// The active editor's text view: the nearest DAX editor around the anchor, else the focused text view.
    var editorTextView: NSTextView? {
        if let tv = cachedTextView, tv.window != nil { return tv }
        func find(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, tv.accessibilityLabel() == "DAX editor" { return tv }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        var node = editorAnchor?.superview
        var hops = 0
        while let n = node, hops < 6 {
            if let tv = find(n) { cachedTextView = tv; return tv }
            node = n.superview; hops += 1
        }
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.accessibilityLabel() == "DAX editor" { return tv }
        return nil
    }

    func focusEditor() {
        guard let tv = editorTextView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Inserts text at the cursor (replacing the selection), or appends when the editor isn't on screen.
    func insert(_ text: String) {
        guard let tab = activeTab else { return }
        if let tv = editorTextView, tv.string == tab.text {
            tv.insertText(text, replacementRange: tv.selectedRange())
            tv.window?.makeFirstResponder(tv)
        } else {
            setText(tab.text + text, for: tab.id)
        }
    }

    /// Replaces a range of the active query through the text view (so editor undo keeps working) when possible.
    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard let tab = activeTab else { return }
        if let tv = editorTextView, tv.string == tab.text {
            tv.insertText(text, replacementRange: range)
            if let select { tv.setSelectedRange(select) }
        } else {
            setText((tab.text as NSString).replacingCharacters(in: range, with: text), for: tab.id)
        }
    }

    /// Puts an accepted fix in place of the text that failed and runs it. False, and nothing changes, when
    /// that tab is no longer active or its text there was edited since the run.
    @discardableResult
    func applyFix(_ query: String, tab id: UUID, original: String, offset: Int) -> Bool {
        guard let tab = activeTab, tab.id == id, offset >= 0 else { return false }
        let text = tab.text as NSString
        let range = NSRange(location: offset, length: (original as NSString).length)
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == original else { return false }
        replace(range, with: query, select: NSRange(location: offset, length: (query as NSString).length))
        run(useSelection: true)
        return true
    }

    func formatQuery() {
        guard let tab = activeTab else { return }
        let formatted = LanguageSupport.dax.format(tab.text)
        guard formatted != tab.text else { return }
        replace(NSRange(location: 0, length: (tab.text as NSString).length), with: formatted)
    }

    func toggleComment() {
        guard let tab = activeTab else { return }
        let selection = editorTextView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let edit = DAXText.toggleComment(in: tab.text, range: selection)
        replace(edit.range, with: edit.replacement,
                select: NSRange(location: edit.range.location, length: (edit.replacement as NSString).length))
    }

    /// Puts a ready-made query in the active tab when it is still empty, otherwise in a new tab.
    func place(_ query: String, name: String? = nil, run: Bool = false) {
        if let tab = activeTab {
            let current = tab.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || current.uppercased() == "EVALUATE" {
                replace(NSRange(location: 0, length: (tab.text as NSString).length), with: query)
                if run { self.run(useSelection: false) }
                return
            }
        }
        addTab(name: name, text: query, run: run)
    }

    // MARK: Running

    /// Runs the selected text when there is a selection, otherwise the whole query.
    func run(useSelection: Bool = true) {
        guard let store = storeRef, let tab = activeTab else { return }
        var text = tab.text
        var offset = 0
        if useSelection, let tv = editorTextView, tv.string == tab.text {
            let r = tv.selectedRange()
            if r.length > 0, !(tv.string as NSString).substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = (tv.string as NSString).substring(with: r); offset = r.location
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = tab.id
        let token = UUID()
        var state = runs[id] ?? DAXRunState()
        state.isRunning = true; state.token = token
        runs[id] = state
        let model = store.model
        Task { [weak self] in
            let outcome: (result: Result<[DataTable], Error>, issues: [ExpressionIssue], ms: Double) = await store.withEngine { engine in
                let start = DispatchTime.now().uptimeNanoseconds
                func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
                do {
                    let tables = try engine.query(text)
                    return (.success(tables), [], elapsed())
                } catch {
                    let ms = elapsed()
                    return (.failure(error), engine.check(text, kind: .query, homeTable: nil), ms)
                }
            }
            guard let self, self.runs[id]?.token == token else { return }
            var state = self.runs[id] ?? DAXRunState()
            state.isRunning = false; state.token = nil; state.hasRun = true
            state.elapsedMilliseconds = outcome.ms
            switch outcome.result {
            case .success(let tables):
                state.results = tables.map { DAXResultModel(table: $0, model: model) }
                state.selectedResult = 0
                state.error = nil; state.issues = []; state.failedText = nil; state.failedOffset = 0
                self.record(DAXHistoryEntry(milliseconds: outcome.ms, rows: tables.reduce(0) { $0 + $1.rowCount }, text: text))
            case .failure(let error):
                state.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                state.failedText = text; state.failedOffset = offset
                // Ranges are relative to what ran; shift them when only a selection ran.
                state.issues = outcome.issues.map { issue in
                    var i = issue
                    if let r = i.range { i.range = (r.lowerBound + offset)..<(r.upperBound + offset) }
                    return i
                }
                self.record(DAXHistoryEntry(milliseconds: outcome.ms, rows: nil, text: text))
            }
            self.runs[id] = state
        }
    }

    /// Best-effort cancel: the engine call can't be interrupted, so its result is discarded when it arrives.
    func cancel() {
        guard let id = activeTab?.id, runs[id]?.isRunning == true else { return }
        runs[id]?.isRunning = false
        runs[id]?.token = nil
    }

    func selectResult(_ index: Int) {
        guard let id = activeTab?.id, let run = runs[id], run.results.indices.contains(index) else { return }
        runs[id]?.selectedResult = index
    }

    private func record(_ entry: DAXHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
    }

    /// Selects the first located issue in the editor and scrolls to it.
    func revealFirstIssue() {
        guard let range = activeRun.issues.compactMap(\.range).min(by: { $0.lowerBound < $1.lowerBound }),
              let tv = editorTextView else { return }
        let length = (tv.string as NSString).length
        let location = min(range.lowerBound, length)
        let ns = NSRange(location: location, length: min(max(range.count, 0), length - location))
        tv.setSelectedRange(ns)
        tv.scrollRangeToVisible(ns)
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: Model updates

    var pendingChanges: [DAXModelChange] {
        guard let store = storeRef, let tab = activeTab else { return [] }
        return DAXModelUpdater.changes(in: tab.text, model: store.model)
    }

    /// Moves the cursor to a definition in the editor.
    func reveal(_ definition: DAXDefinition) {
        guard let tv = editorTextView else { return }
        let length = (tv.string as NSString).length
        let ns = NSRange(location: min(definition.range.lowerBound, length), length: 0)
        tv.setSelectedRange(ns)
        tv.scrollRangeToVisible(ns)
        tv.window?.makeFirstResponder(tv)
    }

    /// Applies the changes as one undoable model edit.
    func apply(_ changes: [DAXModelChange]) {
        guard let store = storeRef, !changes.isEmpty else { return }
        store.updateModel(changes.count == 1 ? "Update Model from Query" : "Update Model with \(changes.count) Changes") { model in
            DAXModelUpdater.apply(changes, to: &model)
        }
        let added = changes.filter(\.isAddition).count, updated = changes.count - added
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if updated > 0 { parts.append("\(updated) updated") }
        store.status = StatusMessage(kind: .success, text: "Model updated: \(parts.joined(separator: ", ")).")
    }

    // MARK: Results

    var activeResult: DAXResultModel? {
        let run = activeRun
        return run.results[safe: run.selectedResult]
    }

    func copyAll(headers: Bool = true) {
        guard let result = activeResult else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(result.tsv(headers: headers), forType: .string)
        storeRef?.status = StatusMessage(kind: .success, text: "Copied \(result.rowCount.formatted()) rows.")
    }

    /// Saves the displayed result as UTF-8 CSV.
    func exportResults() {
        guard let store = storeRef, let result = activeResult else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = (activeTab?.name ?? "Query") + ".csv"
        panel.canCreateDirectories = true
        panel.message = result.isFiltered ? "Exports the \(result.rowCount.formatted()) rows currently shown." : ""
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(result.csv().utf8).write(to: url, options: .atomic)
            store.status = StatusMessage(kind: .success, text: "Exported \(result.rowCount.formatted()) rows to \(url.lastPathComponent).")
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't export the results: \(error.localizedDescription)")
        }
    }
}
