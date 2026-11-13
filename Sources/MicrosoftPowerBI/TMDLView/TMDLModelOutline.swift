import AppKit
import FacetCore
import FacetInterop

/// What the TMDL view's object tree shows for one model, its shared expressions and a search text.
/// The search filters every section: a table matches when its name or one of its members matches,
/// a relationship when either end matches. Counts are the counts of matching rows, and a section
/// with no matches is hidden while searching.
struct TMDLModelOutline {
    enum Section: String, CaseIterable, Identifiable {
        case tables = "Tables", relationships = "Relationships", roles = "Roles"
        case perspectives = "Perspectives", cultures = "Cultures", functions = "Functions", expressions = "Expressions"
        var id: String { rawValue }
    }

    struct Row: Identifiable, Hashable {
        var ref: TMDLObjectRef
        var icon: String
        var name: String
        var id: String { ref.description }
    }

    let model: SemanticModel
    /// The queries that are not table partitions (`TMDL.sharedExpressions`).
    let shared: [QueryDefinition]
    let search: String

    init(model: SemanticModel, shared: [QueryDefinition], search: String = "") {
        self.model = model
        self.shared = shared
        self.search = search.trimmingCharacters(in: .whitespaces)
    }

    var isSearching: Bool { !search.isEmpty }

    func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }

    /// The "Properties" row under the model: shown unless a search rules it out.
    var showsProperties: Bool { matches("Properties") || matches(model.name) }

    /// The tables to list: those whose name or a member matches.
    var tables: [ModelTable] {
        model.tables.filter { t in matches(t.name) || !members(of: t).isEmpty }
    }

    /// Measures, columns and hierarchies of a table that match (all of them when the table itself matches).
    func members(of table: ModelTable) -> [Row] {
        let all = matches(table.name)
        var out: [Row] = []
        for m in table.measures where all || matches(m.name) {
            out.append(Row(ref: .measure(table: table.name, name: m.name), icon: "sum", name: m.name))
        }
        for c in table.columns where all || matches(c.name) {
            out.append(Row(ref: .column(table: table.name, name: c.name), icon: DAXResultFormat.glyph(for: c.dataType), name: c.name))
        }
        for h in table.hierarchies where all || matches(h.name) {
            out.append(Row(ref: .hierarchy(table: table.name, name: h.name), icon: "list.bullet.indent", name: h.name))
        }
        return out
    }

    /// The rows of a section other than the tables themselves (for `.tables`: the calculation groups).
    func rows(_ section: Section) -> [Row] {
        switch section {
        case .tables:
            return model.calculationGroups.filter { matches($0.name) }
                .map { Row(ref: .calculationGroup($0.name), icon: "function", name: $0.name) }
        case .relationships:
            return model.relationships
                .filter { matches($0.fromTable) || matches($0.fromColumn) || matches($0.toTable) || matches($0.toColumn) }
                .map { Row(ref: .relationship($0.id), icon: "link",
                           name: "\($0.fromTable)[\($0.fromColumn)] → \($0.toTable)[\($0.toColumn)]") }
        case .roles:
            return model.roles.filter { matches($0.name) }
                .map { Row(ref: .role($0.name), icon: "person.badge.shield.checkmark", name: $0.name) }
        case .perspectives:
            return model.perspectives.filter { matches($0.name) }
                .map { Row(ref: .perspective($0.name), icon: "rectangle.3.group", name: $0.name) }
        case .cultures:
            return model.translations.filter { matches($0.culture) }
                .map { Row(ref: .culture($0.culture), icon: "globe", name: $0.culture) }
        case .functions:
            return model.functions.filter { matches($0.name) }
                .map { Row(ref: .function($0.name), icon: "f.cursive.circle", name: $0.name) }
        case .expressions:
            return shared.filter { matches($0.name) }.map { Row(ref: .expression($0.name), icon: "curlybraces", name: $0.name) }
        }
    }

    /// Number of top-level rows the section lists under the current search.
    func count(_ section: Section) -> Int {
        rows(section).count + (section == .tables ? tables.count : 0)
    }

    /// Sections to draw: all of them normally, only those with matches while searching.
    var visibleSections: [Section] {
        Section.allCases.filter { !isSearching || count($0) > 0 }
    }

    /// True when a search leaves nothing to show.
    var isEmpty: Bool { isSearching && visibleSections.isEmpty && !showsProperties }
}

/// What a tree row carries when it is dragged into the editor. It travels under its own pasteboard
/// type and never as text, so the editor's text view cannot insert it as characters.
enum TMDLDragPayload {
    static let typeIdentifier = "com.facet.tmdl-object"
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    static func encode(_ ref: TMDLObjectRef) -> Data { Data(ref.description.utf8) }

    static func decode(_ data: Data) -> TMDLObjectRef? {
        String(data: data, encoding: .utf8).flatMap(TMDLObjectRef.init(parsing:))
    }

    static func itemProvider(for ref: TMDLObjectRef) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = encode(ref)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }
}

extension TMDLObjectRef {
    /// "table Sales", "measure Sales[Total]": for status messages and tooltips.
    var displayName: String {
        switch self {
        case .model: return "the model"
        case .modelProperties: return "model properties"
        case .table(let t): return "table \(t)"
        case .column(let t, let c): return "column \(t)[\(c)]"
        case .measure(let t, let m): return "measure \(t)[\(m)]"
        case .hierarchy(let t, let h): return "hierarchy \(t)[\(h)]"
        case .calculationGroup(let g): return "calculation group \(g)"
        case .relationship(let id): return "relationship \(id.uuidString.prefix(8))"
        case .relationships: return "relationships"
        case .role(let r): return "role \(r)"
        case .perspective(let p): return "perspective \(p)"
        case .culture(let c): return "culture \(c)"
        case .function(let f): return "function \(f)"
        case .expression(let e): return "expression \(e)"
        }
    }

    /// Name of a script tab opened for this object.
    var tabName: String {
        switch self {
        case .model, .modelProperties: return "Model"
        case .table(let t), .calculationGroup(let t): return t
        case .column(let t, _), .measure(let t, _), .hierarchy(let t, _): return t
        case .relationship, .relationships: return "Relationships"
        case .role(let r), .perspective(let r), .culture(let r), .function(let r), .expression(let r): return r
        }
    }
}
