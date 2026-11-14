import Foundation
import FacetCore
import FacetDAX
import FacetQuery
import FacetAnalytics
import FacetInterop
import FacetVisuals

// The live implementations of the app's service protocols: the DAX engine, the analytics layer,
// and the Power Query engine. Created by `Services.live()`.

// MARK: Calculation engine

final class LiveCalculation: CalculationService {
    private let engine = DAXEngine()
    private var model = SemanticModel()

    func load(model: SemanticModel, data: DataStore, roles: [String], userName: String) -> [String: String] {
        self.model = model
        return engine.load(model: model, data: data, roles: roles, userName: userName)
    }

    var data: DataStore { engine.data }

    func distinctValues(field: FieldRef, filters: [FilterSpec], limit: Int) -> [Value] {
        engine.distinctValues(field: field, filters: filters, limit: limit)
    }

    func query(_ dax: String) throws -> [DataTable] {
        try engine.query(dax)
    }

    func scalar(_ expression: String, filters: [FilterSpec]) throws -> Value {
        try engine.scalar(expression, filters: filters)
    }

    func check(_ expression: String, kind: ExpressionKind, homeTable: String?) -> [ExpressionIssue] {
        let daxKind: DAXExpressionKind
        switch kind {
        case .measure: daxKind = .measure
        case .calculatedColumn: daxKind = .calculatedColumn
        case .calculatedTable: daxKind = .calculatedTable
        case .query: daxKind = .query
        case .rowFilter: daxKind = .securityFilter
        case .visualCalculation: daxKind = .visualCalculation
        }
        return engine.check(expression, kind: daxKind, homeTable: homeTable).map {
            ExpressionIssue(message: $0.message, range: $0.range, isWarning: $0.severity == .warning)
        }
    }

    func rows(of table: String, request: VisualRequest) throws -> DataTable {
        let filters = filterTables(request)
        guard !filters.isEmpty else {
            guard let all = engine.data[table] else { throw DAXError("There is no table named \(table).") }
            return all
        }
        let dax = "EVALUATE CALCULATETABLE(\(ModelDAX.table(table)), \(filters.joined(separator: ", ")))"
        guard var rows = try engine.query(dax).first else { throw DAXError("The query for \(table)'s rows returned nothing.") }
        // Result columns may come back qualified ('Sales'[Amount]); the analysis wants the plain names.
        for i in rows.columns.indices {
            let name = rows.columns[i].name
            if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
                rows.columns[i].name = String(name[name.index(after: open)..<name.index(before: name.endIndex)]).replacingOccurrences(of: "]]", with: "]")
            }
        }
        rows.name = table
        return rows
    }

    // MARK: Visual queries

    /// Builds the SUMMARIZECOLUMNS query for a visual, exactly as Power BI generates them:
    /// grouping fields, filter tables, then name/expression pairs for the value wells.
    ///
    /// The category well follows the visual's drill state (see `drillPlan`). With a cross-highlight
    /// selection the result has one row per group of the unhighlighted query: `baseline` holds the
    /// unhighlighted values and `table` the values under the highlight (blank where a group has none).
    func visualData(spec original: VisualSpec, request: VisualRequest) -> VisualData {
        let start = CFAbsoluteTimeGetCurrent()
        if original.type.isSlicer { return slicerData(original, request) }
        if original.type == .textBox { return textBoxData(original, request, start: start) }

        let spec = resolvingFieldParameters(original, filters: filterTables(request))
        let drill = Self.drillPlan(spec)
        var groups: [(well: Well, field: FieldRef)] = []
        var values: [(well: Well, field: FieldRef)] = []
        for well in spec.type.wells {
            for f in well == .category ? drill.category : spec.fields(well) {
                if well == .tooltips {
                    // Tooltip fields never group the visual: each is a value of the data point it describes.
                    values.append((well, Self.tooltipValue(f, model: model)))
                } else if f.isAggregate {
                    values.append((well, f))
                } else if well.isGrouping {
                    groups.append((well, f))
                } else if let column = model.table(f.table)?.column(f.name), column.dataType.isNumeric {
                    values.append((well, f))   // implicit measure
                } else {
                    groups.append((well, f))
                }
            }
        }
        guard !groups.isEmpty || !values.isEmpty else { return VisualData() }

        var taken = Set<String>()
        var valueNames: [String] = []
        for v in values {
            var name = v.field.caption
            var n = 2
            while taken.contains(name) { name = "\(v.field.caption) \(n)"; n += 1 }
            taken.insert(name)
            valueNames.append(name)
        }
        // A highlight only makes sense on grouped values; anywhere else the selection filters.
        let highlighting = !request.highlights.isEmpty && !groups.isEmpty && !values.isEmpty
        var filters = filterTables(request)
        filters += drill.path.map { "FILTER(ALL(\(ModelDAX.reference($0.field))), \(ModelDAX.reference($0.field)) IN { \(ModelDAX.literal($0.value)) })" }
        let highlightTables = request.highlights.flatMap(crossFilterTables)
        if !highlighting { filters += highlightTables }
        let valueArgs = values.indices.flatMap { [ModelDAX.string(valueNames[$0]), ModelDAX.aggregate(values[$0].field, model: model)] }

        /// The query grouped by the first `depth` grouping fields, with extra filter tables.
        func summarize(depth: Int, extra: [String] = [], limited: Bool) -> String {
            let args = groups.prefix(depth).map { ModelDAX.reference($0.field) } + filters + extra + valueArgs
            let inner = "SUMMARIZECOLUMNS(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
            if limited, request.rowLimit > 0 {
                return "EVALUATE\n    TOPN(\(request.rowLimit),\n" + inner.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n    )"
            }
            return "EVALUATE\n" + inner.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        }
        let dax = summarize(depth: groups.count, limited: true)

        do {
            guard let table = try engine.query(dax).first else { return VisualData(error: "The visual query returned no result.") }
            var roles: [String: [Int]] = [:]
            var fields: [FieldRef?] = []
            var formats: [String] = []
            for (i, g) in groups.enumerated() {
                roles[g.well.rawValue, default: []].append(i)
                fields.append(g.field)
                formats.append(model.table(g.field.table)?.column(g.field.name)?.formatString ?? "")
            }
            for (k, v) in values.enumerated() {
                let i = groups.count + k
                roles[v.well.rawValue, default: []].append(i)
                fields.append(v.field)
                formats.append(formatString(for: v.field, filters: filters))
            }
            var result = table
            var baseline: DataTable?
            if highlighting {
                let highlighted = try engine.query(summarize(depth: groups.count, extra: highlightTables, limited: false)).first ?? DataTable()
                baseline = table
                result = Self.aligned(highlighted, to: table, keys: groups.count)
            }
            // Visual calculations evaluate over the visual's own result grid, with the real
            // subtotals of every higher level (so COLLAPSE is exact for non-additive values too).
            if !spec.visualCalculations.isEmpty {
                let axisNames = groups.indices.compactMap { result.columns[safe: $0]?.name }
                let extra = highlighting ? highlightTables : []
                let levels: [DataTable] = values.isEmpty ? [] : (0..<groups.count).compactMap { depth in
                    (try? engine.query(summarize(depth: depth, extra: extra, limited: false)))?.first
                }
                for calc in spec.visualCalculations {
                    let computed: [Value]
                    do {
                        computed = try engine.visualCalculation(calc.expression, on: result, rowAxis: axisNames, levels: levels)
                    } catch {
                        // A calculation that cannot be evaluated is the visual's error, like a failing query.
                        let reason = (error as? DAXError)?.message ?? error.localizedDescription
                        throw DAXError("The visual calculation “\(calc.name)” could not be evaluated: \(reason)")
                    }
                    result.columns.append(DataColumn(name: calc.name, type: .any, values: computed))
                    fields.append(nil)
                    formats.append(calc.formatString)
                }
            }
            // Sparklines: one more column per sparkline, each row's series along its axis.
            try Sparklines.append(to: &result, roles: &roles, fields: &fields, formats: &formats, spec: spec,
                                  groups: groups.map(\.field), filters: filters, model: model) { try engine.query($0).first }
            var totals = [Value](repeating: .null, count: result.columnCount)
            if !values.isEmpty, !groups.isEmpty,
               let row = try? engine.query(summarize(depth: 0, limited: false)).first?.rows.first, row.count == values.count {
                for (i, v) in row.enumerated() { totals[groups.count + i] = v }
            }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            var out = VisualData(table: result, roles: roles, fields: fields, formats: formats, totals: totals)
            out.baseline = baseline
            out.queryMilliseconds = ms
            out.daxQuery = dax
            out.dynamicTitle = DynamicTitles.text(for: spec, filters: filters, model: model) { try engine.query($0).first }
            return out
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            var out = VisualData(error: (error as? DAXError)?.message ?? error.localizedDescription)
            out.queryMilliseconds = ms
            out.daxQuery = dax
            return out
        }
    }

    /// A Tooltips-well field as the value it adds to each data point: measures and summarized
    /// columns as they are; a column left unsummarized takes Power BI's default for the well:
    /// numbers its default summarization, dates the earliest, anything else the first value.
    static func tooltipValue(_ f: FieldRef, model: SemanticModel) -> FieldRef {
        guard !f.isAggregate, f.kind == .column else { return f }
        let column = model.table(f.table)?.column(f.name)
        if column?.summarizeBy ?? .none != .none || column?.dataType.isNumeric == true { return f }
        var out = f
        out.aggregation = column?.dataType.isTemporal == true ? .min : .first
        return out
    }

    // MARK: Field parameters

    /// The field parameter whose caption column this field is, if any.
    private func fieldParameter(_ field: FieldRef) -> FieldParameter? {
        guard field.kind == .column, field.aggregation == .none else { return nil }
        return model.fieldParameters.first { ModelDAX.same($0.name, field.table) && ModelDAX.same($0.name, field.name) }
    }

    /// The visual with every well bound to a field parameter showing the parameter's fields
    /// instead: the ones selected under the filters (all of them when the parameter is not
    /// filtered), in parameter order. A slicer keeps the parameter column: it lists the choices.
    private func resolvingFieldParameters(_ spec: VisualSpec, filters: [String]) -> VisualSpec {
        guard !model.fieldParameters.isEmpty, spec.allFields.contains(where: { fieldParameter($0) != nil }) else { return spec }
        var out = spec
        var selections: [UUID: [FieldRef]] = [:]
        for well in spec.type.wells {
            let fields = spec.fields(well)
            guard fields.contains(where: { fieldParameter($0) != nil }) else { continue }
            out.setFields(well, fields.flatMap { field -> [FieldRef] in
                guard let parameter = fieldParameter(field) else { return [field] }
                if let known = selections[parameter.id] { return known }
                let selected = selectedFields(of: parameter, filters: filters)
                selections[parameter.id] = selected
                return selected
            })
        }
        return out
    }

    /// The fields of a parameter that are selected under the filters, in parameter order.
    private func selectedFields(of parameter: FieldParameter, filters: [String]) -> [FieldRef] {
        let order = ModelDAX.column(parameter.name, ParameterLogic.orderColumnName(parameter.name))
        let dax = "EVALUATE CALCULATETABLE(VALUES(\(order))" + filters.map { ", " + $0 }.joined() + ")"
        guard let positions = try? engine.query(dax).first?.columns.first?.values else { return parameter.fields }
        return positions.compactMap { $0.asInt.map(Int.init) }.sorted().compactMap { parameter.fields[safe: $0] }
    }

    /// What a visual's category well groups by at its drill state, as Power BI does:
    /// - not drilled: the first field of the hierarchy;
    /// - drilled into a data point: the field at the drill level, filtered to the drilled path;
    /// - "go to next level": the field at the drill level, for every parent;
    /// - "expand all down one level": every field down to the drill level.
    /// A sunburst draws all its levels at once and a single field has nothing to drill.
    static func drillPlan(_ spec: VisualSpec) -> (category: [FieldRef], path: [(field: FieldRef, value: Value)]) {
        let all = spec.fields(.category)
        let hierarchy = all.filter { !$0.isAggregate }
        guard hierarchy.count > 1, hierarchy.count == all.count, spec.type != .sunburst else { return (all, []) }
        let level = min(max(0, spec.drillLevel), hierarchy.count - 1)
        if spec.expandedAllLevels { return (Array(hierarchy.prefix(level + 1)), []) }
        let path = zip(hierarchy.prefix(level), spec.drillPath).map { (field: $0, value: $1) }
        return ([hierarchy[level]], path)
    }

    /// `source` re-laid on the rows of `shape`: the same rows in the same order, matched on the
    /// first `keys` columns, with blank values where `source` has no such row.
    static func aligned(_ source: DataTable, to shape: DataTable, keys: Int) -> DataTable {
        var index: [[Value]: Int] = [:]
        for r in 0..<source.rowCount where index[(0..<keys).map { source[r, $0] }] == nil {
            index[(0..<keys).map { source[r, $0] }] = r
        }
        var out = shape
        for c in keys..<shape.columnCount {
            let from = source.columnIndex(shape.columns[c].name)
            out.columns[c].values = (0..<shape.rowCount).map { r in
                guard let from, let hit = index[(0..<keys).map { shape[r, $0] }] else { return .null }
                return source[hit, from]
            }
        }
        return out
    }

    /// The distinct values of a slicer's field under the other filters.
    private func slicerData(_ spec: VisualSpec, _ request: VisualRequest) -> VisualData {
        guard let field = spec.fields(.field).first, field.kind == .column else { return VisualData() }
        let args = [ModelDAX.reference(field)] + filterTables(request)
        let inner = "SUMMARIZECOLUMNS(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
        let dax = "EVALUATE\n" + inner.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        do {
            let tables = try engine.query(dax)
            guard let table = tables.first else { return VisualData() }
            var out = VisualData(table: table, roles: [Well.field.rawValue: [0]], fields: [field],
                                 formats: [model.table(field.table)?.column(field.name)?.formatString ?? ""])
            out.daxQuery = dax
            return out
        } catch {
            var out = VisualData(error: (error as? DAXError)?.message ?? error.localizedDescription)
            out.daxQuery = dax
            return out
        }
    }

    // MARK: Text boxes

    /// A text box's dynamic values: each `{{Measure}}` or `{{=DAX}}` placeholder evaluated under the
    /// page's filters, slicers and selections, as a one-row table with one column per placeholder,
    /// named after it (what the text box renderer looks up). A placeholder that names no measure, or
    /// whose expression fails, gets no column and stays a quiet token in the text.
    private func textBoxData(_ spec: VisualSpec, _ request: VisualRequest, start: CFAbsoluteTime) -> VisualData {
        let names = TextBoxPlaceholders.names(in: spec.content)
        guard !names.isEmpty else { return VisualData() }
        // A text box shows no data points, so a selection elsewhere filters it rather than highlighting.
        let filters = filterTables(request) + request.highlights.flatMap(crossFilterTables)
        var columns: [DataColumn] = [], formats: [String] = [], queries: [String] = []
        for name in names {
            guard let (expression, format) = textBoxExpression(name, filters: filters) else { continue }
            let dax = "EVALUATE\n    CALCULATETABLE(\n        ROW(\(ModelDAX.string("Value")), \(expression))"
                + filters.map { ",\n        " + $0 }.joined() + "\n    )"
            queries.append(dax)
            guard let table = try? engine.query(dax).first, table.rowCount > 0, table.columnCount > 0 else { continue }
            columns.append(DataColumn(name: name, type: .any, values: [table[0, 0]]))
            formats.append(format)
        }
        var out = VisualData(table: DataTable(name: spec.name, columns: columns), fields: columns.map { _ in nil },
                             formats: formats, totals: columns.map { _ in .null })
        out.daxQuery = queries.joined(separator: "\n\n")
        out.queryMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return out
    }

    /// The DAX and format string of one placeholder: `=expression` as written, otherwise the
    /// measure of that name (any table, case-insensitive). Nil when no measure has the name.
    private func textBoxExpression(_ name: String, filters: [String]) -> (String, String)? {
        if name.hasPrefix("=") {
            let expression = name.dropFirst().trimmingCharacters(in: .whitespaces)
            return expression.isEmpty ? nil : (expression, "")
        }
        for table in model.tables {
            if let m = table.measures.first(where: { ModelDAX.same($0.name, name) }) {
                return (ModelDAX.measure(m.name), formatString(for: .measure(table.name, m.name), filters: filters))
            }
        }
        return nil
    }

    /// The format string of a value column. A measure's is the one in effect under the visual's
    /// filters: its dynamic format string and the format of a selected calculation item.
    private func formatString(for field: FieldRef, filters: [String] = []) -> String {
        guard field.kind == .measure else { return model.table(field.table)?.column(field.name)?.formatString ?? "" }
        if let dynamic = try? engine.formatString(forMeasure: field.name, filterTables: filters) { return dynamic }
        return model.table(field.table)?.measure(field.name)?.formatString ?? ""
    }
    /// Filter tables for the visual's filters, other slicers and cross-filter selections.
    private func filterTables(_ request: VisualRequest) -> [String] {
        var out: [String] = []
        for f in request.filters { if let t = filterTable(f) { out.append(t) } }
        for s in request.slicers { out += slicerTables(s) }
        for points in request.crossFilters { out += crossFilterTables(points) }
        return out
    }

    private func filterTable(_ f: FilterSpec) -> String? {
        guard f.field.kind == .column else { return nil }
        let ref = ModelDAX.reference(f.field)
        switch f.kind {
        case .basic:
            guard !f.values.isEmpty else { return nil }
            let values = f.values.map(ModelDAX.literal).joined(separator: ", ")
            let predicate = f.isInverted ? "NOT \(ref) IN { \(values) }" : "\(ref) IN { \(values) }"
            return "FILTER(ALL(\(ref)), \(predicate))"
        case .advanced:
            let parts = f.conditions.compactMap { condition($0, ref: ref) }
            guard !parts.isEmpty else { return nil }
            let joiner = f.conditionsUseOr ? " || " : " && "
            return "FILTER(ALL(\(ref)), \(parts.joined(separator: joiner)))"
        case .topN:
            guard let by = f.topN.by else { return nil }
            let order = f.topN.isBottom ? "ASC" : "DESC"
            // CALCULATE gives the order expression context transition: a bare aggregate would be
            // the same grand total for every candidate value, so all would tie and be kept.
            return "TOPN(\(f.topN.count), ALL(\(ref)), CALCULATE(\(ModelDAX.aggregate(by, model: model))), \(order))"
        case .relativeDate, .relativeTime:
            let window = relativeWindow(f.relative)
            return "FILTER(ALL(\(ref)), \(ref) >= \(ModelDAX.literal(.date(window.lowerBound))) && \(ref) < \(ModelDAX.literal(.date(window.upperBound))))"
        }
    }

    private func condition(_ cond: FacetCore.FilterCondition, ref: String) -> String? {
        let lit = ModelDAX.literal(cond.value)
        switch cond.op {
        case .equals: return "\(ref) = \(lit)"
        case .notEquals: return "\(ref) <> \(lit)"
        case .greaterThan: return "\(ref) > \(lit)"
        case .greaterOrEqual: return "\(ref) >= \(lit)"
        case .lessThan: return "\(ref) < \(lit)"
        case .lessOrEqual: return "\(ref) <= \(lit)"
        case .contains: return "CONTAINSSTRING(\(ref), \(lit))"
        case .notContains: return "NOT CONTAINSSTRING(\(ref), \(lit))"
        case .startsWith: return "LEFT(\(ref), LEN(\(lit))) = \(lit)"
        case .notStartsWith: return "LEFT(\(ref), LEN(\(lit))) <> \(lit)"
        case .endsWith: return "RIGHT(\(ref), LEN(\(lit))) = \(lit)"
        case .isBlank: return "ISBLANK(\(ref))"
        case .isNotBlank: return "NOT ISBLANK(\(ref))"
        case .isEmpty: return "LEN(\(ref) & \"\") = 0"
        case .isNotEmpty: return "LEN(\(ref) & \"\") > 0"
        }
    }

    private func slicerTables(_ s: VisualRequest.Slicer) -> [String] {
        // An input slicer's terms are matched with its operator, not taken as values.
        if s.type == .inputSlicer, let field = s.fields.first, field.kind == .column, !s.state.selected.isEmpty {
            return [inputSlicerTable(field, terms: s.state.selected, op: s.matchOperator)]
        }
        // A hierarchy slicer selects whole paths: a parent alone selects everything under it.
        if !s.state.hierarchyPaths.isEmpty, let table = hierarchyTable(s.fields, paths: s.state.hierarchyPaths) {
            return [table]
        }
        var out: [String] = []
        for field in s.fields where field.kind == .column {
            let ref = ModelDAX.reference(field)
            if !s.state.selected.isEmpty {
                let values = s.state.selected.map(ModelDAX.literal).joined(separator: ", ")
                out.append("FILTER(ALL(\(ref)), \(ref) IN { \(values) })")
            }
            if !s.state.rangeLow.isNull || !s.state.rangeHigh.isNull {
                var parts: [String] = []
                if !s.state.rangeLow.isNull { parts.append("\(ref) >= \(ModelDAX.literal(s.state.rangeLow))") }
                if !s.state.rangeHigh.isNull { parts.append("\(ref) <= \(ModelDAX.literal(s.state.rangeHigh))") }
                if !parts.isEmpty { out.append("FILTER(ALL(\(ref)), \(parts.joined(separator: " && ")))") }
            }
            if !s.state.text.isEmpty {
                out.append("FILTER(ALL(\(ref)), CONTAINSSTRING(\(ref), \(ModelDAX.string(s.state.text))))")
            }
            if let relative = s.state.relative {
                let window = relativeWindow(relative)
                out.append("FILTER(ALL(\(ref)), \(ref) >= \(ModelDAX.literal(.date(window.lowerBound))) && \(ref) < \(ModelDAX.literal(.date(window.upperBound))))")
            }
        }
        return out
    }

    /// The values of a column that an input slicer's terms match, as the slicer itself matches them.
    private func inputSlicerTable(_ field: FieldRef, terms: [Value], op: String) -> String {
        let ref = ModelDAX.reference(field)
        var seen = Set<Value>(), matching: [Value] = []
        for v in engine.data[field.table]?.column(field.name)?.values ?? [] where seen.insert(v).inserted {
            if CmpSlInputMatcher.matches(v, terms: terms, op: op) { matching.append(v) }
        }
        guard !matching.isEmpty else { return "FILTER(ALL(\(ref)), FALSE())" }
        return "FILTER(ALL(\(ref)), \(ref) IN { \(matching.map(ModelDAX.literal).joined(separator: ", ")) })"
    }

    /// One filter over the hierarchy's columns keeping the rows on any ticked path. The levels
    /// must come from one table (as a hierarchy's do); otherwise nil.
    private func hierarchyTable(_ fields: [FieldRef], paths: [[Value]]) -> String? {
        let levels = fields.filter { $0.kind == .column }
        guard let table = levels.first?.table, levels.allSatisfy({ $0.table == table }) else { return nil }
        let refs = levels.map(ModelDAX.reference)
        let alternatives = paths.compactMap { path -> String? in
            let parts = zip(refs, path).map { "\($0) = \(ModelDAX.literal($1))" }
            return parts.isEmpty ? nil : "(" + parts.joined(separator: " && ") + ")"
        }
        guard !alternatives.isEmpty else { return nil }
        return "FILTER(ALL(\(refs.joined(separator: ", "))), \(alternatives.joined(separator: " || ")))"
    }

    private func crossFilterTables(_ points: [DataPointSelection]) -> [String] {
        guard !points.isEmpty else { return [] }
        var byField: [String: (field: FieldRef, values: [Value])] = [:]
        for point in points {
            for (field, value) in zip(point.fields, point.values) where field.kind == .column {
                var entry = byField[field.key] ?? (field, [])
                entry.values.append(value)
                byField[field.key] = entry
            }
        }
        return byField.values.compactMap { entry in
            let ref = ModelDAX.reference(entry.field)
            let values = entry.values.map(ModelDAX.literal).joined(separator: ", ")
            return "FILTER(ALL(\(ref)), \(ref) IN { \(values) })"
        }
    }

    /// The date window of a relative date filter: the same one the engine's own filters use.
    private func relativeWindow(_ relative: RelativeDateFilter) -> Range<Date> {
        RelativeDates.window(relative)
    }
}

// MARK: Analytics overlays

final class LiveAnalytics: AnalyticsService {
    func overlays(spec: VisualSpec, data: VisualData) -> AnalyticsOverlays {
        var out = AnalyticsOverlays()
        guard !data.isEmpty, data.error == nil else { return out }
        let valueIndices = data.indices(.values)
        let categoryIndex = data.indices(.category).first ?? data.indices(.legend).first ?? data.indices(.details).first
        for item in spec.analytics {
            switch item.kind {
            case .forecast:
                for column in valueIndices.prefix(3) {
                    let values = (0..<data.table.rowCount).map { r -> Double? in
                        let v = data.table[r, column]
                        return v.isNumber ? v.asDouble : nil
                    }
                    let axis = categoryIndex.map { ci in (0..<data.table.rowCount).map { r in data.table[r, ci] } } ?? []
                    if let forecast = try? Forecaster.overlay(axis: axis, values: values, seriesColumn: column,
                                                              horizon: max(1, Int(item.value)), confidence: item.secondaryValue / 100) {
                        out.forecasts.append(forecast)
                    }
                }
            case .anomalies:
                for column in valueIndices.prefix(1) {
                    let values = (0..<data.table.rowCount).map { r -> Double? in
                        let v = data.table[r, column]
                        return v.isNumber ? v.asDouble : nil
                    }
                    AnomalyDetector.apply(to: &out, values: values, seriesColumn: column,
                                          sensitivity: item.value <= 0 ? 70 : item.value)
                }
            case .clusters:
                // Tooltip values describe the points; they are not dimensions to cluster on.
                let tooltips = Set(data.indices(.tooltips))
                let numeric = data.table.columns.indices.filter { !tooltips.contains($0) && data.table.columns[$0].type.isNumeric }
                    .map { data.table.columns[$0].name }.prefix(4)
                guard !numeric.isEmpty else { break }
                let k = Int(item.secondaryValue)
                if let (assignments, _) = try? Clustering.cluster(table: data.table, columns: Array(numeric),
                                                                 method: .kMeans(k: k > 0 ? k : nil)) {
                    out.clusters = assignments.map { $0 ?? -1 }
                }
            default:
                break
            }
        }
        return out
    }
}

// MARK: Power Query

final class LiveQuery: QueryService {
    func refresh(queries: [QueryDefinition], only: [String]?, baseDirectory: URL?,
                 progress: @escaping (RefreshProgress) -> Void) async -> [String: Result<DataTable, Error>] {
        let engine = QueryEngine(queries: queries, environment: .app(baseDirectory: baseDirectory))
        return await engine.refreshAll(only: only) { p in
            let fraction = p.total > 0 ? Double(min(p.completed, p.total)) / Double(p.total) : 0
            let message: String
            switch p.phase {
            case .started: message = "Loading…"
            case .finished(let rows, let seconds): message = "\(rows) rows in \(String(format: "%.1f", seconds))s"
            case .failed(let m, _): message = m
            }
            progress(RefreshProgress(query: p.query, message: message, fraction: fraction))
        }
    }
}

// MARK: Service factory

extension Services {
    static func live() -> Services {
        Services(makeCalculation: { LiveCalculation() }, analytics: LiveAnalytics(), query: LiveQuery())
    }
}
