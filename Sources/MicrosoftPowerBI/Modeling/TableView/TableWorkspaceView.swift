import SwiftUI
import FacetCore
import FacetDesign

/// The Table view workspace: a table list, the data grid, the formula bar, and the column,
/// measure and table tools. Sort and filter here are view-only, for inspection — they shape what
/// the grid shows and are never written to the document.
struct TableWorkspaceView: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject private var modeling: ModelingState
    @State private var filterRequest: GridFilterRequest?
    /// The last computed row order. A plain object: reading and filling it during a render does
    /// not invalidate the view.
    @State private var rowCache = RowIndexCache()
    /// Bumped when an off-thread row order lands, so the view renders again and the grid reloads.
    @State private var indexArrivals = 0
    @State private var commitProblem: String?
    @State private var committing = false

    /// Tables above this size index their rows off the main thread.
    private static let asyncRowThreshold = 20_000

    /// Everything one render shows, worked out once.
    private struct Shown {
        var table: ModelTable
        var data: DataTable?
        var state: GridViewState
        var plan: TableGrid.Plan
        var key: RowsKey
        /// Visible data rows in order; nil shows the table as stored.
        var rows: [Int]?
        /// A big table's row order is still being computed off the main thread.
        var pending: Bool
    }

    init(store: DocumentStore) {
        _modeling = ObservedObject(wrappedValue: store.modeling)
    }

    // MARK: Body

    var body: some View {
        if let table = currentTable {
            workspace(shown(table))
        } else {
            emptyState
        }
    }

    private func workspace(_ shown: Shown) -> some View {
        VStack(spacing: 0) {
            TableTabBar(tables: store.model.tables.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                        current: shown.table.name) { name in ModelingSelection.select(table: name, in: store) }
            Hairline()
            actionBar(shown)
            contextTools(shown)
            Hairline()
            formulaSection
            grid(shown)
            Hairline()
            statusLine(shown)
        }
        .background(Design.Palette.elevated)
        .onAppear(perform: fixTable)
        .onChange(of: modeling.formula?.id) { _, _ in commitProblem = nil }
        .task(id: shown.key) { await computeRows(shown) }
    }

    private var emptyState: some View {
        VStack(spacing: Design.Space.m) {
            EmptyState(systemImage: "tablecells", title: "No data yet",
                       message: "Connect to data or load the sample, then browse its rows here.")
                .frame(maxHeight: 150)
            Button("Get Data…") { AppCommands.run("data.get", store) }.buttonStyle(.borderedProminent)
            Button("Load Sample Data") { AppCommands.run("data.sample", store) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.Palette.surface)
    }

    // MARK: State

    /// The table the grid shows, falling back to the first table until a tab is picked.
    private var currentTable: ModelTable? {
        if let name = modeling.tableViewTable, let t = store.model.table(name) { return t }
        return store.model.tables.first
    }

    /// Resolves the table's data, columns and row order once per render. Small tables sort and
    /// filter here, cached by (table, data, view state); big ones read what `computeRows` cached.
    private func shown(_ table: ModelTable) -> Shown {
        let data = store.computedData[table.name] ?? store.doc.data[table.name]
        let state = modeling.gridState(for: table.name)
        let plan = TableGrid.plan(for: table, data: data, filters: state.filters, revision: modeling.dataRevision)
        let key = RowsKey(table: table.name, dataToken: plan.dataToken, gridRevision: modeling.gridRevision)
        var rows: [Int]?
        var pending = false
        if let data, !state.isIdentity {
            if data.rowCount <= Self.asyncRowThreshold {
                rows = rowCache.rows(for: key) { TableGrid.rows(for: data, state: state) }
            } else {
                let cached = rowCache.lookup(key)
                rows = cached.rows
                pending = !cached.hit
            }
        }
        return Shown(table: table, data: data, state: state, plan: plan, key: key, rows: rows, pending: pending)
    }

    /// Shows the selected object's table when the view opens, and keeps the shown table pointing
    /// at one that exists.
    private func fixTable() {
        if let selected = modeling.primary?.tableName, let t = store.model.table(selected) {
            modeling.tableViewTable = t.name
        } else if modeling.tableViewTable == nil || store.model.table(modeling.tableViewTable ?? "") == nil {
            modeling.tableViewTable = currentTable?.name
        }
    }

    /// Big tables sort and filter off the main thread. The result is cached under the key it was
    /// computed for, and the arrival counter makes the view render again and the grid reload.
    private func computeRows(_ shown: Shown) async {
        guard shown.pending, let data = shown.data else { return }
        let state = shown.state
        let rows = await Task.detached(priority: .userInitiated) { TableGrid.rows(for: data, state: state) }.value
        guard !Task.isCancelled else { return }
        rowCache.store(rows, for: shown.key)
        indexArrivals &+= 1
    }

    // MARK: Actions

    private func selectColumn(_ name: String?, in table: ModelTable) {
        if let name {
            ModelingSelection.select(column: name, table: table.name, in: store)
        } else {
            ModelingSelection.select(table: table.name, in: store)
        }
    }

    private func applyState(_ state: GridViewState, for table: ModelTable) {
        modeling.setGridState(state, for: table.name)
    }

    private func applyFilter(_ column: String, _ filter: GridColumnFilter?, in shown: Shown) {
        var state = shown.state
        state.filters[column] = filter
        applyState(state, for: shown.table)
    }

    /// Copies the given columns of the rows shown (sorted and filtered), tab-separated with
    /// headers, and reports what was copied once it is on the pasteboard.
    private func copy(_ columns: [GridColumn], of shown: Shown) {
        guard let data = shown.data, !columns.isEmpty else { return }
        guard !shown.pending else {
            store.status = StatusMessage(kind: .info, text: "Still sorting and filtering \(shown.table.name). Copy again in a moment.")
            return
        }
        let index = shown.rows, name = shown.table.name
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                TableGrid.tsv(data: data, columns: columns, rowIndex: index, headers: true)
            }.value
            DataGrid.Coordinator.write(text)
            store.status = StatusMessage(kind: .success,
                                         text: TableGrid.copyMessage(rows: TableGrid.copiedRowCount(data: data, rowIndex: index), of: name))
        }
    }

    private func commitFormula() {
        guard let edit = modeling.formula, !committing else { return }
        committing = true
        Task {
            if let message = await ModelOps.commitFormula(store, edit) {
                commitProblem = message
            }
            committing = false
        }
    }

    private func cancelFormula() {
        modeling.formula = nil
        commitProblem = nil
    }

    // MARK: Action bar

    private func actionBar(_ shown: Shown) -> some View {
        HStack(spacing: Design.Space.xs) {
            Button { AppCommands.run("model.newMeasure", store) } label: { Label("New measure", systemImage: "function") }
                .help("New measure in the formula bar")
            Button { AppCommands.run("model.newColumn", store) } label: { Label("New column", systemImage: "tablecells") }
                .help("New calculated column in the formula bar")
            Button { AppCommands.run("model.newTable", store) } label: { Label("New table", systemImage: "table") }
                .help("New calculated table in the formula bar")
            Button { AppCommands.run("model.quickMeasure", store) } label: { Label("Quick measure", systemImage: "wand.and.stars") }
                .help("Pick a ready-made calculation")
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, Design.Space.xs)
            Button { copy(shown.plan.columns, of: shown) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the table as shown, tab-separated")
            Spacer(minLength: Design.Space.s)
            if !shown.state.isIdentity {
                Button("Clear sort & filters") { applyState(GridViewState(), for: shown.table) }
                    .help("Show the table as stored")
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
    }

    // MARK: Contextual tools

    /// The tool strip for the selected column or measure, or for the shown table when nothing
    /// else is selected or the selection no longer exists.
    @ViewBuilder
    private func contextTools(_ shown: Shown) -> some View {
        Group {
            switch TableGrid.toolsTarget(primary: modeling.primary, shown: shown.table.name, model: store.model) {
            case .column(let table, let name):
                if let column = store.model.table(table)?.column(name) {
                    ColumnToolsRow(column: column, table: table)
                } else {
                    TableToolsRow(table: shown.table)
                }
            case .measure(let table, let name):
                if let measure = store.model.table(table)?.measure(name) {
                    MeasureToolsRow(measure: measure, table: table)
                } else {
                    TableToolsRow(table: shown.table)
                }
            case .table:
                TableToolsRow(table: shown.table)
            }
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
    }

    // MARK: Formula bar

    @ViewBuilder
    private var formulaSection: some View {
        if modeling.formula != nil {
            FormulaBar(text: Binding(get: { modeling.formula?.text ?? "" }, set: { modeling.formula?.text = $0 }),
                       kind: modeling.formula?.kind.expressionKind ?? .measure,
                       homeTable: modeling.formula?.kind == .table ? nil : modeling.formula?.table,
                       message: commitProblem,
                       onCommit: commitFormula,
                       onCancel: cancelFormula)
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, Design.Space.xs)
            Hairline()
        }
    }

    // MARK: Grid

    private func grid(_ shown: Shown) -> some View {
        DataGrid(table: shown.data, dataToken: shown.plan.dataToken, columns: shown.plan.columns,
                 rowIndex: shown.rows,
                 indexToken: TableGrid.indexToken(gridRevision: modeling.gridRevision, arrivals: indexArrivals),
                 selectedColumn: selectedColumn(in: shown.table),
                 sortColumn: shown.state.sortColumn, sortAscending: shown.state.ascending,
                 onSelectColumn: { selectColumn($0, in: shown.table) },
                 headerMenu: { headerMenu($0, in: shown) },
                 filterEditor: { name, close in filterEditor(name, in: shown, close: close) },
                 filterRequest: filterRequest)
    }

    private func selectedColumn(in table: ModelTable) -> String? {
        guard case .column(let t, let n) = modeling.primary, ModelDAX.same(t, table.name), let c = table.column(n) else { return nil }
        return c.name
    }

    private func headerMenu(_ column: String, in shown: Shown) -> [ModelMenuEntry] {
        guard let c = shown.table.column(column) else { return [] }
        return TableColumnMenu.entries(store: store, table: shown.table, column: c,
                                       state: shown.state,
                                       applyState: { applyState($0, for: shown.table) },
                                       openFilter: { filterRequest = GridFilterRequest(column: column) },
                                       copyColumn: { name in copy(shown.plan.columns.filter { $0.name == name }, of: shown) })
    }

    private func filterEditor(_ column: String, in shown: Shown, close: @escaping () -> Void) -> AnyView {
        let gc = shown.plan.columns.first { $0.name == column }
        return TableFilterEditor.view(data: shown.data,
                                      column: gc ?? GridColumn(name: column, type: .text, format: "", glyph: "tablecells"),
                                      current: shown.state.filters[column],
                                      apply: { applyFilter(column, $0, in: shown) },
                                      close: close)
    }

    // MARK: Status line

    private func statusLine(_ shown: Shown) -> some View {
        let total = shown.data?.rowCount ?? 0
        let visible = shown.rows?.count ?? total
        let columns = shown.plan.columns.count
        return HStack(spacing: Design.Space.s) {
            Text(shown.pending ? "Sorting and filtering \(total.formatted()) rows…"
                 : total == 0 ? "No rows"
                 : visible == total ? "\(total.formatted()) row\(total == 1 ? "" : "s")"
                 : "\(visible.formatted()) of \(total.formatted()) rows")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit()
            Text("· \(columns.formatted()) column\(columns == 1 ? "" : "s")")
                .font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit()
            if shown.table.storageMode != .import {
                Chip(ModelGlyph.label(for: shown.table.storageMode))
            }
            if !shown.state.isIdentity, !shown.pending {
                Text("· \(TableGrid.viewStateCaption(shown.state))").font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.m)
        .frame(height: 26)
    }
}

// MARK: - Table list

/// The table list: one chip per table, alphabetically, with a hidden badge.
private struct TableTabBar: View {
    let tables: [ModelTable]
    let current: String
    let onSelect: (String) -> Void
    @State private var hovering: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Design.Space.xxs) {
                ForEach(tables) { t in chip(t) }
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
        }
    }

    private func chip(_ table: ModelTable) -> some View {
        let active = ModelDAX.same(table.name, current)
        return HStack(spacing: Design.Space.xs) {
            Image(systemName: ModelGlyph.symbol(for: table))
                .font(.system(size: 11))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text(table.name).font(Design.Typeface.body).lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            if table.isHidden {
                Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Hidden in report view")
            }
        }
        .padding(.leading, Design.Space.m)
        .padding(.trailing, Design.Space.m)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(active ? Design.Palette.fillStrong : (hovering == table.name ? Design.Palette.fill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 ? table.name : nil }
        .onTapGesture { onSelect(table.name) }
        .help("Show \(table.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Table \(table.name)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
