import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

/// Renders the four AI visuals — Key influencers, Decomposition tree, Narrative and Q&A — with the
/// FacetAnalytics engines. Registered as `VisualExtensions.provider` by `AIFeature`.
enum AIVisuals {
    @MainActor
    static func provider(spec: VisualSpec, data: VisualData, context: VisualContext, store: DocumentStore) -> AnyView? {
        switch spec.type {
        case .keyInfluencers: return AnyView(KeyInfluencersView(spec: spec, data: data, context: context, store: store))
        case .decompositionTree: return AnyView(DecompositionTreeView(spec: spec, data: data, context: context, store: store))
        case .narrative: return AnyView(NarrativeView(spec: spec, data: data, context: context, store: store))
        case .qna: return AnyView(QnAView(spec: spec, data: data, context: context, store: store))
        default: return nil
        }
    }
}

// MARK: - Key influencers

struct KeyInfluencersView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let store: DocumentStore

    @State private var result: KeyInfluencersResult?
    @State private var targetOptions: [Value] = []
    @State private var targetValue: Value?
    @State private var direction: KeyInfluencers.Direction = .increase
    @State private var selected: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var loadedFor = ""

    private var targetField: FieldRef? { spec.fields(.analyze).first }
    private var explainFields: [FieldRef] { spec.fields(.explainBy) }
    private var isCategorical: Bool {
        guard let target = targetField, target.kind == .column else { return false }
        let type = store.computedData[target.table]?.column(target.name)?.type
        return type == .text || type == .boolean
    }
    private var cacheKey: String {
        let explain = explainFields.map(\.key).joined(separator: "|")
        let tv = targetValue.map(\.asString) ?? ""
        // The visual's own query carries the page's filters, so a new filter context reruns the analysis.
        return "\(targetField?.key ?? "")|\(tv)|\(direction.rawValue)|\(explain)|\(data.table.rowCount)|\(data.daxQuery)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            header
            if targetField == nil || explainFields.isEmpty {
                EmptyState(systemImage: "arrow.up.arrow.down.circle", title: "Key influencers",
                           message: "Add a field to Analyze (the metric to explain) and fields to Explain by.")
            } else if loading {
                ProgressView("Analyzing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState(systemImage: "exclamationmark.triangle", title: "Analysis failed", message: error)
            } else if let result {
                resultView(result)
            }
        }
        .padding(Design.Space.s)
        .task(id: cacheKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: Design.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                if let target = targetField {
                    Text("What influences \(target.caption)").font(Design.Typeface.headline)
                }
                if !explainFields.isEmpty {
                    Text("Explained by \(explainFields.map(\.caption).joined(separator: ", "))")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isCategorical, !targetOptions.isEmpty {
                Picker("Target value", selection: $targetValue) {
                    ForEach(targetOptions, id: \.self) { v in Text(v.asString).tag(Optional(v)) }
                }
                .labelsHidden().controlSize(.small)
                .help("Which value of the target to explain")
            } else if !isCategorical {
                Picker("Direction", selection: $direction) {
                    Text("Influences up").tag(KeyInfluencers.Direction.increase)
                    Text("Influences down").tag(KeyInfluencers.Direction.decrease)
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .help("Whether to explain what raises or lowers the metric")
            }
        }
    }

    private func resultView(_ r: KeyInfluencersResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                if r.influencers.isEmpty {
                    Text("No significant influencers were found in this data.")
                        .font(Design.Typeface.body).foregroundStyle(.secondary)
                } else {
                    ForEach(r.influencers.indices, id: \.self) { i in
                        influencerCard(r.influencers[i], rank: i + 1)
                    }
                }
                if !r.segments.isEmpty {
                    Text("Top segments").font(Design.Typeface.headline)
                    ForEach(r.segments.indices, id: \.self) { i in
                        segmentRow(r.segments[i])
                    }
                }
            }
            .padding(.bottom, Design.Space.m)
        }
    }

    private func influencerCard(_ inf: Influencer, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text("#\(rank)").font(Design.Typeface.captionStrong).foregroundStyle(.tertiary)
                Text(inf.sentence).font(Design.Typeface.body).lineLimit(3)
                Spacer(minLength: 0)
                statBadge(inf)
            }
            HStack(spacing: Design.Space.s) {
                Text("\(inf.support) rows").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Text("p \(pText(inf.pValue))").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            if selected == rank - 1, !inf.distribution.isEmpty {
                distributionBars(inf.distribution)
            }
            Hairline()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Design.Motion.quick) { selected = selected == rank - 1 ? nil : rank - 1 } }
    }

    private func statBadge(_ inf: Influencer) -> some View {
        let text: String
        switch inf.kind {
        case .category, .bin: text = inf.multiplier.map { String(format: "%.2f×", $0) } ?? ""
        case .perUnit: text = inf.difference.map { String(format: "%+.1f", $0) } ?? ""
        }
        guard !text.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(Text(text).font(Design.Typeface.captionStrong)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14))))
    }

    private func distributionBars(_ points: [Influencer.DistributionPoint]) -> some View {
        let maxvalue = points.map(\.value).max() ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(points.indices, id: \.self) { i in
                let p = points[i]
                HStack(spacing: Design.Space.xs) {
                    Text(p.label).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .trailing)
                    Capsule().fill(p.isHighlighted ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: max(3, CGFloat(p.value / max(maxvalue, 1e-12)) * 140), height: 12)
                    Text(p.isHighlighted ? "" : "").font(Design.Typeface.caption)
                    Spacer()
                    Text("\(p.count)").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, 18)
    }

    private func segmentRow(_ s: Segment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.sentence).font(Design.Typeface.body).lineLimit(3)
            HStack(spacing: Design.Space.s) {
                Text("\(s.size) rows").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Text(__pct(s.share)).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Text(String(format: "%.2f× lift", s.lift)).font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            Hairline()
        }
    }

    private func pText(_ p: Double) -> String { p < 0.001 ? "< 0.001" : String(format: "%.3f", p) }

    // MARK: Analysis

    private func load() async {
        guard let target = targetField, !explainFields.isEmpty else { return }
        let key = cacheKey
        guard loadedFor != key else { return }
        loading = true
        error = nil
        loadedFor = key
        defer { loading = false }

        // Build the flat analysis table.
        var analysis: (DataTable, String)?
        if target.kind == .column {
            // The rows the page's filters, slicers and selections leave, as Power BI analyses them.
            let request = store.request(for: spec, on: store.currentPage), table = target.table
            let rows = await store.withEngine { engine in Result { try engine.rows(of: table, request: request) } }
            switch rows {
            case .success(let base):
                analysis = Self.flatTable(target: target, explain: explainFields, base: base,
                                          baseTable: target.table, model: store.model, data: store.computedData)
            case .failure(let failure):
                result = nil
                error = (failure as? LocalizedError)?.errorDescription ?? "\(failure)"
                return
            }
        } else if data.table.rowCount > 0 {
            analysis = Self.gridTable(data: data)
        }
        guard case (var table, let targetColumn)? = analysis, table.rowCount >= 20 else {
            result = nil
            error = target.kind == .column
                ? "Key influencers needs at least 20 rows to analyze. This data has fewer."
                : "Key influencers needs at least 20 rows to analyze. Put a column in Analyze, or add more Explain by fields."
            return
        }
        if table.rowCount > 20000 { table = table.prefix(20000) }

        // Target kind, options and default value.
        guard let targetCol = table.column(targetColumn) else {
            result = nil
            error = "The target column is missing from the data."
            return
        }
        let nonNull = targetCol.values.filter { !$0.isNull }
        let categorical = targetCol.type == .text || targetCol.type == .boolean
            || Set(nonNull.map(\.asString)).count <= 2 && nonNull.allSatisfy { !$0.isNumber }
        var options: [Value] = []
        if categorical {
            var counts: [Value: Int] = [:]
            for v in nonNull { counts[v, default: 0] += 1 }
            options = counts.keys.sorted { ($0.asString) < ($1.asString) }
        }
        targetOptions = options
        if categorical {
            if targetValue == nil || !options.contains(targetValue!) {
                // Default to the minority class (e.g. churned = yes).
                var counts: [Value: Int] = [:]
                for v in nonNull { counts[v, default: 0] += 1 }
                targetValue = counts.min { $0.value == $1.value ? $0.key.asString < $1.key.asString : $0.value < $1.value }?.key
            }
        }

        do {
            result = try KeyInfluencers.analyze(table: table, target: targetColumn, targetValue: categorical ? targetValue : nil,
                                                direction: direction, explainBy: table.columnNames.filter { $0 != targetColumn })
            selected = nil
        } catch {
            result = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// The flat row-level table for a column target: the target table's rows plus explain-by
    /// columns, joined from related tables through the model's relationships.
    static func flatTable(target: FieldRef, explain: [FieldRef], base: DataTable, baseTable: String,
                          model: SemanticModel, data: DataStore) -> (DataTable, String)? {
        guard let targetCol = base.column(target.name) else { return nil }
        var names = [target.name]
        var columns: [[Value]] = [targetCol.values]
        for f in explain where f.name != target.name {
            let name = f.name
            if base.column(name) != nil, f.table == baseTable {
                guard !names.contains(name) else { continue }
                names.append(name)
                columns.append(base.column(name)!.values)
            } else if let values = relatedValues(f, base: base, baseTable: baseTable, model: model, data: data),
                      !names.contains(name) {
                names.append(name)
                columns.append(values)
            }
        }
        let rows = (0..<base.rowCount).map { r in columns.map { $0[safe: r] ?? .null } }
        return (DataTable(name: baseTable, columnNames: names, rows: rows), target.name)
    }

    /// Values of a column from a related table, mapped onto the base table's rows via the relationship keys.
    static func relatedValues(_ field: FieldRef, base: DataTable, baseTable: String,
                              model: SemanticModel, data: DataStore) -> [Value]? {
        guard let other = data[field.table] else { return nil }
        guard let rel = model.relationships.first(where: {
            ($0.fromTable == baseTable && $0.toTable == field.table) || ($0.toTable == baseTable && $0.fromTable == field.table)
        }) else { return nil }
        let baseKeyName = rel.fromTable == baseTable ? rel.fromColumn : rel.toColumn
        let otherKeyName = rel.fromTable == baseTable ? rel.toColumn : rel.fromColumn
        guard let baseKey = base.column(baseKeyName), let otherKey = other.column(otherKeyName),
              let fieldCol = other.column(field.name) else { return nil }
        var lookup: [Value: Value] = [:]
        for i in 0..<other.rowCount {
            let k = otherKey.values[i]
            if lookup[k] == nil { lookup[k] = fieldCol.values[i] }
        }
        return baseKey.values.map { lookup[$0] ?? .null }
    }

    /// For a measure target: the visual's aggregated grid (measure by explain-by combinations).
    static func gridTable(data: VisualData) -> (DataTable, String)? {
        guard let analyzeIdx = data.indices(.analyze).first else { return nil }
        let explainIdx = data.indices(.explainBy)
        guard !explainIdx.isEmpty else { return nil }
        var names: [String] = []
        var columns: [[Value]] = []
        for i in explainIdx {
            let name = data.fields[safe: i]?.flatMap { $0 }?.caption ?? data.table.columns[safe: i]?.name ?? "Column \(i)"
            names.append(name)
            columns.append(data.table.columns[i].values)
        }
        let targetName = data.fields[safe: analyzeIdx]?.flatMap { $0 }?.caption ?? data.table.columns[analyzeIdx].name
        names.append(targetName)
        columns.append(data.table.columns[analyzeIdx].values)
        let rows = (0..<data.table.rowCount).map { r in columns.map { $0[safe: r] ?? .null } }
        return (DataTable(name: "Analysis", columnNames: names, rows: rows), targetName)
    }
}

// MARK: - Decomposition tree

struct DecompositionTreeView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let store: DocumentStore

    struct Step: Hashable {
        let dimension: FieldRef
        let value: Value
        /// Basic filter selecting this member.
        var filter: FilterSpec {
            var f = FilterSpec(field: dimension)
            f.values = [value]
            return f
        }
    }
    struct Row: Identifiable {
        let id = UUID()
        let depth: Int
        let dimension: FieldRef        // the dimension this level breaks down by
        let path: [Step]               // filters from the root to this node's parent
        let value: Value               // the member's value
        let amount: Double
        let share: Double?
        var expanded = false
        var note: String?
    }

    @State private var rows: [Row] = []
    @State private var total: Double?
    @State private var loading: Set<String> = []
    @State private var error: String?
    @State private var loadedFor = ""

    private var analyze: FieldRef? { spec.fields(.analyze).first }
    private var dimensions: [FieldRef] { spec.fields(.explainBy) }
    private var dataToken: Int { data.table.rowCount &+ data.table.columnCount }
    private var loadedKey: String { "\(analyze?.key ?? "")|\(dimensions.map(\.key).joined(separator: "|"))|\(dataToken)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            if analyze == nil || dimensions.isEmpty {
                EmptyState(systemImage: "arrow.triangle.branch", title: "Decomposition tree",
                           message: "Add a measure to Analyze and fields to Explain by.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState(systemImage: "exclamationmark.triangle", title: "Analysis failed", message: error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tree
            }
        }
        .task(id: loadedKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: Design.Space.s) {
            if let a = analyze { Text(a.caption).font(Design.Typeface.headline) }
            if let total { Text(__num(total)).font(Design.Typeface.headline).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                }
                if !loading.isEmpty { ProgressView().padding(Design.Space.m) }
            }
            .padding(.bottom, Design.Space.m)
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Design.Space.xs) {
                Text(String(repeating: "    ", count: row.depth))
                    .font(Design.Typeface.mono) + Text("")
                Button {
                    toggle(row)
                } label: {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(availableDimensions(for: row).isEmpty && !row.expanded)
                Text(row.value.asString.isEmpty ? "(Blank)" : row.value.asString)
                    .font(Design.Typeface.body).lineLimit(1)
                Spacer(minLength: 0)
                if let share = row.share {
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(4, CGFloat(share) * 120), height: 10)
                    Text(__pct(share)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                Text(__num(row.amount)).font(Design.Typeface.body).monospacedDigit()
            }
            if let note = row.note {
                Text(note).font(Design.Typeface.caption).foregroundStyle(.secondary).padding(.leading, 30)
            }
            Hairline()
        }
        .padding(.leading, CGFloat(row.depth) * 0)
        .contextMenu { menu(row) }
    }

    @ViewBuilder
    private func menu(_ row: Row) -> some View {
        ForEach(availableDimensions(for: row), id: \.key) { dim in
            Button("Expand by \(dim.caption)") { expand(row, by: dim) }
        }
        Divider()
        Button("Find high value") { aiSplit(row, high: true) }
        Button("Find low value") { aiSplit(row, high: false) }
        Divider()
        Button("Clear below") { collapse(row) }
    }

    // MARK: Loading

    private func load() async {
        guard analyze != nil, !dimensions.isEmpty else { return }
        guard loadedFor != loadedKey else { return }
        loadedFor = loadedKey
        error = nil
        rows = []
        total = nil
        // Root total.
        if let v = await value(at: []) { total = v }
        // First level: break down by the first explain-by dimension.
        if let first = dimensions.first, let kids = await children(path: [], by: first) {
            rows = kids
        }
    }

    private func value(at path: [Step]) async -> Double? {
        let dax = Self.totalQuery(measure: analyze!, path: path, filters: visualFilters, model: store.model)
        let result: Result<[DataTable], Error> = await store.withEngine { engine in Result { try engine.query(dax) } }
        guard case .success(let tables) = result, let t = tables.first, t.rowCount > 0, t.columnCount > 0 else { return nil }
        return t[0, 0].asDouble
    }

    private func children(path: [Step], by dimension: FieldRef) async -> [Row]? {
        let dax = Self.childQuery(dimension: dimension, path: path, measure: analyze!, model: store.model, filters: visualFilters)
        let result: Result<[DataTable], Error> = await store.withEngine { engine in Result { try engine.query(dax) } }
        guard case .success(let tables) = result, let t = tables.first, t.columnCount >= 2 else { return nil }
        var kids: [Row] = []
        let totalAmount = (0..<t.rowCount).compactMap { t[$0, 1].asDouble }.reduce(0, +)
        for r in 0..<t.rowCount {
            guard let amount = t[r, 1].asDouble, amount.isFinite else { continue }
            let v = t[r, 0]
            kids.append(Row(depth: path.count, dimension: dimension, path: path, value: v, amount: amount,
                            share: totalAmount != 0 ? amount / totalAmount : nil))
        }
        kids.sort { a, b in a.amount == b.amount ? a.value.asString < b.value.asString : a.amount > b.amount }
        return kids
    }

    private var visualFilters: [FilterSpec] {
        store.request(for: spec, on: store.currentPage).filters
    }

    // MARK: Interaction

    private func toggle(_ row: Row) {
        if row.expanded { collapse(row) } else { defaultExpand(row) }
    }

    private func defaultExpand(_ row: Row) {
        let available = availableDimensions(for: row)
        guard let dim = available.first else { return }
        expand(row, by: dim)
    }

    private func availableDimensions(for row: Row) -> [FieldRef] {
        let used = Set((row.path + [Step(dimension: row.dimension, value: row.value)]).map { $0.dimension.key })
        return dimensions.filter { !used.contains($0.key) }
    }

    private func expand(_ row: Row, by dimension: FieldRef) {
        let index = rows.firstIndex(where: { $0.id == row.id }) ?? -1
        guard index >= 0, !row.expanded else { return }
        let path = row.path + [Step(dimension: row.dimension, value: row.value)]
        let loadingKey = pathKey(path, dimension.key)
        loading.insert(loadingKey)
        Task {
            let kids = await children(path: path, by: dimension)
            loading.remove(loadingKey)
            if let kids, !kids.isEmpty {
                if let i = rows.firstIndex(where: { $0.id == row.id }) {
                    rows[i].expanded = true
                    rows.replaceSubrange(i + 1..<i + 1, with: kids)
                }
            }
        }
    }

    private func aiSplit(_ row: Row, high: Bool) {
        let candidates = availableDimensions(for: row)
        guard !candidates.isEmpty else { return }
        let path = row.path + [Step(dimension: row.dimension, value: row.value)]
        let loadingKey = pathKey(path, high ? "high" : "low")
        loading.insert(loadingKey)
        Task {
            var levels: [(FieldRef, [Row])] = []
            for dim in candidates {
                if let kids = await children(path: path, by: dim), !kids.isEmpty { levels.append((dim, kids)) }
            }
            loading.remove(loadingKey)
            // The AI split rule from the analysis engine: absolute compares top member values;
            // relative compares how far the top member stands from the others.
            var best: (FieldRef, [Row], Double)?
            for (dim, kids) in levels {
                guard let top = kids.first else { continue }
                let others = kids.dropFirst().map(\.amount)
                let mean = others.isEmpty ? 0 : others.reduce(0, +) / Double(others.count)
                let score: Double
                if high { score = top.amount - mean } else { score = mean - top.amount }
                if best == nil || score > best!.2 { best = (dim, kids, score) }
            }
            guard let (dim, kids, _) = best, let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
            let what = high ? "highest" : "lowest"
            rows[i].expanded = true
            rows[i].note = "\(dim.caption) \(__label(kids.first!.value)) has the \(what) value of any field at this level."
            rows.replaceSubrange(i + 1..<i + 1, with: kids)
        }
    }

    private func collapse(_ row: Row) {
        guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
        var j = i + 1
        while j < rows.count, rows[j].depth > row.depth { j += 1 }
        rows.replaceSubrange(i + 1..<j, with: [])
        rows[i].expanded = false
        rows[i].note = nil
    }

    private func pathKey(_ path: [Step], _ tag: String) -> String {
        path.map { "\($0.dimension.key)=\($0.value.asString)" }.joined(separator: ">") + "|" + tag
    }

    // MARK: DAX

    static func daxFilterTable(_ f: FilterSpec) -> String? {
        guard f.field.kind == .column, !f.values.isEmpty else { return nil }
        let ref = ModelDAX.reference(f.field)
        let values = f.values.map(ModelDAX.literal).joined(separator: ", ")
        let predicate = f.isInverted ? "NOT \(ref) IN { \(values) }" : "\(ref) IN { \(values) }"
        return "FILTER(ALL(\(ref)), \(predicate))"
    }

    static func childQuery(dimension: FieldRef, path: [Step], measure: FieldRef, model: SemanticModel, filters: [FilterSpec]) -> String {
        var args = [ModelDAX.reference(dimension)]
        for step in path { if let f = daxFilterTable(step.filter) { args.append(f) } }
        for f in filters { if let t = daxFilterTable(f) { args.append(t) } }
        args.append(ModelDAX.string("Value"))
        args.append(ModelDAX.aggregate(measure, model: model))
        return "EVALUATE SUMMARIZECOLUMNS(\n    " + args.joined(separator: ",\n    ") + "\n)"
    }

    static func totalQuery(measure: FieldRef, path: [Step], filters: [FilterSpec], model: SemanticModel) -> String {
        var args: [String] = []
        for step in path { if let f = daxFilterTable(step.filter) { args.append(f) } }
        for f in filters { if let t = daxFilterTable(f) { args.append(t) } }
        args.append(ModelDAX.string("Value"))
        args.append(ModelDAX.aggregate(measure, model: model))
        return "EVALUATE SUMMARIZECOLUMNS(\n    " + args.joined(separator: ",\n    ") + "\n)"
    }
}

// MARK: - Local formatting helpers (Fmt is internal to FacetAnalytics)

private func __num(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
    return String(format: "%.10g", d)
}

private func __pct(_ fraction: Double) -> String {
    let s = String(format: "%.1f%%", fraction * 100)
    return s
}

private func __label(_ v: Value) -> String {
    v.isNull ? "(Blank)" : v.asString
}
