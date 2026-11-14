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

    private func menu(_ title: String, symbol: String = "", help: String, _ entries: [ModelMenuEntry]) -> some View {
        Menu {
            ModelMenuItems(entries: entries)
        } label: {
            if symbol.isEmpty { Text(title) } else { Label(title, systemImage: symbol) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
    }

    private var dataTypeMenu: some View {
        menu(column.dataType.displayName, symbol: ModelGlyph.symbol(for: column.dataType), help: "Data type",
             ColumnMenus.dataType(store, table: table, column: column))
    }

    private var summarizeByMenu: some View {
        menu(column.summarizeBy == .none ? "Summarize by" : column.summarizeBy.label(for: column.dataType),
             help: "Default summarization", ColumnMenus.summarizeBy(store, table: table, column: column))
    }

    private var categoryMenu: some View {
        menu(ModelGlyph.label(for: column.dataCategory), help: "Data category",
             ColumnMenus.dataCategory(store, table: table, column: column))
    }

    private var sortByMenu: some View {
        menu(column.sortByColumn ?? "Sort by column", help: "Sort this column by another column's order",
             store.model.table(table).map { ColumnMenus.sortBy(store, table: $0, column: column) } ?? [])
    }

    private func applyFormat(_ format: String) {
        ModelOps.updateColumns(store, [(table, name)], name: "Format Column", coalesce: "format-\(table)-\(name)") { $0.formatString = format }
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
            FormatControls(format: measure.formatString, dataType: .decimal,
                           dynamic: .init(isOn: measure.formatExpression != nil) { DynamicFormat.edit(store, table: table, measure: measure.name) },
                           apply: applyFormat)
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
            ModelMenuItems(entries: ColumnMenus.homeTable(store, table: table, measure: measure))
        } label: {
            Label(store.model.table(table)?.name ?? table, systemImage: "tablecells")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Home table")
    }

    /// A static format replaces a dynamic one, as choosing one does in Power BI.
    private func applyFormat(_ format: String) {
        ModelOps.updateMeasures(store, [(table, measure.name)], name: "Format Measure",
                                coalesce: "format-\(table)-\(measure.name)") { $0.formatString = format; $0.formatExpression = nil }
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
        [
            .submenu(title: "Data type", symbol: "textformat.123", entries: ColumnMenus.dataType(store, table: table.name, column: column)),
            .submenu(title: "Summarize by", entries: ColumnMenus.summarizeBy(store, table: table.name, column: column)),
            .submenu(title: "Data category", entries: ColumnMenus.dataCategory(store, table: table.name, column: column)),
            .submenu(title: "Sort by column", entries: ColumnMenus.sortBy(store, table: table, column: column)),
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
