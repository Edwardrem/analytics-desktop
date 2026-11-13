import Foundation
import FacetCore

/// The DAX engine: loads one semantic model with its data, computes calculated objects,
/// and answers measures, queries and visual calculations. Not thread-safe; the app confines
/// every call to its calculation queue.
public final class DAXEngine {
    // MARK: State

    var db = Database()
    var queryTables: [String: TableValue] = [:]
    var queryFunctions: [String: FunctionDef] = [:]
    var functionDefs: [String: FunctionDef] = [:]
    var queryMeasures: [String: MeasureDef] = [:]
    var measureDefs: [String: MeasureDef] = [:]
    var calcGroups: [CalcGroupDef] = []
    var olsTables: Set<Int> = []
    var olsColumns: Set<ColumnID> = []
    var autoDateColumns: [ColumnID: [String: ColumnID]] = [:]
    var autoDateTables: Set<Int> = []
    var calendars: [String: CalendarDef] = [:]
    var dateIndexCache: [ColumnID: DateIndex] = [:]
    var aggregationMappings: [AggregationMapping] = []
    var userName = ""
    var userPrincipalName = ""
    var userCulture = "en-US"
    var userObjectID = ""
    var customData = ""
    var roleNames: [String] = []
    private var sourceData = DataStore()
    var model = SemanticModel()
    /// Source data plus computed calculated tables, columns and groupings.
    public private(set) var data = DataStore()

    public init() {}

    // MARK: Loading

    /// Loads the model, builds storage and computes every calculated object.
    /// Returns object name → error message for objects that could not be computed.
    @discardableResult
    public func load(model: SemanticModel, data source: DataStore, roles roleNames: [String] = [],
                     userName: String = "", userPrincipalName: String = "", culture: String? = nil) -> [String: String] {
        reset()
        self.model = model
        self.userName = userName
        self.userPrincipalName = userPrincipalName.isEmpty ? userName : userPrincipalName
        self.userCulture = culture ?? model.culture
        sourceData = source

        // Data tables. Calculated tables have no source data yet; their columns arrive below.
        for t in model.tables {
            let table = source[t.name]
            let cols: [ColumnStore] = t.columns.map { c in
                if let dc = table?.column(c.name) {
                    return ColumnStore(name: c.name, type: dc.type == .any ? c.dataType : dc.type, values: dc.values)
                }
                return ColumnStore(name: c.name, type: c.dataType, values: [])
            }
            db.addTable(name: t.name, columns: cols, model: t)
        }
        // Data with no model definition (loaded staging tables).
        for (name, t) in source.tables where db.tableIndex[name.daxKey] == nil {
            let cols = t.columns.map { ColumnStore(name: $0.name, type: $0.type, values: $0.values) }
            db.addTable(name: name, columns: cols, model: nil)
        }

        var errors: [String: String] = [:]
        for problem in db.buildRelationships(model.relationships) { errors[problem] = problem }
        aggregationMappings = model.aggregations
        let security = applySecurity(model: model, roleNames: roleNames)
        for (k, v) in security where errors[k] == nil { errors[k] = v }
        for e in refreshCalculatedObjects() { errors[e.object] = e.message }
        return errors
    }

    private func reset() {
        db = Database()
        queryTables = [:]; queryFunctions = [:]; functionDefs = [:]
        queryMeasures = [:]; measureDefs = [:]; calcGroups = []
        olsTables = []; olsColumns = []; autoDateColumns = [:]; autoDateTables = []
        calendars = [:]; dateIndexCache = [:]; aggregationMappings = []
        data = DataStore()
        userName = ""; userPrincipalName = ""; userCulture = "en-US"; userObjectID = ""; customData = ""; roleNames = []
    }

    // MARK: Security

    /// Applies row-level and object-level security of the named roles. Returns per-role problems.
    private func applySecurity(model: SemanticModel, roleNames: [String]) -> [String: String] {
        var problems: [String: String] = [:]
        let active = roleNames.isEmpty ? [] : model.roles.filter { roleNames.contains($0.name) }
        self.roleNames = active.map(\.name)
        var filters: [CtxFilter] = []
        for role in active {
            for table in role.hiddenTables {
                if let ti = db.tableIndex[table.daxKey] { olsTables.insert(ti) }
            }
            for column in role.hiddenColumns {
                if let open = column.firstIndex(of: "["), column.hasSuffix("]"),
                   let cid = db.columnID(table: String(column[..<open]), column: String(column[column.index(after: open)..<column.index(before: column.endIndex)])) {
                    olsColumns.insert(cid)
                }
            }
            for (table, filter) in role.tableFilters.sorted(by: { $0.key < $1.key }) {
                guard let ti = db.tableIndex[table.daxKey] else { continue }
                do {
                    filters.append(try rowFilter(ti, filter))
                } catch {
                    problems["Role “\(role.name)”"] = "The row filter on \(table) could not be applied: \((error as? DAXError)?.message ?? error.localizedDescription)"
                }
            }
        }
        db.securityFilters = filters
        return problems
    }

    /// Evaluates a boolean DAX filter per row, producing a row filter.
    private func rowFilter(_ ti: Int, _ expression: String) throws -> CtxFilter {
        let expr = try Parser.parseExpression(expression)
        let t = db.tables[ti]
        let fc = FilterContext(db: db, ignoreSecurity: true)
        var ctx = Ctx(fc: fc)
        var passing: [Int32] = []
        for r in 0..<t.rowCount {
            ctx.frames = [.base(ti, Int32(r))]
            if try DAXOps.truthy(scalar(expr, ctx)) { passing.append(Int32(r)) }
        }
        let sel = RowSel(n: t.rowCount, rows: passing.count == t.rowCount ? nil : passing, blank: false)
        return CtxFilter(.rows(ti, sel))
    }

    // MARK: Calculated objects

    /// Computes calculated tables, columns, groupings, measures, functions, calculation groups,
    /// calendars and auto date/time hierarchies. Errors are reported per object, never thrown.
    @discardableResult
    public func refreshCalculatedObjects() -> [DAXObjectError] {
        var issues: [DAXObjectError] = []

        // User-defined functions, so measures and columns can call them.
        for f in model.functions {
            do {
                let parsed = try Parser.parseFunctionBody(f.expression)
                let params = parsed.params ?? f.parameters.map { ParsedParam(name: $0.name, type: $0.type, mode: $0.mode, defaultExpr: nil) }
                functionDefs[f.name.daxKey] = FunctionDef(name: f.name, params: params, body: parsed.body)
            } catch {
                issues.append(DAXObjectError(kind: .function, object: f.name, message: (error as? DAXError)?.message ?? error.localizedDescription))
            }
        }

        // Measures: parse only; evaluation errors surface at query time.
        for tt in model.tables {
            for m in tt.measures {
                do {
                    let expr = try Parser.parseExpression(m.expression)
                    var format: Node?
                    if let fe = m.formatExpression, !fe.isEmpty { format = try? Parser.parseExpression(fe) }
                    measureDefs[m.name.daxKey] = MeasureDef(name: m.name, table: tt.name, source: m.expression, expr: expr,
                                                            formatString: m.formatString, formatExpr: format, description: m.description)
                } catch {
                    issues.append(DAXObjectError(kind: .measure, object: m.name, message: (error as? DAXError)?.message ?? error.localizedDescription))
                }
            }
        }

        // Calculation groups.
        for g in model.calculationGroups {
            guard let ti = db.tableIndex[g.name.daxKey], let cid = db.tables[ti].colIndex[g.columnName.daxKey] else {
                issues.append(DAXObjectError(kind: .calculationGroup, object: g.name, message: "The calculation group's column “\(g.columnName)” is missing."))
                continue
            }
            var items: [String: CalcItemDef] = [:]
            var ok = true
            for item in g.items {
                do {
                    var format: Node?
                    if let fe = item.formatExpression, !fe.isEmpty { format = try? Parser.parseExpression(fe) }
                    items[item.name.daxKey] = CalcItemDef(name: item.name, expr: try Parser.parseExpression(item.expression), formatExpr: format)
                } catch {
                    ok = false
                    issues.append(DAXObjectError(kind: .calculationGroup, object: "\(g.name)[\(item.name)]",
                                                 message: (error as? DAXError)?.message ?? error.localizedDescription))
                }
            }
            if ok { calcGroups.append(CalcGroupDef(name: g.name, column: ColumnID(table: ti, col: cid), precedence: g.precedence, items: items)) }
        }

        // Calculated tables: replace their (empty) storage with the evaluated result.
        for t in model.tables where t.isCalculated {
            let object = t.name
            do {
                guard let expr = t.expression else { continue }
                let node = try Parser.parseExpression(expr)
                let result = try table(node, Ctx(fc: FilterContext(db: db, ignoreSecurity: true)))
                let rows = result.rows(db)
                guard let ti = db.tableIndex[t.name.daxKey], let mt = db.tables[ti].model else { continue }
                let names = result.cols.infos.map(\.name)
                var cols: [ColumnStore] = []
                for c in mt.columns {
                    if let k = names.firstIndex(where: { $0.caseInsensitiveCompare(c.name) == .orderedSame }) {
                        var values = rows.map { k < $0.count ? $0[k] : Value.null }
                        values.convert(to: c.dataType)
                        cols.append(ColumnStore(name: c.name, type: c.dataType, values: values))
                    } else {
                        cols.append(ColumnStore(name: c.name, type: c.dataType, values: []))
                    }
                }
                db.addTable(name: t.name, columns: cols, model: mt)
            } catch {
                issues.append(DAXObjectError(kind: .calculatedTable, object: object, message: (error as? DAXError)?.message ?? error.localizedDescription))
            }
        }

        // Calculated columns and groupings.
        for ti in db.tables.indices {
            guard let mt = db.tables[ti].model else { continue }
            for c in mt.columns {
                if let expr = c.expression {
                    do {
                        let node = try Parser.parseExpression(expr)
                        var values: [Value] = []
                        values.reserveCapacity(db.tables[ti].rowCount)
                        let fc = FilterContext(db: db, ignoreSecurity: true)
                        var ctx = Ctx(fc: fc)
                        let t = db.tables[ti]
                        for r in 0..<t.rowCount {
                            ctx.frames = [.base(ti, Int32(r))]
                            values.append(try scalar(node, ctx))
                        }
                        values.convert(to: c.dataType)
                        db.tables[ti].addColumn(ColumnStore(computed: c.name, type: c.dataType, values: values, model: c))
                    } catch {
                        issues.append(DAXObjectError(kind: .calculatedColumn, object: "\(mt.name)[\(c.name)]",
                                                     message: (error as? DAXError)?.message ?? error.localizedDescription))
                    }
                }
                if let g = c.grouping {
                    do { try computeGrouping(g, table: ti, column: c) }
                    catch {
                        issues.append(DAXObjectError(kind: .grouping, object: "\(mt.name)[\(c.name)]",
                                                     message: (error as? DAXError)?.message ?? error.localizedDescription))
                    }
                }
            }
        }

        // Custom calendars for calendar-based time intelligence.
        for t in model.tables {
            guard let ti = db.tableIndex[t.name.daxKey] else { continue }
            for cal in t.calendars {
                guard let dateName = cal.columnsByUnit["date"] ?? t.dateColumn,
                      let dateCid = db.columnID(table: t.name, column: dateName) else { continue }
                calendars[cal.name.daxKey] = CalendarDef(name: cal.name, table: ti, dateColumn: dateCid, yearEndMonth: cal.fiscalYearStartMonth)
            }
        }

        // Auto date/time hierarchies.
        buildAutoDateColumns()
        rebuildDataStore()
        return issues
    }

    private func computeGrouping(_ g: ColumnGrouping, table ti: Int, column c: ModelColumn) throws {
        guard let sid = db.tables[ti].colIndex[g.sourceColumn.daxKey] else {
            throw DAXError("The source column “\(g.sourceColumn)” is missing.")
        }
        let src = db.tables[ti].columns[sid].values
        var out: [Value] = []
        out.reserveCapacity(src.count)
        let other = g.otherGroupName
        switch g.kind {
        case .list:
            var flat: [Value: String] = [:]
            for (name, members) in g.groups { for m in members { flat[DAXEngine.normKey(m)] = name } }
            for v in src {
                if let name = flat[DAXEngine.normKey(v)] { out.append(.string(name)) }
                else if let other { out.append(.string(other)) }
                else { out.append(v) }
            }
        case .binSize, .binCount:
            let nums = src.compactMap { $0.isNumber ? $0.asDouble : nil }
            guard let lo = nums.min(), let hi = nums.max() else {
                out = src.map { _ in Value.null }
                break
            }
            let width = g.kind == .binSize ? max(g.binValue, 0.0001) : (hi == lo ? 1 : (hi - lo) / max(1, g.binValue))
            for v in src {
                guard let d = v.asDouble else { out.append(.null); continue }
                let index = Int((d - lo) / width)
                let start = lo + Double(max(index, 0)) * width
                out.append(.double(start))
            }
        }
        db.tables[ti].addColumn(ColumnStore(computed: c.name, type: c.dataType == .any ? .text : c.dataType, values: out, model: c))
    }

    /// Appends hidden Year/Quarter/Month/Day columns for every date column when auto date/time is on.
    private func buildAutoDateColumns() {
        for ti in db.tables.indices {
            guard let mt = db.tables[ti].model, !mt.isCalculated, mt.columns.contains(where: { $0.expression == nil }) || true else { continue }
            let cal = Calendar.utc
            for c in mt.columns where c.dataType.isTemporal && c.expression == nil {
                guard let cid = db.tables[ti].colIndex[c.name.daxKey] else { continue }
                let values = db.tables[ti].columns[cid].values
                guard values.contains(where: { if case .date = $0 { return true }; return false }) else { continue }
                var map: [String: ColumnID] = [:]
                let levels: [(String, (Date) -> Value)] = [
                    ("Year", { .int(Int64(cal.component(.year, from: $0))) }),
                    ("Quarter", { .int(Int64(cal.component(.quarter, from: $0))) }),
                    ("Month", { .int(Int64(cal.component(.month, from: $0))) }),
                    ("Day", { .int(Int64(cal.component(.day, from: $0))) }),
                ]
                for (level, make) in levels {
                    let name = "\(c.name).\(level)"
                    guard db.tables[ti].colIndex[name.daxKey] == nil else { continue }
                    let out = values.map { v -> Value in v.asDate.map(make) ?? .null }
                    db.tables[ti].addColumn(ColumnStore(computed: name, type: .integer, values: out, model: nil))
                    if let newCid = db.tables[ti].colIndex[name.daxKey] { map[level.lowercased()] = ColumnID(table: ti, col: newCid) }
                }
                if !map.isEmpty {
                    autoDateColumns[ColumnID(table: ti, col: cid)] = map
                    autoDateTables.insert(ti)
                }
            }
        }
    }

    private func rebuildDataStore() {
        var out = sourceData
        for t in db.tables {
            out[t.name] = DataTable(name: t.name, columns: t.columns.map { DataColumn(name: $0.name, type: $0.type, values: $0.values) })
        }
        data = out
    }

    // MARK: Filter contexts

    /// The root filter context for a query, with the given filters applied.
    func rootContext(_ specs: [FilterSpec] = [], crossFilters: [[DataPointSelection]] = []) throws -> Ctx {
        var filters: [CtxFilter] = []
        for f in specs { if let f = try ctxFilter(f) { filters.append(f) } }
        for points in crossFilters { if let f = crossFilter(points) { filters.append(f) } }
        return Ctx(fc: FilterContext(db: db, filters: filters))
    }

    /// Converts a filter into a context filter; nil when it restricts nothing or refers to a missing column.
    func ctxFilter(_ f: FilterSpec) throws -> CtxFilter? {
        guard let cid = db.columnID(table: f.field.table, column: f.field.name) else { return nil }
        try checkColumnAccess(cid, nil)
        let col = db.column(cid)
        func selected(_ values: [Value]) -> Set<Value> {
            guard col.hasText else { return Set(values) }
            let wanted = Set(values.map(DAXEngine.normKey))
            var set = Set<Value>()
            for v in col.dict where wanted.contains(DAXEngine.normKey(v)) { set.insert(v) }
            return set
        }
        switch f.kind {
        case .basic:
            guard !f.values.isEmpty else { return nil }
            let set = selected(f.values)
            if f.isInverted {
                let n = col.values.count
                let idx: [Int32] = (0..<n).filter { !set.contains(col.values[$0]) }.map { Int32($0) }
                return CtxFilter(.rows(cid.table, RowSel(n: n, rows: idx.isEmpty ? [] : (idx.count == n ? nil : idx), blank: true)))
            }
            guard !set.isEmpty else { return nil }
            return CtxFilter(.values(cid, set))
        case .advanced:
            var alternatives: [[CtxFilter]] = []
            var current: [CtxFilter] = []
            for (i, cond) in f.conditions.enumerated() {
                if i > 0 && f.conditionsUseOr {
                    if !current.isEmpty { alternatives.append(current) }
                    current = []
                }
                if let one = conditionFilter(cond, cid, col) { current.append(one) }
            }
            if !current.isEmpty { alternatives.append(current) }
            guard !alternatives.isEmpty else { return nil }
            return CtxFilter(.union(alternatives))
        case .topN:
            guard let by = f.topN.by else { return nil }
            return CtxFilter(.values(cid, try topNValues(of: cid, count: f.topN.count, by: by, bottom: f.topN.isBottom)))
        case .relativeDate, .relativeTime:
            let r = f.relative
            let now = Date()
            let cal = Calendar.utc
            var start = now, end = now
            let unit: Calendar.Component
            switch r.unit {
            case .minutes: unit = .minute
            case .hours: unit = .hour
            case .days, .weeks, .calendarWeeks: unit = .day
            case .months, .calendarMonths: unit = .month
            case .years, .calendarYears: unit = .year
            }
            func add(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: unit, value: n, to: d) ?? d }
            switch r.direction {
            case .this:
                let lo = r.unit == .days ? cal.startOfDay(for: now) : now
                start = lo; end = add(lo, 1)
            case .last:
                end = r.includeToday ? add(now, 1) : now
                start = add(end, -r.count)
            case .next:
                start = r.includeToday ? now : add(now, 1)
                end = add(start, r.count)
            }
            if r.unit == .calendarWeeks || r.unit == .calendarMonths || r.unit == .calendarYears {
                start = cal.dateInterval(of: unit, for: start)?.start ?? start
                end = cal.dateInterval(of: unit, for: add(end, -1))?.end ?? end
            }
            let n = col.values.count
            let idx: [Int32] = (0..<n).compactMap { r in
                guard let d = col.values[r].asDate else { return nil }
                return d >= start && d < end ? Int32(r) : nil
            }
            return CtxFilter(.rows(cid.table, RowSel(n: n, rows: idx, blank: false)))
        }
    }

    private func conditionFilter(_ cond: FilterCondition, _ cid: ColumnID, _ col: ColumnStore) -> CtxFilter? {
        let n = col.values.count
        var passing: [Int32] = []
        let target = cond.value
        let targetText = target.asString
        for r in 0..<n {
            let v = col.values[r]
            let keep: Bool
            switch cond.op {
            case .equals: keep = !v.isNull && DAXOps.compare(v, target) == 0
            case .notEquals: keep = !v.isNull && DAXOps.compare(v, target) != 0
            case .greaterThan: keep = !v.isNull && DAXOps.compare(v, target) > 0
            case .greaterOrEqual: keep = !v.isNull && DAXOps.compare(v, target) >= 0
            case .lessThan: keep = !v.isNull && DAXOps.compare(v, target) < 0
            case .lessOrEqual: keep = !v.isNull && DAXOps.compare(v, target) <= 0
            case .contains: keep = !v.isNull && v.asString.localizedCaseInsensitiveContains(targetText)
            case .notContains: keep = !v.isNull && !v.asString.localizedCaseInsensitiveContains(targetText)
            case .startsWith: keep = !v.isNull && v.asString.lowercased().hasPrefix(targetText.lowercased())
            case .notStartsWith: keep = !v.isNull && !v.asString.lowercased().hasPrefix(targetText.lowercased())
            case .endsWith: keep = !v.isNull && v.asString.lowercased().hasSuffix(targetText.lowercased())
            case .isBlank: keep = v.isNull || (v.asString.isEmpty && !v.isNumber)
            case .isNotBlank: keep = !(v.isNull || (v.asString.isEmpty && !v.isNumber))
            case .isEmpty: keep = v.isNull || v.asString.isEmpty
            case .isNotEmpty: keep = !(v.isNull || v.asString.isEmpty)
            }
            if keep { passing.append(Int32(r)) }
        }
        return CtxFilter(.rows(cid.table, RowSel(n: n, rows: passing.count == n ? nil : passing, blank: true)))
    }

    /// One cross-filter selection set: the selected combinations of grouping columns.
    private func crossFilter(_ points: [DataPointSelection]) -> CtxFilter? {
        guard !points.isEmpty else { return nil }
        var columns: [ColumnID] = []
        for f in points[0].fields {
            if let cid = db.columnID(table: f.table, column: f.name), !columns.contains(cid) { columns.append(cid) }
        }
        guard !columns.isEmpty else { return nil }
        if columns.count == 1 {
            var set = Set<Value>()
            for p in points { for (i, f) in p.fields.enumerated() where i < p.values.count {
                if let cid = db.columnID(table: f.table, column: f.name), cid == columns[0] { set.insert(p.values[i]) }
            } }
            return set.isEmpty ? nil : CtxFilter(.values(columns[0], set))
        }
        var combos = Set<[Value]>()
        for p in points {
            var combo: [Value] = []
            for cid in columns {
                var hit = Value.null
                for (i, f) in p.fields.enumerated() where i < p.values.count {
                    if let c = db.columnID(table: f.table, column: f.name), c == cid { hit = p.values[i] }
                }
                combo.append(hit)
            }
            combos.insert(combo)
        }
        return CtxFilter(.tuples(columns, combos))
    }

    // MARK: Evaluation entry points

    /// Runs a DAX query (`DEFINE` + one or more `EVALUATE` statements).
    public func query(_ dax: String, filters: [FilterSpec] = [], crossFilters: [[DataPointSelection]] = []) throws -> [DataTable] {
        queryTables = [:]; queryFunctions = [:]; queryMeasures = [:]
        let parsed = try Parser.parseQuery(dax)
        let ctx = try rootContext(filters, crossFilters: crossFilters)
        try define(parsed, ctx: ctx)
        var out: [DataTable] = []
        for (i, ev) in parsed.evaluates.enumerated() {
            var c = ctx
            if i == 0 {
                for (name, expr) in parsed.vars {
                    let value: VarValue
                    switch try eval(expr, c) {
                    case .scalar(let s): value = .scalar(s)
                    case .table(let t): value = .table(t)
                    }
                    c.vars = VarScope(name: name, value: value, parent: c.vars)
                }
            }
            guard case .table(let t) = try eval(ev.expr, c) else {
                throw DAXError("The expression used in the EVALUATE statement is not a table.", range: ev.expr.range)
            }
            var result = t
            if !ev.orderBy.isEmpty { result = try applyOrder(result, ev.orderBy, ev.startAt, c) }
            out.append(result.toDataTable(db))
        }
        return out
    }

    private func define(_ parsed: ParsedQuery, ctx: Ctx) throws {
        for f in parsed.functions {
            queryFunctions[f.name.daxKey] = FunctionDef(name: f.name, params: f.params, body: f.body)
        }
        for m in parsed.measures {
            let home = m.table.isEmpty ? (homeTable(of: m.name) ?? ctx.fc.db.tables.first?.name ?? "") : m.table
            queryMeasures[m.name.daxKey] = MeasureDef(name: m.name, table: home, source: m.source, expr: m.expr, description: m.description)
        }
        for (name, expr) in parsed.tables {
            guard case .table(let t) = try eval(expr, ctx) else {
                throw DAXError("The TABLE definition “\(name)” is not a table.")
            }
            queryTables[name.daxKey] = t
        }
        for (t, name, expr) in parsed.columns {
            guard var tv = queryTables[t.daxKey] ?? (db.tableIndex[t.daxKey].map { visibleTable($0, ctx) }) else {
                throw DAXError("Cannot find table '\(t)' in the COLUMN definition.")
            }
            tv = tv.materialized(db)
            var rows = tv.data
            for r in 0..<rows.count {
                var c = ctx
                c.frames.append(.row(tv.cols, rows[r]))
                rows[r] += [try scalar(expr, c)]
            }
            let cols = Columns(tv.cols.infos + [ColInfo(name: name)])
            queryTables[t.daxKey] = TableValue(cols: cols, rows: rows)
        }
    }

    private func homeTable(of measureName: String) -> String? {
        if let m = measureDefs[measureName.daxKey] { return m.table }
        return nil
    }

    private func applyOrder(_ t: TableValue, _ orderBy: [(expr: Node, descending: Bool)], _ startAt: [Node], _ ctx: Ctx) throws -> TableValue {
        let materialized = t.materialized(db)
        var keys: [[Value]] = []
        keys.reserveCapacity(materialized.count)
        try forEachRow(materialized, ctx) { rc, _ in keys.append(try orderBy.map { try scalar($0.expr, rc) }) }
        var idx = DAXEngine.sortedIndices(keys, descending: orderBy.map(\.descending))
        if !startAt.isEmpty {
            let start = try startAt.map { try scalar($0, ctx) }
            idx = idx.filter { i in
                for (k, s) in zip(keys[i], start) {
                    let cmp = DAXOps.sortCompare(DAXEngine.normKey(k), DAXEngine.normKey(s))
                    if cmp < 0 { return true }
                    if cmp > 0 { return false }
                }
                return true
            }
        }
        return pick(materialized, idx)
    }

    /// Evaluates a scalar expression in a filter context.
    public func scalar(_ expression: String, filters: [FilterSpec] = []) throws -> Value {
        let node = try Parser.parseExpression(expression)
        let ctx = try rootContext(filters)
        return try scalar(node, ctx)
    }

    /// The distinct values of a field under filters, capped at `limit`.
    public func distinctValues(field: FieldRef, filters: [FilterSpec], limit: Int = 1000) -> [Value] {
        guard field.kind == .column, field.aggregation == .none,
              let cid = db.columnID(table: field.table, column: field.name) else { return [] }
        guard let ctx = try? rootContext(filters) else { return [] }
        var out = self.distinctValues(cid, ctx.fc, blankRow: true)
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    /// Evaluates one visual calculation over a visual's result grid, one value per row.
    public func visualCalculation(_ expression: String, on grid: DataTable, rowAxis: [String] = [], colAxis: [String] = []) throws -> [Value] {
        let node = try Parser.parseExpression(expression)
        let infos = grid.columns.map { ColInfo(name: $0.name) }
        let tv = TableValue(cols: Columns(infos), rows: grid.rows)
        let cols = Columns(infos)
        func indexOf(_ names: [String]) -> [Int] {
            names.compactMap { n in cols.byName[n.daxKey] }
        }
        let vc = VisualCalcContext(grid: tv, rowAxis: indexOf(rowAxis), colAxis: indexOf(colAxis),
                                   allRowFields: rowAxis, allColFields: colAxis)
        var ctx = Ctx(fc: FilterContext(db: db))
        ctx.visual = vc
        var out: [Value] = []
        out.reserveCapacity(tv.count)
        for r in 0..<tv.count {
            vc.row = r
            vc.aggRows = nil
            ctx.visual = vc
            out.append(try scalar(node, ctx))
        }
        return out
    }

    // MARK: Static checks

    /// Parses an expression and checks names against the model; parse errors carry source ranges.
    public func check(_ expression: String, kind: DAXExpressionKind, homeTable: String?) -> [DAXDiagnostic] {
        let knownMeasures: Set<String>
        let knownFunctions: Set<String>
        var node: Node
        if kind == .query {
            do {
                let parsed = try Parser.parseQuery(expression)
                var measures = Set(measureDefs.keys), functions = Set(functionDefs.keys)
                for m in parsed.measures { measures.insert(m.name.daxKey) }
                for f in parsed.functions { functions.insert(f.name.daxKey) }
                for v in parsed.vars { functions.insert(v.name.daxKey) }
                for t in parsed.tables { functions.insert(t.name.daxKey) }
                knownMeasures = measures
                knownFunctions = functions
                guard let first = parsed.evaluates.first else { return [] }
                node = first.expr
                var issues: [DAXDiagnostic] = []
                for ev in parsed.evaluates {
                    issues += nameIssues(ev.expr, knownMeasures: knownMeasures, knownFunctions: knownFunctions, homeTable: nil)
                }
                return issues
            } catch let e as DAXError {
                return [DAXDiagnostic(range: e.range ?? 0..<0, message: e.message)]
            } catch { return [] }
        }
        do {
            node = try Parser.parseExpression(expression)
        } catch let e as DAXError {
            return [DAXDiagnostic(range: e.range ?? 0..<0, message: e.message)]
        } catch { return [] }
        knownMeasures = Set(measureDefs.keys).union(queryMeasures.keys)
        knownFunctions = Set(functionDefs.keys).union(queryFunctions.keys)
        return nameIssues(node, knownMeasures: knownMeasures, knownFunctions: knownFunctions, homeTable: homeTable)
    }

    private func nameIssues(_ node: Node, knownMeasures: Set<String>, knownFunctions: Set<String>, homeTable: String?) -> [DAXDiagnostic] {
        var issues: [DAXDiagnostic] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ n: Node) {
            guard seen.insert(ObjectIdentifier(n)).inserted else { return }
            switch n.kind {
            case .column(let table, let name, _):
                if let table {
                    let known = db.columnID(table: table, column: name) != nil
                        || measureDefs[name.daxKey]?.table.caseInsensitiveCompare(table) == .orderedSame
                        || queryMeasures[name.daxKey]?.table.caseInsensitiveCompare(table) == .orderedSame
                    if !known, db.tableIndex[table.daxKey] == nil, queryTables[table.daxKey] == nil,
                       !knownMeasures.contains(name.daxKey) {
                        issues.append(DAXDiagnostic(range: n.range, message: "Cannot find table '\(table)'."))
                    } else if db.tableIndex[table.daxKey] != nil, !known, !knownMeasures.contains(name.daxKey) {
                        issues.append(DAXDiagnostic(range: n.range, message: "Column '\(name)' cannot be found in table '\(table)'."))
                    }
                } else if let home = homeTable, db.columnID(table: home, column: name) == nil, !knownMeasures.contains(name.daxKey) {
                    issues.append(DAXDiagnostic(range: n.range, message: "Column '\(name)' cannot be found or is not a measure."))
                }
            case .call(let name, _):
                let known = DAXEngine.builtins[name] != nil || DAXEngine.pureFns[name] != nil
                    || DAXCatalog.function(named: name) != nil || knownFunctions.contains(name.daxKey)
                if !known { issues.append(DAXDiagnostic(range: n.range, message: "Unknown function '\(name)'.")) }
            default: break
            }
            n.walk(visit)
        }
        visit(node)
        return issues
    }

    // MARK: Aggregation substitutions

    func aggregationHit(_ fn: String, _ cid: ColumnID, _ ctx: Ctx) throws -> Value? {
        guard let m = aggregationMappings.first(where: {
            db.tableIndex[$0.detailTable.daxKey] == cid.table
                && db.columnID(table: $0.detailTable, column: $0.detailColumn) == cid
                && $0.summarization.daxFunction == fn
        }), let aggCid = db.columnID(table: m.aggTable, column: m.aggColumn) else { return nil }
        return try aggregateOverMapping(m, aggCid: aggCid, detail: cid.table, ctx: ctx, fallback: fn)
    }

    func aggregationCountHit(_ ti: Int, _ ctx: Ctx) throws -> Value? {
        guard let m = aggregationMappings.first(where: { db.tableIndex[$0.detailTable.daxKey] == ti && $0.summarization == .count }),
              let aggCid = db.columnID(table: m.aggTable, column: m.aggColumn) else { return nil }
        return try aggregateOverMapping(m, aggCid: aggCid, detail: ti, ctx: ctx, fallback: "COUNT")
    }

    /// Answers from the aggregation table when the filter context only touches the detail
    /// table through shared dimensions; otherwise nil (evaluate the detail table normally).
    private func aggregateOverMapping(_ m: AggregationMapping, aggCid: ColumnID, detail: Int, ctx: Ctx, fallback: String) throws -> Value? {
        let fc = ctx.fc
        for f in fc.filters {
            if f.tables.contains(detail) { return nil }   // a direct filter on the detail table
            let reaches = f.tables.contains { ti in db.path(from: ti, to: aggCid.table, rel: fc.rel, mode: .normal) != nil }
            guard reaches else { return nil }
        }
        return try aggregate(m.summarization.daxFunction ?? fallback, visibleValues(aggCid, fc),
                             intResult: m.summarization == .sum || m.summarization == .count || m.summarization == .distinctCount)
    }
}

private extension [Value] {
    /// Converts values to the column's type in place, tolerating failures by keeping the original.
    mutating func convert(to type: DataType) {
        guard type != .any, type != .binary else { return }
        for i in indices where !self[i].isNull { self[i] = self[i].converted(to: type) }
    }
}

private extension ColumnStore {
    /// A computed column carrying its model definition.
    convenience init(computed name: String, type: DataType, values: [Value], model: ModelColumn?) {
        self.init(name: name, type: type, values: values)
        self.model = model
    }
}
