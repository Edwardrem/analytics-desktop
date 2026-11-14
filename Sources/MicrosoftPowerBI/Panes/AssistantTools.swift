import Foundation
import CoreGraphics
import FacetCore
import FacetQuery
import FacetCloud

/// The tools the Assistant pane gives the model: read the model and the report, run DAX, and author the
/// report. Every change is checked first and goes through `DocumentStore.mutate`, so Undo takes it back.
@MainActor
enum AssistantTools {
    /// The store, held weakly so a closed document is not kept alive by its conversation.
    final class StoreBox: @unchecked Sendable {
        weak var store: DocumentStore?
        init(_ store: DocumentStore) { self.store = store }
    }

    nonisolated static let closed = AssistantToolOutput.error("The document is closed.")

    struct CheckFailure: Error { var message: String }

    private static let fieldItem: FacetCloud.JSONValue = [
        "type": "object",
        "properties": [
            "field": ["type": "string", "description": "'Table'[Column] or [Measure], exactly as named in the model."],
            "well": ["type": "string", "description": "Optional well: category (axis), values, legend, rows, columns, x, y, size, details, tooltips, field."],
            "aggregation": ["type": "string", "description": "Optional, for a column in a value well: sum, average, min, max, count, distinctCount, median."],
        ],
        "required": ["field"],
    ]

    private static let visualProperties: FacetCloud.JSONValue = [
        "type": ["type": "string", "description": .string("Visual type: \(AssistantAuthoring.typeNames.joined(separator: ", ")).")],
        "fields": ["type": "array", "items": fieldItem,
                   "description": "Fields to show. Measures and numeric columns go in the value wells, other columns in the axis or legend, unless a well is given."],
        "title": ["type": "string", "description": "Optional visual title."],
        "text": ["type": "string", "description": "The text of a textBox."],
    ]

    static func tools(for store: DocumentStore) -> [AssistantTool] {
        let box = StoreBox(store)
        return [
            AssistantTool(name: "run_dax",
                          description: "Runs a DAX query (EVALUATE …) against the model and returns up to 20 rows per result table.",
                          inputSchema: ["type": "object", "properties": ["dax": ["type": "string"]], "required": ["dax"]],
                          handler: { input in
                              guard let store = box.store else { return closed }
                              return await runDAX(input["dax"]?.stringValue ?? "", store: store)
                          }),
            AssistantTool(name: "get_model_schema",
                          description: "Returns the semantic model: tables, columns, measures with their DAX, relationships, the author's instructions and verified answers.",
                          inputSchema: ["type": "object", "properties": [:]],
                          handler: { _ in
                              guard let store = box.store else { return closed }
                              return await AssistantToolOutput(AssistantContext.model(store))
                          }),
            AssistantTool(name: "describe_page",
                          description: "Describes a report page as the user sees it now: its filters, and each visual with its fields and the values it shows. Defaults to the page the user is on.",
                          inputSchema: ["type": "object", "properties": ["page": ["type": "string", "description": "Page name; omit for the current page."]]],
                          handler: { input in
                              guard let store = box.store else { return closed }
                              return await describePage(input["page"]?.stringValue, store: store)
                          }),
            AssistantTool(name: "describe_report",
                          description: "Describes every visible page of the report with the top values of each visual.",
                          inputSchema: ["type": "object", "properties": [:]],
                          handler: { _ in
                              guard let store = box.store else { return closed }
                              return await AssistantToolOutput(AssistantContext.report(store))
                          }),
            AssistantTool(name: "add_visual",
                          description: "Adds a visual with its fields to a report page, in free space so it covers no other visual. Fields are checked against the model first.",
                          inputSchema: ["type": "object",
                                        "properties": .object((visualProperties.members ?? []) + [
                                            JSONMember(key: "page", value: ["type": "string", "description": "Page name; omit for the current page."]),
                                        ]),
                                        "required": ["type"]],
                          handler: { input in
                              guard let store = box.store else { return closed }
                              return await addVisual(input, store: store)
                          }),
            AssistantTool(name: "create_page",
                          description: "Creates a new report page holding a set of visuals laid out in a grid (cards, KPIs and slicers in a row across the top), and opens it. Nothing is created if any visual fails the check.",
                          inputSchema: ["type": "object",
                                        "properties": [
                                            "name": ["type": "string", "description": "Page name."],
                                            "visuals": ["type": "array", "items": ["type": "object", "properties": visualProperties, "required": ["type"]]],
                                        ],
                                        "required": ["name", "visuals"]],
                          handler: { input in
                              guard let store = box.store else { return closed }
                              return await createPage(input, store: store)
                          }),
            AssistantTool(name: "add_measure",
                          description: "Adds a DAX measure to a table. The formula is checked and evaluated once before it is added.",
                          inputSchema: ["type": "object",
                                        "properties": ["table": ["type": "string"], "name": ["type": "string"], "expression": ["type": "string"],
                                                       "format_string": ["type": "string", "description": "Optional format, such as \"$#,0\" or \"0.0%\"."],
                                                       "description": ["type": "string", "description": "Optional one-sentence description."]],
                                        "required": ["table", "name", "expression"]],
                          handler: { input in
                              guard let store = box.store else { return closed }
                              return await addMeasure(input, store: store)
                          }),
        ]
    }

    // MARK: Reading

    static func runDAX(_ dax: String, store: DocumentStore) async -> AssistantToolOutput {
        guard !dax.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error("Provide a DAX query in the \"dax\" property.") }
        let result: Result<[DataTable], Error> = await store.withEngine { engine in Result { try engine.query(dax) } }
        switch result {
        case .success(let tables): return AssistantToolOutput(describe(tables))
        case .failure(let e): return .error(MError.wrap(e).description)
        }
    }

    nonisolated static func describe(_ tables: [DataTable], maxRows: Int = 20) -> String {
        var out: [String] = []
        for t in tables {
            out.append(t.columnNames.joined(separator: " | "))
            for row in t.rows.prefix(maxRows) { out.append(row.map { $0.asString }.joined(separator: " | ")) }
            if t.rowCount > maxRows { out.append("… \(t.rowCount - maxRows) more rows") }
        }
        return out.isEmpty ? "(no results)" : out.joined(separator: "\n")
    }

    static func page(named name: String?, in store: DocumentStore) -> Page? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return store.currentPage }
        return store.report.pages.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func describePage(_ name: String?, store: DocumentStore) async -> AssistantToolOutput {
        guard let page = page(named: name, in: store) else { return .error(noPage(name ?? "", store)) }
        return AssistantToolOutput(await AssistantContext.page(page, store: store))
    }

    private static func noPage(_ name: String, _ store: DocumentStore) -> String {
        "The report has no page named \"\(name)\". Its pages are: \(store.report.pages.map { "\"\($0.name)\"" }.joined(separator: ", "))."
    }

    // MARK: Authoring

    /// A visual request from a tool input. Fields may be objects or plain reference strings.
    static func visualRequest(_ input: FacetCloud.JSONValue) -> AssistantAuthoring.VisualRequest {
        let fields = (input["fields"]?.arrayValue ?? []).compactMap { item -> AssistantAuthoring.FieldRequest? in
            if let s = item.stringValue { return AssistantAuthoring.FieldRequest(reference: s) }
            guard let ref = item["field"]?.stringValue else { return nil }
            return AssistantAuthoring.FieldRequest(reference: ref, well: item["well"]?.stringValue, aggregation: item["aggregation"]?.stringValue)
        }
        return AssistantAuthoring.VisualRequest(type: input["type"]?.stringValue ?? "", fields: fields,
                                               title: input["title"]?.stringValue, text: input["text"]?.stringValue)
    }

    private static func uniqueName(_ base: String, among names: Set<String>) -> String {
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func addVisual(_ input: FacetCloud.JSONValue, store: DocumentStore) async -> AssistantToolOutput {
        guard let page = page(named: input["page"]?.stringValue, in: store),
              let pageIndex = store.report.pages.firstIndex(where: { $0.id == page.id }) else {
            return .error(noPage(input["page"]?.stringValue ?? "", store))
        }
        let request = visualRequest(input)
        do {
            guard let type = AssistantAuthoring.visualType(request.type) else { throw AssistantAuthoring.Problem.unknownVisualType(request.type) }
            let occupied = page.visuals.filter { !$0.isHidden }.map(\.frame.cgRect)
            let frame = try AssistantAuthoring.place(type, page: CGSize(width: page.size.width, height: page.size.height), occupied: occupied)
            let name = uniqueName(type.displayName, among: Set(page.visuals.map(\.name)))
            var spec = try AssistantAuthoring.build(request, model: store.model, frame: frame, name: name,
                                                    defaultAggregation: store.defaultAggregation)
            spec.zIndex = (page.visuals.map(\.zIndex).max() ?? 0) + 1
            spec.tabOrder = page.visuals.count
            store.mutate("Add \(type.displayName)", invalidates: .visuals([spec.id])) { d in
                guard d.report.pages.indices.contains(pageIndex) else { return }
                d.report.pages[pageIndex].visuals.append(spec)
            }
            if page.id == store.currentPageID { store.selection = [spec.id] }
            let f = spec.frame
            return AssistantToolOutput("Added a \(type.displayName) \"\(AssistantContext.title(spec))\" to page \"\(page.name)\" at x \(Int(f.x)), y \(Int(f.y)), \(Int(f.width))×\(Int(f.height)): \(AssistantAuthoring.summary(spec)). The user can undo it.")
        } catch {
            return .error(AssistantTasks.message(error))
        }
    }

    static func createPage(_ input: FacetCloud.JSONValue, store: DocumentStore) async -> AssistantToolOutput {
        let requests = (input["visuals"]?.arrayValue ?? []).map(visualRequest)
        guard !requests.isEmpty else { return .error("Give at least one visual for the page.") }
        guard requests.count <= AssistantAuthoring.maxVisualsPerPage else {
            return .error(AssistantAuthoring.Problem.tooManyVisuals(AssistantAuthoring.maxVisualsPerPage).errorDescription ?? "")
        }
        let requested = (input["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var page = Page(name: uniqueName(requested.isEmpty ? "Page" : requested, among: Set(store.report.pages.map(\.name))))
        page.size = store.theme.defaultPageSize ?? .widescreen
        var types: [VisualType] = []
        for (i, r) in requests.enumerated() {
            guard let t = AssistantAuthoring.visualType(r.type) else {
                return .error("Visual \(i + 1): " + (AssistantAuthoring.Problem.unknownVisualType(r.type).errorDescription ?? ""))
            }
            types.append(t)
        }
        let frames = AssistantAuthoring.pageLayout(types, page: CGSize(width: page.size.width, height: page.size.height))
        var lines: [String] = []
        for (i, r) in requests.enumerated() {
            let frame = frames.indices.contains(i) ? frames[i] : Frame(x: 24, y: 24, width: 200, height: 120)
            do {
                let name = uniqueName(types[i].displayName, among: Set(page.visuals.map(\.name)))
                var spec = try AssistantAuthoring.build(r, model: store.model, frame: frame, name: name, defaultAggregation: store.defaultAggregation)
                spec.zIndex = i + 1
                spec.tabOrder = i
                page.visuals.append(spec)
                lines.append("- \(spec.type.displayName) \"\(AssistantContext.title(spec))\": \(AssistantAuthoring.summary(spec))")
            } catch {
                return .error("Visual \(i + 1) (\(r.type)): \(AssistantTasks.message(error)) Nothing was created.")
            }
        }
        let at = min(store.pageIndex + 1, store.report.pages.count)
        let created = page
        store.mutate("Create Page \"\(created.name)\"", invalidates: .layout) { d in
            d.report.pages.insert(created, at: min(at, d.report.pages.count))
        }
        store.goToPage(created.id)
        return AssistantToolOutput("Created page \"\(created.name)\" with \(created.visuals.count) visuals and opened it:\n" + lines.joined(separator: "\n") + "\nThe user can undo it.")
    }

    static func addMeasure(_ input: FacetCloud.JSONValue, store: DocumentStore) async -> AssistantToolOutput {
        let tableName = input["table"]?.stringValue ?? ""
        let name = (input["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = (input["expression"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let table = store.model.table(tableName) else {
            return .error("The model has no table named \"\(tableName)\". Its tables are: \(store.model.tables.map(\.name).joined(separator: ", ")).")
        }
        guard !expression.isEmpty else { return .error("Give the measure's DAX expression.") }
        if let problem = ModelOps.nameProblem(name, kind: .measure, table: table.name, original: nil, model: store.model) { return .error(problem) }
        let home = table.name
        let check: Result<String, CheckFailure> = await store.withEngine { engine in
            let issues = engine.check(expression, kind: .measure, homeTable: home).filter { !$0.isWarning }.map(\.message)
            if !issues.isEmpty { return .failure(CheckFailure(message: issues.joined(separator: " "))) }
            // Evaluated once with no filters, so a reference the static check cannot resolve still fails here.
            do {
                let value = try engine.query("EVALUATE ROW(\"Value\", \(expression)\n)").first?.rows.first?.first
                return .success(value.map { $0.isNull ? "(Blank)" : $0.asString } ?? "(Blank)")
            } catch {
                return .failure(CheckFailure(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        switch check {
        case .failure(let problem):
            return .error("The measure was not added; its formula does not check out: \(problem.message)")
        case .success(let value):
            var measure = Measure(name: name, expression: expression, formatString: input["format_string"]?.stringValue ?? "")
            measure.description = input["description"]?.stringValue ?? ""
            store.mutate("Add Measure", invalidates: .model) { d in
                guard let t = d.model.tableIndex(home) else { return }
                d.model.tables[t].measures.append(measure)
            }
            return AssistantToolOutput("Added measure [\(name)] to '\(home)'. With no filters it evaluates to \(value). The user can undo it.")
        }
    }
}

