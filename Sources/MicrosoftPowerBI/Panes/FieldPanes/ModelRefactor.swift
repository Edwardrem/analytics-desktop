import Foundation
import FacetCore

/// Renames, moves and deletions of model objects that keep the rest of the document consistent:
/// DAX expressions, relationships, hierarchies, stored data and every `FieldRef` in the report.
enum ModelRefactor {

    // MARK: - Name validation

    /// Returns a human-readable reason the name can't be used, or nil when it is fine.
    static func tableNameProblem(_ name: String, renaming old: String, in model: SemanticModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "A table needs a name." }
        if n.caseInsensitiveCompare(old) != .orderedSame, model.table(n) != nil { return "A table named “\(n)” already exists." }
        return nil
    }
    static func fieldNameProblem(_ name: String, renaming old: FieldRef, in model: SemanticModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "A field needs a name." }
        if n.contains("]") { return "Field names can't contain “]”." }
        if n.caseInsensitiveCompare(old.name) == .orderedSame { return nil }
        guard let t = model.table(old.table) else { return nil }
        if t.column(n) != nil || t.hierarchies.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return "“\(n)” already exists in \(t.name)."
        }
        if let other = model.measure(n) { return "A measure named “\(n)” already exists in \(other.table.name)." }
        return nil
    }

    // MARK: - FieldRef traversal

    /// Applies `change` to every field reference stored in the report and model parameters.
    static func rewriteRefs(_ d: inout FacetDocument, _ change: (inout FieldRef) -> Void) {
        func filters(_ list: inout [FilterSpec]) {
            for i in list.indices {
                change(&list[i].field)
                if var by = list[i].topN.by { change(&by); list[i].topN.by = by }
            }
        }
        func key(_ k: String) -> String {
            guard var ref = fieldRef(fromKey: k) else { return k }
            change(&ref)
            return ref.key
        }
        for p in d.report.pages.indices {
            filters(&d.report.pages[p].filters)
            filters(&d.report.pages[p].drillthroughFilters)
            if var m = d.report.pages[p].autoRefresh.changeDetectionMeasure { change(&m); d.report.pages[p].autoRefresh.changeDetectionMeasure = m }
            for v in d.report.pages[p].visuals.indices {
                var spec = d.report.pages[p].visuals[v]
                for (well, fields) in spec.wells {
                    var f = fields
                    for i in f.indices { change(&f[i]) }
                    spec.wells[well] = f
                }
                filters(&spec.filters)
                for i in spec.sort.indices { change(&spec.sort[i].field) }
                for i in spec.conditionalFormats.indices {
                    if var b = spec.conditionalFormats[i].basedOn { change(&b); spec.conditionalFormats[i].basedOn = b }
                    if let k = spec.conditionalFormats[i].appliesToKey { spec.conditionalFormats[i].appliesToKey = key(k) }
                }
                for i in spec.analytics.indices {
                    if let k = spec.analytics[i].seriesKey { spec.analytics[i].seriesKey = key(k) }
                    if var by = spec.analytics[i].explainBy {
                        for j in by.indices { change(&by[j]) }
                        spec.analytics[i].explainBy = by
                    }
                }
                if var m = spec.action?.conditionalMeasure { change(&m); spec.action?.conditionalMeasure = m }
                d.report.pages[p].visuals[v] = spec
            }
        }
        filters(&d.report.filters)
        for b in d.report.bookmarks.indices {
            filters(&d.report.bookmarks[b].state.pageFilters)
            filters(&d.report.bookmarks[b].state.reportFilters)
            for (id, var list) in d.report.bookmarks[b].state.visualFilters { filters(&list); d.report.bookmarks[b].state.visualFilters[id] = list }
            for (id, var sorts) in d.report.bookmarks[b].state.sorts {
                for i in sorts.indices { change(&sorts[i].field) }
                d.report.bookmarks[b].state.sorts[id] = sorts
            }
        }
        for i in d.model.fieldParameters.indices {
            for j in d.model.fieldParameters[i].fields.indices { change(&d.model.fieldParameters[i].fields[j]) }
        }
    }

    /// Removes every use of the matching fields from the report.
    static func removeRefs(_ d: inout FacetDocument, where matches: (FieldRef) -> Bool) {
        func filters(_ list: inout [FilterSpec]) {
            list.removeAll { matches($0.field) }
            for i in list.indices where list[i].topN.by.map(matches) == true { list[i].topN.by = nil }
        }
        for p in d.report.pages.indices {
            filters(&d.report.pages[p].filters)
            filters(&d.report.pages[p].drillthroughFilters)
            if d.report.pages[p].autoRefresh.changeDetectionMeasure.map(matches) == true { d.report.pages[p].autoRefresh.changeDetectionMeasure = nil }
            for v in d.report.pages[p].visuals.indices {
                var spec = d.report.pages[p].visuals[v]
                let removedKeys = Set(spec.allFields.filter(matches).map(\.key))
                for (well, fields) in spec.wells {
                    let kept = fields.filter { !matches($0) }
                    spec.wells[well] = kept.isEmpty ? nil : kept
                }
                filters(&spec.filters)
                spec.sort.removeAll { matches($0.field) }
                spec.conditionalFormats.removeAll { cf in
                    cf.basedOn.map(matches) == true || cf.appliesToKey.map(removedKeys.contains) == true
                }
                for i in spec.analytics.indices where spec.analytics[i].seriesKey.map(removedKeys.contains) == true { spec.analytics[i].seriesKey = nil }
                if spec.action?.conditionalMeasure.map(matches) == true { spec.action?.conditionalMeasure = nil }
                d.report.pages[p].visuals[v] = spec
            }
        }
        filters(&d.report.filters)
        for b in d.report.bookmarks.indices {
            filters(&d.report.bookmarks[b].state.pageFilters)
            filters(&d.report.bookmarks[b].state.reportFilters)
            for (id, var list) in d.report.bookmarks[b].state.visualFilters { filters(&list); d.report.bookmarks[b].state.visualFilters[id] = list }
            for (id, var sorts) in d.report.bookmarks[b].state.sorts { sorts.removeAll { matches($0.field) }; d.report.bookmarks[b].state.sorts[id] = sorts }
        }
        for i in d.model.fieldParameters.indices { d.model.fieldParameters[i].fields.removeAll(where: matches) }
    }

    /// Parses `FieldRef.key` ("kind|table|name|aggregation") back into a reference.
    static func fieldRef(fromKey key: String) -> FieldRef? {
        let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 4, let kind = FieldRef.Kind(rawValue: p[0]), let agg = Aggregation(rawValue: p[p.count - 1]) else { return nil }
        return FieldRef(kind: kind, table: p[1], name: p[2..<(p.count - 1)].joined(separator: "|"), aggregation: agg)
    }

    // MARK: - Expressions

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// `Name` or `'Quoted name'` as DAX requires.
    static func daxTableName(_ name: String) -> String {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !(name.unicodeScalars.first.map(CharacterSet.decimalDigits.contains) ?? false)
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Rewrites identifiers in a DAX expression, leaving string literals and comments untouched.
    /// - Parameters:
    ///   - table: called for every table-name token; return a replacement name or nil.
    ///   - bracket: called for every `[name]` with its table qualifier (nil when unqualified); return a replacement name or nil.
    static func rewriteDAX(_ source: String, table: (String) -> String?, bracket: (String?, String) -> String?) -> String {
        let s = Array(source)
        var out = ""
        out.reserveCapacity(s.count + 16)
        var i = 0
        var qualifier: String?           // table token immediately before the current position
        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }
        while i < s.count {
            let c = s[i]
            if c == "\"" {                                   // string literal
                var j = i + 1
                while j < s.count {
                    if s[j] == "\"" { if j + 1 < s.count, s[j + 1] == "\"" { j += 2; continue }; break }
                    j += 1
                }
                out += String(s[i...min(j, s.count - 1)]); i = j + 1; qualifier = nil
            } else if (c == "-" && i + 1 < s.count && s[i + 1] == "-") || (c == "/" && i + 1 < s.count && s[i + 1] == "/") {
                var j = i
                while j < s.count, s[j] != "\n" { j += 1 }
                out += String(s[i..<j]); i = j; qualifier = nil
            } else if c == "/" && i + 1 < s.count && s[i + 1] == "*" {
                var j = i + 2
                while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                let end = min(j + 2, s.count)
                out += String(s[i..<end]); i = end; qualifier = nil
            } else if c == "'" {                             // quoted table name
                var j = i + 1
                var name = ""
                while j < s.count {
                    if s[j] == "'" { if j + 1 < s.count, s[j + 1] == "'" { name.append("'"); j += 2; continue }; break }
                    name.append(s[j]); j += 1
                }
                let replaced = table(name)
                out += replaced.map(daxTableName) ?? String(s[i...min(j, s.count - 1)])
                qualifier = name; i = j + 1
            } else if c == "[" {                             // column / measure reference
                var j = i + 1
                var name = ""
                while j < s.count {
                    if s[j] == "]" { if j + 1 < s.count, s[j + 1] == "]" { name.append("]"); j += 2; continue }; break }
                    name.append(s[j]); j += 1
                }
                if let r = bracket(qualifier, name) { out += "[" + r.replacingOccurrences(of: "]", with: "]]") + "]" }
                else { out += String(s[i...min(j, s.count - 1)]) }
                qualifier = nil; i = j + 1
            } else if isIdentStart(c) {
                var j = i
                while j < s.count, isIdent(s[j]) { j += 1 }
                let word = String(s[i..<j])
                var k = j
                while k < s.count, s[k] == " " { k += 1 }
                let isCall = k < s.count && s[k] == "("
                if !isCall, let r = table(word) { out += daxTableName(r) } else { out += word }
                qualifier = isCall ? nil : word
                i = j
            } else {
                out.append(c); i += 1
                if !c.isWhitespace { qualifier = nil }
            }
        }
        return out
    }

    /// Applies `rewrite(expression, homeTable)` to every DAX expression in the document.
    static func rewriteExpressions(_ d: inout FacetDocument, _ rewrite: (String, String?) -> String) {
        for t in d.model.tables.indices {
            let home = d.model.tables[t].name
            if let e = d.model.tables[t].expression { d.model.tables[t].expression = rewrite(e, nil) }
            for c in d.model.tables[t].columns.indices {
                if let e = d.model.tables[t].columns[c].expression { d.model.tables[t].columns[c].expression = rewrite(e, home) }
            }
            for m in d.model.tables[t].measures.indices {
                d.model.tables[t].measures[m].expression = rewrite(d.model.tables[t].measures[m].expression, nil)
                if let f = d.model.tables[t].measures[m].formatExpression { d.model.tables[t].measures[m].formatExpression = rewrite(f, nil) }
            }
        }
        for g in d.model.calculationGroups.indices {
            for i in d.model.calculationGroups[g].items.indices {
                d.model.calculationGroups[g].items[i].expression = rewrite(d.model.calculationGroups[g].items[i].expression, nil)
                if let f = d.model.calculationGroups[g].items[i].formatExpression { d.model.calculationGroups[g].items[i].formatExpression = rewrite(f, nil) }
            }
        }
        for f in d.model.functions.indices { d.model.functions[f].expression = rewrite(d.model.functions[f].expression, nil) }
        for r in d.model.roles.indices {
            for (table, filter) in d.model.roles[r].tableFilters { d.model.roles[r].tableFilters[table] = rewrite(filter, table) }
        }
        for q in d.report.daxQueries.indices { d.report.daxQueries[q].text = rewrite(d.report.daxQueries[q].text, nil) }
    }

    private static func objectID(_ table: String, _ name: String) -> String { "\(table)[\(name)]" }
    private static func renameObjectIDs(_ d: inout FacetDocument, _ map: (String) -> String) {
        for r in d.model.roles.indices {
            d.model.roles[r].hiddenColumns = d.model.roles[r].hiddenColumns.map(map)
            d.model.roles[r].hiddenTables = d.model.roles[r].hiddenTables.map(map)
        }
        for p in d.model.perspectives.indices { d.model.perspectives[p].members = d.model.perspectives[p].members.map(map) }
        d.model.aiExcludedFields = d.model.aiExcludedFields.map(map)
    }

    // MARK: - Rename

    static func renameTable(_ d: inout FacetDocument, from old: String, to new: String) {
        guard let ti = d.model.tableIndex(old), old != new else { return }
        d.model.tables[ti].name = new
        if let data = d.data[old] { var t = data; t.name = new; d.data[old] = nil; d.data[new] = t }
        for r in d.model.relationships.indices {
            if same(d.model.relationships[r].fromTable, old) { d.model.relationships[r].fromTable = new }
            if same(d.model.relationships[r].toTable, old) { d.model.relationships[r].toTable = new }
        }
        for l in d.model.layouts.indices {
            if let card = d.model.layouts[l].cards[old] { d.model.layouts[l].cards[old] = nil; d.model.layouts[l].cards[new] = card }
        }
        for a in d.model.aggregations.indices {
            if same(d.model.aggregations[a].aggTable, old) { d.model.aggregations[a].aggTable = new }
            if same(d.model.aggregations[a].detailTable, old) { d.model.aggregations[a].detailTable = new }
        }
        for r in d.model.roles.indices {
            if let f = d.model.roles[r].tableFilters[old] { d.model.roles[r].tableFilters[old] = nil; d.model.roles[r].tableFilters[new] = f }
        }
        renameObjectIDs(&d) { id in
            if same(id, old) { return new }
            if id.lowercased().hasPrefix(old.lowercased() + "[") { return new + id.dropFirst(old.count) }
            return id
        }
        rewriteExpressions(&d) { e, _ in rewriteDAX(e, table: { same($0, old) ? new : nil }, bracket: { _, _ in nil }) }
        rewriteRefs(&d) { if same($0.table, old) { $0.table = new } }
    }

    static func renameColumn(_ d: inout FacetDocument, table: String, from old: String, to new: String) {
        guard let ti = d.model.tableIndex(table),
              let ci = d.model.tables[ti].columns.firstIndex(where: { same($0.name, old) }), old != new else { return }
        let hasMeasureNamedOld = d.model.measure(old) != nil
        d.model.tables[ti].columns[ci].name = new
        for c in d.model.tables[ti].columns.indices {
            if let s = d.model.tables[ti].columns[c].sortByColumn, same(s, old) { d.model.tables[ti].columns[c].sortByColumn = new }
            if let g = d.model.tables[ti].columns[c].grouping, same(g.sourceColumn, old) { d.model.tables[ti].columns[c].grouping?.sourceColumn = new }
        }
        for h in d.model.tables[ti].hierarchies.indices {
            d.model.tables[ti].hierarchies[h].levels = d.model.tables[ti].hierarchies[h].levels.map { same($0, old) ? new : $0 }
        }
        for c in d.model.tables[ti].calendars.indices {
            d.model.tables[ti].calendars[c].columnsByUnit = d.model.tables[ti].calendars[c].columnsByUnit.mapValues { same($0, old) ? new : $0 }
        }
        func fix(_ s: inout String?) { if let v = s, same(v, old) { s = new } }
        fix(&d.model.tables[ti].dateColumn); fix(&d.model.tables[ti].keyColumn); fix(&d.model.tables[ti].rowLabelColumn)
        if let p = d.model.tables[ti].incrementalRefresh {
            if same(p.dateColumn, old) { d.model.tables[ti].incrementalRefresh?.dateColumn = new }
            if let c = p.detectChangesColumn, same(c, old) { d.model.tables[ti].incrementalRefresh?.detectChangesColumn = new }
        }
        for r in d.model.relationships.indices {
            if same(d.model.relationships[r].fromTable, table), same(d.model.relationships[r].fromColumn, old) { d.model.relationships[r].fromColumn = new }
            if same(d.model.relationships[r].toTable, table), same(d.model.relationships[r].toColumn, old) { d.model.relationships[r].toColumn = new }
        }
        for a in d.model.aggregations.indices {
            if same(d.model.aggregations[a].aggTable, table), same(d.model.aggregations[a].aggColumn, old) { d.model.aggregations[a].aggColumn = new }
            if same(d.model.aggregations[a].detailTable, table), same(d.model.aggregations[a].detailColumn, old) { d.model.aggregations[a].detailColumn = new }
        }
        let name = d.model.tables[ti].name
        if var data = d.data[name], let i = data.columnIndex(old) { data.columns[i].name = new; d.data[name] = data }
        renameObjectIDs(&d) { same($0, objectID(table, old)) ? objectID(name, new) : $0 }
        rewriteExpressions(&d) { e, home in
            rewriteDAX(e, table: { _ in nil }, bracket: { q, n in
                guard same(n, old) else { return nil }
                if let q { return same(q, table) ? new : nil }
                // Unqualified: only inside the column's own table, and only if it can't be a measure.
                return (home.map { same($0, table) } ?? false) && !hasMeasureNamedOld ? new : nil
            })
        }
        rewriteRefs(&d) { if $0.kind == .column, same($0.table, table), same($0.name, old) { $0.name = new } }
    }

    static func renameMeasure(_ d: inout FacetDocument, table: String, from old: String, to new: String) {
        guard let ti = d.model.tableIndex(table),
              let mi = d.model.tables[ti].measures.firstIndex(where: { same($0.name, old) }), old != new else { return }
        d.model.tables[ti].measures[mi].name = new
        let snapshot = d.model
        renameObjectIDs(&d) { same($0, objectID(table, old)) ? objectID(table, new) : $0 }
        rewriteExpressions(&d) { e, home in
            rewriteDAX(e, table: { _ in nil }, bracket: { q, n in
                guard same(n, old) else { return nil }
                if let q { return same(q, table) ? new : nil }
                // An unqualified [old] inside another table's calculated column could be that table's own column.
                if let home, let t = snapshot.table(home), t.column(old) != nil { return nil }
                return new
            })
        }
        rewriteRefs(&d) { if $0.kind == .measure, same($0.name, old) { $0.name = new } }
    }

    static func renameHierarchy(_ d: inout FacetDocument, table: String, from old: String, to new: String) {
        guard let ti = d.model.tableIndex(table),
              let hi = d.model.tables[ti].hierarchies.firstIndex(where: { same($0.name, old) }) else { return }
        d.model.tables[ti].hierarchies[hi].name = new
    }

    // MARK: - Move and delete

    static func moveMeasure(_ d: inout FacetDocument, name: String, from: String, to: String) {
        guard let fi = d.model.tableIndex(from), let ti = d.model.tableIndex(to), fi != ti,
              let mi = d.model.tables[fi].measures.firstIndex(where: { same($0.name, name) }) else { return }
        let m = d.model.tables[fi].measures.remove(at: mi)
        d.model.tables[ti].measures.append(m)
        let target = d.model.tables[ti].name
        renameObjectIDs(&d) { same($0, objectID(from, name)) ? objectID(target, name) : $0 }
        rewriteRefs(&d) { if $0.kind == .measure, same($0.name, name) { $0.table = target } }
    }

    static func deleteMeasure(_ d: inout FacetDocument, table: String, name: String) {
        guard let ti = d.model.tableIndex(table) else { return }
        d.model.tables[ti].measures.removeAll { same($0.name, name) }
        removeRefs(&d) { $0.kind == .measure && same($0.name, name) }
    }

    static func deleteColumn(_ d: inout FacetDocument, table: String, name: String) {
        guard let ti = d.model.tableIndex(table) else { return }
        d.model.tables[ti].columns.removeAll { same($0.name, name) }
        for c in d.model.tables[ti].columns.indices {
            if let s = d.model.tables[ti].columns[c].sortByColumn, same(s, name) { d.model.tables[ti].columns[c].sortByColumn = nil }
        }
        for h in d.model.tables[ti].hierarchies.indices { d.model.tables[ti].hierarchies[h].levels.removeAll { same($0, name) } }
        d.model.tables[ti].hierarchies.removeAll { $0.levels.isEmpty }
        if let c = d.model.tables[ti].dateColumn, same(c, name) { d.model.tables[ti].dateColumn = nil }
        if let c = d.model.tables[ti].keyColumn, same(c, name) { d.model.tables[ti].keyColumn = nil }
        if let c = d.model.tables[ti].rowLabelColumn, same(c, name) { d.model.tables[ti].rowLabelColumn = nil }
        if let p = d.model.tables[ti].incrementalRefresh, same(p.dateColumn, name) { d.model.tables[ti].incrementalRefresh = nil }
        d.model.relationships.removeAll {
            (same($0.fromTable, table) && same($0.fromColumn, name)) || (same($0.toTable, table) && same($0.toColumn, name))
        }
        d.model.aggregations.removeAll {
            (same($0.aggTable, table) && same($0.aggColumn, name)) || (same($0.detailTable, table) && same($0.detailColumn, name))
        }
        let tname = d.model.tables[ti].name
        if var data = d.data[tname], let i = data.columnIndex(name) { data.columns.remove(at: i); d.data[tname] = data }
        removeRefs(&d) { $0.kind == .column && same($0.table, table) && same($0.name, name) }
    }

    static func deleteTable(_ d: inout FacetDocument, name: String) {
        guard let ti = d.model.tableIndex(name) else { return }
        let actual = d.model.tables[ti].name
        d.model.tables.remove(at: ti)
        d.data[actual] = nil
        d.model.relationships.removeAll { same($0.fromTable, name) || same($0.toTable, name) }
        d.model.aggregations.removeAll { same($0.aggTable, name) || same($0.detailTable, name) }
        for l in d.model.layouts.indices { d.model.layouts[l].cards[actual] = nil }
        for r in d.model.roles.indices { d.model.roles[r].tableFilters[actual] = nil }
        removeRefs(&d) { same($0.table, name) }
    }

    /// Number of places in the report that use the matching fields — shown in delete confirmations.
    static func usageCount(in report: Report, where matches: (FieldRef) -> Bool) -> Int {
        var n = 0
        for p in report.pages {
            n += p.filters.filter { matches($0.field) }.count + p.drillthroughFilters.filter { matches($0.field) }.count
            for v in p.visuals where v.allFields.contains(where: matches) || v.filters.contains(where: { matches($0.field) }) { n += 1 }
        }
        n += report.filters.filter { matches($0.field) }.count
        return n
    }
}
