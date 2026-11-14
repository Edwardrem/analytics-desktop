import Foundation
import FacetCore

/// The parser's answer to a natural-language question.
public struct QuestionAnswer: Sendable {
    /// A ready-to-render visual (fields, filters, sort, type).
    public var spec: VisualSpec
    /// The question restated using the recognised model terms.
    public var interpretation: String
    /// Words the parser could not map to anything.
    public var unrecognized: [String]
    /// Rephrasings or example questions that would be understood.
    public var suggestions: [String]
    /// Model terms that were recognised, in order of appearance.
    public var recognizedTerms: [String]
    /// False when nothing in the question matched the model.
    public var isAnswerable: Bool
}

/// Natural language → visual. Rule-based, deterministic, offline.
public final class QuestionParser {
    public let model: SemanticModel
    let lexicon: QuestionLexicon
    private let distinctValues: ((FieldRef) -> [Value])?
    /// Reference date for "this year", "last 3 months" interpretation text (filters themselves stay relative).
    public var now: () -> Date = { Date() }
    private var valueIndex: [String: [(field: FieldRef, value: Value)]]?
    private var valueIndexMaxWords = 1
    private var columnValues: [String: [String: Value]] = [:]
    /// Terms taught as filters (Q&A setup), longest first, with the normalised words they match.
    private let taught: [(words: [String], term: QnATerm)]

    /// - Parameters:
    ///   - model: the semantic model whose tables, columns, measures and synonyms form the vocabulary.
    ///   - synonyms: extra synonyms; keys are "Table[Field]", a table name, or a bare field name.
    ///   - distinctValues: returns the distinct values of a column, used to recognise filter values
    ///     ("for France"). Only called for visible text columns, lazily, once per column.
    public init(model: SemanticModel, synonyms: [String: [String]] = [:], distinctValues: ((FieldRef) -> [Value])? = nil) {
        self.model = model
        self.lexicon = QuestionLexicon(model: model, synonyms: synonyms)
        self.distinctValues = distinctValues
        self.taught = (model.qnaTerms ?? [])
            .filter { Self.exists($0.filter.field, in: model) }
            .map { (QuestionTokenizer.tokenize($0.term).map(\.norm), $0) }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
    }

    /// True when the field a taught term filters on is still in the model.
    public static func exists(_ field: FieldRef, in model: SemanticModel) -> Bool {
        guard let t = model.table(field.table) else { return false }
        return field.kind == .measure ? t.measure(field.name) != nil : t.column(field.name) != nil
    }

    // MARK: Parse state

    struct State {
        enum Mode { case none, group, filter, sort }
        var values: [FieldRef] = []
        var groups: [FieldRef] = []
        var groupColumns: [ModelColumn] = []
        var filters: [(spec: FilterSpec, text: String)] = []
        var sortField: FieldRef?
        var sortDescending: Bool?
        var superlative: Bool?           // true = highest, false = lowest
        var topN: (count: Int, bottom: Bool)?
        var topNBy: FieldRef?
        var topNField: FieldRef?
        var awaitingTopNField = false
        var chart: VisualType?
        var overTime = false
        var versus = false
        var pendingAgg: Aggregation?
        /// "how many customers" / "number of customers" count distinct values of a text column.
        var preferDistinct = false
        var mode = Mode.none
        var unrecognized: [String] = []
        var recognized: [String] = []
        var tables: [ModelTable] = []
        var pendingDateRanges: [(start: Date?, end: Date?, text: String)] = []
        var pendingRelative: [(filter: RelativeDateFilter, text: String)] = []
        var pendingYears: [Int] = []
        var preferTables: Set<String> { Set(values.map(\.table) + groups.map(\.table) + tables.map(\.name)) }
    }

    /// Parses a question into a visual.
    public func parse(_ question: String) -> QuestionAnswer {
        let tokens = QuestionTokenizer.tokenize(question)
        var st = State()
        var i = 0
        let lower = tokens.map(\.lower)

        func matchPhrase(_ phrase: [String], at j: Int) -> Bool {
            guard j + phrase.count <= tokens.count else { return false }
            for (k, w) in phrase.enumerated() where lower[j + k] != w || tokens[j + k].quoted { return false }
            return true
        }
        func matchPhraseNorm(_ phrase: [String], at j: Int) -> Bool {
            guard j + phrase.count <= tokens.count else { return false }
            for (k, w) in phrase.enumerated() where tokens[j + k].norm != w || tokens[j + k].quoted { return false }
            return true
        }
        func firstMatch(_ phrases: [[String]], at j: Int) -> Int? {
            phrases.first { matchPhrase($0, at: j) }?.count
        }

        while i < tokens.count {
            let tok = tokens[i]
            if tok.quoted {
                if let hit = matchValue(words: QuestionText.words(of: tok.text)) { addValueFilter(&st, hit) }
                else { st.unrecognized.append(tok.text) }
                i += 1; continue
            }
            // 0. Terms the author taught as filters win over everything else.
            if let hit = taught.first(where: { !$0.words.isEmpty && matchPhraseNorm($0.words, at: i) }) {
                st.filters.append((hit.term.filter, "\(hit.term.term) (\(ReportDescriber.describe(hit.term.filter)))"))
                st.recognized.append(hit.term.term)
                i += hit.words.count; continue
            }
            // 1. Multi-word model terms win over keywords ("Total Sales" is a measure, not SUM(sales)).
            if let (entity, len) = matchEntity(tokens, at: i, state: st, minWords: 2) {
                i += len
                i += place(entity, &st, tokens: tokens, next: i)
                continue
            }
            // 2. Chart type hints.
            if let (type, len) = matchChart(tokens, lower: lower, at: i) { st.chart = type; i += len; continue }
            if matchPhrase(["over", "time"], at: i) { st.overTime = true; st.recognized.append("over time"); i += 2; continue }
            if tok.lower == "trend" || tok.lower == "trends" || tok.lower == "trending" || tok.lower == "timeline" { st.overTime = true; i += 1; continue }
            if tok.lower == "vs" || tok.lower == "versus" || tok.lower == "against" { st.versus = true; i += 1; continue }
            // 3. Top / bottom N.
            if tok.lower == "top" || tok.lower == "bottom" {
                var n = 1, len = 1
                if let num = tokens[safe: i + 1]?.number, num >= 1, num == num.rounded() { n = Int(num); len = 2 }
                else if tok.lower == "top", st.groups.isEmpty, tokens[safe: i + 1] == nil { st.unrecognized.append(tok.text); i += 1; continue }
                st.topN = (n, tok.lower == "bottom"); st.awaitingTopNField = true; st.mode = .none
                i += len; continue
            }
            // 4. Dates: relative periods, years, month + year.
            if let len = parseDatePhrase(tokens, lower: lower, at: i, &st) { i += len; continue }
            // 5. Sorting.
            if let len = firstMatch(QuestionKeywords.sortMarkers, at: i) { st.mode = .sort; i += len; continue }
            if ["ascending", "asc"].contains(tok.lower) { st.sortDescending = false; i += 1; continue }
            if ["descending", "desc"].contains(tok.lower) { st.sortDescending = true; i += 1; continue }
            if matchPhrase(["high", "to", "low"], at: i) { st.sortDescending = true; i += 3; continue }
            if matchPhrase(["low", "to", "high"], at: i) { st.sortDescending = false; i += 3; continue }
            if QuestionKeywords.superlativesHigh.contains(tok.lower) { st.superlative = true; i += 1; continue }
            if QuestionKeywords.superlativesLow.contains(tok.lower) { st.superlative = false; i += 1; continue }
            // 6. Comparison without an explicit subject applies to the latest value field.
            if let subject = st.values.last, let (spec, text, len) = parseCondition(tokens, lower: lower, at: i, field: subject, column: nil, requireOperator: true) {
                st.filters.append((spec, text)); i += len; continue
            }
            // 7. Aggregations.
            if let hit = QuestionKeywords.aggregations.first(where: { matchPhrase($0.phrase, at: i) }) {
                st.pendingAgg = hit.agg; i += hit.phrase.count
                st.preferDistinct = hit.agg == .count && (hit.phrase[0] == "how" || hit.phrase[0] == "number")
                if tokens[safe: i]?.lower == "of" { i += 1 }
                continue
            }
            // 8. Group-by markers.
            if let len = firstMatch(QuestionKeywords.groupMarkers, at: i) { st.mode = .group; i += len; continue }
            if ["where", "whose", "having", "with", "for", "in", "from", "during", "when"].contains(tok.lower) { st.mode = .filter; i += 1; continue }
            // 9. Single-word model terms.
            if let (entity, len) = matchEntity(tokens, at: i, state: st, minWords: 1) {
                i += len
                i += place(entity, &st, tokens: tokens, next: i)
                continue
            }
            // 10. Distinct values of text columns ("France", "West").
            if tok.number == nil, let (hit, len) = matchValueRun(tokens, at: i) { addValueFilter(&st, hit); i += len; continue }
            // 11. Typos.
            if tok.number == nil, !QuestionKeywords.stopwords.contains(tok.lower), !QuestionKeywords.timeGrains.contains(tok.lower),
               let f = lexicon.fuzzy([tok.norm], preferTables: st.preferTables) {
                i += 1
                i += place(f.entity, &st, tokens: tokens, next: i)
                continue
            }
            // 12. Time grains without a matching column fall back to the model's date column.
            if QuestionKeywords.timeGrains.contains(tok.lower) {
                if st.mode == .group || ["daily", "weekly", "monthly", "quarterly", "yearly", "annually", "annual"].contains(tok.lower) { st.overTime = true }
                i += 1; continue
            }
            if QuestionKeywords.stopwords.contains(tok.lower) || tok.lower == "," || tok.lower == "&" { i += 1; continue }
            st.unrecognized.append(tok.text)
            i += 1
        }
        return build(question: question, tokens: tokens, state: st)
    }

    // MARK: Entities

    private func matchEntity(_ tokens: [QToken], at i: Int, state: State, minWords: Int) -> (QEntity, Int)? {
        let maxLen = min(lexicon.maxWords, tokens.count - i)
        guard maxLen >= minWords else { return nil }
        for len in stride(from: maxLen, through: minWords, by: -1) {
            let slice = tokens[i..<(i + len)]
            if slice.contains(where: { $0.quoted }) { continue }
            let words = slice.map(\.norm)
            if let hit = lexicon.lookup(words, preferTables: state.preferTables) {
                // Single reserved words only count as model terms when they are a field's exact, full name.
                if len == 1, QuestionKeywords.stopwords.contains(slice[slice.startIndex].lower), hit.priority < 3 { continue }
                return (hit.entity, len)
            }
        }
        return nil
    }

    /// Assigns a recognised entity to a role. Returns extra tokens consumed (a trailing condition).
    private func place(_ entity: QEntity, _ st: inout State, tokens: [QToken], next: Int) -> Int {
        st.recognized.append(entity.displayName)
        let lower = tokens.map(\.lower)
        switch entity {
        case .table(let t):
            if !st.tables.contains(where: { $0.name == t.name }) { st.tables.append(t) }
            if let agg = st.pendingAgg, agg == .count || agg == .distinctCount, let col = t.keyColumn ?? t.columns.first(where: { $0.isKey })?.name ?? t.columns.first?.name {
                var f = FieldRef.column(t.name, col, .count)
                f.displayName = "Count of \(t.name)"
                st.values.append(f); st.pendingAgg = nil
            }
            return 0
        case .measure(let f):
            st.pendingAgg = nil
            if let (spec, text, len) = parseCondition(tokens, lower: lower, at: next, field: f, column: nil, requireOperator: true) {
                st.filters.append((spec, text))
                addValue(&st, f)
                return len
            }
            if st.mode == .sort { st.sortField = f; addValue(&st, f); st.mode = .none; return 0 }
            if st.mode == .group, st.topN != nil, st.topNBy == nil { st.topNBy = f }
            else if st.mode == .group, !st.groups.isEmpty, st.sortField == nil, st.superlative == nil { st.sortField = f; if st.sortDescending == nil { st.sortDescending = true } }
            addValue(&st, f)
            return 0
        case .column(let f, let col):
            let numeric = col.dataType.isNumeric
            if let agg = st.pendingAgg {
                st.pendingAgg = nil
                let allowed: Bool = numeric || [.count, .distinctCount, .min, .max, .first, .last].contains(agg)
                if allowed {
                    var v = f; v.aggregation = agg == .count && st.preferDistinct && !numeric && !col.isKey ? .distinctCount : agg
                    addValue(&st, v)
                    return 0
                }
            }
            // A condition right after the column makes it a filter subject, not a field of the visual.
            if let (spec, text, len) = parseCondition(tokens, lower: lower, at: next, field: f, column: col, requireOperator: false) {
                st.filters.append((spec, text))
                return len
            }
            let aggregatable = numeric && col.summarizeBy != .none && !col.isKey
            if st.mode == .sort {
                st.mode = .none
                if aggregatable, !st.groups.contains(where: { $0.key == f.key }) {
                    var v = f; v.aggregation = col.summarizeBy
                    st.sortField = v; addValue(&st, v)
                } else { st.sortField = f; addGroup(&st, f, col); if st.sortDescending == nil { st.sortDescending = false } }
                return 0
            }
            if st.mode == .group {
                if aggregatable, st.topN != nil, st.topNBy == nil, !st.groups.isEmpty {
                    var v = f; v.aggregation = col.summarizeBy
                    st.topNBy = v; addValue(&st, v)
                } else { addGroup(&st, f, col) }
                return 0
            }
            if aggregatable, let sup = st.superlative, st.values.isEmpty, !st.awaitingTopNField {
                // "highest price" → MAX(price).
                var v = f; v.aggregation = sup ? .max : .min
                st.superlative = nil
                addValue(&st, v)
            } else if aggregatable {
                var v = f; v.aggregation = col.summarizeBy
                addValue(&st, v)
            } else { addGroup(&st, f, col) }
            return 0
        }
    }

    private func addValue(_ st: inout State, _ f: FieldRef) {
        if !st.values.contains(where: { $0.key == f.key }) { st.values.append(f) }
    }
    private func addGroup(_ st: inout State, _ f: FieldRef, _ col: ModelColumn) {
        if !st.groups.contains(where: { $0.key == f.key }) { st.groups.append(f); st.groupColumns.append(col) }
        if st.awaitingTopNField { st.topNField = f; st.awaitingTopNField = false }
    }

    // MARK: Charts

    private func matchChart(_ tokens: [QToken], lower: [String], at i: Int) -> (VisualType, Int)? {
        func phraseAt(_ p: [String], _ j: Int) -> Bool {
            guard j + p.count <= lower.count else { return false }
            for (k, w) in p.enumerated() where lower[j + k] != w { return false }
            return true
        }
        var lead = 0
        for l in QuestionKeywords.chartLeadIns where phraseAt(l, i) { lead = l.count; break }
        let j = i + lead
        for c in QuestionKeywords.chartTypes where phraseAt(c.phrase, j) {
            let after = j + c.phrase.count
            let hasNoun = after < lower.count && QuestionKeywords.chartNouns.contains(lower[after])
            // Ambiguous words ("line", "table", "map") need a lead-in ("as a …") or a noun ("… chart").
            if hasNoun || c.standalone || (lead > 0 && lower[i] != "in" && lower[i] != "with" && lower[i] != "on") || (lead > 0 && after >= lower.count) {
                return (c.type, lead + c.phrase.count + (hasNoun ? 1 : 0))
            }
        }
        return nil
    }

    // MARK: Conditions

    /// Parses "[is] <operator> <value>", "between A and B" or (for columns) "is <value>" starting at `j`.
    private func parseCondition(_ tokens: [QToken], lower: [String], at j: Int, field: FieldRef, column: ModelColumn?,
                                requireOperator: Bool) -> (FilterSpec, String, Int)? {
        var k = j
        func phraseAt(_ p: [String], _ at: Int) -> Bool {
            guard at + p.count <= lower.count else { return false }
            for (n, w) in p.enumerated() where lower[at + n] != w || tokens[at + n].quoted { return false }
            return true
        }
        // "between A and B"
        var probe = k
        if probe < lower.count, ["is", "are", "was", "were"].contains(lower[probe]) { probe += 1 }
        if phraseAt(["between"], probe), let a = tokens[safe: probe + 1]?.number, tokens[safe: probe + 2]?.lower == "and", let b = tokens[safe: probe + 3]?.number {
            var f = FilterSpec(field: field, kind: .advanced)
            f.conditions = [FilterCondition(op: .greaterOrEqual, value: .double(min(a, b))), FilterCondition(op: .lessOrEqual, value: .double(max(a, b)))]
            return (f, "\(field.caption) is between \(Fmt.number(min(a, b))) and \(Fmt.number(max(a, b)))", probe + 4 - j)
        }
        var op: FilterOperator?
        if let hit = QuestionKeywords.comparisons.first(where: { phraseAt($0.phrase, k) }) { op = hit.op; k += hit.phrase.count }
        else if k < lower.count, ["is", "are", "was", "were"].contains(lower[k]) {
            k += 1
            if let hit = QuestionKeywords.comparisons.first(where: { phraseAt($0.phrase, k) }) { op = hit.op; k += hit.phrase.count }
            else if !requireOperator { op = .equals }
        }
        guard let oper = op else { return nil }
        if !oper.needsValue {
            var f = FilterSpec(field: field, kind: .advanced)
            f.conditions = [FilterCondition(op: oper)]
            return (f, "\(field.caption) \(oper.displayName)", k - j)
        }
        guard let vt = tokens[safe: k] else { return nil }
        var value: Value?
        var consumed = 1
        let numericSubject = column == nil || column!.dataType.isNumeric
        if let num = vt.number, !vt.quoted, numericSubject || [.greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual].contains(oper) {
            value = num == num.rounded() && abs(num) < 1e15 ? .int(Int64(num)) : .double(num)
        } else if column != nil, !numericSubject || vt.quoted {
            // Prefer a known distinct value of this column (longest run of words).
            let known = values(of: field)
            var found = false
            for len in stride(from: min(4, tokens.count - k), through: 1, by: -1) {
                let words = tokens[k..<(k + len)].flatMap { QuestionText.words(of: $0.text) }
                if let v = known[words.joined(separator: " ")] { value = v; consumed = len; found = true; break }
            }
            if !found {
                if [.equals, .notEquals].contains(oper), !vt.quoted, !known.isEmpty { return nil }
                if !vt.quoted, QuestionKeywords.stopwords.contains(vt.lower) || QuestionKeywords.superlativesHigh.contains(vt.lower)
                    || QuestionKeywords.superlativesLow.contains(vt.lower) || lexicon.lookup([vt.norm]) != nil { return nil }
                value = vt.number.map { .double($0) } ?? .string(vt.text)
            }
        }
        guard let v = value else { return nil }
        var f = FilterSpec(field: field, kind: oper == .equals ? .basic : .advanced)
        if oper == .equals { f.values = [v] } else { f.conditions = [FilterCondition(op: oper, value: v)] }
        return (f, "\(field.caption) \(oper.displayName) \(Fmt.label(v))", k + consumed - j)
    }

    // MARK: Distinct values

    private func buildValueIndex() {
        var idx: [String: [(field: FieldRef, value: Value)]] = [:]
        guard let fetch = distinctValues else { valueIndex = [:]; return }
        var columns = 0
        for t in model.tables where !t.isHidden {
            for c in t.columns where !c.isHidden && c.dataType == .text {
                guard columns < 80 else { break }
                columns += 1
                let f = FieldRef.column(t.name, c.name)
                var map: [String: Value] = [:]
                for v in fetch(f).prefix(5000) where !v.isNull {
                    let words = QuestionText.words(of: v.asString)
                    guard !words.isEmpty, words.count <= 4 else { continue }
                    let key = words.joined(separator: " ")
                    if map[key] == nil { map[key] = v; idx[key, default: []].append((f, v)); valueIndexMaxWords = max(valueIndexMaxWords, words.count) }
                }
                columnValues[f.key] = map
            }
        }
        valueIndex = idx
    }

    private func values(of field: FieldRef) -> [String: Value] {
        if valueIndex == nil { buildValueIndex() }
        return columnValues[field.key] ?? [:]
    }

    private func matchValue(words: [String]) -> (field: FieldRef, value: Value)? {
        if valueIndex == nil { buildValueIndex() }
        return valueIndex?[words.joined(separator: " ")]?.first
    }

    private func matchValueRun(_ tokens: [QToken], at i: Int) -> ((field: FieldRef, value: Value), Int)? {
        if valueIndex == nil { buildValueIndex() }
        guard let idx = valueIndex, !idx.isEmpty else { return nil }
        for len in stride(from: min(valueIndexMaxWords, tokens.count - i), through: 1, by: -1) {
            let slice = tokens[i..<(i + len)]
            if slice.contains(where: { $0.quoted }) { continue }
            if len == 1, QuestionKeywords.stopwords.contains(tokens[i].lower) { continue }
            let key = slice.flatMap { QuestionText.words(of: $0.text) }.joined(separator: " ")
            if let hit = idx[key]?.first { return (hit, len) }
        }
        return nil
    }

    private func addValueFilter(_ st: inout State, _ hit: (field: FieldRef, value: Value)) {
        st.recognized.append(hit.value.asString)
        if let i = st.filters.firstIndex(where: { $0.spec.kind == .basic && $0.spec.field.key == hit.field.key }) {
            if !st.filters[i].spec.values.contains(hit.value) {
                st.filters[i].spec.values.append(hit.value)
                st.filters[i].text += " or \(Fmt.label(hit.value))"
            }
            return
        }
        var f = FilterSpec(field: hit.field, kind: .basic)
        f.values = [hit.value]
        st.filters.append((f, "\(hit.field.name) is \(Fmt.label(hit.value))"))
    }

    // MARK: Dates

    private func parseDatePhrase(_ tokens: [QToken], lower: [String], at i: Int, _ st: inout State) -> Int? {
        let w = lower[i]
        let units: [String: (RelativeDateFilter.Unit, RelativeDateFilter.Unit)] = [
            "day": (.days, .days), "days": (.days, .days), "week": (.weeks, .calendarWeeks), "weeks": (.weeks, .calendarWeeks),
            "month": (.months, .calendarMonths), "months": (.months, .calendarMonths), "year": (.years, .calendarYears), "years": (.years, .calendarYears),
            "hour": (.hours, .hours), "hours": (.hours, .hours), "minute": (.minutes, .minutes), "minutes": (.minutes, .minutes),
        ]
        if ["last", "past", "previous", "next", "this", "current"].contains(w) {
            let dir: RelativeDateFilter.Direction = w == "next" ? .next : (w == "this" || w == "current" ? .this : .last)
            var rel = RelativeDateFilter()
            rel.direction = dir
            if let n = tokens[safe: i + 1]?.number, n >= 1, let u = tokens[safe: i + 2].flatMap({ units[$0.lower] }), dir != .this {
                rel.count = Int(n); rel.unit = u.0
                st.pendingRelative.append((rel, "in the \(dir == .next ? "next" : "last") \(Int(n)) \(lower[i + 2])"))
                return 3
            }
            if let u = tokens[safe: i + 1].flatMap({ units[$0.lower] }) {
                rel.count = 1; rel.unit = u.1
                st.pendingRelative.append((rel, "\(dir == .this ? "this" : (dir == .next ? "next" : "last")) \(lower[i + 1])"))
                return 2
            }
            return nil
        }
        if w == "today" || w == "yesterday" {
            var rel = RelativeDateFilter()
            rel.direction = w == "today" ? .this : .last; rel.count = 1; rel.unit = .days
            st.pendingRelative.append((rel, w))
            return 1
        }
        if matchWords(lower, ["year", "to", "date"], i) || w == "ytd" {
            var rel = RelativeDateFilter()
            rel.direction = .this; rel.count = 1; rel.unit = .calendarYears
            st.pendingRelative.append((rel, "this year"))
            return w == "ytd" ? 1 : 3
        }
        func isYear(_ t: QToken?) -> Int? {
            guard let t, !t.quoted, let n = t.number, n == n.rounded(), n >= 1900, n <= 2100, t.text.count == 4 else { return nil }
            return Int(n)
        }
        let cal = Calendar.utc
        func ymd(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date(timeIntervalSince1970: 0) }
        // "March 2025"
        if let m = QuestionKeywords.months[w], let y = isYear(tokens[safe: i + 1]) {
            let start = ymd(y, m), end = cal.date(byAdding: .month, value: 1, to: start)
            st.pendingDateRanges.append((start, end, "in \(DateParsing.string(start, format: "MMMM yyyy"))"))
            return 2
        }
        // "since 2023", "before 2024", "after 2023", "in 2025"
        if ["since", "before", "after", "until"].contains(w), let y = isYear(tokens[safe: i + 1]) {
            switch w {
            case "since": st.pendingDateRanges.append((ymd(y, 1), nil, "since \(y)"))
            case "after": st.pendingDateRanges.append((ymd(y + 1, 1), nil, "after \(y)"))
            default: st.pendingDateRanges.append((nil, ymd(y, 1), "before \(y)"))
            }
            return 2
        }
        if ["in", "for", "during", "of", "year"].contains(w), let y = isYear(tokens[safe: i + 1]) {
            st.pendingYears.append(y)
            return 2
        }
        if ["in", "for", "during", "of"].contains(w), let m = tokens[safe: i + 1].flatMap({ QuestionKeywords.months[$0.lower] }), let y = isYear(tokens[safe: i + 2]) {
            let start = ymd(y, m), end = cal.date(byAdding: .month, value: 1, to: start)
            st.pendingDateRanges.append((start, end, "in \(DateParsing.string(start, format: "MMMM yyyy"))"))
            return 3
        }
        if let y = isYear(tokens[i]), st.mode == .filter || i == tokens.count - 1 || tokens[safe: i + 1]?.lower == "and" || tokens[safe: i - 1]?.lower == "and" {
            st.pendingYears.append(y)
            return 1
        }
        return nil
    }

    private func matchWords(_ lower: [String], _ p: [String], _ at: Int) -> Bool {
        guard at + p.count <= lower.count else { return false }
        for (n, w) in p.enumerated() where lower[at + n] != w { return false }
        return true
    }
}
