import Foundation
import FacetCore

/// Writes a semantic model as a Tabular Model Scripting Language document (`model.bim`, and the
/// `DataModelSchema` stream of a `.pbit` template). The inverse of `TMSLConverter`.
enum TMSLWriter {
    static func summarize(_ a: Aggregation) -> String {
        switch a {
        case .sum: return "sum"
        case .average: return "average"
        case .min: return "min"
        case .max: return "max"
        case .count: return "count"
        case .distinctCount: return "distinctCount"
        default: return "none"
        }
    }

    static func document(model: SemanticModel, queries: [QueryDefinition]) -> JSONValue {
        let byName = Dictionary(queries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let tableQueries = Set(model.tables.compactMap(\.sourceQuery))
        var m: [String: JSONValue] = [
            "culture": js(model.culture.isEmpty ? "en-US" : model.culture),
            "dataAccessOptions": jo(["legacyRedirects": jb(true), "returnErrorValuesAsNull": jb(true)]),
            "defaultPowerBIDataSourceVersion": js("powerBI_V3"),
            "sourceQueryCulture": js(model.culture.isEmpty ? "en-US" : model.culture),
            "tables": ja(model.tables.map { table($0, queries: byName) }),
        ]
        let relationships = model.relationships.map(relationship)
        if !relationships.isEmpty { m["relationships"] = ja(relationships) }
        // Queries that load no table (parameters, staging queries, functions) are shared expressions.
        let shared = queries.filter { !tableQueries.contains($0.name) }.map { q -> JSONValue in
            var e: [String: JSONValue] = ["name": js(q.name), "kind": js("m"), "expression": js(q.mScript)]
            if !q.description.isEmpty { e["description"] = js(q.description) }
            return jo(e)
        }
        if !shared.isEmpty { m["expressions"] = ja(shared) }
        let roles = model.roles.map { r -> JSONValue in
            var role: [String: JSONValue] = ["name": js(r.name), "modelPermission": js("read")]
            if !r.description.isEmpty { role["description"] = js(r.description) }
            let permissions = r.tableFilters.keys.sorted().map { t in
                jo(["name": js(t), "filterExpression": js(r.tableFilters[t] ?? "")])
            }
            if !permissions.isEmpty { role["tablePermissions"] = ja(permissions) }
            return jo(role)
        }
        if !roles.isEmpty { m["roles"] = ja(roles) }
        m["annotations"] = ja([jo(["name": js("__PBI_TimeIntelligenceEnabled"), "value": js(model.autoDateTime ? "1" : "0")])])
        return jo(["name": js(model.name), "compatibilityLevel": jn(1567), "model": jo(m)])
    }

    private static func table(_ t: ModelTable, queries: [String: QueryDefinition]) -> JSONValue {
        var out: [String: JSONValue] = ["name": js(t.name)]
        if !t.description.isEmpty { out["description"] = js(t.description) }
        if t.isHidden { out["isHidden"] = jb(true) }
        out["columns"] = ja(t.columns.map { c in
            var col: [String: JSONValue] = ["name": js(c.name), "dataType": js(TMDLVocabulary.dataType(c.dataType).name),
                                            "summarizeBy": js(summarize(c.summarizeBy))]
            if let expression = c.expression { col["type"] = js("calculated"); col["expression"] = js(expression) }
            else { col["sourceColumn"] = js(c.name) }
            if !c.formatString.isEmpty { col["formatString"] = js(c.formatString) }
            if c.isHidden { col["isHidden"] = jb(true) }
            if c.isKey { col["isKey"] = jb(true) }
            if !c.isNullable { col["isNullable"] = jb(false) }
            if let sort = c.sortByColumn, !sort.isEmpty { col["sortByColumn"] = js(sort) }
            if !c.displayFolder.isEmpty { col["displayFolder"] = js(c.displayFolder) }
            if !c.description.isEmpty { col["description"] = js(c.description) }
            if let category = TMDLVocabulary.category(c.dataCategory) { col["dataCategory"] = js(category) }
            return jo(col)
        })
        if !t.measures.isEmpty {
            out["measures"] = ja(t.measures.map { me in
                var measure: [String: JSONValue] = ["name": js(me.name), "expression": js(me.expression)]
                if !me.formatString.isEmpty { measure["formatString"] = js(me.formatString) }
                if let f = me.formatExpression, !f.isEmpty { measure["formatStringDefinition"] = jo(["expression": js(f)]) }
                if !me.displayFolder.isEmpty { measure["displayFolder"] = js(me.displayFolder) }
                if !me.description.isEmpty { measure["description"] = js(me.description) }
                if me.isHidden { measure["isHidden"] = jb(true) }
                return jo(measure)
            })
        }
        if !t.hierarchies.isEmpty {
            out["hierarchies"] = ja(t.hierarchies.map { h in
                jo(["name": js(h.name), "levels": ja(h.levels.enumerated().map { i, level in
                    jo(["name": js(level), "ordinal": jn(i), "column": js(level)])
                })])
            })
        }
        let mode = TMDLVocabulary.storageMode(t.storageMode) ?? "import"
        if let expression = t.expression {
            out["partitions"] = ja([jo(["name": js(t.name), "mode": js(mode), "source": jo(["type": js("calculated"), "expression": js(expression)])])])
        } else if let name = t.sourceQuery, let q = queries[name] {
            out["partitions"] = ja([jo(["name": js(q.name), "mode": js(mode), "source": jo(["type": js("m"), "expression": js(q.mScript)])])])
        }
        return jo(out)
    }

    private static func relationship(_ r: Relationship) -> JSONValue {
        var out: [String: JSONValue] = ["name": js(r.id.uuidString.lowercased()), "fromTable": js(r.fromTable), "fromColumn": js(r.fromColumn),
                                        "toTable": js(r.toTable), "toColumn": js(r.toColumn)]
        switch r.cardinality {
        case .manyToOne: break
        case .oneToOne: out["fromCardinality"] = js("one")
        case .oneToMany: out["fromCardinality"] = js("one"); out["toCardinality"] = js("many")
        case .manyToMany: out["toCardinality"] = js("many")
        }
        if r.crossFilter == .both { out["crossFilteringBehavior"] = js("bothDirections") }
        if !r.isActive { out["isActive"] = jb(false) }
        if r.assumeReferentialIntegrity { out["assumeReferentialIntegrity"] = jb(true) }
        if r.securityFilterBothDirections { out["securityFilteringBehavior"] = js("bothDirections") }
        return jo(out)
    }
}
