import Foundation
import FacetCore
import FacetAnalytics
import FacetVisuals

/// Anomaly explanations, as Power BI offers them on a line chart: click an anomaly the Analytics
/// pane flagged and the possible explanations are listed with their strength. Each explanation is
/// one member of one field (Region "South") whose own value at the anomaly is furthest from what it
/// was at the normal points around it; its strength is the share of the anomaly's gap — the value
/// against the expected value — that the member accounts for. The breakdowns come from the
/// calculation engine, under the visual's own filters.
enum AnomalyExplanations {
    /// Most fields tried when the card names none, and most explanations listed.
    static let maxDimensions = 12
    static let maxResults = 5

    /// What one explanation looks at.
    struct Plan {
        var measure: FieldRef
        var measureFormat: String
        /// The axis fields, and the axis values and label of every point of the series, in axis order.
        var axisFields: [FieldRef]
        var points: [[Value]]
        var labels: [String]
        /// Detection over the series, as the chart flagged it; `index` is the clicked anomaly in it.
        var detection: AnomalyResult
        var index: Int
        var anomaly: AnalyticsOverlays.Anomaly
        /// The Anomalies card's "Explain by" fields; empty tries the model's suitable fields.
        var explainBy: [FieldRef]
        /// The drill path the visual shows, as filters the breakdowns keep.
        var context: [FilterSpec]
        /// Field keys never offered as explanations: the axis and every level of its hierarchy.
        var excluded: Set<String>

        var label: String { labels[safe: index] ?? "" }
        var value: Double { detection.values[safe: index] ?? 0 }
        var isHigh: Bool { value >= anomaly.expected }
    }

    /// One possible explanation, with the member's value at every point of the series for its chart.
    struct Explanation: Identifiable {
        var id: String { dimension.key + "|" + member.asString }
        var dimension: FieldRef
        var member: Value
        var actual: Double
        var expected: Double
        /// Share of the anomaly's gap this member accounts for, 0…100.
        var strength: Double
        var trend: [Double]
    }

    /// The explanation of an anomaly of a visual's result. Nil when the visual isn't one the
    /// Analytics pane flags anomalies on, or the anomaly no longer matches its data.
    static func plan(spec: VisualSpec, data: VisualData, anomaly: AnalyticsOverlays.Anomaly) -> Plan? {
        guard let item = spec.analytics.first(where: { $0.kind == .anomalies }), spec.fields(.legend).isEmpty,
              data.error == nil, !data.isEmpty else { return nil }
        let column = anomaly.seriesColumn
        guard column >= 0, column < data.table.columnCount,
              let measure = data.fields[safe: column] ?? nil, measure.isAggregate else { return nil }
        let axisColumns = data.indices(.category).filter { $0 >= 0 && $0 < data.table.columnCount }
        let axisFields = axisColumns.compactMap { data.fields[safe: $0] ?? nil }
        guard !axisColumns.isEmpty, axisFields.count == axisColumns.count else { return nil }

        let order = AnalyticsSeries.axisOrder(data)
        let detection = AnomalyDetector.detect(values: AnalyticsSeries.values(data, column: column, order: order),
                                               sensitivity: AnalyticsSeries.sensitivity(item))
        guard let index = order.firstIndex(of: anomaly.row), detection.anomalies.contains(where: { $0.index == index }) else { return nil }

        let points = order.map { r in axisColumns.map { data.table[r, $0] } }
        var labelOfRow: [Int: String] = [:]
        let model = SeriesModel(spec: spec, data: data)
        if let series = model.series.first(where: { $0.column == column }) {
            for (c, row) in series.rows.enumerated() {
                if let row, let category = model.categories[safe: c] { labelOfRow[row] = category.label }
            }
        }
        let labels = zip(order, points).map { row, values in
            labelOfRow[row] ?? values.enumerated().map { i, v in
                ValueFormatter.format(v, data.formats[safe: axisColumns[i]] ?? "")
            }.joined(separator: " ")
        }

        var context: [FilterSpec] = []
        var excluded = Set(axisFields.map(\.key)).union(spec.fields(.category).map(\.key))
        for step in LiveCalculation.drillPlan(spec).path {
            context.append(ExplainChange.basic(step.field, step.value))
            excluded.insert(step.field.key)
        }
        let explainBy = (item.explainBy ?? []).filter { !$0.isAggregate && !excluded.contains($0.key) }
        return Plan(measure: measure, measureFormat: data.formats[safe: column] ?? "", axisFields: axisFields, points: points,
                    labels: labels, detection: detection, index: index, anomaly: anomaly, explainBy: explainBy,
                    context: context, excluded: excluded)
    }

    /// The fields an anomaly is explained by: the card's choice, else the model's visible text and
    /// true/false columns with a few members (as Explain the increase picks them).
    static func dimensions(for plan: Plan, model: SemanticModel, data: DataStore) -> [FieldRef] {
        if !plan.explainBy.isEmpty {
            return plan.explainBy.filter { f in model.table(f.table)?.column(f.name) != nil }
        }
        return Array(ExplainChange.candidateFields(preferred: [], excluded: plan.excluded, model: model, data: data).prefix(maxDimensions))
    }

    /// Per point of the series, the members of `dimension` and the measure for each, from one
    /// engine query grouped by the axis and the dimension.
    static func breakdown(_ plan: Plan, dimension: FieldRef, request: VisualRequest,
                          engine: CalculationService) -> [Int: [(member: Value, value: Double)]] {
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 1, height: 1))
        spec.setFields(.category, plan.axisFields + [dimension])
        spec.setFields(.values, [plan.measure])
        // Several category fields are a drill hierarchy; expanded to the last level, all of them group.
        spec.expandedAllLevels = true
        spec.drillLevel = plan.axisFields.count
        var r = request
        r.crossFilters += r.highlights
        r.highlights = []
        r.rowLimit = 0
        r.filters += plan.context
        let result = engine.visualData(spec: spec, request: r)
        guard result.error == nil else { return [:] }
        let groups = result.indices(.category).filter { $0 < result.table.columnCount }
        guard groups.count == plan.axisFields.count + 1, let valueColumn = result.indices(.values).first,
              valueColumn < result.table.columnCount, let memberColumn = groups.last else { return [:] }
        let axis = Array(groups.dropLast())
        var pointOf: [[Value]: Int] = [:]
        for (i, values) in plan.points.enumerated() where pointOf[values] == nil { pointOf[values] = i }
        var out: [Int: [(member: Value, value: Double)]] = [:]
        for row in 0..<result.table.rowCount {
            let key = axis.map { result.table[row, $0] }
            let v = result.table[row, valueColumn]
            guard let i = pointOf[key], v.isNumber, let d = v.asDouble, d.isFinite else { continue }
            out[i, default: []].append((result.table[row, memberColumn], d))
        }
        return out
    }

    /// The possible explanations of the plan's anomaly, strongest first. A field whose members never
    /// share a point (a week column on a day axis) can't split the anomaly, so it isn't one.
    static func explain(_ plan: Plan, dimensions: [FieldRef], request: VisualRequest, engine: CalculationService) -> [Explanation] {
        var tables: [String: [Int: [(member: Value, value: Double)]]] = [:]
        var usable: [FieldRef] = []
        for dim in dimensions {
            let table = breakdown(plan, dimension: dim, request: request, engine: engine)
            let atAnomaly = (table[plan.index] ?? []).filter { $0.value != 0 }
            guard Set(atAnomaly.map(\.member)).count >= 2 else { continue }
            tables[dim.key] = table
            usable.append(dim)
        }
        let found = AnomalyDetector.explain(anomalyIndex: plan.index, in: plan.detection, dimensions: usable,
                                            breakdown: { dim, i in tables[dim.key]?[i] ?? [] }, maxResults: maxResults)
        return found.map { e in
            let table = tables[e.dimension.key] ?? [:]
            let trend = plan.points.indices.map { i in (table[i] ?? []).filter { $0.member == e.member }.reduce(0) { $0 + $1.value } }
            return Explanation(dimension: e.dimension, member: e.member, actual: e.actual, expected: e.expected,
                               strength: e.strength, trend: trend)
        }
    }

    // MARK: Wording

    static func member(_ v: Value) -> String { v.isNull || v.asString.isEmpty ? "(Blank)" : v.asString }

    /// "Region South was higher than expected: 60 against 10."
    static func sentence(_ e: Explanation, high: Bool, format: String) -> String {
        "\(e.dimension.caption) \(member(e.member)) was \(high ? "higher" : "lower") than expected: "
            + "\(ValueFormatter.format(.double(e.actual), format)) against \(ValueFormatter.format(.double(e.expected), format))."
    }

    /// "70 is above the expected range 2.24 – 37.76 (expected 20)."
    static func summary(_ plan: Plan) -> String {
        let f = plan.measureFormat
        func n(_ v: Double) -> String { ValueFormatter.format(.double(v), f) }
        return "\(n(plan.value)) is \(plan.isHigh ? "above" : "below") the expected range "
            + "\(n(plan.anomaly.lower)) – \(n(plan.anomaly.upper)) (expected \(n(plan.anomaly.expected)))."
    }
}
