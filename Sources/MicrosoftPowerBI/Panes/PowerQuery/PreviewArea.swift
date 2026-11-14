import SwiftUI
import AppKit
import FacetCore
import FacetDesign
import FacetQuery

/// The data preview of the selected step: the grid with column quality / distribution strips, or the step's value
/// when it is not a table, or its error.
struct PreviewArea: View {
    @ObservedObject var session: QueryEditorSession

    var body: some View {
        Group {
            if session.queries.isEmpty {
                emptyFile
            } else if let q = session.selectedQuery, q.kind == .parameter {
                ParameterSummary(session: session, query: q)
            } else if let error = session.previewError {
                errorView(error)
            } else if let preview = session.preview {
                switch preview.valueKind {
                case "table": grid(preview)
                case "list", "record":
                    VStack(spacing: 0) {
                        shapeBanner(preview.valueKind)
                        Hairline()
                        grid(preview)
                    }
                default: scalar(preview)
                }
            } else if session.selectedQuery == nil {
                EmptyState(systemImage: "tablecells", title: "Select a query")
            } else {
                ProgressView("Evaluating…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFile: some View {
        VStack(spacing: Design.Space.m) {
            EmptyState(systemImage: "wand.and.rays", title: "No queries yet", message: "Connect to a source, type a table, or start from a blank query.")
                .frame(height: 160)
            HStack {
                Button("New Source…") { session.dialog = .newSource }
                Button("Enter Data…") { session.dialog = .enterData }
                Button("Blank Query") { session.newBlankQuery() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grid(_ preview: QueryPreview) -> some View {
        QueryGrid(
            table: preview.table, cellErrors: preview.cellErrors, structuredCells: preview.structuredCells,
            selection: Set(session.selectedColumns), profiles: session.profiles,
            showQuality: session.showQuality, showDistribution: session.showDistribution,
            onSelect: { name, toggle, range in session.clickColumn(name, toggle: toggle, range: range) },
            headerMenu: { name in focus(name); return EditorMenus.menu(EditorMenus.headerEntries, session: session) },
            contextMenu: { name in focus(name); return EditorMenus.menu(EditorMenus.contextEntries, session: session) },
            typeMenu: { name in
                focus(name)
                return EditorMenus.menu(DataTypeCommands.types.map { .command(DataTypeCommands.id($0.type)) } + [.divider, .command("pq.typeLocale")], session: session)
            },
            onOpenCell: { row, column in drill(row: row, column: column, in: preview) },
            monospaced: session.monospaced, showWhitespace: session.showWhitespace)
    }

    /// A click on a header that is not selected selects it first (as Power Query does before showing a menu).
    private func focus(_ column: String) {
        if !session.selectedColumns.contains(column) { session.selectedColumns = [column] }
    }

    /// Clicking a Table / Record / List cell navigates into it: `Previous{row}[Column]`.
    private func drill(row: Int, column: Int, in preview: QueryPreview) {
        guard let name = preview.table.columnNames[safe: column] else { return }
        let rowSelector = preview.valueKind == "table" ? "{\(row)}" + MSyntax.field(name) : (preview.valueKind == "list" ? "{\(row)}" : MSyntax.field(preview.table.column("Name")?.values[safe: row]?.asString ?? name))
        session.applyStep(named: name == "Value" ? "Navigation" : name) { $0 + rowSelector }
    }

    private func shapeBanner(_ kind: String) -> some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: kind == "list" ? "list.bullet" : "curlybraces").foregroundStyle(.secondary)
            Text(kind == "list" ? "This step returns a list." : "This step returns a record.").font(Design.Typeface.caption)
            Spacer()
            Button(kind == "list" ? "To Table" : "Into Table") { EditorCommands.command("pq.toTable")?.run(session) }.controlSize(.small)
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
    }

    private func scalar(_ preview: QueryPreview) -> some View {
        let value = preview.table.columns.first?.values.first ?? .null
        let type = preview.table.columns.first?.type ?? .any
        return VStack(spacing: Design.Space.s) {
            Text(QueryCellText.text(value, type: type)).font(.system(size: 22, weight: .light)).textSelection(.enabled)
            Text(preview.valueKind).font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Label(session.currentStep.map { "Error in step “\($0.name)”" } ?? "Error", systemImage: "exclamationmark.triangle.fill")
                .font(Design.Typeface.bodyStrong).foregroundStyle(Design.Palette.caution)
            Text(error).font(Design.Typeface.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if session.selectedStep != nil {
                Button("Go to Last Step") { session.selectStep(nil) }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Parameter

private struct ParameterSummary: View {
    @ObservedObject var session: QueryEditorSession
    let query: QueryDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(query.name).font(Design.Typeface.headline)
            if !query.description.isEmpty { Text(query.description).font(Design.Typeface.caption).foregroundStyle(.secondary) }
            if let p = query.parameter {
                PropertyRow("Type") { Text(p.type.displayName) }
                PropertyRow("Current value") { Text(QueryCellText.text(p.currentValue, type: p.type)).textSelection(.enabled) }
                if !p.suggestedValues.isEmpty {
                    PropertyRow("Suggested") { Text(p.suggestedValues.map { QueryCellText.text($0, type: p.type) }.joined(separator: ", ")).lineLimit(2) }
                }
                PropertyRow("Required") { Text(p.isRequired ? "Yes" : "No") }
            }
            Button("Manage Parameter…") { session.dialog = .manageParameters(select: query.id) }.controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(Design.Space.l)
        .frame(maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Column profile

/// View ▸ Column profile: statistics and the value distribution of the selected column.
struct ColumnProfilePanel: View {
    @ObservedObject var session: QueryEditorSession

    private var profile: ColumnProfile? {
        guard let name = session.selectedColumns.first else { return nil }
        return session.profiles.first { $0.column == name }
    }

    var body: some View {
        if let profile, let type = session.preview?.table.column(profile.column)?.type {
            HStack(alignment: .top, spacing: Design.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Column statistics").font(Design.Typeface.captionStrong)
                    ForEach(Array(Self.statistics(profile, type: type).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.1).monospacedDigit().textSelection(.enabled)
                        }
                        .font(Design.Typeface.caption)
                    }
                }
                .frame(width: 240)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Value distribution").font(Design.Typeface.captionStrong)
                    distribution(profile, type: type)
                }
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Select a column to see its profile.").font(Design.Typeface.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Power Query's column statistics list.
    static func statistics(_ p: ColumnProfile, type: DataType) -> [(String, String)] {
        func v(_ x: Value) -> String { QueryCellText.text(x, type: type) }
        func n(_ d: Double?) -> String { d.map { String(format: "%.6g", $0) } ?? "" }
        var rows: [(String, String)] = [
            ("Count", "\(p.count)"), ("Error", "\(p.errorCount)"), ("Empty", "\(p.emptyCount - p.emptyTextCount)"),
            ("Empty string", "\(p.emptyTextCount)"), ("Distinct", "\(p.distinctCount)"), ("Unique", "\(p.uniqueCount)"),
            ("Min", v(p.minimum)), ("Max", v(p.maximum)),
        ]
        if p.average != nil {
            rows += [("Average", n(p.average)), ("Standard deviation", n(p.standardDeviation)), ("NaN", "\(p.nanCount ?? 0)"),
                     ("Zero", "\(p.zeroCount ?? 0)"), ("Even", "\(p.evenCount ?? 0)"), ("Odd", "\(p.oddCount ?? 0)")]
        }
        return rows
    }

    private func distribution(_ p: ColumnProfile, type: DataType) -> some View {
        let bars = Array(p.distribution.prefix(40))
        let top = max(bars.map(\.count).max() ?? 1, 1)
        return ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    VStack(spacing: 2) {
                        Text("\(bar.count)").font(.system(size: 9)).foregroundStyle(.secondary)
                        Design.Palette.accent.opacity(0.75)
                            .frame(width: 18, height: max(2, 110 * CGFloat(bar.count) / CGFloat(top)))
                        Text(QueryCellText.text(bar.value, type: type)).font(.system(size: 9)).lineLimit(1).frame(width: 34)
                    }
                    .help("\(QueryCellText.text(bar.value, type: type)): \(bar.count)")
                }
            }
            .frame(height: 150, alignment: .bottom)
        }
    }
}
