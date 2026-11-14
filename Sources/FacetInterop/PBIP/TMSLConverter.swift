import Foundation
import FacetCore

/// Converts a legacy Tabular Model Scripting Language `model.bim` — as written by Power BI Desktop
/// before the TMDL project format and still produced by SQL Server Analysis Services — into FacetCore.
/// Everything the model carries is read; what Facet doesn't model is reported in the warnings.
enum TMSLConverter {
    /// Reads a parsed `model.bim`. Unknown content never fails; it is reported in the warnings.
    static func convert(_ bim: JSONValue) -> (model: SemanticModel, queries: [QueryDefinition], warnings: [ImportWarning]) {
        var model = SemanticModel()
        var queries: [QueryDefinition] = []
        var warnings: [ImportWarning] = []
        let m = bim["model"] ?? bim   // tolerate a bare model object

        model.name = bim["name"]?.stringValue ?? model.name
        model.culture = m["culture"]?.stringValue ?? model.culture
        for a in m["annotations"]?.arrayValue ?? [] {
            if a["name"]?.stringValue == "__PBI_TimeIntelligenceEnabled", a["value"]?.stringValue == "1" { model.autoDateTime = true }
        }
        // Aggregations: the annotation lists every mapping; each column's alternateOf then wins where both exist.
        var aggregationState = TMDLAggregations.ReadState()
        if let list = facet(m, TMDLAggregations.annotationName), let mappings = try? list.decode([AggregationMapping].self) {
            model.aggregations = mappings
            aggregationState.flagged = TMDLAggregations.flagged(in: list)
        }

        // Shared M expressions: parameters, staging queries and functions.
        var shared: [String: String] = [:]   // name → M script
        for e in m["expressions"]?.arrayValue ?? [] {
            guard let name = e["name"]?.stringValue, !name.isEmpty else { continue }
            if (e["kind"]?.stringValue ?? "m") != "m" { continue }   // "calculation" expressions belong to calculation groups
            var q = QueryDefinition(name: name, mScript: text(e["expression"]))
            q.description = e["description"]?.stringValue ?? ""
            queries.append(q)
            shared[name.lowercased()] = q.mScript
        }

        for t in m["tables"]?.arrayValue ?? [] {
            guard let read = readTable(t, shared: shared, queries: &queries, warnings: &warnings) else { continue }
            let (table, alternates) = read
            model.tables.append(table)
            TMDLAggregations.reconcile(table: table.name, columns: alternates, model: &model, state: &aggregationState)
            // A calculation group is a table carrying a calculationGroup child; keep both.
            if let cg = t["calculationGroup"] {
                var group = CalculationGroup(name: table.name)
                group.precedence = cg["precedence"]?.intValue ?? 0
                group.columnName = table.columns.first?.name ?? "Name"
                for (i, item) in (cg["calculationItems"]?.arrayValue ?? []).enumerated() {
                    var it = CalculationItem(name: item["name"]?.stringValue ?? "Item \(i + 1)",
                                             expression: text(item["expression"]))
                    it.ordinal = item["ordinal"]?.intValue ?? i
                    let fmt = item["formatStringDefinition"]?["expression"]
                    it.formatExpression = fmt == nil || fmt?.isNull == true ? nil : text(fmt)
                    group.items.append(it)
                }
                model.calculationGroups.append(group)
            }
        }

        TMDLAggregations.finish(&model, state: &aggregationState)

        for r in m["relationships"]?.arrayValue ?? [] {
            guard let fromTable = r["fromTable"]?.stringValue, let toTable = r["toTable"]?.stringValue else { continue }
            var rel = Relationship(fromTable: fromTable, fromColumn: r["fromColumn"]?.stringValue ?? "",
                                   toTable: toTable, toColumn: r["toColumn"]?.stringValue ?? "")
            rel.crossFilter = r["crossFilteringBehavior"]?.stringValue == "bothDirections" ? .both : .single
            rel.isActive = r["isActive"]?.boolValue ?? true
            rel.assumeReferentialIntegrity = r["assumeReferentialIntegrity"]?.boolValue ?? false
            rel.securityFilterBothDirections = r["securityFilteringBehavior"]?.stringValue == "bothDirections"
            model.relationships.append(rel)
        }

        for r in m["roles"]?.arrayValue ?? [] {
            guard let name = r["name"]?.stringValue else { continue }
            var role = SecurityRole(name: name)
            role.description = r["description"]?.stringValue ?? ""
            for tp in r["tablePermissions"]?.arrayValue ?? [] {
                guard let table = tp["name"]?.stringValue else { continue }
                if let filter = tp["filterExpression"], !filter.isNull { role.tableFilters[table] = text(filter) }
                if tp["metadataPermission"]?.stringValue == "none" { role.hiddenTables.append(table) }
                for cp in tp["columnPermissions"]?.arrayValue ?? []
                where (cp["metadataPermission"]?.stringValue ?? "default") == "none" {
                    role.hiddenColumns.append("\(table)[\(cp["name"]?.stringValue ?? "")]")
                }
            }
            model.roles.append(role)
        }

        for p in m["perspectives"]?.arrayValue ?? [] {
            guard let name = p["name"]?.stringValue else { continue }
            var perspective = Perspective(name: name)
            for t in p["perspectiveTables"]?.arrayValue ?? [] {
                if let t = t["name"]?.stringValue { perspective.members.append(t) }
            }
            for entries in [p["perspectiveColumns"], p["perspectiveMeasures"]] {
                for e in entries?.arrayValue ?? [] {
                    if let t = e["table"]?.stringValue, let n = e["name"]?.stringValue { perspective.members.append("\(t)[\(n)]") }
                }
            }
            model.perspectives.append(perspective)
        }

        return (model, queries, warnings)
    }

    // MARK: Tables

    /// A table, and each of its columns with the aggregation its `alternateOf` describes (if any).
    private static func readTable(_ t: JSONValue, shared: [String: String], queries: inout [QueryDefinition],
                                  warnings: inout [ImportWarning]) -> (ModelTable, [(name: String, native: AggregationMapping?)])? {
        guard let name = t["name"]?.stringValue, !name.isEmpty else { return nil }
        let location = "table “\(name)”"
        var table = ModelTable(name: name)
        table.description = t["description"]?.stringValue ?? ""
        table.isHidden = t["isHidden"]?.boolValue ?? false
        var alternates: [(name: String, native: AggregationMapping?)] = []

        for c in t["columns"]?.arrayValue ?? [] {
            if (c["type"]?.stringValue ?? "data") == "rowNumber" { continue }   // Power BI's auto row-number column
            guard let colName = c["name"]?.stringValue else { continue }
            if let a = c["alternateOf"], !a.isNull {
                let (mapping, problem) = alternateOf(a, table: name, column: colName)
                alternates.append((colName, mapping))
                if let problem { warnings.append(ImportWarning(problem, location: location)) }
            } else {
                alternates.append((colName, nil))
            }
            let type = c["dataType"]?.stringValue.flatMap(TMDLVocabulary.parseDataType) ?? .any
            var col = ModelColumn(name: colName, dataType: type)
            if (c["type"]?.stringValue ?? "data") == "calculated" { col.expression = text(c["expression"]) }
            col.formatString = c["formatString"]?.stringValue ?? ""
            col.isHidden = c["isHidden"]?.boolValue ?? false
            col.isKey = c["isKey"]?.boolValue ?? false
            col.isNullable = c["isNullable"]?.boolValue ?? true
            col.sortByColumn = c["sortByColumn"]?.stringValue
            col.displayFolder = c["displayFolder"]?.stringValue ?? ""
            col.description = c["description"]?.stringValue ?? ""
            col.dataCategory = c["dataCategory"]?.stringValue.flatMap(TMDLVocabulary.parseCategory) ?? .uncategorized
            if let s = c["summarizeBy"]?.stringValue {
                switch s.lowercased() {
                case "default", "": col.summarizeBy = type.isNumeric ? .sum : .none
                case "countnonnull": col.summarizeBy = .count
                default: col.summarizeBy = TMDLVocabulary.parseSummarize(s)
                }
            }
            table.columns.append(col)
        }

        for me in t["measures"]?.arrayValue ?? [] {
            guard let mName = me["name"]?.stringValue, let expression = me["expression"] else { continue }
            var measure = Measure(name: mName, expression: text(expression), formatString: me["formatString"]?.stringValue ?? "")
            measure.displayFolder = me["displayFolder"]?.stringValue ?? ""
            measure.description = me["description"]?.stringValue ?? ""
            measure.isHidden = me["isHidden"]?.boolValue ?? false
            measure.dataCategory = me["dataCategory"]?.stringValue.flatMap(TMDLVocabulary.parseCategory) ?? .uncategorized
            if let fmt = me["formatStringDefinition"]?["expression"], !fmt.isNull { measure.formatExpression = text(fmt) }
            table.measures.append(measure)
        }

        for h in t["hierarchies"]?.arrayValue ?? [] {
            guard let hName = h["name"]?.stringValue else { continue }
            let levels = (h["levels"]?.arrayValue ?? []).sorted { ($0["ordinal"]?.intValue ?? 0) < ($1["ordinal"]?.intValue ?? 0) }
                .compactMap { $0["column"]?.stringValue ?? $0["name"]?.stringValue }
            var hierarchy = Hierarchy(name: hName, levels: levels)
            hierarchy.isHidden = h["isHidden"]?.boolValue ?? false
            table.hierarchies.append(hierarchy)
        }

        // The partition decides where the table's data comes from.
        let partitions = t["partitions"]?.arrayValue ?? []
        if partitions.count > 1 { warnings.append(ImportWarning("Table “\(name)” has \(partitions.count) partitions; only the first is used.", location: location)) }
        var partitionM: String?
        if let p = partitions.first {
            if let mode = p["mode"]?.stringValue.flatMap(TMDLVocabulary.parseStorageMode) { table.storageMode = mode }
            let source = p["source"]
            switch source?["type"]?.stringValue ?? "m" {
            case "m":
                let script = text(source?["expression"])
                // A partition either holds the full M query or names a shared expression from model.expressions.
                if let named = shared[script.lowercased()] {
                    table.sourceQuery = script
                    partitionM = named
                } else {
                    partitionM = script
                    var q = QueryDefinition(name: p["name"]?.stringValue ?? name, mScript: script)
                    q.description = p["description"]?.stringValue ?? ""
                    queries.append(q)
                    table.sourceQuery = q.name
                }
            case "calculated":
                table.expression = text(source?["expression"])
            default:
                warnings.append(ImportWarning("Partition “\(p["name"]?.stringValue ?? name)” of kind “\(source?["type"]?.stringValue ?? "m")” isn't supported; the table has no source.", location: location))
            }
        }
        // A date table: the column this app recorded, else the key date column (how Power BI marks one), else the first
        // date column of a table tagged dataCategory "Time". A table that merely has a date column is not one.
        if table.dateColumn == nil {
            if let d = facet(t, "dateColumn")?.stringValue, table.column(d) != nil {
                table.dateColumn = d
            } else if let key = table.columns.first(where: { $0.isKey && $0.dataType.isTemporal })?.name {
                table.dateColumn = key
            } else if t["dataCategory"]?.stringValue?.lowercased() == "time" {
                table.dateColumn = table.columns.first { $0.dataType.isTemporal }?.name
            }
        }
        if let rp = t["refreshPolicy"], rp.objectValue != nil {
            let annotated = facet(t, TMDLRefreshPolicy.dateColumnAnnotation)?.stringValue
            let (policy, problems) = TMDLRefreshPolicy.parse(property: { k in rp[k]?.stringValue ?? rp[k]?.intValue.map(String.init) },
                                                             expression: { k in rp[k].map(text) },
                                                             partitionSource: partitionM, annotatedDateColumn: annotated)
            table.incrementalRefresh = policy
            for m in problems { warnings.append(ImportWarning(m, location: location)) }
            let known = TMDLRefreshPolicy.properties.union(TMDLRefreshPolicy.expressions)
            for key in (rp.objectValue ?? [:]).keys.sorted() where !known.contains(key.lowercased()) {
                warnings.append(ImportWarning("Ignored refreshPolicy property “\(key)”.", location: location))
            }
        }
        return (table, alternates)
    }

    /// Reads a column's `alternateOf`: `baseColumn` is a reference into another table (`{"table", "column"}`),
    /// `baseTable` a table name.
    static func alternateOf(_ a: JSONValue, table: String, column: String) -> (AggregationMapping?, problem: String?) {
        var base: (table: String, column: String)?
        if let ref = a["baseColumn"], !ref.isNull {
            guard let t = ref["table"]?.stringValue, let c = ref["column"]?.stringValue else {
                return (nil, "Ignored alternateOf on \(table)[\(column)]: baseColumn must name a table and a column.")
            }
            base = (t, c)
        }
        return TMDLAggregations.mapping(summarization: a["summarization"]?.stringValue, baseColumn: base,
                                        baseTable: a["baseTable"]?.stringValue, table: table, column: column)
    }

    /// A `Facet_*` annotation of a TMSL object, parsed from its JSON value.
    static func facet(_ j: JSONValue, _ name: String) -> JSONValue? {
        let entry = j["annotations"]?.arrayValue?.first { $0["name"]?.stringValue == "Facet_" + name }
        return entry?["value"].map(text).flatMap { try? JSONValue.parse($0) }
    }

    // MARK: M expression text

    /// TMSL stores M as a string, or as an array of lines that join with line breaks.
    static func text(_ j: JSONValue?) -> String {
        if let s = j?.stringValue { return s }
        return (j?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
    }
}
