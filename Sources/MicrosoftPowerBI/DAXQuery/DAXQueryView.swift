import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// The DAX query workspace: query tabs, an editor over a results grid, and a collapsible side panel.
struct DAXQueryView: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    @AppStorage("dax.fontSize") private var fontSize = 13.0
    @AppStorage("dax.sidePanelVisible") private var sidePanelVisible = true
    @AppStorage("dax.editorFraction") private var editorFraction = 0.42

    var body: some View {
        if store.model.tables.isEmpty {
            VStack(spacing: Design.Space.m) {
                EmptyState(systemImage: "function", title: "Nothing to query yet",
                           message: "Add data to the model, then explore it here with DAX queries.")
                    .frame(maxHeight: 150)
                Button("Get Data…") { AppCommands.run("data.get", store) }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Design.Palette.surface)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    DAXTabBar(session: session)
                    Hairline()
                    DAXToolbar(session: session, fontSize: $fontSize, sidePanelVisible: $sidePanelVisible)
                    Hairline()
                    if let tab = session.activeTab {
                        split(tab)
                    }
                }
                if sidePanelVisible {
                    Hairline(vertical: true)
                    DAXSidePanel(session: session).frame(width: 260)
                }
            }
            .background(Design.Palette.elevated)
            .onAppear {
                if session.tabs.isEmpty { session.addTab(name: "Query 1") }
                else if session.activeTabID == nil { session.activeTabID = session.tabs.first?.id }
            }
        }
    }

    private func split(_ tab: DAXQueryTab) -> some View {
        GeometryReader { geo in
            let total = max(1, geo.size.height)
            let editorHeight = min(max(90, total * editorFraction), max(90, total - 120))
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    CodeEditor(text: Binding(get: { session.tabs.first { $0.id == tab.id }?.text ?? "" },
                                             set: { session.setText($0, for: tab.id) }),
                               language: .dax, model: store.model, issues: session.activeRun.issues,
                               fontSize: fontSize, showsLineNumbers: true,
                               onCommit: { session.run() })
                        .id(tab.id)
                        .background(DAXEditorAnchor(session: session))
                    DAXPendingChangesBar(session: session, changes: session.pendingChanges)
                }
                .frame(height: editorHeight)
                DAXSplitHandle(current: editorHeight) { height in
                    editorFraction = min(0.85, max(0.12, height / total))
                }
                DAXResultsPane(session: session, run: session.activeRun)
            }
        }
    }
}

/// An invisible view behind the editor; the session finds the editor's text view from it.
private struct DAXEditorAnchor: NSViewRepresentable {
    let session: DAXQuerySession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        session.editorAnchor = v
        return v
    }
    func updateNSView(_ view: NSView, context: Context) { session.editorAnchor = view }
}

/// The draggable hairline between editor and results.
private struct DAXSplitHandle: View {
    /// Current editor height; `onDrag` receives the height the drag asks for.
    let current: CGFloat
    var onDrag: (CGFloat) -> Void
    @State private var hovering = false
    @State private var startHeight: CGFloat?
    var body: some View {
        Rectangle().fill(hovering ? Design.Palette.hairlineStrong : Design.Palette.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startHeight ?? current
                    startHeight = start
                    onDrag(start + drag.translation.height)
                }
                .onEnded { _ in startHeight = nil })
            .padding(.vertical, -3)
            .accessibilityLabel("Resize editor")
    }
}

// MARK: - Tabs

private struct DAXTabBar: View {
    @ObservedObject var session: DAXQuerySession
    @State private var renaming: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Design.Space.xxs) {
                ForEach(session.tabs) { tab in
                    DAXTabChip(session: session, tab: tab, isActive: session.activeTab?.id == tab.id,
                               canClose: session.tabs.count > 1, renaming: $renaming)
                }
                IconButton("plus", help: "New query tab") { session.addTab() }
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
        }
    }
}

private struct DAXTabChip: View {
    @ObservedObject var session: DAXQuerySession
    let tab: DAXQueryTab
    let isActive: Bool
    let canClose: Bool
    @Binding var renaming: UUID?
    @State private var draft = ""
    @State private var hovering = false
    @State private var targeted = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            if renaming == tab.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Design.Typeface.body)
                    .frame(width: 120)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: focused) { _, now in if !now, renaming == tab.id { commit() } }
                    .onAppear { draft = tab.name; focused = true }
            } else {
                Text(tab.name).font(Design.Typeface.body).lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            if canClose, renaming != tab.id {
                Button { session.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || isActive ? 1 : 0)
                .help("Close tab")
                .accessibilityLabel("Close \(tab.name)")
            }
        }
        .padding(.leading, Design.Space.m)
        .padding(.trailing, canClose ? Design.Space.s : Design.Space.m)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(targeted ? Color.accentColor.opacity(0.14) : (isActive ? Design.Palette.fillStrong : (hovering ? Design.Palette.fill : .clear))))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { session.activeTabID = tab.id; renaming = tab.id }
        .onTapGesture { session.activeTabID = tab.id }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let id = UUID(uuidString: first) else { return false }
            session.move(id, onto: tab.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Rename") { session.activeTabID = tab.id; renaming = tab.id }
            Button("Duplicate") { session.duplicate(tab.id) }
            Divider()
            Button("Close") { session.close(tab.id) }.disabled(!canClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Query tab \(tab.name)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func commit() {
        session.rename(tab.id, to: draft)
        renaming = nil
    }
}

// MARK: - Toolbar

private struct DAXToolbar: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    @Binding var fontSize: Double
    @Binding var sidePanelVisible: Bool
    @State private var explaining = false
    @State private var asking = false

    var body: some View {
        let run = session.activeRun
        let changes = session.pendingChanges
        HStack(spacing: Design.Space.xs) {
            if run.isRunning {
                Button { session.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                    .help("Stop waiting for this run")
            } else {
                Button { session.run() } label: { Label("Run", systemImage: "play.fill") }
                    .help("Run the query, or the selected text (⌘↩)")
            }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, Design.Space.xs)
            IconButton("text.alignleft", help: "Format query (⌥⇧F)") { session.formatQuery() }
            Button { session.toggleComment() } label: {
                Image(systemName: "text.bubble").font(.system(size: 13)).frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("/", modifiers: .command)
            .help("Comment or uncomment lines (⌘/)")
            .accessibilityLabel("Comment or uncomment lines")
            Menu {
                ForEach(DAXQueryBuilder.infoQueries, id: \.title) { item in
                    Button(item.title) { session.place(item.query, name: item.title) }
                }
            } label: { Label("Model info", systemImage: "info.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Insert a query that lists objects in the model")

            Spacer(minLength: Design.Space.s)

            if !changes.isEmpty {
                Button("Update model with changes (\(changes.count))") { AppCommands.run("dax.updateModel", store) }
                    .help("Review and write the measures defined in this query back to the model")
            }
            if DAXAssistantHook.explain != nil {
                Button { explaining = true } label: { Label("Explain", systemImage: "sparkles") }
                    .help("Explain the selected query, or the whole query, in plain language")
                    .popover(isPresented: $explaining, arrowEdge: .bottom) { DAXExplainPopover(session: session) }
            }
            if DAXAssistantHook.write != nil {
                Button { asking = true } label: { Label("Ask assistant", systemImage: "text.bubble") }
                    .help("Describe a result and the assistant writes the query in a new tab")
                    .popover(isPresented: $asking, arrowEdge: .bottom) { DAXAskPopover(session: session, isPresented: $asking) }
            }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, Design.Space.xs)
            IconButton("textformat.size.smaller", help: "Smaller text") { fontSize = max(10, fontSize - 1) }
            IconButton("textformat.size.larger", help: "Larger text") { fontSize = min(24, fontSize + 1) }
            IconButton("sidebar.right", help: sidePanelVisible ? "Hide side panel" : "Show side panel", isOn: sidePanelVisible) {
                withAnimation(Design.Motion.quick) { sidePanelVisible.toggle() }
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
    }
}

// MARK: - Pending model changes

/// Quiet strip under the editor listing definitions that differ from the model.
private struct DAXPendingChangesBar: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    let changes: [DAXModelChange]

    var body: some View {
        if !changes.isEmpty {
            VStack(spacing: 0) {
                Hairline()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Design.Space.l) {
                        ForEach(changes) { change in
                            HStack(spacing: Design.Space.xs) {
                                Button("Line \(change.definition.line)") { session.reveal(change.definition) }
                                    .foregroundStyle(.secondary)
                                    .help("Go to this definition")
                                Button("\(change.title) \(change.objectName)") {
                                    store.present { DAXUpdateModelSheet(session: session, changes: [change]) }
                                }
                                .help("Review this change, then write it to the model")
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .font(Design.Typeface.caption)
                    .padding(.horizontal, Design.Space.m)
                    .padding(.vertical, Design.Space.xs + 1)
                }
            }
        }
    }
}

// MARK: - Results

private struct DAXResultsPane: View {
    @ObservedObject var session: DAXQuerySession
    let run: DAXRunState

    var body: some View {
        VStack(spacing: 0) {
            if let error = run.error { errorBanner(error) }
            if let result = run.results[safe: run.selectedResult] {
                DAXResultsGrid(model: result, onCopyAll: { session.copyAll() }, onExport: { session.exportResults() })
                    .opacity(run.isRunning ? 0.45 : 1)
                    .allowsHitTesting(!run.isRunning)
                    .animation(Design.Motion.quick, value: run.isRunning)
                Hairline()
                DAXStatusLine(session: session, run: run, result: result)
            } else if run.isRunning {
                VStack(spacing: Design.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if run.error != nil {
                Spacer(minLength: 0)
            } else if run.hasRun {
                EmptyState(systemImage: "tablecells", title: "No result tables",
                           message: "The query ran without an EVALUATE statement that returns rows.")
            } else {
                EmptyState(systemImage: "play", title: "Run a query to see results",
                           message: "Press ⌘↩ to run the whole query, or select part of it to run just that.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        let located = run.issues.contains { $0.range != nil }
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Design.Palette.negative)
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(message).font(Design.Typeface.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(run.issues.filter { $0.message != message }.prefix(4)) { issue in
                        Text(issue.message).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Design.Space.s)
                DAXFixButton(session: session, run: run)
                if located {
                    Button("Show in editor") { session.revealFirstIssue() }.buttonStyle(.link).font(Design.Typeface.caption)
                }
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            .background(Design.Palette.negative.opacity(0.06))
            .contentShape(Rectangle())
            .onTapGesture { if located { session.revealFirstIssue() } }
            Hairline()
        }
    }
}

private struct DAXStatusLine: View {
    @ObservedObject var session: DAXQuerySession
    let run: DAXRunState
    @ObservedObject var result: DAXResultModel

    private var summary: String {
        var parts: [String] = []
        let total = result.totalRows
        if result.isFiltered { parts.append("\(result.rowCount.formatted()) of \(total.formatted()) rows") }
        else { parts.append("\(total.formatted()) \(total == 1 ? "row" : "rows")") }
        parts.append("\(result.columnCount.formatted()) \(result.columnCount == 1 ? "column" : "columns")")
        if let ms = run.elapsedMilliseconds {
            parts.append(ms < 10_000 ? "\(Int(ms.rounded()).formatted()) ms" : String(format: "%.1f s", ms / 1000))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Design.Space.m) {
            if run.results.count > 1 {
                HStack(spacing: Design.Space.xxs) {
                    IconButton("chevron.left", help: "Previous result") { session.selectResult(run.selectedResult - 1) }
                        .disabled(run.selectedResult == 0)
                    Text("Result \(run.selectedResult + 1) of \(run.results.count)").monospacedDigit()
                    IconButton("chevron.right", help: "Next result") { session.selectResult(run.selectedResult + 1) }
                        .disabled(run.selectedResult >= run.results.count - 1)
                }
            }
            if run.isRunning || result.isWorking { ProgressView().controlSize(.mini) }
            Text(run.isRunning ? "Running…" : summary).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            if result.isFiltered {
                Button("Clear filters") { result.clearFilters() }.buttonStyle(.link)
            }
            Spacer(minLength: Design.Space.s)
            Button("Copy all") { session.copyAll() }.buttonStyle(.link)
                .help("Copy every row shown, with headers, as tab-separated text")
            Button("Export…") { session.exportResults() }.buttonStyle(.link)
                .help("Save the rows shown as a CSV file")
        }
        .font(Design.Typeface.caption)
        .padding(.horizontal, Design.Space.m)
        .frame(height: 28)
    }
}

// MARK: - Assistant

private struct DAXExplainPopover: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    @State private var answer: String?
    @State private var failure: Error?

    var body: some View {
        ScrollView {
            Group {
                if let answer { Text(answer).textSelection(.enabled) }
                else if let failure { AssistantNotice(error: failure) }
                else { HStack(spacing: Design.Space.s) { ProgressView().controlSize(.small); Text("Reading the query…").foregroundStyle(.secondary) } }
            }
            .font(Design.Typeface.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.l)
        }
        .frame(width: 380)
        .frame(minHeight: 80, maxHeight: 360)
        .task {
            guard let explain = DAXAssistantHook.explain else { return }
            do { answer = try await explain(session.assistantQueryText, store) }
            catch { failure = error }
        }
    }
}

private struct DAXAskPopover: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    @Binding var isPresented: Bool
    @State private var prompt = ""
    @State private var working = false
    @State private var failure: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Describe the query you need").font(Design.Typeface.bodyStrong)
            TextField("Top 10 products by sales this year", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let failure { AssistantNotice(error: failure) }
            else if !AssistantTasks.isConfigured { AssistantNotice(message: AssistantTasks.setupMessage, showsSettings: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Write query", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 340)
    }

    private func submit() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working, !request.isEmpty, let write = DAXAssistantHook.write else { return }
        working = true; failure = nil
        Task {
            do {
                let dax = try await write(request, store)
                session.addTab(name: DAXAssistant.tabName(for: request), text: dax)
                isPresented = false
            } catch {
                failure = error
            }
            working = false
        }
    }
}
