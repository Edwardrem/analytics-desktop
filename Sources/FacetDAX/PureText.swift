import Foundation
import FacetCore

/// Context-free text functions.
enum PureText {
    private typealias A = PureArgs

    /// FORMAT(value, format [, locale]) in a culture: the locale argument's, else the model's.
    static func format(_ a: [Value], culture: FormatCulture) -> Value {
        let v = a[safe: 0] ?? .null
        let fmt = A.s(a, 1)
        let plain = fmt.isEmpty || ["general number", "general"].contains(fmt.lowercased())
        switch v {
        case .null: return .string("")
        case .string(let s):
            guard !fmt.isEmpty, let d = numeric(s) else { return .string(s) }
            return .string(plain ? culture.localize(Value.double(d).asString) : ValueFormatter.format(.double(d), fmt, culture: culture))
        case .bool(let b):
            if plain { return .string(b ? "True" : "False") }
            return .string(ValueFormatter.format(.int(b ? 1 : 0), fmt, culture: culture))
        case .int, .double:
            return .string(plain ? culture.localize(v.asString) : ValueFormatter.format(v, fmt, culture: culture))
        case .date:
            return .string(ValueFormatter.format(v, plain ? "General Date" : fmt, culture: culture))
        }
    }

    /// Length of the prefix of `text[from...]` matched by `pattern[pi...]` (wildcards `?`, `*`, `~` escape), or nil.
    private static func matchLength(_ pattern: [Character], _ pi: Int, _ text: [Character], _ from: Int) -> Int? {
        var p = pi, t = from
        while p < pattern.count {
            let c = pattern[p]
            if c == "*" {
                // Shortest match first so the reported match is minimal.
                var k = t
                while k <= text.count {
                    if let rest = matchLength(pattern, p + 1, text, k) { return (k - from) + rest }
                    k += 1
                }
                return nil
            }
            guard t < text.count else { return nil }
            if c == "?" { p += 1; t += 1; continue }
            var lit = c
            if c == "~", p + 1 < pattern.count { p += 1; lit = pattern[p] }
            guard text[t] == lit else { return nil }
            p += 1; t += 1
        }
        return t - from
    }

    /// 0-based index of the first wildcard match of `pattern` in `text` at or after `start`, or nil.
    static func wildcardFind(_ pattern: String, in text: String, from start: Int = 0, caseInsensitive: Bool = true) -> Int? {
        let p = Array(caseInsensitive ? pattern.lowercased() : pattern)
        let t = Array(caseInsensitive ? text.lowercased() : text)
        if start > t.count { return nil }
        var i = max(0, start)
        while i <= t.count {
            if matchLength(p, 0, t, i) != nil { return i }
            i += 1
        }
        return nil
    }

    private static func count(_ a: [Value], _ i: Int, default d: Int, _ fn: String) throws -> Int {
        let n = try A.i(a, i, default: d)
        if n < 0 { throw DAXError("\(fn) requires a non-negative number of characters.") }
        return n
    }

    private static func search(_ a: [Value], caseInsensitive: Bool, name: String) throws -> Value {
        let find = A.s(a, 0), within = A.s(a, 1)
        let start = try A.i(a, 2, default: 1)
        if start < 1 { throw DAXError("\(name) requires a start position of 1 or greater.") }
        let hit: Int?
        if caseInsensitive {
            hit = wildcardFind(find, in: within, from: start - 1, caseInsensitive: true)
        } else {
            let f = Array(find), t = Array(within)
            var found: Int?
            if start - 1 <= t.count {
                var i = start - 1
                while i + f.count <= t.count {
                    if Array(t[i..<(i + f.count)]) == f { found = i; break }
                    i += 1
                }
            }
            hit = found
        }
        if let h = hit { return .int(Int64(h + 1)) }
        if a.count > 3 { return a[3] }
        throw DAXError("The search text '\(find)' provided to function '\(name)' could not be found in the given text.")
    }

    /// Parses text as a number or date serial for VALUE / FORMAT.
    static func numeric(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        return Double(t) ?? DataTable.parseNumber(t)
    }

    static let functions: [String: PureFn] = {
        var f: [String: PureFn] = [:]

        f["CONCATENATE"] = { a in .string(A.s(a, 0) + A.s(a, 1)) }
        f["LEFT"] = { a in
            let s = A.s(a, 0)
            return .string(String(s.prefix(try count(a, 1, default: 1, "LEFT"))))
        }
        f["RIGHT"] = { a in
            let s = A.s(a, 0)
            return .string(String(s.suffix(try count(a, 1, default: 1, "RIGHT"))))
        }
        f["MID"] = { a in
            let s = Array(A.s(a, 0))
            let start = try A.i(a, 1, default: 1), n = try count(a, 2, default: 0, "MID")
            if start < 1 { throw DAXError("MID requires a start position of 1 or greater.") }
            guard start <= s.count else { return .string("") }
            return .string(String(s[(start - 1)..<min(s.count, start - 1 + n)]))
        }
        f["LEN"] = { a in .int(Int64(A.s(a, 0).count)) }
        f["UPPER"] = { a in .string(A.s(a, 0).uppercased()) }
        f["LOWER"] = { a in .string(A.s(a, 0).lowercased()) }
        f["TRIM"] = { a in
            .string(A.s(a, 0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        }
        f["SUBSTITUTE"] = { a in
            let text = A.s(a, 0), old = A.s(a, 1), new = A.s(a, 2)
            if old.isEmpty { return .string(text) }
            guard a.count > 3, !a[3].isNull else { return .string(text.replacingOccurrences(of: old, with: new)) }
            let instance = try A.i(a, 3)
            if instance < 1 { throw DAXError("SUBSTITUTE requires an instance number of 1 or greater.") }
            var seen = 0
            var searchStart = text.startIndex
            while let r = text.range(of: old, range: searchStart..<text.endIndex) {
                seen += 1
                if seen == instance { return .string(text.replacingCharacters(in: r, with: new)) }
                searchStart = r.upperBound
            }
            return .string(text)
        }
        f["REPLACE"] = { a in
            let s = Array(A.s(a, 0))
            let start = try A.i(a, 1, default: 1), n = try count(a, 2, default: 0, "REPLACE")
            if start < 1 { throw DAXError("REPLACE requires a start position of 1 or greater.") }
            let from = min(start - 1, s.count), to = min(s.count, from + n)
            return .string(String(s[..<from]) + A.s(a, 3) + String(s[to...]))
        }
        f["SEARCH"] = { a in try search(a, caseInsensitive: true, name: "SEARCH") }
        f["FIND"] = { a in try search(a, caseInsensitive: false, name: "FIND") }
        f["FORMAT"] = { a in format(a, culture: a.count > 2 ? FormatCulture(identifier: A.s(a, 2)) : .enUS) }
        f["VALUE"] = { a in
            switch a[safe: 0] ?? .null {
            case .null: return .null
            case .int(let i): return .int(i)
            case .double(let d): return .double(d)
            case .bool(let b): return .int(b ? 1 : 0)
            case .date(let d): return .double(Value.serial(from: d))
            case .string(let s):
                let t = s.trimmingCharacters(in: .whitespaces)
                if let i = Int64(t) { return .int(i) }
                if let d = numeric(t) { return .double(d) }
                if let d = DateParsing.parse(t) { return .double(Value.serial(from: d)) }
                throw DAXError("Cannot convert value '\(s)' of type Text to type Number.")
            }
        }
        f["FIXED"] = { a in
            let x = try A.n(a, 0)
            let decimals = try A.i(a, 1, default: 2)
            let noCommas = try A.flag(a, 2)
            let r = PureMath.round(x, digits: decimals, mode: .toNearestOrAwayFromZero)
            let body = String(format: "%.\(max(0, decimals))f", abs(r))
            var parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if !noCommas, parts[0].count > 3 {
                var out = ""
                for (i, ch) in parts[0].reversed().enumerated() {
                    if i > 0, i % 3 == 0 { out.append(",") }
                    out.append(ch)
                }
                parts[0] = String(out.reversed())
            }
            return .string((r < 0 ? "-" : "") + parts.joined(separator: "."))
        }
        f["REPT"] = { a in
            let n = try count(a, 1, default: 0, "REPT")
            let s = A.s(a, 0)
            if s.count * n > 10_000_000 { throw DAXError("REPT: the result is too long.") }
            return .string(String(repeating: s, count: n))
        }
        f["EXACT"] = { a in .bool(A.s(a, 0) == A.s(a, 1)) }
        f["UNICHAR"] = { a in
            if A.isBlank(a, 0) { return .null }
            let n = try A.i(a, 0)
            guard n > 0, let sc = Unicode.Scalar(UInt32(n)) else { throw DAXError("UNICHAR: \(n) is not a valid Unicode code point.") }
            return .string(String(Character(sc)))
        }
        f["UNICODE"] = { a in
            guard let sc = A.s(a, 0).unicodeScalars.first else { return .null }
            return .int(Int64(sc.value))
        }
        f["COMBINEVALUES"] = { a in
            .string(a.dropFirst().map(\.asString).joined(separator: A.s(a, 0)))
        }
        f["CONTAINSSTRING"] = { a in
            let find = A.s(a, 1)
            if find.isEmpty { return .bool(true) }
            return .bool(wildcardFind(find, in: A.s(a, 0), caseInsensitive: true) != nil)
        }
        f["CONTAINSSTRINGEXACT"] = { a in
            let find = A.s(a, 1)
            if find.isEmpty { return .bool(true) }
            return .bool(A.s(a, 0).contains(find))
        }
        return f
    }()
}
