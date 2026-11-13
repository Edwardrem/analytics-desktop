import SwiftUI
import AppKit
import FacetCore

/// The one set of menu builders for a column's properties. The Table view's tool strip, its grid
/// header menu, the Model view and the ribbon commands all show these, so the choices and what
/// they do can't drift apart.
@MainActor
enum ColumnMenus {
    static func dataType(_ store: DocumentStore, table: String, column: ModelColumn) -> [ModelMenuEntry] {
        DataType.allCases.map { t in
            .item(title: t.displayName, symbol: ModelGlyph.symbol(for: t), checked: column.dataType == t) {
                ModelOps.changeDataType(store, table: table, column: column.name, to: t)
            }
        }
    }

    static func summarizeBy(_ store: DocumentStore, table: String, column: ModelColumn) -> [ModelMenuEntry] {
        let name = column.name
        var entries: [ModelMenuEntry] = [.item(title: Aggregation.none.displayName, checked: column.summarizeBy == .none) {
            ModelOps.updateColumns(store, [(table, name)], name: "Summarize By") { $0.summarizeBy = .none }
        }, .separator]
        entries += Aggregation.valid(for: column.dataType).map { a in
            .item(title: a.label(for: column.dataType), checked: column.summarizeBy == a) {
                ModelOps.updateColumns(store, [(table, name)], name: "Summarize By") { $0.summarizeBy = a }
            }
        }
        return entries
    }

    static func dataCategory(_ store: DocumentStore, table: String, column: ModelColumn) -> [ModelMenuEntry] {
        let name = column.name
        return DataCategory.allCases.map { c in
            .item(title: ModelGlyph.label(for: c), checked: column.dataCategory == c) {
                ModelOps.updateColumns(store, [(table, name)], name: "Change Data Category") { $0.dataCategory = c }
            }
        }
    }

    static func sortBy(_ store: DocumentStore, table: ModelTable, column: ModelColumn) -> [ModelMenuEntry] {
        let name = column.name
        var entries: [ModelMenuEntry] = [.item(title: "Default", checked: column.sortByColumn == nil) {
            ModelOps.setSortByColumn(store, table: table.name, column: name, by: nil)
        }, .separator]
        entries += TableGrid.sortByCandidates(for: column, in: table).map { other in
            .item(title: other.name, checked: ModelDAX.same(column.sortByColumn ?? "", other.name)) {
                ModelOps.setSortByColumn(store, table: table.name, column: name, by: other.name)
            }
        }
        return entries
    }

    static func homeTable(_ store: DocumentStore, table: String, measure: Measure) -> [ModelMenuEntry] {
        store.model.tables.map { t in
            .item(title: t.name, symbol: ModelGlyph.symbol(for: t), checked: ModelDAX.same(t.name, table)) {
                ModelOps.moveMeasure(store, name: measure.name, from: table, to: t.name)
            }
        }
    }
}

/// Renders menu entries inside a SwiftUI `Menu`.
struct ModelMenuItems: View {
    let entries: [ModelMenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            row(entry)
        }
    }

    private func row(_ entry: ModelMenuEntry) -> AnyView {
        switch entry {
        case .separator:
            return AnyView(Divider())
        case .item(let title, let symbol, let enabled, let checked, let action):
            return AnyView(Button(action: action) {
                if checked { Label(title, systemImage: "checkmark") }
                else if !symbol.isEmpty { Label(title, systemImage: symbol) }
                else { Text(title) }
            }.disabled(!enabled))
        case .submenu(let title, _, let entries):
            return AnyView(Menu(title) { ModelMenuItems(entries: entries) })
        }
    }
}

extension ModelMenuEntry {
    /// Shows the entries as a pop-up menu at the pointer — how a ribbon command offers a choice.
    @MainActor
    static func popUp(_ entries: [ModelMenuEntry]) {
        let menu = NSMenu()
        build(entries, into: menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
