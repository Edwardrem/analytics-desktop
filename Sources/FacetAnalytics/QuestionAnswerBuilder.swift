import Foundation
import FacetCore

extension QuestionParser {
    // MARK: Building the answer

    func build(question: String, tokens: [QToken], state initial: State) -> QuestionAnswer {
        var st = initial
        // A dangling "count" / "how many" counts the rows of the table in play.
        if let agg = st.pendingAgg, agg == .count || agg == .distinctCount, st.values.isEmpty,
           let t = st.tables.first ?? st.groups.first.flatMap({ model.table($0.table) }),
           let col = t.keyColumn ?? t.columns.first?.name {
            var f = FieldRef.column(t.name, col, .count)
            f.displayName = "Count of \(t.name)"
            st.values.append(f)
        }
        // "sales by region": a table name that is also the core of a measure name means that measure.
        if st.values.isEmpty, let t = st.tables.first, let m = lexicon.aliasMeasure(forTable: t) { st.values.append(m) }
        // Dates.
        let date = dateField(preferTables: st.values.map(\.table) + st.groups.map(\.table))
        if !st.pendingYears.isEmpty {
            let lo = st.pendingYears.min() ?? 0, hi = st.pendingYears.max() ?? 0
            let label = lo == hi ? "\(lo)" : "\(lo)–\(hi)"
            if let d = date {
                st.filters.append((rangeFilter(d.field, start: Self.jan1(lo), end: Self.jan1(hi + 1)), "\(d.field.name) is in \(label)"))
            } else if case .column(let f, _)? = lexicon.lookup(["year"])?.entity {
                var spec = FilterSpec(field: f, kind: .basic)
                spec.values = st.pendingYears.map { .int(Int64($0)) }
                st.filters.append((spec, "\(f.name) is \(label)"))
            } else { st.unrecognized += st.pendingYears.map(String.init) }
        }
        for r in st.pendingDateRanges {
            if let d = date { st.filters.append((rangeFilter(d.field, start: r.start, end: r.end), "\(d.field.name) is \(r.text)")) }
            else { st.unrecognized.append(r.text) }
        }
        for r in st.pendingRelative {
            if let d = date {
                var spec = FilterSpec(field: d.field, kind: .relativeDate)
                spec.relative = r.filter
                st.filters.append((spec, "\(d.field.name) is \(r.text)"))
            } else { st.unrecognized.append(r.text) }
        }
        if st.overTime, !st.groupColumns.contains(where: { $0.dataType.isTemporal }), let d = date {
            st.groups.insert(d.field, at: 0); st.groupColumns.insert(d.column, at: 0)
        }
        // A bare table mention lists its columns.
        if st.values.isEmpty, st.groups.isEmpty, let t = st.tables.first {
            for c in t.columns.filter({ !$0.isHidden }).prefix(8) { st.groups.append(.column(t.name, c.name)); st.groupColumns.append(c) }
        }

        // Top N and superlatives.
        var sort: SortSpec?
        var topText: String?
        let leading = tokens.first?.lower ?? ""
        if st.topN == nil, let sup = st.superlative, !st.groups.isEmpty, !st.values.isEmpty, ["which", "what", "who"].contains(leading) {
            st.topN = (1, !sup)
        }
        if let top = st.topN, let field = st.topNField ?? st.groups.first, let by = st.topNBy ?? st.values.first {
            var spec = FilterSpec(field: field, kind: .topN)
            spec.topN.count = top.count; spec.topN.isBottom = top.bottom; spec.topN.by = by
            topText = "\(top.bottom ? "bottom" : "top") \(top.count) \(field.name) by \(by.caption)"
            st.filters.append((spec, ""))
            sort = SortSpec(field: by, descending: !top.bottom)
        }
        if let f = st.sortField { sort = SortSpec(field: f, descending: st.sortDescending ?? true) }
        else if sort == nil, let sup = st.superlative, let v = st.values.first, !st.groups.isEmpty { sort = SortSpec(field: v, descending: sup) }
        else if sort == nil, let desc = st.sortDescending, let v = st.values.first ?? st.groups.first { sort = SortSpec(field: v, descending: desc) }

        // Visual type.
        let firstTemporal = st.groupColumns.first?.dataType.isTemporal ?? false
        var type: VisualType
        if let c = st.chart { type = c }
        else if st.groups.isEmpty { type = st.values.count <= 1 ? .card : .multiRowCard }
        else if st.values.isEmpty { type = .table }
        else if st.versus, st.values.count >= 2 { type = .scatter }
        else if firstTemporal { type = .line }
        else if let c = st.groupColumns.first, Self.isGeographic(c) { type = .map }
        else { type = .clusteredBar }
        if type == .card, st.values.count > 1 { type = .multiRowCard }
        if (type == .card || type == .multiRowCard), st.values.isEmpty { type = .table }

        let title = Self.title(values: st.values, groups: st.groups)
        var spec = VisualSpec(type: type, frame: Frame(x: 0, y: 0, width: 520, height: 340), name: title.isEmpty ? type.displayName : title)
        Self.assign(&spec, groups: st.groups, values: st.values)
        spec.filters = st.filters.map(\.spec)
        if let s = sort { spec.sort = [s] }

        // Interpretation.
        var text = "Show "
        text += title.isEmpty ? "nothing" : title
        let filterTexts = st.filters.map(\.text).filter { !$0.isEmpty }
        if !filterTexts.isEmpty { text += " where " + filterTexts.joined(separator: " and ") }
        if let t = topText { text += ", " + t }
        if let s = sort, topText == nil || st.sortField != nil { text += ", sorted by \(s.field.caption) \(s.descending ? "descending" : "ascending")" }
        let article = "aeiou".contains(type.displayName.lowercased().first ?? "x") ? "an" : "a"
        text += " as \(article) \(type.displayName.lowercased())"

        let answerable = !(st.values.isEmpty && st.groups.isEmpty && st.filters.isEmpty)
        var suggestions: [String] = []
        for w in st.unrecognized {
            guard let near = lexicon.nearest(w), near.lowercased() != w.lowercased() else { continue }
            let s = question.replacingOccurrences(of: w, with: near, options: .caseInsensitive)
            if !suggestions.contains(s) { suggestions.append(s) }
        }
        if !answerable || suggestions.isEmpty && !st.unrecognized.isEmpty {
            for q in suggestedQuestions(limit: 3) where !suggestions.contains(q) { suggestions.append(q) }
        }
        var seen = Set<String>()
        let recognized = st.recognized.filter { seen.insert($0).inserted }
        return QuestionAnswer(spec: spec, interpretation: answerable ? text : "Sorry, nothing in that question matched the data.",
                              unrecognized: st.unrecognized, suggestions: Array(suggestions.prefix(5)), recognizedTerms: recognized,
                              isAnswerable: answerable)
    }

    static func jan1(_ year: Int) -> Date {
        Calendar.utc.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
    }

    private func rangeFilter(_ field: FieldRef, start: Date?, end: Date?) -> FilterSpec {
        var spec = FilterSpec(field: field, kind: .advanced)
        if let s = start { spec.conditions.append(FilterCondition(op: .greaterOrEqual, value: .date(s))) }
        if let e = end { spec.conditions.append(FilterCondition(op: .lessThan, value: .date(e))) }
        return spec
    }

    /// The model's main date column: a marked date table first, then a date column of the tables in play, then any.
    func dateField(preferTables: [String]) -> (field: FieldRef, column: ModelColumn)? {
        for t in model.tables where !t.isHidden {
            if let name = t.dateColumn, let c = t.column(name) { return (.column(t.name, c.name), c) }
        }
        let ordered = preferTables.compactMap { model.table($0) } + model.tables
        for t in ordered where !t.isHidden {
            if let c = t.columns.first(where: { !$0.isHidden && ($0.dataType == .date || $0.dataType == .dateTime) }) {
                return (.column(t.name, c.name), c)
            }
        }
        return nil
    }

    static func isGeographic(_ c: ModelColumn) -> Bool {
        switch c.dataCategory {
        case .address, .city, .continent, .country, .county, .stateOrProvince, .postalCode, .place, .latitude, .longitude: return true
        default: return false
        }
    }

    static func title(values: [FieldRef], groups: [FieldRef]) -> String {
        func join(_ xs: [String]) -> String {
            xs.count <= 2 ? xs.joined(separator: " and ") : xs.dropLast().joined(separator: ", ") + " and " + (xs.last ?? "")
        }
        let v = join(values.map(\.caption)), g = join(groups.map(\.caption))
        if v.isEmpty { return g }
        return g.isEmpty ? v : "\(v) by \(g)"
    }

    /// Distributes group and value fields over the wells of the chosen visual type.
    static func assign(_ spec: inout VisualSpec, groups: [FieldRef], values: [FieldRef]) {
        let g0 = Array(groups.prefix(1)), g1 = Array(groups.dropFirst().prefix(1))
        switch spec.type {
        case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
             .line, .area, .stackedArea, .stackedArea100, .ribbon:
            spec.setFields(.category, g0); spec.setFields(.legend, g1); spec.setFields(.values, values)
        case .lineStackedColumn, .lineClusteredColumn:
            spec.setFields(.category, g0); spec.setFields(.legend, g1)
            spec.setFields(.values, Array(values.prefix(1))); spec.setFields(.lineValues, Array(values.dropFirst()))
        case .waterfall:
            spec.setFields(.category, g0); spec.setFields(.breakdown, g1); spec.setFields(.values, Array(values.prefix(1)))
        case .pie, .donut:
            spec.setFields(.legend, g0); spec.setFields(.details, g1); spec.setFields(.values, Array(values.prefix(1)))
        case .treemap, .sunburst:
            spec.setFields(.category, g0); spec.setFields(.details, g1); spec.setFields(.values, Array(values.prefix(1)))
        case .funnel, .radar, .wordCloud, .calendarHeatmap:
            spec.setFields(.category, g0); spec.setFields(.values, values)
        case .scatter:
            spec.setFields(.details, g0); spec.setFields(.legend, g1)
            spec.setFields(.x, Array(values.prefix(1))); spec.setFields(.y, Array(values.dropFirst().prefix(1)))
            spec.setFields(.size, Array(values.dropFirst(2).prefix(1)))
        case .map, .azureMap:
            spec.setFields(.location, g0); spec.setFields(.legend, g1); spec.setFields(.size, Array(values.prefix(1)))
            spec.setFields(.tooltips, Array(values.dropFirst()))
        case .filledMap, .shapeMap:
            spec.setFields(.location, g0); spec.setFields(.legend, g1); spec.setFields(.values, Array(values.prefix(1)))
        case .card, .cardLegacy:
            spec.setFields(.values, Array(values.prefix(1)))
        case .kpi:
            spec.setFields(.values, Array(values.prefix(1))); spec.setFields(.trendAxis, g0); spec.setFields(.target, Array(values.dropFirst().prefix(1)))
        case .gauge, .bullet:
            spec.setFields(.values, Array(values.prefix(1))); spec.setFields(.target, Array(values.dropFirst().prefix(1)))
        case .matrix, .heatmap:
            spec.setFields(.rows, g0); spec.setFields(.columns, g1); spec.setFields(.values, values)
        case .histogram, .boxPlot:
            spec.setFields(.values, Array(values.prefix(1))); spec.setFields(.category, g0)
        case .dotPlot:
            spec.setFields(.category, g0); spec.setFields(.legend, g1); spec.setFields(.values, values)
        default:
            spec.setFields(.values, groups + values)
        }
    }

    // MARK: Suggested questions and autocomplete

    /// Example questions the parser understands for this model.
    public func suggestedQuestions(limit: Int = 8) -> [String] { QuestionParser.suggestedQuestions(model, limit: limit) }

    /// Example questions generated from a model's measures, numeric columns, categories and dates.
    public static func suggestedQuestions(_ model: SemanticModel, limit: Int = 8) -> [String] {
        var measures: [String] = [], numerics: [String] = [], categories: [String] = [], geo: [String] = []
        var dateName: String?, firstTable: String?
        for t in model.tables where !t.isHidden {
            if firstTable == nil, !t.isDateTable { firstTable = t.name }
            measures += t.measures.filter { !$0.isHidden }.map(\.name)
            for c in t.columns where !c.isHidden && !c.isKey {
                if c.dataType.isTemporal { if dateName == nil { dateName = c.name } }
                else if c.dataType.isNumeric, c.summarizeBy != .none { numerics.append(c.name) }
                else if c.dataType == .text {
                    if isGeographic(c) { geo.append(c.name) } else { categories.append(c.name) }
                }
            }
        }
        var out: [String] = []
        func add(_ q: String) { if !out.contains(q) { out.append(q) } }
        let primary = measures.first ?? numerics.first.map { "total \($0)" }
        let cats = categories + geo
        if let m = primary {
            add(m)
            if let c = cats.first { add("\(m) by \(c)") }
            if dateName != nil { add("\(m) over time") }
            if let c = cats.first { add("top 5 \(c) by \(m)") }
            if let g = geo.first { add("\(m) by \(g) as a map") }
            if cats.count > 1 { add("\(m) by \(cats[1]) as a pie chart") }
            if dateName != nil { add("\(m) this year") }
        }
        if let n = numerics.first, let c = cats.first { add("average \(n) by \(c)") }
        if measures.count > 1, let c = cats.first { add("\(measures[0]) vs \(measures[1]) by \(c)") }
        if let t = firstTable { add("count of \(t)") }
        return Array(out.prefix(max(0, limit)))
    }

    /// Autocomplete: completes the last (partial) word of `prefix` with model terms and grammar keywords.
    /// Returns whole question strings, best matches first.
    public func completions(prefix: String, limit: Int = 8) -> [String] {
        let endsWithSpace = prefix.last?.isWhitespace ?? true
        var words = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
        let partial = endsWithSpace ? "" : (words.popLast() ?? "").lowercased()
        let head = words.joined(separator: " ")
        let prev = words.last?.lowercased() ?? ""

        var measures: [String] = [], numerics: [String] = [], groupers: [String] = [], tables: [String] = []
        for e in lexicon.entities {
            switch e {
            case .measure(let f): measures.append(f.name)
            case .column(let f, let c):
                if c.dataType.isNumeric, c.summarizeBy != .none, !c.isKey { numerics.append(f.name) } else { groupers.append(f.name) }
            case .table(let t): tables.append(t.name)
            }
        }
        let keywords = ["by", "total", "average", "count of", "top 5", "sorted by", "where", "over time", "this year", "last 3 months",
                        "as a line chart", "as a bar chart", "as a pie chart", "as a table", "as a map"]
        var candidates: [String]
        switch prev {
        case "by", "per", "each", "every", "across": candidates = groupers + (st_isTopContext(words) ? measures + numerics : [])
        case "total", "sum", "average", "avg", "mean", "max", "maximum", "min", "minimum", "median": candidates = numerics + measures
        case "of": candidates = numerics + measures + tables + groupers
        case "top", "bottom": candidates = ["3", "5", "10"]
        case "a", "an", "as": candidates = ["line chart", "bar chart", "column chart", "pie chart", "donut chart", "area chart", "scatter chart", "table", "matrix", "map", "card", "treemap"]
        case "": candidates = measures + numerics.map { "total \($0)" } + groupers + keywords
        default: candidates = measures + numerics + groupers + tables + keywords
        }
        var starts: [String] = [], contains: [String] = []
        for c in candidates {
            let l = c.lowercased()
            if partial.isEmpty || l.hasPrefix(partial) { if !starts.contains(c) { starts.append(c) } }
            else if l.split(separator: " ").contains(where: { $0.hasPrefix(partial) }) { if !contains.contains(c) { contains.append(c) } }
        }
        return (starts + contains).prefix(max(0, limit)).map { head.isEmpty ? $0 : head + " " + $0 }
    }

    private func st_isTopContext(_ words: [String]) -> Bool {
        words.contains { $0.lowercased() == "top" || $0.lowercased() == "bottom" }
    }
}
