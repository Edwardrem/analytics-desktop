import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// Which applied steps have a settings dialog (the gear), and the dialog that edits each.
@MainActor
enum StepSettings {
    static func dialog(forStep index: Int, in s: QueryEditorSession) -> EditorDialog? {
        guard let step = s.steps[safe: index] else { return nil }
        if SourcePlanner.request(fromSource: step.expression) != nil { return .sourceSettings(step: index) }
        guard let (t, previous) = Transform.recognize(step.expression), hasDialog(t) else { return nil }
        return .editStep(StepEdit(index: index, previous: previous, transform: t))
    }

    /// Steps Power Query opens a dialog for (others are edited in the formula bar).
    static func hasDialog(_ t: Transform) -> Bool {
        switch t {
        case .keepTopRows, .keepBottomRows, .keepRangeOfRows, .removeTopRows, .removeBottomRows, .removeAlternateRows,
             .filterRows, .replaceValues, .replaceErrors, .splitByDelimiter, .splitByLength, .splitByPositions, .mergeColumns,
             .addPrefix, .addSuffix, .groupBy, .pivotColumn, .addCustomColumn, .addConditionalColumn, .addIndexColumn,
             .invokeCustomFunction, .mergeQueries, .appendQueries, .expandRecordColumn, .expandTableColumn, .aggregateTableColumn,
             .runPythonScript, .runRScript, .extractListValues, .renameColumns:
            return true
        case .changeType(_, let culture): return culture != nil
        case .extractText(_, let kind, _):
            if case .length = kind { return false }
            return true
        case .number(_, let op, _):
            switch op {
            case .add, .subtract, .multiply, .divide, .integerDivide, .modulo, .percentage, .percentOf, .power, .round: return true
            default: return false
            }
        default: return false
        }
    }
}

extension QueryEditorSession {
    /// A dialog's OK: apply the transform as a new step, or replace the step being edited.
    func commit(_ transform: Transform, editing: StepEdit?) {
        if let e = editing { replaceStep(at: e.index, with: transform, previous: e.previous) } else { apply(transform) }
    }

    /// The table a dialog works on: the current preview, or for a step being edited, the step it reads.
    func inputPreview(for edit: StepEdit?) async -> QueryPreview? {
        guard let edit else { return preview }
        guard let q = selectedQuery else { return nil }
        let index = steps.firstIndex { MSyntax.identifier($0.name) == edit.previous || $0.name == edit.previous } ?? (edit.index - 1)
        return try? await makeEngine().evaluatePreview(q.name, upToStep: index, rowLimit: Self.previewRows)
    }
}

/// Shows the dialog the session asked for.
struct EditorDialogHost: View {
    @ObservedObject var session: QueryEditorSession
    let dialog: EditorDialog

    var body: some View {
        content.environmentObject(session.store)
    }

    @ViewBuilder private var content: some View {
        switch dialog {
        case .rows(let kind): RowsDialog(session: session, kind: kind, edit: nil)
        case .editStep(let e): StepDialogLoader(session: session, edit: e)
        case .advancedEditor: AdvancedEditorDialog(session: session)
        case .sourceSettings(let step): SourceSettingsDialog(session: session, step: step)
        case .renameColumn(let c): NameDialog(title: "Rename Column", initial: c) { n in
            if n != c, !n.isEmpty { session.apply(.renameColumns([(c, n)])) }
            return nil
        }
        case .renameQuery(let id): NameDialog(title: "Rename Query", initial: session.query(id)?.name ?? "") { session.renameQuery(id, to: $0) }
        case .renameGroup(let g): NameDialog(title: "Rename Group", initial: g) { session.renameGroup(g, to: $0); return nil }
        case .newGroup(let moving): NameDialog(title: "New Group", initial: "New Group") { name in
            session.newGroup(name)
            if !moving.isEmpty { session.moveQueries(moving, toGroup: name) }
            return nil
        }
        case .createFunction(let id): NameDialog(title: "Create Function", subtitle: "The function's parameters are the parameters the query uses.", initial: "fx\(session.query(id)?.name ?? "")") {
            session.createFunction(from: id, named: $0)
        }
        case .goToColumn: ColumnListDialog(session: session, choose: false)
        case .chooseColumns: ColumnListDialog(session: session, choose: true)
        case .queryProperties(let id): QueryPropertiesDialog(session: session, id: id)
        case .nativeQuery(let text): NativeQueryDialog(text: text)
        case .diagnostics(let events, let title): DiagnosticsDialog(session: session, events: events, title: title)
        case .script(let python): ScriptDialog(session: session, python: python, edit: nil)
        case .manageParameters(let select): ManageParametersDialog(session: session, selected: select)
        case .dependencies: QueryDependenciesView(session: session)
        case .columnProfile: ColumnProfilePanel(session: session).frame(width: 640, height: 260)
        case .newSource: GetDataDialog(store: session.store, insideEditor: true)
        case .connect(let id, let location):
            GetDataDialog(store: session.store, connector: DataConnector.connector(id), location: location, insideEditor: true)
        case .enterData: EnterDataSheet(editor: session)
        case .recentSources: RecentSourcesSheet { connector, location in
            session.dialog = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session.dialog = .connect(connectorID: connector.id, location: location) }
        }
        case .dataSourceSettings: DataSourceSettingsSheet()
        case .changeTypeStep(let change): ChangeTypeStepDialog(session: session, change: change)
        default: TransformDialogRouter(session: session, dialog: dialog)
        }
    }
}

/// Loads the input of an edited step, then shows that step's dialog filled from it.
private struct StepDialogLoader: View {
    @ObservedObject var session: QueryEditorSession
    let edit: StepEdit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch edit.transform {
        case .keepTopRows: RowsDialog(session: session, kind: .keepTop, edit: edit)
        case .keepBottomRows: RowsDialog(session: session, kind: .keepBottom, edit: edit)
        case .keepRangeOfRows: RowsDialog(session: session, kind: .keepRange, edit: edit)
        case .removeTopRows: RowsDialog(session: session, kind: .removeTop, edit: edit)
        case .removeBottomRows: RowsDialog(session: session, kind: .removeBottom, edit: edit)
        case .removeAlternateRows: RowsDialog(session: session, kind: .removeAlternate, edit: edit)
        case .runPythonScript: ScriptDialog(session: session, python: true, edit: edit)
        case .runRScript: ScriptDialog(session: session, python: false, edit: edit)
        default: TransformDialogRouter(session: session, dialog: .editStep(edit))
        }
    }
}

/// "Change Column Type": the selected step already converts the column.
private struct ChangeTypeStepDialog: View {
    @ObservedObject var session: QueryEditorSession
    let change: TypeStepChange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let step = session.steps[safe: change.stepIndex]?.name ?? "Changed Type"
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Change Column Type").font(Design.Typeface.headline)
            Text("The step “\(step)” already changes the type of \(change.changes.filter { c in change.existing.contains { $0.column == c.column } }.map(\.column).joined(separator: ", ")). Replace that conversion, or add a new step that changes the type again?")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add New Step") { session.resolve(change, replace: false); dismiss() }
                Button("Replace Current") { session.resolve(change, replace: true); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 460)
    }
}

// MARK: - Chrome

/// The frame every editor dialog shares: title, optional explanation, content, Cancel and OK.
struct DialogChrome<Content: View>: View {
    let title: String
    var subtitle = ""
    var okTitle = "OK"
    var canCommit = true
    var width: CGFloat = 480
    var problem: String?
    let commit: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text(title).font(Design.Typeface.headline)
            if !subtitle.isEmpty {
                Text(subtitle).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
            if let problem {
                Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(okTitle) { commit() }.keyboardShortcut(.defaultAction).disabled(!canCommit)
            }
        }
        .padding(Design.Space.l)
        .frame(width: width)
    }
}

/// A labelled whole-number field.
struct CountField: View {
    let label: String
    @Binding var value: Int
    var body: some View {
        PropertyRow(label) {
            TextField(label, value: $value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 120)
        }
    }
}

// MARK: - Small dialogs

struct RowsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let kind: EditorDialog.RowsKind
    let edit: StepEdit?
    @Environment(\.dismiss) private var dismiss
    @State private var a = 1
    @State private var b = 1
    @State private var c = 1

    private var title: String {
        switch kind {
        case .keepTop: return "Keep Top Rows"
        case .keepBottom: return "Keep Bottom Rows"
        case .keepRange: return "Keep Range of Rows"
        case .removeTop: return "Remove Top Rows"
        case .removeBottom: return "Remove Bottom Rows"
        case .removeAlternate: return "Remove Alternate Rows"
        }
    }
    private var valid: Bool { a >= (kind == .keepRange || kind == .removeAlternate ? 1 : 0) && b >= 0 && c >= 0 }

    var body: some View {
        DialogChrome(title: title, subtitle: subtitle, canCommit: valid, commit: commit) {
            switch kind {
            case .keepTop, .keepBottom, .removeTop, .removeBottom: CountField(label: "Number of rows", value: $a)
            case .keepRange:
                CountField(label: "First row", value: $a)
                CountField(label: "Number of rows", value: $b)
            case .removeAlternate:
                CountField(label: "First row to remove", value: $a)
                CountField(label: "Rows to remove", value: $b)
                CountField(label: "Rows to keep", value: $c)
            }
        }
        .onAppear(perform: load)
    }

    private var subtitle: String {
        switch kind {
        case .keepTop: return "Specify how many rows to keep from the top."
        case .keepBottom: return "Specify how many rows to keep from the bottom."
        case .keepRange: return "Specify the range of rows to keep; the first row is 1."
        case .removeTop: return "Specify how many rows to remove from the top."
        case .removeBottom: return "Specify how many rows to remove from the bottom."
        case .removeAlternate: return "Specify the pattern of rows to remove and keep; the first row is 1."
        }
    }

    private func load() {
        switch edit?.transform {
        case .keepTopRows(let n)?, .keepBottomRows(let n)?, .removeTopRows(let n)?, .removeBottomRows(let n)?: a = n
        case .keepRangeOfRows(let f, let n)?: a = f; b = n
        case .removeAlternateRows(let f, let r, let k)?: a = f; b = r; c = k
        default: break
        }
    }

    private func commit() {
        let t: Transform
        switch kind {
        case .keepTop: t = .keepTopRows(a)
        case .keepBottom: t = .keepBottomRows(a)
        case .keepRange: t = .keepRangeOfRows(first: a, count: b)
        case .removeTop: t = .removeTopRows(a)
        case .removeBottom: t = .removeBottomRows(a)
        case .removeAlternate: t = .removeAlternateRows(firstToRemove: a, numberToRemove: b, numberToKeep: c)
        }
        session.commit(t, editing: edit)
        dismiss()
    }
}

/// A single-name dialog; `commit` returns a problem to show instead of closing.
struct NameDialog: View {
    let title: String
    var subtitle = ""
    let initial: String
    let commit: (String) -> String?
    @State private var name = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: title, subtitle: subtitle, canCommit: !name.trimmingCharacters(in: .whitespaces).isEmpty, width: 380, problem: problem, commit: done) {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(done)
        }
        .onAppear { name = initial }
    }
    private func done() {
        problem = commit(name.trimmingCharacters(in: .whitespacesAndNewlines))
        if problem == nil { dismiss() }
    }
}

/// Go to Column (select one) and Choose Columns (keep the checked ones).
private struct ColumnListDialog: View {
    @ObservedObject var session: QueryEditorSession
    let choose: Bool
    @State private var search = ""
    @State private var checked: Set<String> = []
    @State private var picked: String?
    @Environment(\.dismiss) private var dismiss

    private var shown: [String] {
        let n = search.trimmingCharacters(in: .whitespaces).lowercased()
        return n.isEmpty ? session.columnNames : session.columnNames.filter { $0.lowercased().contains(n) }
    }

    var body: some View {
        DialogChrome(title: choose ? "Choose Columns" : "Go to Column", canCommit: choose ? !checked.isEmpty : picked != nil, width: 380, commit: done) {
            TextField("Search Columns", text: $search).textFieldStyle(.roundedBorder)
            if choose {
                Toggle("(Select All Columns)", isOn: Binding(get: { checked.count == session.columnNames.count },
                                                            set: { checked = $0 ? Set(session.columnNames) : [] }))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.self) { name in
                        if choose {
                            Toggle(name, isOn: Binding(get: { checked.contains(name) }, set: { if $0 { checked.insert(name) } else { checked.remove(name) } }))
                        } else {
                            Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                                .background(picked == name ? Design.Palette.accent.opacity(0.16) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { picked = name }
                                .onTapGesture(count: 2) { picked = name; done() }
                        }
                    }
                }
            }
            .frame(height: 260)
        }
        .onAppear { checked = Set(session.columnNames) }
    }

    private func done() {
        if choose {
            session.apply(.chooseColumns(session.columnNames.filter(checked.contains)))
        } else if let picked {
            session.selectedColumns = [picked]
        }
        dismiss()
    }
}

private struct QueryPropertiesDialog: View {
    @ObservedObject var session: QueryEditorSession
    let id: UUID
    @State private var name = ""
    @State private var description = ""
    @State private var load = true
    @State private var refresh = true
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: "Query Properties", canCommit: !name.isEmpty, width: 440, problem: problem, commit: done) {
            PropertyRow("Name") { TextField("Name", text: $name).textFieldStyle(.roundedBorder) }
            PropertyRow("Description") { TextField("Description", text: $description, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder) }
            if session.query(id)?.kind == .table {
                Toggle("Enable load to report", isOn: $load)
                Toggle("Include in report refresh", isOn: $refresh).disabled(!load).padding(.leading, Design.Space.l)
            }
        }
        .onAppear {
            guard let q = session.query(id) else { return }
            name = q.name; description = q.description; load = q.loadEnabled; refresh = q.includeInRefresh
        }
    }

    private func done() {
        guard let q = session.query(id) else { dismiss(); return }
        if let p = session.renameQuery(id, to: name) { problem = p; return }
        if description != q.description { session.setDescription(id, description) }
        if load != q.loadEnabled { session.setLoadEnabled(id, load) }
        if load, refresh != (session.query(id)?.includeInRefresh ?? refresh) { session.setIncludeInRefresh(id, refresh) }
        dismiss()
    }
}

private struct NativeQueryDialog: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Native Query").font(Design.Typeface.headline)
            Text("The statement the data source runs for this step.").font(Design.Typeface.caption).foregroundStyle(.secondary)
            ScrollView { Text(text).font(Design.Typeface.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Design.Space.s) }
                .frame(height: 220)
                .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: Design.Radius.control))
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.l).frame(width: 560)
    }
}
