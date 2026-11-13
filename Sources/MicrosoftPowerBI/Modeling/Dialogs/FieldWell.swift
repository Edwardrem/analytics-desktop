import SwiftUI
import FacetCore
import FacetDesign

/// Which model fields a well accepts.
enum FieldWellFilter {
    case any, columns, measures, dateColumns
    /// Something that produces a number: a measure or a column (aggregated).
    case values

    func accepts(_ f: FieldRef, model: SemanticModel) -> Bool {
        switch self {
        case .any, .values: return true
        case .columns: return f.kind == .column
        case .measures: return f.kind == .measure
        case .dateColumns: return f.kind == .column && (model.table(f.table)?.column(f.name)?.dataType.isTemporal ?? false)
        }
    }
    var hint: String {
        switch self {
        case .any: return "Add a field"
        case .columns: return "Add a column"
        case .measures: return "Add a measure"
        case .dateColumns: return "Add a date column"
        case .values: return "Add a measure or column"
        }
    }
}

/// A drop target for model fields with a picker menu. Accepts drags from the Data pane (`FieldDrag`)
/// and holds one field or an ordered list.
struct FieldWell: View {
    @EnvironmentObject private var store: DocumentStore
    let title: String
    @Binding var fields: [FieldRef]
    var filter: FieldWellFilter = .any
    var allowsMultiple = false
    /// Columns get an aggregation menu (for wells that need a number).
    var aggregates = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty { Text(title).font(Design.Typeface.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in row(field, index: index) }
                if fields.isEmpty || allowsMultiple {
                    FieldPickerMenu(filter: filter, excluding: allowsMultiple ? fields : []) { add($0) } label: {
                        HStack(spacing: Design.Space.xs) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                            Text(filter.hint).font(Design.Typeface.caption)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Design.Space.s).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Design.Palette.fill))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor.opacity(0.6) : .clear))
            .dropDestination(for: String.self) { items, _ in
                let dropped = items.compactMap(FieldDrag.decode).filter { filter.accepts($0, model: store.model) }
                guard !dropped.isEmpty else { return false }
                for f in (allowsMultiple ? dropped : [dropped[0]]) { add(f) }
                return true
            } isTargeted: { targeted = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.isEmpty ? "Field well" : title)
    }

    private func add(_ field: FieldRef) {
        guard filter.accepts(field, model: store.model) else { return }
        var f = field
        f.id = UUID()
        if aggregates, f.kind == .column, f.aggregation == .none { f.aggregation = store.defaultAggregation(for: f) }
        if allowsMultiple {
            if !fields.contains(where: { $0.kind == f.kind && ModelDAX.same($0.table, f.table) && ModelDAX.same($0.name, f.name) }) { fields.append(f) }
        } else {
            fields = [f]
        }
    }

    private func row(_ field: FieldRef, index: Int) -> some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: field.kind == .measure ? "function" : "tablecells")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(field.name).font(Design.Typeface.body).lineLimit(1)
            Text(field.table).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            if aggregates, field.kind == .column {
                Menu {
                    ForEach(Aggregation.allCases.filter { $0 != .none }, id: \.self) { a in
                        Button(a.displayName) { fields[index].aggregation = a }
                    }
                } label: { Text(field.aggregation.displayName).font(Design.Typeface.caption) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Summarization")
            }
            if allowsMultiple, fields.count > 1 {
                FieldWellGlyphButton("chevron.up", help: "Move up", disabled: index == 0) { fields.swapAt(index, index - 1) }
                FieldWellGlyphButton("chevron.down", help: "Move down", disabled: index == fields.count - 1) { fields.swapAt(index, index + 1) }
            }
            FieldWellGlyphButton("xmark", help: "Remove \(field.name)") { fields.remove(at: index) }
        }
        .padding(.horizontal, Design.Space.s).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control - 1, style: .continuous).fill(Design.Palette.elevated))
    }
}

/// Tiny borderless glyph button used inside rows.
struct FieldWellGlyphButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    init(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.disabled = disabled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled).opacity(disabled ? 0.35 : 1)
        .help(help).accessibilityLabel(help)
    }
}

/// A menu of the model's tables → columns and measures.
struct FieldPickerMenu<Label: View>: View {
    @EnvironmentObject private var store: DocumentStore
    var filter: FieldWellFilter = .any
    var excluding: [FieldRef] = []
    let onPick: (FieldRef) -> Void
    @ViewBuilder var label: () -> Label

    private func fields(in t: ModelTable) -> [FieldRef] {
        let cols = t.columns.map { FieldRef.column(t.name, $0.name) }
        let measures = t.measures.map { FieldRef.measure(t.name, $0.name) }
        return (cols + measures).filter { f in
            filter.accepts(f, model: store.model) && !excluding.contains { $0.kind == f.kind && $0.table == f.table && $0.name == f.name }
        }
    }

    var body: some View {
        Menu {
            let tables = store.model.tables.map { ($0, fields(in: $0)) }.filter { !$0.1.isEmpty }
            if tables.isEmpty { Text("No matching fields") }
            ForEach(tables, id: \.0.id) { table, list in
                Menu(table.name) {
                    ForEach(list) { f in
                        Button { onPick(f) } label: { SwiftUI.Label(f.name, systemImage: f.kind == .measure ? "function" : "tablecells") }
                    }
                }
            }
        } label: { label() }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

/// A DAX editor bound to document content: edits a local draft, validates it (debounced 300 ms) and
/// commits through `commit` once typing pauses, so each burst of typing is one undoable change.
struct ModelingDAXEditor: View {
    @EnvironmentObject private var store: DocumentStore
    /// The value currently stored in the document.
    let text: String
    var kind: ExpressionKind? = .measure
    var homeTable: String?
    var height: CGFloat = 120
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var lastCommitted: String?
    @State private var issues: [ExpressionIssue] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            CodeEditor(text: $draft, language: .dax, model: store.model, issues: issues)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.elevated))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).strokeBorder(Design.Palette.hairlineStrong))
            if let issue = issues.first {
                Label(issue.message, systemImage: issue.isWarning ? "exclamationmark.triangle" : "exclamationmark.circle")
                    .font(Design.Typeface.caption)
                    .foregroundStyle(issue.isWarning ? Design.Palette.caution : Design.Palette.negative)
                    .lineLimit(2)
            }
        }
        .onAppear { if !loaded { loaded = true; draft = text } }
        .onChange(of: text) { _, new in if new != lastCommitted, new != draft { draft = new } }
        .task(id: draft) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled || !loaded { return }
            let current = draft
            if current != text { lastCommitted = current; commit(current) }
            guard let kind, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { issues = []; return }
            let home = homeTable
            let found = await store.withEngine { $0.check(current, kind: kind, homeTable: home) }
            if !Task.isCancelled { issues = found }
        }
    }
}
