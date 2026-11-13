import Foundation
import FacetCore
import FacetDAX
import FacetQuery
import FacetAnalytics
import FacetInterop

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

    // MARK: Visual queries

    /// Builds the SUMMARIZECOLUMNS query for a visual, exactly as Power BI generates them:
    /// grouping fields, filter tables, then name/expression pairs for the value wells.
    func visualData(spec: VisualSpec, request: VisualRequest) -> VisualData {
        let start = CFAbsoluteTimeGetCurrent()
        if spec.type.isSlicer { return slicerData(spec, request) }

        var groups: [(well: Well, field: FieldRef)] = []
        var values: [(well: Well, field: FieldRef)] = []
        for well in spec.type.wells where well != .tooltips {
            for f in spec.fields(well) {
                if f.isAggregate {
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
        var args: [String] = groups.map { ModelDAX.reference($0.field) }
        args += filterTables(request)
        for (i, v) in values.enumerated() {
            args.append(ModelDAX.string(valueNames[i]))
            args.append(ModelDAX.aggregate(v.field, model: model))
        }
        let inner = "SUMMARIZECOLUMNS(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
        var dax: String
        if request.rowLimit > 0 {
            dax = "EVALUATE\n    TOPN(\(request.rowLimit),\n" + inner.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n") + "\n    )"
        } else {
            dax = "EVALUATE\n" + inner.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        }

        do {
            let tables = try engine.query(dax)
            guard let table = tables.first else { return VisualData(error: "The visual query returned no result.") }
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
                formats.append(formatString(for: v.field))
            }
            var result = table
            // Visual calculations evaluate over the visual's own result grid.
            for calc in spec.visualCalculations {
                let axisNames = groups.compactMap { g -> String? in
                    guard let i = groups.firstIndex(where: { $0.field.key == g.field.key }) else { return nil }
                    return result.columns[safe: i]?.name
                }
                guard let computed = try? engine.visualCalculation(calc.expression, on: result, rowAxis: axisNames) else { continue }
                result.columns.append(DataColumn(name: calc.name, type: .any, values: computed))
                fields.append(nil)
                formats.append(calc.formatString)
            }
            var totals = [Value](repeating: .null, count: result.columnCount)
            if !values.isEmpty, !groups.isEmpty {
                totals = grandTotals(values: values, names: valueNames, request: request, offset: groups.count, count: result.columnCount) ?? totals
            }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            var out = VisualData(table: result, roles: roles, fields: fields, formats: formats, totals: totals)
            out.queryMilliseconds = ms
            out.daxQuery = dax
            return out
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            var out = VisualData(error: (error as? DAXError)?.message ?? error.localizedDescription)
            out.queryMilliseconds = ms
            out.daxQuery = dax
            return out
        }
    }

    /// The distinct values of a slicer's field under the other filters.
    private func slicerData(_ spec: VisualSpec, _ request: VisualRequest) -> VisualData {
        guard let field = spec.fields(.field).first, field.kind == .column else { return VisualData() }
        var args = [ModelDAX.reference(field)] + filterTables(request)
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

    private func formatString(for field: FieldRef) -> String {
        if field.kind == .measure { return model.table(field.table)?.measure(field.name)?.formatString ?? "" }
        return model.table(field.table)?.column(field.name)?.formatString ?? ""
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

    /// The date window of a relative date filter, computed in Swift (UTC).
    private func relativeWindow(_ relative: RelativeDateFilter) -> ClosedRange<Date> {
        let now = Date()
        let calendar = Calendar.utc
        let unit: Calendar.Component
        switch relative.unit {
        case .minutes: unit = .minute
        case .hours: unit = .hour
        case .days, .weeks, .calendarWeeks: unit = .day
        case .months, .calendarMonths: unit = .month
        case .years, .calendarYears: unit = .year
        }
        func add(_ d: Date, _ n: Int) -> Date { calendar.date(byAdding: unit, value: n, to: d) ?? d }
        let lower: Date, upper: Date
        switch relative.direction {
        case .this:
            lower = relative.unit == .days ? calendar.startOfDay(for: now) : now
            upper = add(lower, 1)
        case .last:
            upper = relative.includeToday ? add(now, 1) : now
            lower = add(upper, -relative.count)
        case .next:
            lower = relative.includeToday ? now : add(now, 1)
            upper = add(lower, relative.count)
        }
        return lower...upper
    }

    /// One summary row: the value expressions evaluated without grouping columns.
    private func grandTotals(values: [(well: Well, field: FieldRef)], names: [String], request: VisualRequest,
                             offset: Int, count: Int) -> [Value]? {
        var args: [String] = filterTables(request)
        for (i, v) in values.enumerated() {
            args.append(ModelDAX.string(names[safe: i] ?? "Total \(i)"))
            args.append(ModelDAX.aggregate(v.field, model: model))
        }
        let dax = "EVALUATE\n    SUMMARIZECOLUMNS(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
        guard let tables = try? engine.query(dax), let row = tables.first?.rows.first, tables.first?.columnCount == values.count else { return nil }
        var totals = [Value](repeating: .null, count: count)
        for (i, v) in row.enumerated() where i < values.count {
            totals[offset + i] = v
        }
        return totals
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
                let numeric = data.table.columns.filter { $0.type.isNumeric }.map(\.name).prefix(4)
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
        let engine = QueryEngine(queries: queries, environment: QueryEnvironment(baseDirectory: baseDirectory))
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

// MARK: Foreign-format importers

/// Registers the interop readers (PBIP projects, TMDL, .pbix/.pbit reports) with the shell.
@MainActor
enum LiveBridge {
    static func register() {
        FileOperations.importers["pbip"] = { url in
            let (doc, warnings) = try PBIPProject.read(from: url)
            return FileOperations.ImportResult(document: doc, warnings: warnings.map(\.description))
        }
        FileOperations.importers["tmdl"] = { url in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            var files: [TMDLFile] = []
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let f as URL in walker where f.pathExtension.lowercased() == "tmdl" {
                        if let data = try? Data(contentsOf: f) {
                            files.append(TMDLFile(path: f.lastPathComponent, text: String(decoding: data, as: UTF8.self)))
                        }
                    }
                }
            } else if let data = try? Data(contentsOf: url) {
                files.append(TMDLFile(path: url.lastPathComponent, text: String(decoding: data, as: UTF8.self)))
            }
            guard !files.isEmpty else { throw InteropError.missingFile("No TMDL definitions were found.") }
            let (model, queries) = try TMDL.parse(files: files)
            var doc = FacetDocument()
            doc.model = model
            doc.queries = queries
            return FileOperations.ImportResult(document: doc)
        }
        for ext in ["pbix", "pbit"] {
            FileOperations.importers[ext] = { url in
                let zip = try ZipArchive(url: url)
                var doc = FacetDocument()
                var warnings: [ImportWarning] = []
                for path in ["Report/Layout", "Report/report.json", "Report/definition/report.json"] where zip.contains(path) {
                    if let json = try? JSONValue.parse(try zip.data(named: path)) {
                        let (report, w) = LegacyReportLayout.convert(json, resource: { _ in nil })
                        doc.report = report
                        warnings += w
                        break
                    }
                }
                guard !doc.report.pages.isEmpty else {
                    throw InteropError.invalidFormat("“\(url.lastPathComponent)” holds no report layout \(AppIdentity.name) can read.")
                }
                warnings.append(ImportWarning("A \(ext) file carries its semantic model in a binary form; connect to your data with Get Data.",
                                              severity: .info))
                return FileOperations.ImportResult(document: doc, warnings: warnings.map(\.description))
            }
        }
    }
}
