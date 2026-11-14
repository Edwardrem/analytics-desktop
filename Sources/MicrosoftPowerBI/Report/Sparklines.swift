import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// Sparklines in table and matrix cells: a value (Y axis) drawn along a field (X axis) for every
/// row of the table, or every row and column of the matrix (with its subtotals and totals).
///
/// Each sparkline is an extra column of the table. Its definition lives in the table renderer's
/// contract, `format["sparklines"][<column name>] = { type, by }`, with the value and axis fields
/// kept alongside so the visual query can compute the series.
struct Sparkline: Equatable, Identifiable {
    enum Kind: String, CaseIterable { case line, column }
    /// The column the table shows ("Total by Month").
    var name: String
    /// What is drawn: a measure or a summarized column.
    var value: FieldRef
    /// Along what: a column (usually a date or a period).
    var axis: FieldRef
    var kind: Kind = .line
    var id: String { name }

    static let card = "sparklines"
    /// The same sparkline: fields compare by what they refer to, not by their well identity.
    static func == (a: Sparkline, b: Sparkline) -> Bool {
        a.name == b.name && a.kind == b.kind && a.value.key == b.value.key && a.axis.key == b.axis.key
    }
    static func defaultName(value: FieldRef, axis: FieldRef) -> String { "\(value.caption) by \(axis.caption)" }

    var json: JSONValue {
        .object(["type": .string(kind.rawValue), "by": .string(axis.name),
                 "value": Self.encode(value), "axis": Self.encode(axis)])
    }

    init(name: String, value: FieldRef, axis: FieldRef, kind: Kind = .line) {
        self.name = name; self.value = value; self.axis = axis; self.kind = kind
    }

    /// A definition read back from the format card; nil when it lacks either field.
    init?(name: String, json: JSONValue) {
        guard let value = Self.decode(json["value"]), let axis = Self.decode(json["axis"]) else { return nil }
        self.init(name: name, value: value, axis: axis, kind: Kind(rawValue: json["type"]?.stringValue ?? "") ?? .line)
    }

    private static func encode(_ f: FieldRef) -> JSONValue {
        .object(["kind": .string(f.kind.rawValue), "table": .string(f.table), "name": .string(f.name),
                 "aggregation": .string(f.aggregation.rawValue)])
    }
    private static func decode(_ j: JSONValue?) -> FieldRef? {
        guard let j, let kind = j["kind"]?.stringValue.flatMap(FieldRef.Kind.init(rawValue:)),
              let table = j["table"]?.stringValue, let name = j["name"]?.stringValue else { return nil }
        return FieldRef(kind: kind, table: table, name: name,
                        aggregation: j["aggregation"]?.stringValue.flatMap(Aggregation.init(rawValue:)) ?? .none)
    }
}

enum Sparklines {
    static func supports(_ type: VisualType) -> Bool { type == .table || type == .matrix }

    /// The sparklines a visual defines, in name order.
    static func list(_ spec: VisualSpec) -> [Sparkline] {
        (spec.format[Sparkline.card] ?? [:]).compactMap { Sparkline(name: $0.key, json: $0.value) }.sorted { $0.name < $1.name }
    }

    /// Adds or replaces a sparkline (`replacing` names the one being edited, when renamed).
    static func set(_ s: Sparkline, replacing old: String? = nil, on spec: inout VisualSpec) {
        if let old, old != s.name { spec.setFmt(Sparkline.card, old, nil) }
        spec.setFmt(Sparkline.card, s.name, s.json)
    }
    static func remove(_ name: String, from spec: inout VisualSpec) { spec.setFmt(Sparkline.card, name, nil) }

    /// A name for a new sparkline that no column of the visual already uses.
    static func uniqueName(_ base: String, in spec: VisualSpec) -> String {
        let taken = Set(list(spec).map(\.name) + spec.allFields.map(\.caption))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// The series of every row group, from a result grouped by the row fields (its first `keys`
    /// columns) and the axis. Points are ordered along the axis — by its sort-by column when there is
    /// one — and blank values are left out.
    static func series(_ table: DataTable, keys: Int, axis: Int, sort: Int?, value: Int) -> [[Value]: [Double]] {
        guard table.columnCount > max(keys - 1, axis, sort ?? 0, value) else { return [:] }
        var points: [[Value]: [(order: Value, value: Double)]] = [:]
        for r in 0..<table.rowCount {
            guard let v = table[r, value].asDouble, v.isFinite else { continue }
            let key = (0..<keys).map { table[r, $0] }
            let order = sort.map { table[r, $0] }.flatMap { $0.isNull ? nil : $0 } ?? table[r, axis]
            points[key, default: []].append((order, v))
        }
        return points.mapValues { $0.sorted { $0.order < $1.order }.map(\.value) }
    }

    /// The series of every row group at each point of the axis across the whole result (nil where
    /// the group has no value there), so a matrix can combine the rows under a subtotal point by
    /// point. Points are ordered along the axis as in `series`.
    static func alignedSeries(_ table: DataTable, keys: Int, axis: Int, sort: Int?, value: Int) -> [[Value]: [Double?]] {
        guard table.columnCount > max(keys - 1, axis, sort ?? 0, value) else { return [:] }
        func order(_ r: Int) -> Value { sort.map { table[r, $0] }.flatMap { $0.isNull ? nil : $0 } ?? table[r, axis] }
        var orders = Set<Value>()
        for r in 0..<table.rowCount where table[r, value].asDouble?.isFinite == true { orders.insert(order(r)) }
        let position = Dictionary(uniqueKeysWithValues: orders.sorted().enumerated().map { ($1, $0) })
        var out: [[Value]: [Double?]] = [:]
        for r in 0..<table.rowCount {
            guard let v = table[r, value].asDouble, v.isFinite, let p = position[order(r)] else { continue }
            let key = (0..<keys).map { table[r, $0] }
            if out[key] == nil { out[key] = [Double?](repeating: nil, count: position.count) }
            out[key]?[p] = v
        }
        return out
    }

    /// The cell text the table renderer draws as a sparkline: "1.0|2.5|3.0".
    static func cell(_ values: [Double]) -> Value {
        .string(values.map { "\($0)" }.joined(separator: "|"))
    }

    /// Adds one column per sparkline to a table visual's result: for each row, the value along the
    /// axis under that row's fields and the visual's filters. `query` runs a DAX query.
    static func append(to result: inout DataTable, roles: inout [String: [Int]], fields: inout [FieldRef?], formats: inout [String],
                       spec: VisualSpec, groups: [FieldRef], filters: [String], model: SemanticModel,
                       query: (String) throws -> DataTable?) throws {
        guard supports(spec.type) else { return }
        func same(_ a: FieldRef, _ b: FieldRef) -> Bool { a.kind == b.kind && ModelDAX.same(a.table, b.table) && ModelDAX.same(a.name, b.name) }
        for s in list(spec) {
            var args = groups.map { ModelDAX.reference($0) }
            // An axis the table already groups by gives each row a single point.
            let axis: Int
            if let i = groups.firstIndex(where: { same($0, s.axis) }) { axis = i } else {
                axis = args.count
                args.append(ModelDAX.reference(s.axis))
            }
            var sort: Int?
            if s.axis.kind == .column, let by = model.table(s.axis.table)?.column(s.axis.name)?.sortByColumn {
                if let i = groups.firstIndex(where: { same($0, .column(s.axis.table, by)) }) { sort = i } else {
                    sort = args.count
                    args.append(ModelDAX.column(s.axis.table, by))
                }
            }
            let value = args.count
            args += filters
            args += [ModelDAX.string("__sparkline"), ModelDAX.aggregate(s.value, model: model)]
            let dax = "EVALUATE\n    SUMMARIZECOLUMNS(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
            let table = try query(dax) ?? DataTable()
            let values: [Value]
            if spec.type == .matrix {
                let byRow = alignedSeries(table, keys: groups.count, axis: axis, sort: sort, value: value)
                values = (0..<result.rowCount).map { r in MatrixSparkline.encode(byRow[(0..<groups.count).map { result[r, $0] }] ?? []) }
            } else {
                let byRow = series(table, keys: groups.count, axis: axis, sort: sort, value: value)
                values = (0..<result.rowCount).map { r in cell(byRow[(0..<groups.count).map { result[r, $0] }] ?? []) }
            }
            roles[Well.values.rawValue, default: []].append(result.columnCount)
            result.columns.append(DataColumn(name: s.name, type: .text, values: values))
            fields.append(nil)
            formats.append("")
        }
    }
}

// MARK: - Add a sparkline

extension DocumentStore {
    /// The table the sparkline commands act on.
    var sparklineTarget: VisualSpec? {
        guard view == .report, let v = selectedVisual, Sparklines.supports(v.type), !v.fields(.values).isEmpty else { return nil }
        return v
    }
}

/// The "Add a sparkline" dialog: what to draw (Y axis), along what (X axis), and as what; plus the table's existing sparklines.
struct SparklineSheet: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    @State private var value: FieldRef?
    @State private var summarization: Aggregation = .sum
    @State private var axis: FieldRef?
    @State private var kind: Sparkline.Kind = .line
    @State private var editing: String?

    private var spec: VisualSpec? { store.visual(visualID) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text(editing == nil ? "Add a sparkline" : "Edit sparkline").font(Design.Typeface.headline)
            PaneNote(spec?.type == .matrix
                     ? "A small chart in every cell of the matrix: the value along the axis, for that row and column, with totals."
                     : "A small chart in every row of the table: the value along the axis, for that row.")
            PropertyRow("Y-axis") {
                FieldPickerButton(selection: value, placeholder: "Choose a value", allowsClear: false) { picked in
                    guard var f = picked else { return }
                    if f.kind == .column { f.aggregation = store.defaultAggregation(for: f) }
                    if f.kind == .column, f.aggregation == .none { f.aggregation = .count }
                    value = f
                    if f.kind == .column { summarization = f.aggregation }
                }
            }
            if value?.kind == .column {
                PropertyRow("Summarization") {
                    Picker("Summarization", selection: $summarization) {
                        ForEach(Aggregation.allCases.filter { $0 != .none }, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            PropertyRow("X-axis") {
                FieldPickerButton(selection: axis, placeholder: "Choose a field", allowsMeasures: false, allowsClear: false) { axis = $0 }
            }
            PropertyRow("Type") {
                Picker("Type", selection: $kind) {
                    Text("Line").tag(Sparkline.Kind.line)
                    Text("Column").tag(Sparkline.Kind.column)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            existing
            HStack {
                Spacer()
                Button("Cancel") { store.dismissSheet() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value == nil || axis == nil)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 380)
        .onAppear(perform: prefill)
    }

    @ViewBuilder private var existing: some View {
        if let spec, !Sparklines.list(spec).isEmpty {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                SectionLabel(spec.type == .matrix ? "Sparklines in this matrix" : "Sparklines in this table")
                ForEach(Sparklines.list(spec)) { s in
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: s.kind == .line ? "chart.xyaxis.line" : "chart.bar").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(s.name).font(Design.Typeface.body).lineLimit(1)
                        Spacer(minLength: 0)
                        MiniIconButton("pencil", help: "Edit \(s.name)") { load(s) }
                        MiniIconButton("trash", help: "Remove \(s.name)") {
                            store.updateVisual(visualID, name: "Remove Sparkline") { Sparklines.remove(s.name, from: &$0) }
                            if editing == s.name { editing = nil }
                        }
                    }
                }
            }
        }
    }

    /// Start from the table's first value and a date column it does not show, as Power BI does.
    private func prefill() {
        guard let spec else { return }
        value = spec.fields(.values).first { $0.isAggregate }
        if let v = value, v.kind == .column { summarization = v.aggregation }
        let shown = Set(spec.allFields.map { "\($0.table)|\($0.name)" })
        let dates = store.model.tables.flatMap { t in t.columns.filter { $0.dataType.isTemporal && !$0.isHidden }.map { (t.name, $0.name) } }
        if let d = dates.first(where: { !shown.contains("\($0.0)|\($0.1)") }) ?? dates.first { axis = .column(d.0, d.1) }
    }

    private func load(_ s: Sparkline) {
        editing = s.name; value = s.value; axis = s.axis; kind = s.kind
        if s.value.kind == .column { summarization = s.value.aggregation }
    }

    private func save() {
        guard var v = value, let axis, let spec else { return }
        if v.kind == .column { v.aggregation = summarization }
        v.id = UUID()
        let base = Sparkline.defaultName(value: v, axis: axis)
        var probe = spec
        if let editing { Sparklines.remove(editing, from: &probe) }
        let sparkline = Sparkline(name: Sparklines.uniqueName(base, in: probe), value: v, axis: axis, kind: kind)
        let old = editing
        store.updateVisual(visualID, name: old == nil ? "Add Sparkline" : "Edit Sparkline") { Sparklines.set(sparkline, replacing: old, on: &$0) }
        store.dismissSheet()
    }
}
