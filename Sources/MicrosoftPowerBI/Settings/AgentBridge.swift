import SwiftUI
import AppKit
import FacetCore
import FacetInterop

/// The Modeling MCP server: lets AI agents and tools on this Mac read the open documents' models, run DAX, and —
/// after the user confirms each change — add or change measures.
///
/// Off by default. It listens on 127.0.0.1 only, on a port chosen at start, and every request must carry the session
/// token, which is new on every start and never written to disk.
@MainActor
final class AgentBridge: ObservableObject {
    static let shared = AgentBridge()

    @Published private(set) var isRunning = false
    @Published private(set) var endpoint = ""
    @Published private(set) var token = ""
    @Published private(set) var lastError: String?
    private var server: MCPServer?

    /// Asks the user before a tool changes a document. Replaced in tests.
    var confirm: (_ message: String, _ detail: String) -> Bool = { message, detail in
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// The documents tools work on. Replaced in tests.
    var documents: () -> [(id: UUID, store: DocumentStore)] = {
        StoreRegistry.shared.all.compactMap { s in StoreRegistry.shared.id(of: s).map { ($0, s) } }
    }

    func start() async {
        guard server == nil else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let dispatcher = MCPDispatcher(serverName: "\(AppIdentity.name) modeling", serverVersion: version, tools: { AgentTools.all })
        let s = MCPServer(dispatcher: dispatcher)
        do {
            try await s.start()
            server = s
            isRunning = true
            endpoint = s.endpoint
            token = s.token
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        endpoint = ""
        token = ""
    }

    /// The JSON an MCP client is configured with (endpoint and bearer header).
    var clientConfiguration: String {
        """
        {
          "mcpServers": {
            "analytics-desktop": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }
}

/// The tools the MCP server offers.
enum AgentTools {
    struct ToolError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let documentArgument: JSONValue = .object(["type": .string("string"), "description": .string("Document id from list_documents; optional when one document is open.")])

    static var all: [MCPTool] {
        [
            MCPTool(name: "list_documents", description: "Lists the documents open in \(AppIdentity.name) with their ids, tables, measures and pages.") { _ in
                try await MainActor.run { try listDocuments() }
            },
            MCPTool(name: "get_model", description: "Returns a document's semantic model and Power Query queries as TMDL.",
                    inputSchema: schema(["document": documentArgument], required: [])) { args in
                try await MainActor.run { try modelTMDL(document(args)) }
            },
            MCPTool(name: "get_report_outline", description: "Lists a document's report pages and the fields each visual uses.",
                    inputSchema: schema(["document": documentArgument], required: [])) { args in
                try await MainActor.run { try outline(document(args)) }
            },
            MCPTool(name: "run_dax_query", description: "Runs a DAX query (EVALUATE …) against a document's model and returns up to 500 rows as tab-separated text.",
                    inputSchema: schema(["document": documentArgument, "query": text("The DAX query, starting with EVALUATE or DEFINE.")], required: ["query"])) { args in
                let store = try await MainActor.run { try document(args) }
                return try await runQuery(store, query: string(args, "query"))
            },
            MCPTool(name: "set_measure", description: "Adds a measure to a table, or replaces the measure of that name. The user is asked to allow each change.",
                    inputSchema: schema(["document": documentArgument, "table": text("Home table of the measure."), "name": text("Measure name."),
                                         "expression": text("DAX expression."), "formatString": text("Optional format string, e.g. #,0.00.")],
                                        required: ["table", "name", "expression"])) { args in
                let store = try await MainActor.run { try document(args) }
                return try await setMeasure(store, args)
            },
        ]
    }

    private static func text(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) })])
    }

    static func string(_ args: JSONValue, _ key: String) throws -> String {
        guard let v = args[key]?.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError(message: "“\(key)” is required.")
        }
        return v
    }

    @MainActor static func document(_ args: JSONValue) throws -> DocumentStore {
        let docs = AgentBridge.shared.documents()
        if let id = args["document"]?.stringValue, !id.isEmpty {
            guard let uuid = UUID(uuidString: id), let match = docs.first(where: { $0.id == uuid }) else {
                throw ToolError(message: "No open document has the id \(id). Call list_documents.")
            }
            return match.store
        }
        guard let only = docs.first else { throw ToolError(message: "No document is open in \(AppIdentity.name).") }
        guard docs.count == 1 else { throw ToolError(message: "\(docs.count) documents are open; pass “document” with an id from list_documents.") }
        return only.store
    }

    @MainActor static func listDocuments() throws -> String {
        let rows: [JSONValue] = AgentBridge.shared.documents().map { id, store in
            .object([
                "id": .string(id.uuidString), "name": .string(store.displayName), "unsaved": .bool(store.isDirty),
                "tables": .array(store.model.tables.map { .string($0.name) }),
                "measures": .number(Double(store.model.tables.reduce(0) { $0 + $1.measures.count })),
                "pages": .array(store.report.pages.map { .string($0.name) }),
            ])
        }
        return String(decoding: JSONValue.array(rows).serialized(pretty: true), as: UTF8.self)
    }

    @MainActor static func modelTMDL(_ store: DocumentStore) -> String {
        TMDL.serialize(model: store.model, queries: store.doc.queries)
            .map { "// \($0.path)\n\($0.text)" }.joined(separator: "\n\n")
    }

    @MainActor static func outline(_ store: DocumentStore) -> String {
        store.report.pages.map { page in
            let visuals = page.visuals.filter { !$0.type.isPageElement }.map { v in
                let fields = v.allFields.map { $0.kind == .measure ? "[\($0.name)]" : "'\($0.table)'[\($0.name)]" }
                return "  - \(v.name.isEmpty ? v.type.displayName : v.name) (\(v.type.displayName)): \(fields.joined(separator: ", "))"
            }
            return "\(page.name)\n" + (visuals.isEmpty ? "  (no data visuals)" : visuals.joined(separator: "\n"))
        }.joined(separator: "\n")
    }

    static let rowLimit = 500

    static func runQuery(_ store: DocumentStore, query: String) async throws -> String {
        let result: Result<[DataTable], Error> = await store.withEngine { engine in Result { try engine.query(query) } }
        guard let table = try result.get().first else { return "The query returned no table." }
        var lines = [table.columns.map(\.name).joined(separator: "\t")]
        let count = min(table.rowCount, rowLimit)
        for r in 0..<count {
            lines.append(table.columns.map { c in r < c.values.count ? c.values[r].asString : "" }.joined(separator: "\t"))
        }
        if table.rowCount > rowLimit { lines.append("… \(table.rowCount - rowLimit) more rows") }
        return lines.joined(separator: "\n")
    }

    @MainActor static func setMeasure(_ store: DocumentStore, _ args: JSONValue) async throws -> String {
        let tableName = try string(args, "table"), name = try string(args, "name"), expression = try string(args, "expression")
        let format = args["formatString"]?.stringValue
        guard store.model.table(tableName) != nil else { throw ToolError(message: "“\(store.displayName)” has no table named \(tableName).") }
        let issues = await store.withEngine { $0.check(expression, kind: .measure, homeTable: tableName) }.filter { !$0.isWarning }
        guard issues.isEmpty else { throw ToolError(message: "The expression has errors: " + issues.map(\.message).joined(separator: "; ")) }
        let replacing = store.model.measure(name) != nil
        guard AgentBridge.shared.confirm("An agent wants to \(replacing ? "change" : "add") the measure “\(name)” in “\(store.displayName)”.",
                                         "\(tableName)[\(name)] =\n\(expression)") else {
            throw ToolError(message: "The user didn't allow the change.")
        }
        store.updateModel(replacing ? "Change Measure" : "New Measure") { model in
            for t in model.tables.indices { model.tables[t].measures.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            guard let i = model.tableIndex(tableName) else { return }
            var m = Measure(name: name, expression: expression)
            if let format, !format.isEmpty { m.formatString = format }
            model.tables[i].measures.append(m)
        }
        return "\(replacing ? "Changed" : "Added") \(tableName)[\(name)]."
    }
}

@MainActor
enum AgentBridgeFeature {
    static func register() {
        if !SettingsSections.extra.contains(where: { $0.title == "Developer" }) {
            SettingsSections.extra.append(SettingsSections.Section(title: "Developer", symbol: "hammer", view: { AnyView(DeveloperSettings()) }))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if AppSettings.bool(.mcpServerEnabled) { Task { await AgentBridge.shared.start() } }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentBridge.shared.stop() }
        }
    }
}
