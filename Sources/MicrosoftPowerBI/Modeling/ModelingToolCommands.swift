import SwiftUI
import FacetCore

/// The Table tools, Column tools and Measure tools commands the ribbon shows for the selected
/// table, column or measure in Table view and Model view. They act on `ModelingTarget`; commands
/// that offer a choice (data type, format, sort by column…) open it as a menu at the pointer,
/// built by the same `ColumnMenus` the Table view and the Model view use.
@MainActor
enum ModelingToolCommands {
    private static func table(_ store: DocumentStore) -> ModelTable? {
        ModelingTarget.table(store).flatMap { store.model.table($0) }
    }
    private static func column(_ store: DocumentStore) -> (table: ModelTable, column: ModelColumn)? {
        guard let (t, n) = ModelingTarget.column(store), let table = store.model.table(t), let column = table.column(n) else { return nil }
        return (table, column)
    }
    private static func measure(_ store: DocumentStore) -> (table: ModelTable, measure: Measure)? {
        guard let (t, n) = ModelingTarget.measure(store), let table = store.model.table(t), let measure = table.measure(n) else { return nil }
        return (table, measure)
    }

    private static func command(_ id: String, _ title: String, _ symbol: String, separator: Bool = false,
                                enabled: @escaping @MainActor (DocumentStore) -> Bool,
                                isOn: (@MainActor (DocumentStore) -> Bool)? = nil,
                                run: @escaping @MainActor (DocumentStore) -> Void) -> AppCommand {
        AppCommand(id: id, title: title, menu: .modeling, symbol: symbol, separatorBefore: separator, isEnabled: enabled, isOn: isOn, run: run)
    }

    static var commands: [AppCommand] { tableCommands + columnCommands + measureCommands }

    // MARK: Table tools

    private static var tableCommands: [AppCommand] {
        let has: @MainActor (DocumentStore) -> Bool = { table($0) != nil }
        return [
            command("model.table.rename", "Rename Table…", "pencil", separator: true, enabled: has) { store in
                guard let t = table(store), let new = ModelPrompt.text(title: "Rename table", value: t.name) else { return }
                ModelOps.renameTable(store, t.name, to: new)
            },
            command("model.table.hide", "Hide Table in Report View", "eye.slash", enabled: has, isOn: { table($0)?.isHidden == true }) { store in
                if let t = table(store) { ModelOps.toggleHidden(store, .table(t.name)) }
            },
            command("model.table.refresh", "Refresh Table", "arrow.triangle.2.circlepath", enabled: { table($0)?.sourceQuery != nil }) { store in
                if let query = table(store)?.sourceQuery { store.refreshData(only: [query]) }
            },
            command("model.table.editFormula", "Edit Table Formula", "square.and.pencil", enabled: { table($0)?.isCalculated == true }) { store in
                if let t = table(store) { ModelOps.beginFormula(store, kind: .table, editing: t.name) }
            },
            command("model.table.delete", "Delete Table…", "trash", enabled: has) { store in
                guard let t = table(store),
                      ModelPrompt.confirm(title: "Delete “\(t.name)” from the model?",
                                          message: "Its columns, measures and relationships are removed too. You can undo this.") else { return }
                ModelOps.delete(store, [.table(t.name)])
            },
        ]
    }

    // MARK: Column tools

    private static var columnCommands: [AppCommand] {
        let has: @MainActor (DocumentStore) -> Bool = { column($0) != nil }
        func choice(_ id: String, _ title: String, _ symbol: String, separator: Bool = false,
                    _ entries: @escaping @MainActor (DocumentStore, ModelTable, ModelColumn) -> [ModelMenuEntry]) -> AppCommand {
            command(id, title, symbol, separator: separator, enabled: has) { store in
                if let (t, c) = column(store) { ModelMenuEntry.popUp(entries(store, t, c)) }
            }
        }
        return [
            choice("model.column.dataType", "Data Type", "textformat.123", separator: true) { ColumnMenus.dataType($0, table: $1.name, column: $2) },
            choice("model.column.format", "Column Format", "number") { store, t, c in
                ColumnMenus.format(current: c.formatString) { format in
                    ModelOps.updateColumns(store, [(t.name, c.name)], name: "Format Column") { $0.formatString = format }
                }
            },
            choice("model.column.summarizeBy", "Summarize By", "sum") { ColumnMenus.summarizeBy($0, table: $1.name, column: $2) },
            choice("model.column.dataCategory", "Data Category", "mappin.and.ellipse") { ColumnMenus.dataCategory($0, table: $1.name, column: $2) },
            choice("model.sortByColumn", "Sort by Column", "arrow.up.arrow.down") { ColumnMenus.sortBy($0, table: $1, column: $2) },
            command("model.column.hide", "Hide Column in Report View", "eye.slash", enabled: has, isOn: { column($0)?.column.isHidden == true }) { store in
                if let (t, c) = column(store) { ModelOps.toggleHidden(store, .column(table: t.name, name: c.name)) }
            },
            command("model.column.rename", "Rename Column…", "pencil", enabled: has) { store in
                guard let (t, c) = column(store), let new = ModelPrompt.text(title: "Rename column", value: c.name) else { return }
                ModelOps.renameColumn(store, table: t.name, c.name, to: new)
            },
            command("model.column.editFormula", "Edit Column Formula", "square.and.pencil", enabled: { column($0)?.column.isCalculated == true }) { store in
                if let (t, c) = column(store) { ModelOps.beginFormula(store, kind: .column, table: t.name, editing: c.name) }
            },
            command("model.column.delete", "Delete Column…", "trash", enabled: has) { store in
                guard let (t, c) = column(store),
                      ModelPrompt.confirm(title: "Delete “\(c.name)”?", message: "Relationships on this column are removed too. You can undo this.") else { return }
                ModelOps.delete(store, [.column(table: t.name, name: c.name)])
            },
        ]
    }

    // MARK: Measure tools

    private static var measureCommands: [AppCommand] {
        let has: @MainActor (DocumentStore) -> Bool = { measure($0) != nil }
        return [
            command("model.measure.edit", "Edit Measure Formula", "square.and.pencil", separator: true, enabled: has) { store in
                if let (t, m) = measure(store) { ModelOps.beginFormula(store, kind: .measure, table: t.name, editing: m.name) }
            },
            command("model.measure.format", "Measure Format", "number", enabled: has) { store in
                guard let (t, m) = measure(store) else { return }
                ModelMenuEntry.popUp(ColumnMenus.format(current: m.formatString) { format in
                    ModelOps.updateMeasures(store, [(t.name, m.name)], name: "Format Measure") { $0.formatString = format }
                })
            },
            command("model.measure.homeTable", "Home Table", "tablecells", enabled: has) { store in
                if let (t, m) = measure(store) { ModelMenuEntry.popUp(ColumnMenus.homeTable(store, table: t.name, measure: m)) }
            },
            command("model.measure.hide", "Hide Measure in Report View", "eye.slash", enabled: has, isOn: { measure($0)?.measure.isHidden == true }) { store in
                if let (t, m) = measure(store) { ModelOps.toggleHidden(store, .measure(table: t.name, name: m.name)) }
            },
            command("model.measure.rename", "Rename Measure…", "pencil", enabled: has) { store in
                guard let (t, m) = measure(store), let new = ModelPrompt.text(title: "Rename measure", value: m.name) else { return }
                ModelOps.renameMeasure(store, table: t.name, m.name, to: new)
            },
            command("model.measure.delete", "Delete Measure…", "trash", enabled: has) { store in
                guard let (t, m) = measure(store),
                      ModelPrompt.confirm(title: "Delete “\(m.name)”?", message: "You can undo this.") else { return }
                ModelOps.delete(store, [.measure(table: t.name, name: m.name)])
            },
        ]
    }
}

extension FormatComposer {
    /// The format with `delta` more (or fewer) decimal places, between 0 and 10. A whole number
    /// gaining a place becomes a decimal number; a decimal number losing its last becomes whole.
    /// Formats without decimal places (dates, custom, general) are returned unchanged.
    static func adjustingDecimals(of format: String, by delta: Int) -> String {
        var c = FormatComposer(format)
        guard c.supportsDecimals || c.kind == .whole else { return format }
        c.decimals = max(0, min(10, c.decimals + delta))
        if c.kind == .whole, c.decimals > 0 { c.kind = .decimal }
        else if c.kind == .decimal, c.decimals == 0 { c.kind = .whole }
        return c.formatString
    }

    /// The format with the thousands separator switched, where the format has one to switch.
    static func togglingThousands(of format: String) -> String {
        var c = FormatComposer(format)
        guard c.supportsThousands else { return format }
        c.thousands.toggle()
        return c.formatString
    }
}

extension ColumnMenus {
    /// The format choices as a menu: the presets `FormatControls` offers, plus decimal places and
    /// the thousands separator.
    static func format(current: String, apply: @escaping (String) -> Void) -> [ModelMenuEntry] {
        let c = FormatComposer(current)
        func preset(_ title: String, _ kind: FormatComposer.Kind, _ change: @escaping (inout FormatComposer) -> Void) -> ModelMenuEntry {
            .item(title: title, checked: c.kind == kind) {
                var next = c
                next.kind = kind
                change(&next)
                apply(next.formatString)
            }
        }
        return [
            .item(title: "General", checked: c.kind == .general) { apply("") },
            .separator,
            preset("Whole number", .whole) { $0.decimals = 0 },
            preset("Decimal number", .decimal) { $0.decimals = max(2, c.decimals) },
            .submenu(title: "Currency", entries: FormatComposer.currencySymbols.map { symbol in
                .item(title: symbol, checked: c.kind == .currency && c.symbol == symbol) {
                    var next = c
                    next.decimals = c.kind == .currency ? c.decimals : 2
                    next.kind = .currency; next.symbol = symbol; next.thousands = true
                    apply(next.formatString)
                }
            }),
            preset("Percentage", .percentage) { $0.decimals = c.kind == .percentage ? c.decimals : 1 },
            .item(title: "Scientific", checked: c.kind == .scientific) { apply("Scientific") },
            .separator,
            .submenu(title: "Date", entries: FormatComposer.dateFormats.map { f in
                .item(title: f.title, checked: current.lowercased() == f.format.lowercased()) { apply(f.format) }
            }),
            .submenu(title: "Time", entries: FormatComposer.timeFormats.map { f in
                .item(title: f.title, checked: current.lowercased() == f.format.lowercased()) { apply(f.format) }
            }),
            .separator,
            .item(title: "More decimal places", enabled: (c.supportsDecimals || c.kind == .whole) && c.decimals < 10) {
                apply(FormatComposer.adjustingDecimals(of: current, by: 1))
            },
            .item(title: "Fewer decimal places", enabled: c.supportsDecimals && c.decimals > 0) {
                apply(FormatComposer.adjustingDecimals(of: current, by: -1))
            },
            .item(title: "Thousands separator", enabled: c.supportsThousands, checked: c.supportsThousands && c.thousands) {
                apply(FormatComposer.togglingThousands(of: current))
            },
        ]
    }
}
