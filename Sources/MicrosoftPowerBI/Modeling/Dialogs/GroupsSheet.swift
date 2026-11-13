import SwiftUI
import FacetCore
import FacetDesign

/// Groups and bins: collect a column's values into named groups, or bin numbers and dates by size or count.
struct GroupsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    /// Name of the group column being edited; nil when creating.
    let editing: String?
    let sourceType: DataType
    @State private var draft: GroupDraft
    @State private var distinct: [Value] = []
    @State private var range: (min: Double, max: Double)?
    @State private var picked: Set<Value> = []
    @State private var targetGroup: UUID?
    @State private var loaded = false

    init(table: ModelTable, source: ModelColumn, existing: ModelColumn? = nil) {
        self.table = table.name
        self.editing = existing?.name
        self.sourceType = source.dataType
        _draft = State(initialValue: GroupingLogic.draft(source: source, existing: existing, table: table))
    }

    private var modelTable: ModelTable { store.model.table(table) ?? ModelTable(name: table) }
    private var problems: [String] { GroupingLogic.problems(draft, table: modelTable, editing: editing, sourceType: sourceType) }
    private var binnable: Bool { sourceType.isNumeric || sourceType == .date || sourceType == .dateTime }

    var body: some View {
        ModelingSheet(title: editing == nil ? "Groups" : "Edit groups", subtitle: "A new column in \(table) built from \(draft.source).",
                      width: 700, height: 540) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                HStack(alignment: .bottom, spacing: Design.Space.l) {
                    ModelField("Name") { TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 240) }
                    ModelField("Field") { Text(draft.source).font(Design.Typeface.body).frame(height: 22) }
                    ModelField("Group type") {
                        Picker("Group type", selection: $draft.mode) {
                            ForEach(GroupDraft.Mode.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 100).disabled(!binnable)
                    }
                }
                Hairline()
                if draft.mode == .list { listEditor } else { binEditor }
            }
            .padding(Design.Space.l)
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "OK", confirmDisabled: !problems.isEmpty, confirm: save)
        }
        .task { await load() }
    }

    // MARK: List

    private var listEditor: some View {
        HStack(alignment: .top, spacing: Design.Space.l) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("Ungrouped values").font(Design.Typeface.caption).foregroundStyle(.secondary)
                let values = GroupingLogic.ungrouped(distinct, draft: draft)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !loaded { ProgressView().controlSize(.small).padding(Design.Space.s) }
                        ForEach(Array(values.enumerated()), id: \.offset) { _, v in valueRow(v) }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
                HStack {
                    Button("Group") { targetGroup = GroupingLogic.group(orderedPicked, in: &draft); picked = [] }
                        .disabled(picked.isEmpty)
                    Button("Add to Group") { if let g = targetGroup { GroupingLogic.add(orderedPicked, to: g, in: &draft); picked = [] } }
                        .disabled(picked.isEmpty || targetGroup == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("Groups and members").font(Design.Typeface.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Design.Space.xs) {
                        ForEach($draft.groups) { $g in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: Design.Space.xs) {
                                    Image(systemName: targetGroup == g.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(targetGroup == g.id ? Color.accentColor : .secondary)
                                        .onTapGesture { targetGroup = g.id }
                                        .help("Add picked values to this group")
                                        .accessibilityLabel("Target \(g.name)")
                                    TextField("Group name", text: $g.name).textFieldStyle(.plain).font(Design.Typeface.bodyStrong)
                                    FieldWellGlyphButton("xmark", help: "Ungroup \(g.name)") { GroupingLogic.ungroup(group: g.id, in: &draft) }
                                }
                                ForEach(Array(g.members.enumerated()), id: \.offset) { _, m in
                                    HStack(spacing: Design.Space.xs) {
                                        Text(label(m)).font(Design.Typeface.body).lineLimit(1).padding(.leading, 20)
                                        Spacer(minLength: 0)
                                        FieldWellGlyphButton("minus", help: "Remove \(label(m)) from \(g.name)") { GroupingLogic.ungroup(value: m, in: &draft) }
                                    }
                                }
                            }
                            .padding(Design.Space.xs)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
                HStack {
                    Toggle("Include Other group", isOn: $draft.includeOther).toggleStyle(.checkbox)
                        .help("Put every ungrouped value into one group")
                    if draft.includeOther { TextField("Other", text: $draft.otherName).textFieldStyle(.roundedBorder).frame(width: 110) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var orderedPicked: [Value] { distinct.filter(picked.contains) }
    private func label(_ v: Value) -> String { v.isNull ? "(Blank)" : v.asString }

    private func valueRow(_ v: Value) -> some View {
        let on = picked.contains(v)
        return HStack(spacing: Design.Space.s) {
            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
            Text(label(v)).font(Design.Typeface.body).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.s).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if on { picked.remove(v) } else { picked.insert(v) } }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Bins

    private var binEditor: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Picker("Bin type", selection: $draft.bySize) {
                Text("Size of bins").tag(true)
                Text("Number of bins").tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if draft.bySize {
                HStack(spacing: Design.Space.s) {
                    ModelField("Bin size") {
                        TextField("10", value: $draft.binSize, format: .number).textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    if sourceType.isTemporal {
                        ModelField("Unit") {
                            Picker("Unit", selection: Binding(get: { draft.unit ?? .day }, set: { draft.unit = $0 })) {
                                ForEach(ColumnGrouping.BinUnit.allCases.reversed(), id: \.self) { Text($0.rawValue.capitalized + "s").tag($0) }
                            }.labelsHidden().frame(width: 120)
                        }
                    }
                }
            } else {
                ModelField("Bin count") {
                    TextField("10", value: $draft.binCount, format: .number).textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
            if let range {
                let lo = sourceType.isTemporal ? String(DateParsing.isoString(Value.date(fromSerial: range.min)).prefix(10)) : ModelDAX.number(range.min)
                let hi = sourceType.isTemporal ? String(DateParsing.isoString(Value.date(fromSerial: range.max)).prefix(10)) : ModelDAX.number(range.max)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Minimum \(lo), maximum \(hi).")
                    if draft.bySize, !sourceType.isTemporal, draft.binSize > 0 {
                        Text("\(GroupingLogic.binCount(size: draft.binSize, minimum: range.min, maximum: range.max).formatted()) bins. Each value falls in the multiple of \(ModelDAX.number(draft.binSize)) at or below it.")
                    } else if !draft.bySize, draft.binCount >= 1, !sourceType.isTemporal {
                        Text("Each bin is \(ModelDAX.number(GroupingLogic.binSize(count: draft.binCount, minimum: range.min, maximum: range.max))) wide.")
                    }
                }
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Data

    private func load() async {
        let data = DialogTarget.data(store)
        let key = data.tables.keys.first { ModelDAX.same($0, table) }
        let values = key.flatMap { data.tables[$0]?.column(draft.source)?.values } ?? []
        let (list, bounds) = await Task.detached(priority: .userInitiated) { () -> ([Value], (Double, Double)?) in
            var seen = Set<Value>()
            var out: [Value] = []
            var lo = Double.infinity, hi = -Double.infinity
            for v in values {
                if seen.insert(v).inserted, out.count < 5000 { out.append(v) }
                var isDate = false
                if case .date = v { isDate = true }
                if isDate || v.isNumber, let d = v.asDouble { lo = min(lo, d); hi = max(hi, d) }
            }
            out.sort { a, b in a.asString.localizedStandardCompare(b.asString) == .orderedAscending }
            return (out, lo <= hi ? (lo, hi) : nil)
        }.value
        distinct = list
        range = bounds.map { (min: $0.0, max: $0.1) }
        if editing == nil, draft.mode == .bins, !sourceType.isTemporal, let range {
            draft.binSize = GroupingLogic.suggestedSize(minimum: range.min, maximum: range.max)
        }
        loaded = true
    }

    private func save() {
        guard problems.isEmpty else { return }
        var d = draft
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = sourceType
        var target = editing
        // Renaming goes through the model-wide rename so visuals and formulas follow the column.
        if let original = editing, original != d.name, ModelOps.renameColumn(store, table: table, original, to: d.name) { target = d.name }
        store.mutate(editing == nil ? "New Group" : "Edit Group", invalidates: .model) { doc in
            guard let t = doc.model.tableIndex(table) else { return }
            if let target, let c = doc.model.tables[t].columns.firstIndex(where: { ModelDAX.same($0.name, target) }) {
                doc.model.tables[t].columns[c] = GroupingLogic.column(from: d, sourceType: type, keeping: doc.model.tables[t].columns[c])
            } else {
                doc.model.tables[t].columns.append(GroupingLogic.column(from: d, sourceType: type))
            }
        }
        store.modeling.select(.column(table: table, name: d.name))
        store.dismissSheet()
    }
}
