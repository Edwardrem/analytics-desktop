import SwiftUI
import FacetCore
import FacetDesign

/// The formula bar: a DAX editor with cancel/commit, live validation and a function reference.
///
/// For measures, calculated columns and calculated tables the text is `Name = expression`
/// (`hasNamePrefix`); only the expression part is sent to the engine for checking.
/// Esc cancels; ⌘↩ commits; ↩ commits while the formula is a single line (⇧↩ adds a line).
struct FormulaBar: View {
    @EnvironmentObject private var store: DocumentStore
    @Binding var text: String
    var kind: ExpressionKind = .measure
    var homeTable: String?
    var hasNamePrefix = true
    /// A message to show under the bar ahead of validation issues (e.g. a commit failure).
    var message: String?
    var onCommit: () -> Void
    var onCancel: () -> Void

    @State private var issues: [ExpressionIssue] = []
    @State private var extraHeight: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var showingFunctions = false

    private static let lineHeight: CGFloat = 17
    private var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var isSingleLine: Bool { lineCount == 1 }
    private var editorHeight: CGFloat {
        CGFloat(min(8, max(1, lineCount))) * Self.lineHeight + 16 + extraHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Design.Space.xs) {
                IconButton("xmark", help: "Cancel (Esc)", action: onCancel)
                IconButton("checkmark", help: isSingleLine ? "Commit (Return)" : "Commit (⌘Return)", action: onCommit)
                CodeEditor(text: $text, language: .dax, model: store.model, issues: issues, onCommit: onCommit, onCancel: onCancel)
                    .frame(height: editorHeight)
                    .background(ReturnKeyCatcher(isActive: isSingleLine, action: onCommit))
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.elevated))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .strokeBorder(issues.contains { !$0.isWarning } ? Design.Palette.negative.opacity(0.5) : Design.Palette.hairlineStrong))
                IconButton("function", help: "Function reference", isOn: showingFunctions) { showingFunctions.toggle() }
                    .popover(isPresented: $showingFunctions, arrowEdge: .bottom) {
                        FunctionReference { name in
                            text += (text.hasSuffix(" ") || text.isEmpty ? "" : " ") + name + "("
                            showingFunctions = false
                        }
                    }
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.top, Design.Space.s)

            if let line = message ?? issues.first?.message {
                let warning = message == nil && (issues.first?.isWarning ?? false)
                Label(line, systemImage: warning ? "exclamationmark.triangle" : "exclamationmark.circle")
                    .font(Design.Typeface.caption)
                    .foregroundStyle(warning ? Design.Palette.caution : Design.Palette.negative)
                    .lineLimit(2)
                    .padding(.leading, 28 * 2 + Design.Space.s + Design.Space.xs * 2)
                    .padding(.top, Design.Space.xs)
                    .accessibilityLabel("Formula problem: \(line)")
            }

            // Drag handle: makes the editor taller.
            Capsule().fill(Design.Palette.hairlineStrong)
                .frame(width: 36, height: 3)
                .frame(maxWidth: .infinity)
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if dragStart == nil { dragStart = extraHeight }
                        extraHeight = max(0, min(420, (dragStart ?? 0) + g.translation.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .help("Drag to resize the formula bar")
                .accessibilityHidden(true)
        }
        .task(id: text) {
            // Debounced live validation.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await validate()
        }
    }

    private func validate() async {
        var expression = text
        var offset = 0
        if hasNamePrefix {
            guard let eq = text.firstIndex(of: "=") else { issues = []; return }
            let after = text.index(after: eq)
            expression = String(text[after...])
            offset = text[..<after].utf16.count
        }
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { issues = []; return }
        let kind = kind, home = homeTable
        let found = await store.withEngine { $0.check(expression, kind: kind, homeTable: home) }
        if Task.isCancelled { return }
        issues = found.map { issue in
            var i = issue
            if let r = issue.range { i.range = (r.lowerBound + offset)..<(r.upperBound + offset) }
            return i
        }
    }
}

/// Lets Return commit a single-line formula. `CodeEditor` itself only commits on ⌘↩, so this watches
/// key-downs while the editor it sits behind has focus.
private struct ReturnKeyCatcher: NSViewRepresentable {
    var isActive: Bool
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.anchor = v
        context.coordinator.install()
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.action = action
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        weak var anchor: NSView?
        var isActive = false
        var action: () -> Void = {}
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive, event.keyCode == 36 || event.keyCode == 76,
                      event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
                      let anchor = self.anchor, let window = anchor.window, event.window === window,
                      let tv = window.firstResponder as? NSTextView, !tv.hasMarkedText() else { return event }
                // Only when focus is in the editor this catcher sits behind.
                let editor = (tv.enclosingScrollView ?? tv).convert((tv.enclosingScrollView ?? tv).bounds, to: nil)
                guard editor.intersects(anchor.convert(anchor.bounds, to: nil)) else { return event }
                // A completion list is open: Return picks the suggestion.
                if NSApp.windows.contains(where: { $0.isVisible && String(describing: type(of: $0)).contains("Completion") }) { return event }
                self.action()
                return nil
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { remove() }
    }
}

/// Searchable list of DAX functions from the language catalog.
struct FunctionReference: View {
    var onInsert: (String) -> Void
    @State private var search = ""

    private var functions: [FunctionDoc] {
        let all = LanguageSupport.dax.functions
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search functions", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(Design.Space.s)
            Hairline()
            if LanguageSupport.dax.functions.isEmpty {
                EmptyState(systemImage: "function", title: "No function catalog", message: "The function reference appears once the calculation engine is loaded.")
            } else if functions.isEmpty {
                EmptyState(systemImage: "magnifyingglass", title: "No matching functions")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(functions) { f in
                            Button { onInsert(f.name) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(f.name).font(Design.Typeface.mono)
                                        Spacer()
                                        Text(f.category).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                                    }
                                    if !f.signature.isEmpty { Text(f.signature).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    if !f.summary.isEmpty { Text(f.summary).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs + 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Insert \(f.name)")
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }
}

/// New/edit measure, calculated column or calculated table as a sheet (used outside Table view).
struct FormulaSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State var edit: FormulaEdit
    @State private var format = ""
    @State private var problem: String?
    @State private var committing = false
    @State private var loaded = false

    private var title: String { "\(edit.original == nil ? "New" : "Edit") \(edit.kind == .column ? "calculated column" : (edit.kind == .table ? "calculated table" : "measure"))" }

    var body: some View {
        ModelingSheet(title: title, subtitle: subtitle, width: 640, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                FormulaBar(text: $edit.text, kind: edit.kind.expressionKind, homeTable: edit.kind == .table ? nil : edit.table,
                           message: problem, onCommit: commit, onCancel: { store.dismissSheet() })
                    .padding(.horizontal, -Design.Space.s)
                if edit.kind != .table {
                    HStack(spacing: Design.Space.l) {
                        if edit.kind == .measure {
                            LabeledContent("Home table") {
                                Picker("Home table", selection: $edit.table) {
                                    ForEach(store.model.tables) { Text($0.name).tag($0.name) }
                                }.labelsHidden().fixedSize()
                            }
                        }
                        LabeledContent("Format") { FormatControls(format: format, apply: { format = $0 }) }
                        Spacer()
                    }
                    .font(Design.Typeface.caption)
                    .controlSize(.small)
                }
            }
            .padding(Design.Space.l)
        } footer: {
            ModelingSheetButtons(confirmTitle: edit.original == nil ? "Create" : "Save", confirmDisabled: committing, confirm: commit)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let original = edit.original {
                if edit.kind == .measure { format = store.model.table(edit.table)?.measure(original)?.formatString ?? "" }
                if edit.kind == .column { format = store.model.table(edit.table)?.column(original)?.formatString ?? "" }
            }
        }
    }

    private var subtitle: String {
        switch edit.kind {
        case .measure: return "Evaluated at query time in each visual's filter context. Write it as Name = expression."
        case .column: return "Evaluated row by row in \(edit.table) when data refreshes."
        case .table: return "A table defined by a DAX expression, evaluated when data refreshes."
        }
    }

    private func commit() {
        guard !committing else { return }
        committing = true
        var e = edit
        // Editing in a sheet may move the measure to another home table.
        let originalTable = e.original.flatMap { store.model.measure($0)?.table.name }
        Task {
            if e.kind == .measure, let original = e.original, let from = originalTable, !ModelDAX.same(from, e.table) {
                ModelOps.moveMeasure(store, name: original, from: from, to: e.table)
            }
            e.table = store.model.table(e.table)?.name ?? e.table
            let result = await ModelOps.commitFormula(store, e, formatString: e.kind == .table ? nil : format)
            committing = false
            if let result { problem = result } else { store.dismissSheet() }
        }
    }
}
