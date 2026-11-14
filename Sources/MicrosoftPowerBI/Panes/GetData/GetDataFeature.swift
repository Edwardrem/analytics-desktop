import SwiftUI
import FacetCore
import FacetQuery
import FacetDesign

/// Getting data: the connector catalog and Navigator, Enter Data, Recent Sources, Data source settings, and the
/// commands that open them.
@MainActor
enum GetDataFeature {
    static func register() {
        AppCommands.register { commands }
    }

    static var commands: [AppCommand] {
        [
            AppCommand(id: "data.get", title: "Get Data…", menu: .data, symbol: "cylinder.split.1x2",
                       shortcut: .init("g", modifiers: [.command, .shift]), separatorBefore: true) { store in
                store.present { GetDataDialog(store: store) }
            },
            AppCommand(id: "data.enter", title: "Enter Data", menu: .data, symbol: "square.and.pencil") { store in
                store.present { EnterDataSheet() }
            },
            AppCommand(id: "data.recent", title: "Recent Sources…", menu: .data, symbol: "clock") { store in
                store.present { RecentSourcesSheet() }
            },
            AppCommand(id: "data.sourceSettings", title: "Data Source Settings…", menu: .data, symbol: "lock.shield") { store in
                store.present { DataSourceSettingsSheet() }
            },
            AppCommand(id: "data.editParameters", title: "Edit Parameters…", menu: .data, symbol: "slider.horizontal.3",
                       isEnabled: { $0.doc.queries.contains { $0.kind == .parameter } }) { store in
                store.present { EditParametersSheet() }
            },
            AppCommand(id: "data.transform", title: "Transform Data", menu: .data, symbol: "wand.and.rays") { store in
                // Addressed to this document: its window opens the editor only for its own store.
                NotificationCenter.default.post(name: .facetOpenQueryEditor, object: store)
            },
        ]
    }
}

// MARK: - Enter data

struct EnterDataSheet: View {
    @EnvironmentObject var store: DocumentStore
    /// Set when opened from the Power Query Editor: the table becomes a pending query there instead of loading.
    var editor: QueryEditorSession?
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Table"
    @State private var text = "Column1\tColumn2\n"

    private var parsed: EnteredTable? { EnteredTable.parse(text) }
    private var typed: DataTable? {
        guard var table = parsed?.textTable else { return nil }
        table.detectAndConvertTextTypes()
        return table
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Enter Data").font(Design.Typeface.headline)
            Text("Type or paste a table. The first line is the header; cells are separated by tabs (as copied from a spreadsheet) or by commas.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(Design.Typeface.mono)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            if let typed, typed.columnCount > 0 {
                QueryGrid(table: typed)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairline))
            }
            HStack {
                Text("Name").font(Design.Typeface.caption).foregroundStyle(.secondary)
                TextField("Table", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editor == nil ? "Load" : "OK") { load() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 640)
        .frame(minHeight: 480)
    }

    private func load() {
        guard let parsed, var table = typed else { return }
        var taken = Set(store.doc.queries.map(\.name)).union(store.doc.data.tables.keys).union(store.doc.model.tables.map(\.name))
        if let editor { taken.formUnion(editor.queryNames) }
        let unique = SourcePlanner.uniqueName(name.isEmpty ? "Table" : name, taken: taken)
        table.name = unique
        var definition = QueryDefinition(name: unique, mScript: parsed.script)
        definition.description = "Enter Data"
        if let editor {
            editor.addQuery(definition, name: "Enter Data")
            dismiss()
            return
        }
        store.mutate("Enter Data", invalidates: .model) { d in
            d.queries.append(definition)
            d.data[unique] = table
            var model = ModelTable(name: unique, columns: table.columns.map(DocumentStore.modelColumn))
            model.sourceQuery = unique
            d.model.tables.append(model)
        }
        store.status = StatusMessage(kind: .success, text: "Loaded \(unique) (\(table.rowCount) row\(table.rowCount == 1 ? "" : "s")).")
        dismiss()
    }
}

// MARK: - Recent sources

struct RecentSourcesSheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var sources = QuerySecurity.shared.recentSources
    /// Where Connect goes; by default Get Data opens over the document window with the source filled in.
    var onConnect: ((DataConnector, String) -> Void)?

    private static let dates: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Sources").font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Design.Space.m)
            Hairline()
            if sources.isEmpty {
                EmptyState(systemImage: "clock", title: "No recent sources", message: "Sources you connect to with Get Data are listed here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sources) { source in
                            HStack(spacing: Design.Space.s) {
                                Image(systemName: DataConnector.connector(for: source.kind)?.symbol ?? "cylinder")
                                    .foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.displayName).lineLimit(1).truncationMode(.middle)
                                    Text("\(DataConnector.connector(for: source.kind)?.name ?? "") · \(Self.dates.string(from: source.lastUsed))")
                                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                                }
                                .help(source.location)
                                Spacer(minLength: 0)
                                Button("Connect") { connect(source) }.controlSize(.small)
                                IconButton("xmark", help: "Remove from this list") {
                                    QuerySecurity.shared.removeRecent(source)
                                    sources = QuerySecurity.shared.recentSources
                                }
                            }
                            .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
                            Hairline()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 380)
    }

    private func connect(_ source: RecentSource) {
        guard let connector = DataConnector.connector(for: source.kind) else { return }
        if let onConnect { onConnect(connector, source.location); return }
        let target = store
        dismiss()
        // Present after this sheet is gone, so the new one is not swallowed by the dismissal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            target.present { GetDataDialog(store: target, connector: connector, location: source.location) }
        }
    }
}
