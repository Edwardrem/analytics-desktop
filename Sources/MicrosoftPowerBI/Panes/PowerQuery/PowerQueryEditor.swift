import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// The Power Query Editor: queries pane, data preview, applied steps and a formula bar.
/// The M script is the source of truth; the Applied Steps list edits it through `MScript`.
@MainActor
enum PowerQueryFeature {
    static func register() {
        Features.queryEditorBuilder = { store in AnyView(PowerQueryEditor()) }
    }
}

// MARK: Editor shell

struct PowerQueryEditor: View {
    @EnvironmentObject var store: DocumentStore
    @State private var selectedQuery: String?
    @State private var preview: DataTable?
    @State private var previewStep: Int?          // nil = the whole query
    @State private var previewError: String?
    @State private var isRefreshing = false

    var body: some View {
        let queries = store.doc.queries
        Group {
            if queries.isEmpty {
                EmptyState(systemImage: "wand.and.rays",
                           title: "No queries yet",
                           message: "Get data first (File ▸ Get Data), then open Transform data to shape it here.")
                    .frame(minWidth: 640, minHeight: 400)
            } else {
                NavigationSplitView {
                    QueriesPane(selection: $selectedQuery)
                } detail: {
                    if let name = selectedQuery ?? queries.first(where: { $0.kind == .table })?.name {
                        QueryDetail(queryName: name, preview: $preview, previewStep: $previewStep,
                                    previewError: $previewError, isRefreshing: $isRefreshing)
                    } else {
                        EmptyState(systemImage: "tablecells", title: "Select a query")
                            .frame(minWidth: 480, minHeight: 360)
                    }
                }
                .frame(minWidth: 900, minHeight: 520)
                .onAppear { if selectedQuery == nil { selectedQuery = queries.first(where: { $0.kind == .table })?.name } }
            }
        }
    }
}

// MARK: Queries pane

private struct QueriesPane: View {
    @EnvironmentObject var store: DocumentStore
    @Binding var selection: String?
    @State private var renaming: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.doc.queries) { q in
                row(q)
            }
            .onDelete { indexSet in
                let names = indexSet.map { store.doc.queries[$0].name }
                store.mutate("Delete Queries", invalidates: .model) { d in
                    d.queries.removeAll { names.contains($0.name) }
                }
                if let selection, names.contains(selection) { self.selection = nil }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .sheet(item: Binding(
            get: { renaming.map { RenameRequest(name: $0) } },
            set: { renaming = $0?.name })) { request in
            RenameField(title: "Rename query", initial: request.name) { newName in
                applyRename(request.name, to: newName)
            }
        }
    }

    private func row(_ q: QueryDefinition) -> some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: icon(q.kind)).foregroundStyle(.secondary)
            Text(q.name).lineLimit(1)
            if q.kind == .parameter {
                let current = q.parameter.map { ValueFormatter.format($0.currentValue, "") } ?? ""
                Text(current).font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if !q.loadEnabled { Text("disabled").font(Design.Typeface.caption).foregroundStyle(.tertiary) }
        }
        .tag(q.name)
        .contextMenu { menu(q) }
    }

    @ViewBuilder
    private func menu(_ q: QueryDefinition) -> some View {
        Button("Rename…") { renaming = q.name }
        Button("Duplicate") { duplicate(q) }
        Button("Create Reference") { reference(q) }
        Divider()
        Button(q.loadEnabled ? "Disable Load" : "Enable Load") { toggleLoad(q) }
        Button(q.includeInRefresh ? "Exclude from Report Refresh" : "Include in Report Refresh") { toggleRefresh(q) }
    }

    private func applyRename(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        store.mutate("Rename Query", invalidates: .model) { d in
            if let i = d.queries.firstIndex(where: { $0.name == oldName }) {
                d.queries[i].name = trimmed
                if let ti = d.model.tableIndex(oldName) { d.model.tables[ti].sourceQuery = trimmed }
                if let table = d.data.tables.removeValue(forKey: oldName) { d.data.tables[trimmed] = table }
                selection = trimmed
            }
        }
    }

    private func toggleLoad(_ q: QueryDefinition) {
        store.mutate("Change Query") { d in
            if let i = d.queries.firstIndex(where: { $0.id == q.id }) { d.queries[i].loadEnabled.toggle() }
        }
    }

    private func toggleRefresh(_ q: QueryDefinition) {
        store.mutate("Change Query") { d in
            if let i = d.queries.firstIndex(where: { $0.id == q.id }) { d.queries[i].includeInRefresh.toggle() }
        }
    }

    private func icon(_ kind: QueryDefinition.Kind) -> String {
        switch kind {
        case .table: return "tablecells"
        case .parameter: return "slider.horizontal.3"
        case .function: return "f(x)"
        case .list: return "list.bullet"
        case .value: return "number"
        }
    }

    private func duplicate(_ q: QueryDefinition) {
        var name = q.name + " (2)"
        var k = 3
        while store.doc.queries.contains(where: { $0.name == name }) { name = "\(q.name) (\(k))"; k += 1 }
        store.mutate("Duplicate Query", invalidates: .model) { d in
            d.queries.append(MScript.duplicateQuery(q, newName: name))
        }
    }

    private func reference(_ q: QueryDefinition) {
        var name = q.name + " (reference)"
        var k = 3
        while store.doc.queries.contains(where: { $0.name == name }) { name = "\(q.name) (reference \(k))"; k += 1 }
        store.mutate("Create Reference", invalidates: .model) { d in
            d.queries.append(MScript.referenceQuery(q, newName: name))
        }
    }

    private struct RenameRequest: Identifiable { var name: String; var id: String { name } }
}

// MARK: Rename sheet

private struct RenameField: View {
    let title: String
    @State var initial: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text(title).font(Design.Typeface.headline)
            TextField("Name", text: $initial)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func commit() {
        onCommit(initial)
        dismiss()
    }
}

// MARK: Query detail

private struct QueryDetail: View {
    @EnvironmentObject var store: DocumentStore
    let queryName: String
    @Binding var preview: DataTable?
    @Binding var previewStep: Int?
    @Binding var previewError: String?
    @Binding var isRefreshing: Bool

    var body: some View {
        VStack(spacing: 0) {
            FormulaBarHeader(queryName: queryName)
            Hairline()
            HSplitView {
                PreviewPane(preview: $preview, previewStep: $previewStep, previewError: $previewError,
                            queryName: queryName)
                QuerySettingsPane(queryName: queryName, preview: $preview, previewStep: $previewStep,
                                 previewError: $previewError, isRefreshing: $isRefreshing)
                    .frame(minWidth: 240, idealWidth: 280)
            }
        }
    }
}

// MARK: Formula bar + ribbon

private struct FormulaBarHeader: View {
    @EnvironmentObject var store: DocumentStore
    let queryName: String
    @State private var editingScript = false
    @State private var draft = ""

    private var query: QueryDefinition? { store.doc.queries.first { $0.name == queryName } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.s) {
                Text(queryName).font(Design.Typeface.headline)
                Spacer(minLength: 0)
                Button("Refresh Preview") { NotificationCenter.default.post(name: .queryPreviewRequested, object: nil) }
                    .controlSize(.small)
                Button(editingScript ? "Done" : "Advanced Editor") {
                    if editingScript {
                        store.mutate("Edit Query", coalesce: "m-script") { d in
                            if let i = d.queries.firstIndex(where: { $0.name == queryName }) { d.queries[i].mScript = draft }
                        }
                    } else {
                        draft = query?.mScript ?? ""
                    }
                    editingScript.toggle()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
            if editingScript {
                CodeEditor(text: $draft, language: LanguageSupport.m, model: store.model, fontSize: 12)
                    .frame(height: 220)
                    .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.s)
            } else {
                Text(query?.mScript ?? "")
                    .font(Design.Typeface.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.s)
            }
        }
        .background(Design.Palette.fill)
    }
}

extension Notification.Name {
    static let queryPreviewRequested = Notification.Name("queryPreviewRequested")
}

// MARK: Data preview

private struct PreviewPane: View {
    @EnvironmentObject var store: DocumentStore
    @Binding var preview: DataTable?
    @Binding var previewStep: Int?
    @Binding var previewError: String?
    let queryName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.s) {
                if let step = previewStep {
                    Text(store.doc.queries.first { $0.name == queryName }.map { MScript.steps(of: $0.mScript) }?[safe: step]?.name ?? "")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Text("step preview").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                } else {
                    Text("final result").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let preview { Text("\(preview.rowCount) rows").font(Design.Typeface.caption).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
            if let previewError {
                EmptyState(systemImage: "exclamationmark.triangle", title: "Preview failed", message: previewError)
            } else if let preview {
                DataGrid(table: preview, dataToken: preview.rowCount &+ preview.columnCount,
                         columns: preview.columns.map {
                            GridColumn(name: $0.name, type: $0.type, format: "", glyph: "number")
                         }, rowIndex: nil, indexToken: 0, selectedColumn: nil, sortColumn: nil, sortAscending: true,
                         onSelectColumn: { _ in }, headerMenu: { _ in [] },
                         filterEditor: { _, dismiss in AnyView(Button("Done", action: dismiss)) })
            } else {
                ProgressView("Evaluating preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { Task { await load() } }
        .onChange(of: queryName) { _, _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .queryPreviewRequested)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        guard let q = store.doc.queries.first(where: { $0.name == queryName }), q.kind == .table else {
            preview = nil
            previewError = nil
            return
        }
        let step = previewStep
        let base = store.fileURL?.deletingLastPathComponent()
        let engine = QueryEngine(queries: store.doc.queries, environment: QueryEnvironment(baseDirectory: base))
        do {
            let table = try await engine.evaluate(queryName, upToStep: step, rowLimit: 1000)
            preview = table
            previewError = nil
        } catch {
            preview = nil
            previewError = MError.wrap(error).description
        }
    }
}

// MARK: Query settings (Applied Steps)

private struct QuerySettingsPane: View {
    @EnvironmentObject var store: DocumentStore
    let queryName: String
    @Binding var preview: DataTable?
    @Binding var previewStep: Int?
    @Binding var previewError: String?
    @Binding var isRefreshing: Bool

    @State private var selectedStep: Int?
    @State private var renamingStep: String?
    @State private var editingStep: String?

    private var query: QueryDefinition? { store.doc.queries.first { $0.name == queryName } }
    private var steps: [MStep] { query.map { MScript.steps(of: $0.mScript) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Common transforms.
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("Transform").font(Design.Typeface.bodyStrong)
                HStack(spacing: 6) {
                    Button("Remove Rows") { removeRows() }.controlSize(.small)
                    Button("Remove Columns") { removeColumns() }.controlSize(.small)
                    Button("Split Column") { splitColumn() }.controlSize(.small)
                }
                HStack(spacing: 6) {
                    Button("Group By") { groupBy() }.controlSize(.small)
                    Button("Pivot") { pivot() }.controlSize(.small)
                    Button("Unpivot") { unpivot() }.controlSize(.small)
                }
                HStack(spacing: 6) {
                    Button("Change Type") { changeType() }.controlSize(.small)
                    Button("Rename") { renameColumns() }.controlSize(.small)
                    Button("Fill Down") { fillDown() }.controlSize(.small)
                }
            }
            .padding(Design.Space.m)
            Hairline()
            // Applied steps.
            VStack(alignment: .leading, spacing: 0) {
                Text("Applied Steps").font(Design.Typeface.bodyStrong)
                    .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.s).padding(.bottom, Design.Space.xs)
                List(selection: $selectedStep) {
                    ForEach(steps.indices, id: \.self) { i in
                        HStack {
                            Button {
                                previewStep = (previewStep == i) ? nil : i
                                Task { await reloadPreview() }
                            } label: {
                                Image(systemName: previewStep == i ? "eye.fill" : "eye")
                                    .foregroundStyle(previewStep == i ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Preview up to this step")
                            Text(steps[i].name)
                            Spacer(minLength: 0)
                        }
                        .tag(i)
                        .contextMenu {
                            Button("Rename…") { renamingStep = steps[i].name }
                            Button("Move Up") { move(i, to: i - 1) }.disabled(i == 0)
                            Button("Move Down") { move(i, to: i + 1) }.disabled(i == steps.count - 1)
                            Divider()
                            Button("Delete") { delete(steps[i].name) }
                        }
                    }
                }
                .listStyle(.plain)
            }
            Spacer(minLength: 0)
            // Refresh data.
            HStack {
                Spacer()
                Button("Close & Apply") {
                    store.refreshData()
                    isRefreshing = true
                }
                .controlSize(.small)
                .help("Re-run every load-enabled query and load the results into the model")
            }
            .padding(Design.Space.m)
        }
        .onAppear { selectedStep = previewStep }
        .onChange(of: steps.count) { _, _ in
            if let s = selectedStep, s >= steps.count { selectedStep = nil }
        }
        .sheet(item: Binding(
            get: { renamingStep.map { StepRenameRequest(name: $0) } },
            set: { renamingStep = $0?.name })) { request in
            RenameField(title: "Rename step", initial: request.name) { newName in
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                updateScript { MScript.renamingStep(request.name, to: trimmed, in: $0) }
            }
        }
    }

    private func reloadPreview() async {
        NotificationCenter.default.post(name: .queryPreviewRequested, object: nil)
    }

    /// Applies an edit to the query's M script.
    private func updateScript(_ edit: (String) -> String) {
        store.mutate("Edit Query", coalesce: "m-script", invalidates: .model) { d in
            if let i = d.queries.firstIndex(where: { $0.name == queryName }) {
                d.queries[i].mScript = edit(d.queries[i].mScript)
            }
        }
        Task { await reloadPreview() }
    }

    // MARK: Transform commands (operate on the preview grid's columns)

    private func firstSelectedColumn() -> String? { preview?.columnNames.first }

    private func removeRows() {
        updateScript { MScript.appending(.removeTopRows(1), to: $0) }
    }
    private func removeColumns() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.removeColumns([col]), to: $0) }
    }
    private func splitColumn() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.splitByDelimiter(column: col, delimiter: ",", at: .each, into: .columns(2)), to: $0) }
    }
    private func groupBy() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.groupBy(keys: [col], aggregations: []), to: $0) }
    }
    private func pivot() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.pivotColumn(column: col, valueColumn: col, aggregation: .sum), to: $0) }
    }
    private func unpivot() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.unpivotColumns([col]), to: $0) }
    }
    private func changeType() {
        guard let col = firstSelectedColumn(), let type = preview?.column(col)?.type else { return }
        updateScript { MScript.appending(.changeType([(col, type)], culture: nil), to: $0) }
    }
    private func renameColumns() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.renameColumns([(col, col + " (renamed)")]), to: $0) }
    }
    private func fillDown() {
        guard let col = firstSelectedColumn() else { return }
        updateScript { MScript.appending(.fillDown([col]), to: $0) }
    }
    private func move(_ i: Int, to j: Int) {
        guard steps.indices.contains(i), steps.indices.contains(j) else { return }
        updateScript { MScript.movingStep(steps[i].name, to: j, in: $0) }
    }
    private func delete(_ name: String) {
        updateScript { MScript.deletingStep(name, in: $0) }
    }

    private struct StepRenameRequest: Identifiable { var name: String; var id: String { name } }
}
