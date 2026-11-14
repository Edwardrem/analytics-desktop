import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

/// "Explain the increase / decrease", as Power BI offers it on a line or column chart: right-click a
/// data point and compare it with the point before it on the axis. The change in the visual's measure
/// is broken down by other fields of the model, through the calculation engine and under the visual's
/// own filters, and the fields that concentrate the change most are listed first.
enum ExplainChange {
    static let supportedTypes: Set<VisualType> = [
        .line, .area, .stackedArea, .clusteredColumn, .stackedColumn, .clusteredBar, .stackedBar,
        .lineClusteredColumn, .lineStackedColumn,
    ]
    /// Most fields tried as explanations, and the most members a field may have to be one.
    static let maxDimensions = 12
    static let maxMembers = 30

    /// What one explanation compares.
    struct Plan {
        struct Point: Hashable {
            var label: String
            /// Selects this point: one basic filter per axis field.
            var filters: [FilterSpec]
            /// The measure at this point, as the visual shows it.
            var value: Double?
        }
        var measure: FieldRef
        var measureFormat: String
        /// Every point of the axis, in axis order.
        var points: [Point]
        var from: Int
        var to: Int
        /// Filters both sides share: the series of the clicked mark and the visual's drill path.
        var context: [FilterSpec]
        /// Field keys never offered as explanations (the axis and the fixed series).
        var excluded: Set<String>
        /// Grouping fields of the visual worth trying first (its legend).
        var preferred: [FieldRef]

        func isIncrease(from: Int, to: Int) -> Bool { (points[safe: to]?.value ?? 0) >= (points[safe: from]?.value ?? 0) }
        var title: String { isIncrease(from: from, to: to) ? "Explain the increase" : "Explain the decrease" }
    }

    /// The comparison for a clicked point: that point against the one before it on the axis. Nil when
    /// the visual can't explain it (another visual type, no measure, or the first point of the axis).
    static func plan(spec: VisualSpec, data: VisualData, point: DataPointSelection) -> Plan? {
        guard supportedTypes.contains(spec.type), data.error == nil, !data.isEmpty else { return nil }
        let valueColumns = (data.indices(.values) + data.indices(.lineValues)).filter { $0 < data.table.columnCount }
        guard let column = valueColumns.first(where: { c in (data.fields[safe: c] ?? nil).map { $0.isAggregate && !$0.isHidden } ?? false }),
              let measure = data.fields[safe: column] ?? nil else { return nil }
        let series = SeriesModel(spec: spec, data: data)
        let axisFields = series.categoryFields
        guard !axisFields.isEmpty, axisFields.count == series.categoryColumns.count else { return nil }

        func pointValue(_ field: FieldRef) -> Value? {
            zip(point.fields, point.values).first { $0.0.key == field.key }?.1
        }
        // The clicked mark's series stays fixed on both sides.
        var context: [FilterSpec] = []
        var excluded = Set(axisFields.map(\.key))
        let legend = series.legendField
        var rowsInSeries = Array(0..<data.table.rowCount)
        if let legend, let value = pointValue(legend), let lc = series.legendColumn {
            context.append(basic(legend, value))
            excluded.insert(legend.key)
            rowsInSeries = rowsInSeries.filter { data.table[$0, lc] == value }
        }
        for step in LiveCalculation.drillPlan(spec).path {
            context.append(basic(step.field, step.value))
            excluded.insert(step.field.key)
        }

        var order = Array(series.categories.indices)
        if series.axisKind != .categorical {
            order.sort { (series.categories[$0].values.first ?? .null) < (series.categories[$1].values.first ?? .null) }
        }
        let points = order.map { i -> Plan.Point in
            let category = series.categories[i]
            let rows = rowsInSeries.filter { r in zip(series.categoryColumns, category.values).allSatisfy { data.table[r, $0.0] == $0.1 } }
            let numbers = rows.compactMap { data.table[$0, column].asDouble }.filter(\.isFinite)
            return Plan.Point(label: category.label.isEmpty ? "(Blank)" : category.label,
                              filters: zip(axisFields, category.values).map { basic($0, $1) },
                              value: numbers.isEmpty ? nil : numbers.reduce(0, +))
        }
        let clicked = axisFields.map(pointValue)
        guard !clicked.contains(where: { $0 == nil }),
              let to = order.firstIndex(where: { series.categories[$0].values == clicked.compactMap { $0 } }), to > 0 else { return nil }
        let preferred = spec.fields(.legend).filter { !excluded.contains($0.key) && !$0.isAggregate }
        return Plan(measure: measure, measureFormat: data.formats[safe: column] ?? "", points: points, from: to - 1, to: to,
                    context: context, excluded: excluded, preferred: preferred)
    }

    private static func basic(_ field: FieldRef, _ value: Value) -> FilterSpec {
        var f = FieldRef(kind: field.kind, table: field.table, name: field.name)
        f.aggregation = .none
        var filter = FilterSpec(field: f)
        filter.values = [value]
        return filter
    }

    /// The fields an explanation can break the change down by: the visual's legend first, then the
    /// model's visible text and true/false columns with between 2 and `maxMembers` values.
    static func dimensions(for plan: Plan, model: SemanticModel, data: DataStore) -> [FieldRef] {
        var out = plan.preferred
        var seen = plan.excluded.union(out.map(\.key))
        let parameterTables = Set(model.fieldParameters.map { $0.name.lowercased() })
        for table in model.tables where !table.isHidden && !parameterTables.contains(table.name.lowercased()) {
            for column in table.columns where !column.isHidden && (column.dataType == .text || column.dataType == .boolean) {
                let field = FieldRef.column(table.name, column.name)
                guard !seen.contains(field.key), let values = data[table.name]?.column(column.name)?.values else { continue }
                var distinct = Set<Value>()
                for v in values where !v.isNull {
                    distinct.insert(v)
                    if distinct.count > maxMembers { break }
                }
                guard (2...maxMembers).contains(distinct.count) else { continue }
                seen.insert(field.key)
                out.append(field)
            }
        }
        return Array(out.prefix(maxDimensions))
    }

    /// Explains the change between two of the plan's points with the engine, under the visual's
    /// request (a cross-highlight counts as a filter here).
    static func explain(_ plan: Plan, from: Int, to: Int, dimensions: [FieldRef], request: VisualRequest,
                        engine: CalculationService) -> ChangeExplanationResult? {
        guard let before = plan.points[safe: from], let after = plan.points[safe: to] else { return nil }
        var base = request
        base.crossFilters += base.highlights
        base.highlights = []
        base.rowLimit = 0
        let query: AnalyticsQuery = { groupBy, filters in
            var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 1, height: 1))
            spec.setFields(.category, groupBy)
            spec.setFields(.values, [plan.measure])
            var r = base
            r.filters += filters
            return engine.visualData(spec: spec, request: r).table
        }
        return ChangeExplainer.explain(before: before.filters + plan.context, after: after.filters + plan.context,
                                       dimensions: dimensions, query: query, measureFormat: plan.measureFormat)
    }
}

// MARK: - Store

extension DocumentStore {
    /// Opens Explain the increase / decrease for a data point of a visual on the current page.
    func explainChange(in visualID: UUID, point: DataPointSelection) {
        guard let spec = currentPage.visual(visualID), let data = visualData[visualID],
              let plan = ExplainChange.plan(spec: spec, data: data, point: point) else {
            status = StatusMessage(kind: .info, text: "Right-click a point after the first one on a line or column chart's axis to explain its change.")
            return
        }
        let request = self.request(for: spec, on: currentPage)
        let model = self.model
        present { ExplainChangeSheet(session: ExplainChangeSession(store: self, plan: plan, request: request, model: model)) }
    }
}

@MainActor
final class ExplainChangeSession: ObservableObject {
    let plan: ExplainChange.Plan
    @Published var from: Int { didSet { if from != oldValue { run() } } }
    @Published var to: Int { didSet { if to != oldValue { run() } } }
    @Published private(set) var result: ChangeExplanationResult?
    @Published private(set) var running = false
    private weak var store: DocumentStore?
    private let request: VisualRequest
    private let model: SemanticModel
    private var generation = 0

    init(store: DocumentStore, plan: ExplainChange.Plan, request: VisualRequest, model: SemanticModel) {
        self.store = store; self.plan = plan; self.request = request; self.model = model
        from = plan.from; to = plan.to
    }

    var title: String {
        guard let result else { return plan.isIncrease(from: from, to: to) ? "Explain the increase" : "Explain the decrease" }
        return result.isIncrease ? "Explain the increase" : "Explain the decrease"
    }

    func run() {
        guard let store, from != to else { result = nil; return }
        generation += 1
        let gen = generation, plan = plan, request = request, model = model, from = from, to = to
        running = true
        Task {
            let r = await store.withEngine { engine -> ChangeExplanationResult? in
                let dims = ExplainChange.dimensions(for: plan, model: model, data: engine.data)
                return ExplainChange.explain(plan, from: from, to: to, dimensions: dims, request: request, engine: engine)
            }
            guard gen == self.generation else { return }
            self.result = r
            self.running = false
        }
    }
}

struct ExplainChangeSheet: View {
    @StateObject var session: ExplainChangeSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).font(Design.Typeface.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            controls.padding(.horizontal).padding(.vertical, Design.Space.s)
            Hairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 440)
        .onAppear { session.run() }
    }

    private var controls: some View {
        HStack(spacing: Design.Space.s) {
            Picker("From", selection: $session.from) {
                ForEach(session.plan.points.indices, id: \.self) { Text(session.plan.points[$0].label).tag($0) }
            }
            .frame(width: 200)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("To", selection: $session.to) {
                ForEach(session.plan.points.indices, id: \.self) { Text(session.plan.points[$0].label).tag($0) }
            }
            .frame(width: 200)
            Spacer()
            if session.running { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var content: some View {
        if session.from == session.to {
            EmptyState(systemImage: "equal", title: "Pick two different points", message: "Choose where the change starts and where it ends.")
        } else if let r = session.result {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    summary(r)
                    if r.explanations.isEmpty {
                        PaneNote("No field in the model splits this change unevenly, so nothing stands out as its cause.")
                    }
                    ForEach(r.explanations.indices, id: \.self) { explanation(r.explanations[$0], delta: r.delta) }
                }
                .padding()
            }
        } else if session.running {
            ProgressView("Looking for what changed…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't explain this change",
                       message: "The visual's data is no longer available. Close this and try again.")
        }
    }

    private func number(_ v: Double) -> String { ValueFormatter.format(.double(v), session.plan.measureFormat) }
    private func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + number(abs(v)) }

    private func summary(_ r: ChangeExplanationResult) -> some View {
        HStack(spacing: Design.Space.m) {
            LabeledContent(session.plan.points[safe: session.from]?.label ?? "Before", value: number(r.before))
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            LabeledContent(session.plan.points[safe: session.to]?.label ?? "After", value: number(r.after))
            Text(signed(r.delta)).font(Design.Typeface.bodyStrong)
                .foregroundStyle(r.isIncrease ? Design.Palette.positive : Design.Palette.negative)
            Text(session.plan.measure.caption).font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
        .font(Design.Typeface.body)
    }

    private func explanation(_ e: ChangeExplanation, delta: Double) -> some View {
        let largest = max(e.waterfall.contributions.map { abs($0.change) }.max() ?? 0, abs(e.waterfall.other), 1e-12)
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text("By \(e.dimension.caption)").font(Design.Typeface.bodyStrong)
            Text(e.sentence).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(e.waterfall.contributions.indices, id: \.self) { i in
                let c = e.waterfall.contributions[i]
                bar(c.member.isNull || c.member.asString.isEmpty ? "(Blank)" : c.member.asString, change: c.change, scale: largest)
            }
            if e.waterfall.other != 0 { bar("Other", change: e.waterfall.other, scale: largest) }
            Hairline()
        }
    }

    private func bar(_ label: String, change: Double, scale: Double) -> some View {
        HStack(spacing: Design.Space.s) {
            Text(label).font(Design.Typeface.caption).frame(width: 140, alignment: .trailing).lineLimit(1)
            Capsule().fill((change >= 0 ? Design.Palette.positive : Design.Palette.negative).opacity(0.6))
                .frame(width: max(3, CGFloat(abs(change) / scale) * 220), height: 10)
            Text(signed(change)).font(Design.Typeface.caption).monospacedDigit()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
