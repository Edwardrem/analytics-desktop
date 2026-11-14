import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

// MARK: - Custom column

struct CustomColumnDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let edit: StepEdit?
    @State private var name = "Custom"
    @State private var formula = ""
    @State private var type: DataType = .any
    @Environment(\.dismiss) private var dismiss

    /// Syntax check of the formula as Power Query runs it (`each <formula>`).
    static func problem(in formula: String, known: Set<String>) -> String? {
        let body = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return "Type a formula." }
        let script = MScript.script(from: [MStep(name: "Check", expression: "each " + (body.hasPrefix("=") ? String(body.dropFirst()) : body))])
        return MScript.validate(script, knownNames: known).first { $0.severity == .error }?.message
    }
    private var problem: String? { Self.problem(in: formula, known: session.queryNames) }

    var body: some View {
        DialogChrome(title: "Custom Column", subtitle: "Write a formula over the columns of each row, for example [Quantity] * [Price].",
                     canCommit: problem == nil && !name.isEmpty, width: 640, commit: done) {
            HStack(alignment: .top, spacing: Design.Space.m) {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    PropertyRow("New column name") { TextField("Custom", text: $name).textFieldStyle(.roundedBorder) }
                    PropertyRow("Data type") {
                        Picker("Data type", selection: $type) {
                            Text("Any").tag(DataType.any)
                            ForEach(DataTypeCommands.types, id: \.type) { Text($0.title).tag($0.type) }
                        }.labelsHidden()
                    }
                    Text("Custom column formula").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    CodeEditor(text: $formula, language: LanguageSupport.m, fontSize: 12).frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairlineStrong))
                    Label(problem ?? "No syntax errors have been detected.", systemImage: problem == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(Design.Typeface.caption).foregroundStyle(problem == nil ? Design.Palette.positive : Design.Palette.caution)
                }
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text("Available columns").font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(columns, id: \.self) { c in
                                Text(c).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                                    .onTapGesture { formula += MSyntax.field(c) }
                                    .help("Insert \(MSyntax.field(c))")
                            }
                        }
                    }
                }
                .frame(width: 170, height: 250)
            }
        }
        .onAppear {
            if case .addCustomColumn(let n, let e, let t)? = edit?.transform { name = n; formula = e; type = t ?? .any }
            else { name = QueryEditorPlans.uniqueColumnName("Custom", taken: columns) }
        }
    }

    private func done() {
        var body = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("=") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
        session.commit(.addCustomColumn(name: name, expression: body, type: type == .any ? nil : type), editing: edit)
        dismiss()
    }
}

// MARK: - Conditional column

/// A conditional column's value or output: typed text (parsed by the column's type) or another column.
struct OperandField: View {
    @Binding var useColumn: Bool
    @Binding var text: String
    @Binding var column: String
    let columns: [String]
    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Picker("Kind", selection: $useColumn) {
                Image(systemName: "textformat.abc").tag(false).help("Enter a value")
                Image(systemName: "tablecells").tag(true).help("Select a column")
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 64)
            if useColumn {
                Picker("Column", selection: $column) { ForEach(columns, id: \.self) { Text($0).tag($0) } }.labelsHidden()
            } else {
                TextField("Value", text: $text).textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct ConditionalColumnDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    let edit: StepEdit?
    struct Row {
        var column = ""
        var op = ConditionalClause.Operator.equals
        var valueIsColumn = false, value = "", valueColumn = ""
        var outputIsColumn = false, output = "", outputColumn = ""
    }
    @State private var name = "Custom"
    @State private var rows: [Row] = []
    @State private var elseIsColumn = false
    @State private var elseText = ""
    @State private var elseColumn = ""
    @Environment(\.dismiss) private var dismiss

    private var columns: [String] { table.columnNames }
    private static let ops: [(ConditionalClause.Operator, String)] = [
        (.equals, "equals"), (.notEquals, "does not equal"), (.greaterThan, "is greater than"), (.greaterOrEqual, "is greater than or equal to"),
        (.lessThan, "is less than"), (.lessOrEqual, "is less than or equal to"), (.beginsWith, "begins with"), (.endsWith, "ends with"),
        (.contains, "contains"), (.doesNotContain, "does not contain"), (.isNull, "is null"), (.isNotNull, "is not null"),
    ]

    var body: some View {
        DialogChrome(title: "Add Conditional Column", subtitle: "Add a column whose value depends on conditions over other columns.",
                     canCommit: !name.isEmpty && !rows.isEmpty, width: 760, commit: done) {
            PropertyRow("New column name") { TextField("Custom", text: $name).textFieldStyle(.roundedBorder).frame(width: 220) }
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: Design.Space.xs) {
                    Text(i == 0 ? "If" : "Else If").font(Design.Typeface.caption).frame(width: 40, alignment: .leading)
                    Picker("Column", selection: $rows[i].column) { ForEach(columns, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                    Picker("Operator", selection: $rows[i].op) { ForEach(Self.ops, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 150)
                    if rows[i].op != .isNull, rows[i].op != .isNotNull {
                        OperandField(useColumn: $rows[i].valueIsColumn, text: $rows[i].value, column: $rows[i].valueColumn, columns: columns).frame(width: 180)
                    }
                    Text("Then").font(Design.Typeface.caption)
                    OperandField(useColumn: $rows[i].outputIsColumn, text: $rows[i].output, column: $rows[i].outputColumn, columns: columns).frame(width: 180)
                    IconButton("minus.circle", help: "Remove this clause") { rows.remove(at: i) }.disabled(rows.count == 1)
                }
            }
            Button("Add Clause") { rows.append(Row(column: columns.first ?? "", valueColumn: columns.first ?? "", outputColumn: columns.first ?? "")) }.controlSize(.small)
            HStack {
                Text("Else").font(Design.Typeface.caption).frame(width: 40, alignment: .leading)
                OperandField(useColumn: $elseIsColumn, text: $elseText, column: $elseColumn, columns: columns).frame(width: 240)
            }
        }
        .onAppear(perform: load)
    }

    /// Typed outputs: numbers and logicals stay numbers and logicals, everything else is text; empty is null.
    static func output(_ text: String) -> Value {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.lowercased() == "null" { return .null }
        if let i = Int64(t) { return .int(i) }
        if let d = Double(t) { return .double(d) }
        if t == "true" || t == "false" { return .bool(t == "true") }
        return .string(text)
    }

    private func operand(_ isColumn: Bool, _ text: String, _ column: String, type: DataType?) -> ConditionalClause.Operand {
        if isColumn { return .column(column) }
        if let type { return .value(type == .any ? Self.output(text) : EditorValues.parse(text, as: type)) }
        return .value(Self.output(text))
    }

    private func load() {
        let first = columns.first ?? ""
        if case .addConditionalColumn(let n, let clauses, let otherwise)? = edit?.transform {
            name = n
            rows = clauses.map { c in
                var r = Row(column: c.column, op: c.op, valueColumn: first, outputColumn: first)
                switch c.value { case .column(let x): r.valueIsColumn = true; r.valueColumn = x; case .value(let v): r.value = v.isNull ? "" : v.asString }
                switch c.output { case .column(let x): r.outputIsColumn = true; r.outputColumn = x; case .value(let v): r.output = v.isNull ? "" : v.asString }
                return r
            }
            switch otherwise { case .column(let x): elseIsColumn = true; elseColumn = x; case .value(let v): elseText = v.isNull ? "" : v.asString }
        } else {
            name = QueryEditorPlans.uniqueColumnName("Custom", taken: columns)
            rows = [Row(column: session.selectedColumns.first ?? first, valueColumn: first, outputColumn: first)]
            elseColumn = first
        }
    }

    private func done() {
        let clauses = rows.map { r in
            ConditionalClause(column: r.column, op: r.op,
                              value: operand(r.valueIsColumn, r.value, r.valueColumn, type: table.column(r.column)?.type ?? .any),
                              output: operand(r.outputIsColumn, r.output, r.outputColumn, type: nil))
        }
        session.commit(.addConditionalColumn(name: name, clauses: clauses, otherwise: operand(elseIsColumn, elseText, elseColumn, type: nil)), editing: edit)
        dismiss()
    }
}

// MARK: - Invoke custom function

struct InvokeFunctionDialog: View {
    @ObservedObject var session: QueryEditorSession
    let columns: [String]
    let edit: StepEdit?
    struct Argument { var name: String; var useColumn = true; var text = ""; var column = "" }
    @State private var name = "Invoked Function"
    @State private var function = ""
    @State private var arguments: [Argument] = []
    @Environment(\.dismiss) private var dismiss

    private var functions: [String] { session.queries.filter { $0.kind == .function }.map(\.name) }

    /// Parameter names of a function query written as `(a, b as text) => …` (optionally inside `let`).
    static func parameters(of script: String) -> [String]? {
        guard let ast = try? MParser.parse(script) else { return nil }
        switch ast {
        case .function(let params, _, _): return params.map(\.name)
        case .letIn(let bindings, .identifier(let result, _)):
            if case .function(let params, _, _)? = bindings.first(where: { $0.name == result })?.expr { return params.map(\.name) }
            return nil
        default: return nil
        }
    }

    var body: some View {
        DialogChrome(title: "Invoke Custom Function", subtitle: "Call a function query for each row.", canCommit: !name.isEmpty && !function.isEmpty, width: 520, commit: done) {
            PropertyRow("New column name") { TextField("Name", text: $name).textFieldStyle(.roundedBorder) }
            PropertyRow("Function query") {
                Picker("Function", selection: $function) { ForEach(functions, id: \.self) { Text($0).tag($0) } }.labelsHidden()
            }
            ForEach(arguments.indices, id: \.self) { i in
                PropertyRow(arguments[i].name) {
                    OperandField(useColumn: $arguments[i].useColumn, text: $arguments[i].text, column: $arguments[i].column, columns: columns)
                }
            }
        }
        .onAppear {
            if case .invokeCustomFunction(let n, let f, let args)? = edit?.transform {
                name = n; function = f
                loadParameters()
                for (i, a) in args.enumerated() where arguments.indices.contains(i) {
                    switch a { case .column(let c): arguments[i].useColumn = true; arguments[i].column = c
                    case .value(let v): arguments[i].useColumn = false; arguments[i].text = v.asString }
                }
            } else {
                function = functions.first ?? ""
                loadParameters()
            }
        }
        .onChange(of: function) { _, _ in if edit == nil { loadParameters() } }
    }

    private func loadParameters() {
        let names = session.query(named: function).flatMap { Self.parameters(of: $0.mScript) } ?? []
        arguments = names.map { Argument(name: $0, column: columns.first ?? "") }
        if edit == nil { name = QueryEditorPlans.uniqueColumnName(function.isEmpty ? "Invoked Function" : function, taken: columns) }
    }

    private func done() {
        let args: [ConditionalClause.Operand] = arguments.map { $0.useColumn ? .column($0.column) : .value(ConditionalColumnDialog.output($0.text)) }
        session.commit(.invokeCustomFunction(name: name, function: function, arguments: args), editing: edit)
        dismiss()
    }
}

// MARK: - Column from examples

struct ColumnFromExamplesDialog: View {
    @ObservedObject var session: QueryEditorSession
    let table: DataTable
    let sourceColumns: [String]?
    @State private var examples: [Int: String] = [:]
    @State private var name = "Custom"
    @State private var result: ColumnFromExamples.Result?
    @Environment(\.dismiss) private var dismiss

    private static let rows = 40
    private var shownColumns: [DataColumn] { table.columns.filter { sourceColumns?.contains($0.name) ?? true } }

    var body: some View {
        DialogChrome(title: "Add Column from Examples", subtitle: "Type a value in the new column for a few rows; the transformation is inferred from your examples.",
                     okTitle: "OK", canCommit: result != nil && !name.isEmpty, width: 820, commit: done) {
            HStack {
                PropertyRow("New column name") { TextField("Custom", text: $name).textFieldStyle(.roundedBorder).frame(width: 220) }
                Spacer()
            }
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(shownColumns, id: \.name) { c in Text(c.name).font(Design.Typeface.bodyStrong).frame(width: 140, alignment: .leading).padding(4) }
                        Text(name).font(Design.Typeface.bodyStrong).foregroundStyle(Color.accentColor).frame(width: 180, alignment: .leading).padding(4)
                    }
                    Hairline()
                    ForEach(0..<min(Self.rows, table.rowCount), id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(shownColumns, id: \.name) { c in
                                Text(QueryCellText.text(c.values[safe: r] ?? .null, type: c.type)).font(Design.Typeface.caption).lineLimit(1)
                                    .frame(width: 140, alignment: .leading).padding(.horizontal, 4)
                            }
                            TextField(result?.values[safe: r].map { QueryCellText.text($0, type: .any) } ?? "", text: Binding(
                                get: { examples[r] ?? "" },
                                set: { examples[r] = $0.isEmpty ? nil : $0; infer() }))
                                .textFieldStyle(.roundedBorder).font(Design.Typeface.caption).frame(width: 180)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(height: 300)
            if let result {
                Text("Transform: \(result.description)").font(Design.Typeface.caption)
                Text(result.expression).font(Design.Typeface.mono).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            } else if !examples.isEmpty {
                Text("No transformation reproduces every example yet.").font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution)
            }
        }
        .onAppear { name = QueryEditorPlans.uniqueColumnName("Custom", taken: table.columnNames) }
    }

    private func infer() {
        result = examples.isEmpty ? nil : ColumnFromExamples.infer(table: table, examples: examples, columns: sourceColumns)
    }

    private func done() {
        guard let result else { return }
        session.apply(.addColumnFromExamples(name: name, expression: result.expression))
        dismiss()
    }
}
