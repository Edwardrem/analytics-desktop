import Foundation
import FacetCore
import FacetQuery

/// One command of the Power Query Editor ribbon, header menus and context menus. `blocker` says why the command
/// cannot run right now (nil = it can); the ribbon shows that reason as the disabled button's tooltip.
struct EditorCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var blocker: @MainActor (QueryEditorSession) -> String? = { _ in nil }
    var isOn: (@MainActor (QueryEditorSession) -> Bool)?
    let run: @MainActor (QueryEditorSession) -> Void
}

/// Preconditions shared by the commands.
@MainActor
enum Need {
    static func query(_ s: QueryEditorSession) -> String? { s.selectedQuery == nil ? "Select a query first." : nil }
    static func table(_ s: QueryEditorSession) -> String? {
        guard let q = s.selectedQuery else { return "Select a query first." }
        if q.kind == .parameter { return "A parameter has no rows to transform." }
        if s.preview == nil { return s.previewError == nil ? "The preview is still loading." : "Fix the error in this step first." }
        return nil
    }
    static func columns(_ s: QueryEditorSession) -> String? {
        table(s) ?? (s.selectedColumns.isEmpty ? "Select one or more columns first." : nil)
    }
    static func oneColumn(_ s: QueryEditorSession) -> String? {
        table(s) ?? (s.selectedColumns.count == 1 ? nil : "Select exactly one column.")
    }
    static func twoColumns(_ s: QueryEditorSession) -> String? {
        table(s) ?? (s.selectedColumns.count >= 2 ? nil : "Select two or more columns.")
    }
    /// Columns of a kind of type (any-typed columns qualify, as in Power Query).
    static func typed(_ what: String, _ allowed: @escaping (DataType) -> Bool) -> @MainActor (QueryEditorSession) -> String? {
        { s in
            if let b = columns(s) { return b }
            return s.selectedColumnTypes.allSatisfy { $0 == .any || allowed($0) } ? nil : "Select \(what) columns."
        }
    }
    static let text = typed("text") { $0 == .text }
    static let number = typed("number") { $0.isNumeric }
    static let date = typed("date or date/time") { $0 == .date || $0 == .dateTime }
    static let time = typed("time or date/time") { $0 == .time || $0 == .dateTime }
    static let duration = typed("duration") { $0 == .duration }
    static func otherQueries(_ s: QueryEditorSession) -> String? {
        table(s) ?? (s.queries.contains { $0.id != s.selectedQueryID && $0.kind == .table } ? nil : "There is no other query to combine with.")
    }
    static func structured(_ s: QueryEditorSession) -> String? {
        if let b = oneColumn(s) { return b }
        guard let i = s.columnNames.firstIndex(of: s.selectedColumns[0]) else { return "Select a column." }
        return (s.preview?.structuredCells[i]?.isEmpty ?? true) ? "The column holds no tables, records or lists." : nil
    }
}

@MainActor
enum EditorCommands {
    static func command(_ id: String) -> EditorCommand? { index[id] }
    static var all: [EditorCommand] { list }

    private static let list: [EditorCommand] = home + transform + addColumn + view + tools
    private static let index: [String: EditorCommand] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    private static func c(_ id: String, _ title: String, _ symbol: String, _ blocker: @escaping @MainActor (QueryEditorSession) -> String? = { _ in nil },
                          _ run: @escaping @MainActor (QueryEditorSession) -> Void) -> EditorCommand {
        EditorCommand(id: id, title: title, symbol: symbol, blocker: blocker, run: run)
    }
    private static func toggle(_ id: String, _ title: String, _ symbol: String, _ key: ReferenceWritableKeyPath<QueryEditorSession, Bool>) -> EditorCommand {
        EditorCommand(id: id, title: title, symbol: symbol, isOn: { $0[keyPath: key] }) { $0[keyPath: key].toggle() }
    }
    private static func sel(_ s: QueryEditorSession) -> [String] { s.selectedColumns }
    private static func first(_ s: QueryEditorSession) -> String { s.selectedColumns.first ?? "" }

    // MARK: Home

    private static let home: [EditorCommand] = [
        c("pq.closeApply", "Close & Apply", "checkmark.rectangle") { $0.closeRequest = .apply },
        c("pq.apply", "Apply", "checkmark", { $0.hasPendingChanges || !$0.refreshPlan().refresh.isEmpty ? nil : "There are no changes to apply." }) { $0.applyChanges() },
        c("pq.close", "Close", "xmark.rectangle") { $0.closeRequest = .ask },
        c("pq.newSource", "New Source…", "cylinder.split.1x2") { $0.dialog = .newSource },
        c("pq.recentSources", "Recent Sources…", "clock") { $0.dialog = .recentSources },
        c("pq.enterData", "Enter Data…", "square.and.pencil") { $0.dialog = .enterData },
        c("pq.blankQuery", "Blank Query", "doc.badge.plus") { $0.newBlankQuery() },
        c("pq.dataSourceSettings", "Data Source Settings…", "lock.shield") { $0.dialog = .dataSourceSettings },
        c("pq.manageParameters", "Manage Parameters…", "slider.horizontal.3") { $0.dialog = .manageParameters(select: $0.selectedQuery?.kind == .parameter ? $0.selectedQueryID : nil) },
        c("pq.newParameter", "New Parameter…", "plus.square") { $0.dialog = .manageParameters(select: nil) },
        c("pq.refreshPreview", "Refresh Preview", "arrow.clockwise", Need.query) { $0.refreshPreview() },
        c("pq.refreshAll", "Refresh All", "arrow.triangle.2.circlepath") { $0.refreshAllPreviews() },
        c("pq.properties", "Properties…", "info.circle", Need.query) { s in s.selectedQueryID.map { s.dialog = .queryProperties($0) } },
        c("pq.advancedEditor", "Advanced Editor", "chevron.left.forwardslash.chevron.right", Need.query) { $0.dialog = .advancedEditor },
        c("pq.deleteQuery", "Delete", "trash", Need.query) { $0.deleteRequest = $0.selectedQueryID },
        c("pq.duplicateQuery", "Duplicate", "plus.square.on.square", Need.query) { s in s.selectedQueryID.map(s.duplicateQuery) },
        c("pq.referenceQuery", "Reference", "arrow.turn.down.right", Need.query) { s in s.selectedQueryID.map(s.referenceQuery) },
        c("pq.chooseColumns", "Choose Columns…", "checklist", Need.table) { $0.dialog = .chooseColumns },
        c("pq.goToColumn", "Go to Column…", "arrow.right.to.line", Need.table) { $0.dialog = .goToColumn },
        c("pq.removeColumns", "Remove Columns", "minus.square", Need.columns) { $0.apply(.removeColumns(sel($0))) },
        c("pq.removeOtherColumns", "Remove Other Columns", "minus.square.fill", Need.columns) { s in
            s.apply(.removeOtherColumns(keeping: s.columnNames.filter(s.selectedColumns.contains)))
        },
        c("pq.keepTopRows", "Keep Top Rows…", "arrow.up.to.line", Need.table) { $0.dialog = .rows(.keepTop) },
        c("pq.keepBottomRows", "Keep Bottom Rows…", "arrow.down.to.line", Need.table) { $0.dialog = .rows(.keepBottom) },
        c("pq.keepRange", "Keep Range of Rows…", "arrow.up.and.down", Need.table) { $0.dialog = .rows(.keepRange) },
        c("pq.keepDuplicates", "Keep Duplicates", "square.on.square", Need.table) { $0.apply(.keepDuplicates(columns: sel($0))) },
        c("pq.keepErrors", "Keep Errors", "exclamationmark.triangle", Need.table) { $0.apply(.keepErrors(columns: sel($0))) },
        c("pq.removeTopRows", "Remove Top Rows…", "arrow.up.to.line", Need.table) { $0.dialog = .rows(.removeTop) },
        c("pq.removeBottomRows", "Remove Bottom Rows…", "arrow.down.to.line", Need.table) { $0.dialog = .rows(.removeBottom) },
        c("pq.removeAlternateRows", "Remove Alternate Rows…", "line.3.horizontal.decrease", Need.table) { $0.dialog = .rows(.removeAlternate) },
        c("pq.removeDuplicates", "Remove Duplicates", "square.on.square.dashed", Need.table) { $0.apply(.removeDuplicates(columns: sel($0))) },
        c("pq.removeBlankRows", "Remove Blank Rows", "rectangle.dashed", Need.table) { $0.apply(.removeBlankRows) },
        c("pq.removeErrors", "Remove Errors", "exclamationmark.triangle.fill", Need.table) { $0.apply(.removeErrors(columns: sel($0))) },
        c("pq.sortAscending", "Sort Ascending", "arrow.up", Need.columns) { s in s.apply(.sortRows(s.selectedColumns.map { ($0, false) })) },
        c("pq.sortDescending", "Sort Descending", "arrow.down", Need.columns) { s in s.apply(.sortRows(s.selectedColumns.map { ($0, true) })) },
        c("pq.splitDelimiter", "By Delimiter…", "scissors", Need.oneColumn) { $0.dialog = .split(column: first($0), .delimiter) },
        c("pq.splitLength", "By Number of Characters…", "textformat.size", Need.oneColumn) { $0.dialog = .split(column: first($0), .length) },
        c("pq.splitPositions", "By Positions…", "ruler", Need.oneColumn) { $0.dialog = .split(column: first($0), .positions) },
        c("pq.splitLowerUpper", "By Lowercase to Uppercase", "textformat", Need.oneColumn) { s in s.apply(.splitByTransition(column: first(s), .lowerToUpper, into: .columns(SplitCount.parts(s, .lowerToUpper)))) },
        c("pq.splitUpperLower", "By Uppercase to Lowercase", "textformat", Need.oneColumn) { s in s.apply(.splitByTransition(column: first(s), .upperToLower, into: .columns(SplitCount.parts(s, .upperToLower)))) },
        c("pq.splitDigitNonDigit", "By Digit to Non-Digit", "number", Need.oneColumn) { s in s.apply(.splitByTransition(column: first(s), .digitToNonDigit, into: .columns(SplitCount.parts(s, .digitToNonDigit)))) },
        c("pq.splitNonDigitDigit", "By Non-Digit to Digit", "number", Need.oneColumn) { s in s.apply(.splitByTransition(column: first(s), .nonDigitToDigit, into: .columns(SplitCount.parts(s, .nonDigitToDigit)))) },
        c("pq.groupBy", "Group By…", "square.grid.3x1.below.line.grid.1x2", Need.table) { $0.dialog = .groupBy },
        c("pq.typeLocale", "Using Locale…", "globe", Need.columns) { $0.dialog = .changeTypeWithLocale(columns: sel($0)) },
        c("pq.detectType", "Detect Data Type", "wand.and.stars", Need.table) { s in
            guard let table = s.preview?.untypedTable else { return }
            let scope = s.selectedColumns.isEmpty ? table : DataTable(name: table.name, columns: table.columns.filter { s.selectedColumns.contains($0.name) })
            if let t = Transform.detectTypes(in: scope) { s.apply(t) } else { s.message = StatusMessage(kind: .info, text: "The column types already match the data.") }
        },
        c("pq.promoteHeaders", "Use First Row as Headers", "text.line.first.and.arrowtriangle.forward", Need.table) { $0.apply(.promoteHeaders) },
        c("pq.demoteHeaders", "Use Headers as First Row", "text.line.last.and.arrowtriangle.forward", Need.table) { $0.apply(.demoteHeaders) },
        c("pq.replaceValues", "Replace Values…", "arrow.left.arrow.right", Need.columns) { $0.dialog = .replaceValues(columns: sel($0)) },
        c("pq.replaceErrors", "Replace Errors…", "exclamationmark.arrow.triangle.2.circlepath", Need.columns) { $0.dialog = .replaceErrors(columns: sel($0)) },
        c("pq.mergeQueries", "Merge Queries…", "arrow.triangle.merge", Need.otherQueries) { $0.dialog = .merge(asNew: false) },
        c("pq.mergeQueriesNew", "Merge Queries as New…", "arrow.triangle.merge", Need.otherQueries) { $0.dialog = .merge(asNew: true) },
        c("pq.appendQueries", "Append Queries…", "rectangle.stack.badge.plus", Need.otherQueries) { $0.dialog = .append(asNew: false) },
        c("pq.appendQueriesNew", "Append Queries as New…", "rectangle.stack.badge.plus", Need.otherQueries) { $0.dialog = .append(asNew: true) },
        c("pq.combineFiles", "Combine Files", "doc.on.doc", { s in
            if let b = Need.table(s) { return b }
            return s.columnNames.contains("Content") && s.columnNames.contains("Extension") ? nil : "Combine Files works on a folder listing (Content and Extension columns)."
        }) { s in CombineFilesCommand.run(s) },
    ] + DataTypeCommands.all + aiCommands

    /// AI Insights: the text and image transforms run on this Mac (NaturalLanguage and Vision) and add a column;
    /// Azure Machine Learning needs Azure, which the engine cannot reach.
    private static let aiCommands: [EditorCommand] = [
        ("pq.ai.sentiment", "Score Sentiment", "face.smiling", "Sentiment", Transform.aiSentiment),
        ("pq.ai.keyPhrases", "Extract Key Phrases", "text.quote", "Key phrases", Transform.aiKeyPhrases),
        ("pq.ai.language", "Detect Language", "globe", "Language", Transform.aiDetectLanguage),
        ("pq.ai.vision", "Tag Images", "eye", "Tags", Transform.aiTagImage),
    ].map { id, title, symbol, column, step in
        c(id, title, symbol, Need.oneColumn) { s in
            s.apply(step(first(s), QueryEditorPlans.uniqueColumnName(column, taken: s.columnNames)))
        }
    } + [c("pq.ai.ml", "Azure Machine Learning", "brain", { _ in "Needs Azure Machine Learning with a Microsoft sign-in, which the query engine cannot reach." }) { _ in }]

    // MARK: Transform

    private static let transform: [EditorCommand] = [
        c("pq.transpose", "Transpose", "arrow.up.left.and.arrow.down.right", Need.table) { $0.apply(.transpose) },
        c("pq.reverseRows", "Reverse Rows", "arrow.up.arrow.down", Need.table) { $0.apply(.reverseRows) },
        c("pq.countRows", "Count Rows", "number.square", Need.table) { $0.apply(.countRows) },
        c("pq.renameColumn", "Rename…", "character.cursor.ibeam", Need.oneColumn) { $0.dialog = .renameColumn(first($0)) },
        c("pq.fillDown", "Down", "arrow.down.to.line.compact", Need.columns) { $0.apply(.fillDown(sel($0))) },
        c("pq.fillUp", "Up", "arrow.up.to.line.compact", Need.columns) { $0.apply(.fillUp(sel($0))) },
        c("pq.pivot", "Pivot Column…", "arrow.turn.right.up", Need.oneColumn) { $0.dialog = .pivot(column: first($0)) },
        c("pq.moveLeft", "Left", "arrow.left", Need.columns) { move($0, .left) },
        c("pq.moveRight", "Right", "arrow.right", Need.columns) { move($0, .right) },
        c("pq.moveToBeginning", "To Beginning", "arrow.left.to.line", Need.columns) { move($0, .toBeginning) },
        c("pq.moveToEnd", "To End", "arrow.right.to.line", Need.columns) { move($0, .toEnd) },
        c("pq.unpivot", "Unpivot Columns", "arrow.turn.left.down", Need.columns) { s in
            s.apply(.unpivotOtherColumns(keeping: s.columnNames.filter { !s.selectedColumns.contains($0) }))
        },
        c("pq.unpivotOther", "Unpivot Other Columns", "arrow.turn.left.down", Need.columns) { s in
            s.apply(.unpivotOtherColumns(keeping: s.columnNames.filter(s.selectedColumns.contains)))
        },
        c("pq.unpivotSelected", "Unpivot Only Selected Columns", "arrow.turn.left.down", Need.columns) { s in
            s.apply(.unpivotColumns(s.columnNames.filter(s.selectedColumns.contains)))
        },
        c("pq.convertToList", "Convert to List", "list.bullet", Need.oneColumn) { s in
            let column = first(s)
            s.applyStep(named: column) { "\($0)\(MSyntax.field(column))" }
        },
        c("pq.mergeColumns", "Merge Columns…", "arrow.right.and.line.vertical.and.arrow.left", Need.twoColumns) { s in
            s.dialog = .mergeColumns(columns: s.columnNames.filter(s.selectedColumns.contains), asNewColumn: false)
        },
        c("pq.prefix", "Add Prefix…", "text.insert", Need.columns) { $0.dialog = .affix(columns: sel($0), suffix: false) },
        c("pq.suffix", "Add Suffix…", "text.append", Need.columns) { $0.dialog = .affix(columns: sel($0), suffix: true) },
        c("pq.parseJSON", "JSON", "curlybraces", Need.oneColumn) { $0.apply(.parse(column: first($0), .json)) },
        c("pq.parseXML", "XML", "chevron.left.forwardslash.chevron.right", Need.oneColumn) { $0.apply(.parse(column: first($0), .xml)) },
        c("pq.expand", "Expand…", "arrow.up.left.and.arrow.down.right.circle", Need.structured) { s in
            let column = first(s)
            if let i = s.columnNames.firstIndex(of: column), s.preview?.structuredCells[i]?.values.contains("List") == true {
                s.apply(.expandListColumn(column: column))
            } else {
                s.dialog = .expand(column: column)
            }
        },
        c("pq.aggregate", "Aggregate…", "sum", Need.structured) { $0.dialog = .aggregate(column: first($0)) },
        c("pq.extractValues", "Extract Values…", "list.bullet.indent", Need.structured) { $0.dialog = .extractValues(column: first($0)) },
        c("pq.runR", "Run R Script…", "terminal", Need.table) { $0.dialog = .script(python: false) },
        c("pq.runPython", "Run Python Script…", "terminal", Need.table) { $0.dialog = .script(python: true) },
        c("pq.filterColumn", "Filter Rows…", "line.3.horizontal.decrease.circle", Need.oneColumn) { $0.dialog = .filter(column: first($0)) },
        c("pq.removeEmpty", "Remove Empty", "rectangle.badge.minus", Need.oneColumn) { $0.apply(.filterRows(.isNotBlank(column: first($0)))) },
        c("pq.drillDown", "Drill Down", "arrow.down.right.circle", Need.oneColumn) { s in
            let column = first(s)
            s.applyStep(named: column) { "\($0)\(MSyntax.field(column))" }
        },
        c("pq.addAsNewQuery", "Add as New Query", "plus.rectangle.on.folder", Need.oneColumn) { s in
            guard let q = s.selectedQuery, let i = s.currentStepIndex else { return }
            let column = first(s)
            let base = MScript.truncating(q.mScript, upToStep: i)
            let script = MScript.appendingStep(named: column, expression: { "\($0)\(MSyntax.field(column))" }, to: base)
            var copy = QueryDefinition(name: SourcePlanner.uniqueName(column, taken: s.queryNames), mScript: script)
            copy.group = q.group
            s.addQuery(copy, name: "Add as New Query")
        },
        c("pq.toTable", "To Table", "tablecells", { s in s.preview?.valueKind == "list" || s.preview?.valueKind == "record" ? nil : "The step does not return a list or a record." }) { s in
            if s.preview?.valueKind == "record" { s.applyStep(named: "Converted to Table") { "Record.ToTable(\($0))" } }
            else { s.applyStep(named: "Converted to Table") { "Table.FromList(\($0), Splitter.SplitByNothing(), null, null, ExtraValues.Error)" } }
        },
        c("pq.earliest", "Earliest", "calendar.badge.minus", { s in Need.oneColumn(s) ?? Need.date(s) }) { $0.apply(.earliest(column: first($0))) },
        c("pq.latest", "Latest", "calendar.badge.plus", { s in Need.oneColumn(s) ?? Need.date(s) }) { $0.apply(.latest(column: first($0))) },
    ] + ColumnOperationCommands.transform

    private static func move(_ s: QueryEditorSession, _ m: QueryEditorPlans.Move) {
        let order = QueryEditorPlans.movedColumns(s.columnNames, selected: s.selectedColumns, m)
        if order != s.columnNames { s.apply(.reorderColumns(order)) }
    }

    // MARK: Add Column

    private static let addColumn: [EditorCommand] = [
        c("pq.add.examples", "From All Columns", "wand.and.rays", Need.table) { $0.dialog = .columnFromExamples(columns: nil) },
        c("pq.add.examplesSelection", "From Selection", "wand.and.rays.inverse", Need.columns) { $0.dialog = .columnFromExamples(columns: sel($0)) },
        c("pq.add.custom", "Custom Column…", "function", Need.table) { $0.dialog = .customColumn },
        c("pq.add.invoke", "Invoke Custom Function…", "f.cursive", { s in
            Need.table(s) ?? (s.queries.contains { $0.kind == .function } ? nil : "The file has no function queries.")
        }) { $0.dialog = .invokeFunction },
        c("pq.add.conditional", "Conditional Column…", "arrow.triangle.branch", Need.table) { $0.dialog = .conditionalColumn },
        c("pq.add.index0", "From 0", "list.number", Need.table) { s in s.apply(.addIndexColumn(name: QueryEditorPlans.uniqueColumnName("Index", taken: s.columnNames), start: 0, increment: 1)) },
        c("pq.add.index1", "From 1", "list.number", Need.table) { s in s.apply(.addIndexColumn(name: QueryEditorPlans.uniqueColumnName("Index", taken: s.columnNames), start: 1, increment: 1)) },
        c("pq.add.indexCustom", "Custom…", "list.number", Need.table) { $0.dialog = .indexColumn },
        c("pq.add.duplicate", "Duplicate Column", "plus.rectangle.on.rectangle", Need.oneColumn) { s in
            s.apply(.duplicateColumn(first(s), newName: QueryEditorPlans.uniqueColumnName("\(first(s)) - Copy", taken: s.columnNames)))
        },
        c("pq.add.mergeColumns", "Merge Columns…", "arrow.right.and.line.vertical.and.arrow.left", Need.twoColumns) { s in
            s.dialog = .mergeColumns(columns: s.columnNames.filter(s.selectedColumns.contains), asNewColumn: true)
        },
        c("pq.add.parseJSON", "JSON", "curlybraces", Need.oneColumn) { s in addCustom(s, "JSON", "Json.Document(\(MSyntax.field(first(s))))", nil) },
        c("pq.add.parseXML", "XML", "chevron.left.forwardslash.chevron.right", Need.oneColumn) { s in addCustom(s, "XML", "Xml.Tables(\(MSyntax.field(first(s))))", nil) },
    ] + ColumnOperationCommands.addColumn

    /// A new column from a per-row expression.
    static func addCustom(_ s: QueryEditorSession, _ name: String, _ expression: String, _ type: DataType?) {
        s.apply(.addCustomColumn(name: QueryEditorPlans.uniqueColumnName(name, taken: s.columnNames), expression: expression, type: type))
    }

    // MARK: View and Tools

    private static let view: [EditorCommand] = [
        toggle("pq.view.querySettings", "Query Settings", "sidebar.right", \.showQuerySettings),
        toggle("pq.view.formulaBar", "Formula Bar", "function", \.showFormulaBar),
        toggle("pq.view.monospaced", "Monospaced", "textformat.abc", \.monospaced),
        toggle("pq.view.whitespace", "Show Whitespace", "text.word.spacing", \.showWhitespace),
        toggle("pq.view.quality", "Column Quality", "checkmark.seal", \.showQuality),
        toggle("pq.view.distribution", "Column Distribution", "chart.bar", \.showDistribution),
        toggle("pq.view.profile", "Column Profile", "chart.bar.doc.horizontal", \.showProfile),
        toggle("pq.view.wholeDataset", "Profile Entire Data Set", "square.stack.3d.up", \.profileWholeDataset),
        c("pq.view.dependencies", "Query Dependencies", "point.3.connected.trianglepath.dotted") { $0.dialog = .dependencies },
        centre("pq.view.data", "Data View", "tablecells", .data),
        centre("pq.view.schema", "Schema View", "list.bullet.rectangle", .schema),
        centre("pq.view.script", "Query Script", "curlybraces.square", .script),
        EditorCommand(id: "pq.view.diagram", title: "Diagram View", symbol: "rectangle.3.group", blocker: newEditor, isOn: { $0.showDiagram }) { $0.showDiagram.toggle() },
    ]

    /// The diagram, schema and script views belong to the new editor, a preview feature.
    private static func newEditor(_ s: QueryEditorSession) -> String? {
        s.newEditorViews ? nil : "Turn on “Diagram, schema and script views in the Power Query Editor” in Settings ▸ Preview features."
    }
    private static func centre(_ id: String, _ title: String, _ symbol: String, _ view: QueryEditorSession.CentreView) -> EditorCommand {
        EditorCommand(id: id, title: title, symbol: symbol, blocker: view == .data ? { _ in nil } : newEditor,
                      isOn: { $0.centreView == view }) { $0.centreView = view }
    }

    private static let tools: [EditorCommand] = [
        c("pq.tools.diagnoseStep", "Diagnose Step", "stethoscope", Need.query) { $0.diagnoseStep() },
        c("pq.tools.startDiagnostics", "Start Diagnostics", "record.circle", { $0.isRecordingDiagnostics ? "Diagnostics are already being recorded." : nil }) { $0.startDiagnostics() },
        c("pq.tools.stopDiagnostics", "Stop Diagnostics", "stop.circle", { $0.isRecordingDiagnostics ? nil : "Start diagnostics first." }) { $0.stopDiagnostics() },
        c("pq.tools.nativeQuery", "View Native Query", "text.magnifyingglass", { s in
            guard let step = s.currentStep else { return "Select a step." }
            return s.folding[step.name]?.nativeQuery == nil ? "This step is not folded to the data source." : nil
        }) { s in
            if let step = s.currentStep, let q = s.folding[step.name]?.nativeQuery { s.dialog = .nativeQuery(q) }
        },
        c("pq.undo", "Undo", "arrow.uturn.backward", { $0.undoName == nil ? "Nothing to undo." : nil }) { $0.undo() },
        c("pq.redo", "Redo", "arrow.uturn.forward", { $0.redoName == nil ? "Nothing to redo." : nil }) { $0.redo() },
    ]
}

/// How many columns a split produces: the most parts any previewed value splits into, as Power Query counts them.
@MainActor
enum SplitCount {
    static func parts(_ s: QueryEditorSession, _ transition: CharacterTransition) -> Int {
        guard let column = s.preview?.table.column(s.selectedColumns.first ?? "") else { return 2 }
        return max(2, column.values.map { parts(of: $0.asString, transition) }.max() ?? 2)
    }
    static func parts(of text: String, _ transition: CharacterTransition) -> Int {
        let chars = Array(text)
        guard chars.count > 1 else { return 1 }
        var n = 1
        for i in 1..<chars.count {
            let a = chars[i - 1], b = chars[i]
            let cut: Bool
            switch transition {
            case .lowerToUpper: cut = ("a"..."z").contains(a) && ("A"..."Z").contains(b)
            case .upperToLower: cut = ("A"..."Z").contains(a) && ("a"..."z").contains(b)
            case .digitToNonDigit: cut = ("0"..."9").contains(a) && !("0"..."9").contains(b)
            case .nonDigitToDigit: cut = !("0"..."9").contains(a) && ("0"..."9").contains(b)
            }
            if cut { n += 1 }
        }
        return n
    }
    /// Parts of text split at a delimiter (each occurrence).
    static func parts(of text: String, delimiter: String) -> Int {
        delimiter.isEmpty ? 1 : text.components(separatedBy: delimiter).count
    }
}

/// Home ▸ Combine Files on a folder listing: the plan Get Data uses for the files of the most common format.
@MainActor
enum CombineFilesCommand {
    static func run(_ s: QueryEditorSession) {
        guard let table = s.preview?.table, let ext = table.column("Extension") else { return }
        guard let plan = SourcePlanner.combinePlan(extensions: ext.values.map(\.asString), sampleText: { GetDataSession.sampleText(of: $0, in: table) }) else {
            s.message = StatusMessage(kind: .warning, text: "The folder has no CSV, text, JSON or Excel files to combine.")
            return
        }
        s.applyStep(named: "Filtered Files") { "Table.SelectRows(\($0), each Text.Lower([Extension]) = \(MSyntax.text(plan.extension)))" }
        s.apply(.combineFiles(plan.format))
    }
}
