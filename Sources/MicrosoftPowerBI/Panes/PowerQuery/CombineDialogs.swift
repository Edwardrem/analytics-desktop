import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// Matching rows of a merge on the previews: how many rows of the first table find a row in the second with equal
/// keys (null keys never match, as in Power Query's join).
enum MergeEstimate {
    static func matches(left: DataTable, leftKeys: [String], right: DataTable, rightKeys: [String]) -> Int? {
        guard !leftKeys.isEmpty, leftKeys.count == rightKeys.count else { return nil }
        let li = leftKeys.compactMap(left.columnIndex), ri = rightKeys.compactMap(right.columnIndex)
        guard li.count == leftKeys.count, ri.count == rightKeys.count else { return nil }
        var keys = Set<[Value]>()
        for r in 0..<right.rowCount {
            let k = ri.map { right[r, $0] }
            if !k.contains(where: \.isNull) { keys.insert(k) }
        }
        var n = 0
        for r in 0..<left.rowCount {
            let k = li.map { left[r, $0] }
            if !k.contains(where: \.isNull), keys.contains(k) { n += 1 }
        }
        return n
    }
}

// MARK: - Merge

struct MergeQueriesDialog: View {
    @ObservedObject var session: QueryEditorSession
    let asNew: Bool
    let edit: StepEdit?
    @State private var left = ""
    @State private var right = ""
    @State private var leftKeys: [String] = []
    @State private var rightKeys: [String] = []
    @State private var kind = MergeJoinKind.leftOuter
    @State private var fuzzy = false
    @State private var options = FuzzyMergeOptions()
    @State private var maxMatches = 0
    @State private var transformation = ""
    @State private var leftTable: DataTable?
    @State private var rightTable: DataTable?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var tables: [QueryDefinition] { session.queries.filter { $0.kind == .table } }
    private static let kinds: [(MergeJoinKind, String)] = [
        (.leftOuter, "Left Outer (all from first, matching from second)"), (.rightOuter, "Right Outer (all from second, matching from first)"),
        (.fullOuter, "Full Outer (all rows from both)"), (.inner, "Inner (only matching rows)"),
        (.leftAnti, "Left Anti (rows only in first)"), (.rightAnti, "Right Anti (rows only in second)"),
    ]

    var body: some View {
        DialogChrome(title: "Merge", subtitle: "Select a table and matching columns to create a merged table. Click column headers in order to pick the keys.",
                     canCommit: canCommit, width: 760, problem: problem, commit: done) {
            if asNew {
                Picker("First table", selection: $left) { ForEach(tables) { Text($0.name).tag($0.name) } }.frame(width: 320)
            } else {
                Text(left).font(Design.Typeface.bodyStrong)
            }
            keyGrid(leftTable, keys: $leftKeys)
            Picker("Second table", selection: $right) { ForEach(tables.filter { $0.name != left || asNew }) { Text($0.name).tag($0.name) } }.frame(width: 320)
            keyGrid(rightTable, keys: $rightKeys)
            Picker("Join Kind", selection: $kind) { ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) } }.frame(width: 420)
            Toggle("Use fuzzy matching to perform the merge", isOn: $fuzzy)
            if fuzzy {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    HStack {
                        Text("Similarity threshold").font(Design.Typeface.caption)
                        Slider(value: $options.threshold, in: 0...1, step: 0.05).frame(width: 200)
                        Text(String(format: "%.2f", options.threshold)).font(Design.Typeface.caption).monospacedDigit()
                    }
                    Toggle("Ignore case", isOn: $options.ignoreCase)
                    Toggle("Match by combining text parts", isOn: $options.ignoreSpace)
                    HStack {
                        Text("Maximum number of matches (0 = all)").font(Design.Typeface.caption)
                        TextField("0", value: $maxMatches, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    Picker("Transformation table", selection: $transformation) {
                        Text("None").tag("")
                        ForEach(tables.filter { $0.name != left && $0.name != right }) { Text($0.name).tag($0.name) }
                    }
                    .frame(width: 360)
                }
                .padding(.leading, Design.Space.l)
            }
            if !fuzzy, let l = leftTable, let r = rightTable, let n = MergeEstimate.matches(left: l, leftKeys: leftKeys, right: r, rightKeys: rightKeys) {
                Text("The selection matches \(n) of \(l.rowCount) rows from the first table\(l.rowCount >= QueryEditorSession.previewRows ? " (first \(QueryEditorSession.previewRows) rows)" : "").")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .task(id: left) { leftTable = await previewTable(left) }
        .task(id: right) { rightTable = await previewTable(right) }
    }

    private var canCommit: Bool { !left.isEmpty && !right.isEmpty && !leftKeys.isEmpty && leftKeys.count == rightKeys.count }

    /// A short preview with clickable headers; clicked columns become keys, numbered in click order.
    private func keyGrid(_ table: DataTable?, keys: Binding<[String]>) -> some View {
        Group {
            if let table {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(table.columnNames, id: \.self) { c in
                                let index = keys.wrappedValue.firstIndex(of: c)
                                HStack(spacing: 4) {
                                    if let index { Text("\(index + 1)").font(Design.Typeface.captionStrong).foregroundStyle(Color.accentColor) }
                                    Text(c).font(Design.Typeface.bodyStrong).lineLimit(1)
                                }
                                .frame(width: 130, alignment: .leading).padding(4)
                                .background(index != nil ? Design.Palette.accent.opacity(0.18) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let index { keys.wrappedValue.remove(at: index) } else { keys.wrappedValue.append(c) }
                                }
                            }
                        }
                        ForEach(0..<min(5, table.rowCount), id: \.self) { r in
                            HStack(spacing: 0) {
                                ForEach(Array(table.columns.enumerated()), id: \.offset) { _, col in
                                    Text(QueryCellText.text(col.values[safe: r] ?? .null, type: col.type)).font(Design.Typeface.caption).lineLimit(1)
                                        .frame(width: 130, alignment: .leading).padding(.horizontal, 4)
                                }
                            }
                        }
                    }
                }
                .frame(height: 130)
                .background(Design.Palette.elevated)
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairline))
            } else {
                ProgressView().frame(height: 130).frame(maxWidth: .infinity)
            }
        }
    }

    private func previewTable(_ name: String) async -> DataTable? {
        guard !name.isEmpty else { return nil }
        let engine = session.makeEngine()
        if name == session.selectedQuery?.name, let edit {
            let index = session.steps.firstIndex { MSyntax.identifier($0.name) == edit.previous } ?? (edit.index - 1)
            return try? await engine.evaluatePreview(name, upToStep: index, rowLimit: QueryEditorSession.previewRows).table
        }
        if name == session.selectedQuery?.name, !asNew, let current = session.preview { return current.table }
        return try? await engine.evaluatePreview(name, rowLimit: QueryEditorSession.previewRows).table
    }

    private func load() {
        left = session.selectedQuery?.name ?? tables.first?.name ?? ""
        if case .mergeQueries(let other, let lk, let rk, let k, _, let fz)? = edit?.transform {
            right = other; leftKeys = lk; rightKeys = rk; kind = k
            if let fz { fuzzy = true; options = fz; maxMatches = fz.maximumMatches ?? 0; transformation = fz.transformationTable ?? "" }
        } else {
            right = tables.first { $0.name != left }?.name ?? ""
            leftKeys = session.selectedColumns
        }
    }

    private func done() {
        var fz: FuzzyMergeOptions?
        if fuzzy {
            var o = options
            o.maximumMatches = maxMatches > 0 ? maxMatches : nil
            o.transformationTable = transformation.isEmpty ? nil : transformation
            fz = o
        }
        let taken = leftTable?.columnNames ?? []
        var column = QueryEditorPlans.uniqueColumnName(right, taken: taken)
        if case .mergeQueries(_, _, _, _, let existing, _)? = edit?.transform { column = existing }
        let t = Transform.mergeQueries(other: right, leftKeys: leftKeys, rightKeys: rightKeys, kind: kind, newColumn: column, fuzzy: fz)
        if asNew {
            let name = QueryEditorPlans.newQueryName("Merge", taken: session.queryNames)
            let script = MScript.script(from: [MStep(name: "Source", expression: t.expression(previous: MSyntax.identifier(left)))])
            session.addQuery(QueryDefinition(name: name, mScript: script), name: "Merge Queries as New")
        } else {
            session.commit(t, editing: edit)
        }
        dismiss()
    }
}

// MARK: - Append

struct AppendQueriesDialog: View {
    @ObservedObject var session: QueryEditorSession
    let asNew: Bool
    let edit: StepEdit?
    @State private var many = false
    @State private var primary = ""
    @State private var chosen: [String] = []
    @State private var second = ""
    @Environment(\.dismiss) private var dismiss

    private var tables: [String] { session.queries.filter { $0.kind == .table }.map(\.name) }
    private var others: [String] { many ? chosen : [second] }

    var body: some View {
        DialogChrome(title: "Append", subtitle: "Concatenate rows from two or more tables; columns are matched by name.",
                     canCommit: !others.isEmpty && !others.contains("") && (!asNew || !primary.isEmpty), width: 520, commit: done) {
            Picker("Mode", selection: $many) { Text("Two tables").tag(false); Text("Three or more tables").tag(true) }.pickerStyle(.segmented).labelsHidden()
            if asNew {
                Picker("Primary table", selection: $primary) { ForEach(tables, id: \.self) { Text($0).tag($0) } }
            } else {
                Text("Primary table: \(primary)").font(Design.Typeface.bodyStrong)
            }
            if many {
                HStack(alignment: .top, spacing: Design.Space.m) {
                    list("Available tables", tables.filter { !chosen.contains($0) }) { chosen.append($0) }
                    list("Tables to append", chosen) { t in chosen.removeAll { $0 == t } }
                }
                .frame(height: 200)
            } else {
                Picker("Table to append", selection: $second) { ForEach(tables, id: \.self) { Text($0).tag($0) } }
            }
        }
        .onAppear {
            primary = session.selectedQuery?.name ?? tables.first ?? ""
            if case .appendQueries(let list)? = edit?.transform {
                many = list.count > 1; chosen = list; second = list.first ?? ""
            } else {
                second = tables.first { $0 != primary } ?? ""
            }
        }
    }

    private func list(_ title: String, _ items: [String], _ tap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            Text(title).font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                        Text(t).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                            .onTapGesture { tap(t) }.help("Click to move")
                    }
                }
            }
            .padding(Design.Space.xs)
            .background(Design.Palette.elevated)
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Design.Palette.hairline))
        }
    }

    private func done() {
        let t = Transform.appendQueries(others)
        if asNew {
            let name = QueryEditorPlans.newQueryName("Append", taken: session.queryNames)
            let script = MScript.script(from: [MStep(name: "Source", expression: t.expression(previous: MSyntax.identifier(primary)))])
            session.addQuery(QueryDefinition(name: name, mScript: script), name: "Append Queries as New")
        } else {
            session.commit(t, editing: edit)
        }
        dismiss()
    }
}
