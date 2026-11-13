import Foundation
import FacetCore

extension MText {
    /// Split on any of `delimiters` (longest first). With `csv`, a field that starts with `"` runs to its closing quote
    /// (`""` is an escaped quote), delimiters inside it are data and the quotes are removed.
    /// `limit` stops after that many splits; the remainder is returned verbatim as the last part.
    static func split(_ text: String, delimiters: [String], csv: Bool, limit: Int? = nil) -> [String] {
        let cs = Array(text), ds = delimiters.filter { !$0.isEmpty }.map(Array.init).sorted { $0.count > $1.count }
        guard !ds.isEmpty else { return [text] }
        var parts: [String] = [], field: [Character] = [], i = 0, atFieldStart = true
        func delimiter(at i: Int) -> Int? {
            for d in ds where i + d.count <= cs.count && cs[i] == d[0] && Array(cs[i..<(i + d.count)]) == d { return d.count }
            return nil
        }
        while i < cs.count {
            if let limit, parts.count >= limit { field.append(contentsOf: cs[i...]); i = cs.count; break }
            if csv, atFieldStart, cs[i] == "\"" {
                i += 1
                while i < cs.count {
                    if cs[i] == "\"" {
                        if i + 1 < cs.count, cs[i + 1] == "\"" { field.append("\""); i += 2; continue }
                        i += 1; break
                    }
                    field.append(cs[i]); i += 1
                }
                atFieldStart = false
                continue
            }
            if let n = delimiter(at: i) {
                parts.append(String(field)); field = []; i += n; atFieldStart = true
                continue
            }
            field.append(cs[i]); i += 1; atFieldStart = false
        }
        parts.append(String(field))
        return parts
    }
    /// Quote a field for CSV output when it contains the delimiter, a quote or a line break.
    static func csvQuoted(_ s: String, delimiter: String) -> String {
        guard s.contains("\"") || s.contains("\n") || s.contains("\r") || (!delimiter.isEmpty && s.contains(delimiter)) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    /// Cut at character positions; each part runs to the next position.
    static func cut(_ cs: [Character], at positions: [Int]) -> [String] {
        positions.enumerated().map { k, p in
            let start = min(max(p, 0), cs.count), end = k + 1 < positions.count ? min(max(positions[k + 1], start), cs.count) : cs.count
            return String(cs[start..<end])
        }
    }
}

extension MLibrary {
    /// A splitter: `text → list of text`. Null input gives an empty list.
    private static func splitter(_ body: @escaping (String, MInterpreter) throws -> [String]) -> MValue {
        .function(MFunction(name: "Splitter", minArgs: 1, maxArgs: 1) { a, ctx in
            if a[0].isNull { return .list([]) }
            return .list(try body(try MConvert.text(a[0], culture: ctx.culture), ctx).map(MValue.text))
        })
    }
    private static func ints(_ a: MArgs, _ i: Int) throws -> [Int] {
        try a.forcedList(i).map { v in
            guard case .number(let d) = v, d >= 0 else { throw MError("\(a.functionName): positions must be non-negative numbers.") }
            return Int(d)
        }
    }

    static func registerSplitters(_ lib: MLibrary) {
        func csv(_ a: MArgs, _ i: Int) throws -> Bool { (try a.optInt(i) ?? 1) == 1 }
        lib.fn("Splitter.SplitTextByDelimiter", 1...2) { a, _ in
            let d = try a.text(0), quoted = try csv(a, 1)
            return splitter { s, _ in MText.split(s, delimiters: [d], csv: quoted) }
        }
        lib.fn("Splitter.SplitTextByAnyDelimiter", 1...3) { a, _ in
            let ds = try a.textList(0), quoted = try csv(a, 1)
            return splitter { s, _ in MText.split(s, delimiters: ds, csv: quoted) }
        }
        lib.fn("Splitter.SplitTextByEachDelimiter", 1...3) { a, _ in
            let ds = try a.textList(0), quoted = try csv(a, 1), fromEnd = try a.optLogical(2) ?? false
            return splitter { s, _ in
                var parts: [String] = [], rest = s
                for d in fromEnd ? ds.reversed() : ds {
                    if fromEnd {
                        let cs = Array(rest)
                        guard let at = MText.occurrences(of: Array(d), in: cs).last else { break }
                        parts.insert(String(cs[(at + d.count)...]), at: 0)
                        rest = String(cs[..<at])
                    } else {
                        let pieces = MText.split(rest, delimiters: [d], csv: quoted, limit: 1)
                        guard pieces.count == 2 else { break }
                        parts.append(pieces[0]); rest = pieces[1]
                    }
                }
                if fromEnd { parts.insert(rest, at: 0) } else { parts.append(rest) }
                return parts
            }
        }
        lib.fn("Splitter.SplitTextByWhitespace", 0...1) { _, _ in
            splitter { s, _ in s.split(whereSeparator: \.isWhitespace).map(String.init) }
        }
        lib.fn("Splitter.SplitTextByPositions", 1...2) { a, _ in
            let positions = try ints(a, 0), fromEnd = try a.optLogical(1) ?? false
            return splitter { s, _ in
                let cs = Array(s)
                if !fromEnd { return MText.cut(cs, at: positions) }
                return MText.cut(cs, at: positions.reversed().map { cs.count - $0 }.map { max(0, $0) }.sorted())
            }
        }
        lib.fn("Splitter.SplitTextByRanges", 1...2) { a, _ in
            let ranges = try a.forcedList(0).map { v -> (Int, Int) in
                guard case .list(let p) = v, p.count == 2, let o = try p[0].forced().numberValue, let n = try p[1].forced().numberValue else {
                    throw MError("Splitter.SplitTextByRanges: each range must be {offset, length}.")
                }
                return (Int(o), Int(n))
            }
            return splitter { s, _ in
                let cs = Array(s)
                return ranges.map { o, n in String(cs.dropFirst(o).prefix(n)) }
            }
        }
        lib.fn("Splitter.SplitTextByLengths", 1...2) { a, _ in
            let lengths = try ints(a, 0)
            return splitter { s, _ in
                var cs = Array(s)[...]
                return lengths.map { n in let part = String(cs.prefix(n)); cs = cs.dropFirst(n); return part }
            }
        }
        lib.fn("Splitter.SplitTextByRepeatedLengths", 1...2) { a, _ in
            let length = try a.int(0)
            guard length > 0 else { throw MError("Splitter.SplitTextByRepeatedLengths: the length must be positive.") }
            return splitter { s, _ in
                let cs = Array(s)
                return stride(from: 0, to: cs.count, by: length).map { String(cs[$0..<min($0 + length, cs.count)]) }
            }
        }
        lib.fn("Splitter.SplitTextByCharacterTransition", 2) { a, _ in
            func matcher(_ v: MValue) throws -> (Character, MInterpreter) throws -> Bool {
                if case .function(let f) = v { return { c, ctx in try MLib.test(f, .text(String(c)), ctx) } }
                let set = try MText.charSet(v)
                return { c, _ in set.contains(c) }
            }
            let before = try matcher(a[0]), after = try matcher(a[1])
            return splitter { s, ctx in
                let cs = Array(s)
                var parts: [String] = [], start = 0
                for i in stride(from: 1, to: cs.count, by: 1) where try before(cs[i - 1], ctx) && after(cs[i], ctx) {
                    parts.append(String(cs[start..<i])); start = i
                }
                parts.append(String(cs[start...]))
                return parts
            }
        }
        lib.fn("Splitter.SplitByNothing", 0) { _, _ in splitter { s, _ in [s] } }

        /// A combiner: `list → text`; nulls combine as empty text.
        func combiner(_ body: @escaping ([String]) -> String) -> MValue {
            .function(MFunction(name: "Combiner", minArgs: 1, maxArgs: 1) { a, ctx in
                .text(body(try a.forcedList(0).map { try MConvert.text($0, culture: ctx.culture) }))
            })
        }
        lib.fn("Combiner.CombineTextByDelimiter", 1...2) { a, _ in
            let d = try a.text(0), quoted = (try a.optInt(1) ?? 0) == 1
            return combiner { parts in parts.map { quoted ? MText.csvQuoted($0, delimiter: d) : $0 }.joined(separator: d) }
        }
        lib.fn("Combiner.CombineTextByEachDelimiter", 1...2) { a, _ in
            let ds = try a.textList(0)
            return combiner { parts in
                var out = ""
                for (i, p) in parts.enumerated() { out += p + (i < parts.count - 1 && i < ds.count ? ds[i] : "") }
                return out
            }
        }
        lib.fn("Combiner.CombineTextByLengths", 1...2) { a, _ in
            let lengths = try ints(a, 0)
            return combiner { parts in
                zip(parts, lengths).map { p, n in String(p.prefix(n)).padding(toLength: n, withPad: " ", startingAt: 0) }.joined()
            }
        }
    }
}
