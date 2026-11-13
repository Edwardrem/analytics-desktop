import SwiftUI
import FacetCore
import FacetDesign

/// Name rules shared by every modeling dialog.
enum ModelNames {
    /// Why `name` can't be used for a `noun`, given the names already taken (quoted as they are spelled); nil when it is fine.
    static func problem(_ name: String, noun: String, others: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name the \(noun)." }
        if let taken = others.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { ModelDAX.same($0, trimmed) }) {
            return "Another \(noun) is already named “\(taken)”."
        }
        return nil
    }
    /// The first name that appears more than once (case-insensitively), if any.
    static func firstDuplicate(_ names: [String]) -> String? {
        var seen = Set<String>()
        for n in names {
            let key = n.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !seen.insert(key).inserted { return n.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }
    /// "Table" or "Table[Name]".
    static func identifier(table: String, name: String? = nil) -> String { name.map { "\(table)[\($0)]" } ?? table }
    /// Splits "Table" / "Table[Member]" identifiers (the form roles, perspectives, captions and the AI schema use).
    static func split(_ identifier: String) -> (table: String, member: String?) {
        guard identifier.hasSuffix("]"), let open = identifier.firstIndex(of: "[") else { return (identifier, nil) }
        let member = identifier[identifier.index(after: open)..<identifier.index(before: identifier.endIndex)]
        return (String(identifier[..<open]), String(member))
    }
    /// True when the identifier still names something in the model.
    static func exists(_ identifier: String, in model: SemanticModel) -> Bool {
        let (table, member) = split(identifier)
        guard let t = model.table(table) else { return false }
        guard let member else { return true }
        return t.column(member) != nil || t.measure(member) != nil || t.hierarchies.contains { ModelDAX.same($0.name, member) }
    }
}

/// What a dialog command should act on: the Data pane's right-clicked table or field when the
/// command came from there, otherwise the modeling selection.
@MainActor
enum DialogTarget {
    static func table(_ store: DocumentStore) -> String? {
        if let t = FieldPaneContext.table ?? FieldPaneContext.field?.table, let found = store.model.table(t) { return found.name }
        return ModelingTarget.table(store)
    }
    static func column(_ store: DocumentStore) -> (table: String, name: String)? {
        if let f = FieldPaneContext.field {
            guard f.kind == .column, store.model.table(f.table)?.column(f.name) != nil else { return nil }
            return (f.table, f.name)
        }
        if FieldPaneContext.table != nil { return nil }
        return ModelingTarget.column(store)
    }
    static func measure(_ store: DocumentStore) -> (table: String, name: String)? {
        if let f = FieldPaneContext.field {
            guard f.kind == .measure, let found = store.model.measure(f.name) else { return nil }
            return (found.table.name, found.measure.name)
        }
        return ModelingTarget.measure(store)
    }
    /// The data the dialogs validate against: computed tables when the engine has run, else source data.
    static func data(_ store: DocumentStore) -> DataStore {
        store.computedData.tables.isEmpty ? store.doc.data : store.computedData
    }
}

// MARK: - Small views shared by the dialogs

/// The line above a dialog's buttons: the first problem in red, else a warning, else nothing.
struct DialogProblemLine: View {
    var problem: String?
    var warning: String?
    var body: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.circle")
                .font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        } else if let warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A table picker over the model's tables.
struct ModelTablePicker: View {
    @EnvironmentObject private var store: DocumentStore
    let label: String
    @Binding var selection: String
    var allowsNone = false
    var tables: [ModelTable]?
    var body: some View {
        Picker(label, selection: $selection) {
            if allowsNone || selection.isEmpty { Text("—").tag("") }
            ForEach(tables ?? store.model.tables) { t in Text(t.name).tag(t.name) }
        }
        .labelsHidden()
    }
}

/// A column picker over one table's columns.
struct ModelColumnPicker: View {
    @EnvironmentObject private var store: DocumentStore
    let label: String
    let table: String
    @Binding var selection: String
    var allowsNone = false
    var filter: (ModelColumn) -> Bool = { _ in true }
    var body: some View {
        Picker(label, selection: $selection) {
            if allowsNone || selection.isEmpty { Text("—").tag("") }
            ForEach((store.model.table(table)?.columns ?? []).filter(filter)) { c in Text(c.name).tag(c.name) }
        }
        .labelsHidden()
    }
}

/// A checklist of the model's tables and their fields, used by perspectives, object-level security
/// and the AI data schema. `isOn`/`toggle` receive "Table" or "Table[Member]" identifiers.
struct ModelObjectChecklist: View {
    @EnvironmentObject private var store: DocumentStore
    var includeMeasures = true
    var includeHierarchies = false
    let state: (String) -> PerspectiveLogic.Inclusion
    let toggle: (String) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.model.tables) { t in
                    HStack(spacing: Design.Space.xs) {
                        Button {
                            if !expanded.insert(t.name).inserted { expanded.remove(t.name) }
                        } label: {
                            Image(systemName: expanded.contains(t.name) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 14, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(expanded.contains(t.name) ? "Collapse \(t.name)" : "Expand \(t.name)")
                        check(t.name, title: t.name, symbol: ModelGlyph.symbol(for: t), strong: true)
                    }
                    if expanded.contains(t.name) {
                        ForEach(t.columns) { c in
                            check(ModelNames.identifier(table: t.name, name: c.name), title: c.name, symbol: ModelGlyph.symbol(for: c))
                                .padding(.leading, 34)
                        }
                        if includeMeasures {
                            ForEach(t.measures) { m in
                                check(ModelNames.identifier(table: t.name, name: m.name), title: m.name, symbol: ModelGlyph.measure)
                                    .padding(.leading, 34)
                            }
                        }
                        if includeHierarchies {
                            ForEach(t.hierarchies) { h in
                                check(ModelNames.identifier(table: t.name, name: h.name), title: h.name, symbol: ModelGlyph.hierarchy)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
            }
            .padding(Design.Space.s)
        }
    }

    private func check(_ id: String, title: String, symbol: String, strong: Bool = false) -> some View {
        let s = state(id)
        return Button { toggle(id) } label: {
            HStack(spacing: Design.Space.s) {
                Image(systemName: s == .all ? "checkmark.square.fill" : (s == .some ? "minus.square.fill" : "square"))
                    .foregroundStyle(s == .none ? Color.secondary : Color.accentColor)
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                Text(title).font(strong ? Design.Typeface.bodyStrong : Design.Typeface.body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(s == .all ? "included" : (s == .some ? "partly included" : "not included"))
    }
}
