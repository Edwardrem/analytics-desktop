import Foundation
import FacetCore

/// Identifies a model object to script in TMDL view.
public enum TMDLObjectRef: Hashable, Sendable, CustomStringConvertible {
    /// Every object in the model.
    case model
    /// Only the model's own properties (culture, annotations).
    case modelProperties
    case table(String)
    case column(table: String, name: String)
    case measure(table: String, name: String)
    case hierarchy(table: String, name: String)
    case calculationGroup(String)
    case relationship(UUID)
    case relationships
    case role(String)
    case perspective(String)
    case culture(String)
    case function(String)
    /// A shared Power Query expression (a query not loaded as a table partition).
    case expression(String)

    /// Parses "model", "table:Sales", "measure:Sales[Total]", "column:Sales[Amount]", "hierarchy:Geo[Hier]",
    /// "calculationGroup:Time", "relationship:<uuid>", "relationships", "role:X", "perspective:X", "culture:fr-FR",
    /// "function:X", "expression:X". A name may be single-quoted with '' for a quote, which is how
    /// `description` writes names that would otherwise be ambiguous: "table:'Sales [2024]'",
    /// "measure:'Sales [2024]'['Total [All]']".
    public init?(parsing text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        let kind: String, arg: String
        if let colon = t.firstIndex(of: ":") {
            kind = t[..<colon].lowercased(); arg = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else { kind = t.lowercased(); arg = "" }
        func name() -> String? { arg.isEmpty ? nil : Self.readName(arg) }
        func member() -> (String, String)? { Self.splitMember(arg) }
        switch kind {
        case "model", "": self = .model
        case "modelproperties": self = .modelProperties
        case "relationships": self = .relationships
        case "table": guard let n = name() else { return nil }; self = .table(n)
        case "calculationgroup": guard let n = name() else { return nil }; self = .calculationGroup(n)
        case "role": guard let n = name() else { return nil }; self = .role(n)
        case "perspective": guard let n = name() else { return nil }; self = .perspective(n)
        case "culture": guard let n = name() else { return nil }; self = .culture(n)
        case "function": guard let n = name() else { return nil }; self = .function(n)
        case "expression": guard let n = name() else { return nil }; self = .expression(n)
        case "relationship": guard let u = UUID(uuidString: arg) else { return nil }; self = .relationship(u)
        case "measure": guard let (t, m) = member() else { return nil }; self = .measure(table: t, name: m)
        case "column": guard let (t, m) = member() else { return nil }; self = .column(table: t, name: m)
        case "hierarchy": guard let (t, m) = member() else { return nil }; self = .hierarchy(table: t, name: m)
        default: return nil
        }
    }

    /// The canonical parseable form ("model", "table:Sales", "measure:Sales[Total Sales]"), so refs can be
    /// carried across drag and drop. A name is single-quoted when it is empty, starts with a quote, has
    /// a bracket or has whitespace at either end, so `TMDLObjectRef(parsing: description)` round-trips
    /// for every name.
    public var description: String {
        let q = Self.writeName
        switch self {
        case .model: return "model"
        case .modelProperties: return "modelProperties"
        case .table(let t): return "table:\(q(t))"
        case .column(let t, let c): return "column:\(q(t))[\(q(c))]"
        case .measure(let t, let m): return "measure:\(q(t))[\(q(m))]"
        case .hierarchy(let t, let h): return "hierarchy:\(q(t))[\(q(h))]"
        case .calculationGroup(let g): return "calculationGroup:\(q(g))"
        case .relationship(let id): return "relationship:\(id.uuidString)"
        case .relationships: return "relationships"
        case .role(let r): return "role:\(q(r))"
        case .perspective(let p): return "perspective:\(q(p))"
        case .culture(let c): return "culture:\(q(c))"
        case .function(let f): return "function:\(q(f))"
        case .expression(let e): return "expression:\(q(e))"
        }
    }

    /// A name as `description` writes it: quoted only when the plain text would not parse back to itself.
    private static func writeName(_ name: String) -> String {
        let edge: (Character?) -> Bool = { $0.map { $0.isWhitespace } ?? false }
        let plain = !name.isEmpty && !name.hasPrefix("'") && !name.contains("[") && !name.contains("]")
            && !edge(name.first) && !edge(name.last)
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A whole (already trimmed) argument as one name: unquoted when it is one complete quoted name.
    private static func readName(_ s: String) -> String {
        if s.hasPrefix("'"), let r = TMDLName.read(Substring(s)), r.rest.isEmpty { return r.name }
        return s
    }

    /// Splits "Table[Member]" where either part may be quoted; a quoted table may itself contain brackets.
    private static func splitMember(_ s: String) -> (String, String)? {
        let table: String, rest: Substring
        if s.hasPrefix("'"), let r = TMDLName.read(Substring(s)), r.rest.drop(while: { $0 == " " }).hasPrefix("[") {
            table = r.name; rest = r.rest.drop(while: { $0 == " " })
        } else {
            guard let open = s.firstIndex(of: "["), open > s.startIndex else { return nil }
            table = s[..<open].trimmingCharacters(in: .whitespaces); rest = s[open...]
        }
        guard rest.hasPrefix("["), rest.hasSuffix("]"), rest.count >= 2 else { return nil }
        let inner = String(rest.dropFirst().dropLast())
        guard !inner.isEmpty, !(table.isEmpty && !s.hasPrefix("'")) else { return nil }
        return (table, readName(inner))
    }
}

/// A parsed `createOrReplace` script.
public struct TMDLScript {
    public struct Object: Hashable, Sendable {
        /// "table", "measure", "relationship", …
        public var type: String
        public var name: String
        /// For child objects scripted under `ref table`: the owning table.
        public var table: String?
    }
    /// The objects the script creates or replaces, in order.
    public let objects: [Object]
    let nodes: [TMDLNode]
}

/// One object-level difference between two models.
public struct TMDLChange: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case added, changed, removed }
    public var kind: Kind
    /// "table", "column", "measure", "hierarchy", "relationship", "role", "perspective", "culture", "function",
    /// "calculationGroup", "expression" or "model".
    public var objectType: String
    /// Display name, e.g. "Sales" or "Sales[Total Sales]".
    public var name: String
    public var description: String { "\(kind.rawValue) \(objectType) \(name)" }
}

/// What applying a TMDL script (or any model edit) would add, change and remove — for a "preview the difference" UI.
public struct TMDLChangeSummary: Hashable, Sendable {
    public var changes: [TMDLChange] = []
    public var added: [TMDLChange] { changes.filter { $0.kind == .added } }
    public var changed: [TMDLChange] { changes.filter { $0.kind == .changed } }
    public var removed: [TMDLChange] { changes.filter { $0.kind == .removed } }
    public var isEmpty: Bool { changes.isEmpty }
    /// "2 added, 1 changed, 0 removed" followed by one line per change.
    public var text: String {
        (["\(added.count) added, \(changed.count) changed, \(removed.count) removed"] + changes.map { "  " + $0.description }).joined(separator: "\n")
    }
}

/// Full outcome of `TMDL.apply`.
public struct TMDLApplyResult: Sendable {
    public var model: SemanticModel
    public var queries: [QueryDefinition]
    public var summary: TMDLChangeSummary
    public var warnings: [ImportWarning]
    /// Per-file line diffs of the model's TMDL before and after.
    public var fileDiffs: [TMDLFileDiff]
}

/// The line diff of one TMDL file between two versions of a model.
public struct TMDLFileDiff: Hashable, Sendable {
    public enum Status: String, Sendable { case added, removed, modified }
    public var path: String
    public var status: Status
    public var hunks: [TextDiff.Hunk]
}

public extension TMDL {
    /// The document's queries that are not table partitions — the shared expressions TMDL view scripts.
    static func sharedExpressions(model: SemanticModel, queries: [QueryDefinition]) -> [QueryDefinition] {
        TMDLWriter(model: model, queries: queries).sharedQueries
    }

    /// Produces a `createOrReplace` script for one object, ready to edit and apply.
    static func script(for object: TMDLObjectRef, in model: SemanticModel, queries: [QueryDefinition] = []) throws -> String {
        let w = TMDLWriter(model: model, queries: queries)
        let e = TMDLEmitter()
        e.raw(0, "createOrReplace")
        e.blank()
        func missing(_ what: String) -> TMDLError { TMDLError("The model has no \(what).") }
        func inTable(_ table: String, _ body: (ModelTable) throws -> Void) throws {
            guard let t = model.table(table) else { throw missing("table named “\(table)”") }
            e.raw(1, "ref table \(TMDLName.quote(t.name))")
            e.blank()
            try body(t)
        }
        switch object {
        case .model:
            w.emitModel(e, 1, includeRefs: false); e.blank()
            for t in model.tables { w.emitTable(e, 1, t); e.blank() }
            for g in model.calculationGroups { w.emitCalculationGroup(e, 1, g); e.blank() }
            for r in model.relationships { w.emitRelationship(e, 1, r); e.blank() }
            for q in w.sharedQueries { w.emitExpression(e, 1, q); e.blank() }
            for f in model.functions { w.emitFunction(e, 1, f); e.blank() }
            for r in model.roles { w.emitRole(e, 1, r); e.blank() }
            for p in model.perspectives { w.emitPerspective(e, 1, p); e.blank() }
            for c in model.translations { w.emitCulture(e, 1, c); e.blank() }
        case .modelProperties:
            w.emitModel(e, 1, includeRefs: false)
        case .table(let name):
            if let t = model.table(name) { w.emitTable(e, 1, t) }
            else if let g = model.calculationGroups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { w.emitCalculationGroup(e, 1, g) }
            else { throw missing("table named “\(name)”") }
        case .calculationGroup(let name):
            guard let g = model.calculationGroups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw missing("calculation group named “\(name)”")
            }
            w.emitCalculationGroup(e, 1, g)
        case .column(let table, let name):
            try inTable(table) { t in
                guard let c = t.column(name) else { throw missing("column \(table)[\(name)]") }
                w.emitColumn(e, 2, c, table: t.name)
            }
        case .measure(let table, let name):
            try inTable(table) { t in
                guard let m = t.measure(name) else { throw missing("measure \(table)[\(name)]") }
                w.emitMeasure(e, 2, m)
            }
        case .hierarchy(let table, let name):
            try inTable(table) { t in
                guard let h = t.hierarchies.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw missing("hierarchy \(table)[\(name)]")
                }
                w.emitHierarchy(e, 2, h)
            }
        case .relationship(let id):
            guard let r = model.relationships.first(where: { $0.id == id }) else { throw missing("relationship \(id.lower)") }
            w.emitRelationship(e, 1, r)
        case .relationships:
            for r in model.relationships { w.emitRelationship(e, 1, r); e.blank() }
        case .role(let name):
            guard let r = model.roles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw missing("role named “\(name)”") }
            w.emitRole(e, 1, r)
        case .perspective(let name):
            guard let p = model.perspectives.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw missing("perspective named “\(name)”")
            }
            w.emitPerspective(e, 1, p)
        case .culture(let name):
            guard let c = model.translations.first(where: { $0.culture.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw missing("culture “\(name)”")
            }
            w.emitCulture(e, 1, c)
        case .function(let name):
            guard let f = model.functions.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw missing("function named “\(name)”")
            }
            w.emitFunction(e, 1, f)
        case .expression(let name):
            guard let q = queries.first(where: { $0.name == name }) else { throw missing("query named “\(name)”") }
            w.emitExpression(e, 1, q)
        }
        var text = e.text
        while text.hasSuffix("\n\n") { text.removeLast() }
        return text
    }

    /// Parses a single TMDL script (`createOrReplace` followed by indented objects; a bare object list is accepted too).
    static func parseScript(_ text: String) throws -> TMDLScript {
        let parsed = try TMDLParser.parse(text, file: nil)
        guard !parsed.nodes.isEmpty else { throw TMDLError("The script doesn't contain any objects.") }
        var objects: [TMDLScript.Object] = []
        for n in parsed.nodes {
            if n.isRef {
                guard n.keyword.lowercased() == "table" else { continue }
                for c in n.children where c.keyword != "annotation" {
                    objects.append(.init(type: c.keyword, name: c.name, table: n.name))
                }
            } else {
                let isGroup = n.keyword.lowercased() == "table" && !n.children("calculationGroup").isEmpty
                objects.append(.init(type: isGroup ? "calculationGroup" : n.keyword, name: n.name, table: nil))
            }
        }
        return TMDLScript(objects: objects, nodes: parsed.nodes)
    }

    /// Applies a script to a model, returning the new model and a summary of what changed. The input model is not modified.
    static func apply(script: String, to model: SemanticModel) throws -> (SemanticModel, TMDLChangeSummary) {
        let r = try apply(script: script, to: model, queries: [])
        return (r.model, r.summary)
    }

    /// Applies a script to a model and its queries, with warnings and per-file text diffs for previewing.
    static func apply(script: String, to model: SemanticModel, queries: [QueryDefinition]) throws -> TMDLApplyResult {
        let parsed = try parseScript(script)
        var builder = TMDLBuilder()
        builder.aggregationState.scriptMode = true
        var newModel = model
        var newQueries = queries
        for node in parsed.nodes { try builder.merge(node, into: &newModel, queries: &newQueries) }
        let problems = validate(newModel)
        if let fatal = problems.first(where: { $0.severity == .error }) { throw TMDLError(fatal.message) }
        return TMDLApplyResult(model: newModel, queries: newQueries,
                               summary: changeSummary(old: model, new: newModel, oldQueries: queries, newQueries: newQueries),
                               warnings: builder.warnings + problems,
                               fileDiffs: fileDiffs(old: model, oldQueries: queries, new: newModel, newQueries: newQueries))
    }

    /// Structural checks: duplicate names (errors) and dangling references (warnings).
    static func validate(_ model: SemanticModel) -> [ImportWarning] {
        var out: [ImportWarning] = []
        var tableNames = Set<String>()
        for name in model.tables.map(\.name) + model.calculationGroups.map(\.name) {
            if !tableNames.insert(name.lowercased()).inserted { out.append(ImportWarning("Two tables are named “\(name)”.", severity: .error)) }
        }
        var measures = Set<String>()
        for t in model.tables {
            var cols = Set<String>()
            for c in t.columns where !cols.insert(c.name.lowercased()).inserted {
                out.append(ImportWarning("Table “\(t.name)” has two columns named “\(c.name)”.", severity: .error))
            }
            for m in t.measures {
                if !measures.insert(m.name.lowercased()).inserted {
                    out.append(ImportWarning("Two measures are named “\(m.name)”; measure names must be unique in the model.", severity: .error))
                }
                if cols.contains(m.name.lowercased()) {
                    out.append(ImportWarning("Measure “\(m.name)” has the same name as a column in “\(t.name)”.", severity: .error))
                }
            }
            for c in t.columns {
                if let s = c.sortByColumn, t.column(s) == nil {
                    out.append(ImportWarning("Column \(t.name)[\(c.name)] sorts by “\(s)”, which doesn't exist.", location: t.name))
                }
            }
            for h in t.hierarchies { for l in h.levels where t.column(l) == nil {
                out.append(ImportWarning("Hierarchy \(t.name)[\(h.name)] uses column “\(l)”, which doesn't exist.", location: t.name))
            } }
        }
        for r in model.relationships {
            for (t, c) in [(r.fromTable, r.fromColumn), (r.toTable, r.toColumn)] where model.table(t)?.column(c) == nil {
                out.append(ImportWarning("A relationship refers to \(t)[\(c)], which doesn't exist.", location: "relationships"))
            }
        }
        return out
    }

    /// Object-level comparison of two models (ignoring internal ids).
    static func changeSummary(old: SemanticModel, new: SemanticModel,
                              oldQueries: [QueryDefinition] = [], newQueries: [QueryDefinition] = []) -> TMDLChangeSummary {
        var s = TMDLChangeSummary()
        func fingerprint<T: Encodable>(_ v: T) -> String {
            ((try? JSONValue(encoding: v)) ?? .null).strippingKeys(["id"]).compactString
        }
        func compare<T: Encodable>(_ type: String, _ a: [T], _ b: [T], name: (T) -> String, display: (T) -> String) {
            var oldByName: [String: T] = [:]
            for x in a { oldByName[name(x).lowercased()] = x }
            var seen = Set<String>()
            for x in b {
                let k = name(x).lowercased()
                seen.insert(k)
                if let o = oldByName[k] {
                    if fingerprint(o) != fingerprint(x) { s.changes.append(TMDLChange(kind: .changed, objectType: type, name: display(x))) }
                } else { s.changes.append(TMDLChange(kind: .added, objectType: type, name: display(x))) }
            }
            for x in a where !seen.contains(name(x).lowercased()) {
                s.changes.append(TMDLChange(kind: .removed, objectType: type, name: display(x)))
            }
        }
        // Model-level properties.
        var om = old, nm = new
        for m in [\SemanticModel.tables] { om[keyPath: m] = []; nm[keyPath: m] = [] }
        om.relationships = []; nm.relationships = []; om.calculationGroups = []; nm.calculationGroups = []
        om.functions = []; nm.functions = []; om.roles = []; nm.roles = []; om.perspectives = []; nm.perspectives = []
        om.translations = []; nm.translations = []
        if fingerprint(om) != fingerprint(nm) { s.changes.append(TMDLChange(kind: .changed, objectType: "model", name: new.name)) }

        // Tables: own properties, then children.
        func shell(_ t: ModelTable) -> ModelTable { var c = t; c.columns = []; c.measures = []; c.hierarchies = []; return c }
        compare("table", old.tables.map(shell), new.tables.map(shell), name: { $0.name }, display: { $0.name })
        for t in new.tables {
            guard let o = old.table(t.name) else { continue }
            compare("column", o.columns, t.columns, name: { $0.name }, display: { "\(t.name)[\($0.name)]" })
            compare("measure", o.measures, t.measures, name: { $0.name }, display: { "\(t.name)[\($0.name)]" })
            compare("hierarchy", o.hierarchies, t.hierarchies, name: { $0.name }, display: { "\(t.name)[\($0.name)]" })
        }
        compare("calculationGroup", old.calculationGroups, new.calculationGroups, name: { $0.name }, display: { $0.name })
        compare("relationship", old.relationships, new.relationships,
                name: { "\($0.fromTable)[\($0.fromColumn)]→\($0.toTable)[\($0.toColumn)]" },
                display: { "\($0.fromTable)[\($0.fromColumn)] → \($0.toTable)[\($0.toColumn)]" })
        compare("role", old.roles, new.roles, name: { $0.name }, display: { $0.name })
        compare("perspective", old.perspectives, new.perspectives, name: { $0.name }, display: { $0.name })
        compare("culture", old.translations, new.translations, name: { $0.culture }, display: { $0.culture })
        compare("function", old.functions, new.functions, name: { $0.name }, display: { $0.name })
        compare("expression", oldQueries, newQueries, name: { $0.name }, display: { $0.name })
        return s
    }

    /// Line diffs of each TMDL file between two versions of a model.
    static func fileDiffs(old: SemanticModel, oldQueries: [QueryDefinition] = [],
                          new: SemanticModel, newQueries: [QueryDefinition] = [], context: Int = 3) -> [TMDLFileDiff] {
        let a = serialize(model: old, queries: oldQueries), b = serialize(model: new, queries: newQueries)
        let oldByPath = Dictionary(a.map { ($0.path, $0.text) }, uniquingKeysWith: { x, _ in x })
        let newByPath = Dictionary(b.map { ($0.path, $0.text) }, uniquingKeysWith: { x, _ in x })
        var out: [TMDLFileDiff] = []
        for f in b {
            if let before = oldByPath[f.path] {
                if before != f.text {
                    out.append(TMDLFileDiff(path: f.path, status: .modified, hunks: TextDiff.diff(old: before, new: f.text, context: context)))
                }
            } else {
                out.append(TMDLFileDiff(path: f.path, status: .added, hunks: TextDiff.diff(old: "", new: f.text, context: context)))
            }
        }
        for f in a where newByPath[f.path] == nil {
            out.append(TMDLFileDiff(path: f.path, status: .removed, hunks: TextDiff.diff(old: f.text, new: "", context: context)))
        }
        return out
    }
}

extension JSONValue {
    /// Removes the given keys from every object in the tree.
    func strippingKeys(_ keys: Set<String>) -> JSONValue {
        switch self {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o where !keys.contains(k) { out[k] = v.strippingKeys(keys) }
            return .object(out)
        case .array(let a): return .array(a.map { $0.strippingKeys(keys) })
        default: return self
        }
    }
}
