import Foundation
import FacetCore

/// Writes a semantic model as a Tabular Model Scripting Language document (`model.bim`, and the
/// `DataModelSchema` stream of a `.pbit` template). The inverse of `TMSLConverter`.
///
/// Incremental refresh and aggregations are written the way TMDL writes them (`TMDLRefreshPolicy`,
/// `TMDLAggregations`): a table's `refreshPolicy`, each aggregation column's `alternateOf`, and the
/// `Facet_aggregations` / `Facet_refreshPolicyDateColumn` annotations for what Tabular can't say.
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
        let native = TMDLAggregations.native(in: model)
        var m: [String: JSONValue] = [
            "culture": js(model.culture.isEmpty ? "en-US" : model.culture),
            "dataAccessOptions": jo(["legacyRedirects": jb(true), "returnErrorValuesAsNull": jb(true)]),
            "defaultPowerBIDataSourceVersion": js("powerBI_V3"),
            "sourceQueryCulture": js(model.culture.isEmpty ? "en-US" : model.culture),
            "tables": ja(model.tables.map { table($0, queries: byName, aggregations: native) }),
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
        var annotations = [jo(["name": js("__PBI_TimeIntelligenceEnabled"), "value": js(model.autoDateTime ? "1" : "0")])]
        if !model.aggregations.isEmpty,
           let v = TMDLAggregations.annotation(model.aggregations, native: Set(native.values.map(\.id))) {
            annotations.append(facet(TMDLAggregations.annotationName, v))
        }
        m["annotations"] = ja(annotations)
        return jo(["name": js(model.name), "compatibilityLevel": jn(1567), "model": jo(m)])
    }

    /// A `Facet_*` annotation; its value is compact JSON, as in TMDL.
    static func facet(_ name: String, _ value: JSONValue) -> JSONValue {
        jo(["name": js("Facet_" + name), "value": js(value.compactString)])
    }

    /// A column's `alternateOf`: the detail column (an object reference, as TMSL writes references into another
    /// table) or, to count rows, the detail table.
    static func alternateOf(_ m: AggregationMapping) -> JSONValue? {
        guard let s = TMDLAggregations.summarization(m) else { return nil }
        var o: [String: JSONValue] = ["summarization": js(s)]
        if m.detailColumn.isEmpty { o["baseTable"] = js(m.detailTable) }
        else { o["baseColumn"] = jo(["table": js(m.detailTable), "column": js(m.detailColumn)]) }
        return jo(o)
    }

    /// A table's `refreshPolicy`; `source` is the M of its partition, if it has one.
    static func refreshPolicy(_ p: IncrementalRefreshPolicy, source: String?, table: String) -> JSONValue {
        var o: [String: JSONValue] = [
            "policyType": js("basic"),
            "rollingWindowGranularity": js(p.archiveUnit), "rollingWindowPeriods": jn(p.archiveCount),
            "incrementalGranularity": js(p.refreshUnit), "incrementalPeriods": jn(p.refreshCount),
        ]
        if p.onlyCompletePeriods { o["incrementalPeriodsOffset"] = jn(-1) }
        if p.realTimeDirectQuery { o["mode"] = js("hybrid") }
        if let c = p.detectChangesColumn {
            o["pollingExpression"] = js(TMDLRefreshPolicy.pollingExpression(column: c, source: source, table: table))
        }
        if let source { o["sourceExpression"] = js(source) }
        return jo(o)
    }

    private static func table(_ t: ModelTable, queries: [String: QueryDefinition], aggregations: [String: AggregationMapping]) -> JSONValue {
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
            if let m = aggregations[TMDLAggregations.key(t.name, c.name)], let a = alternateOf(m) { col["alternateOf"] = a }
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
        if let p = t.incrementalRefresh {
            let source = t.expression == nil ? t.sourceQuery.flatMap { queries[$0]?.mScript } : nil
            out["refreshPolicy"] = refreshPolicy(p, source: source, table: t.name)
            if TMDLRefreshPolicy.needsDateColumnAnnotation(p, source: source) {
                out["annotations"] = ja([facet(TMDLRefreshPolicy.dateColumnAnnotation, .string(p.dateColumn))])
            }
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
