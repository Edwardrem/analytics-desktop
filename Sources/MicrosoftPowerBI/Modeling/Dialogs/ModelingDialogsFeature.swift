import SwiftUI
import FacetCore

/// Commands that open the modeling dialogs. Registered from `ModelingFeature.register()`.
@MainActor
enum ModelingDialogsFeature {
    static func register() {
        AppCommands.register { commands }
        // Commands run from the Data pane's context menus act on the table or field that was
        // right-clicked: `ModelingFeature.register()` wires `ModelingTarget` to that context, per document.
    }

    private static let hasTables: @MainActor (DocumentStore) -> Bool = { !$0.model.tables.isEmpty }

    static var commands: [AppCommand] { groupA + groupB }

    // MARK: Relationships, security, parameters, hierarchies, groups, date tables

    static var groupA: [AppCommand] {
        [
            AppCommand(id: "model.relationships", title: "Manage Relationships…", menu: .modeling, symbol: "arrow.left.arrow.right",
                       separatorBefore: true, isEnabled: { $0.model.tables.count >= 2 }) { store in
                store.present { RelationshipsSheet() }
            },
            AppCommand(id: "model.autodetectRelationships", title: "Autodetect Relationships", menu: .modeling, symbol: "sparkle.magnifyingglass",
                       isEnabled: { $0.model.tables.count >= 2 }) { RelationshipOps.autodetect($0) },
            AppCommand(id: "model.newParameter", title: "New Parameter…", menu: .modeling, symbol: "slider.horizontal.3",
                       separatorBefore: true) { store in
                store.present { ParametersSheet() }
            },
            AppCommand(id: "model.newFieldParameter", title: "New Field Parameter…", menu: .modeling, symbol: "list.bullet.rectangle",
                       isEnabled: hasTables) { store in
                store.present { ParametersSheet(page: .fields) }
            },
            AppCommand(id: "model.roles", title: "Manage Roles…", menu: .modeling, symbol: "lock.shield",
                       separatorBefore: true, isEnabled: hasTables) { store in
                store.present { RolesSheet(model: store.model) }
            },
            AppCommand(id: "model.viewAs", title: "View As…", menu: .modeling, symbol: "person.crop.rectangle",
                       isEnabled: hasTables, isOn: { !$0.viewAsRoles.isEmpty || !$0.viewAsUser.isEmpty }) { store in
                store.present { ViewAsSheet(roles: store.viewAsRoles, user: store.viewAsUser) }
            },
            AppCommand(id: "model.newHierarchy", title: "New Hierarchy…", menu: .modeling, symbol: "list.bullet.indent",
                       separatorBefore: true, isEnabled: hasTables) { store in
                let column = DialogTarget.column(store)
                guard let table = (column?.table ?? DialogTarget.table(store)).flatMap(store.model.table) else { return }
                store.present { HierarchiesSheet(table: table, startingFrom: column?.name ?? table.columns.first?.name) }
            },
            AppCommand(id: "model.hierarchies", title: "Manage Hierarchies…", menu: .modeling, symbol: "list.bullet.indent",
                       isEnabled: hasTables) { store in
                guard let table = DialogTarget.table(store).flatMap(store.model.table) else { return }
                store.present { HierarchiesSheet(table: table) }
            },
            AppCommand(id: "model.newGroup", title: "New Group…", menu: .modeling, symbol: "square.stack.3d.up",
                       isEnabled: { ModelingDialogsFeature.groupTarget($0) != nil }) { store in
                guard let (table, source, existing) = groupTarget(store) else { return }
                store.present { GroupsSheet(table: table, source: source, existing: existing) }
            },
            AppCommand(id: "model.markDateTable", title: "Mark as Date Table…", menu: .modeling, symbol: "calendar",
                       separatorBefore: true, isEnabled: hasTables) { store in
                guard let table = DialogTarget.table(store).flatMap(store.model.table) else { return }
                store.present { DateTableSheet(table: table) }
            },
            AppCommand(id: "model.calendars", title: "Calendars…", menu: .modeling, symbol: "calendar.badge.clock",
                       isEnabled: hasTables) { store in
                guard let table = DialogTarget.table(store).flatMap(store.model.table) else { return }
                store.present { CalendarsSheet(table: table) }
            },
            AppCommand(id: "model.editMeasure", title: "Edit Measure", menu: .modeling, symbol: "function",
                       isEnabled: { DialogTarget.measure($0) != nil }) { store in
                guard let m = DialogTarget.measure(store) else { return }
                ModelOps.beginFormula(store, kind: .measure, table: m.table, editing: m.name)
            },
        ]
    }

    /// The column a group is made from: the selected column, or (when a group column is selected) its source, for editing.
    static func groupTarget(_ store: DocumentStore) -> (table: ModelTable, source: ModelColumn, existing: ModelColumn?)? {
        guard let c = DialogTarget.column(store), let table = store.model.table(c.table), let column = table.column(c.name) else { return nil }
        if let g = column.grouping {
            guard let source = table.column(g.sourceColumn) else { return nil }
            return (table, source, column)
        }
        if column.dataType == .binary { return nil }
        return (table, column, nil)
    }

    // MARK: Calculation groups, functions, storage, metadata, AI

    static var groupB: [AppCommand] {
        [
            AppCommand(id: "model.calculationGroups", title: "Calculation Groups…", menu: .modeling, symbol: "square.stack.3d.up",
                       separatorBefore: true, isEnabled: hasTables) { store in
                store.present { CalculationGroupsSheet(model: store.model) }
            },
            AppCommand(id: "model.functions", title: "Functions…", menu: .modeling, symbol: "curlybraces") { store in
                store.present { FunctionsSheet(model: store.model) }
            },
            AppCommand(id: "model.incrementalRefresh", title: "Incremental Refresh…", menu: .modeling, symbol: "arrow.triangle.2.circlepath",
                       separatorBefore: true, isEnabled: hasTables) { store in
                guard let table = DialogTarget.table(store).flatMap(store.model.table) else { return }
                store.present { IncrementalRefreshSheet(table: table) }
            },
            AppCommand(id: "model.aggregations", title: "Manage Aggregations…", menu: .modeling, symbol: "sum",
                       isEnabled: { $0.model.tables.count >= 2 }) { store in
                let table = DialogTarget.table(store)
                store.present { AggregationsSheet(model: store.model, table: table) }
            },
            AppCommand(id: "model.perspectives", title: "Perspectives…", menu: .modeling, symbol: "eye",
                       separatorBefore: true, isEnabled: hasTables) { store in
                store.present { PerspectivesSheet(model: store.model) }
            },
            AppCommand(id: "model.translations", title: "Translations…", menu: .modeling, symbol: "globe", isEnabled: hasTables) { store in
                store.present { TranslationsSheet(model: store.model) }
            },
            AppCommand(id: "model.synonyms", title: "Synonyms…", menu: .modeling, symbol: "character.book.closed", isEnabled: hasTables) { store in
                store.present { SynonymsSheet(model: store.model) }
            },
            AppCommand(id: "model.prepForAI", title: "Prep Data for AI…", menu: .modeling, symbol: "sparkles", isEnabled: hasTables) { store in
                store.present { AIPrepSheet(model: store.model) }
            },
        ]
    }
}
