import SwiftUI
import FacetCore

/// Optional assistant integration for the DAX query view. The Explain, Ask and Fix buttons only appear
/// once the corresponding hook is set.
enum DAXAssistantHook {
    /// Explains a query in plain language.
    @MainActor static var explain: ((String, DocumentStore) async throws -> String)?
    /// Writes a DAX query for a natural-language prompt.
    @MainActor static var write: ((String, DocumentStore) async throws -> String)?
    /// Proposes a corrected query for a query that failed, given the query and its error.
    @MainActor static var fix: ((String, String, DocumentStore) async throws -> String)?
}

/// What a quick-query command should act on. Other panes set these just before running a
/// `dax.quick.*` command; the command clears them. Without a context, the commands use the item
/// selected in the query view's Model list.
@MainActor
enum DAXQueryContext {
    static var table: String?
    static var field: FieldRef?

    /// Takes and clears the context, falling back to the Model list selection.
    static func take(_ store: DocumentStore) -> DAXModelItem? {
        defer { table = nil; field = nil }
        if let f = field {
            return f.kind == .measure ? .measure(table: f.table, name: f.name) : .column(table: f.table, name: f.name)
        }
        if let t = table { return .table(t) }
        return DAXQuerySession.of(store).selectedItem
    }
}

/// Ready-made queries. Each switches to the DAX query view, opens a new tab and runs it.
@MainActor
enum DAXQuickQuery {
    private static func open(_ query: String, name: String, _ store: DocumentStore) {
        store.view = .dax
        DAXQuerySession.of(store).addTab(name: name, text: query, run: true)
    }
    private static func missing(_ what: String, _ store: DocumentStore) {
        store.view = .dax
        store.status = StatusMessage(kind: .info, text: "Select \(what) in the Model list first.")
    }

    static func topRows(_ table: String, _ store: DocumentStore) {
        open(DAXQueryBuilder.topRows(table), name: "\(table) top 100", store)
    }
    static func preview(_ table: String, _ store: DocumentStore) {
        open(DAXQueryBuilder.preview(table), name: "\(table) preview", store)
    }
    static func tableStatistics(_ table: String, _ store: DocumentStore) {
        guard let t = store.model.table(table) else { return }
        open(DAXQueryBuilder.tableStatistics(t), name: "\(t.name) statistics", store)
    }
    static func distinctValues(_ table: String, _ column: String, _ store: DocumentStore) {
        open(DAXQueryBuilder.distinctValues(table: table, column: column), name: "\(column) values", store)
    }
    static func columnStatistics(_ table: String, _ column: String, _ store: DocumentStore) {
        guard let c = store.model.table(table)?.column(column) else { return }
        open(DAXQueryBuilder.columnStatistics(table: table, column: c), name: "\(c.name) statistics", store)
    }
    static func evaluate(_ measure: String, _ store: DocumentStore) {
        open(DAXQueryBuilder.evaluate(measures: [measure]), name: measure, store)
    }
    static func define(_ measure: String, _ store: DocumentStore) {
        guard let hit = store.model.measure(measure) else { return }
        open(DAXQueryBuilder.defineAndEvaluate(table: hit.table.name, measure: hit.measure), name: hit.measure.name, store)
    }
    static func defineWithReferences(_ measure: String, _ store: DocumentStore) {
        guard let hit = store.model.measure(measure) else { return }
        open(DAXQueryBuilder.defineWithReferences(table: hit.table.name, measure: hit.measure, model: store.model), name: hit.measure.name, store)
    }
    static func defineAll(_ store: DocumentStore) {
        guard !store.model.allMeasures.isEmpty else {
            store.view = .dax
            store.status = StatusMessage(kind: .info, text: "This model has no measures yet.")
            return
        }
        open(DAXQueryBuilder.defineAll(model: store.model), name: "All measures", store)
    }

    // Command entry points: act on the context, or the Model list selection.
    static func topRowsCommand(_ store: DocumentStore) {
        guard let item = DAXQueryContext.take(store) else { return missing("a table", store) }
        topRows(item.table, store)
    }
    static func columnStatisticsCommand(_ store: DocumentStore) {
        switch DAXQueryContext.take(store) {
        case .column(let t, let c): columnStatistics(t, c, store)
        case .table(let t), .measure(let t, _): tableStatistics(t, store)
        case nil: missing("a table or column", store)
        }
    }
    static func measureCommand(_ store: DocumentStore, withReferences: Bool) {
        guard case .measure(_, let name) = DAXQueryContext.take(store) else { return missing("a measure", store) }
        if withReferences { defineWithReferences(name, store) } else { define(name, store) }
    }
}

/// DAX query view.
@MainActor
enum DAXQueryFeature {
    static func register() {
        Features.workspaceBuilders[.dax] = { store in AnyView(DAXQueryView(session: DAXQuerySession.of(store))) }
        AppCommands.register(commands)
    }

    static func commands() -> [AppCommand] {
        let inView: @MainActor (DocumentStore) -> Bool = { $0.view == .dax && !$0.model.tables.isEmpty }
        let hasModel: @MainActor (DocumentStore) -> Bool = { !$0.model.tables.isEmpty }
        return [
            AppCommand(id: "dax.run", title: "Run Query", menu: .modeling, symbol: "play", shortcut: .init(.return),
                       separatorBefore: true, isEnabled: inView) { DAXQuerySession.of($0).run() },
            AppCommand(id: "dax.newTab", title: "New Query Tab", menu: .modeling, symbol: "plus.square.on.square", isEnabled: hasModel) { s in
                s.view = .dax
                DAXQuerySession.of(s).addTab()
            },
            AppCommand(id: "dax.format", title: "Format Query", menu: .modeling, symbol: "text.alignleft",
                       shortcut: .init("f", modifiers: [.option, .shift]), isEnabled: inView) { DAXQuerySession.of($0).formatQuery() },
            AppCommand(id: "dax.quick.top100", title: "Show Top 100 Rows", menu: .modeling, separatorBefore: true, isEnabled: hasModel) {
                DAXQuickQuery.topRowsCommand($0)
            },
            AppCommand(id: "dax.quick.columnStats", title: "Show Column Statistics", menu: .modeling, isEnabled: hasModel) {
                DAXQuickQuery.columnStatisticsCommand($0)
            },
            AppCommand(id: "dax.quick.defineMeasure", title: "Define and Evaluate Measure", menu: .modeling, isEnabled: hasModel) {
                DAXQuickQuery.measureCommand($0, withReferences: false)
            },
            AppCommand(id: "dax.quick.defineWithReferences", title: "Define Measure with References and Evaluate", menu: .modeling, isEnabled: hasModel) {
                DAXQuickQuery.measureCommand($0, withReferences: true)
            },
            AppCommand(id: "dax.quick.defineAll", title: "Define All Measures in This Model", menu: .modeling, isEnabled: hasModel) {
                DAXQuickQuery.defineAll($0)
            },
            AppCommand(id: "dax.updateModel", title: "Update Model with Changes", menu: .modeling, symbol: "arrow.up.doc", separatorBefore: true,
                       isEnabled: { $0.view == .dax && !DAXQuerySession.of($0).pendingChanges.isEmpty }) { s in
                let session = DAXQuerySession.of(s)
                let changes = session.pendingChanges
                guard !changes.isEmpty else { return }
                s.present { DAXUpdateModelSheet(session: session, changes: changes) }
            },
            AppCommand(id: "dax.export", title: "Export Query Results…", menu: .modeling, symbol: "square.and.arrow.up",
                       isEnabled: { $0.view == .dax && DAXQuerySession.of($0).activeResult != nil }) { DAXQuerySession.of($0).exportResults() },
        ]
    }
}
