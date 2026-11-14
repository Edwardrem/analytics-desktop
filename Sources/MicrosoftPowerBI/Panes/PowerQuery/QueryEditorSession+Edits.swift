import Foundation
import FacetCore
import FacetQuery

/// Applied-step and query-level edits of the Power Query Editor. Every edit goes through `change(_:_:)`.
extension QueryEditorSession {
    // MARK: Transforms

    /// Apply a UI transformation to the selected query: appended after the last step, or inserted after the
    /// selected step when an earlier step is selected (as Power Query's "Insert Step").
    func apply(_ transform: Transform) {
        applyStep(named: transform.stepName) { transform.expression(previous: $0) }
    }

    /// Apply a step that no `Transform` case describes (drill down, To Table, Convert to List…), the same way.
    func applyStep(named base: String, _ expression: (_ previous: String) -> String) {
        guard selectedQuery != nil else { return }
        let steps = self.steps
        if let i = currentStepIndex, i < steps.count - 1 {
            let previous = steps[i]
            let step = MStep(name: base, expression: expression(MSyntax.identifier(previous.name)))
            changeScript("Insert Step", refresh: false) { MScript.insertingStep(step, after: previous.name, in: $0) }
            selectStep(i + 1)
        } else {
            changeScript(base, refresh: false) { MScript.appendingStep(named: base, expression: expression, to: $0) }
            selectStep(nil)
        }
    }

    /// Change column types as Power Query does: into the selected step when it is a type change with the same
    /// locale (asking first, when `ask`, if it already converts one of the columns), otherwise as a new step.
    func changeTypes(_ changes: [(column: String, type: DataType)], culture: String?, ask: Bool = true) {
        guard !changes.isEmpty else { return }
        guard let index = currentStepIndex, let step = steps[safe: index], let recognized = Transform.recognize(step.expression),
              case .changeType(let existing, let stepCulture) = recognized.transform, stepCulture == culture else {
            return apply(.changeType(changes, culture: culture))
        }
        let change = TypeStepChange(stepIndex: index, previous: recognized.previous, existing: existing, changes: changes, culture: culture)
        if !change.clashes { return replaceStep(at: index, with: .changeType(change.merged, culture: culture), previous: change.previous) }
        if ask { dialog = .changeTypeStep(change) } else { apply(.changeType(changes, culture: culture)) }
    }

    /// The answer to "Change Column Type": replace the conversion in the current step, or add a new step.
    func resolve(_ change: TypeStepChange, replace: Bool) {
        if replace {
            replaceStep(at: change.stepIndex, with: .changeType(change.merged, culture: change.culture), previous: change.previous)
        } else {
            apply(.changeType(change.changes, culture: change.culture))
        }
    }

    /// Replace a step's expression with a transform re-built by its settings dialog (the gear), keeping the
    /// step's name and the step it reads.
    func replaceStep(at index: Int, with transform: Transform, previous: String) {
        guard let step = steps[safe: index] else { return }
        changeScript("Edit Step") { MScript.replacingStepExpression(step.name, with: transform.expression(previous: previous), in: $0) }
    }

    // MARK: Steps

    func renameStep(at index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let step = steps[safe: index], !trimmed.isEmpty, trimmed != step.name else { return }
        guard !steps.contains(where: { $0.name == trimmed }) else {
            message = StatusMessage(kind: .warning, text: "The query already has a step named “\(trimmed)”.")
            return
        }
        changeScript("Rename Step") { MScript.renamingStep(step.name, to: trimmed, in: $0) }
    }

    func deleteStep(at index: Int) {
        guard let step = steps[safe: index], steps.count > 1 else { return }
        changeScript("Delete Step", refresh: false) { MScript.deletingStep(step.name, in: $0) }
        selectStep(index == 0 ? 0 : index - 1)
    }

    /// "Delete Until End": the step and every step after it.
    func deleteUntilEnd(from index: Int) {
        let all = steps
        guard index > 0, index < all.count else { return }
        changeScript("Delete Steps", refresh: false) { _ in MScript.script(from: Array(all.prefix(index))) }
        selectStep(nil)
    }

    func moveStep(at index: Int, by offset: Int) {
        let all = steps
        guard let step = all[safe: index], all.indices.contains(index + offset) else { return }
        changeScript("Move Step", refresh: false) { MScript.movingStep(step.name, to: index + offset, in: $0) }
        selectStep(index + offset)
    }

    /// The formula bar's fx button: a new step after the selected one that returns it unchanged.
    func insertCustomStep() {
        guard let current = currentStep, let i = currentStepIndex else { return }
        let step = MStep(name: "Custom1", expression: MSyntax.identifier(current.name))
        changeScript("Insert Step", refresh: false) { MScript.insertingStep(step, after: current.name, in: $0) }
        selectStep(i + 1)
    }

    /// Commit a formula-bar edit of the selected step. Returns the syntax error that stopped it, if any.
    @discardableResult
    func setStepExpression(_ text: String) -> String? {
        guard let step = currentStep, let q = selectedQuery else { return nil }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("=") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard body != step.expression else { return nil }
        let script = MScript.replacingStepExpression(step.name, with: body, in: q.mScript)
        if let problem = syntaxError(in: script) { return problem }
        changeScript("Edit Step") { _ in script }
        return nil
    }

    /// Commit the Advanced Editor. Returns the syntax error that stopped it, if any.
    @discardableResult
    func setScript(_ text: String) -> String? {
        guard let q = selectedQuery, text != q.mScript else { return nil }
        if let problem = syntaxError(in: text) { return problem }
        changeScript("Edit Query", refresh: false) { _ in text }
        selectStep(nil)
        return nil
    }

    /// The first syntax error of a script (warnings such as unknown names do not block a commit, as in Power Query).
    func syntaxError(in script: String) -> String? {
        MScript.validate(script, knownNames: queryNames).first { $0.severity == .error }?.errorDescription
    }

    // MARK: Queries

    func addQuery(_ q: QueryDefinition, name actionName: String) {
        change(actionName) { $0.append(q) }
        selectedQueryID = q.id
    }

    func newBlankQuery() {
        let q = QueryDefinition(name: QueryEditorPlans.newQueryName(taken: queryNames), mScript: MScript.script(from: [MStep(name: "Source", expression: "\"\"")]))
        addQuery(q, name: "New Query")
    }

    /// Rename a query and every reference to it in the other queries. Returns why it could not be renamed.
    @discardableResult
    func renameQuery(_ id: UUID, to newName: String) -> String? {
        guard let q = query(id) else { return nil }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != q.name else { return nil }
        var tables: [String: String] = [:]
        for t in store.doc.model.tables { tables[t.name] = t.sourceQuery ?? "" }
        if let problem = QueryEditorPlans.queryNameProblem(trimmed, for: id, queries: queries, modelTables: tables) {
            message = StatusMessage(kind: .warning, text: problem)
            return problem
        }
        let old = q.name
        change("Rename Query") { qs in
            for i in qs.indices {
                if qs[i].id == id { qs[i].name = trimmed } else { qs[i].mScript = MScript.replacingIdentifier(old, with: trimmed, in: qs[i].mScript) }
            }
        }
        return nil
    }

    /// Delete queries. Refused (with the reason) while other queries that are not deleted reference them.
    @discardableResult
    func deleteQueries(_ ids: Set<UUID>) -> String? {
        let names = Set(queries.filter { ids.contains($0.id) }.map(\.name))
        guard !names.isEmpty else { return nil }
        let graph = QueryDependencyGraph(queries: queries)
        for n in names.sorted() {
            let users = (graph.dependents[n] ?? []).filter { !names.contains($0) }
            if !users.isEmpty {
                let problem = "“\(n)” can't be deleted because \(users.map { "“\($0)”" }.joined(separator: ", ")) refer\(users.count == 1 ? "s" : "") to it."
                message = StatusMessage(kind: .warning, text: problem)
                return problem
            }
        }
        change(names.count == 1 ? "Delete Query" : "Delete Queries") { $0.removeAll { ids.contains($0.id) } }
        if selectedQuery == nil { selectedQueryID = queries.first?.id }
        return nil
    }

    func duplicateQuery(_ id: UUID) {
        guard let q = query(id) else { return }
        addQuery(MScript.duplicateQuery(q, newName: SourcePlanner.uniqueName(q.name, taken: queryNames)), name: "Duplicate Query")
    }

    func referenceQuery(_ id: UUID) {
        guard let q = query(id) else { return }
        addQuery(MScript.referenceQuery(q, newName: SourcePlanner.uniqueName(q.name, taken: queryNames)), name: "Reference Query")
    }

    func setLoadEnabled(_ id: UUID, _ on: Bool) {
        change(on ? "Enable Load" : "Disable Load", refresh: false) { qs in
            // A query that does not load is not refreshed either; enabling load includes it again.
            if let i = qs.firstIndex(where: { $0.id == id }) { qs[i].loadEnabled = on; qs[i].includeInRefresh = on }
        }
    }

    func setIncludeInRefresh(_ id: UUID, _ on: Bool) {
        change("Include in Report Refresh", refresh: false) { qs in
            if let i = qs.firstIndex(where: { $0.id == id }) { qs[i].includeInRefresh = on }
        }
    }

    func setDescription(_ id: UUID, _ text: String) {
        change("Edit Description", refresh: false) { qs in
            if let i = qs.firstIndex(where: { $0.id == id }) { qs[i].description = text }
        }
    }

    // MARK: Groups

    func moveQueries(_ ids: Set<UUID>, toGroup group: String) {
        change("Move to Group", refresh: false) { qs in
            for i in qs.indices where ids.contains(qs[i].id) { qs[i].group = group }
        }
        extraGroups.removeAll { $0 == group }
    }

    func newGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !groups.contains(trimmed) else { return }
        extraGroups.append(trimmed)
    }

    func renameGroup(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        if let i = extraGroups.firstIndex(of: old) { extraGroups[i] = trimmed }
        change("Rename Group", refresh: false) { qs in
            for i in qs.indices where qs[i].group == old { qs[i].group = trimmed }
        }
    }

    /// "Ungroup": the group's queries move back to Other Queries.
    func ungroup(_ group: String) {
        extraGroups.removeAll { $0 == group }
        change("Ungroup", refresh: false) { qs in
            for i in qs.indices where qs[i].group == group { qs[i].group = "" }
        }
    }

    // MARK: Parameters

    /// Add or replace a parameter query. Returns why it could not be saved.
    @discardableResult
    func saveParameter(id: UUID?, name: String, description: String, parameter: QueryParameter) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var tables: [String: String] = [:]
        for t in store.doc.model.tables { tables[t.name] = t.sourceQuery ?? "" }
        if let problem = QueryEditorPlans.queryNameProblem(trimmed, for: id ?? UUID(), queries: queries, modelTables: tables) { return problem }
        if let id, let existing = query(id) {
            let old = existing.name
            change("Edit Parameter") { qs in
                for i in qs.indices {
                    if qs[i].id == id {
                        qs[i].name = trimmed; qs[i].description = description
                        qs[i].parameter = parameter; qs[i].mScript = MScript.parameterScript(parameter)
                    } else if old != trimmed {
                        qs[i].mScript = MScript.replacingIdentifier(old, with: trimmed, in: qs[i].mScript)
                    }
                }
            }
        } else {
            var q = QueryDefinition(name: trimmed, mScript: MScript.parameterScript(parameter))
            q.kind = .parameter
            q.parameter = parameter
            q.description = description
            q.loadEnabled = false
            q.includeInRefresh = false
            change("New Parameter") { $0.append(q) }
        }
        return nil
    }

    /// "Convert To Parameter": a query that returns a single value becomes a parameter with that value.
    func convertToParameter(_ id: UUID) async {
        guard let q = query(id) else { return }
        do {
            let engine = makeEngine()
            let raw = try await engine.evaluateValue(q.name)
            let table = try await engine.evaluate(q.name)
            guard raw.scalarKind == .value, let column = table.columns.first, let value = column.values.first else {
                message = StatusMessage(kind: .warning, text: "Only a query that returns a single value can become a parameter.")
                return
            }
            var p = QueryParameter()
            p.type = column.type == .any ? .text : column.type
            p.currentValue = value
            change("Convert to Parameter") { qs in
                if let i = qs.firstIndex(where: { $0.id == id }) {
                    qs[i].kind = .parameter; qs[i].parameter = p; qs[i].mScript = MScript.parameterScript(p)
                    qs[i].loadEnabled = false; qs[i].includeInRefresh = false
                }
            }
        } catch {
            message = StatusMessage(kind: .error, text: MError.wrap(error).description)
        }
    }

    /// "Convert To Query": a parameter becomes an ordinary query returning its current value.
    func convertToQuery(_ id: UUID) {
        guard let q = query(id), q.kind == .parameter else { return }
        let literal = q.parameter.map { MSyntax.literal($0.currentValue, type: $0.type) } ?? "null"
        change("Convert to Query") { qs in
            if let i = qs.firstIndex(where: { $0.id == id }) {
                qs[i].kind = .table; qs[i].parameter = nil
                qs[i].mScript = MScript.script(from: [MStep(name: "Source", expression: literal)])
            }
        }
    }

    /// "Create Function…": the query becomes the body of a function whose parameters replace the parameter
    /// queries it references, added as a new function query.
    @discardableResult
    func createFunction(from id: UUID, named name: String) -> String? {
        guard let q = query(id) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = QueryEditorPlans.queryNameProblem(trimmed, for: UUID(), queries: queries, modelTables: [:]) { return problem }
        let parameters = queries.filter { $0.kind == .parameter }
        let used = MScript.referencedIdentifiers(in: q.mScript).filter { n in parameters.contains { $0.name == n } }
        guard !used.isEmpty else { return "“\(q.name)” uses no parameters; add a parameter to the query first." }
        let typed = used.map { n -> (name: String, type: String?) in
            (n, parameters.first { $0.name == n }?.parameter.flatMap { Self.primitiveTypeName($0.type) })
        }
        var f = QueryDefinition(name: trimmed, mScript: MScript.toFunction(q.mScript, parameters: typed))
        f.kind = .function
        f.group = q.group
        f.loadEnabled = false
        addQuery(f, name: "Create Function")
        return nil
    }
}

extension QueryEditorSession {
    /// The M primitive type a function parameter is declared with (`as number`, `as text`…).
    static func primitiveTypeName(_ type: DataType) -> String? {
        switch type {
        case .text: return "text"
        case .integer, .decimal, .currency: return "number"
        case .boolean: return "logical"
        case .date: return "date"
        case .dateTime: return "datetime"
        case .time: return "time"
        case .duration: return "duration"
        case .binary: return "binary"
        case .any: return nil
        }
    }
}

private extension MValue {
    enum ScalarKind { case value, structured }
    /// Whether the value is a single primitive (number, text, date, logical…), as a parameter needs.
    var scalarKind: ScalarKind {
        switch typeName {
        case "table", "list", "record", "function", "binary", "type": return .structured
        default: return .value
        }
    }
}
