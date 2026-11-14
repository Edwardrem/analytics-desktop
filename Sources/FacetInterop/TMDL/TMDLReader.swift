import Foundation
import FacetCore

/// The result of reading TMDL: the model, its Power Query queries, and anything that was skipped.
public struct TMDLParseResult: Sendable {
    public var model: SemanticModel
    public var queries: [QueryDefinition]
    public var warnings: [ImportWarning]
}

public extension TMDL {
    /// Parses a TMDL folder (as produced by `serialize` or by Power BI Desktop) into a model and its queries.
    static func parse(files: [TMDLFile]) throws -> (SemanticModel, [QueryDefinition]) {
        let r = try parseDetailed(files: files)
        return (r.model, r.queries)
    }

    /// Like `parse(files:)` but also reports the TMDL content Facet doesn't model.
    static func parseDetailed(files: [TMDLFile]) throws -> TMDLParseResult {
        var builder = TMDLBuilder()
        // model.tmdl first so `ref` ordering is known; then the rest in a stable order.
        let ordered = files.sorted { a, b in
            func rank(_ f: TMDLFile) -> Int {
                let n = (f.path as NSString).lastPathComponent.lowercased()
                return n == "database.tmdl" ? 0 : n == "model.tmdl" ? 1 : 2
            }
            return rank(a) < rank(b)
        }
        var model = SemanticModel()
        var queries: [QueryDefinition] = []
        for f in ordered {
            let parsed = try TMDLParser.parse(f.text, file: f.path)
            for node in parsed.nodes { try builder.merge(node, into: &model, queries: &queries, file: f.path) }
        }
        builder.finish(&model, queries: &queries)
        return TMDLParseResult(model: model, queries: queries, warnings: builder.warnings)
    }
}

/// Converts parsed TMDL nodes into FacetCore objects and merges them into a model.
struct TMDLBuilder {
    var warnings: [ImportWarning] = []
    /// IDs invented because the TMDL carried none; a merge keeps the existing object's id instead.
    var synthesized = Set<UUID>()
    private var refOrder: [String: [String]] = [:]   // keyword → names in `ref` order
    private var queryOrder: [String]?
    var aggregationState = TMDLAggregations.ReadState()

    private mutating func warn(_ m: String, _ node: TMDLNode, _ file: String?) {
        warnings.append(ImportWarning(m, severity: .info, location: file.map { "\($0):\(node.line)" }))
    }

    private mutating func id(_ text: String?) -> UUID {
        if let text, let u = UUID(uuidString: text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) { return u }
        let u = UUID()
        synthesized.insert(u)
        return u
    }
    private mutating func facetID(_ node: TMDLNode) -> UUID { id(node.facet("id")?.stringValue) }

    private mutating func noteUnknown(_ node: TMDLNode, properties: Set<String>, children: Set<String>, expressions: Set<String> = [], file: String?) {
        for p in node.properties where !properties.contains(p.key.lowercased()) {
            warn("Ignored \(node.keyword) property “\(p.key)”.", node, file)
        }
        for p in node.expressionProperties where !expressions.contains(p.key.lowercased()) {
            warn("Ignored \(node.keyword) expression “\(p.key)”.", node, file)
        }
        for c in node.children where !children.contains(c.keyword.lowercased()) && c.keyword != "annotation" {
            warn("Ignored \(c.keyword) “\(c.name)” in \(node.keyword) “\(node.name)”.", c, file)
        }
    }

    // MARK: Merge

    /// Merges one top-level TMDL object into `model` (create or replace by name).
    mutating func merge(_ node: TMDLNode, into model: inout SemanticModel, queries: inout [QueryDefinition], file: String? = nil) throws {
        let kw = node.keyword.lowercased()
        if node.isRef {
            if kw == "table", !node.children.isEmpty || !node.properties.isEmpty {
                try mergePartialTable(node, into: &model, queries: &queries, file: file)
            } else {
                refOrder[kw, default: []].append(node.name)
            }
            return
        }
        switch kw {
        case "database":
            model.name = node.name
        case "model":
            applyModel(node, to: &model, file: file)
        case "table":
            if !node.children("calculationGroup").isEmpty || node.flag("calculationGroup") == true {
                var g = calculationGroup(node, file: file)
                if let i = model.calculationGroups.firstIndex(where: { same($0.name, g.name) }) {
                    if synthesized.contains(g.id) { g.id = model.calculationGroups[i].id }
                    let old = model.calculationGroups[i]
                    for j in g.items.indices where synthesized.contains(g.items[j].id) {
                        if let o = old.items.first(where: { same($0.name, g.items[j].name) }) { g.items[j].id = o.id }
                    }
                    model.calculationGroups[i] = g
                } else { model.calculationGroups.append(g) }
                model.tables.removeAll { same($0.name, g.name) }
            } else {
                var (t, q, alternates) = try table(node, file: file)
                if let i = model.tableIndex(t.name) {
                    inheritIDs(&t, from: model.tables[i])
                    model.tables[i] = t
                } else { model.tables.append(t) }
                TMDLAggregations.reconcile(table: t.name, columns: alternates, model: &model, state: &aggregationState)
                model.calculationGroups.removeAll { same($0.name, t.name) }
                if let q { upsert(q, into: &queries) }
            }
        case "relationship":
            var r = try relationship(node, file: file)
            if let i = model.relationships.firstIndex(where: { $0.id == r.id }) { model.relationships[i] = r }
            else if synthesized.contains(r.id), let i = model.relationships.firstIndex(where: {
                $0.fromTable == r.fromTable && $0.fromColumn == r.fromColumn && $0.toTable == r.toTable && $0.toColumn == r.toColumn
            }) { r.id = model.relationships[i].id; model.relationships[i] = r }
            else { model.relationships.append(r) }
        case "role":
            var r = role(node, file: file)
            if let i = model.roles.firstIndex(where: { same($0.name, r.name) }) {
                if synthesized.contains(r.id) { r.id = model.roles[i].id }
                model.roles[i] = r
            } else { model.roles.append(r) }
        case "perspective":
            var p = perspective(node, file: file)
            if let i = model.perspectives.firstIndex(where: { same($0.name, p.name) }) {
                if synthesized.contains(p.id) { p.id = model.perspectives[i].id }
                model.perspectives[i] = p
            } else { model.perspectives.append(p) }
        case "cultureinfo":
            var c = culture(node, file: file)
            if let i = model.translations.firstIndex(where: { same($0.culture, c.culture) }) {
                if synthesized.contains(c.id) { c.id = model.translations[i].id }
                model.translations[i] = c
            } else { model.translations.append(c) }
        case "function":
            var f = function(node, file: file)
            if let i = model.functions.firstIndex(where: { same($0.name, f.name) }) {
                if synthesized.contains(f.id) { f.id = model.functions[i].id }
                model.functions[i] = f
            } else { model.functions.append(f) }
        case "expression":
            upsert(query(node, script: node.expression ?? "", shared: true), into: &queries)
        case "annotation":
            break
        default:
            warn("Ignored unsupported object “\(node.keyword) \(node.name)”.", node, file)
        }
    }

    private func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    private mutating func upsert(_ q: QueryDefinition, into queries: inout [QueryDefinition]) {
        var q = q
        if let i = queries.firstIndex(where: { $0.name == q.name }) {
            if synthesized.contains(q.id) { q.id = queries[i].id }
            queries[i] = q
        } else { queries.append(q) }
    }

    private func inheritIDs(_ t: inout ModelTable, from old: ModelTable) {
        if synthesized.contains(t.id) { t.id = old.id }
        for i in t.columns.indices where synthesized.contains(t.columns[i].id) {
            if let o = old.column(t.columns[i].name) { t.columns[i].id = o.id }
        }
        for i in t.measures.indices where synthesized.contains(t.measures[i].id) {
            if let o = old.measure(t.measures[i].name) { t.measures[i].id = o.id }
        }
        for i in t.hierarchies.indices where synthesized.contains(t.hierarchies[i].id) {
            if let o = old.hierarchies.first(where: { same($0.name, t.hierarchies[i].name) }) { t.hierarchies[i].id = o.id }
        }
    }

    /// `ref table X` with children (TMDL-view scripts): create-or-replace the listed child objects only.
    private mutating func mergePartialTable(_ node: TMDLNode, into model: inout SemanticModel, queries: inout [QueryDefinition], file: String?) throws {
        guard let i = model.tableIndex(node.name) else {
            throw TMDLError("The script refers to table “\(node.name)”, which doesn't exist in the model.", file: file, line: node.line)
        }
        let (partial, q, alternates) = try table(node, file: file)
        TMDLAggregations.reconcile(table: model.tables[i].name, columns: alternates, model: &model, state: &aggregationState)
        var t = model.tables[i]
        for var c in partial.columns {
            if let j = t.columns.firstIndex(where: { same($0.name, c.name) }) {
                if synthesized.contains(c.id) { c.id = t.columns[j].id }
                t.columns[j] = c
            } else { t.columns.append(c) }
        }
        for var m in partial.measures {
            if let j = t.measures.firstIndex(where: { same($0.name, m.name) }) {
                if synthesized.contains(m.id) { m.id = t.measures[j].id }
                t.measures[j] = m
            } else { t.measures.append(m) }
        }
        for var h in partial.hierarchies {
            if let j = t.hierarchies.firstIndex(where: { same($0.name, h.name) }) {
                if synthesized.contains(h.id) { h.id = t.hierarchies[j].id }
                t.hierarchies[j] = h
            } else { t.hierarchies.append(h) }
        }
        if !node.children("partition").isEmpty {
            t.expression = partial.expression
            t.sourceQuery = partial.sourceQuery
            t.storageMode = partial.storageMode
            if let q { upsert(q, into: &queries) }
        }
        if !node.children("refreshPolicy").isEmpty { t.incrementalRefresh = partial.incrementalRefresh }
        model.tables[i] = t
    }

    /// Restores `ref` and query ordering once all files are merged.
    mutating func finish(_ model: inout SemanticModel, queries: inout [QueryDefinition]) {
        func reorder<T>(_ items: [T], by names: [String]?, name: (T) -> String) -> [T] {
            guard let names, !names.isEmpty else { return items }
            var rank: [String: Int] = [:]
            for (i, n) in names.enumerated() where rank[n.lowercased()] == nil { rank[n.lowercased()] = i }
            return items.enumerated().sorted { a, b in
                let ra = rank[name(a.element).lowercased()] ?? Int.max, rb = rank[name(b.element).lowercased()] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }
        model.tables = reorder(model.tables, by: refOrder["table"]) { $0.name }
        model.calculationGroups = reorder(model.calculationGroups, by: refOrder["table"]) { $0.name }
        model.roles = reorder(model.roles, by: refOrder["role"]) { $0.name }
        model.perspectives = reorder(model.perspectives, by: refOrder["perspective"]) { $0.name }
        model.translations = reorder(model.translations, by: refOrder["cultureinfo"]) { $0.culture }
        queries = reorder(queries, by: queryOrder) { $0.name }
        TMDLAggregations.finish(&model, state: &aggregationState)
    }

    // MARK: Model

    private mutating func applyModel(_ node: TMDLNode, to model: inout SemanticModel, file: String?) {
        if let c = node.prop("culture") { model.culture = c }
        if let v = node.facet("autoDateTime")?.boolValue { model.autoDateTime = v }
        if let v = node.annotation("__PBI_TimeIntelligenceEnabled") { model.autoDateTime = v.trimmingCharacters(in: .whitespaces) == "1" }
        if let v = node.facet("autodetectRelationships")?.boolValue { model.autodetectRelationships = v }
        if let v = node.facet("fieldParameters", as: [FieldParameter].self) { model.fieldParameters = v }
        if let v = node.facet("whatIfParameters", as: [WhatIfParameter].self) { model.whatIfParameters = v }
        if let v = node.facet("aggregations", as: [AggregationMapping].self) {
            model.aggregations = v
            aggregationState.flagged.formUnion(TMDLAggregations.flagged(in: node.facet("aggregations")))
        }
        if let v = node.facet("layouts", as: [ModelLayout].self) { model.layouts = v }
        if let v = node.facet("aiExcludedFields", as: [String].self) { model.aiExcludedFields = v }
        if let v = node.facet("aiInstructions")?.stringValue { model.aiInstructions = v }
        if let v = node.facet("verifiedAnswers", as: [VerifiedAnswer].self) { model.verifiedAnswers = v }
        if let v = node.facet("qnaSynonyms", as: [String: [String]].self) { model.qnaSynonyms = v }
        if let v = node.facet("queryOrder", as: [String].self) { queryOrder = v }
    }

    // MARK: Tables

    private mutating func table(_ node: TMDLNode, file: String?) throws
        -> (ModelTable, QueryDefinition?, [(name: String, native: AggregationMapping?)]) {
        var t = ModelTable(name: node.name)
        t.id = id(node.prop("lineageTag"))
        t.description = node.description
        t.isHidden = node.flag("isHidden") ?? false
        t.columns = node.children("column").map { column($0, file: file) }
        t.measures = node.children("measure").map { measure($0, file: file) }
        t.hierarchies = node.children("hierarchy").map { hierarchy($0, file: file) }
        var query: QueryDefinition?
        var partitionM: String?
        let partitions = node.children("partition")
        if partitions.count > 1 { warn("Table “\(node.name)” has \(partitions.count) partitions; only the first is used.", node, file) }
        if let p = partitions.first {
            let kind = (p.expression ?? "").lowercased()
            let source = p.expr("source") ?? ""
            if let m = p.prop("mode").flatMap(TMDLVocabulary.parseStorageMode) { t.storageMode = m }
            switch kind {
            case "m":
                var q = self.query(p, script: source, shared: false)
                q.name = p.name
                t.sourceQuery = p.name
                query = q
                partitionM = source
            case "calculated":
                t.expression = source
            default:
                warn("Partition “\(p.name)” of kind “\(kind)” isn't supported; the table has no source.", p, file)
            }
        }
        if let s = node.facet("storageMode")?.stringValue.flatMap(StorageMode.init(rawValue:)) { t.storageMode = s }
        if let q = node.facet("sourceQuery")?.stringValue { t.sourceQuery = q }
        if let d = node.facet("dateColumn")?.stringValue { t.dateColumn = d }
        else if node.prop("dataCategory")?.lowercased() == "time" {
            t.dateColumn = t.columns.first { $0.isKey && $0.dataType.isTemporal }?.name ?? t.columns.first { $0.dataType.isTemporal }?.name
        }
        t.synonyms = node.facet("synonyms", as: [String].self) ?? []
        t.isFeatured = node.facet("isFeatured")?.boolValue ?? false
        t.rowLabelColumn = node.facet("rowLabelColumn")?.stringValue
        t.keyColumn = node.facet("keyColumn")?.stringValue
        t.calendars = node.facet("calendars", as: [CalendarDefinition].self) ?? []
        if let rp = node.children("refreshPolicy").first {
            let annotated = node.facet(TMDLRefreshPolicy.dateColumnAnnotation)?.stringValue
            let (policy, problems) = TMDLRefreshPolicy.parse(rp, partitionSource: partitionM, annotatedDateColumn: annotated)
            t.incrementalRefresh = policy
            for m in problems { warn(m, rp, file) }
            noteUnknown(rp, properties: TMDLRefreshPolicy.properties, children: [], expressions: TMDLRefreshPolicy.expressions, file: file)
        } else {
            t.incrementalRefresh = node.facet("incrementalRefresh", as: IncrementalRefreshPolicy.self)   // files before refreshPolicy
        }
        let (alternates, problems) = TMDLAggregations.columns(of: node, table: t.name)
        for (m, n) in problems { warn(m, n, file) }
        noteUnknown(node, properties: ["lineagetag", "ishidden", "datacategory"],
                    children: ["column", "measure", "hierarchy", "partition", "refreshpolicy"], file: file)
        return (t, query, alternates)
    }

    private mutating func column(_ node: TMDLNode, file: String?) -> ModelColumn {
        let type = node.facet("dataType")?.stringValue.flatMap(DataType.init(rawValue:))
            ?? node.prop("dataType").flatMap(TMDLVocabulary.parseDataType) ?? .any
        var c = ModelColumn(name: node.name, dataType: type, expression: node.expression)
        c.id = id(node.prop("lineageTag"))
        c.description = node.description
        c.formatString = node.prop("formatString") ?? ""
        c.isHidden = node.flag("isHidden") ?? false
        c.isKey = node.flag("isKey") ?? false
        c.isNullable = node.flag("isNullable") ?? true
        c.summarizeBy = node.facet("summarizeBy")?.stringValue.flatMap(Aggregation.init(rawValue:))
            ?? node.prop("summarizeBy").map(TMDLVocabulary.parseSummarize) ?? .none
        c.sortByColumn = node.prop("sortByColumn").map(TMDLName.unquote)
        c.displayFolder = node.prop("displayFolder") ?? ""
        c.dataCategory = node.prop("dataCategory").flatMap(TMDLVocabulary.parseCategory) ?? .uncategorized
        c.formatLocale = node.facet("formatLocale")?.stringValue ?? ""
        c.synonyms = node.facet("synonyms", as: [String].self) ?? []
        c.grouping = node.facet("grouping", as: ColumnGrouping.self)
        noteUnknown(node, properties: ["datatype", "formatstring", "ishidden", "iskey", "isnullable", "lineagetag", "summarizeby",
                                       "sourcecolumn", "sortbycolumn", "displayfolder", "datacategory"], children: ["alternateof"], file: file)
        return c
    }

    private mutating func measure(_ node: TMDLNode, file: String?) -> Measure {
        var m = Measure(name: node.name, expression: node.expression ?? "", formatString: node.prop("formatString") ?? "")
        m.id = id(node.prop("lineageTag"))
        m.description = node.description
        m.formatExpression = node.expr("formatStringDefinition")
        m.displayFolder = node.prop("displayFolder") ?? ""
        m.isHidden = node.flag("isHidden") ?? false
        m.dataCategory = node.prop("dataCategory").flatMap(TMDLVocabulary.parseCategory) ?? .uncategorized
        noteUnknown(node, properties: ["formatstring", "displayfolder", "ishidden", "datacategory", "lineagetag"],
                    children: [], expressions: ["formatstringdefinition"], file: file)
        return m
    }

    private mutating func hierarchy(_ node: TMDLNode, file: String?) -> Hierarchy {
        var h = Hierarchy(name: node.name, levels: node.children("level").map { $0.prop("column").map(TMDLName.unquote) ?? $0.name })
        h.id = id(node.prop("lineageTag"))
        h.isHidden = node.flag("isHidden") ?? false
        return h
    }

    private mutating func calculationGroup(_ node: TMDLNode, file: String?) -> CalculationGroup {
        var g = CalculationGroup(name: node.name)
        g.id = id(node.prop("lineageTag"))
        g.columnName = node.children("column").first?.name ?? "Name"
        if let cg = node.children("calculationGroup").first {
            g.precedence = cg.prop("precedence").flatMap { Int($0) } ?? 0
            for (i, n) in cg.children("calculationItem").enumerated() {
                var item = CalculationItem(name: n.name, expression: n.expression ?? "")
                item.id = facetID(n)
                item.ordinal = n.prop("ordinal").flatMap { Int($0) } ?? i
                item.formatExpression = n.expr("formatStringDefinition")
                g.items.append(item)
            }
        }
        return g
    }

    // MARK: Queries

    private mutating func query(_ node: TMDLNode, script: String, shared: Bool) -> QueryDefinition {
        var q = QueryDefinition(name: node.name, mScript: script)
        q.description = node.description
        q.group = node.prop("queryGroup").map(TMDLName.unquote) ?? ""
        let extra = node.facet("query")
        q.id = id(extra?["id"]?.stringValue ?? (shared ? node.prop("lineageTag") : nil))
        q.loadEnabled = extra?["loadEnabled"]?.boolValue ?? !shared
        q.includeInRefresh = extra?["includeInRefresh"]?.boolValue ?? true
        if let k = extra?["kind"]?.stringValue.flatMap(QueryDefinition.Kind.init(rawValue:)) { q.kind = k }
        else if extra == nil { q.kind = MScript.inferKind(script) }
        if let p = extra?["parameter"], let decoded = try? p.decode(QueryParameter.self) { q.parameter = decoded }
        else if extra == nil, q.kind == .parameter { q.parameter = MScript.parameter(from: script) }
        return q
    }

    // MARK: Relationships and security

    private mutating func relationship(_ node: TMDLNode, file: String?) throws -> Relationship {
        let from = TMDLName.splitQualified(node.prop("fromColumn") ?? ""), to = TMDLName.splitQualified(node.prop("toColumn") ?? "")
        guard from.count == 2, to.count == 2 else {
            throw TMDLError("Relationship “\(node.name)” needs fromColumn and toColumn in the form Table.Column.", file: file, line: node.line)
        }
        var r = Relationship(fromTable: from[0], fromColumn: from[1], toTable: to[0], toColumn: to[1])
        r.id = id(node.name)
        let fromOne = node.prop("fromCardinality")?.lowercased() == "one"
        let toMany = node.prop("toCardinality")?.lowercased() == "many"
        r.cardinality = fromOne ? (toMany ? .oneToMany : .oneToOne) : (toMany ? .manyToMany : .manyToOne)
        r.crossFilter = node.prop("crossFilteringBehavior")?.lowercased() == "bothdirections" ? .both : .single
        r.isActive = node.flag("isActive") ?? true
        r.assumeReferentialIntegrity = node.flag("relyOnReferentialIntegrity") ?? false
        r.securityFilterBothDirections = node.prop("securityFilteringBehavior")?.lowercased() == "bothdirections"
        noteUnknown(node, properties: ["fromcolumn", "tocolumn", "fromcardinality", "tocardinality", "crossfilteringbehavior", "isactive",
                                       "relyonreferentialintegrity", "securityfilteringbehavior"], children: [], file: file)
        return r
    }

    private mutating func role(_ node: TMDLNode, file: String?) -> SecurityRole {
        var r = SecurityRole(name: node.name)
        r.id = facetID(node)
        r.description = node.description
        for tp in node.children("tablePermission") {
            if let f = tp.expression { r.tableFilters[tp.name] = f }
            if tp.prop("metadataPermission")?.lowercased() == "none" { r.hiddenTables.append(tp.name) }
            for cp in tp.children("columnPermission") where (cp.expression ?? cp.prop("metadataPermission") ?? "none").lowercased() == "none" {
                r.hiddenColumns.append("\(tp.name)[\(cp.name)]")
            }
        }
        if let v = node.facet("hiddenTables", as: [String].self) { r.hiddenTables = v }
        if let v = node.facet("hiddenColumns", as: [String].self) { r.hiddenColumns = v }
        noteUnknown(node, properties: ["modelpermission"], children: ["tablepermission"], file: file)
        return r
    }

    private mutating func perspective(_ node: TMDLNode, file: String?) -> Perspective {
        var p = Perspective(name: node.name)
        p.id = facetID(node)
        for pt in node.children("perspectiveTable") {
            if pt.flag("includeAll") == true { p.members.append(pt.name) }
            for c in pt.children where c.keyword.lowercased().hasPrefix("perspective") {
                p.members.append("\(pt.name)[\(c.name)]")
            }
        }
        if let v = node.facet("members", as: [String].self) { p.members = v }
        return p
    }

    private mutating func culture(_ node: TMDLNode, file: String?) -> Translation {
        var c = Translation(culture: node.name)
        c.id = facetID(node)
        // translations → model → table → (column | measure | hierarchy), each with `caption:`.
        let models = node.children("translations").flatMap { $0.children("model") } + node.children("translation").flatMap { $0.children("model") }
        for m in models {
            for t in m.children("table") {
                if let cap = t.prop("caption") ?? t.prop("translatedCaption") { c.captions[t.name] = cap }
                for member in t.children where member.keyword != "annotation" {
                    if let cap = member.prop("caption") ?? member.prop("translatedCaption") { c.captions["\(t.name)[\(member.name)]"] = cap }
                }
            }
        }
        if let extra = node.facet("captions", as: [String: String].self) { c.captions.merge(extra) { _, new in new } }
        return c
    }

    private mutating func function(_ node: TMDLNode, file: String?) -> UserFunction {
        let text = node.expression ?? ""
        var f = UserFunction(name: node.name, expression: text)
        if let parsed = TMDLFunctionSignature.parse(text) { f.parameters = parsed.parameters; f.expression = parsed.body }
        if let p = node.facet("parameters", as: [FunctionParameter].self) { f.parameters = p }
        if let b = node.facet("body")?.stringValue { f.expression = b }
        f.id = id(node.prop("lineageTag"))
        f.description = node.description
        return f
    }
}

/// Small helpers for reading Power Query (M) text without evaluating it.
enum MScript {
    static func inferKind(_ script: String) -> QueryDefinition.Kind {
        let compact = script.replacingOccurrences(of: " ", with: "")
        if compact.range(of: "IsParameterQuery=true", options: .caseInsensitive) != nil { return .parameter }
        let t = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("("), let arrow = t.range(of: "=>"), let letRange = t.range(of: "let"), arrow.lowerBound < letRange.lowerBound { return .function }
        if t.hasPrefix("("), t.contains("=>"), !t.contains("let") { return .function }
        return .table
    }

    /// Reads `<literal> meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true, List={…}]`.
    static func parameter(from script: String) -> QueryParameter? {
        guard let metaRange = script.range(of: " meta ", options: [.caseInsensitive, .backwards]) else { return nil }
        var p = QueryParameter()
        let literal = script[..<metaRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = String(script[metaRange.upperBound...])
        p.currentValue = value(fromLiteral: literal)
        p.defaultValue = p.currentValue
        func field(_ name: String) -> String? {
            guard let r = meta.range(of: name + "\\s*=\\s*", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let rest = meta[r.upperBound...]
            if rest.first == "\"" {
                let body = rest.dropFirst()
                return body.firstIndex(of: "\"").map { String(body[..<$0]) }
            }
            return String(rest.prefix { $0 != "," && $0 != "]" }).trimmingCharacters(in: .whitespaces)
        }
        switch (field("Type") ?? "").lowercased() {
        case "text": p.type = .text
        case "number", "decimal": p.type = .decimal
        case "int64", "whole number": p.type = .integer
        case "logical", "true/false": p.type = .boolean
        case "date": p.type = .date
        case "datetime", "date/time": p.type = .dateTime
        case "time": p.type = .time
        case "duration": p.type = .duration
        case "binary": p.type = .binary
        default: p.type = p.currentValue.isNull ? .any : p.currentValue.dataType
        }
        p.isRequired = (field("IsParameterQueryRequired") ?? "true").lowercased() != "false"
        if let r = meta.range(of: "List\\s*=\\s*\\{", options: [.regularExpression, .caseInsensitive]),
           let end = meta[r.upperBound...].firstIndex(of: "}") {
            p.suggestedValues = splitTopLevel(String(meta[r.upperBound..<end]), separator: ",").map { value(fromLiteral: $0.trimmingCharacters(in: .whitespaces)) }
        }
        return p
    }

    /// Parses an M literal (text, number, logical, null, #date/#datetime).
    static func value(fromLiteral s: String) -> Value {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "null" || t.isEmpty { return .null }
        if t == "true" { return .bool(true) }
        if t == "false" { return .bool(false) }
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            return .string(String(t.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\""))
        }
        if let i = Int64(t) { return .int(i) }
        if let d = Double(t) { return .double(d) }
        for prefix in ["#datetime(", "#date("] where t.hasPrefix(prefix) && t.hasSuffix(")") {
            let nums = t.dropFirst(prefix.count).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if nums.count >= 3 {
                var c = DateComponents()
                c.year = nums[0]; c.month = nums[1]; c.day = nums[2]
                c.hour = nums[safe: 3] ?? 0; c.minute = nums[safe: 4] ?? 0; c.second = nums[safe: 5] ?? 0
                if let d = Calendar.utc.date(from: c) { return .date(d) }
            }
        }
        return .string(t)
    }

    /// Formats a value as an M literal.
    static func literal(_ v: Value, type: DataType = .any) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return text(s)
        case .date(let d):
            let c = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            if type == .date || (c.hour == 0 && c.minute == 0 && c.second == 0 && type != .dateTime) {
                return "#date(\(c.year ?? 1970), \(c.month ?? 1), \(c.day ?? 1))"
            }
            return "#datetime(\(c.year ?? 1970), \(c.month ?? 1), \(c.day ?? 1), \(c.hour ?? 0), \(c.minute ?? 0), \(c.second ?? 0))"
        }
    }
    static func text(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func typeName(_ t: DataType) -> String {
        switch t {
        case .text: return "Text"
        case .integer, .decimal, .currency: return "Number"
        case .boolean: return "Logical"
        case .date: return "Date"
        case .dateTime: return "DateTime"
        case .time: return "Time"
        case .duration: return "Duration"
        case .binary: return "Binary"
        case .any: return "Any"
        }
    }

    /// The M script of a parameter query.
    static func parameterScript(_ p: QueryParameter) -> String {
        var meta = "IsParameterQuery=true, Type=\"\(typeName(p.type))\", IsParameterQueryRequired=\(p.isRequired)"
        if !p.suggestedValues.isEmpty { meta += ", List={\(p.suggestedValues.map { literal($0, type: p.type) }.joined(separator: ", "))}" }
        if !p.defaultValue.isNull { meta += ", DefaultValue=\(literal(p.defaultValue, type: p.type))" }
        return "\(literal(p.currentValue, type: p.type)) meta [\(meta)]"
    }

    /// Splits on a separator outside quotes and brackets.
    static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var out: [String] = [], cur = "", depth = 0, inString = false
        for ch in s {
            if ch == "\"" { inString.toggle() }
            if !inString {
                if "([{".contains(ch) { depth += 1 } else if ")]}".contains(ch) { depth -= 1 }
                if ch == separator, depth == 0 { out.append(cur); cur = ""; continue }
            }
            cur.append(ch)
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }
}
