import Foundation
import FacetCore

/// Text utilities shared by the Q&A parser.
enum QuestionText {
    /// Lowercases and reduces a word to a crude singular form so "Regions" matches "region".
    static func normalise(_ word: String) -> String {
        let w = word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard w.count > 3 else { return w }
        if w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") || w.hasSuffix("shes") || w.hasSuffix("ches") || w.hasSuffix("xes") { return String(w.dropLast(2)) }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }

    /// Splits a model name ("OrderDate", "unit_price", "Sales Amount") into normalised words.
    static func words(of name: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prev: Character?
        func flush() { if !cur.isEmpty { out.append(normalise(cur)); cur = "" } }
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if let p = prev, (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter) { flush() }
                cur.append(ch)
            } else { flush() }
            prev = ch
        }
        flush()
        return out
    }

    /// Levenshtein distance with an upper bound (returns `limit + 1` when exceeded).
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// Allowed typos for a term of a given length.
    static func fuzzyLimit(_ length: Int) -> Int { length >= 8 ? 2 : (length >= 5 ? 1 : 0) }
}

/// One token of a question.
struct QToken {
    var text: String        // original spelling
    var lower: String       // lowercased
    var norm: String        // lowercased + singularised
    var number: Double?
    var quoted = false
}

enum QuestionTokenizer {
    static func tokenize(_ question: String) -> [QToken] {
        var out: [QToken] = []
        let chars = Array(question)
        var i = 0
        func push(_ s: String, quoted: Bool = false) {
            guard !s.isEmpty else { return }
            var t = QToken(text: s, lower: s.lowercased(), norm: QuestionText.normalise(s), number: nil, quoted: quoted)
            if !quoted { t.number = parseNumber(s) }
            out.append(t)
        }
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            // Quoted phrases.
            let isQuote = ch == "\"" || ch == "“" || ch == "”" || (ch == "'" && (i == 0 || chars[i - 1].isWhitespace))
            if isQuote {
                var j = i + 1; var s = ""
                while j < chars.count, !(chars[j] == "\"" || chars[j] == "”" || chars[j] == "“" || (ch == "'" && chars[j] == "'")) { s.append(chars[j]); j += 1 }
                push(s, quoted: true)
                i = j + 1; continue
            }
            // Comparison operators.
            if "<>=!".contains(ch) {
                var s = String(ch)
                if i + 1 < chars.count, chars[i + 1] == "=" || (ch == "<" && chars[i + 1] == ">") { s.append(chars[i + 1]); i += 1 }
                push(s); i += 1; continue
            }
            if ch == "," || ch == "&" { push(String(ch)); i += 1; continue }
            if ch.isLetter || ch.isNumber || ch == "$" || ch == "_" {
                var s = ""
                while i < chars.count {
                    let c = chars[i]
                    let inNumber = !s.isEmpty && (s.last!.isNumber) && (c == "." || c == ",") && i + 1 < chars.count && chars[i + 1].isNumber
                    if c.isLetter || c.isNumber || c == "_" || c == "$" || c == "%" || c == "'" || inNumber { s.append(c); i += 1 } else { break }
                }
                if s.hasSuffix("'s") { s.removeLast(2) }
                push(s); continue
            }
            i += 1 // punctuation
        }
        return out
    }

    /// Parses "100", "1,000", "2.5", "$40", "10k", "1.5m", "25%".
    static func parseNumber(_ s: String) -> Double? {
        var t = s.lowercased().replacingOccurrences(of: ",", with: "")
        if t.hasPrefix("$") { t.removeFirst() }
        var scale = 1.0
        if t.hasSuffix("%") { t.removeLast(); scale = 0.01 }
        else if t.hasSuffix("k") { t.removeLast(); scale = 1e3 }
        else if t.hasSuffix("m") { t.removeLast(); scale = 1e6 }
        else if t.hasSuffix("bn") { t.removeLast(2); scale = 1e9 }
        guard let f = t.first, f.isNumber || f == ".", let d = Double(t) else { return nil }
        return d * scale
    }
}

/// What a term in the question refers to.
enum QEntity {
    case measure(FieldRef)
    case column(FieldRef, ModelColumn)
    case table(ModelTable)

    var displayName: String {
        switch self {
        case .measure(let f): return f.name
        case .column(let f, _): return f.name
        case .table(let t): return t.name
        }
    }
    var tableName: String {
        switch self {
        case .measure(let f): return f.table
        case .column(let f, _): return f.table
        case .table(let t): return t.name
        }
    }
    var rank: Int { switch self { case .measure: return 0; case .column: return 1; case .table: return 2 } }
}

/// Vocabulary built from the semantic model: names and synonyms of tables, columns and measures.
struct QuestionLexicon {
    struct Entry { var entity: QEntity; var priority: Int; var words: [String] }
    /// Normalised phrase → entries.
    private(set) var phrases: [String: [Entry]] = [:]
    private(set) var maxWords = 1
    /// All full-name entries, in model order (for suggestions and completions).
    private(set) var entities: [QEntity] = []

    init(model: SemanticModel, synonyms: [String: [String]]) {
        var extra: [String: [String]] = [:]
        for (k, v) in model.qnaSynonyms { extra[QuestionLexicon.identifierKey(k), default: []] += v }
        for (k, v) in synonyms { extra[QuestionLexicon.identifierKey(k), default: []] += v }
        func syns(_ ids: [String]) -> [String] { ids.flatMap { extra[QuestionLexicon.identifierKey($0)] ?? [] } }
        for t in model.tables where !t.isHidden {
            let te = QEntity.table(t)
            entities.append(te)
            add(t.name, te, 3)
            for s in t.synonyms + syns([t.name]) { add(s, te, 3) }
            for m in t.measures where !m.isHidden {
                let e = QEntity.measure(.measure(t.name, m.name))
                entities.append(e)
                add(m.name, e, 4)
                for s in syns([m.name, "\(t.name)[\(m.name)]"]) { add(s, e, 4) }
                addPartials(m.name, e)
            }
            for c in t.columns where !c.isHidden {
                let e = QEntity.column(.column(t.name, c.name), c)
                entities.append(e)
                add(c.name, e, 3)
                for s in c.synonyms + syns([c.name, "\(t.name)[\(c.name)]"]) { add(s, e, 3) }
                // "customer name" for column Name of table Customers.
                add("\(t.name) \(c.name)", e, 3)
                addPartials(c.name, e)
            }
        }
    }

    /// Canonical form of a synonym-dictionary key: "Table[Column]", "'Table'[Column]" or a bare name.
    static func identifierKey(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
    }

    private mutating func add(_ phrase: String, _ entity: QEntity, _ priority: Int) {
        let words = QuestionText.words(of: phrase)
        guard !words.isEmpty else { return }
        let key = words.joined(separator: " ")
        if phrases[key]?.contains(where: { $0.entity.displayName == entity.displayName && $0.entity.tableName == entity.tableName && $0.entity.rank == entity.rank }) == true { return }
        phrases[key, default: []].append(Entry(entity: entity, priority: priority, words: words))
        maxWords = max(maxWords, words.count)
    }

    /// Single words of a multi-word name act as low-priority aliases ("amount" → "Sales Amount").
    private mutating func addPartials(_ name: String, _ entity: QEntity) {
        let words = QuestionText.words(of: name)
        guard words.count > 1 else { return }
        for w in words where w.count >= 4 && !QuestionKeywords.reserved.contains(w) { add(w, entity, 1) }
    }

    /// Best entity for an exact (normalised) phrase.
    func lookup(_ words: [String], preferTables: Set<String> = []) -> (entity: QEntity, priority: Int)? {
        guard let list = phrases[words.joined(separator: " ")], !list.isEmpty else { return nil }
        let best = list.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let pa = preferTables.contains(a.entity.tableName), pb = preferTables.contains(b.entity.tableName)
            if pa != pb { return pa }
            return a.entity.rank < b.entity.rank
        }[0]
        // A low-priority alias shared by several different fields is too ambiguous to use.
        if best.priority == 1, list.filter({ $0.priority == 1 }).count > 1,
           !preferTables.contains(best.entity.tableName) { return nil }
        return (best.entity, best.priority)
    }

    /// A measure that shares its name with a table ("Sales" → [Total Sales]), so "sales by region" charts the measure.
    func aliasMeasure(forTable t: ModelTable) -> FieldRef? {
        let key = QuestionText.words(of: t.name).joined(separator: " ")
        for e in phrases[key] ?? [] { if case .measure(let f) = e.entity { return f } }
        return nil
    }

    /// Closest phrase within the typo budget, for a single unknown word or short phrase.
    func fuzzy(_ words: [String], preferTables: Set<String> = []) -> (entity: QEntity, phrase: String, distance: Int)? {
        let key = words.joined(separator: " ")
        let limit = QuestionText.fuzzyLimit(key.count)
        guard limit > 0 else { return nil }
        var best: (QEntity, String, Int)?
        for (phrase, list) in phrases.sorted(by: { $0.key < $1.key }) where list.contains(where: { $0.priority > 1 }) {
            guard list[0].words.count == words.count, phrase.first == key.first else { continue }
            let d = QuestionText.editDistance(key, phrase, limit: limit)
            if d <= limit, d < (best?.2 ?? Int.max), let e = lookup(list[0].words, preferTables: preferTables) { best = (e.entity, phrase, d) }
        }
        return best.map { (entity: $0.0, phrase: $0.1, distance: $0.2) }
    }

    /// Nearest term regardless of the typo budget (for "did you mean" suggestions).
    func nearest(_ word: String) -> String? {
        let limit = max(2, word.count / 2)
        var best: (String, Int)?
        for e in entities {
            let name = e.displayName
            let d = QuestionText.editDistance(QuestionText.normalise(word), QuestionText.words(of: name).joined(separator: " "), limit: limit)
            if d <= limit, d < (best?.1 ?? Int.max) { best = (name, d) }
        }
        return best?.0
    }
}

/// Fixed vocabulary of the question grammar.
enum QuestionKeywords {
    static let stopwords: Set<String> = [
        "show", "me", "what", "is", "are", "was", "were", "the", "a", "an", "of", "give", "display", "list", "please", "which",
        "tell", "do", "does", "did", "we", "have", "has", "had", "our", "my", "their", "its", "that", "this", "these", "those",
        "to", "on", "at", "it", "be", "been", "get", "find", "see", "view", "plot", "draw", "chart", "graph", "visualize",
        "much", "all", "each", "any", "there", "who", "whom", "can", "you", "i", "us", "want", "need", "like", "would",
        "compare", "compared", "breakdown", "report", "data", "value", "values", "amount", "how", "many", "about", "only",
        "made", "make", "sold", "got", "with", "for", "in", "from", "during", "where", "whose", "having", "when", "and", "or",
        "as", "by", "per", "than", "then", "also", "just", "total", "overall", "across", "sum", "s",
        "over", "under", "above", "below", "between", "not", "top", "bottom", "last", "next", "past", "previous", "current",
    ]
    /// Words that must never become single-word aliases of a field.
    static let reserved: Set<String> = stopwords.union([
        "average", "count", "number", "top", "bottom", "last", "next", "year", "month", "week", "day", "quarter", "date",
        "time", "name", "type", "line", "bar", "table", "over", "under", "above", "below", "between", "sort", "sorted", "order",
    ])
    static let aggregations: [(phrase: [String], agg: Aggregation)] = [
        (["distinct", "count", "of"], .distinctCount), (["count", "of", "distinct"], .distinctCount), (["count", "of", "unique"], .distinctCount),
        (["number", "of", "distinct"], .distinctCount), (["number", "of", "unique"], .distinctCount), (["how", "many", "distinct"], .distinctCount),
        (["how", "many", "unique"], .distinctCount), (["how", "many", "different"], .distinctCount), (["unique"], .distinctCount), (["distinct"], .distinctCount),
        (["standard", "deviation", "of"], .stdDev), (["standard", "deviation"], .stdDev),
        (["count", "of"], .count), (["number", "of"], .count), (["how", "many"], .count), (["count"], .count),
        (["sum", "of"], .sum), (["total", "of"], .sum), (["total"], .sum), (["sum"], .sum),
        (["average", "of"], .average), (["average"], .average), (["avg"], .average), (["mean"], .average),
        (["maximum"], .max), (["max"], .max), (["largest"], .max), (["biggest"], .max),
        (["minimum"], .min), (["min"], .min), (["smallest"], .min),
        (["median"], .median), (["variance", "of"], .variance), (["variance"], .variance),
    ]
    static let groupMarkers: [[String]] = [
        ["grouped", "by"], ["group", "by"], ["broken", "down", "by"], ["split", "by"], ["segmented", "by"], ["for", "each"],
        ["for", "every"], ["by"], ["per"], ["across"],
    ]
    static let sortMarkers: [[String]] = [["sorted", "by"], ["sort", "by"], ["ordered", "by"], ["order", "by"], ["ranked", "by"], ["rank", "by"]]
    static let superlativesHigh: Set<String> = ["highest", "most", "best", "greatest", "top"]
    static let superlativesLow: Set<String> = ["lowest", "least", "worst", "fewest"]
    static let chartTypes: [(phrase: [String], type: VisualType, standalone: Bool)] = [
        (["stacked", "bar"], .stackedBar, false), (["stacked", "column"], .stackedColumn, false), (["stacked", "area"], .stackedArea, false),
        (["clustered", "bar"], .clusteredBar, false), (["clustered", "column"], .clusteredColumn, false),
        (["filled", "map"], .filledMap, true), (["line"], .line, false), (["bar"], .clusteredBar, false), (["column"], .clusteredColumn, false),
        (["area"], .area, false), (["pie"], .pie, true), (["donut"], .donut, true), (["doughnut"], .donut, true),
        (["scatter"], .scatter, true), (["scatterplot"], .scatter, true), (["bubble"], .scatter, true), (["map"], .map, false),
        (["table"], .table, false), (["matrix"], .matrix, true), (["card"], .card, false), (["treemap"], .treemap, true),
        (["funnel"], .funnel, true), (["waterfall"], .waterfall, true), (["gauge"], .gauge, true), (["kpi"], .kpi, true),
        (["histogram"], .histogram, true), (["heatmap"], .heatmap, true), (["ribbon"], .ribbon, false), (["list"], .table, false),
    ]
    static let chartLeadIns: [[String]] = [["show", "as", "a"], ["show", "as", "an"], ["show", "as"], ["as", "a"], ["as", "an"], ["as"], ["in", "a"], ["in", "an"],
                                            ["on", "a"], ["using", "a"], ["using", "an"], ["with", "a"]]
    static let chartNouns: Set<String> = ["chart", "graph", "plot", "visual", "diagram"]
    static let timeGrains: Set<String> = ["daily", "weekly", "monthly", "quarterly", "yearly", "annually", "annual", "day", "week", "month",
                                          "quarter", "year", "date", "time"]
    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6,
        "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10,
        "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    static let comparisons: [(phrase: [String], op: FilterOperator)] = [
        (["is", "not", "blank"], .isNotBlank), (["is", "blank"], .isBlank),
        (["greater", "than", "or", "equal", "to"], .greaterOrEqual), (["less", "than", "or", "equal", "to"], .lessOrEqual),
        (["at", "least"], .greaterOrEqual), (["at", "most"], .lessOrEqual), (["no", "more", "than"], .lessOrEqual), (["no", "less", "than"], .greaterOrEqual),
        (["greater", "than"], .greaterThan), (["more", "than"], .greaterThan), (["higher", "than"], .greaterThan), (["bigger", "than"], .greaterThan),
        (["larger", "than"], .greaterThan), (["over"], .greaterThan), (["above"], .greaterThan), (["exceeds"], .greaterThan), (["exceeding"], .greaterThan),
        (["less", "than"], .lessThan), (["fewer", "than"], .lessThan), (["lower", "than"], .lessThan), (["smaller", "than"], .lessThan),
        (["under"], .lessThan), (["below"], .lessThan),
        (["does", "not", "contain"], .notContains), (["not", "containing"], .notContains), (["contains"], .contains), (["containing"], .contains),
        (["starts", "with"], .startsWith), (["starting", "with"], .startsWith), (["begins", "with"], .startsWith),
        (["ends", "with"], .endsWith), (["ending", "with"], .endsWith),
        (["not", "equal", "to"], .notEquals), (["is", "not"], .notEquals), (["isn't"], .notEquals), (["isnt"], .notEquals), (["not"], .notEquals),
        (["!="], .notEquals), (["<>"], .notEquals), ([">="], .greaterOrEqual), (["<="], .lessOrEqual), ([">"], .greaterThan), (["<"], .lessThan),
        (["equal", "to"], .equals), (["equals"], .equals), (["="], .equals), (["=="], .equals),
    ]
}
