import SwiftUI
import FacetCore
import FacetDesign

/// Right-hand panel of the DAX query view: the model tree, the function catalogue and run history.
struct DAXSidePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case model = "Model", functions = "Functions", history = "History"
        var id: String { rawValue }
    }
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    @AppStorage("dax.sidePanelTab") private var tab: Tab = .model
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            if tab != .history {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                    TextField(tab == .model ? "Search fields" : "Search functions", text: $search)
                        .textFieldStyle(.plain)
                        .font(Design.Typeface.body)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, Design.Space.m)
                .padding(.bottom, Design.Space.s)
            }
            Hairline()
            switch tab {
            case .model: DAXModelTree(session: session, search: search)
            case .functions: DAXFunctionList(session: session, search: search)
            case .history: DAXHistoryList(session: session)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Design.Palette.surface)
    }
}

// MARK: - Model

private struct DAXModelTree: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    let search: String
    @State private var collapsed: Set<String> = []
    @State private var seeded = false

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }

    var body: some View {
        let tables = store.model.tables.filter { t in
            matches(t.name) || t.columns.contains { matches($0.name) } || t.measures.contains { matches($0.name) }
        }
        if tables.isEmpty {
            EmptyState(systemImage: "magnifyingglass", title: "No matching fields")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tables) { table in
                        let open = !search.isEmpty || !collapsed.contains(table.name)
                        row(.table(table.name), icon: "tablecells", name: table.name, indent: 0, disclosure: open) {
                            if collapsed.contains(table.name) { collapsed.remove(table.name) } else { collapsed.insert(table.name) }
                        }
                        if open {
                            let tableHit = matches(table.name)
                            ForEach(table.measures.filter { tableHit || matches($0.name) }) { m in
                                row(.measure(table: table.name, name: m.name), icon: "sum", name: m.name, indent: 1)
                            }
                            ForEach(table.columns.filter { tableHit || matches($0.name) }) { c in
                                row(.column(table: table.name, name: c.name), icon: DAXResultFormat.glyph(for: c.dataType), name: c.name, indent: 1)
                            }
                        }
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
            .onAppear {
                // Start with only the first table open when the model is large.
                guard !seeded else { return }
                seeded = true
                if store.model.tables.count > 4 { collapsed = Set(store.model.tables.dropFirst().map(\.name)) }
            }
        }
    }

    private func reference(_ item: DAXModelItem) -> String {
        switch item {
        case .table(let t): return DAXQueryBuilder.tableRef(t)
        case .column(let t, let c): return DAXQueryBuilder.columnRef(t, c)
        case .measure(_, let m): return DAXQueryBuilder.bracket(m)
        }
    }

    private func row(_ item: DAXModelItem, icon: String, name: String, indent: Int, disclosure: Bool? = nil,
                     toggle: (() -> Void)? = nil) -> some View {
        let selected = session.selectedItem == item
        return HStack(spacing: Design.Space.xs) {
            if let disclosure {
                Button { toggle?() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(disclosure ? 90 : 0)).foregroundStyle(.tertiary)
                        .frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosure ? "Collapse \(name)" : "Expand \(name)")
            } else {
                Spacer().frame(width: 14)
            }
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(name).font(indent == 0 ? Design.Typeface.bodyStrong : Design.Typeface.body).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Design.Space.s + CGFloat(indent) * Design.Space.m)
        .padding(.trailing, Design.Space.s)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.14) : .clear).padding(.horizontal, Design.Space.xs))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.selectedItem = item; session.insert(reference(item)) }
        .onTapGesture { session.selectedItem = item }
        .help("Double-click to insert \(reference(item))")
        .contextMenu { menu(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func menu(_ item: DAXModelItem) -> some View {
        Button("Insert \(reference(item))") { session.insert(reference(item)) }
        Divider()
        switch item {
        case .table(let t):
            Button("Show top 100 rows") { DAXQuickQuery.topRows(t, store) }
            Button("Show column statistics") { DAXQuickQuery.tableStatistics(t, store) }
            Button("Show data preview") { DAXQuickQuery.preview(t, store) }
        case .column(let t, let c):
            Button("Show distinct values with counts") { DAXQuickQuery.distinctValues(t, c, store) }
            Button("Show column statistics") { DAXQuickQuery.columnStatistics(t, c, store) }
        case .measure(_, let m):
            Button("Evaluate") { DAXQuickQuery.evaluate(m, store) }
            Button("Define and evaluate") { DAXQuickQuery.define(m, store) }
            Button("Define with references and evaluate") { DAXQuickQuery.defineWithReferences(m, store) }
            Divider()
            Button("Define all measures in this model") { DAXQuickQuery.defineAll(store) }
        }
    }
}

// MARK: - Functions

private struct DAXFunctionList: View {
    @ObservedObject var session: DAXQuerySession
    let search: String

    var body: some View {
        let all = LanguageSupport.dax.functions
        let shown = search.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search)
        }
        if all.isEmpty {
            EmptyState(systemImage: "function", title: "No function catalogue",
                       message: "Function help isn't available in this session. You can still type any DAX function in the editor.")
        } else if shown.isEmpty {
            EmptyState(systemImage: "magnifyingglass", title: "No matching functions")
        } else {
            let groups = Dictionary(grouping: shown, by: { $0.category.isEmpty ? "Other" : $0.category })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(groups.keys.sorted(), id: \.self) { category in
                        SectionLabel(category)
                            .padding(.horizontal, Design.Space.m)
                            .padding(.top, Design.Space.m)
                            .padding(.bottom, Design.Space.xs)
                        ForEach((groups[category] ?? []).sorted { $0.name < $1.name }) { f in
                            DAXFunctionRow(function: f) { session.insert(f.name + "(") }
                        }
                    }
                }
                .padding(.bottom, Design.Space.s)
            }
        }
    }
}

private struct DAXFunctionRow: View {
    let function: FunctionDoc
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text(function.name).font(Design.Typeface.mono)
                if !function.signature.isEmpty {
                    Text(function.signature).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !function.summary.isEmpty {
                    Text(function.summary).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            .background(hovering ? Design.Palette.fill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Insert \(function.name)(")
    }
}

// MARK: - History

private struct DAXHistoryList: View {
    @ObservedObject var session: DAXQuerySession

    var body: some View {
        if session.history.isEmpty {
            EmptyState(systemImage: "clock", title: "No runs yet", message: "Queries you run in this session appear here.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.history) { entry in
                        DAXHistoryRow(entry: entry) { session.addTab(text: entry.text) }
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
        }
    }
}

private struct DAXHistoryRow: View {
    let entry: DAXHistoryEntry
    let action: () -> Void
    @State private var hovering = false

    private var detail: String {
        let ms = entry.milliseconds
        let duration = ms < 10_000 ? "\(Int(ms.rounded()).formatted()) ms" : String(format: "%.1f s", ms / 1000)
        let outcome = entry.rows.map { "\($0.formatted()) \($0 == 1 ? "row" : "rows")" } ?? "Failed"
        return "\(entry.date.formatted(date: .omitted, time: .standard)) · \(duration) · \(outcome)"
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text(DAXText.firstLine(entry.text)).font(Design.Typeface.mono).lineLimit(1)
                Text(detail).font(Design.Typeface.caption).monospacedDigit()
                    .foregroundStyle(entry.rows == nil ? Design.Palette.negative : Design.Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            .background(hovering ? Design.Palette.fill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this query in a new tab")
    }
}

// MARK: - Update model sheet

/// Confirmation for writing query definitions back to the model, with a before/after diff per object.
struct DAXUpdateModelSheet: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    let changes: [DAXModelChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(changes.count == 1 ? "Update the model?" : "Update the model with \(changes.count) changes?")
                    .font(Design.Typeface.headline)
                Text("The definitions in this query replace what is in the model. You can undo this.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            .padding(Design.Space.l)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: Design.Space.s) {
                            HStack(spacing: Design.Space.s) {
                                Text(change.objectName).font(Design.Typeface.bodyStrong).lineLimit(1)
                                Chip(change.isAddition ? "New" : "Overwrite",
                                     tint: change.isAddition ? Design.Palette.positive : .primary)
                            }
                            DAXDiffView(lines: DAXLineDiff.diff(old: change.before, new: change.after))
                        }
                    }
                }
                .padding(Design.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { store.dismissSheet() }.keyboardShortcut(.cancelAction)
                Button("Update model") {
                    session.apply(changes)
                    store.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(Design.Space.l)
        }
        .frame(width: 560)
        .frame(minHeight: 260, maxHeight: 560)
    }
}

/// Removed lines above added lines, each marked in the margin; unchanged lines stay quiet.
struct DAXDiffView: View {
    let lines: [DAXLineDiff.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " "))
                        .foregroundStyle(.secondary).frame(width: 10)
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(line.kind == .same ? .secondary : .primary)
                        .strikethrough(line.kind == .removed, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Design.Typeface.mono)
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, 1.5)
                .background(line.kind == .added ? Design.Palette.positive.opacity(0.12)
                            : (line.kind == .removed ? Design.Palette.negative.opacity(0.1) : Color.clear))
                .accessibilityLabel("\(line.kind == .added ? "Added" : (line.kind == .removed ? "Removed" : "Unchanged")): \(line.text)")
            }
        }
        .padding(.vertical, Design.Space.xs)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
    }
}
