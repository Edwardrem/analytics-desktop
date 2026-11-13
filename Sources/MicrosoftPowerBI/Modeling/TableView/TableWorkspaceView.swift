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
    @State private var asyncIndex: AsyncIndex?
    @State private var commitProblem: String?
    @State private var committing = false

    /// Tables above this size index their rows off the main thread.
    private static let asyncRowThreshold = 20_000

    private struct AsyncIndex: Equatable { var table: String; var rows: [Int]? }
    private struct RowsKey: Equatable { var table: String; var token: Int }

    init(store: DocumentStore) {
        _modeling = ObservedObject(wrappedValue: store.modeling)
    }

    // MARK: Body

    var body: some View {
        if let table = currentTable {
            workspace(table)
        } else {
            emptyState
        }
    }

    private func workspace(_ table: ModelTable) -> some View {
        VStack(spacing: 0) {
            TableTabBar(tables: store.model.tables.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                        current: table.name) { name in ModelingSelection.select(table: name, in: store) }
            Hairline()
            actionBar
            contextTools
            Hairline()
            formulaSection
            grid(table)
            Hairline()
            statusLine(table)
        }
        .background(Design.Palette.elevated)
        .onAppear(perform: fixTable)
        .onChange(of: modeling.formula?.id) { _, _ in commitProblem = nil }
        .task(id: RowsKey(table: table.name, token: plan.dataToken &+ modeling.gridRevision)) {
            await computeRows(table)
        }
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

    private var data: DataTable? {
        guard let name = currentTable?.name else { return nil }
        return store.computedData[name] ?? store.doc.data[name]
    }

    private func gridState(for table: ModelTable) -> GridViewState { modeling.gridState(for: table.name) }

    private var plan: TableGrid.Plan {
        TableGrid.plan(for: currentTable ?? ModelTable(name: "Table"), data: data, filters: currentTable.map { gridState(for: $0).filters } ?? [:])
    }

    private func rowIndex(for table: ModelTable, data: DataTable?) -> [Int]? {
        guard let data else { return nil }
        let state = gridState(for: table)
        if state.isIdentity { return nil }
        if data.rowCount <= Self.asyncRowThreshold { return TableGrid.rows(for: data, state: state) }
        return asyncIndex?.table == table.name ? asyncIndex?.rows : nil
    }

    /// Keeps the shown table pointing at a table that exists.
    private func fixTable() {
        if modeling.tableViewTable == nil || store.model.table(modeling.tableViewTable ?? "") == nil {
            modeling.tableViewTable = currentTable?.name
        }
    }

    /// Big tables sort and filter off the main thread; the result is keyed by table so a switch
    /// never applies another table's order.
    private func computeRows(_ table: ModelTable) async {
        guard let data, data.rowCount > Self.asyncRowThreshold else {
            asyncIndex = nil
            return
        }
        let state = gridState(for: table)
        guard !state.isIdentity else {
            asyncIndex = nil
            return
        }
        let rows = await Task.detached(priority: .userInitiated) { TableGrid.rows(for: data, state: state) }.value
        if !Task.isCancelled { asyncIndex = AsyncIndex(table: table.name, rows: rows) }
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

    private func applyFilter(_ column: String, _ filter: GridColumnFilter?, for table: ModelTable) {
        var state = gridState(for: table)
        state.filters[column] = filter
        applyState(state, for: table)
    }

    /// Copies the table as shown (sorted and filtered), tab-separated with headers.
    private func copyTable(_ table: ModelTable) {
        guard let d = data else { return }
        let columns = plan.columns, index = rowIndex(for: table, data: d)
        Task.detached(priority: .userInitiated) {
            let text = TableGrid.tsv(data: d, columns: columns, rowIndex: index, headers: true)
            await MainActor.run { DataGrid.Coordinator.write(text) }
        }
        store.status = StatusMessage(kind: .success, text: "Copied \(d.rowCount.formatted()) row\(d.rowCount == 1 ? "" : "s") of \(table.name).")
    }

    private func copyColumn(_ column: String, in table: ModelTable) {
        guard let d = data, let gc = plan.columns.first(where: { $0.name == column }) else { return }
        let index = rowIndex(for: table, data: d)
        Task.detached(priority: .userInitiated) {
            let text = TableGrid.tsv(data: d, columns: [gc], rowIndex: index, headers: true)
            await MainActor.run { DataGrid.Coordinator.write(text) }
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

    private var actionBar: some View {
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
            if let table = currentTable {
                Button { copyTable(table) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the table as shown, tab-separated")
            }
            Spacer(minLength: Design.Space.s)
            if let table = currentTable, !gridState(for: table).isIdentity {
                Button("Clear sort & filters") { applyState(GridViewState(), for: table) }
                    .help("Show the table as stored")
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
    }

    // MARK: Contextual tools

    @ViewBuilder
    private var contextTools: some View {
        switch toolsContext {
        case .column(let column, let table):
            ColumnToolsRow(column: column, table: table).padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
        case .measure(let measure, let table):
            MeasureToolsRow(measure: measure, table: table).padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
        case .table(let table):
            TableToolsRow(table: table).padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
        case nil:
            EmptyView()
        }
    }

    private enum ToolsContext { case column(ModelColumn, String), measure(Measure, String), table(ModelTable) }

    /// What the tool strip edits: the picked column, measure or table; otherwise what the Data
    /// pane last focused; otherwise the table the grid shows.
    private var toolsContext: ToolsContext? {
        switch modeling.primary {
        case .column(let t, let n):
            guard let mt = store.model.table(t), let c = mt.column(n) else { return nil }
            return .column(c, mt.name)
        case .measure(let t, let n):
            guard let mt = store.model.table(t), let m = mt.measure(n) else { return nil }
            return .measure(m, mt.name)
        case .table(let t):
            return store.model.table(t).map { ToolsContext.table($0) }
        default:
            if let (t, n) = ModelingTarget.measure(store), let m = store.model.table(t)?.measure(n) { return .measure(m, t) }
            if let (t, n) = ModelingTarget.column(store), let c = store.model.table(t)?.column(n) { return .column(c, t) }
            return currentTable.map { ToolsContext.table($0) }
        }
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

    private func grid(_ table: ModelTable) -> some View {
        DataGrid(table: data, dataToken: plan.dataToken, columns: plan.columns,
                 rowIndex: rowIndex(for: table, data: data), indexToken: modeling.gridRevision,
                 selectedColumn: selectedColumn(in: table),
                 sortColumn: gridState(for: table).sortColumn, sortAscending: gridState(for: table).ascending,
                 onSelectColumn: { selectColumn($0, in: table) },
                 headerMenu: { headerMenu($0, in: table) },
                 filterEditor: { name, close in filterEditor(name, in: table, close: close) },
                 filterRequest: filterRequest)
    }

    private func selectedColumn(in table: ModelTable) -> String? {
        guard case .column(let t, let n) = modeling.primary, ModelDAX.same(t, table.name), let c = table.column(n) else { return nil }
        return c.name
    }

    private func headerMenu(_ column: String, in table: ModelTable) -> [ModelMenuEntry] {
        guard let c = table.column(column) else { return [] }
        return TableColumnMenu.entries(store: store, table: table, column: c,
                                       state: gridState(for: table),
                                       applyState: { applyState($0, for: table) },
                                       openFilter: { filterRequest = GridFilterRequest(column: column) },
                                       copyColumn: { copyColumn($0, in: table) })
    }

    private func filterEditor(_ column: String, in table: ModelTable, close: @escaping () -> Void) -> AnyView {
        let gc = plan.columns.first { $0.name == column }
        return TableFilterEditor.view(data: data,
                                      column: gc ?? GridColumn(name: column, type: .text, format: "", glyph: "tablecells"),
                                      current: gridState(for: table).filters[column],
                                      apply: { applyFilter(column, $0, for: table) },
                                      close: close)
    }

    // MARK: Status line

    private func statusLine(_ table: ModelTable) -> some View {
        let d = data
        let state = gridState(for: table)
        let total = d?.rowCount ?? 0
        let shown = rowIndex(for: table, data: d)?.count ?? total
        return HStack(spacing: Design.Space.s) {
            Text(total == 0 ? "No rows"
                 : shown == total ? "\(total.formatted()) row\(total == 1 ? "" : "s")"
                 : "\(shown.formatted()) of \(total.formatted()) rows")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit()
            Text("· \(plan.columns.count.formatted()) column\(plan.columns.count == 1 ? "" : "s")")
                .font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit()
            if table.storageMode != .import {
                Chip(ModelGlyph.label(for: table.storageMode))
            }
            if !state.isIdentity {
                Text("· sorted & filtered").font(Design.Typeface.caption).foregroundStyle(.tertiary)
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
