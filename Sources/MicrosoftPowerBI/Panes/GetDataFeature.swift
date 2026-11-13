import SwiftUI
import FacetCore
import FacetQuery
import FacetDesign

/// Getting data: the connector dialog (file, database, web and folder sources the M engine
/// supports), Enter Data (paste a table), and the commands that wire them up.
@MainActor
enum GetDataFeature {
    static func register() {
        AppCommands.register { commands }
    }

    static var commands: [AppCommand] {
        [
            AppCommand(id: "data.get", title: "Get Data…", menu: .data, symbol: "cylinder.split.1x2",
                       shortcut: .init("g", modifiers: [.command, .shift]), separatorBefore: true) { store in
                store.present { GetDataDialog() }
            },
            AppCommand(id: "data.enter", title: "Enter Data", menu: .data, symbol: "square.and.pencil") { store in
                store.present { EnterDataSheet() }
            },
            AppCommand(id: "data.recent", title: "Recent Sources…", menu: .data, symbol: "clock",
                       isEnabled: { _ in true }) { store in
                store.present { RecentSourcesSheet() }
            },
            AppCommand(id: "data.transform", title: "Transform Data", menu: .data, symbol: "wand.and.rays") { store in
                NotificationCenter.default.post(name: .facetOpenQueryEditor, object: nil)
                if store.doc.queries.isEmpty {
                    store.status = StatusMessage(kind: .info, text: "Get data first, then shape it in the Power Query Editor.")
                }
            },
        ]
    }
}

// MARK: - Connector catalog

struct DataConnector: Identifiable, Hashable {
    enum Family: String, CaseIterable { case file = "File", database = "Database", web = "Web", other = "Other" }
    let id: String
    let name: String
    let family: Family
    let symbol: String
    /// What the dialog asks for: path picker, URL field, connection fields.
    let fields: [Field]

    struct Field: Hashable { let key: String; let label: String; let placeholder: String; let isSecure = false }

    static let all: [DataConnector] = [
        DataConnector(id: "csv", name: "Text/CSV", family: .file, symbol: "doc.plaintext",
                      fields: [Field(key: "path", label: "File path", placeholder: "/path/to/file.csv")]),
        DataConnector(id: "excel", name: "Excel workbook", family: .file, symbol: "tablecells",
                      fields: [Field(key: "path", label: "File path", placeholder: "/path/to/workbook.xlsx")]),
        DataConnector(id: "json", name: "JSON", family: .file, symbol: "curlybraces",
                      fields: [Field(key: "path", label: "File path", placeholder: "/path/to/data.json")]),
        DataConnector(id: "xml", name: "XML", family: .file, symbol: "chevron.left.forwardslash.chevron.right",
                      fields: [Field(key: "path", label: "File path", placeholder: "/path/to/data.xml")]),
        DataConnector(id: "parquet", name: "Parquet", family: .file, symbol: "cylinder",
                      fields: [Field(key: "path", label: "File path", placeholder: "/path/to/data.parquet")]),
        DataConnector(id: "sql", name: "SQL Server database", family: .database, symbol: "cylinder.split.1x2",
                      fields: [Field(key: "server", label: "Server", placeholder: "server\\instance"),
                               Field(key: "database", label: "Database (optional)", placeholder: "Sales")]),
        DataConnector(id: "odbc", name: "ODBC", family: .database, symbol: "cylinder",
                      fields: [Field(key: "dsn", label: "Connection string or DSN", placeholder: "dsn=Sales")]),
        DataConnector(id: "web", name: "Web", family: .web, symbol: "globe",
                      fields: [Field(key: "url", label: "URL", placeholder: "https://example.com/data.json")]),
        DataConnector(id: "folder", name: "Folder", family: .other, symbol: "folder",
                      fields: [Field(key: "path", label: "Folder path", placeholder: "/path/to/folder")]),
        DataConnector(id: "sharepoint", name: "SharePoint folder", family: .other, symbol: "cloud",
                      fields: [Field(key: "url", label: "Site URL", placeholder: "https://contoso.sharepoint.com/sites/site")]),
    ]

    static func connector(_ id: String) -> DataConnector? { all.first { $0.id == id } }
}

// MARK: - Dialog

struct GetDataDialog: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: DataConnector?
    @State private var values: [String: String] = [:]
    @State private var isWorking = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selected?.id }, set: { id in
                selected = id.flatMap(DataConnector.connector)
                values = [:]
            })) {
                ForEach(DataConnector.Family.allCases, id: \.self) { family in
                    Section(family.rawValue) {
                        ForEach(DataConnector.all.filter { $0.family == family }) { c in
                            HStack(spacing: Design.Space.xs) {
                                Image(systemName: c.symbol).foregroundStyle(.secondary)
                                Text(c.name).lineLimit(1)
                            }
                            .tag(Optional(c.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460)
    }

    @ViewBuilder
    private var detail: some View {
        if let connector = selected {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: connector.symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor)
                    Text(connector.name).font(Design.Typeface.headline)
                }
                if connector.id == "csv" || connector.id == "excel" || connector.id == "json" || connector.id == "xml" || connector.id == "parquet" {
                    Button("Browse…") { browse() }.controlSize(.small)
                }
                ForEach(connector.fields, id: \.key) { field in
                    LabeledContent(field.label) {
                        TextField(field.placeholder, text: Binding(
                            get: { values[field.key] ?? "" },
                            set: { values[field.key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                Text("The connection runs through Power Query (M). Tables found are loaded into the model.")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Spacer()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!values.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } || isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyState(systemImage: "cylinder.split.1x2", title: "Get Data",
                       message: "Choose a connector on the left, then connect to load tables into the model.")
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = selected?.id == "folder"
        panel.canChooseFiles = selected?.id != "folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        values["path"] = url.path
        if selected?.id == "folder" { values["path"] = url.path }
    }

    private func connect() {
        guard let connector = selected else { return }
        isWorking = true
        let args = values
        let kind = connector.id
        Task { @MainActor in
            defer { isWorking = false }
            let script = Self.mScript(kind: kind, args: args)
            guard let script else {
                store.status = StatusMessage(kind: .error, text: "Fill in the connection details.")
                return
            }
            let name = Self.queryName(for: connector, args: args, in: store)
            var definition = QueryDefinition(name: name, mScript: script)
            definition.description = connector.name
            do {
                let queryEngine = QueryEngine(queries: [definition], environment: QueryEnvironment())
                var table = try await queryEngine.evaluate(name)
                table.name = name
                store.installTables([table], sourceQueries: [name: script], actionName: "Get Data")
                store.mutate("Get Data", invalidates: .model) { d in
                    if !d.queries.contains(where: { $0.name == name }) { d.queries.append(definition) }
                }
                store.status = StatusMessage(kind: .success, text: "Loaded \(name).")
                dismiss()
            } catch {
                store.status = StatusMessage(kind: .error, text: "Couldn't connect: \(MError.wrap(error).description)")
            }
        }
    }

    // MARK: M script generation

    /// The M query for a connector + connection details. Only sources the M engine supports.
    static func mScript(kind: String, args: [String: String]) -> String? {
        func v(_ key: String) -> String { (args[key] ?? "").trimmingCharacters(in: .whitespaces) }
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        switch kind {
        case "csv":
            let path = v("path"); guard !path.isEmpty else { return nil }
            return "let\n    Source = Csv.Document(File.Contents(\(quote(path))), [Delimiter = \",\", Encoding = 65001]),\n    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),\n    Typed = Table.TransformColumnTypes(Promoted, {}, \"en-US\")\nin\n    Typed"
        case "excel":
            let path = v("path"); guard !path.isEmpty else { return nil }
            return "let\n    Source = Excel.Workbook(File.Contents(\(quote(path))), null, true),\n    First = Source{0}[Data],\n    Promoted = Table.PromoteHeaders(First, [PromoteAllScalars = true])\nin\n    Promoted"
        case "json":
            let path = v("path"); guard !path.isEmpty else { return nil }
            return "let\n    Source = Json.Document(File.Contents(\(quote(path))))\nin\n    Source"
        case "xml":
            let path = v("path"); guard !path.isEmpty else { return nil }
            return "let\n    Source = Xml.Tables(File.Contents(\(quote(path))))\nin\n    Source"
        case "parquet":
            let path = v("path"); guard !path.isEmpty else { return nil }
            return "let\n    Source = Parquet.Document(File.Contents(\(quote(path))))\nin\n    Source"
        case "sql":
            let server = v("server"); guard !server.isEmpty else { return nil }
            let database = v("database")
            let source = database.isEmpty ? "Sql.Databases(\(quote(server)))" : "Sql.Database(\(quote(server)), \(quote(database)))"
            return "let\n    Source = \(source)\nin\n    Source"
        case "odbc":
            let dsn = v("dsn"); guard !dsn.isEmpty else { return nil }
            return "let\n    Source = Odbc.DataSource(\(quote(dsn)), [HierarchicalNavigation = true])\nin\n    Source"
        case "web":
            let url = v("url"); guard !url.isEmpty else { return nil }
            return "let\n    Source = Web.Contents(\(quote(url))),\n    Data = Csv.Document(Source, [Delimiter = \",\", Encoding = 65001]),\n    Promoted = Table.PromoteHeaders(Data, [PromoteAllScalars = true])\nin\n    Promoted"
        case "folder":
            let path = v("path"); guard !path.isEmpty else { return nil }
            return "let\n    Source = Folder.Files(\(quote(path)))\nin\n    Source"
        case "sharepoint":
            let url = v("url"); guard !url.isEmpty else { return nil }
            return "let\n    Source = SharePoint.Files(\(quote(url)), [ApiVersion = 15])\nin\n    Source"
        default: return nil
        }
    }

    static func queryName(for connector: DataConnector, args: [String: String], in store: DocumentStore) -> String {
        func v(_ key: String) -> String { (args[key] ?? "").trimmingCharacters(in: .whitespaces) }
        var base: String
        switch connector.id {
        case "csv", "excel", "json", "xml", "parquet": base = (v("path") as NSString).lastPathComponent.replacingOccurrences(of: ".", with: " ")
        case "sql": base = v("database").isEmpty ? v("server") : v("database")
        case "web": base = URL(string: v("url"))?.host ?? "Web"
        case "folder": base = (v("path") as NSString).lastPathComponent
        case "sharepoint": base = URL(string: v("url"))?.host ?? "SharePoint"
        default: base = connector.name
        }
        if base.isEmpty { base = connector.name }
        var name = base, k = 2
        while store.doc.queries.contains(where: { $0.name == name }) { name = "\(base) \(k)"; k += 1 }
        return name
    }
}

// MARK: - Enter data (paste a table)

struct EnterDataSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Table"
    @State private var text = "Column 1\tColumn 2\n\t"

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Enter Data").font(Design.Typeface.headline)
            Text("Type or paste a table. The first row is the header; columns are separated by tabs or commas.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(Design.Typeface.mono)
                .border(Design.Palette.fill)
                .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Load") { load() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 560)
        .frame(minHeight: 360)
    }

    private func load() {
        var rows: [[String]] = []
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let cells: [String]
            if line.contains("\t") { cells = line.components(separatedBy: "\t") }
            else if line.contains(",") { cells = line.components(separatedBy: ",") }
            else { cells = [line] }
            rows.append(cells.map { $0.trimmingCharacters(in: .whitespaces) })
        }
        guard let header = rows.first else { return }
        let width = header.count
        let valueRows = rows.dropFirst().map { r -> [Value] in
            (0..<width).map { i -> Value in
                let cell = i < r.count ? r[i] : ""
                if cell.isEmpty { return .null }
                if let d = Double(cell.replacingOccurrences(of: ",", with: ".")) { return .double(d) }
                return .string(cell)
            }
        }
        var tableName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if tableName.isEmpty { tableName = "Table" }
        var unique = tableName, k = 2
        while store.doc.data[unique] != nil || store.doc.queries.contains(where: { $0.name == unique }) { unique = "\(tableName) \(k)"; k += 1 }
        let table = DataTable(name: unique, columnNames: header, rows: valueRows)
        let script = "let\n    Source = #table(\n        \(jsonArray(header)),\n        \(valueRows.prefix(3).map { jsonArray($0.map { $0.asString }) }.joined(separator: ", "))\n    )\nin\n    Source"
        store.installTables([table], sourceQueries: [unique: script], actionName: "Enter Data")
        store.mutate("Enter Data", invalidates: .model) { d in
            if !d.queries.contains(where: { $0.name == unique }) {
                d.queries.append(QueryDefinition(name: unique, mScript: script))
            }
        }
        store.status = StatusMessage(kind: .success, text: "Loaded \(unique) (\(valueRows.count) rows).")
        dismiss()
    }

    private func jsonArray(_ items: [String]) -> String {
        "{" + items.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ", ") + "}"
    }
}

// MARK: - Recent sources

struct RecentSourcesSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent sources").font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if store.doc.dataSources.isEmpty && store.doc.queries.isEmpty {
                EmptyState(systemImage: "clock", title: "No recent sources",
                           message: "Sources you connect to are listed here.")
            } else {
                List {
                    if !store.doc.dataSources.isEmpty {
                        Section("Connections") {
                            ForEach(store.doc.dataSources) { record in
                                HStack(spacing: Design.Space.xs) {
                                    Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
                                    Text(record.displayName).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(record.kind).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    if !store.doc.queries.isEmpty {
                        Section("Queries") {
                            ForEach(store.doc.queries) { q in
                                HStack(spacing: Design.Space.xs) {
                                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                                    Text(q.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button("Refresh") { store.refreshData(only: [q.name]); dismiss() }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 380)
    }
}
