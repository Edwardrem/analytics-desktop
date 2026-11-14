import Foundation
import CoreGraphics
import FacetCore
import FacetInterop

/// The Modeling MCP server's write tools besides `set_measure`. Each checks what the agent sent (one-line, bounded
/// names without control characters; tables, columns and fields that exist; DAX that parses and runs once), then
/// asks the user in the same approval dialog, then makes the change as one undoable document edit.
extension AgentTools {
    static let maxDescriptionLength = 2_000
    static let maxReferenceLength = 400
    static let maxTextLength = 2_000
    static let maxFieldsPerVisual = 20

    static var writeTools: [MCPTool] {
        let doc = ["document": documentArgument]
        let object: [String: JSONValue] = [
            "kind": .object(["type": .string("string"), "enum": .array(["table", "column", "measure"].map { .string($0) })]),
            "table": text("The table, or the table that holds the column or measure."),
            "name": text("The column or measure name; omit for a table."),
        ]
        let ends: [String: JSONValue] = [
            "fromTable": text("Many side: table."), "fromColumn": text("Many side: column."),
            "toTable": text("One side: table."), "toColumn": text("One side: column."),
        ]
        let field: JSONValue = .object(["type": .string("object"), "properties": .object([
            "field": text("'Table'[Column] or [Measure]."), "well": text("Optional well, e.g. category, values, legend."),
            "aggregation": text("Optional: sum, average, min, max, count, distinctCount, median."),
        ]), "required": .array([.string("field")])])
        let visual: [String: JSONValue] = [
            "type": text("Visual type: \(AssistantAuthoring.typeNames.joined(separator: ", "))."),
            "fields": .object(["type": .string("array"), "items": field]),
            "title": text("Optional title."), "text": text("The text of a textBox."),
        ]
        return [
            MCPTool(name: "set_calculated_column", description: "Adds a calculated column to a table, or changes the calculated column of that name. The user is asked to allow each change.",
                    inputSchema: schema(doc.merging(["table": text("Table."), "name": text("Column name."), "expression": text("DAX expression, evaluated per row."),
                                                     "formatString": text("Optional format string.")]) { a, _ in a },
                                        required: ["table", "name", "expression"])) { args in
                let store = try await MainActor.run { try document(args) }
                return try await setCalculatedColumn(store, args)
            },
            MCPTool(name: "create_relationship", description: "Creates a relationship between two columns (many side → one side). The user is asked to allow it.",
                    inputSchema: schema(doc.merging(ends) { a, _ in a }.merging([
                        "cardinality": .object(["type": .string("string"), "enum": .array(Cardinality.allCases.map { .string($0.rawValue) })]),
                        "crossFilter": .object(["type": .string("string"), "enum": .array(CrossFilterDirection.allCases.map { .string($0.rawValue) })]),
                        "active": .object(["type": .string("boolean")]),
                    ]) { a, _ in a }, required: ["fromTable", "fromColumn", "toTable", "toColumn"])) { args in
                try await MainActor.run { try createRelationship(try document(args), args) }
            },
            MCPTool(name: "delete_relationship", description: "Deletes the relationship between two columns. The user is asked to allow it.",
                    inputSchema: schema(doc.merging(ends) { a, _ in a }, required: ["fromTable", "fromColumn", "toTable", "toColumn"])) { args in
                try await MainActor.run { try deleteRelationship(try document(args), args) }
            },
            MCPTool(name: "rename_object", description: "Renames a table, column or measure, and updates the DAX and visuals that use it. The user is asked to allow it.",
                    inputSchema: schema(doc.merging(object) { a, _ in a }.merging(["newName": text("The new name.")]) { a, _ in a },
                                        required: ["kind", "table", "newName"])) { args in
                try await MainActor.run { try rename(try document(args), args) }
            },
            MCPTool(name: "set_hidden", description: "Hides a table, column or measure in Report view, or shows it again. The user is asked to allow it.",
                    inputSchema: schema(doc.merging(object) { a, _ in a }.merging(["hidden": .object(["type": .string("boolean")])]) { a, _ in a },
                                        required: ["kind", "table", "hidden"])) { args in
                try await MainActor.run { try setHidden(try document(args), args) }
            },
            MCPTool(name: "set_description", description: "Sets the description of a table, column or measure (one line; empty clears it). The user is asked to allow it.",
                    inputSchema: schema(doc.merging(object) { a, _ in a }.merging(["description": text("The description.")]) { a, _ in a },
                                        required: ["kind", "table", "description"])) { args in
                try await MainActor.run { try setDescription(try document(args), args) }
            },
            MCPTool(name: "set_format_string", description: "Sets the format string of a column or measure, e.g. #,0.00 or 0.0%. The user is asked to allow it.",
                    inputSchema: schema(doc.merging(["table": text("Table."), "name": text("Column or measure."), "formatString": text("Format string.")]) { a, _ in a },
                                        required: ["table", "name", "formatString"])) { args in
                try await MainActor.run { try setFormatString(try document(args), args) }
            },
            MCPTool(name: "add_visual", description: "Adds a visual with its fields to a report page, in free space. Fields are checked against the model. The user is asked to allow it.",
                    inputSchema: schema(doc.merging(visual) { a, _ in a }.merging(["page": text("Page name; omit for the current page.")]) { a, _ in a },
                                        required: ["type"])) { args in
                try await MainActor.run { try addVisual(try document(args), args) }
            },
            MCPTool(name: "add_page", description: "Adds a report page holding a set of visuals laid out in a grid. Nothing is added if any visual fails the check. The user is asked to allow it.",
                    inputSchema: schema(doc.merging(["name": text("Page name."),
                                                     "visuals": .object(["type": .string("array"), "items": .object(["type": .string("object"), "properties": .object(visual)])])]) { a, _ in a },
                                        required: ["name", "visuals"])) { args in
                try await MainActor.run { try addPage(try document(args), args) }
            },
        ]
    }

    // MARK: Checks shared by the write tools

    /// A required one-line value, bounded.
    static func requiredLine(_ args: JSONValue, _ key: String, max: Int = maxNameLength) throws -> String {
        try line(try string(args, key), key, max: max)
    }

    /// An optional one-line value, bounded; nil when absent.
    static func optionalLine(_ args: JSONValue, _ key: String, max: Int = maxNameLength) throws -> String? {
        guard let v = args[key] else { return nil }
        guard let s = v.stringValue else { throw ToolError(message: "“\(key)” must be text.") }
        return try line(s, key, max: max)
    }

    static func requiredBool(_ args: JSONValue, _ key: String) throws -> Bool {
        guard let b = args[key]?.boolValue else { throw ToolError(message: "“\(key)” is required and must be true or false.") }
        return b
    }

    /// Asks the user; throws when they refuse.
    @MainActor static func approve(_ change: AgentChange) throws {
        guard AgentBridge.shared.confirm(change) else { throw ToolError(message: "The user didn't allow the change.") }
    }

    @MainActor static func table(_ store: DocumentStore, _ name: String) throws -> ModelTable {
        guard let t = store.model.table(name) else { throw ToolError(message: "“\(store.displayName)” has no table named \(name).") }
        return t
    }

    /// A model object named by `kind`, `table` and (for a column or measure) `name`.
    enum Target: Equatable {
        case table(String)
        case column(table: String, name: String)
        case measure(table: String, name: String)

        var noun: String {
            switch self { case .table: return "table"; case .column: return "column"; case .measure: return "measure" }
        }
        var label: String {
            switch self {
            case .table(let t): return t
            case .column(let t, let n), .measure(let t, let n): return "\(t)[\(n)]"
            }
        }
    }

    @MainActor static func target(_ store: DocumentStore, _ args: JSONValue) throws -> Target {
        let kind = try requiredLine(args, "kind", max: 20)
        let t = try table(store, try requiredLine(args, "table"))
        switch kind {
        case "table": return .table(t.name)
        case "column":
            let name = try requiredLine(args, "name")
            guard let c = t.column(name) else { throw ToolError(message: "\(t.name) has no column named \(name).") }
            return .column(table: t.name, name: c.name)
        case "measure":
            let name = try requiredLine(args, "name")
            guard let m = t.measure(name) else { throw ToolError(message: "\(t.name) has no measure named \(name).") }
            return .measure(table: t.name, name: m.name)
        default:
            throw ToolError(message: "“kind” must be table, column or measure.")
        }
    }

    // MARK: Calculated columns

    @MainActor static func setCalculatedColumn(_ store: DocumentStore, _ args: JSONValue) async throws -> String {
        let t = try table(store, try requiredLine(args, "table"))
        let name = try requiredLine(args, "name")
        let expression = try string(args, "expression")
        let format = try optionalLine(args, "formatString", max: maxFormatLength).flatMap { $0.isEmpty ? nil : $0 }
        guard expression.count <= maxExpressionLength else { throw ToolError(message: "The expression is longer than \(maxExpressionLength) characters.") }
        guard !name.contains("["), !name.contains("]") else { throw ToolError(message: "Names can't contain square brackets.") }
        let existing = t.column(name)
        if let existing, !existing.isCalculated { throw ToolError(message: "\(t.name)[\(existing.name)] is a data column; only calculated columns can be changed.") }
        if t.measure(name) != nil { throw ToolError(message: "“\(name)” is already a measure in \(t.name).") }
        let home = t.name
        let quoted = "'" + home.replacingOccurrences(of: "'", with: "''") + "'"
        let problems: [String] = await store.withEngine { engine in
            let issues = engine.check(expression, kind: .calculatedColumn, homeTable: home).filter { !$0.isWarning }.map(\.message)
            if !issues.isEmpty { return issues }
            // Evaluated once over the table's rows, so a name the static check cannot resolve still fails here.
            do { _ = try engine.query("EVALUATE TOPN(1, ADDCOLUMNS(\(quoted), \"__check\", \(expression)\n))"); return [] }
            catch { return [(error as? LocalizedError)?.errorDescription ?? error.localizedDescription] }
        }
        guard problems.isEmpty else { throw ToolError(message: "The expression has errors: " + problems.joined(separator: "; ")) }
        let replacing = existing != nil
        var rows = [AgentChange.Row(label: "Column", value: name), AgentChange.Row(label: "Table", value: home)]
        if let format { rows.append(AgentChange.Row(label: "Format", value: format)) }
        try approve(AgentChange(title: replacing ? "An agent wants to change a calculated column." : "An agent wants to add a calculated column.",
                                document: store.displayName, name: name, rows: rows, expression: expression))
        store.mutate(replacing ? "Change Column" : "New Column", invalidates: .model) { d in
            guard let ti = d.model.tableIndex(home) else { return }
            if let ci = d.model.tables[ti].columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                d.model.tables[ti].columns[ci].expression = expression
                if let format { d.model.tables[ti].columns[ci].formatString = format }
            } else {
                var c = ModelColumn(name: name, dataType: .any, expression: expression)
                c.formatString = format ?? ""
                d.model.tables[ti].columns.append(c)
            }
        }
        return "\(replacing ? "Changed" : "Added") the calculated column \(home)[\(name)]."
    }

    // MARK: Relationships

    @MainActor static func ends(_ store: DocumentStore, _ args: JSONValue) throws -> (from: (String, String), to: (String, String)) {
        func end(_ tableKey: String, _ columnKey: String) throws -> (String, String) {
            let t = try table(store, try requiredLine(args, tableKey))
            let name = try requiredLine(args, columnKey)
            guard let c = t.column(name) else { throw ToolError(message: "\(t.name) has no column named \(name).") }
            return (t.name, c.name)
        }
        return (try end("fromTable", "fromColumn"), try end("toTable", "toColumn"))
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// The relationship joining these two columns, in either direction.
    static func relationship(_ model: SemanticModel, _ a: (String, String), _ b: (String, String)) -> Relationship? {
        model.relationships.first { r in
            (same(r.fromTable, a.0) && same(r.fromColumn, a.1) && same(r.toTable, b.0) && same(r.toColumn, b.1))
                || (same(r.fromTable, b.0) && same(r.fromColumn, b.1) && same(r.toTable, a.0) && same(r.toColumn, a.1))
        }
    }

    @MainActor static func createRelationship(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let (from, to) = try ends(store, args)
        guard !same(from.0, to.0) else { throw ToolError(message: "A relationship joins two different tables.") }
        guard relationship(store.model, from, to) == nil else { throw ToolError(message: "Those columns are already related.") }
        var r = Relationship(fromTable: from.0, fromColumn: from.1, toTable: to.0, toColumn: to.1)
        if let c = try optionalLine(args, "cardinality", max: 20) {
            guard let v = Cardinality(rawValue: c) else { throw ToolError(message: "“cardinality” must be one of \(Cardinality.allCases.map(\.rawValue).joined(separator: ", ")).") }
            r.cardinality = v
        }
        if let f = try optionalLine(args, "crossFilter", max: 20) {
            guard let v = CrossFilterDirection(rawValue: f) else { throw ToolError(message: "“crossFilter” must be single or both.") }
            r.crossFilter = v
        }
        // Only one active path may join two tables: a second one starts inactive unless the agent says otherwise.
        let alreadyJoined = store.model.relationships.contains { x in
            x.isActive && ((same(x.fromTable, from.0) && same(x.toTable, to.0)) || (same(x.fromTable, to.0) && same(x.toTable, from.0)))
        }
        if let active = args["active"] {
            guard let b = active.boolValue else { throw ToolError(message: "“active” must be true or false.") }
            guard !(b && alreadyJoined) else { throw ToolError(message: "\(from.0) and \(to.0) already have an active relationship; create this one inactive.") }
            r.isActive = b
        } else {
            r.isActive = !alreadyJoined
        }
        try approve(AgentChange(title: "An agent wants to create a relationship.", document: store.displayName, name: "\(from.0)[\(from.1)]",
                                rows: [.init(label: "From", value: "\(from.0)[\(from.1)]"), .init(label: "To", value: "\(to.0)[\(to.1)]"),
                                       .init(label: "Cardinality", value: r.cardinality.displayName),
                                       .init(label: "Cross filter", value: r.crossFilter == .both ? "Both" : "Single"),
                                       .init(label: "Active", value: r.isActive ? "Yes" : "No")]))
        let created = r
        store.updateModel("New Relationship") { $0.relationships.append(created) }
        return "Created the \(r.isActive ? "active" : "inactive") relationship \(from.0)[\(from.1)] → \(to.0)[\(to.1)]."
    }

    @MainActor static func deleteRelationship(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let (from, to) = try ends(store, args)
        guard let r = relationship(store.model, from, to) else { throw ToolError(message: "No relationship joins those columns.") }
        try approve(AgentChange(title: "An agent wants to delete a relationship.", document: store.displayName, name: "\(r.fromTable)[\(r.fromColumn)]",
                                rows: [.init(label: "From", value: "\(r.fromTable)[\(r.fromColumn)]"), .init(label: "To", value: "\(r.toTable)[\(r.toColumn)]")]))
        let id = r.id
        store.updateModel("Delete Relationship") { $0.relationships.removeAll { $0.id == id } }
        return "Deleted the relationship \(r.fromTable)[\(r.fromColumn)] → \(r.toTable)[\(r.toColumn)]."
    }

    // MARK: Names, visibility, descriptions, formats

    @MainActor static func rename(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let target = try target(store, args)
        let newName = try requiredLine(args, "newName").trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { throw ToolError(message: "“newName” is required.") }
        let kind: FormulaEdit.Kind, table: String, old: String
        switch target {
        case .table(let t): (kind, table, old) = (.table, t, t)
        case .column(let t, let n): (kind, table, old) = (.column, t, n)
        case .measure(let t, let n): (kind, table, old) = (.measure, t, n)
        }
        guard newName != old else { throw ToolError(message: "The \(target.noun) is already called \(old).") }
        if let problem = ModelOps.nameProblem(newName, kind: kind, table: table, original: old, model: store.model) { throw ToolError(message: problem) }
        try approve(AgentChange(title: "An agent wants to rename a \(target.noun).", document: store.displayName, name: old,
                                rows: [.init(label: target.noun.capitalized, value: target.label), .init(label: "New name", value: newName)]))
        let done: Bool
        switch target {
        case .table: done = ModelOps.renameTable(store, old, to: newName)
        case .column: done = ModelOps.renameColumn(store, table: table, old, to: newName)
        case .measure: done = ModelOps.renameMeasure(store, table: table, old, to: newName)
        }
        guard done else { throw ToolError(message: "The \(target.noun) could not be renamed.") }
        return "Renamed the \(target.noun) \(target.label) to \(newName); the DAX and visuals that use it follow."
    }

    @MainActor static func setHidden(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let target = try target(store, args)
        let hidden = try requiredBool(args, "hidden")
        try approve(AgentChange(title: hidden ? "An agent wants to hide a \(target.noun)." : "An agent wants to show a hidden \(target.noun).",
                                document: store.displayName, name: target.label,
                                rows: [.init(label: target.noun.capitalized, value: target.label)]))
        let name = hidden ? "Hide in Report View" : "Unhide in Report View"
        switch target {
        case .table(let t): ModelOps.updateTable(store, t, name: name, invalidates: .layout) { $0.isHidden = hidden }
        case .column(let t, let n): ModelOps.updateColumns(store, [(t, n)], name: name, invalidates: .layout) { $0.isHidden = hidden }
        case .measure(let t, let n): ModelOps.updateMeasures(store, [(t, n)], name: name, invalidates: .layout) { $0.isHidden = hidden }
        }
        return "\(hidden ? "Hid" : "Showed") the \(target.noun) \(target.label) in Report view."
    }

    @MainActor static func setDescription(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let target = try target(store, args)
        guard let raw = args["description"]?.stringValue else { throw ToolError(message: "“description” is required.") }
        let description = try line(raw, "description", max: maxDescriptionLength)
        try approve(AgentChange(title: "An agent wants to change a description.", document: store.displayName, name: target.label,
                                rows: [.init(label: target.noun.capitalized, value: target.label),
                                       .init(label: "Description", value: description.isEmpty ? "(none)" : description)]))
        switch target {
        case .table(let t): ModelOps.updateTable(store, t, name: "Change Description", invalidates: .layout) { $0.description = description }
        case .column(let t, let n): ModelOps.updateColumns(store, [(t, n)], name: "Change Description", invalidates: .layout) { $0.description = description }
        case .measure(let t, let n): ModelOps.updateMeasures(store, [(t, n)], name: "Change Description", invalidates: .layout) { $0.description = description }
        }
        return description.isEmpty ? "Cleared the description of \(target.label)." : "Set the description of \(target.label)."
    }

    @MainActor static func setFormatString(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let t = try table(store, try requiredLine(args, "table"))
        let name = try requiredLine(args, "name")
        guard let raw = args["formatString"]?.stringValue else { throw ToolError(message: "“formatString” is required.") }
        let format = try line(raw, "formatString", max: maxFormatLength)
        let target: Target
        if let m = t.measure(name) { target = .measure(table: t.name, name: m.name) }
        else if let c = t.column(name) { target = .column(table: t.name, name: c.name) }
        else { throw ToolError(message: "\(t.name) has no column or measure named \(name).") }
        try approve(AgentChange(title: "An agent wants to change a format string.", document: store.displayName, name: target.label,
                                rows: [.init(label: target.noun.capitalized, value: target.label),
                                       .init(label: "Format", value: format.isEmpty ? "(automatic)" : format)]))
        switch target {
        case .column(let tn, let n): ModelOps.updateColumns(store, [(tn, n)], name: "Change Format", invalidates: .visuals(nil)) { $0.formatString = format }
        case .measure(let tn, let n): ModelOps.updateMeasures(store, [(tn, n)], name: "Change Format", invalidates: .visuals(nil)) { $0.formatString = format }
        case .table: break
        }
        return "Set the format string of \(target.label)."
    }

    // MARK: Visuals and pages

    /// A visual request from an agent, with every text checked: one line, bounded.
    static func visualRequest(_ value: JSONValue) throws -> AssistantAuthoring.VisualRequest {
        let fields = value["fields"]?.arrayValue ?? []
        guard fields.count <= maxFieldsPerVisual else { throw ToolError(message: "A visual takes at most \(maxFieldsPerVisual) fields.") }
        let requests = try fields.map { item -> AssistantAuthoring.FieldRequest in
            if let s = item.stringValue { return AssistantAuthoring.FieldRequest(reference: try line(s, "field", max: maxReferenceLength)) }
            return AssistantAuthoring.FieldRequest(reference: try requiredLine(item, "field", max: maxReferenceLength),
                                                   well: try optionalLine(item, "well", max: 40), aggregation: try optionalLine(item, "aggregation", max: 40))
        }
        return AssistantAuthoring.VisualRequest(type: try requiredLine(value, "type", max: 40), fields: requests,
                                               title: try optionalLine(value, "title"), text: try optionalLine(value, "text", max: maxTextLength))
    }

    private static func uniqueName(_ base: String, among names: [String]) -> String {
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private static func problem(_ error: Error) -> ToolError {
        error as? ToolError ?? ToolError(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    @MainActor static func addVisual(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let pageName = try optionalLine(args, "page")
        guard let page = pageName.map({ n in store.report.pages.first { same($0.name, n) } }) ?? store.currentPage else {
            throw ToolError(message: "No page is named \(pageName ?? ""). Pages: \(store.report.pages.map(\.name).joined(separator: ", ")).")
        }
        let request = try visualRequest(args)
        let spec: VisualSpec
        do {
            guard let type = AssistantAuthoring.visualType(request.type) else { throw AssistantAuthoring.Problem.unknownVisualType(request.type) }
            let frame = try AssistantAuthoring.place(type, page: CGSize(width: page.size.width, height: page.size.height),
                                                     occupied: page.visuals.filter { !$0.isHidden }.map(\.frame.cgRect))
            var built = try AssistantAuthoring.build(request, model: store.model, frame: frame, name: uniqueName(type.displayName, among: page.visuals.map(\.name)),
                                                     defaultAggregation: store.defaultAggregation)
            built.zIndex = (page.visuals.map(\.zIndex).max() ?? 0) + 1
            built.tabOrder = page.visuals.count
            spec = built
        } catch { throw problem(error) }
        var rows: [AgentChange.Row] = [.init(label: "Page", value: page.name), .init(label: "Visual", value: spec.type.displayName)]
        if let title = request.title, !title.isEmpty { rows.append(.init(label: "Title", value: title)) }
        if spec.type == .textBox { rows.append(.init(label: "Text", value: spec.content)) }
        else { rows.append(.init(label: "Fields", value: AssistantAuthoring.summary(spec))) }
        try approve(AgentChange(title: "An agent wants to add a visual.", document: store.displayName, name: spec.name, rows: rows))
        let pageID = page.id, added = spec
        store.mutate("Add \(spec.type.displayName)", invalidates: .visuals([spec.id])) { d in
            guard let i = d.report.pages.firstIndex(where: { $0.id == pageID }) else { return }
            d.report.pages[i].visuals.append(added)
        }
        return "Added a \(spec.type.displayName) to page \(page.name): \(AssistantAuthoring.summary(spec))."
    }

    @MainActor static func addPage(_ store: DocumentStore, _ args: JSONValue) throws -> String {
        let requested = try requiredLine(args, "name")
        let items = args["visuals"]?.arrayValue ?? []
        guard !items.isEmpty else { throw ToolError(message: "Give at least one visual for the page.") }
        guard items.count <= AssistantAuthoring.maxVisualsPerPage else {
            throw ToolError(message: AssistantAuthoring.Problem.tooManyVisuals(AssistantAuthoring.maxVisualsPerPage).errorDescription ?? "")
        }
        let requests = try items.map(visualRequest)
        var page = Page(name: uniqueName(requested, among: store.report.pages.map(\.name)))
        page.size = store.theme.defaultPageSize ?? .widescreen
        var types: [VisualType] = []
        for (i, r) in requests.enumerated() {
            guard let t = AssistantAuthoring.visualType(r.type) else {
                throw ToolError(message: "Visual \(i + 1): " + (AssistantAuthoring.Problem.unknownVisualType(r.type).errorDescription ?? ""))
            }
            types.append(t)
        }
        let frames = AssistantAuthoring.pageLayout(types, page: CGSize(width: page.size.width, height: page.size.height))
        for (i, r) in requests.enumerated() {
            let frame = frames.indices.contains(i) ? frames[i] : Frame(x: 24, y: 24, width: 200, height: 120)
            do {
                var spec = try AssistantAuthoring.build(r, model: store.model, frame: frame, name: uniqueName(types[i].displayName, among: page.visuals.map(\.name)),
                                                        defaultAggregation: store.defaultAggregation)
                spec.zIndex = i + 1
                spec.tabOrder = i
                page.visuals.append(spec)
            } catch {
                throw ToolError(message: "Visual \(i + 1) (\(r.type)): \(problem(error).message) Nothing was added.")
            }
        }
        try approve(AgentChange(title: "An agent wants to add a page.", document: store.displayName, name: page.name,
                                rows: [.init(label: "Page", value: page.name),
                                       .init(label: "Visuals", value: page.visuals.map(\.type.displayName).joined(separator: ", "))]))
        let created = page, at = min(store.pageIndex + 1, store.report.pages.count)
        store.mutate("Add Page", invalidates: .visuals(nil)) { d in d.report.pages.insert(created, at: min(at, d.report.pages.count)) }
        return "Added page \(created.name) with \(created.visuals.count) visuals: " + created.visuals.map { AssistantAuthoring.summary($0) }.joined(separator: " | ") + "."
    }
}
