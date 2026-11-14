import Foundation
import FacetCore

/// Fuzzy text matching used by `Table.FuzzyNestedJoin` / `Table.FuzzyJoin`.
///
/// Power Query does not publish its exact similarity measure. Facet scores two keys as
/// `1 − editDistance / longerLength` (edit distance counts insertions, deletions, substitutions and swaps of
/// adjacent characters) after the documented normalisations: case folding (`IgnoreCase`), removing white space
/// (`IgnoreSpace`) and the From → To substitutions of a `TransformationTable`. A threshold of 1 therefore keeps
/// only keys that are equal after normalisation, and 0 matches everything, as documented.
public enum FuzzyMatch {
    public struct Options {
        public var threshold = 0.8
        public var ignoreCase = true
        public var ignoreSpace = true
        public var maximumMatches: Int?
        /// Normalised From → To.
        public var transformations: [String: String] = [:]
        public init() {}
    }

    public static func normalise(_ s: String, _ o: Options) -> String {
        func fold(_ x: String) -> String { o.ignoreCase ? x.lowercased() : x }
        let mapping = Dictionary(o.transformations.map { (fold($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        var words = s.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let whole = fold(s.trimmingCharacters(in: .whitespaces))
        if let to = mapping[whole] { words = to.split(whereSeparator: \.isWhitespace).map { fold(String($0)) } }
        else { words = words.map { mapping[$0].map(fold) ?? $0 } }
        return words.joined(separator: o.ignoreSpace ? "" : " ")
    }
    /// Optimal-string-alignment edit distance.
    public static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev2 = [Int](repeating: 0, count: b.count + 1), prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
            }
            prev2 = prev; prev = cur
        }
        return prev[b.count]
    }
    /// Similarity in 0…1 of two texts under the options.
    public static func similarity(_ x: String, _ y: String, _ o: Options = Options()) -> Double {
        let a = Array(normalise(x, o)), b = Array(normalise(y, o))
        if a == b { return 1 }
        let longer = max(a.count, b.count)
        return longer == 0 ? 1 : 1 - Double(editDistance(a, b)) / Double(longer)
    }
}

/// Which right rows each left row matched, and which right rows matched nothing.
struct JoinMatches {
    var perLeft: [[Int]]
    var unmatchedRight: [Int]
    /// Similarity of each match (fuzzy joins only), parallel to `perLeft`.
    var scores: [[Double]]?
}

extension MLibrary {
    static func exactMatches(_ left: MTable, _ lk: [Int], _ right: MTable, _ rk: [Int]) throws -> JoinMatches {
        guard lk.count == rk.count else { throw MError("The join needs the same number of key columns on both sides.") }
        let lc = try left.columns, rc = try right.columns
        var index: [MKey: [Int]] = [:]
        for r in 0..<(try right.rowCount) { index[MLib.rowKey(rc, rk, r), default: []].append(r) }
        var used = Set<Int>(), perLeft: [[Int]] = []
        for l in 0..<(try left.rowCount) {
            let hits = index[MLib.rowKey(lc, lk, l)] ?? []
            used.formUnion(hits); perLeft.append(hits)
        }
        return JoinMatches(perLeft: perLeft, unmatchedRight: (0..<(try right.rowCount)).filter { !used.contains($0) }, scores: nil)
    }

    static func fuzzyOptions(_ record: MRecord?) throws -> FuzzyMatch.Options {
        var o = FuzzyMatch.Options()
        guard let r = record else { return o }
        if let t = try r.number("Threshold") {
            guard t >= 0, t <= 1 else { throw MError("The fuzzy matching threshold must be between 0 and 1.", detail: .number(t)) }
            o.threshold = t
        }
        o.ignoreCase = try r.logical("IgnoreCase") ?? true
        o.ignoreSpace = try r.logical("IgnoreSpace") ?? true
        if let n = try r.number("NumberOfMatches") { o.maximumMatches = max(1, Int(n)) }
        if case .table(let tt)? = try r.get("TransformationTable") {
            let from = try tt.column("From"), to = try tt.column("To")
            for (f, t) in zip(from, to) {
                if case .text(let fs) = f.forcedCell(), case .text(let ts) = t.forcedCell() { o.transformations[fs] = ts }
            }
        }
        return o
    }

    static func fuzzyMatches(_ left: MTable, _ lk: [Int], _ right: MTable, _ rk: [Int], _ o: FuzzyMatch.Options) throws -> JoinMatches {
        guard lk.count == rk.count else { throw MError("The join needs the same number of key columns on both sides.") }
        let lc = try left.columns, rc = try right.columns, rn = try right.rowCount
        func score(_ x: MValue, _ y: MValue) -> Double {
            if x.isNull || y.isNull { return 0 }
            if case .text(let a) = x, case .text(let b) = y { return FuzzyMatch.similarity(a, b, o) }
            return MValue.equals(x, y) ? 1 : 0
        }
        var used = Set<Int>(), perLeft: [[Int]] = [], scores: [[Double]] = []
        for l in 0..<(try left.rowCount) {
            var hits: [(Int, Double)] = []
            for r in 0..<rn {
                let s = zip(lk, rk).map { score(lc[$0][l].forcedCell(), rc[$1][r].forcedCell()) }.min() ?? 0
                if s >= o.threshold, s > 0 || o.threshold == 0 { hits.append((r, s)) }
            }
            hits = hits.enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 > $1.element.1 }.map(\.element)
            if let m = o.maximumMatches { hits = Array(hits.prefix(m)) }
            used.formUnion(hits.map(\.0)); perLeft.append(hits.map(\.0)); scores.append(hits.map(\.1))
        }
        return JoinMatches(perLeft: perLeft, unmatchedRight: (0..<rn).filter { !used.contains($0) }, scores: scores)
    }

    /// `Table.NestedJoin`: the left table plus a column of nested right tables.
    static func nestedJoin(_ left: MTable, _ right: MTable, _ m: JoinMatches, newColumn: String, kind: Int) throws -> MTable {
        let lc = try left.columns
        var rows: [Int?] = [] // left row index, nil = the row that carries unmatched right rows
        for l in 0..<m.perLeft.count {
            let matched = !m.perLeft[l].isEmpty
            switch kind {
            case 0, 2, 6, 7: if matched { rows.append(l) }
            case 4: if !matched { rows.append(l) }
            case 5: break
            default: rows.append(l)
            }
        }
        if [2, 3, 5].contains(kind), !m.unmatchedRight.isEmpty { rows.append(nil) }
        var cols = lc.map { c in rows.map { $0.map { c[$0] } ?? .null } }
        cols.append(try rows.map { .table(try right.selecting(rows: $0.map { m.perLeft[$0] } ?? m.unmatchedRight)) })
        return try MTable.make(left.columnNames + [newColumn], left.columnTypes + [right.tableType], cols, rows: rows.count)
    }

    /// `Table.Join`: a flat join. Key columns with the same name on both sides are merged into one.
    static func flatJoin(_ left: MTable, _ lk: [Int], _ right: MTable, _ rk: [Int], _ m: JoinMatches, kind: Int,
                         similarityColumn: String? = nil) throws -> MTable {
        let lc = try left.columns, rc = try right.columns
        var mergedRight: [Int: Int] = [:] // right column → left column it merges into
        for (l, r) in zip(lk, rk) where left.columnNames[l] == right.columnNames[r] { mergedRight[r] = l }
        let rightKept = (0..<right.columnCount).filter { mergedRight[$0] == nil }
        if let clash = rightKept.map({ right.columnNames[$0] }).first(where: { left.columnIndex($0) != nil }) {
            throw MError("A join operation cannot result in a table with duplicate column names (\"\(clash)\").", detail: .text(clash))
        }
        var pairs: [(Int?, Int?, Double?)] = []
        for l in 0..<m.perLeft.count {
            let hits = m.perLeft[l]
            switch kind {
            case 4: if hits.isEmpty { pairs.append((l, nil, nil)) }
            case 5: break
            case 6: if !hits.isEmpty { pairs.append((l, nil, nil)) }
            default:
                for (k, r) in hits.enumerated() { pairs.append((l, r, m.scores?[l][k])) }
                if hits.isEmpty, kind == 1 || kind == 3 { pairs.append((l, nil, nil)) }
            }
        }
        if [2, 3, 5].contains(kind) { for r in m.unmatchedRight { pairs.append((nil, r, nil)) } }
        var cols: [[MValue]] = []
        for c in 0..<left.columnCount {
            let fromRight = mergedRight.first { $0.value == c }?.key
            cols.append(pairs.map { l, r, _ in l.map { lc[c][$0] } ?? (fromRight.flatMap { fr in r.map { rc[fr][$0] } } ?? .null) })
        }
        for c in rightKept { cols.append(pairs.map { _, r, _ in r.map { rc[c][$0] } ?? .null }) }
        var names = left.columnNames + rightKept.map { right.columnNames[$0] }
        var types = left.columnTypes + rightKept.map { right.columnTypes[$0] }
        if let similarityColumn {
            names.append(similarityColumn); types.append(.plainNumber)
            cols.append(pairs.map { .optNumber($0.2) })
        }
        return try MTable.make(names, types, cols, rows: pairs.count)
    }

    static func registerTableJoins(_ lib: MLibrary) {
        func keys(_ a: MArgs, _ table: Int, _ key: Int) throws -> (MTable, [Int]) {
            let t = try a.table(table)
            return (t, try t.requiredIndices(try a.textList(key)))
        }
        for name in ["Table.NestedJoin", "Table.AddJoinColumn"] {
            lib.fn(name, 5...7) { a, ctx in
                let (l, lk) = try keys(a, 0, 1), (r, rk) = try keys(a, 2, 3), kind = try a.optInt(5) ?? 1
                if l.isLazy, !a.has(6) || a[6].isNull,
                   let folded = l.folded(.nestedJoin(leftKeys: try a.textList(1), right: r, rightKeys: try a.textList(3), newColumn: try a.text(4), kind: kind), ctx) {
                    return .table(folded)
                }
                return .table(try nestedJoin(l, r, try exactMatches(l, lk, r, rk), newColumn: try a.text(4), kind: kind))
            }
        }
        lib.fn("Table.Join", 4...8) { a, ctx in
            let (l, lk) = try keys(a, 0, 1), (r, rk) = try keys(a, 2, 3), kind = try a.optInt(4) ?? 0
            if l.isLazy, !a.has(6) || a[6].isNull,
               let folded = l.folded(.join(leftKeys: try a.textList(1), right: r, rightKeys: try a.textList(3), kind: kind), ctx) {
                return .table(folded)
            }
            return .table(try flatJoin(l, lk, r, rk, try exactMatches(l, lk, r, rk), kind: kind))
        }
        lib.fn("Table.FuzzyNestedJoin", 5...7) { a, _ in
            let (l, lk) = try keys(a, 0, 1), (r, rk) = try keys(a, 2, 3)
            let m = try fuzzyMatches(l, lk, r, rk, try fuzzyOptions(try a.optRecord(6)))
            return .table(try nestedJoin(l, r, m, newColumn: try a.text(4), kind: try a.optInt(5) ?? 1))
        }
        lib.fn("Table.FuzzyJoin", 4...6) { a, _ in
            let (l, lk) = try keys(a, 0, 1), (r, rk) = try keys(a, 2, 3), options = try a.optRecord(5)
            let m = try fuzzyMatches(l, lk, r, rk, try fuzzyOptions(options))
            return .table(try flatJoin(l, lk, r, rk, m, kind: try a.optInt(4) ?? 0, similarityColumn: try options?.text("SimilarityColumnName")))
        }
    }
}
