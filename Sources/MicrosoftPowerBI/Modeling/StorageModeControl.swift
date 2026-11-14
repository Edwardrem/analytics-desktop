import SwiftUI
import FacetCore
import FacetQuery
import FacetDesign

/// A table's storage mode: Import, DirectQuery or Dual, where the table's source allows.
enum StorageModeLogic {
    enum Support: Equatable {
        /// The source runs the table's whole query, so DirectQuery and Dual are possible.
        case directQuery
        /// Only Import, and why.
        case importOnly(String)
    }

    static let choices: [StorageMode] = [.import, .directQuery, .dual]

    /// Why a table can only be imported, when that is known without asking its source.
    static func knownReason(_ t: ModelTable, queries: [QueryDefinition]) -> String? {
        if t.storageMode == .directLake || t.storageMode == .live {
            return "\(ModelGlyph.label(for: t.storageMode)) tables belong to a model in the Power BI service and can't be changed here."
        }
        if t.isCalculated { return "Calculated tables are computed by the model, so they are always imported." }
        guard let q = t.sourceQuery, queries.contains(where: { $0.name == q }) else {
            return "\(t.name) isn't loaded by a Power Query query, so there's no source to query directly. It can only be imported."
        }
        return nil
    }

    /// Whether the table's source can answer its query itself. Here only SQLite databases can, and only
    /// when every step of the query folds into SQL.
    static func support(_ t: ModelTable, queries: [QueryDefinition], baseDirectory: URL?) async -> Support {
        if let reason = knownReason(t, queries: queries) { return .importOnly(reason) }
        guard let q = t.sourceQuery else { return .importOnly("\(t.name) has no source query.") }
        let engine = QueryEngine(queries: queries, environment: .app(baseDirectory: baseDirectory))
        do {
            if try await engine.nativeQuery(for: q) != nil { return .directQuery }
        } catch {
            return .importOnly("The source of “\(q)” couldn't be reached to check it: \(error.localizedDescription)")
        }
        if let local = ((try? await engine.stepFolding(for: q)) ?? []).first(where: { $0.indicator == .notFolded }) {
            return .importOnly("DirectQuery needs the source to run every step of “\(q)”. Step “\(local.step)” runs on this Mac, so the table can only be imported.")
        }
        return .importOnly("DirectQuery needs a source that runs queries itself: a SQLite database, with a query that folds completely. “\(q)” doesn't read one.")
    }

    /// Changes the mode. DirectQuery drops the imported rows (they are read from the source from then on);
    /// leaving DirectQuery imports the table again, as Power BI does.
    @MainActor static func set(_ mode: StorageMode, table: String, store: DocumentStore) {
        guard let t = store.model.table(table), t.storageMode != mode, choices.contains(mode) else { return }
        let wasDirect = t.storageMode == .directQuery
        store.mutate("Storage Mode", invalidates: .model) { d in
            guard let i = d.model.tableIndex(table) else { return }
            d.model.tables[i].storageMode = mode
            if mode == .directQuery { d.data[d.model.tables[i].name] = nil }
        }
        if wasDirect, let q = t.sourceQuery { store.refreshData(only: [q]) }
    }

    static func note(for mode: StorageMode) -> String {
        switch mode {
        case .directQuery:
            return "Rows are read from the source when visuals are queried (up to \(DirectQuerySession.rowLimit.formatted()) per table) and aren't saved in the file. Refresh reads them again."
        case .dual:
            return "Imported and saved like Import, and marked as able to query its source when published. Here, queries use the imported rows."
        default:
            return ""
        }
    }
}

/// The Storage mode row of a table's properties.
struct StorageModeControl: View {
    @EnvironmentObject private var store: DocumentStore
    let table: ModelTable
    @State private var support: StorageModeLogic.Support?

    private var reason: String? {
        if case .importOnly(let r)? = support { return r }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                ForEach(StorageModeLogic.choices, id: \.self) { mode in
                    Button { StorageModeLogic.set(mode, table: table.name, store: store) } label: {
                        if mode == table.storageMode { Label(ModelGlyph.label(for: mode), systemImage: "checkmark") } else { Text(ModelGlyph.label(for: mode)) }
                    }
                    .disabled(mode != .import && support != .directQuery)
                }
            } label: {
                Text(ModelGlyph.label(for: table.storageMode)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!StorageModeLogic.choices.contains(table.storageMode))
            .help(reason ?? "How this table's rows reach the model")
            Group {
                if support == nil { Text("Checking whether the source supports DirectQuery…") }
                else if let reason, table.storageMode == .import { Text(reason) }
                else if !StorageModeLogic.note(for: table.storageMode).isEmpty { Text(StorageModeLogic.note(for: table.storageMode)) }
            }
            .font(Design.Typeface.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: checkKey) {
            support = nil
            let t = table, queries = store.doc.queries, base = store.fileURL?.deletingLastPathComponent()
            let result = await StorageModeLogic.support(t, queries: queries, baseDirectory: base)
            if !Task.isCancelled { support = result }
        }
    }

    /// Checked again when the table or its query changes.
    private var checkKey: String {
        table.name + "\u{1F}" + (table.sourceQuery ?? "") + "\u{1F}" + (table.sourceQuery.flatMap { q in store.doc.queries.first { $0.name == q }?.mScript } ?? "")
    }
}
