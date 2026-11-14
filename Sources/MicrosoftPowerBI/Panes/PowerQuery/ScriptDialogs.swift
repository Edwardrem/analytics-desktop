import SwiftUI
import AppKit
import FacetCore
import FacetDesign
import FacetQuery

// MARK: - Advanced Editor

struct AdvancedEditorDialog: View {
    @ObservedObject var session: QueryEditorSession
    @State private var text = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var diagnostics: [MDiagnostic] { MScript.validate(text, knownNames: session.queryNames) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack {
                Text(session.selectedQuery?.name ?? "Advanced Editor").font(Design.Typeface.headline)
                Spacer()
                Button("Format") { text = MScript.format(text) }.controlSize(.small).help("Lay the query out one step per line")
            }
            CodeEditor(text: $text, language: LanguageSupport.m, fontSize: 12, showsLineNumbers: true, onCommit: done, onCancel: { dismiss() })
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            let d = diagnostics
            if let first = d.first {
                Label("\(first.message) (line \(first.line), column \(first.column))", systemImage: first.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(Design.Typeface.caption).foregroundStyle(first.severity == .error ? Design.Palette.negative : Design.Palette.caution)
                    .help(d.map { "\($0.message) (line \($0.line))" }.joined(separator: "\n"))
            } else {
                Label("No syntax errors have been detected.", systemImage: "checkmark.circle").font(Design.Typeface.caption).foregroundStyle(Design.Palette.positive)
            }
            if let problem { Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative) }
            HStack {
                Text("⌘↩ to finish").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 760, height: 520)
        .onAppear { text = session.selectedQuery?.mScript ?? "" }
    }

    private func done() {
        problem = session.setScript(text)
        if problem == nil { dismiss() }
    }
}

// MARK: - Run R / Python script

struct ScriptDialog: View {
    @ObservedObject var session: QueryEditorSession
    let python: Bool
    let edit: StepEdit?
    @State private var script = ""
    @State private var allow = QuerySecurity.shared.allowScripts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogChrome(title: python ? "Run Python Script" : "Run R Script",
                     subtitle: "'dataset' holds the input of this step; every data frame the script leaves becomes a result, and the step keeps 'dataset'.",
                     canCommit: !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, width: 620, commit: done) {
            CodeEditor(text: $script, language: python ? LanguageSupport.python : LanguageSupport.m, fontSize: 12)
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
            Toggle("Allow Python and R scripts to run on this Mac", isOn: $allow)
                .onChange(of: allow) { _, on in QuerySecurity.shared.allowScripts = on }
            Text("The script runs with your permissions, using the \(python ? "Python (with pandas)" : "R") installed on this Mac.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            switch edit?.transform {
            case .runPythonScript(let s)?, .runRScript(let s)?: script = s
            default: script = python ? "# 'dataset' holds the input data for this script\n" : "# 'dataset' holds the input data for this script\n"
            }
        }
    }
    private func done() {
        session.commit(python ? .runPythonScript(script) : .runRScript(script), editing: edit)
        dismiss()
    }
}

// MARK: - Source settings (the gear of a Source step)

struct SourceSettingsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let step: Int
    @State private var request = SourceRequest(kind: .csv)
    @Environment(\.dismiss) private var dismiss

    private var problem: String? { SourcePlanner.validationMessage(request) }

    var body: some View {
        DialogChrome(title: DataConnector.connector(for: request.kind)?.name ?? "Source", subtitle: "Change where this query reads its data.",
                     canCommit: problem == nil, width: 560, problem: problem, commit: done) {
            switch request.kind {
            case .web, .odata, .oneDriveFile, .sharePointFolder, .sharePointList, .dataverse, .dynamics365, .azureBlobs, .azureDataLake, .lakehouse:
                PropertyRow(request.kind == .dataverse ? "Environment" : request.kind == .azureBlobs ? "Account" : "URL") {
                    TextField("https://", text: $request.location).textFieldStyle(.roundedBorder)
                }
            case .kusto, .semanticModel:
                PropertyRow(request.kind == .kusto ? "Cluster" : "Workspace") { TextField("", text: $request.location).textFieldStyle(.roundedBorder) }
                PropertyRow(request.kind == .kusto ? "Database" : "Semantic model") { TextField("", text: $request.database).textFieldStyle(.roundedBorder) }
            case .python, .r:
                CodeEditor(text: $request.location, language: request.kind == .python ? LanguageSupport.python : LanguageSupport.m, fontSize: 12).frame(height: 180)
            case .blank:
                EmptyView()
            default:
                PropertyRow(request.kind == .folder ? "Folder path" : "File path") {
                    HStack {
                        TextField("Path", text: $request.location).textFieldStyle(.roundedBorder)
                        Button("Browse…", action: browse)
                    }
                }
            }
            if request.kind == .csv || (request.kind == .web && request.webContent == .csv) {
                DelimiterPicker(label: "Delimiter", value: $request.delimiter)
                PropertyRow("File origin") {
                    Picker("File origin", selection: $request.encoding) { ForEach(SourcePlanner.encodings, id: \.codePage) { Text($0.name).tag($0.codePage) } }.labelsHidden()
                }
            }
        }
        .onAppear {
            if let s = session.steps[safe: step], let r = SourcePlanner.request(fromSource: s.expression) { request = r }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = request.kind == .folder
        panel.canChooseFiles = request.kind != .folder
        panel.directoryURL = URL(fileURLWithPath: request.location).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { request.location = url.path }
    }

    private func done() {
        guard let s = session.steps[safe: step] else { dismiss(); return }
        let expression = SourcePlanner.sourceExpression(request)
        session.changeScript("Edit Source") { MScript.replacingStepExpression(s.name, with: expression, in: $0) }
        dismiss()
    }
}

// MARK: - Diagnostics

struct DiagnosticsDialog: View {
    @ObservedObject var session: QueryEditorSession
    let events: [QueryDiagnosticEvent]
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(title).font(Design.Typeface.headline)
            Text("What the query engine evaluated, step by step: wall-clock and exclusive time, rows produced and whether the step folded.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                EmptyState(systemImage: "stethoscope", title: "Nothing was recorded", message: "Evaluate a preview while diagnostics are recording.")
            } else {
                Table(Array(events.enumerated()).map { DiagnosticRow(index: $0.offset, event: $0.element) }) {
                    TableColumn("Query") { Text($0.event.query) }
                    TableColumn("Step") { Text($0.event.step) }
                    TableColumn("Duration (ms)") { Text(String(format: "%.1f", $0.event.seconds * 1000)).monospacedDigit() }
                    TableColumn("Exclusive (ms)") { Text(String(format: "%.1f", $0.event.exclusiveSeconds * 1000)).monospacedDigit() }
                    TableColumn("Rows") { Text($0.event.rowCount.map(String.init) ?? "") }
                    TableColumn("Folding") { Text(DiagnosticsDialog.folding($0.event.folding)) }
                    TableColumn("Native query / error") { Text($0.event.error ?? $0.event.nativeQuery ?? "").lineLimit(1).help($0.event.error ?? $0.event.nativeQuery ?? "") }
                }
            }
            HStack {
                Button("Add as Query") { addAsQuery() }.disabled(events.isEmpty)
                    .help("Add the recorded events as a query in the Diagnostics group")
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 860, height: 460)
    }

    struct DiagnosticRow: Identifiable { let index: Int; let event: QueryDiagnosticEvent; var id: Int { index } }

    static func folding(_ f: FoldingIndicator) -> String {
        switch f {
        case .folded: return "Folded"
        case .notFolded: return "Not folded"
        case .notApplicable: return ""
        case .notEvaluated: return "Not evaluated"
        }
    }

    /// The events as an M `#table`, so they can be explored like any query.
    static func script(for events: [QueryDiagnosticEvent]) -> String {
        let rows = events.map { e in
            "{" + [MSyntax.text(e.query), MSyntax.text(e.step), MSyntax.number(e.seconds * 1000), MSyntax.number(e.exclusiveSeconds * 1000),
                   e.rowCount.map { String($0) } ?? "null", MSyntax.text(folding(e.folding)),
                   e.nativeQuery.map(MSyntax.text) ?? "null", e.error.map(MSyntax.text) ?? "null"].joined(separator: ", ") + "}"
        }
        let source = "#table(type table [Query = text, Step = text, #\"Duration (ms)\" = number, #\"Exclusive (ms)\" = number, Rows = nullable number, Folding = text, #\"Native Query\" = nullable text, Error = nullable text], {\(rows.joined(separator: ", "))})"
        return MScript.script(from: [MStep(name: "Source", expression: source)])
    }

    private func addAsQuery() {
        var q = QueryDefinition(name: QueryEditorPlans.newQueryName("Diagnostics_", taken: session.queryNames), mScript: Self.script(for: events))
        q.group = "Diagnostics"
        q.loadEnabled = false
        q.includeInRefresh = false
        session.addQuery(q, name: "Add Diagnostics")
        dismiss()
    }
}
