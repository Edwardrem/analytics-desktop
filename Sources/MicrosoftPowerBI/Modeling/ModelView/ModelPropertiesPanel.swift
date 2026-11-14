import SwiftUI
import FacetCore
import FacetDesign

/// Pure helpers of the Properties panel.
enum ModelProperties {
    /// "a, b ,c" → ["a", "b", "c"]: trimmed, blanks and case-insensitive repeats dropped.
    static func synonyms(from text: String) -> [String] {
        var out: [String] = []
        for part in text.split(separator: ",") {
            let s = part.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, !out.contains(where: { ModelDAX.same($0, s) }) { out.append(s) }
        }
        return out
    }

    /// What the panel edits: every selected object of the primary object's kind, so several
    /// columns (or measures, or tables) can be changed together. The primary object comes last.
    static func targets(_ selection: [ModelObjectRef]) -> [ModelObjectRef] {
        guard let primary = selection.last else { return [] }
        func kind(_ r: ModelObjectRef) -> Int {
            switch r {
            case .table: return 0
            case .column: return 1
            case .measure: return 2
            case .relationship: return 3
            default: return 4
            }
        }
        if kind(primary) == 4 { return [primary] }
        return selection.filter { kind($0) == kind(primary) }
    }

    /// The value every item shares, or nil when they differ (shown as "Mixed").
    static func shared<T: Equatable>(_ values: [T]) -> T? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// A text field that writes when the user commits (Return or leaving the field), so typing does
/// not put a document change on the undo stack per keystroke.
struct CommitField: View {
    let value: String
    var placeholder = ""
    var multiline = false
    /// Writes the text; returns false when it was refused, and the field goes back to `value`.
    let commit: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    init(value: String, placeholder: String = "", multiline: Bool = false, commit: @escaping (String) -> Void) {
        self.value = value; self.placeholder = placeholder; self.multiline = multiline
        self.commit = { commit($0); return true }
    }
    /// For names: `rename` reports whether the new name was accepted.
    init(value: String, rename: @escaping (String) -> Bool) {
        self.value = value
        self.commit = rename
    }

    var body: some View {
        Group {
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(2...5)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(Design.Typeface.caption)
        .focused($focused)
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
        .onSubmit(apply)
    }

    private func apply() {
        guard text != value else { return }
        if !commit(text) { text = value }
    }
}

/// The Properties panel of Model view: the selected table, column, measure or relationship.
struct ModelPropertiesPanel: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var modeling: ModelingState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Properties").font(Design.Typeface.bodyStrong)
                Spacer(minLength: 0)
                if targets.count > 1 { Text("\(targets.count) selected").font(Design.Typeface.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, Design.Space.m)
            .frame(height: 32)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.small)
    }

    private var targets: [ModelObjectRef] { ModelProperties.targets(modeling.selection) }

    @ViewBuilder
    private var content: some View {
        switch targets.last {
        case .table(let name)?:
            if let table = store.model.table(name) { tableProperties(table) } else { gone }
        case .column?:
            let columns = targets.compactMap { ref -> (table: String, column: ModelColumn)? in
                guard case .column(let t, let n) = ref, let table = store.model.table(t), let c = table.column(n) else { return nil }
                return (table.name, c)
            }
            if columns.isEmpty { gone } else { columnProperties(columns) }
        case .measure?:
            let measures = targets.compactMap { ref -> (table: String, measure: Measure)? in
                guard case .measure(let t, let n) = ref, let table = store.model.table(t), let m = table.measure(n) else { return nil }
                return (table.name, m)
            }
            if measures.isEmpty { gone } else { measureProperties(measures) }
        case .relationship(let id)?:
            if let r = store.model.relationships.first(where: { $0.id == id }) { relationshipProperties(r) } else { gone }
        case let other?:
            note(ModelExplorerItems.caption(for: other, in: store.model) ?? "This object no longer exists.",
                 "\(ModelOps.noun(other)). It has no properties to edit here.")
        case nil:
            summary
        }
    }

    private var gone: some View { note("Nothing selected", "The selected object is no longer in the model.") }

    private var summary: some View {
        let model = store.model
        return note("Nothing selected",
                    "Select a table, a column, a measure or a relationship line to see and change its properties.\n\n"
                    + "\(model.tables.count) table\(model.tables.count == 1 ? "" : "s"), "
                    + "\(model.relationships.count) relationship\(model.relationships.count == 1 ? "" : "s"), "
                    + "\(model.allMeasures.count) measure\(model.allMeasures.count == 1 ? "" : "s").")
    }

    private func note(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text(title).font(Design.Typeface.bodyStrong)
            Text(message).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.m)
    }

    private func problem(_ ref: ModelObjectRef) -> some View {
        Group {
            if let message = ModelOps.error(for: ref, in: store) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Table

    private func tableProperties(_ table: ModelTable) -> some View {
        let name = table.name
        func set(_ title: String, invalidates: Invalidation = .layout, _ change: @escaping (inout ModelTable) -> Void) {
            ModelOps.updateTable(store, name, name: title, invalidates: invalidates, change)
        }
        return Group {
            InspectorSection("General") {
                PropertyRow("Name") { CommitField(value: name, rename: { ModelOps.renameTable(store, name, to: $0) }) }
                PropertyRow("Description") { CommitField(value: table.description, multiline: true) { v in set("Change Description") { $0.description = v } } }
                PropertyRow("Synonyms") {
                    CommitField(value: table.synonyms.joined(separator: ", "), placeholder: "Comma-separated") { v in
                        set("Change Synonyms") { $0.synonyms = ModelProperties.synonyms(from: v) }
                    }
                }
                PropertyRow("Row label") { columnPicker("Row label", table: table, value: table.rowLabelColumn) { v in set("Change Row Label") { $0.rowLabelColumn = v } } }
                PropertyRow("Key column") { columnPicker("Key column", table: table, value: table.keyColumn) { v in set("Change Key Column") { $0.keyColumn = v } } }
                Toggle("Hidden in report view", isOn: Binding(get: { table.isHidden }, set: { _ in ModelOps.toggleHidden(store, .table(name)) }))
                Toggle("Featured table", isOn: Binding(get: { table.isFeatured }, set: { v in set("Change Featured Table") { $0.isFeatured = v } }))
                problem(.table(name))
            }
            InspectorSection("Advanced") {
                PropertyRow("Storage mode") { StorageModeControl(table: table) }
                PropertyRow("Source") {
                    Text(table.isCalculated ? "Calculated table" : table.sourceQuery.map { "Query “\($0)”" } ?? "Loaded data")
                        .font(Design.Typeface.caption)
                }
                if table.isDateTable, let date = table.dateColumn {
                    PropertyRow("Date table") { Text("Marked on \(date)").font(Design.Typeface.caption) }
                }
                PropertyRow("Contents") {
                    Text("\(table.columns.count) column\(table.columns.count == 1 ? "" : "s"), \(table.measures.count) measure\(table.measures.count == 1 ? "" : "s")")
                        .font(Design.Typeface.caption)
                }
                if table.isCalculated {
                    Button("Edit formula…") { ModelOps.beginFormula(store, kind: .table, editing: name) }
                        .help("Edit the DAX expression of this calculated table")
                }
            }
        }
    }

    private func columnPicker(_ label: String, table: ModelTable, value: String?, set: @escaping (String?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { table.column(value ?? "")?.name ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
            Text("None").tag("")
            ForEach(table.columns) { Text($0.name).tag($0.name) }
        }
        .labelsHidden()
    }

    // MARK: Column

    private func columnProperties(_ columns: [(table: String, column: ModelColumn)]) -> some View {
        let refs = columns.map { (table: $0.table, name: $0.column.name) }
        let single = columns.count == 1 ? columns.first : nil
        func set(_ title: String, coalesce: String? = nil, invalidates: Invalidation = .layout, _ change: @escaping (inout ModelColumn) -> Void) {
            ModelOps.updateColumns(store, refs, name: title, coalesce: coalesce, invalidates: invalidates, change)
        }
        let hidden = ModelProperties.shared(columns.map(\.column.isHidden))
        return Group {
            InspectorSection("General") {
                if let single {
                    PropertyRow("Name") { CommitField(value: single.column.name, rename: { ModelOps.renameColumn(store, table: single.table, single.column.name, to: $0) }) }
                    PropertyRow("Table") { Text(single.table).font(Design.Typeface.caption) }
                }
                PropertyRow("Description") {
                    CommitField(value: ModelProperties.shared(columns.map(\.column.description)) ?? "", placeholder: single == nil ? "Mixed" : "", multiline: true) { v in
                        set("Change Description") { $0.description = v }
                    }
                }
                PropertyRow("Synonyms") {
                    CommitField(value: (ModelProperties.shared(columns.map(\.column.synonyms)) ?? []).joined(separator: ", "), placeholder: "Comma-separated") { v in
                        set("Change Synonyms") { $0.synonyms = ModelProperties.synonyms(from: v) }
                    }
                }
                PropertyRow("Display folder") {
                    CommitField(value: ModelProperties.shared(columns.map(\.column.displayFolder)) ?? "", placeholder: single == nil ? "Mixed" : "") { v in
                        set("Change Display Folder") { $0.displayFolder = v.trimmingCharacters(in: .whitespaces) }
                    }
                }
                Toggle(hidden == nil ? "Hidden in report view (mixed)" : "Hidden in report view",
                       isOn: Binding(get: { hidden ?? false }, set: { v in set("Hide in Report View") { $0.isHidden = v } }))
                if let single { problem(.column(table: single.table, name: single.column.name)) }
            }
            InspectorSection("Formatting") {
                if let single {
                    PropertyRow("Data type") { menu(single.column.dataType.displayName, ColumnMenus.dataType(store, table: single.table, column: single.column)) }
                }
                PropertyRow("Format") {
                    FormatControls(format: ModelProperties.shared(columns.map(\.column.formatString)),
                                   dataType: ModelProperties.shared(columns.map(\.column.dataType)) ?? .any) { format in
                        set("Format Column", coalesce: "format-columns", invalidates: .model) { $0.formatString = format }
                    }
                }
            }
            InspectorSection("Advanced") {
                if let single, let table = store.model.table(single.table) {
                    PropertyRow("Sort by column") { menu(single.column.sortByColumn ?? "Default", ColumnMenus.sortBy(store, table: table, column: single.column)) }
                    PropertyRow("Data category") { menu(ModelGlyph.label(for: single.column.dataCategory), ColumnMenus.dataCategory(store, table: single.table, column: single.column)) }
                    PropertyRow("Summarize by") {
                        menu(single.column.summarizeBy == .none ? Aggregation.none.displayName : single.column.summarizeBy.label(for: single.column.dataType),
                             ColumnMenus.summarizeBy(store, table: single.table, column: single.column))
                    }
                    Toggle("Key column", isOn: Binding(get: { single.column.isKey }, set: { v in set("Change Key Column", invalidates: .model) { $0.isKey = v } }))
                        .help("Marks the column that identifies each row")
                    Toggle("Is nullable", isOn: Binding(get: { single.column.isNullable }, set: { v in set("Change Nullable") { $0.isNullable = v } }))
                    if single.column.isCalculated {
                        Button("Edit formula…") { ModelOps.beginFormula(store, kind: .column, table: single.table, editing: single.column.name) }
                            .help("Edit the DAX expression of this calculated column")
                    }
                } else {
                    Text("Select one column to change its sort order, category and summarization.")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func menu(_ title: String, _ entries: [ModelMenuEntry]) -> some View {
        Menu { ModelMenuItems(entries: entries) } label: { Text(title).lineLimit(1) }
            .menuStyle(.borderlessButton)
            .fixedSize()
    }

    // MARK: Measure

    private func measureProperties(_ measures: [(table: String, measure: Measure)]) -> some View {
        let refs = measures.map { (table: $0.table, name: $0.measure.name) }
        let single = measures.count == 1 ? measures.first : nil
        func set(_ title: String, coalesce: String? = nil, invalidates: Invalidation = .layout, _ change: @escaping (inout Measure) -> Void) {
            ModelOps.updateMeasures(store, refs, name: title, coalesce: coalesce, invalidates: invalidates, change)
        }
        let hidden = ModelProperties.shared(measures.map(\.measure.isHidden))
        return Group {
            InspectorSection("General") {
                if let single {
                    PropertyRow("Name") { CommitField(value: single.measure.name, rename: { ModelOps.renameMeasure(store, table: single.table, single.measure.name, to: $0) }) }
                    PropertyRow("Home table") { menu(single.table, ColumnMenus.homeTable(store, table: single.table, measure: single.measure)) }
                }
                PropertyRow("Description") {
                    CommitField(value: ModelProperties.shared(measures.map(\.measure.description)) ?? "", placeholder: single == nil ? "Mixed" : "", multiline: true) { v in
                        set("Change Description") { $0.description = v }
                    }
                }
                PropertyRow("Display folder") {
                    CommitField(value: ModelProperties.shared(measures.map(\.measure.displayFolder)) ?? "", placeholder: single == nil ? "Mixed" : "") { v in
                        set("Change Display Folder") { $0.displayFolder = v.trimmingCharacters(in: .whitespaces) }
                    }
                }
                Toggle(hidden == nil ? "Hidden in report view (mixed)" : "Hidden in report view",
                       isOn: Binding(get: { hidden ?? false }, set: { v in set("Hide in Report View") { $0.isHidden = v } }))
                if let single { problem(.measure(table: single.table, name: single.measure.name)) }
            }
            InspectorSection("Formatting") {
                PropertyRow("Format") {
                    FormatControls(format: ModelProperties.shared(measures.map(\.measure.formatString)), dataType: .decimal,
                                   dynamic: single.map { s in .init(isOn: s.measure.formatExpression != nil) {
                                       DynamicFormat.edit(store, table: s.table, measure: s.measure.name)
                                   } }) { format in
                        set("Format Measure", coalesce: "format-measures", invalidates: .model) { $0.formatString = format; $0.formatExpression = nil }
                    }
                }
                PropertyRow("Data category") {
                    let category = ModelProperties.shared(measures.map(\.measure.dataCategory))
                    Menu {
                        ForEach(DataCategory.allCases, id: \.self) { c in
                            Button { set("Change Data Category") { $0.dataCategory = c } } label: {
                                if category == c { Label(ModelGlyph.label(for: c), systemImage: "checkmark") } else { Text(ModelGlyph.label(for: c)) }
                            }
                        }
                    } label: { Text(category.map(ModelGlyph.label(for:)) ?? "Mixed").lineLimit(1) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if let single {
                InspectorSection("Formula") {
                    Text(single.measure.expression).font(Design.Typeface.mono).foregroundStyle(.secondary)
                        .lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Edit formula…") { ModelOps.beginFormula(store, kind: .measure, table: single.table, editing: single.measure.name) }
                        .help("Edit the DAX expression of this measure")
                }
            }
        }
    }

    // MARK: Relationship

    private func relationshipProperties(_ relationship: Relationship) -> some View {
        InspectorSection("Relationship") {
            Text(RelationshipOps.caption(relationship)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RelationshipForm(relationship: Binding(get: { relationship }, set: { change in
                let edited = RelationshipLogic.retargeted(change, model: store.model)
                // An end without a column to offer is an edit in progress: wait for the column.
                guard !edited.fromColumn.isEmpty, !edited.toColumn.isEmpty else {
                    store.status = StatusMessage(kind: .info, text: "Choose the column to relate in \(edited.fromColumn.isEmpty ? edited.fromTable : edited.toTable).")
                    return
                }
                if let message = RelationshipOps.update(store, edited) { store.status = StatusMessage(kind: .warning, text: message) }
            }))
            Button("Delete relationship", role: .destructive) { RelationshipOps.delete(store, relationship.id) }
                .help("Remove this relationship from the model")
        }
    }
}
