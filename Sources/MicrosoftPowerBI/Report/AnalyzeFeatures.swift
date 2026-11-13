import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

/// The Analyze features for the selected visual: quick insights, explain the increase/decrease,
/// and find where this distribution differs. Results are presented as sheets.
@MainActor
enum AnalyzeFeature {
    static func register() {
        AppCommands.register { commands }
    }

    static var commands: [AppCommand] {
        [
            AppCommand(id: "analyze.quickInsights", title: "Quick Insights", menu: .data, symbol: "wand.and.stars",
                       isEnabled: { store in hasData(store) }) { store in
                quickInsights(store)
            },
            AppCommand(id: "analyze.explainChange", title: "Explain the Increase/Decrease", menu: .data, symbol: "chart.line.uptrend.xyaxis",
                       isEnabled: { store in hasData(store) && !(store.pointSelections[store.selectedVisual?.id ?? UUID()] ?? []).isEmpty }) { store in
                explainChange(store)
            },
            AppCommand(id: "analyze.distribution", title: "Find Where This Distribution Differs", menu: .data, symbol: "percent",
                       isEnabled: { store in hasData(store) }) { store in
                distribution(store)
            },
        ]
    }

    private static func hasData(_ store: DocumentStore) -> Bool {
        guard let spec = store.selectedVisual, let d = store.visualData[spec.id] else { return false }
        return d.error == nil && d.table.rowCount > 0
    }

    // MARK: - Analysis table

    /// The visual's result table with columns renamed to their model field names, so the analysis
    /// engines' field references match by name.
    static func analysisTable(_ store: DocumentStore, for spec: VisualSpec)
        -> (table: DataTable, valueField: FieldRef?, valueColumn: String, dimensions: [FieldRef])? {
        guard let d = store.visualData[spec.id], d.error == nil, d.table.rowCount > 0 else { return nil }
        let t = d.table
        var used = Set<String>()
        let columns = (0..<t.columnCount).map { i -> DataColumn in
            let field = d.fields[safe: i].flatMap { $0 }
            var name = field?.name ?? t.columns[i].name
            var k = 2
            while used.contains(name) { name = "\(field?.name ?? t.columns[i].name) \(k)"; k += 1 }
            used.insert(name)
            return DataColumn(name: name, type: t.columns[i].type, values: t.columns[i].values)
        }
        let table = DataTable(name: t.name, columns: columns)
        let dimWells: [Well] = [.category, .legend, .rows, .columns, .details, .location, .breakdown, .trendAxis]
        var dims: [FieldRef] = []
        for w in dimWells {
            for f in spec.fields(w) where !dims.contains(where: { $0.key == f.key }) { dims.append(f) }
        }
        let valueWells: [Well] = [.values, .lineValues, .y, .x]
        let valueField = valueWells.flatMap { spec.fields($0) }.first { $0.isAggregate }
            ?? valueWells.flatMap { spec.fields($0) }.first
        return (table, valueField, valueField?.name ?? t.columns.first?.name ?? "", dims)
    }

    // MARK: Quick insights

    private static func quickInsights(_ store: DocumentStore) {
        guard let spec = store.selectedVisual,
              let (table, _, valueColumn, _) = analysisTable(store, for: spec) else { return }
        let dimWells: [Well] = [.category, .legend, .rows, .location]
        let dimensions = dimWells.flatMap { spec.fields($0) }
        let valueWells: [Well] = [.values, .lineValues]
        var measures = valueWells.flatMap { spec.fields($0) }
        if measures.isEmpty {
            measures = table.columns.filter { $0.type.isNumeric }.prefix(3).map { .column(table.name, $0.name, .sum) }
        }
        let trend = spec.fields(.trendAxis).first ?? spec.fields(.category).first
        let dateField: FieldRef? = (trend.flatMap { store.model.table($0.table)?.column($0.name)?.dataType }.map { $0.isTemporal } ?? false) ? trend : nil
        let source = table
        let insights = QuickInsights.scan(dimensions: dimensions, measures: measures, dateField: dateField) { groupBy, ms in
            InMemoryQuery.aggregate(table: source, groupBy: groupBy.map(\.name),
                                    measures: ms.map { ($0.name, $0.aggregation) })
        }
        guard !insights.isEmpty else {
            store.status = StatusMessage(kind: .info, text: "No notable insights were found for this visual.")
            return
        }
        store.present {
            QuickInsightsSheet(insights: insights, source: source, valueColumn: valueColumn)
        }
    }

    // MARK: Explain the change

    private static func explainChange(_ store: DocumentStore) {
        guard let spec = store.selectedVisual,
              let (table, _, valueColumn, dimensions) = analysisTable(store, for: spec) else { return }
        let points = store.pointSelections[spec.id] ?? []
        let field = points.first?.fields.first ?? dimensions.first
        let value = points.first?.values.first
        store.present {
            ExplainChangeSheet(table: table, measureName: valueColumn, dimensions: dimensions,
                               initialField: field, initialValue: value)
        }
    }

    // MARK: Distribution difference

    private static func distribution(_ store: DocumentStore) {
        guard let spec = store.selectedVisual,
              let (table, valueField, valueColumn, dimensions) = analysisTable(store, for: spec) else { return }
        let category = dimensions.first ?? valueField ?? .column(table.name, table.columnNames.first ?? "", .none)
        let others = dimensions.dropFirst().filter { $0.key != category.key }
        guard !others.isEmpty else {
            store.status = StatusMessage(kind: .info, text: "Add more than one field to this visual to compare distributions.")
            return
        }
        let source = table
        let measureName = valueColumn
        let slices = DistributionDifference.find(category: category, dimensions: Array(others),
                                                 query: InMemoryQuery.make(table: source, measure: measureName))
        guard let top = slices.first else {
            store.status = StatusMessage(kind: .info, text: "No distribution differences were found for this visual.")
            return
        }
        store.present {
            DistributionSheet(slices: slices, top: top, category: category)
        }
    }
}

// MARK: - Quick insights sheet

struct QuickInsightsSheet: View {
    let insights: [QuickInsight]
    let source: DataTable
    let valueColumn: String
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quick insights").font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    ForEach(insights.indices, id: \.self) { i in
                        card(insights[i], index: i)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480)
    }

    private func card(_ insight: QuickInsight, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(insight.kind.displayName).font(Design.Typeface.captionStrong)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                Text(insight.sentence).font(Design.Typeface.body).lineLimit(3)
                Spacer(minLength: 0)
                Button(expanded == index ? "Hide visual" : "Show visual") {
                    withAnimation(Design.Motion.quick) { expanded = expanded == index ? nil : index }
                }
                .controlSize(.small)
            }
            if expanded == index {
                InsightPreview(spec: insight.spec, source: source, valueColumn: valueColumn)
                    .frame(height: 220)
            }
            Hairline()
        }
    }
}

/// Renders one insight's ready-made visual with data aggregated from the source table.
private struct InsightPreview: View {
    let spec: VisualSpec
    let source: DataTable
    let valueColumn: String

    @State private var data: VisualData?

    var body: some View {
        Group {
            if let data {
                VisualView(spec: spec, data: data, context: previewContext)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private var previewContext: VisualContext {
        var c = VisualContext()
        c.isInteractive = false
        return c
    }

    private func load() async {
        // Group the source by the insight's grouping fields and aggregate its measure.
        let groups = (spec.fields(.category) + spec.fields(.legend) + spec.fields(.rows)).map { ($0, Well.category) }
        let measures = (spec.fields(.values) + spec.fields(.y) + spec.fields(.x)).map { ($0, Well.values) }
        let groupNames = groups.map { $0.0.name }
        let table: DataTable
        if groupNames.isEmpty, let m = measures.first {
            table = InMemoryQuery.aggregate(table: source, groupBy: [],
                                            measures: [(m.0.name, m.0.aggregation)])
        } else {
            table = InMemoryQuery.aggregate(table: source, groupBy: groupNames,
                                            measures: measures.map { ($0.0.name, $0.0.aggregation) })
        }
        var roles: [String: [Int]] = [:]
        var fields: [FieldRef?] = []
        var gi = 0
        for (f, well) in groups + measures {
            roles[well.rawValue, default: []].append(gi)
            fields.append(f)
            gi += 1
        }
        data = VisualData(table: table, roles: roles,
                          fields: fields, formats: fields.map { _ in "" },
                          totals: (0..<table.columnCount).map { _ in .null })
    }
}

// MARK: - Explain the change sheet

struct ExplainChangeSheet: View {
    let table: DataTable
    let measureName: String
    let dimensions: [FieldRef]
    let initialField: FieldRef?
    let initialValue: Value?

    @Environment(\.dismiss) private var dismiss
    @State var field: FieldRef = .column("", "", .none)
    @State var fromValue: Value?
    @State var toValue: Value?
    @State var result: ChangeExplanationResult?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Explain the \(result?.isIncrease == false ? "decrease" : "increase")").font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        header(result)
                        ForEach(result.explanations.indices, id: \.self) { i in
                            explanation(result.explanations[i])
                        }
                    }
                    .padding()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 440)
        .onAppear {
            if field == nil { field = initialField ?? dimensions.first ?? .column("", "", .none) }
            let options = Self.distinctValues(of: field.name, in: table)
            if toValue == nil { toValue = initialValue ?? options.last }
            if fromValue == nil { fromValue = options.last(where: { $0 != toValue }) ?? options.first }
            run()
        }
        .onChange(of: field) { _, _ in
            let options = Self.distinctValues(of: field.name, in: table)
            toValue = options.last
            fromValue = options.last(where: { $0 != toValue }) ?? options.first
            run()
        }
    }

    private var controls: some View {
        HStack(spacing: Design.Space.s) {
            Picker("Break down by", selection: $field) {
                ForEach(dimensions, id: \.key) { d in Text(d.caption).tag(d) }
            }
            .frame(width: 180)
            Picker("From", selection: $fromValue) {
                ForEach(Self.distinctValues(of: field.name, in: table), id: \.self) { v in
                    Text(v.asString.isEmpty ? "(Blank)" : v.asString).tag(Optional(v))
                }
            }
            .frame(width: 140)
            Picker("To", selection: $toValue) {
                ForEach(Self.distinctValues(of: field.name, in: table), id: \.self) { v in
                    Text(v.asString.isEmpty ? "(Blank)" : v.asString).tag(Optional(v))
                }
            }
            .frame(width: 140)
            Spacer()
        }
    }

    private func header(_ r: ChangeExplanationResult) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            controls
            HStack(spacing: Design.Space.m) {
                LabeledContent("Before", value: Fmt2.number(r.before))
                Image(systemName: "arrow.right")
                LabeledContent("After", value: Fmt2.number(r.after))
                Text(Fmt2.signed(r.delta)).font(Design.Typeface.bodyStrong)
                    .foregroundStyle(r.isIncrease ? Color.green : Color.red)
            }
            .font(Design.Typeface.body)
        }
    }

    @ViewBuilder
    private func explanation(_ e: ChangeExplanation) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack {
                Text("By \(e.dimension.caption)").font(Design.Typeface.bodyStrong)
                Text(e.sentence).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(e.contributions.indices, id: \.self) { i in
                let c = e.contributions[i]
                HStack(spacing: Design.Space.s) {
                    Text(c.member.asString.isEmpty ? "(Blank)" : c.member.asString)
                        .font(Design.Typeface.caption).frame(width: 120, alignment: .trailing).lineLimit(1)
                    Capsule().fill(c.change >= 0 ? Color.green.opacity(0.55) : Color.red.opacity(0.55))
                        .frame(width: max(3, CGFloat(abs(c.shareOfDelta)) * 200), height: 12)
                    Text(Fmt2.signed(c.change)).font(Design.Typeface.caption).monospacedDigit()
                    Text(Fmt2.percent(abs(c.shareOfDelta))).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            Hairline()
        }
    }

    private func run() {
        guard let f = fromValue, let t = toValue, f != t else { result = nil; return }
        var before = FilterSpec(field: field, kind: .basic)
        before.values = [f]
        var after = FilterSpec(field: field, kind: .basic)
        after.values = [t]
        result = ChangeExplainer.explain(before: [before], after: [after], dimensions: dimensions,
                                         query: InMemoryQuery.make(table: table, measure: measureName))
    }

    static func distinctValues(of column: String, in table: DataTable) -> [Value] {
        guard let col = table.column(column) else { return [] }
        var seen = Set<Value>(), out: [Value] = []
        for v in col.values where !v.isNull {
            if seen.insert(v).inserted { out.append(v) }
        }
        return out
    }
}

// MARK: - Distribution sheet

struct DistributionSheet: View {
    let slices: [DistributionSlice]
    let top: DistributionSlice
    let category: FieldRef

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Where this distribution differs").font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    Text("The distribution of \(category.caption) differs most within these slices:")
                        .font(Design.Typeface.body).foregroundStyle(.secondary)
                    ForEach(slices.indices, id: \.self) { i in
                        sliceRow(slices[i], isTop: i == 0)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 440)
    }

    private func sliceRow(_ s: DistributionSlice, isTop: Bool) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text("\(s.dimension.caption) = \(s.value.asString.isEmpty ? "(Blank)" : s.value.asString)")
                    .font(Design.Typeface.bodyStrong)
                if isTop {
                    Text("most different").font(Design.Typeface.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                Spacer()
                Text("divergence \(String(format: "%.2f", s.divergence))").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                Text("p \(s.pValue < 0.001 ? "< 0.001" : String(format: "%.3f", s.pValue))")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            Text(s.sentence).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(3)
            // Per-category share bars: slice share vs overall share.
            ForEach(s.shares.indices, id: \.self) { i in
                let share = s.shares[i]
                HStack(spacing: Design.Space.xs) {
                    Text(share.category.asString.isEmpty ? "(Blank)" : share.category.asString)
                        .font(Design.Typeface.caption).frame(width: 90, alignment: .trailing).lineLimit(1)
                    Capsule().fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, CGFloat(share.slice) * 140), height: 9)
                    Text(Fmt2.percent(share.slice)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Text("overall \(Fmt2.percent(share.overall))").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            Hairline()
        }
    }
}

// MARK: - Local formatting (Fmt is internal to FacetAnalytics)

enum Fmt2 {
    static func number(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.10g", d)
    }
    static func signed(_ d: Double) -> String { (d >= 0 ? "+" : "") + number(d) }
    static func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
}
