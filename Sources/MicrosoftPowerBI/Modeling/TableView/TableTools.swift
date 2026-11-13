import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Column tools

/// Data type, format, summarization, data category, sort-by-column and visibility for the
/// selected column — the Table view's "Column tools" strip.
struct ColumnToolsRow: View {
    @EnvironmentObject private var store: DocumentStore
    let column: ModelColumn
    let table: String

    private var name: String { column.name }

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Text("Column tools").font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
            Hairline(vertical: true).frame(height: 14).padding(.horizontal, Design.Space.xxs)
            dataTypeMenu
            FormatControls(format: column.formatString, dataType: column.dataType, apply: applyFormat)
            summarizeByMenu
            categoryMenu
            sortByMenu
            IconButton(column.isHidden ? "eye" : "eye.slash",
                       help: column.isHidden ? "Unhide in report view" : "Hide in report view") {
                ModelOps.toggleHidden(store, .column(table: table, name: name))
            }
        }
        .controlSize(.small)
    }

    private func set(_ undoName: String, coalesce: String? = nil, _ change: @escaping (inout ModelColumn) -> Void) {
        ModelOps.updateColumns(store, [(table, name)], name: undoName, coalesce: coalesce, change)
    }

    private var dataTypeMenu: some View {
        Menu {
            ForEach(DataType.allCases, id: \.self) { t in
                Button(t.displayName) { ModelOps.changeDataType(store, table: table, column: name, to: t) }
            }
        } label: {
            Label(column.dataType.displayName, systemImage: ModelGlyph.symbol(for: column.dataType))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Data type")
    }

    private var summarizeByMenu: some View {
        Menu {
            Button(Aggregation.none.displayName) { set("Summarize By") { $0.summarizeBy = .none } }
            Divider()
            ForEach(Aggregation.valid(for: column.dataType), id: \.self) { a in
                Button(a.label(for: column.dataType)) { set("Summarize By") { $0.summarizeBy = a } }
            }
        } label: {
            Text(column.summarizeBy == .none ? "Summarize by" : column.summarizeBy.label(for: column.dataType))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Default summarization")
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(DataCategory.allCases, id: \.self) { c in
                Button(ModelGlyph.label(for: c)) { set("Change Data Category") { $0.dataCategory = c } }
            }
        } label: {
            Text(ModelGlyph.label(for: column.dataCategory))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Data category")
    }

    private var sortByMenu: some View {
        Menu {
            Button("Default") { set("Sort by Column") { $0.sortByColumn = nil } }
            Divider()
            if let t = store.model.table(table) {
                ForEach(TableGrid.sortByCandidates(for: column, in: t)) { other in
                    Button(other.name) { set("Sort by Column") { $0.sortByColumn = other.name } }
                }
            }
        } label: {
            Text(column.sortByColumn ?? "Sort by column")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort this column by another column's order")
    }

    private func applyFormat(_ format: String) {
        set("Format Column", coalesce: "format-\(table)-\(name)") { $0.formatString = format }
    }
}

// MARK: - Measure tools

/// Format, home table, edit and visibility for the selected measure — the "Measure tools" strip.
struct MeasureToolsRow: View {
    @EnvironmentObject private var store: DocumentStore
    let measure: Measure
    let table: String

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Text("Measure tools").font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
            Hairline(vertical: true).frame(height: 14).padding(.horizontal, Design.Space.xxs)
            FormatControls(format: measure.formatString, dataType: .decimal, apply: applyFormat)
            homeTableMenu
            IconButton("square.and.pencil", help: "Edit in the formula bar") {
                ModelOps.beginFormula(store, kind: .measure, table: table, editing: measure.name)
            }
            IconButton(measure.isHidden ? "eye" : "eye.slash",
                       help: measure.isHidden ? "Unhide in report view" : "Hide in report view") {
                ModelOps.toggleHidden(store, .measure(table: table, name: measure.name))
            }
        }
        .controlSize(.small)
    }

    private var homeTableMenu: some View {
        Menu {
            ForEach(store.model.tables.filter { !ModelDAX.same($0.name, table) }) { t in
                Button(t.name) { ModelOps.moveMeasure(store, name: measure.name, from: table, to: t.name) }
            }
        } label: {
            Label(store.model.table(table)?.name ?? table, systemImage: "tablecells")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Home table")
    }

    private func applyFormat(_ format: String) {
        ModelOps.updateMeasures(store, [(table, measure.name)], name: "Format Measure",
                                coalesce: "format-\(table)-\(measure.name)") { $0.formatString = format }
    }
}

// MARK: - Table tools

/// Rename, visibility, copy, refresh and delete for the table shown in the grid.
struct TableToolsRow: View {
    @EnvironmentObject private var store: DocumentStore
    let table: ModelTable

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Text("Table tools").font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
            Hairline(vertical: true).frame(height: 14).padding(.horizontal, Design.Space.xxs)
            Button("Rename…") { rename() }.buttonStyle(.link)
            IconButton(table.isHidden ? "eye" : "eye.slash",
                       help: table.isHidden ? "Unhide in report view" : "Hide in report view") {
                ModelOps.toggleHidden(store, .table(table.name))
            }
            if let query = table.sourceQuery {
                Button { store.refreshData(only: [query]) } label: { Label("Refresh data", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Re-run the Power Query query that loads this table")
            }
            Button("Delete…", role: .destructive) { delete() }.buttonStyle(.link)
        }
        .controlSize(.small)
    }

    private func rename() {
        guard let new = ModelPrompt.text(title: "Rename table", value: table.name) else { return }
        ModelOps.renameTable(store, table.name, to: new)
    }

    private func delete() {
        guard ModelPrompt.confirm(title: "Delete “\(table.name)” from the model?",
                                  message: "Its columns, measures and relationships are removed too. You can undo this.",
                                  confirm: "Delete") else { return }
        ModelOps.delete(store, [.table(table.name)])
    }
}

// MARK: - Header menu

/// The context menu for one grid column header in Table view.
@MainActor
enum TableColumnMenu {
    static func entries(store: DocumentStore, table: ModelTable, column: ModelColumn,
                        state: GridViewState,
                        applyState: @escaping (GridViewState) -> Void,
                        openFilter: @escaping () -> Void,
                        copyColumn: @escaping (String) -> Void) -> [ModelMenuEntry] {
        let name = column.name
        var items: [ModelMenuEntry] = [
            .item(title: "Sort ascending", symbol: "arrow.up", checked: state.sortColumn == name && state.ascending) {
                var s = state; s.sortColumn = name; s.ascending = true; applyState(s)
            },
            .item(title: "Sort descending", symbol: "arrow.down", checked: state.sortColumn == name && !state.ascending) {
                var s = state; s.sortColumn = name; s.ascending = false; applyState(s)
            },
            .item(title: "Clear sort", enabled: state.sortColumn != nil) {
                var s = state; s.sortColumn = nil; applyState(s)
            },
            .item(title: "Filter…", symbol: "line.3.horizontal.decrease", checked: state.filters[name]?.isActive == true) {
                openFilter()
            },
            .separator,
            .item(title: "Copy column", symbol: "doc.on.doc") { copyColumn(name) },
            .separator,
        ]
        items.append(contentsOf: propertyMenus(store: store, table: table, column: column))
        items.append(contentsOf: objectMenus(store: store, table: table, column: column))
        return items
    }

    private static func propertyMenus(store: DocumentStore, table: ModelTable, column: ModelColumn) -> [ModelMenuEntry] {
        let name = column.name
        var summarize: [ModelMenuEntry] = [.item(title: Aggregation.none.displayName, checked: column.summarizeBy == .none) {
            ModelOps.updateColumns(store, [(table.name, name)], name: "Summarize By") { $0.summarizeBy = .none }
        }]
        summarize += Aggregation.valid(for: column.dataType).map { a in
            .item(title: a.label(for: column.dataType), checked: column.summarizeBy == a) {
                ModelOps.updateColumns(store, [(table.name, name)], name: "Summarize By") { $0.summarizeBy = a }
            }
        }
        return [
            .submenu(title: "Data type", symbol: "textformat.123", entries: DataType.allCases.map { t in
                .item(title: t.displayName, checked: column.dataType == t) {
                    ModelOps.changeDataType(store, table: table.name, column: name, to: t)
                }
            }),
            .submenu(title: "Summarize by", entries: summarize),
            .submenu(title: "Data category", entries: DataCategory.allCases.map { c in
                .item(title: ModelGlyph.label(for: c), checked: column.dataCategory == c) {
                    ModelOps.updateColumns(store, [(table.name, name)], name: "Change Data Category") { $0.dataCategory = c }
                }
            }),
            .submenu(title: "Sort by column", entries: [.item(title: "Default", checked: column.sortByColumn == nil) {
                ModelOps.updateColumns(store, [(table.name, name)], name: "Sort by Column") { $0.sortByColumn = nil }
            }] + TableGrid.sortByCandidates(for: column, in: table).map { other in
                .item(title: other.name, checked: ModelDAX.same(column.sortByColumn ?? "", other.name)) {
                    ModelOps.updateColumns(store, [(table.name, name)], name: "Sort by Column") { $0.sortByColumn = other.name }
                }
            }),
            .separator,
        ]
    }

    private static func objectMenus(store: DocumentStore, table: ModelTable, column: ModelColumn) -> [ModelMenuEntry] {
        let name = column.name
        return [
            .item(title: "New measure", symbol: "function") { ModelOps.beginFormula(store, kind: .measure, table: table.name) },
            .item(title: "New column", symbol: "tablecells") { ModelOps.beginFormula(store, kind: .column, table: table.name) },
            .separator,
            .item(title: "Rename…") {
                if let new = ModelPrompt.text(title: "Rename column", value: name) {
                    ModelOps.renameColumn(store, table: table.name, name, to: new)
                }
            },
            .item(title: column.isHidden ? "Unhide" : "Hide", symbol: column.isHidden ? "eye" : "eye.slash") {
                ModelOps.toggleHidden(store, .column(table: table.name, name: name))
            },
            .item(title: "Delete…", symbol: "trash") {
                if ModelPrompt.confirm(title: "Delete “\(name)”?", message: "You can undo this.") {
                    ModelOps.delete(store, [.column(table: table.name, name: name)])
                }
            },
        ]
    }
}

/// Builds the filter popover the grid shows for one column. Filters are view-only: they shape
/// what the grid shows and are never written to the document.
@MainActor
enum TableFilterEditor {
    static func view(data: DataTable?, column: GridColumn, current: GridColumnFilter?,
                     apply: @escaping (GridColumnFilter?) -> Void, close: @escaping () -> Void) -> AnyView {
        var values: [Value] = []
        if let data, let di = column.dataIndex, data.columns.indices.contains(di) { values = data.columns[di].values }
        return AnyView(GridFilterEditor(columnName: column.name, type: column.type, format: column.format,
                                        values: values, current: current, apply: apply, close: close))
    }
}
