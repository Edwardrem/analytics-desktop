import Foundation
import FacetCore

/// Tabular Model Definition Language: serialise, parse, script and apply semantic-model definitions.
public enum TMDL {
    /// Serialises a model into the TMDL folder layout used by Power BI projects
    /// (`database.tmdl`, `model.tmdl`, `relationships.tmdl`, `expressions.tmdl`, `functions.tmdl`,
    /// `tables/*.tmdl`, `roles/*.tmdl`, `perspectives/*.tmdl`, `cultures/*.tmdl`).
    /// Properties that only Facet understands are stored as `annotation Facet_<name> = <json>` so the round trip is lossless.
    public static func serialize(model: SemanticModel, queries: [QueryDefinition] = []) -> [TMDLFile] {
        TMDLWriter(model: model, queries: queries).files()
    }
}

// MARK: - Vocabulary mapping

enum TMDLVocabulary {
    static func dataType(_ t: DataType) -> (name: String, exact: Bool) {
        switch t {
        case .text: return ("string", true)
        case .integer: return ("int64", true)
        case .decimal: return ("double", true)
        case .currency: return ("decimal", true)
        case .boolean: return ("boolean", true)
        case .dateTime: return ("dateTime", true)
        case .date, .time: return ("dateTime", false)
        case .duration: return ("double", false)
        case .binary: return ("binary", true)
        case .any: return ("variant", true)
        }
    }
    static func parseDataType(_ s: String) -> DataType? {
        switch s.lowercased() {
        case "string": return .text
        case "int64": return .integer
        case "double": return .decimal
        case "decimal": return .currency
        case "boolean": return .boolean
        case "datetime": return .dateTime
        case "binary": return .binary
        case "variant", "unknown", "automatic": return .any
        default: return nil
        }
    }
    static let nativeSummaries: Set<Aggregation> = [.none, .sum, .min, .max, .count, .average, .distinctCount]
    static func parseSummarize(_ s: String) -> Aggregation {
        switch s.lowercased() {
        case "sum": return .sum
        case "min": return .min
        case "max": return .max
        case "count": return .count
        case "average": return .average
        case "distinctcount": return .distinctCount
        default: return .none
        }
    }
    static let categories: [(DataCategory, String)] = [
        (.address, "Address"), (.city, "City"), (.continent, "Continent"), (.country, "Country"), (.county, "County"),
        (.stateOrProvince, "StateOrProvince"), (.postalCode, "PostalCode"), (.place, "Place"), (.latitude, "Latitude"),
        (.longitude, "Longitude"), (.webURL, "WebUrl"), (.imageURL, "ImageUrl"), (.barcode, "Barcode"),
    ]
    static func category(_ c: DataCategory) -> String? { categories.first { $0.0 == c }?.1 }
    static func parseCategory(_ s: String) -> DataCategory? {
        categories.first { $0.1.caseInsensitiveCompare(s) == .orderedSame }?.0
    }
    static func storageMode(_ m: StorageMode) -> String? {
        switch m {
        case .import: return "import"
        case .directQuery: return "directQuery"
        case .dual: return "dual"
        case .directLake: return "directLake"
        case .live: return nil
        }
    }
    static func parseStorageMode(_ s: String) -> StorageMode? {
        switch s.lowercased() {
        case "import": return .import
        case "directquery": return .directQuery
        case "dual": return .dual
        case "directlake": return .directLake
        default: return nil
        }
    }

    /// Splits "Table[Name]" into its parts; a bare "Table" yields a nil member.
    static func splitMember(_ s: String) -> (table: String, member: String?)? {
        guard let open = s.firstIndex(of: "[") else { return s.isEmpty ? nil : (s, nil) }
        guard s.hasSuffix("]"), open > s.startIndex else { return nil }
        let member = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        return member.isEmpty ? nil : (String(s[..<open]), member)
    }
}

// MARK: - DAX function signatures

enum TMDLFunctionSignature {
    /// "(a : scalar val, b : anyref expr) => body"
    static func compose(_ f: UserFunction) -> String {
        let params = f.parameters.map { "\($0.name) : \($0.type) \($0.mode)" }.joined(separator: ", ")
        return "(\(params)) =>" + (f.expression.contains("\n") ? "\n" : " ") + f.expression
    }

    /// Splits a function expression into parameters and body; nil when it has no `(…) =>` head.
    static func parse(_ text: String) -> (parameters: [FunctionParameter], body: String)? {
        let chars = Array(text)
        var i = 0
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, chars[i] == "(" else { return nil }
        var depth = 0, close = -1
        var j = i
        while j < chars.count {
            if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1; if depth == 0 { close = j; break } }
            j += 1
        }
        guard close > 0 else { return nil }
        var k = close + 1
        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
        guard k + 1 < chars.count, chars[k] == "=", chars[k + 1] == ">" else { return nil }
        k += 2
        if k < chars.count, chars[k] == "\n" || chars[k] == " " || chars[k] == "\r\n" { k += 1 }
        let body = String(chars[k...])
        // Parameters, split on top-level commas.
        var params: [FunctionParameter] = []
        var cur = "", d = 0
        var pieces: [String] = []
        for ch in chars[(i + 1)..<close] {
            if ch == "(" { d += 1 } else if ch == ")" { d -= 1 }
            if ch == ",", d == 0 { pieces.append(cur); cur = "" } else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(cur) }
        for p in pieces {
            let parts = p.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            var fp = FunctionParameter(name: name)
            if parts.count > 1 {
                let words = parts[1].split(whereSeparator: \.isWhitespace).map(String.init)
                if let t = words.first { fp.type = t }
                if words.count > 1 { fp.mode = words[1] }
                if words.count > 2 { return nil }
            }
            params.append(fp)
        }
        return (params, body)
    }
}

// MARK: - Writer

struct TMDLWriter {
    let model: SemanticModel
    let queries: [QueryDefinition]
    /// Table name → the query emitted as that table's `partition … = m`.
    let partitionQuery: [String: QueryDefinition]

    init(model: SemanticModel, queries: [QueryDefinition]) {
        self.model = model
        self.queries = queries
        var map: [String: QueryDefinition] = [:]
        var used = Set<String>()
        for t in model.tables where t.expression == nil {
            guard let q = t.sourceQuery, !used.contains(q), let def = queries.first(where: { $0.name == q }) else { continue }
            used.insert(q)
            map[t.name] = def
        }
        partitionQuery = map
    }

    var sharedQueries: [QueryDefinition] {
        let used = Set(partitionQuery.values.map(\.id))
        return queries.filter { !used.contains($0.id) }
    }

    func files() -> [TMDLFile] {
        var out: [TMDLFile] = []
        var names = Set<String>()
        func unique(_ folder: String, _ name: String) -> String {
            let base = DocumentPackage.fileName(for: name)
            var candidate = base, n = 2
            while names.contains("\(folder)/\(candidate)".lowercased()) { candidate = "\(base) (\(n))"; n += 1 }
            names.insert("\(folder)/\(candidate)".lowercased())
            return "\(folder)/\(candidate).tmdl"
        }
        func file(_ path: String, _ build: (TMDLEmitter) -> Void) {
            let e = TMDLEmitter()
            build(e)
            out.append(TMDLFile(path: path, text: e.text))
        }

        file("database.tmdl") { e in
            e.raw(0, "database \(TMDLName.quote(model.name))")
            e.prop(1, "compatibilityLevel", "1601")
        }
        file("model.tmdl") { emitModel($0, 0, includeRefs: true) }
        if !model.relationships.isEmpty {
            file("relationships.tmdl") { e in
                for r in model.relationships { emitRelationship(e, 0, r); e.blank() }
            }
        }
        let shared = sharedQueries
        if !shared.isEmpty {
            file("expressions.tmdl") { e in for q in shared { emitExpression(e, 0, q); e.blank() } }
        }
        if !model.functions.isEmpty {
            file("functions.tmdl") { e in for f in model.functions { emitFunction(e, 0, f); e.blank() } }
        }
        for t in model.tables { file(unique("tables", t.name)) { emitTable($0, 0, t) } }
        for g in model.calculationGroups { file(unique("tables", g.name)) { emitCalculationGroup($0, 0, g) } }
        for r in model.roles { file(unique("roles", r.name)) { emitRole($0, 0, r) } }
        for p in model.perspectives { file(unique("perspectives", p.name)) { emitPerspective($0, 0, p) } }
        for c in model.translations { file(unique("cultures", c.culture)) { emitCulture($0, 0, c) } }
        return out
    }

    // MARK: Model

    func emitModel(_ e: TMDLEmitter, _ l: Int, includeRefs: Bool) {
        let defaults = SemanticModel()
        e.raw(l, "model Model")
        e.prop(l + 1, "culture", model.culture)
        e.prop(l + 1, "defaultPowerBIDataSourceVersion", "powerBI_V3")
        e.blank()
        if model.autoDateTime { e.facet(l + 1, "autoDateTime", .bool(true)) }
        if !model.fieldParameters.isEmpty { e.facet(l + 1, "fieldParameters", encoding: model.fieldParameters) }
        if !model.whatIfParameters.isEmpty { e.facet(l + 1, "whatIfParameters", encoding: model.whatIfParameters) }
        if !model.aggregations.isEmpty { e.facet(l + 1, "aggregations", encoding: model.aggregations) }
        e.facet(l + 1, "layouts", encoding: model.layouts)
        if model.aiExcludedFields != defaults.aiExcludedFields { e.facet(l + 1, "aiExcludedFields", encoding: model.aiExcludedFields) }
        if !model.aiInstructions.isEmpty { e.facet(l + 1, "aiInstructions", .string(model.aiInstructions)) }
        if !model.verifiedAnswers.isEmpty { e.facet(l + 1, "verifiedAnswers", encoding: model.verifiedAnswers) }
        if !model.qnaSynonyms.isEmpty { e.facet(l + 1, "qnaSynonyms", encoding: model.qnaSynonyms) }
        if let terms = model.qnaTerms, !terms.isEmpty { e.facet(l + 1, "qnaTerms", encoding: terms) }
        if queries.count > 1 { e.facet(l + 1, "queryOrder", .array(queries.map { .string($0.name) })) }
        guard includeRefs else { return }
        e.blank()
        for t in model.tables { e.raw(l, "ref table \(TMDLName.quote(t.name))") }
        for g in model.calculationGroups { e.raw(l, "ref table \(TMDLName.quote(g.name))") }
        for r in model.roles { e.raw(l, "ref role \(TMDLName.quote(r.name))") }
        for p in model.perspectives { e.raw(l, "ref perspective \(TMDLName.quote(p.name))") }
        for c in model.translations { e.raw(l, "ref cultureInfo \(TMDLName.quote(c.culture))") }
    }

    // MARK: Tables

    func emitTable(_ e: TMDLEmitter, _ l: Int, _ t: ModelTable) {
        e.description(l, t.description)
        e.raw(l, "table \(TMDLName.quote(t.name))")
        if t.isHidden { e.flag(l + 1, "isHidden") }
        e.prop(l + 1, "lineageTag", t.id.lower)
        if t.dateColumn != nil { e.prop(l + 1, "dataCategory", "Time") }
        e.blank()
        for m in t.measures { emitMeasure(e, l + 1, m); e.blank() }
        for c in t.columns { emitColumn(e, l + 1, c); e.blank() }
        for h in t.hierarchies { emitHierarchy(e, l + 1, h); e.blank() }

        var modeWritten = false
        var sourceQueryWritten = false
        if let dax = t.expression {
            e.raw(l + 1, "partition \(TMDLName.quote(t.name)) = calculated")
            if let m = TMDLVocabulary.storageMode(t.storageMode) { e.prop(l + 2, "mode", m); modeWritten = true }
            e.expression(l + 2, "source", dax)
            e.blank()
        } else if let q = partitionQuery[t.name] {
            emitQueryDescription(e, l + 1, q)
            e.raw(l + 1, "partition \(TMDLName.quote(q.name)) = m")
            if let m = TMDLVocabulary.storageMode(t.storageMode) { e.prop(l + 2, "mode", m); modeWritten = true }
            if !q.group.isEmpty { e.prop(l + 2, "queryGroup", TMDLName.quote(q.group)) }
            e.expression(l + 2, "source", q.mScript)
            emitQueryExtras(e, l + 2, q, sharedDefault: false)
            e.blank()
            sourceQueryWritten = true
        }
        if !modeWritten, t.storageMode != .import { e.facet(l + 1, "storageMode", .string(t.storageMode.rawValue)) }
        if !sourceQueryWritten, let q = t.sourceQuery { e.facet(l + 1, "sourceQuery", .string(q)) }
        if let d = t.dateColumn { e.facet(l + 1, "dateColumn", .string(d)) }
        if !t.synonyms.isEmpty { e.facet(l + 1, "synonyms", encoding: t.synonyms) }
        if t.isFeatured { e.facet(l + 1, "isFeatured", .bool(true)) }
        if let c = t.rowLabelColumn { e.facet(l + 1, "rowLabelColumn", .string(c)) }
        if let c = t.keyColumn { e.facet(l + 1, "keyColumn", .string(c)) }
        if !t.calendars.isEmpty { e.facet(l + 1, "calendars", encoding: t.calendars) }
        if let p = t.incrementalRefresh { e.facet(l + 1, "incrementalRefresh", encoding: p) }
    }

    func emitMeasure(_ e: TMDLEmitter, _ l: Int, _ m: Measure) {
        e.description(l, m.description)
        e.expression(l, "measure \(TMDLName.quote(m.name))", m.expression)
        if !m.formatString.isEmpty { e.prop(l + 1, "formatString", m.formatString) }
        if let f = m.formatExpression { e.expression(l + 1, "formatStringDefinition", f) }
        if !m.displayFolder.isEmpty { e.prop(l + 1, "displayFolder", m.displayFolder) }
        if m.isHidden { e.flag(l + 1, "isHidden") }
        if let c = TMDLVocabulary.category(m.dataCategory) { e.prop(l + 1, "dataCategory", c) }
        e.prop(l + 1, "lineageTag", m.id.lower)
    }

    func emitColumn(_ e: TMDLEmitter, _ l: Int, _ c: ModelColumn) {
        e.description(l, c.description)
        if let dax = c.expression { e.expression(l, "column \(TMDLName.quote(c.name))", dax) }
        else { e.raw(l, "column \(TMDLName.quote(c.name))") }
        let dt = TMDLVocabulary.dataType(c.dataType)
        e.prop(l + 1, "dataType", dt.name)
        if !c.formatString.isEmpty { e.prop(l + 1, "formatString", c.formatString) }
        if c.isHidden { e.flag(l + 1, "isHidden") }
        if c.isKey { e.flag(l + 1, "isKey") }
        if !c.isNullable { e.prop(l + 1, "isNullable", "false") }
        e.prop(l + 1, "lineageTag", c.id.lower)
        let native = TMDLVocabulary.nativeSummaries.contains(c.summarizeBy)
        e.prop(l + 1, "summarizeBy", native ? c.summarizeBy.rawValue : "none")
        if c.expression == nil { e.prop(l + 1, "sourceColumn", c.name) }
        if let s = c.sortByColumn { e.prop(l + 1, "sortByColumn", TMDLName.quote(s)) }
        if !c.displayFolder.isEmpty { e.prop(l + 1, "displayFolder", c.displayFolder) }
        if let cat = TMDLVocabulary.category(c.dataCategory) { e.prop(l + 1, "dataCategory", cat) }
        if !dt.exact { e.facet(l + 1, "dataType", .string(c.dataType.rawValue)) }
        if !native { e.facet(l + 1, "summarizeBy", .string(c.summarizeBy.rawValue)) }
        if !c.formatLocale.isEmpty { e.facet(l + 1, "formatLocale", .string(c.formatLocale)) }
        if !c.synonyms.isEmpty { e.facet(l + 1, "synonyms", encoding: c.synonyms) }
        if let g = c.grouping { e.facet(l + 1, "grouping", encoding: g) }
    }

    func emitHierarchy(_ e: TMDLEmitter, _ l: Int, _ h: Hierarchy) {
        e.raw(l, "hierarchy \(TMDLName.quote(h.name))")
        e.prop(l + 1, "lineageTag", h.id.lower)
        if h.isHidden { e.flag(l + 1, "isHidden") }
        // Level names must be unique; a repeated column gets a numeric suffix.
        var seen: [String: Int] = [:]
        for column in h.levels {
            seen[column, default: 0] += 1
            let levelName = seen[column] == 1 ? column : "\(column) \(seen[column] ?? 2)"
            e.blank()
            e.raw(l + 1, "level \(TMDLName.quote(levelName))")
            e.prop(l + 2, "column", TMDLName.quote(column))
        }
    }

    func emitCalculationGroup(_ e: TMDLEmitter, _ l: Int, _ g: CalculationGroup) {
        e.raw(l, "table \(TMDLName.quote(g.name))")
        e.prop(l + 1, "lineageTag", g.id.lower)
        e.blank()
        e.raw(l + 1, "calculationGroup")
        e.prop(l + 2, "precedence", String(g.precedence))
        for item in g.items {
            e.blank()
            e.expression(l + 2, "calculationItem \(TMDLName.quote(item.name))", item.expression)
            e.prop(l + 3, "ordinal", String(item.ordinal))
            if let f = item.formatExpression { e.expression(l + 3, "formatStringDefinition", f) }
            e.facet(l + 3, "id", .string(item.id.lower))
        }
        e.blank()
        e.raw(l + 1, "column \(TMDLName.quote(g.columnName))")
        e.prop(l + 2, "dataType", "string")
        e.prop(l + 2, "summarizeBy", "none")
        e.prop(l + 2, "sourceColumn", "Name")
    }

    // MARK: Queries

    func emitQueryDescription(_ e: TMDLEmitter, _ l: Int, _ q: QueryDefinition) { e.description(l, q.description) }

    /// Query properties that TMDL has no home for, as one `Facet_query` annotation.
    func emitQueryExtras(_ e: TMDLEmitter, _ l: Int, _ q: QueryDefinition, sharedDefault: Bool) {
        var extra: [String: JSONValue] = ["id": .string(q.id.lower)]
        if q.kind != .table { extra["kind"] = .string(q.kind.rawValue) }
        if q.loadEnabled != !sharedDefault { extra["loadEnabled"] = .bool(q.loadEnabled) }
        if !q.includeInRefresh { extra["includeInRefresh"] = .bool(false) }
        if let p = q.parameter, let j = try? JSONValue(encoding: p) { extra["parameter"] = j }
        e.facet(l, "query", .object(extra))
    }

    func emitExpression(_ e: TMDLEmitter, _ l: Int, _ q: QueryDefinition) {
        emitQueryDescription(e, l, q)
        e.expression(l, "expression \(TMDLName.quote(q.name))", q.mScript)
        if !q.group.isEmpty { e.prop(l + 1, "queryGroup", TMDLName.quote(q.group)) }
        emitQueryExtras(e, l + 1, q, sharedDefault: true)
    }

    // MARK: Relationships, roles, perspectives, cultures, functions

    func emitRelationship(_ e: TMDLEmitter, _ l: Int, _ r: Relationship) {
        e.raw(l, "relationship \(r.id.lower)")
        e.prop(l + 1, "fromColumn", TMDLName.qualified(r.fromTable, r.fromColumn))
        e.prop(l + 1, "toColumn", TMDLName.qualified(r.toTable, r.toColumn))
        switch r.cardinality {
        case .manyToOne: break
        case .oneToOne: e.prop(l + 1, "fromCardinality", "one")
        case .oneToMany: e.prop(l + 1, "fromCardinality", "one"); e.prop(l + 1, "toCardinality", "many")
        case .manyToMany: e.prop(l + 1, "toCardinality", "many")
        }
        if r.crossFilter == .both { e.prop(l + 1, "crossFilteringBehavior", "bothDirections") }
        if !r.isActive { e.prop(l + 1, "isActive", "false") }
        if r.assumeReferentialIntegrity { e.flag(l + 1, "relyOnReferentialIntegrity") }
        if r.securityFilterBothDirections { e.prop(l + 1, "securityFilteringBehavior", "bothDirections") }
    }

    /// Tables in a role's permissions, in emission order, and the object-level lists that order implies.
    static func roleLayout(_ r: SecurityRole) -> (tables: [String], hiddenTables: [String], hiddenColumns: [String]) {
        var columnsByTable: [String: [String]] = [:]
        for hc in r.hiddenColumns {
            if let (t, c) = TMDLVocabulary.splitMember(hc), let c { columnsByTable[t, default: []].append(c) }
        }
        let tables = Set(r.tableFilters.keys).union(r.hiddenTables).union(columnsByTable.keys).sorted()
        let hiddenSet = Set(r.hiddenTables)
        let hiddenTables = tables.filter(hiddenSet.contains)
        let hiddenColumns = tables.flatMap { t in (columnsByTable[t] ?? []).map { "\(t)[\($0)]" } }
        return (tables, hiddenTables, hiddenColumns)
    }

    func emitRole(_ e: TMDLEmitter, _ l: Int, _ r: SecurityRole) {
        e.description(l, r.description)
        e.raw(l, "role \(TMDLName.quote(r.name))")
        e.prop(l + 1, "modelPermission", "read")
        e.facet(l + 1, "id", .string(r.id.lower))
        let layout = TMDLWriter.roleLayout(r)
        if layout.hiddenTables != r.hiddenTables { e.facet(l + 1, "hiddenTables", encoding: r.hiddenTables) }
        if layout.hiddenColumns != r.hiddenColumns { e.facet(l + 1, "hiddenColumns", encoding: r.hiddenColumns) }
        var columnsByTable: [String: [String]] = [:]
        for hc in r.hiddenColumns {
            if let (t, c) = TMDLVocabulary.splitMember(hc), let c { columnsByTable[t, default: []].append(c) }
        }
        for t in layout.tables {
            e.blank()
            if let filter = r.tableFilters[t] { e.expression(l + 1, "tablePermission \(TMDLName.quote(t))", filter) }
            else { e.raw(l + 1, "tablePermission \(TMDLName.quote(t))") }
            if r.hiddenTables.contains(t) { e.prop(l + 2, "metadataPermission", "none") }
            for c in columnsByTable[t] ?? [] {
                e.raw(l + 2, "columnPermission \(TMDLName.quote(c)) = none")
            }
        }
    }

    /// Groups perspective members by table in first-appearance order; returns the member list that grouping implies.
    static func perspectiveLayout(_ p: Perspective) -> (tables: [(name: String, includeAll: Bool, members: [String])], implied: [String]) {
        var order: [String] = []
        var all = Set<String>()
        var members: [String: [String]] = [:]
        for m in p.members {
            guard let (t, member) = TMDLVocabulary.splitMember(m) else { continue }
            if members[t] == nil { members[t] = []; order.append(t) }
            if let member { members[t]?.append(member) } else { all.insert(t) }
        }
        let tables = order.map { (name: $0, includeAll: all.contains($0), members: members[$0] ?? []) }
        let implied = tables.flatMap { t in (t.includeAll ? [t.name] : []) + t.members.map { "\(t.name)[\($0)]" } }
        return (tables, implied)
    }

    func emitPerspective(_ e: TMDLEmitter, _ l: Int, _ p: Perspective) {
        e.raw(l, "perspective \(TMDLName.quote(p.name))")
        e.facet(l + 1, "id", .string(p.id.lower))
        let layout = TMDLWriter.perspectiveLayout(p)
        if layout.implied != p.members { e.facet(l + 1, "members", encoding: p.members) }
        for t in layout.tables {
            e.blank()
            e.raw(l + 1, "perspectiveTable \(TMDLName.quote(t.name))")
            if t.includeAll { e.flag(l + 2, "includeAll") }
            let table = model.table(t.name)
            for m in t.members {
                let kind: String
                if table?.measure(m) != nil { kind = "perspectiveMeasure" }
                else if table?.column(m) == nil, table?.hierarchies.contains(where: { $0.name == m }) == true { kind = "perspectiveHierarchy" }
                else { kind = "perspectiveColumn" }
                e.raw(l + 2, "\(kind) \(TMDLName.quote(m))")
            }
        }
    }

    func emitCulture(_ e: TMDLEmitter, _ l: Int, _ c: Translation) {
        e.raw(l, "cultureInfo \(TMDLName.quote(c.culture))")
        e.facet(l + 1, "id", .string(c.id.lower))
        // Captions keyed "Table" or "Table[Member]" map to TMDL's nested translations; the rest ride in an annotation.
        var tableCaptions: [String: String] = [:]
        var memberCaptions: [String: [(String, String)]] = [:]
        var leftover: [String: String] = [:]
        for key in c.captions.keys.sorted() {
            let caption = c.captions[key] ?? ""
            guard let (t, member) = TMDLVocabulary.splitMember(key), !caption.hasLineBreak else { leftover[key] = caption; continue }
            if let member { memberCaptions[t, default: []].append((member, caption)) } else { tableCaptions[t] = caption }
        }
        if !leftover.isEmpty { e.facet(l + 1, "captions", encoding: leftover) }
        let tables = Set(tableCaptions.keys).union(memberCaptions.keys).sorted()
        guard !tables.isEmpty else { return }
        e.blank()
        e.raw(l + 1, "translations")
        e.raw(l + 2, "model Model")
        for t in tables {
            e.raw(l + 3, "table \(TMDLName.quote(t))")
            if let cap = tableCaptions[t] { e.prop(l + 4, "caption", cap) }
            let table = model.table(t)
            for (member, cap) in memberCaptions[t] ?? [] {
                let kind: String
                if table?.measure(member) != nil { kind = "measure" }
                else if table?.column(member) == nil, table?.hierarchies.contains(where: { $0.name == member }) == true { kind = "hierarchy" }
                else { kind = "column" }
                e.raw(l + 4, "\(kind) \(TMDLName.quote(member))")
                e.prop(l + 5, "caption", cap)
            }
        }
    }

    func emitFunction(_ e: TMDLEmitter, _ l: Int, _ f: UserFunction) {
        e.description(l, f.description)
        let signature = TMDLFunctionSignature.compose(f)
        e.expression(l, "function \(TMDLName.quote(f.name))", signature)
        e.prop(l + 1, "lineageTag", f.id.lower)
        // If the signature can't be re-read exactly, keep the structured form alongside it.
        let reread = TMDLFunctionSignature.parse(signature)
        if reread?.parameters != f.parameters || reread?.body != f.expression {
            e.facet(l + 1, "parameters", encoding: f.parameters)
            e.facet(l + 1, "body", .string(f.expression))
        }
    }
}
