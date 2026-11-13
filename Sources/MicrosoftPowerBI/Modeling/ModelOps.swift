import SwiftUI
import FacetCore

/// Named, undoable operations on the semantic model. Everything goes through `store.mutate`.
@MainActor
enum ModelOps {
    // MARK: Names

    static func uniqueName(_ base: String, among existing: [String]) -> String {
        if !existing.contains(where: { ModelDAX.same($0, base) }) { return base }
        var n = 2
        while existing.contains(where: { ModelDAX.same($0, "\(base) \(n)") }) { n += 1 }
        return "\(base) \(n)"
    }
    static func allMeasureNames(_ model: SemanticModel) -> [String] { model.allMeasures.map(\.measure.name) }

    /// Why a name can't be used, or nil when it is fine.
    static func nameProblem(_ name: String, kind: FormulaEdit.Kind, table: String, original: String?, model: SemanticModel) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the \(kind.noun) a name before the equals sign." }
        if name.contains("[") || name.contains("]") { return "Names can't contain square brackets." }
        if let original, ModelDAX.same(original, name) { return nil }
        switch kind {
        case .measure:
            if model.measure(name) != nil { return "A measure named “\(name)” already exists." }
            if model.table(table)?.column(name) != nil { return "“\(name)” is already a column in \(table)." }
        case .column:
            if model.table(table)?.column(name) != nil { return "A column named “\(name)” already exists in \(table)." }
            if model.table(table)?.measure(name) != nil { return "“\(name)” is already a measure in \(table)." }
        case .table:
            if model.table(name) != nil { return "A table named “\(name)” already exists." }
        }
        return nil
    }

    // MARK: Generic property edits

    static func updateTable(_ store: DocumentStore, _ table: String, name: String = "Change Table",
                            invalidates: Invalidation = .model, _ body: (inout ModelTable) -> Void) {
        store.mutate(name, invalidates: invalidates) { d in
            guard let i = d.model.tableIndex(table) else { return }
            body(&d.model.tables[i])
        }
    }
    static func updateColumns(_ store: DocumentStore, _ refs: [(table: String, name: String)], name: String = "Change Column",
                              coalesce: String? = nil, invalidates: Invalidation = .model, _ body: (inout ModelColumn) -> Void) {
        store.mutate(name, coalesce: coalesce, invalidates: invalidates) { d in
            for r in refs {
                guard let t = d.model.tableIndex(r.table),
                      let c = d.model.tables[t].columns.firstIndex(where: { ModelDAX.same($0.name, r.name) }) else { continue }
                body(&d.model.tables[t].columns[c])
            }
        }
    }
    static func updateMeasures(_ store: DocumentStore, _ refs: [(table: String, name: String)], name: String = "Change Measure",
                               coalesce: String? = nil, invalidates: Invalidation = .model, _ body: (inout Measure) -> Void) {
        store.mutate(name, coalesce: coalesce, invalidates: invalidates) { d in
            for r in refs {
                guard let t = d.model.tableIndex(r.table),
                      let m = d.model.tables[t].measures.firstIndex(where: { ModelDAX.same($0.name, r.name) }) else { continue }
                body(&d.model.tables[t].measures[m])
            }
        }
    }
    static func updateRelationships(_ store: DocumentStore, _ ids: [UUID], name: String = "Change Relationship",
                                    _ body: (inout Relationship) -> Void) {
        store.updateModel(name) { m in
            for i in m.relationships.indices where ids.contains(m.relationships[i].id) { body(&m.relationships[i]) }
        }
    }

    // MARK: Expression and report fix-ups

    /// Applies `transform` to every DAX expression in the model, passing the expression's home table.
    static func mapExpressions(_ m: inout SemanticModel, _ transform: (_ expr: String, _ home: String?) -> String) {
        for t in m.tables.indices {
            let home = m.tables[t].name
            if let e = m.tables[t].expression { m.tables[t].expression = transform(e, nil) }
            for c in m.tables[t].columns.indices {
                if let e = m.tables[t].columns[c].expression { m.tables[t].columns[c].expression = transform(e, home) }
            }
            for k in m.tables[t].measures.indices {
                m.tables[t].measures[k].expression = transform(m.tables[t].measures[k].expression, home)
                if let f = m.tables[t].measures[k].formatExpression { m.tables[t].measures[k].formatExpression = transform(f, home) }
            }
        }
        for g in m.calculationGroups.indices {
            for i in m.calculationGroups[g].items.indices {
                m.calculationGroups[g].items[i].expression = transform(m.calculationGroups[g].items[i].expression, nil)
                if let f = m.calculationGroups[g].items[i].formatExpression { m.calculationGroups[g].items[i].formatExpression = transform(f, nil) }
            }
        }
        for f in m.functions.indices { m.functions[f].expression = transform(m.functions[f].expression, nil) }
        for r in m.roles.indices {
            m.roles[r].tableFilters = Dictionary(uniqueKeysWithValues: m.roles[r].tableFilters.map { ($0.key, transform($0.value, $0.key)) })
        }
    }

    /// Applies `body` to every field reference stored in the report and in field parameters.
    static func mapFieldRefs(_ d: inout FacetDocument, _ body: (inout FieldRef) -> Void) {
        func mapFilters(_ filters: inout [FilterSpec]) {
            for i in filters.indices {
                body(&filters[i].field)
                if var by = filters[i].topN.by { body(&by); filters[i].topN.by = by }
            }
        }
        mapFilters(&d.report.filters)
        for p in d.report.pages.indices {
            mapFilters(&d.report.pages[p].filters)
            mapFilters(&d.report.pages[p].drillthroughFilters)
            for v in d.report.pages[p].visuals.indices {
                for key in d.report.pages[p].visuals[v].wells.keys {
                    guard var fields = d.report.pages[p].visuals[v].wells[key] else { continue }
                    for i in fields.indices { body(&fields[i]) }
                    d.report.pages[p].visuals[v].wells[key] = fields
                }
                mapFilters(&d.report.pages[p].visuals[v].filters)
                for s in d.report.pages[p].visuals[v].sort.indices { body(&d.report.pages[p].visuals[v].sort[s].field) }
            }
        }
        for fp in d.model.fieldParameters.indices {
            for i in d.model.fieldParameters[fp].fields.indices { body(&d.model.fieldParameters[fp].fields[i]) }
        }
    }

    // MARK: Rename

    @discardableResult
    static func renameTable(_ store: DocumentStore, _ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return false }
        if !ModelDAX.same(old, new), store.model.table(new) != nil {
            store.status = StatusMessage(kind: .warning, text: "A table named “\(new)” already exists.")
            return false
        }
        // View-only sort and filters follow the table to its new name (before the write: the
        // document change prunes state for names the model no longer has).
        store.modeling.renameGridTable(old, to: new)
        store.mutate("Rename Table", invalidates: .model) { d in
            guard let i = d.model.tableIndex(old) else { return }
            d.model.tables[i].name = new
            for r in d.model.relationships.indices {
                if ModelDAX.same(d.model.relationships[r].fromTable, old) { d.model.relationships[r].fromTable = new }
                if ModelDAX.same(d.model.relationships[r].toTable, old) { d.model.relationships[r].toTable = new }
            }
            for l in d.model.layouts.indices {
                if let key = d.model.layouts[l].cards.keys.first(where: { ModelDAX.same($0, old) }) {
                    d.model.layouts[l].cards[new] = d.model.layouts[l].cards.removeValue(forKey: key)
                }
            }
            for r in d.model.roles.indices {
                if let key = d.model.roles[r].tableFilters.keys.first(where: { ModelDAX.same($0, old) }) {
                    d.model.roles[r].tableFilters[new] = d.model.roles[r].tableFilters.removeValue(forKey: key)
                }
                d.model.roles[r].hiddenTables = d.model.roles[r].hiddenTables.map { ModelDAX.same($0, old) ? new : $0 }
                d.model.roles[r].hiddenColumns = d.model.roles[r].hiddenColumns.map { renameIdentifier($0, table: old, to: new) }
            }
            for p in d.model.perspectives.indices { d.model.perspectives[p].members = d.model.perspectives[p].members.map { renameIdentifier($0, table: old, to: new) } }
            d.model.aiExcludedFields = d.model.aiExcludedFields.map { renameIdentifier($0, table: old, to: new) }
            for a in d.model.aggregations.indices {
                if ModelDAX.same(d.model.aggregations[a].aggTable, old) { d.model.aggregations[a].aggTable = new }
                if ModelDAX.same(d.model.aggregations[a].detailTable, old) { d.model.aggregations[a].detailTable = new }
            }
            mapExpressions(&d.model) { e, _ in
                ModelDAX.rewrite(e, mapTable: { ModelDAX.same($0, old) ? new : nil }, mapBracket: { _, _ in nil })
            }
            if let key = d.data.tables.keys.first(where: { ModelDAX.same($0, old) }), var t = d.data.tables.removeValue(forKey: key) {
                t.name = new
                d.data.tables[new] = t
            }
            for q in d.queries.indices where ModelDAX.same(d.queries[q].name, old) { d.queries[q].name = new }
            mapFieldRefs(&d) { f in if ModelDAX.same(f.table, old) { f.table = new } }
        }
        let ui = store.modeling
        if let t = ui.tableViewTable, ModelDAX.same(t, old) { ui.tableViewTable = new }
        ui.selection = ui.selection.map { ref in
            switch ref {
            case .table(let t) where ModelDAX.same(t, old): return .table(new)
            case .column(let t, let n) where ModelDAX.same(t, old): return .column(table: new, name: n)
            case .measure(let t, let n) where ModelDAX.same(t, old): return .measure(table: new, name: n)
            case .hierarchy(let t, let id) where ModelDAX.same(t, old): return .hierarchy(table: new, id: id)
            case .calendar(let t, let id) where ModelDAX.same(t, old): return .calendar(table: new, id: id)
            default: return ref
            }
        }
        return true
    }

    /// "Table", "Table[Name]" identifiers used by roles, perspectives and the AI schema.
    static func identifier(table: String, name: String? = nil) -> String { name.map { "\(table)[\($0)]" } ?? table }
    private static func renameIdentifier(_ id: String, table old: String, to new: String) -> String {
        if ModelDAX.same(id, old) { return new }
        if id.lowercased().hasPrefix(old.lowercased() + "[") { return new + id.dropFirst(old.count) }
        return id
    }

    @discardableResult
    static func renameColumn(_ store: DocumentStore, table: String, _ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, let mt = store.model.table(table) else { return false }
        if !ModelDAX.same(old, new), mt.column(new) != nil || mt.measure(new) != nil {
            store.status = StatusMessage(kind: .warning, text: "“\(new)” is already used in \(table).")
            return false
        }
        let measureNamedOld = store.model.measure(old) != nil
        store.modeling.renameGridColumn(table: table, old, to: new)
        store.mutate("Rename Column", invalidates: .model) { d in
            guard let t = d.model.tableIndex(table),
                  let c = d.model.tables[t].columns.firstIndex(where: { ModelDAX.same($0.name, old) }) else { return }
            d.model.tables[t].columns[c].name = new
            for i in d.model.tables[t].columns.indices {
                if let s = d.model.tables[t].columns[i].sortByColumn, ModelDAX.same(s, old) { d.model.tables[t].columns[i].sortByColumn = new }
                if let g = d.model.tables[t].columns[i].grouping, ModelDAX.same(g.sourceColumn, old) { d.model.tables[t].columns[i].grouping?.sourceColumn = new }
            }
            for h in d.model.tables[t].hierarchies.indices {
                d.model.tables[t].hierarchies[h].levels = d.model.tables[t].hierarchies[h].levels.map { ModelDAX.same($0, old) ? new : $0 }
            }
            for k in d.model.tables[t].calendars.indices {
                d.model.tables[t].calendars[k].columnsByUnit = d.model.tables[t].calendars[k].columnsByUnit.mapValues { ModelDAX.same($0, old) ? new : $0 }
            }
            func fix(_ s: inout String?) { if let v = s, ModelDAX.same(v, old) { s = new } }
            fix(&d.model.tables[t].rowLabelColumn); fix(&d.model.tables[t].keyColumn); fix(&d.model.tables[t].dateColumn)
            if let p = d.model.tables[t].incrementalRefresh {
                if ModelDAX.same(p.dateColumn, old) { d.model.tables[t].incrementalRefresh?.dateColumn = new }
                if let dc = p.detectChangesColumn, ModelDAX.same(dc, old) { d.model.tables[t].incrementalRefresh?.detectChangesColumn = new }
            }
            for r in d.model.relationships.indices {
                if ModelDAX.same(d.model.relationships[r].fromTable, table), ModelDAX.same(d.model.relationships[r].fromColumn, old) { d.model.relationships[r].fromColumn = new }
                if ModelDAX.same(d.model.relationships[r].toTable, table), ModelDAX.same(d.model.relationships[r].toColumn, old) { d.model.relationships[r].toColumn = new }
            }
            let oldID = identifier(table: table, name: old), newID = identifier(table: table, name: new)
            for r in d.model.roles.indices { d.model.roles[r].hiddenColumns = d.model.roles[r].hiddenColumns.map { ModelDAX.same($0, oldID) ? newID : $0 } }
            for p in d.model.perspectives.indices { d.model.perspectives[p].members = d.model.perspectives[p].members.map { ModelDAX.same($0, oldID) ? newID : $0 } }
            d.model.aiExcludedFields = d.model.aiExcludedFields.map { ModelDAX.same($0, oldID) ? newID : $0 }
            for a in d.model.aggregations.indices {
                if ModelDAX.same(d.model.aggregations[a].aggTable, table), ModelDAX.same(d.model.aggregations[a].aggColumn, old) { d.model.aggregations[a].aggColumn = new }
                if ModelDAX.same(d.model.aggregations[a].detailTable, table), ModelDAX.same(d.model.aggregations[a].detailColumn, old) { d.model.aggregations[a].detailColumn = new }
            }
            mapExpressions(&d.model) { e, home in
                ModelDAX.rewrite(e, mapTable: { _ in nil }, mapBracket: { qualifier, name in
                    guard ModelDAX.same(name, old) else { return nil }
                    if let q = qualifier { return ModelDAX.same(q, table) ? new : nil }
                    if let home, ModelDAX.same(home, table), !measureNamedOld { return new }
                    return nil
                })
            }
            if let key = d.data.tables.keys.first(where: { ModelDAX.same($0, table) }),
               let ci = d.data.tables[key]?.columnIndex(old) {
                d.data.tables[key]?.columns[ci].name = new
            }
            mapFieldRefs(&d) { f in if f.kind == .column, ModelDAX.same(f.table, table), ModelDAX.same(f.name, old) { f.name = new } }
        }
        let ui = store.modeling
        ui.selection = ui.selection.map { $0 == .column(table: table, name: old) ? .column(table: table, name: new) : $0 }
        return true
    }

    @discardableResult
    static func renameMeasure(_ store: DocumentStore, table: String, _ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return false }
        if !ModelDAX.same(old, new), store.model.measure(new) != nil {
            store.status = StatusMessage(kind: .warning, text: "A measure named “\(new)” already exists.")
            return false
        }
        store.mutate("Rename Measure", invalidates: .model) { d in
            guard let t = d.model.tableIndex(table),
                  let m = d.model.tables[t].measures.firstIndex(where: { ModelDAX.same($0.name, old) }) else { return }
            d.model.tables[t].measures[m].name = new
            let model = d.model
            mapExpressions(&d.model) { e, _ in
                ModelDAX.rewrite(e, mapTable: { _ in nil }, mapBracket: { qualifier, name in
                    guard ModelDAX.same(name, old) else { return nil }
                    if let q = qualifier, model.table(q)?.column(old) != nil { return nil }
                    return new
                })
            }
            let oldID = identifier(table: table, name: old), newID = identifier(table: table, name: new)
            for p in d.model.perspectives.indices { d.model.perspectives[p].members = d.model.perspectives[p].members.map { ModelDAX.same($0, oldID) ? newID : $0 } }
            d.model.aiExcludedFields = d.model.aiExcludedFields.map { ModelDAX.same($0, oldID) ? newID : $0 }
            mapFieldRefs(&d) { f in if f.kind == .measure, ModelDAX.same(f.name, old) { f.name = new } }
        }
        let ui = store.modeling
        ui.selection = ui.selection.map { $0 == .measure(table: table, name: old) ? .measure(table: table, name: new) : $0 }
        return true
    }

    /// Move a measure to another home table.
    static func moveMeasure(_ store: DocumentStore, name: String, from: String, to: String) {
        guard !ModelDAX.same(from, to) else { return }
        store.mutate("Change Home Table", invalidates: .model) { d in
            guard let a = d.model.tableIndex(from), let b = d.model.tableIndex(to),
                  let i = d.model.tables[a].measures.firstIndex(where: { ModelDAX.same($0.name, name) }) else { return }
            let m = d.model.tables[a].measures.remove(at: i)
            d.model.tables[b].measures.append(m)
            let home = d.model.tables[b].name
            mapFieldRefs(&d) { f in if f.kind == .measure, ModelDAX.same(f.name, name) { f.table = home } }
        }
        let ui = store.modeling
        ui.selection = ui.selection.map { $0 == .measure(table: from, name: name) ? .measure(table: to, name: name) : $0 }
    }

    // MARK: Delete

    /// Deletes any mix of model objects in one undo step.
    static func delete(_ store: DocumentStore, _ refs: [ModelObjectRef]) {
        guard !refs.isEmpty else { return }
        let title = refs.count == 1 ? "Delete \(noun(refs[0]))" : "Delete \(refs.count) Objects"
        store.mutate(title, invalidates: .model) { d in
            for ref in refs { remove(ref, from: &d) }
        }
        let ui = store.modeling
        ui.pruneGrid(to: store.model)
        ui.selection.removeAll { refs.contains($0) }
        if let t = ui.tableViewTable, store.model.table(t) == nil { ui.tableViewTable = store.model.tables.first?.name }
    }

    static func noun(_ ref: ModelObjectRef) -> String {
        switch ref {
        case .table: return "Table"
        case .column: return "Column"
        case .measure: return "Measure"
        case .hierarchy: return "Hierarchy"
        case .calendar: return "Calendar"
        case .relationship: return "Relationship"
        case .calcGroup: return "Calculation Group"
        case .calcItem: return "Calculation Item"
        case .function: return "Function"
        case .role: return "Role"
        case .perspective: return "Perspective"
        case .culture: return "Culture"
        case .whatIf, .fieldParameter: return "Parameter"
        case .aggregation: return "Aggregation"
        }
    }

    private static func remove(_ ref: ModelObjectRef, from d: inout FacetDocument) {
        switch ref {
        case .table(let name):
            d.model.tables.removeAll { ModelDAX.same($0.name, name) }
            d.model.relationships.removeAll { ModelDAX.same($0.fromTable, name) || ModelDAX.same($0.toTable, name) }
            for l in d.model.layouts.indices { d.model.layouts[l].cards = d.model.layouts[l].cards.filter { !ModelDAX.same($0.key, name) } }
            for r in d.model.roles.indices {
                d.model.roles[r].tableFilters = d.model.roles[r].tableFilters.filter { !ModelDAX.same($0.key, name) }
                d.model.roles[r].hiddenTables.removeAll { ModelDAX.same($0, name) }
                d.model.roles[r].hiddenColumns.removeAll { $0.lowercased().hasPrefix(name.lowercased() + "[") }
            }
            d.model.aggregations.removeAll { ModelDAX.same($0.aggTable, name) || ModelDAX.same($0.detailTable, name) }
            d.data.tables = d.data.tables.filter { !ModelDAX.same($0.key, name) }
        case .column(let table, let name):
            guard let t = d.model.tableIndex(table) else { return }
            d.model.tables[t].columns.removeAll { ModelDAX.same($0.name, name) }
            for i in d.model.tables[t].columns.indices {
                if let s = d.model.tables[t].columns[i].sortByColumn, ModelDAX.same(s, name) { d.model.tables[t].columns[i].sortByColumn = nil }
            }
            for h in d.model.tables[t].hierarchies.indices { d.model.tables[t].hierarchies[h].levels.removeAll { ModelDAX.same($0, name) } }
            d.model.tables[t].hierarchies.removeAll { $0.levels.isEmpty }
            func clear(_ s: inout String?) { if let v = s, ModelDAX.same(v, name) { s = nil } }
            clear(&d.model.tables[t].rowLabelColumn); clear(&d.model.tables[t].keyColumn); clear(&d.model.tables[t].dateColumn)
            d.model.relationships.removeAll {
                (ModelDAX.same($0.fromTable, table) && ModelDAX.same($0.fromColumn, name)) || (ModelDAX.same($0.toTable, table) && ModelDAX.same($0.toColumn, name))
            }
            if let key = d.data.tables.keys.first(where: { ModelDAX.same($0, table) }), let ci = d.data.tables[key]?.columnIndex(name) {
                d.data.tables[key]?.columns.remove(at: ci)
            }
        case .measure(let table, let name):
            guard let t = d.model.tableIndex(table) else { return }
            d.model.tables[t].measures.removeAll { ModelDAX.same($0.name, name) }
        case .hierarchy(let table, let id):
            guard let t = d.model.tableIndex(table) else { return }
            d.model.tables[t].hierarchies.removeAll { $0.id == id }
        case .calendar(let table, let id):
            guard let t = d.model.tableIndex(table) else { return }
            d.model.tables[t].calendars.removeAll { $0.id == id }
        case .relationship(let id): d.model.relationships.removeAll { $0.id == id }
        case .calcGroup(let id): d.model.calculationGroups.removeAll { $0.id == id }
        case .calcItem(let group, let item):
            if let g = d.model.calculationGroups.firstIndex(where: { $0.id == group }) { d.model.calculationGroups[g].items.removeAll { $0.id == item } }
        case .function(let id): d.model.functions.removeAll { $0.id == id }
        case .role(let id): d.model.roles.removeAll { $0.id == id }
        case .perspective(let id): d.model.perspectives.removeAll { $0.id == id }
        case .culture(let id): d.model.translations.removeAll { $0.id == id }
        case .whatIf(let id): d.model.whatIfParameters.removeAll { $0.id == id }
        case .fieldParameter(let id): d.model.fieldParameters.removeAll { $0.id == id }
        case .aggregation(let id): d.model.aggregations.removeAll { $0.id == id }
        }
    }

    // MARK: Data type

    /// How many non-blank values of a source column can't be represented in `type`.
    static func conversionLoss(_ values: [Value], to type: DataType) -> Int {
        var lost = 0
        for v in values where !v.isNull { if v.converted(to: type).isNull { lost += 1 } }
        return lost
    }

    /// Changes a column's data type; for source columns the stored values are converted too.
    static func changeDataType(_ store: DocumentStore, table: String, column: String, to type: DataType, confirmLoss: Bool = true) {
        guard let col = store.model.table(table)?.column(column), col.dataType != type else { return }
        let source = col.isCalculated || col.grouping != nil ? nil : store.doc.data[table]?.column(column)
        guard let source else {
            updateColumns(store, [(table, column)], name: "Change Data Type") { $0.dataType = type; if !type.isNumeric { $0.summarizeBy = .none } }
            return
        }
        Task {
            let (converted, lost) = await Task.detached(priority: .userInitiated) { () -> ([Value], Int) in
                var lost = 0
                let out = source.values.map { v -> Value in
                    let c = v.converted(to: type)
                    if c.isNull, !v.isNull { lost += 1 }
                    return c
                }
                return (out, lost)
            }.value
            if lost > 0, confirmLoss {
                let alert = NSAlert()
                alert.messageText = "Change “\(column)” to \(type.displayName)?"
                alert.informativeText = "\(lost.formatted()) value\(lost == 1 ? "" : "s") can't be converted and will become blank. You can undo this change."
                alert.addButton(withTitle: "Change Type")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
            store.mutate("Change Data Type", invalidates: .model) { d in
                guard let t = d.model.tableIndex(table),
                      let c = d.model.tables[t].columns.firstIndex(where: { ModelDAX.same($0.name, column) }) else { return }
                d.model.tables[t].columns[c].dataType = type
                if !type.isNumeric { d.model.tables[t].columns[c].summarizeBy = .none }
                else if d.model.tables[t].columns[c].summarizeBy == .none, !col.dataType.isNumeric { d.model.tables[t].columns[c].summarizeBy = .sum }
                if type.isTemporal != col.dataType.isTemporal || type.isNumeric != col.dataType.isNumeric { d.model.tables[t].columns[c].formatString = "" }
                if let key = d.data.tables.keys.first(where: { ModelDAX.same($0, table) }), let ci = d.data.tables[key]?.columnIndex(column) {
                    d.data.tables[key]?.columns[ci].values = converted
                    d.data.tables[key]?.columns[ci].type = type
                }
            }
        }
    }

    // MARK: Formulas

    /// Starts a formula-bar session. In Table view the bar is inline; elsewhere it opens as a sheet.
    static func beginFormula(_ store: DocumentStore, kind: FormulaEdit.Kind, table: String? = nil, editing original: String? = nil) {
        let model = store.model
        let home = table ?? ModelingTarget.table(store) ?? ""
        if kind != .table, model.table(home) == nil {
            store.status = StatusMessage(kind: .warning, text: "Load a table first — a \(kind.noun) needs a home table.")
            return
        }
        var text: String
        switch kind {
        case .measure:
            if let original, let m = model.table(home)?.measure(original) { text = "\(m.name) = \(m.expression)" }
            else { text = "\(uniqueName("Measure", among: allMeasureNames(model))) = " }
        case .column:
            if let original, let c = model.table(home)?.column(original), let e = c.expression { text = "\(c.name) = \(e)" }
            else { text = "\(uniqueName("Column", among: model.table(home)?.columns.map(\.name) ?? [])) = " }
        case .table:
            if let original, let t = model.table(original), let e = t.expression { text = "\(t.name) = \(e)" }
            else { text = "\(uniqueName("Table", among: model.tables.map(\.name))) = " }
        }
        let edit = FormulaEdit(kind: kind, table: home, original: original, text: text)
        if store.view == .table {
            if kind != .table { store.modeling.tableViewTable = model.table(home)?.name ?? home }
            store.modeling.formula = edit
        } else {
            store.present { FormulaSheet(edit: edit) }
        }
    }

    /// Validates and writes a formula. Returns a message when it can't be committed.
    static func commitFormula(_ store: DocumentStore, _ edit: FormulaEdit, formatString: String? = nil) async -> String? {
        guard let (name, expression) = ModelDAX.splitFormula(edit.text) else { return "Write the formula as Name = expression." }
        if expression.isEmpty { return "Add an expression after the equals sign." }
        if let problem = nameProblem(name, kind: edit.kind, table: edit.table, original: edit.original, model: store.model) { return problem }
        switch edit.kind {
        case .measure:
            if let original = edit.original, !ModelDAX.same(original, name) { renameMeasure(store, table: edit.table, original, to: name) }
            store.mutate(edit.original == nil ? "New Measure" : "Edit Measure", invalidates: .model) { d in
                guard let t = d.model.tableIndex(edit.table) else { return }
                if let i = d.model.tables[t].measures.firstIndex(where: { ModelDAX.same($0.name, name) }) {
                    d.model.tables[t].measures[i].expression = expression
                    if let formatString { d.model.tables[t].measures[i].formatString = formatString }
                } else {
                    d.model.tables[t].measures.append(Measure(name: name, expression: expression, formatString: formatString ?? ""))
                }
            }
            finish(store, .measure(table: store.model.table(edit.table)?.name ?? edit.table, name: name))
        case .column:
            if let original = edit.original, !ModelDAX.same(original, name) { renameColumn(store, table: edit.table, original, to: name) }
            store.mutate(edit.original == nil ? "New Column" : "Edit Column", invalidates: .model) { d in
                guard let t = d.model.tableIndex(edit.table) else { return }
                if let i = d.model.tables[t].columns.firstIndex(where: { ModelDAX.same($0.name, name) }) {
                    d.model.tables[t].columns[i].expression = expression
                    if let formatString { d.model.tables[t].columns[i].formatString = formatString }
                } else {
                    var c = ModelColumn(name: name, dataType: .any, expression: expression)
                    c.formatString = formatString ?? ""
                    d.model.tables[t].columns.append(c)
                }
            }
            finish(store, .column(table: store.model.table(edit.table)?.name ?? edit.table, name: name))
        case .table:
            // Evaluate once to learn the table's columns, so the model lists them immediately.
            let shape: Result<DataTable?, Error> = await store.withEngine { engine in
                Result { try engine.query("EVALUATE\n" + expression).first }
            }
            var columns: [ModelColumn] = []
            switch shape {
            case .failure(let error): return error.localizedDescription
            case .success(let result):
                var seen: [String] = []
                for c in result?.columns ?? [] {
                    let n = uniqueName(plainColumnName(c.name), among: seen)
                    seen.append(n)
                    columns.append(DocumentStore.modelColumn(for: DataColumn(name: n, type: c.type)))
                }
            }
            if let original = edit.original, !ModelDAX.same(original, name) { renameTable(store, original, to: name) }
            store.mutate(edit.original == nil ? "New Table" : "Edit Table", invalidates: .model) { d in
                if let t = d.model.tableIndex(name) {
                    d.model.tables[t].expression = expression
                    guard !columns.isEmpty else { return }
                    // Keep metadata for columns that survive; keep calculated columns added on top.
                    let old = d.model.tables[t].columns
                    var merged = columns.map { c in old.first { ModelDAX.same($0.name, c.name) && !$0.isCalculated } ?? c }
                    merged.append(contentsOf: old.filter { o in (o.isCalculated || o.grouping != nil) && !merged.contains { ModelDAX.same($0.name, o.name) } })
                    d.model.tables[t].columns = merged
                } else {
                    var t = ModelTable(name: name, columns: columns)
                    t.expression = expression
                    d.model.tables.append(t)
                }
            }
            store.modeling.tableViewTable = name
            finish(store, .table(name))
        }
        return nil
    }

    /// Query results name columns "Table[Column]" or "[Column]"; the model wants the bare name.
    static func plainColumnName(_ name: String) -> String {
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else { return name }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return inner.isEmpty ? name : String(inner)
    }

    private static func finish(_ store: DocumentStore, _ ref: ModelObjectRef) {
        let ui = store.modeling
        ui.lastCommitted = ref
        ui.select(ref)
        ui.formula = nil
    }

    /// The engine's error for an object, if it failed to evaluate. Keys are "Table", "Table[Name]" or the bare name.
    static func error(for ref: ModelObjectRef, in store: DocumentStore) -> String? {
        let errors = store.modelErrors
        guard !errors.isEmpty else { return nil }
        var keys: [String] = []
        switch ref {
        case .table(let t): keys = [t, ModelDAX.table(t)]
        case .column(let t, let n), .measure(let t, let n): keys = ["\(t)[\(n)]", ModelDAX.column(t, n), n, "[\(n)]"]
        case .calcGroup(let id): keys = store.model.calculationGroups.first { $0.id == id }.map { [$0.name] } ?? []
        case .function(let id): keys = store.model.functions.first { $0.id == id }.map { [$0.name] } ?? []
        case .role(let id): keys = store.model.roles.first { $0.id == id }.map { [$0.name] } ?? []
        default: return nil
        }
        for (k, v) in errors where keys.contains(where: { ModelDAX.same($0, k) }) { return v }
        return nil
    }

    // MARK: Sort by column

    /// Sets (or with nil clears) the column another column is sorted by. Refuses a choice that
    /// would make two columns sort by each other, or where one value maps to several.
    static func setSortByColumn(_ store: DocumentStore, table: String, column: String, by other: String?) {
        guard let other else {
            updateColumns(store, [(table, column)], name: "Sort by Column") { $0.sortByColumn = nil }
            return
        }
        guard let mt = store.model.table(table) else { return }
        let data = store.computedData[mt.name] ?? store.doc.data[mt.name]
        Task {
            let problem = await Task.detached(priority: .userInitiated) {
                TableGrid.sortByProblem(column: column, by: other, in: mt, data: data)
            }.value
            if let problem {
                store.status = StatusMessage(kind: .warning, text: problem)
                return
            }
            let name = mt.column(other)?.name ?? other
            // Checked again inside the write: the model may have changed while the data was read.
            store.mutate("Sort by Column", invalidates: .model) { d in
                guard let t = d.model.tableIndex(table),
                      let c = d.model.tables[t].columns.firstIndex(where: { ModelDAX.same($0.name, column) }),
                      TableGrid.sortByProblem(column: column, by: name, in: d.model.tables[t], data: nil) == nil else { return }
                d.model.tables[t].columns[c].sortByColumn = name
            }
        }
    }

    // MARK: Hidden

    static func toggleHidden(_ store: DocumentStore, _ ref: ModelObjectRef) {
        switch ref {
        case .table(let t): updateTable(store, t, name: "Hide in Report View", invalidates: .layout) { $0.isHidden.toggle() }
        case .column(let t, let n): updateColumns(store, [(t, n)], name: "Hide in Report View", invalidates: .layout) { $0.isHidden.toggle() }
        case .measure(let t, let n): updateMeasures(store, [(t, n)], name: "Hide in Report View", invalidates: .layout) { $0.isHidden.toggle() }
        default: break
        }
    }
}
