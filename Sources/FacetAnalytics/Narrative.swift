import Foundation
import FacetCore

/// A generated summary as a sequence of static text and dynamic values, so the UI can render values
/// as editable, refreshable chips.
public struct Narrative: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case text(String)
        /// A computed value (already formatted) and a stable key identifying what it is, e.g. "Sales.max.value".
        case value(String, key: String)
    }
    public var segments: [Segment]
    public init(segments: [Segment] = []) { self.segments = segments }

    /// The narrative as plain text.
    public var text: String {
        segments.map { s -> String in
            switch s { case .text(let t): return t; case .value(let v, _): return v }
        }.joined()
    }
    public var isEmpty: Bool { segments.isEmpty }
    /// All dynamic values by key.
    public var values: [String: String] {
        var out: [String: String] = [:]
        for case .value(let v, let key) in segments { out[key] = v }
        return out
    }
}

/// Rule-based natural-language summaries ("smart narrative").
public enum SmartNarrative {
    public struct Options: Sendable {
        /// Maximum sentences per visual.
        public var maxSentences = 8
        /// Maximum measures described per visual.
        public var maxMeasures = 2
        public init() {}
    }

    /// Summarises one visual's data.
    public static func summarize(data: VisualData, spec: VisualSpec? = nil, options: Options = Options()) -> Narrative {
        guard data.error == nil, !data.isEmpty else { return Narrative() }
        let t = data.table
        // Grouping columns: by role when roles are known, otherwise non-aggregate fields / non-numeric columns.
        let roleGroup = Set(Well.allCases.filter(\.isGrouping).flatMap { data.indices($0) })
        let plotted = Set([Well.x, .y, .size].flatMap { data.indices($0) })
        var groupCols: [Int] = [], measureCols: [Int] = []
        for i in 0..<t.columnCount {
            let field = data.fields[safe: i].flatMap { $0 }
            let numeric = t.columns[i].type.isNumeric || t.columns[i].values.contains { $0.isNumber }
            let isGroup: Bool
            if roleGroup.contains(i) { isGroup = true }
            else if plotted.contains(i) { isGroup = false }
            else if let f = field { isGroup = !f.isAggregate }
            else { isGroup = !numeric }
            if isGroup { groupCols.append(i) } else if numeric { measureCols.append(i) }
        }
        // Prefer the category-like wells first.
        let preferred = [Well.category, .trendAxis, .rows, .location, .details, .legend].flatMap { data.indices($0) }
        let category = preferred.first ?? groupCols.first
        let names = (0..<t.columnCount).map { i in data.fields[safe: i].flatMap { $0 }?.caption ?? t.columns[i].name }
        let totals: [Double?] = (0..<t.columnCount).map { data.totals[safe: $0]?.asDouble }
        return summarize(table: t, categoryColumn: category, valueColumns: measureCols, names: names,
                         formats: data.formats, totals: totals, options: options)
    }

    /// Summarises a plain table.
    /// - Parameters:
    ///   - categoryColumn: the column holding category or time-axis labels (nil for a single-row result).
    ///   - valueColumns: numeric columns to describe.
    ///   - names: display names per column (defaults to the column names).
    ///   - formats: format strings per column.
    ///   - totals: known grand totals per column (used instead of summing when given).
    public static func summarize(table: DataTable, categoryColumn: Int?, valueColumns: [Int], names: [String]? = nil,
                                 formats: [String] = [], totals: [Double?] = [], options: Options = Options()) -> Narrative {
        var b = Builder()
        let cols = valueColumns.filter { $0 >= 0 && $0 < table.columnCount }
        guard !cols.isEmpty, table.rowCount > 0 else { return Narrative() }
        func name(_ c: Int) -> String { names?[safe: c] ?? table.columns[c].name }
        let catName = categoryColumn.map(name)
        let labels: [Value] = categoryColumn.map { table.columns[$0].values } ?? []
        let isTime = categoryColumn.map { isTimeAxis(table.columns[$0]) } ?? false
        let catFormat = categoryColumn.flatMap { formats[safe: $0] } ?? ""

        for c in cols.prefix(options.maxMeasures) {
            let fmt = formats[safe: c] ?? ""
            let m = name(c)
            // Keep rows with a numeric value (and a label when there is a category).
            var idx: [Int] = []
            for r in 0..<table.rowCount where table[r, c].asDouble?.isFinite == true { idx.append(r) }
            guard !idx.isEmpty else { continue }
            if isTime, let cc = categoryColumn { idx.sort { table[$0, cc] < table[$1, cc] } }
            let v = idx.map { table[$0, c].asDouble ?? 0 }
            func lab(_ k: Int) -> String { categoryColumn == nil ? "" : Fmt.label(labels[idx[k]], catFormat) }
            let total = totals[safe: c].flatMap { $0 } ?? v.reduce(0, +)

            if categoryColumn == nil || v.count == 1 {
                b.sentence([.text("\(m) is "), .value(Fmt.number(v[0], fmt), key: "\(m).total"), .text(".")])
                continue
            }
            b.sentence([.text("\(m) totals "), .value(Fmt.number(total, fmt), key: "\(m).total"),
                        .text(" across "), .value("\(v.count)", key: "\(m).count"), .text(" \(catName ?? "categories") values.")])

            let maxI = v.indices.max { v[$0] < v[$1] } ?? 0, minI = v.indices.min { v[$0] < v[$1] } ?? 0
            let positive = v.allSatisfy { $0 >= 0 } && total > 0
            if isTime {
                timeSentences(&b, m: m, v: v, lab: lab, fmt: fmt, maxI: maxI, minI: minI)
            } else {
                var hi: [Narrative.Segment] = [.value(lab(maxI), key: "\(m).max.category"), .text(" has the highest \(m) at "),
                                               .value(Fmt.number(v[maxI], fmt), key: "\(m).max.value")]
                if positive { hi += [.text(" ("), .value(Fmt.percent(v[maxI] / total), key: "\(m).max.share"), .text(" of the total)")] }
                hi.append(.text("."))
                b.sentence(hi)
                if maxI != minI {
                    var lo: [Narrative.Segment] = [.value(lab(minI), key: "\(m).min.category"), .text(" has the lowest at "),
                                                   .value(Fmt.number(v[minI], fmt), key: "\(m).min.value")]
                    if positive { lo += [.text(" ("), .value(Fmt.percent(v[minI] / total), key: "\(m).min.share"), .text(")")] }
                    lo.append(.text("."))
                    b.sentence(lo)
                }
                // Concentration.
                if positive, v.count >= 5 {
                    let sorted = v.sorted(by: >)
                    let k = min(3, v.count / 2)
                    let share = sorted.prefix(k).reduce(0, +) / total
                    if share >= 0.5 {
                        b.sentence([.text("The top \(k) \(catName ?? "categories") values account for "),
                                    .value(Fmt.percent(share, decimals: 0), key: "\(m).topShare"), .text(" of \(m).")])
                    }
                }
                // Outliers by robust z-score.
                if v.count >= 6 {
                    let med = Stats.median(v), scale = 1.4826 * Stats.mad(v)
                    if scale > 0 {
                        let out = v.indices.filter { abs(v[$0] - med) / scale > 3.5 }.sorted { abs(v[$0] - med) > abs(v[$1] - med) }
                        if let o = out.first {
                            b.sentence([.value(lab(o), key: "\(m).outlier.category"), .text(" is an outlier, far \(v[o] > med ? "above" : "below") the typical \(m) of "),
                                        .value(Fmt.number(med, fmt), key: "\(m).median"), .text(".")])
                        }
                    }
                }
            }
        }
        // Correlation between the first two measures.
        if cols.count >= 2 {
            var xs: [Double] = [], ys: [Double] = []
            for r in 0..<table.rowCount {
                if let x = table[r, cols[0]].asDouble, let y = table[r, cols[1]].asDouble, x.isFinite, y.isFinite { xs.append(x); ys.append(y) }
            }
            if xs.count >= 5, let r = Stats.pearson(xs, ys), abs(r) >= 0.7 {
                b.sentence([.text("\(name(cols[0])) and \(name(cols[1])) are \(abs(r) >= 0.9 ? "very strongly" : "strongly") \(r > 0 ? "positively" : "negatively") correlated (r = "),
                            .value(String(format: "%.2f", r), key: "correlation"), .text(").")])
            }
        }
        return b.build(limit: options.maxSentences)
    }

    /// Summarises a whole page: one short paragraph per data visual, in reading order.
    public static func summarize(page: [(VisualSpec, VisualData)], options: Options = Options()) -> Narrative {
        var out: [Narrative.Segment] = []
        var per = options
        per.maxSentences = min(options.maxSentences, 3)
        let ordered = page.sorted { a, b in
            a.0.frame.y != b.0.frame.y ? a.0.frame.y < b.0.frame.y : a.0.frame.x < b.0.frame.x
        }
        for (spec, data) in ordered {
            guard !spec.type.isPageElement, !spec.type.isSlicer, spec.type != .narrative, spec.type != .qna, !spec.isHidden else { continue }
            let n = summarize(data: data, spec: spec, options: per)
            guard !n.isEmpty else { continue }
            if !out.isEmpty { out.append(.text("\n")) }
            let title = spec.fmtString("title", "text", spec.name)
            out.append(.text("\(title): "))
            out += n.segments.enumerated().map { i, s -> Narrative.Segment in
                // Namespace value keys by visual so they stay unique on the page.
                if case .value(let v, let key) = s { return .value(v, key: "\(spec.id.uuidString).\(key)") }
                return s
            }
        }
        return Narrative(segments: out)
    }

    // MARK: Time-series sentences

    private static func timeSentences(_ b: inout Builder, m: String, v: [Double], lab: (Int) -> String, fmt: String, maxI: Int, minI: Int) {
        let n = v.count
        let first = v[0], last = v[n - 1]
        // Overall trend.
        if n >= 3, let fit = OLS.fit(x: (0..<n).map(Double.init), y: v) {
            let slope = fit.coefficients[1]
            let change = last - first
            let strong = fit.rSquared >= 0.5 && slope * change > 0
            let dir = !strong ? "showed no clear trend" : (slope > 0 ? "trended upward" : "trended downward")
            var s: [Narrative.Segment] = [.text("\(m) "), .value(dir, key: "\(m).trend"), .text(", ")]
            if first != 0 {
                s += [.text(change >= 0 ? "rising " : "falling "), .value(Fmt.percent(abs(change / first)), key: "\(m).changePercent"), .text(" ")]
            } else {
                s += [.text("changing by "), .value(Fmt.signed(change, fmt), key: "\(m).change"), .text(" ")]
            }
            s += [.text("from "), .value(Fmt.number(first, fmt), key: "\(m).first.value"), .text(" in "), .value(lab(0), key: "\(m).first.label"),
                  .text(" to "), .value(Fmt.number(last, fmt), key: "\(m).last.value"), .text(" in "), .value(lab(n - 1), key: "\(m).last.label"), .text(".")]
            b.sentence(s)
        }
        b.sentence([.text("\(m) peaked at "), .value(Fmt.number(v[maxI], fmt), key: "\(m).max.value"), .text(" in "),
                    .value(lab(maxI), key: "\(m).max.category"), .text(" and was lowest at "),
                    .value(Fmt.number(v[minI], fmt), key: "\(m).min.value"), .text(" in "), .value(lab(minI), key: "\(m).min.category"), .text(".")])
        // Biggest period-over-period moves.
        if n >= 3 {
            let d = (1..<n).map { v[$0] - v[$0 - 1] }
            if let up = d.indices.max(by: { d[$0] < d[$1] }), d[up] > 0 {
                var s: [Narrative.Segment] = [.text("The largest increase was between "), .value(lab(up), key: "\(m).jump.from"), .text(" and "),
                                              .value(lab(up + 1), key: "\(m).jump.to"), .text(" ("), .value(Fmt.signed(d[up], fmt), key: "\(m).jump.value")]
                if v[up] != 0 { s += [.text(", "), .value(Fmt.signed(d[up] / abs(v[up]) * 100) + "%", key: "\(m).jump.percent")] }
                s.append(.text(")."))
                b.sentence(s)
            }
            if let down = d.indices.min(by: { d[$0] < d[$1] }), d[down] < 0 {
                var s: [Narrative.Segment] = [.text("The largest decrease was between "), .value(lab(down), key: "\(m).drop.from"), .text(" and "),
                                              .value(lab(down + 1), key: "\(m).drop.to"), .text(" ("), .value(Fmt.signed(d[down], fmt), key: "\(m).drop.value")]
                if v[down] != 0 { s += [.text(", "), .value(Fmt.signed(d[down] / abs(v[down]) * 100) + "%", key: "\(m).drop.percent")] }
                s.append(.text(")."))
                b.sentence(s)
            }
            // Longest streak of consecutive rises or falls.
            var bestLen = 0, bestStart = 0, bestUp = true
            var runLen = 0, runStart = 0, runUp = true
            for i in d.indices {
                let up = d[i] > 0
                if d[i] != 0, runLen > 0, up == runUp { runLen += 1 }
                else if d[i] != 0 { runLen = 1; runStart = i; runUp = up }
                else { runLen = 0 }
                if runLen > bestLen { bestLen = runLen; bestStart = runStart; bestUp = runUp }
            }
            if bestLen >= 3, bestLen < d.count {
                b.sentence([.text("\(m) \(bestUp ? "rose" : "fell") for "), .value("\(bestLen)", key: "\(m).streak.length"),
                            .text(" consecutive periods, from "), .value(lab(bestStart), key: "\(m).streak.from"), .text(" to "),
                            .value(lab(bestStart + bestLen), key: "\(m).streak.to"), .text(".")])
            }
        }
    }

    /// True when a column looks like a time axis: date-typed, or all values are dates.
    static func isTimeAxis(_ col: DataColumn) -> Bool {
        if col.type.isTemporal { return true }
        let nonNull = col.values.filter { !$0.isNull }
        guard !nonNull.isEmpty else { return false }
        return nonNull.allSatisfy { if case .date = $0 { return true }; return false }
    }

    struct Builder {
        var sentences: [[Narrative.Segment]] = []
        mutating func sentence(_ s: [Narrative.Segment]) { sentences.append(s) }
        func build(limit: Int) -> Narrative {
            var out: [Narrative.Segment] = []
            for (i, s) in sentences.prefix(max(1, limit)).enumerated() {
                if i > 0 { out.append(.text(" ")) }
                out += s
            }
            // Merge adjacent text segments.
            var merged: [Narrative.Segment] = []
            for s in out {
                if case .text(let t) = s, case .text(let prev)? = merged.last { merged[merged.count - 1] = .text(prev + t) }
                else { merged.append(s) }
            }
            return Narrative(segments: merged)
        }
    }
}
