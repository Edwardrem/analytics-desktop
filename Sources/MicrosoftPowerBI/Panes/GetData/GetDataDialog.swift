import SwiftUI
import AppKit
import FacetCore
import FacetQuery
import FacetDesign

/// Get Data: the connector catalog, the connection form, native query approval and the Navigator.
struct GetDataDialog: View {
    @StateObject private var session: GetDataSession
    @Environment(\.dismiss) private var dismiss
    private let connectNow: Bool

    /// `insideEditor`: opened from the Power Query Editor (New Source), where the navigator only adds queries.
    /// `connectNow`: connect to `location` as the dialog opens and go straight to the navigator (a data source file);
    /// if that fails, the connection form shows why and lets the details be corrected.
    init(store: DocumentStore, connector: DataConnector? = nil, location: String = "", insideEditor: Bool = false, connectNow: Bool = false) {
        let s = GetDataSession(store: store)
        s.insideEditor = insideEditor
        if let connector { s.choose(connector, location: location) }
        _session = StateObject(wrappedValue: s)
        self.connectNow = connectNow && connector != nil
    }

    var body: some View {
        Group {
            switch session.stage {
            case .catalog: ConnectorCatalogView(session: session, cancel: { dismiss() })
            case .form: ConnectionForm(session: session, cancel: { dismiss() })
            case .approval: NativeQueryApproval(session: session, cancel: { dismiss() })
            case .navigator: NavigatorView(session: session, cancel: { dismiss() })
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 520, idealHeight: 580)
        .onChange(of: session.isDone) { _, done in if done { dismiss() } }
        .onAppear { if session.isDone { dismiss() } }
        .task { if connectNow, session.stage == .form { await session.connect() } }
    }
}

// MARK: Catalog

private struct ConnectorCatalogView: View {
    @ObservedObject var session: GetDataSession
    let cancel: () -> Void
    @State private var category: DataConnector.Category?
    @State private var search = ""
    @State private var selected: String?

    private var shown: [DataConnector] { DataConnector.matching(search, in: category) }
    private var selectedConnector: DataConnector? { selected.flatMap(DataConnector.connector) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    categoryButton("All", nil)
                    ForEach(DataConnector.Category.allCases) { categoryButton($0.rawValue, $0) }
                    Spacer(minLength: 0)
                }
                .padding(Design.Space.m)
                .frame(width: 180)
                Hairline(vertical: true)
                VStack(spacing: 0) {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(Design.Space.m)
                    Hairline()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { row($0) }
                        }
                        .padding(.vertical, Design.Space.xs)
                    }
                    if shown.isEmpty {
                        EmptyState(systemImage: "magnifyingglass", title: "No connector matches", message: "Try another name or category.")
                    }
                }
            }
            Hairline()
            HStack {
                Text("\(DataConnector.all.filter(\.isAvailable).count) of \(DataConnector.all.count) connectors are available in \(AppIdentity.name).")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Connect") { if let c = selectedConnector { session.choose(c) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(selectedConnector?.isAvailable ?? false))
            }
            .padding(Design.Space.m)
        }
    }

    private func categoryButton(_ title: String, _ value: DataConnector.Category?) -> some View {
        Button { category = value } label: {
            Text(title).font(category == value ? Design.Typeface.bodyStrong : Design.Typeface.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.xs)
                .background(category == value ? Design.Palette.fillStrong : Color.clear,
                            in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ c: DataConnector) -> some View {
        let isSelected = selected == c.id
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: c.symbol).frame(width: 20).foregroundStyle(c.isAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(Design.Typeface.body)
                if let reason = c.unavailableReason {
                    Text("Unavailable. \(reason)").font(Design.Typeface.caption)
                }
            }
            Spacer(minLength: 0)
            if category == nil { Text(c.category.rawValue).font(Design.Typeface.caption).foregroundStyle(.tertiary) }
        }
        .opacity(c.isAvailable ? 1 : 0.45)
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Design.Palette.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if c.isAvailable { session.choose(c) } }
        .onTapGesture { selected = c.isAvailable ? c.id : nil }
        .help(c.unavailableReason ?? "Connect to \(c.name)")
        .accessibilityLabel(c.isAvailable ? c.name : "\(c.name), unavailable")
    }
}

// MARK: Connection form

private struct ConnectionForm: View {
    @ObservedObject var session: GetDataSession
    let cancel: () -> Void
    @State private var showAdvanced = false
    @State private var allowScripts = QuerySecurity.shared.allowScripts

    private var kind: SourceKind { session.request.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: session.connector?.symbol ?? "cylinder").font(.system(size: 20)).foregroundStyle(Color.accentColor)
                Text(session.connector?.name ?? "Get Data").font(Design.Typeface.headline)
            }
            fields
            if let error = session.error {
                Text(error).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { session.back() }
                Spacer()
                if session.isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK") { Task { await session.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isWorking || SourcePlanner.validationMessage(session.request) != nil)
            }
        }
        .padding(Design.Space.l)
    }

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .csv, .excel, .json, .xml, .folder, .sqlite:
            HStack {
                TextField(kind == .folder ? "Folder path" : "File path", text: $session.request.location).textFieldStyle(.roundedBorder)
                Button("Browse…") { browse() }
            }
            if kind == .sqlite { databaseOptions }
        case .sqlServer:
            SQLServerFields(session: session)
            databaseOptions
        case .web, .odata:
            TextField(kind == .web ? "https://example.com/data.csv" : "https://services.odata.org/V4/TripPinService", text: $session.request.location)
                .textFieldStyle(.roundedBorder)
            Text(kind == .web
                 ? "CSV, JSON, XML, Excel workbooks and the tables of HTML pages are recognised from the content. The address is read anonymously."
                 : "The feed is read as JSON (OData v4, or older services that answer JSON), anonymously.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .python, .r:
            Text("Script").font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
            TextEditor(text: $session.request.location)
                .font(Design.Typeface.mono)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            Toggle("Allow scripts to run on this Mac", isOn: $allowScripts)
                .onChange(of: allowScripts) { _, on in QuerySecurity.shared.allowScripts = on }
            Text(kind == .python
                 ? "The script runs with your permissions using the Python on this Mac (pandas is required). Every data frame it leaves behind becomes a table."
                 : "The script runs with your permissions using the R on this Mac. Every data frame it leaves behind becomes a table.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .blank:
            EmptyView()
        }
    }

    @ViewBuilder
    private var databaseOptions: some View {
        Picker("Data connectivity mode", selection: $session.request.directQuery) {
            Text("Import").tag(false)
            Text("DirectQuery").tag(true)
        }
        .pickerStyle(.radioGroup)
        Text(session.request.directQuery
             ? "The tables are marked DirectQuery: steps that fold are run by the database."
             : "A copy of the data is loaded into the model and updated on refresh.")
            .font(Design.Typeface.caption).foregroundStyle(.secondary)
        DisclosureGroup("Advanced options", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("SQL statement (optional)").font(Design.Typeface.caption).foregroundStyle(.secondary)
                TextEditor(text: $session.request.nativeQuery)
                    .font(Design.Typeface.mono)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            }
            .padding(.top, Design.Space.xs)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind != .folder
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.request.location = url.path
    }
}

// MARK: Native query approval

private struct NativeQueryApproval: View {
    @ObservedObject var session: GetDataSession
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Label("Native Database Query", systemImage: "exclamationmark.shield").font(Design.Typeface.headline)
            Text("You are about to run a native database query. Native queries can make changes to the database. Run it only if you trust the statement below.")
                .font(Design.Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(session.request.location).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            ScrollView {
                Text(session.pendingNativeQuery).font(Design.Typeface.mono).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Design.Space.s)
            }
            .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: Design.Radius.control))
            Text(session.request.kind == .sqlServer
                 ? "The statement runs with the permissions of your sign-in. \(AppIdentity.name) remembers this approval until you clear it in Data source settings."
                 : "\(AppIdentity.name) opens SQLite databases read-only, and remembers this approval until you clear it in Data source settings.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { session.back() }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Run") { Task { await session.approveNativeQuery() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.l)
    }
}

// MARK: Navigator

private struct NavigatorView: View {
    @ObservedObject var session: GetDataSession
    let cancel: () -> Void
    @State private var search = ""

    private var shownItems: [NavigatorItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? session.items : session.items.filter { $0.name.lowercased().contains(needle) }
    }
    private var isText: Bool { session.request.kind == .csv || (session.request.kind == .web && session.request.webContent == .csv) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !session.items.isEmpty {
                    itemList.frame(width: 240)
                    Hairline(vertical: true)
                }
                VStack(spacing: 0) {
                    if isText { textOptions; Hairline() }
                    previewArea
                }
            }
            Hairline()
            footer
        }
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(Design.Space.s)
            HStack {
                Text(session.request.directQuery ? "DirectQuery" : "\(session.checked.count) selected")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { session.checked = Set(session.items.map(\.id)) }.buttonStyle(.link).font(Design.Typeface.caption)
                Button("None") { session.checked = [] }.buttonStyle(.link).font(Design.Typeface.caption)
            }
            .padding(.horizontal, Design.Space.s).padding(.bottom, Design.Space.xs)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shownItems) { item in
                        HStack(spacing: Design.Space.xs) {
                            Toggle("", isOn: Binding(get: { session.checked.contains(item.id) }, set: { _ in session.toggle(item.id) }))
                                .labelsHidden().toggleStyle(.checkbox)
                                .help("Include \(item.name)")
                            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 18).help(item.kind)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.xs)
                        .background(session.focused == item.id ? Design.Palette.accent.opacity(0.16) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await session.focus(item.id) } }
                    }
                }
            }
        }
    }

    private var textOptions: some View {
        HStack(spacing: Design.Space.m) {
            Picker("File origin", selection: $session.request.encoding) {
                ForEach(SourcePlanner.encodings, id: \.codePage) { Text($0.name).tag($0.codePage) }
            }
            .frame(maxWidth: 280)
            Picker("Delimiter", selection: $session.request.delimiter) {
                ForEach(SourcePlanner.delimiters, id: \.value) { Text($0.name).tag($0.value) }
                if !SourcePlanner.delimiters.contains(where: { $0.value == session.request.delimiter }) {
                    Text("Custom (\(session.request.delimiter))").tag(session.request.delimiter)
                }
            }
            .frame(maxWidth: 200)
            Toggle("Use first row as headers", isOn: $session.promoteHeaders)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(Design.Space.s)
        .onChange(of: session.request.encoding) { _, _ in session.optionsChanged() }
        .onChange(of: session.request.delimiter) { _, _ in session.optionsChanged() }
        .onChange(of: session.promoteHeaders) { _, _ in session.optionsChanged() }
    }

    @ViewBuilder
    private var previewArea: some View {
        if let error = session.previewError {
            EmptyState(systemImage: "exclamationmark.triangle", title: "The preview could not be loaded", message: error)
        } else if let preview = session.preview {
            VStack(spacing: 0) {
                HStack {
                    Text(session.items.first { $0.id == session.focused }?.name ?? SourcePlanner.queryName(session.request, item: nil))
                        .font(Design.Typeface.bodyStrong).lineLimit(1)
                    Spacer()
                    Text(preview.isTruncated ? "Preview of the first \(preview.table.rowCount) rows" : "\(preview.table.rowCount) rows")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
                Hairline()
                QueryGrid(table: preview.table, cellErrors: preview.cellErrors, structuredCells: preview.structuredCells)
            }
        } else {
            ProgressView("Reading the source…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { session.back() }
            if let error = session.error {
                Text(error).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            if session.isWorking { ProgressView().controlSize(.small) }
            if session.request.kind == .folder {
                if session.insideEditor {
                    Button("Combine") { Task { await session.finish(.transform, combined: true) } }
                        .disabled(session.combine == nil || !session.canFinish)
                        .help(session.combine == nil ? "The folder has no CSV, text, JSON or Excel files to combine" : "Append the \(session.combine?.extension ?? "") files into one table")
                } else {
                    Menu("Combine") {
                        Button("Combine & Load") { Task { await session.finish(.load, combined: true) } }
                        Button("Combine & Transform Data") { Task { await session.finish(.transform, combined: true) } }
                    }
                    .fixedSize()
                    .disabled(session.combine == nil || !session.canFinish)
                    .help(session.combine == nil ? "The folder has no CSV, text, JSON or Excel files to combine" : "Append the \(session.combine?.extension ?? "") files into one table")
                }
            }
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            if session.insideEditor {
                Button("OK") { Task { await session.finish(.transform) } }
                    .keyboardShortcut(.defaultAction).disabled(!session.canFinish)
                    .help("Add the selected objects as queries in the editor")
            } else {
                Button("Transform Data") { Task { await session.finish(.transform) } }.disabled(!session.canFinish)
                Button("Load") { Task { await session.finish(.load) } }
                    .keyboardShortcut(.defaultAction).disabled(!session.canFinish)
            }
        }
        .padding(Design.Space.m)
    }
}
