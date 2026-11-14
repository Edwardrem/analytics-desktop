import SwiftUI
import FacetCore
import FacetQuery

extension QueryPreview {
    /// The preview with columns the M type leaves untyped (`any`) marked `.any`, so "Detect data type" types them
    /// even when their values already are numbers or dates (as Excel cells are).
    var untypedTable: DataTable {
        var t = table
        for i in t.columns.indices where columnTypes[safe: i]?.dataType == .any { t.columns[i].type = .any }
        return t
    }
}

/// Which query the Power Query Editor should select when it opens for a document (set by Get Data ▸ Transform Data).
@MainActor
enum QueryEditorRouting {
    private static var pending: [ObjectIdentifier: String] = [:]
    static func select(_ query: String, in store: DocumentStore) { pending[ObjectIdentifier(store)] = query }
    static func takeSelection(for store: DocumentStore) -> String? { pending.removeValue(forKey: ObjectIdentifier(store)) }
}

/// One Get Data run: connector → connection details → (native query approval) → navigator → load or transform.
@MainActor
final class GetDataSession: ObservableObject {
    enum Stage: Equatable { case catalog, form, approval, navigator }
    enum Destination { case load, transform }

    let store: DocumentStore
    @Published var stage: Stage = .catalog
    @Published var connector: DataConnector?
    @Published var request = SourceRequest(kind: .csv)
    /// The SQL Server sign-in typed into the form (saved to the Keychain on connect).
    @Published var sqlSignIn = SQLServerSignIn()
    @Published var isWorking = false
    @Published var error: String?
    /// Objects of a multi-table source; empty when the source is a single table.
    @Published var items: [NavigatorItem] = []
    @Published var checked: Set<String> = []
    @Published var focused: String?
    @Published var preview: QueryPreview?
    @Published var previewError: String?
    /// For folders: how the files would be combined (nil when no file can be).
    @Published var combine: (extension: String, format: CombineFilesFormat)?
    /// "Use first row as headers" for text files (set from the data, then the user's choice).
    @Published var promoteHeaders = false
    /// Set when the run finished and the dialog should close.
    @Published var isDone = false
    /// A source refused its credentials (or needs some): the dialog asks for them, then tries again.
    @Published var credentialPrompt: QueryDataSource?
    /// Opened from the Power Query Editor: Transform adds the queries there instead of opening the editor.
    var insideEditor = false
    private var headersDecided = false
    private var scripts: [String: String] = [:]
    private var generation = 0

    let security: QuerySecurity
    /// Settings ▸ Data load: promote headers and detect column types for files and web content; add the
    /// relationships that like-named key columns suggest once the tables are loaded.
    var detectTypes: Bool
    var detectRelationships: Bool

    init(store: DocumentStore, security: QuerySecurity = .shared, options: UserDefaults = AppSettings.defaults) {
        self.store = store
        self.security = security
        func option(_ key: AppSettings.Key) -> Bool { options.object(forKey: key.rawValue) as? Bool ?? AppSettings.initial[key.rawValue] as? Bool ?? false }
        detectTypes = option(.detectTypes)
        detectRelationships = DataLoadOptions.autodetectRelationships(for: store.doc, defaults: options)
    }

    var environment: QueryEnvironment { security.environment(baseDirectory: store.fileURL?.deletingLastPathComponent()) }

    private func engine(with script: String, named name: String) -> QueryEngine {
        QueryEngine(queries: store.doc.queries.filter { $0.name != name } + [QueryDefinition(name: name, mScript: script)], environment: environment)
    }
    private static let scratchName = "Get Data preview"

    // MARK: Stages

    func choose(_ connector: DataConnector, location: String = "") {
        guard let kind = connector.kind else { return }
        self.connector = connector
        request = SourceRequest(kind: kind, location: location)
        // A recent database server is remembered as "server;database", as data source files give it.
        if kind.isServer || kind == .sqlServer, let split = location.firstIndex(of: ";") {
            request.location = String(location[..<split])
            request.database = String(location[location.index(after: split)...])
        }
        sqlSignIn = SQLServerSignIn(method: SQLServerConnection.defaultMethod(for: request.location))
        reset()
        if kind == .blank { Task { await finish(.transform) } } else { stage = .form }
    }

    /// Text sample of the first listed file with an extension, for detecting a folder's CSV delimiter.
    static func sampleText(of wanted: String, in table: DataTable) -> String? {
        guard let ext = table.column("Extension"), let names = table.column("Name"), let folders = table.column("Folder Path"),
              let row = ext.values.firstIndex(where: { $0.asString.lowercased() == wanted }),
              let name = names.values[safe: row]?.asString, let folder = folders.values[safe: row]?.asString else { return nil }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 65_536)).map { String(decoding: $0, as: UTF8.self) }
    }

    func back() {
        error = nil
        switch stage {
        case .navigator, .approval: stage = .form
        default: stage = .catalog; connector = nil
        }
    }

    private func reset() {
        items = []; checked = []; focused = nil; preview = nil; previewError = nil; error = nil
        combine = nil; scripts = [:]; headersDecided = false; promoteHeaders = false
    }

    /// The source a hand-written query would run against, named as the engine names it (nil: no query typed).
    var nativeQuerySource: QueryDataSource? {
        guard !pendingNativeQuery.isEmpty else { return nil }
        if request.kind == .sqlite {
            return QueryDataSource(kind: "SQLite", location: (request.location.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath)
        }
        if request.kind == .sqlServer {
            return QueryDataSource(kind: "SQL", location: SQLServerConnection.location(server: request.location, database: request.database))
        }
        if request.kind.isServer { return SourcePlanner.dataSource(request) }
        return CloudSourcePlanner.nativeQuerySource(request)
    }
    var pendingNativeQuery: String { request.nativeQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    func approveNativeQuery() async {
        if let s = nativeQuerySource { security.approve(query: pendingNativeQuery, kind: s.kind, location: s.location) }
        await connect()
    }

    /// Validate the form, read the source and open the navigator.
    func connect() async {
        if let message = SourcePlanner.validationMessage(request) { error = message; return }
        reset()
        if request.kind == .sqlServer {
            let stored = SQLServerConnection.hasStoredCredential(server: request.location, database: request.database)
            if let message = SQLServerConnection.validationMessage(server: request.location, database: request.database, signIn: sqlSignIn, hasStoredCredential: stored) {
                error = message; return
            }
            do { try SQLServerConnection.save(sqlSignIn, server: request.location, database: request.database) } catch {
                self.error = "The sign-in couldn't be saved in the Keychain: \(error.localizedDescription)"; return
            }
        }
        if let s = nativeQuerySource, security.requiresNativeQueryApproval,
           !security.isApproved(query: pendingNativeQuery, kind: s.kind, location: s.location) {
            stage = .approval
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            if request.kind.readsWebContents {
                let probe = engine(with: "\"\"", named: Self.scratchName)
                let address = request.location.trimmingCharacters(in: .whitespacesAndNewlines)
                if case .binary(let data) = try await probe.evaluateExpression("Web.Contents(\(MSyntax.text(address)))") {
                    request.webContent = SourcePlanner.sniffWeb(data, address: address)
                    if request.webContent == .csv { request.delimiter = SourcePlanner.detectDelimiter(String(decoding: data.prefix(65_536), as: UTF8.self)) }
                }
            }
            if request.kind == .csv { request.delimiter = Self.sniffDelimiter(path: request.location) ?? request.delimiter }
            let source = MScript.script(from: SourcePlanner.sourceSteps(request))
            let value = try await engine(with: source, named: Self.scratchName).evaluateValue(Self.scratchName)
            items = try SourcePlanner.navigatorItems(from: value) ?? []
            stage = .navigator
            if let first = items.first { checked = [first.id]; await focus(first.id) } else { await focus(nil) }
            if request.kind.listsFiles, items.isEmpty { planCombine() }
        } catch {
            self.error = MError.wrap(error).description
            askForCredentials(error)
        }
    }

    /// Opens the credentials dialog when an error says a source needs credentials.
    func askForCredentials(_ error: Error) {
        if let s = MError.wrap(error).credentialSource { credentialPrompt = QueryDataSource(kind: s.kind, location: s.location) }
    }

    /// Credentials were saved: run the step that failed again.
    func retryAfterCredentials() async {
        credentialPrompt = nil
        switch stage {
        case .navigator: await focus(focused)
        default: await connect()
        }
    }

    private static func sniffDelimiter(path: String) -> String? {
        let url = URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), !data.isEmpty else { return nil }
        if url.pathExtension.lowercased() == "tsv" { return "\t" }
        return SourcePlanner.detectDelimiter(String(decoding: data, as: UTF8.self))
    }

    private func planCombine() {
        guard let table = preview?.table, let ext = table.column("Extension") else { return }
        // Cloud listings aren't sampled (that would download a file): their text files are read as comma-separated.
        let local = request.kind == .folder
        combine = SourcePlanner.combinePlan(extensions: ext.values.map(\.asString)) { local ? Self.sampleText(of: $0, in: table) : nil }
    }

    // MARK: Preview and scripts

    /// The finished M for an object (nil = the source itself): navigation, conversion to a table, promoted
    /// headers and detected types, as Power Query adds them.
    private func buildScript(item: NavigatorItem?, combined: Bool) async throws -> (script: String, preview: QueryPreview) {
        var steps = SourcePlanner.baseSteps(request, item: item)
        if combined, let combine { steps += SourcePlanner.combineSteps(extension: combine.extension, format: combine.format) }
        var script = MScript.script(from: steps)
        func sample(_ s: String) async throws -> QueryPreview {
            try await engine(with: s, named: Self.scratchName).evaluatePreview(Self.scratchName, rowLimit: 200)
        }
        var shown = try await sample(script)
        if shown.valueKind != "table", let last = steps.last {
            let value = try await engine(with: script, named: Self.scratchName).evaluateValue(Self.scratchName)
            steps += SourcePlanner.tableConversion(of: value, previous: last.name)
            script = MScript.script(from: steps)
            shown = try await sample(script)
        }
        let web = request.kind.readsWebContents
        let textual = request.kind == .csv || (web && request.webContent == .csv)
        let headerCandidate = textual || request.kind == .excel || (web && [.excel, .html].contains(request.webContent))
        if headerCandidate, !combined {
            let looksLikeHeaders = SourcePlanner.looksLikeHeaderRow(shown.table)
            if textual, !headersDecided { promoteHeaders = detectTypes && looksLikeHeaders; headersDecided = true }
            if textual ? promoteHeaders : detectTypes && looksLikeHeaders {
                script = MScript.appending(.promoteHeaders, to: script)
                shown = try await sample(script)
            }
        }
        let typed = request.kind.isDatabase || [.sqlServer, .python, .r, .parquet, .kusto].contains(request.kind)
        if detectTypes, !typed, let types = Transform.detectTypes(in: shown.untypedTable) {
            script = MScript.appending(types, to: script)
            shown = try await sample(script)
        }
        return (script, shown)
    }

    /// Show an object's preview (nil = the single table of the source).
    func focus(_ id: String?) async {
        focused = id
        generation += 1
        let mine = generation
        isWorking = true
        defer { if mine == generation { isWorking = false } }
        do {
            let built = try await buildScript(item: items.first { $0.id == id }, combined: false)
            guard mine == generation else { return }
            scripts[id ?? ""] = built.script
            preview = built.preview
            previewError = nil
        } catch {
            guard mine == generation else { return }
            preview = nil
            previewError = MError.wrap(error).description
            askForCredentials(error)
        }
    }

    /// Text file options changed: rebuild the preview.
    func optionsChanged() {
        scripts = [:]
        Task { await focus(focused) }
    }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    var canFinish: Bool { !isWorking && (items.isEmpty ? previewError == nil && preview != nil : !checked.isEmpty) }

    // MARK: Load / Transform

    /// Create the queries; `.load` also evaluates them into model tables, `.transform` opens the editor.
    /// Returns true when the dialog should close.
    @discardableResult
    func finish(_ destination: Destination, combined: Bool = false) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        error = nil
        var taken = Set(store.doc.queries.map(\.name)).union(store.doc.data.tables.keys).union(store.doc.model.tables.map(\.name))
        var definitions: [QueryDefinition] = []
        do {
            if request.kind == .blank {
                let name = SourcePlanner.uniqueName("Query1", taken: taken)
                definitions = [QueryDefinition(name: name, mScript: MScript.script(from: SourcePlanner.sourceSteps(request)))]
            } else {
                let chosen: [NavigatorItem?] = items.isEmpty ? [nil] : items.filter { checked.contains($0.id) }
                for item in chosen {
                    let key = item?.id ?? ""
                    let script: String
                    if !combined, let cached = scripts[key] { script = cached } else { script = try await buildScript(item: item, combined: combined).script }
                    let name = SourcePlanner.uniqueName(SourcePlanner.queryName(request, item: item), taken: taken)
                    taken.insert(name)
                    var definition = QueryDefinition(name: name, mScript: script)
                    definition.description = connector?.name ?? ""
                    definitions.append(definition)
                }
            }
            guard let first = definitions.first else { return false }
            var tables: [DataTable] = []
            var sources: [QueryDataSource] = SourcePlanner.dataSource(request).map { [$0] } ?? []
            if destination == .load {
                let engine = QueryEngine(queries: store.doc.queries + definitions, environment: environment)
                DataLoadOptions.configure(engine)
                let results = await engine.refreshAll(only: definitions.map(\.name)) { _ in }
                var failures: [String] = []
                for definition in definitions {
                    switch results[definition.name] {
                    case .success(var table)?: table.name = definition.name; tables.append(table)
                    case .failure(let e)?: failures.append("\(definition.name): \(MError.wrap(e).description)"); askForCredentials(e)
                    case nil: failures.append("\(definition.name): no result.")
                    }
                }
                if !failures.isEmpty { error = failures.joined(separator: "\n"); return false }
                // One record per location: OData reads its feed through Web.Contents, which is the same source.
                for s in engine.dataSourcesAccessed where !sources.contains(where: { $0.location == s.location }) { sources.append(s) }
            }
            let directQuery = (request.kind.isDatabase || request.kind == .sqlServer) && request.directQuery
            if directQuery {
                // The same check as the storage-mode menu: DirectQuery only when every step folds into SQL.
                for table in tables {
                    var probe = ModelTable(name: table.name)
                    probe.sourceQuery = table.name
                    let support = await StorageModeLogic.support(probe, queries: store.doc.queries + definitions,
                                                                   baseDirectory: store.fileURL?.deletingLastPathComponent())
                    if case .importOnly(let reason) = support {
                        error = reason + " Choose Import to load it."
                        return false
                    }
                }
            }
            // Routed before the write, so an editor that is already open selects the new query as it appears.
            if destination == .transform { QueryEditorRouting.select(first.name, in: store) }
            var related: [Relationship] = []
            // One write, so one undo step takes the queries, tables, relationships and source records away together.
            store.mutate(destination == .load ? "Get Data" : "Add Queries", invalidates: .model) { d in
                d.queries.append(contentsOf: definitions)
                for table in tables {
                    d.data[table.name] = table
                    var model = ModelTable(name: table.name, columns: table.columns.map(DocumentStore.modelColumn))
                    model.sourceQuery = table.name
                    if directQuery { model.storageMode = .directQuery }
                    d.model.tables.append(model)
                }
                if detectRelationships, !tables.isEmpty {
                    let loaded = Set(tables.map { $0.name.lowercased() })
                    related = RelationshipLogic.autodetect(d.model, data: d.data)
                        .filter { loaded.contains($0.fromTable.lowercased()) || loaded.contains($0.toTable.lowercased()) }
                    d.model.relationships += related
                }
                for s in sources {
                    if let i = d.dataSources.firstIndex(where: { $0.kind == s.kind && $0.location == s.location }) {
                        d.dataSources[i].lastUsed = Date()
                    } else {
                        var record = DataSourceRecord(kind: s.kind, location: s.location, displayName: (s.location as NSString).lastPathComponent)
                        if s.location.contains("://") { record.displayName = s.location }
                        record.privacy = security.privacyLevel(kind: s.kind, location: s.location)
                        d.dataSources.append(record)
                    }
                }
            }
            security.noteRecent(kind: request.kind, location: request.kind.isServer
                                ? request.location.trimmingCharacters(in: .whitespacesAndNewlines) + ";" + request.database.trimmingCharacters(in: .whitespacesAndNewlines)
                                : request.location)
            switch destination {
            case .load:
                let rows = tables.reduce(0) { $0 + $1.rowCount }
                let what = tables.count == 1 ? first.name : "\(tables.count) tables"
                let found = related.isEmpty ? "" : " Found \(related.count) relationship\(related.count == 1 ? "" : "s")."
                store.status = StatusMessage(kind: .success, text: "Loaded \(what) (\(rows) row\(rows == 1 ? "" : "s"))\(directQuery ? " in DirectQuery mode" : "").\(found)")
            case .transform:
                if !insideEditor { NotificationCenter.default.post(name: .facetOpenQueryEditor, object: store) }
            }
            isDone = true
            return true
        } catch {
            self.error = MError.wrap(error).description
            askForCredentials(error)
            return false
        }
    }
}
