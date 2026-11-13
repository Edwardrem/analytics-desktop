import Foundation
import FacetCore

/// A lexical token of DAX source. Offsets are UTF-16 code units, matching `NSTextView` ranges.
struct DAXToken: Equatable {
    enum Kind { case word, quotedName, bracket, string, number, comment, symbol }
    var kind: Kind
    var start: Int
    var end: Int
    /// Words, numbers, comments, strings: the raw text. Quoted names and brackets: the unescaped name.
    var text: String

    func isWord(_ keyword: String) -> Bool { kind == .word && text.caseInsensitiveCompare(keyword) == .orderedSame }
    func isSymbol(_ s: String) -> Bool { kind == .symbol && text == s }
}

/// A small, tolerant DAX tokenizer used for reference discovery and `DEFINE` parsing in the query view.
/// It never fails: unterminated strings, names and comments simply run to the end of the line or text.
enum DAXLexer {
    static func tokens(_ source: String) -> [DAXToken] {
        let s = Array(source.utf16)
        let n = s.count
        var out: [DAXToken] = []
        var i = 0
        func str(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF16.self) }
        func isWordStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 160 }
        func isWordPart(_ c: UInt16) -> Bool { isWordStart(c) || (c >= 48 && c <= 57) || c == 46 }
        /// Reads a delimited name starting after the opening delimiter; a doubled closer is an escape.
        func delimited(from start: Int, closer: UInt16) -> (name: String, end: Int) {
            var j = start
            var name: [UInt16] = []
            while j < n {
                if s[j] == closer {
                    if j + 1 < n, s[j + 1] == closer { name.append(closer); j += 2; continue }
                    return (String(decoding: name, as: UTF16.self), j + 1)
                }
                if s[j] == 10 { break }
                name.append(s[j]); j += 1
            }
            return (String(decoding: name, as: UTF16.self), j)
        }
        while i < n {
            let c = s[i]
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 160 { i += 1; continue }
            let next: UInt16 = i + 1 < n ? s[i + 1] : 0
            if (c == 47 && next == 47) || (c == 45 && next == 45) {
                var j = i
                while j < n, s[j] != 10 { j += 1 }
                var e = j
                if e > i, s[e - 1] == 13 { e -= 1 }
                out.append(DAXToken(kind: .comment, start: i, end: e, text: str(i, e))); i = j
            } else if c == 47, next == 42 {
                var j = i + 2
                while j < n, !(s[j] == 42 && j + 1 < n && s[j + 1] == 47) { j += 1 }
                j = min(n, j + 2)
                out.append(DAXToken(kind: .comment, start: i, end: j, text: str(i, j))); i = j
            } else if c == 34 {
                var j = i + 1
                while j < n {
                    if s[j] == 34 { if j + 1 < n, s[j + 1] == 34 { j += 2; continue }; break }
                    j += 1
                }
                j = min(n, j + 1)
                out.append(DAXToken(kind: .string, start: i, end: j, text: str(i, j))); i = j
            } else if c == 39 {
                let r = delimited(from: i + 1, closer: 39)
                out.append(DAXToken(kind: .quotedName, start: i, end: r.end, text: r.name)); i = r.end
            } else if c == 91 {
                let r = delimited(from: i + 1, closer: 93)
                out.append(DAXToken(kind: .bracket, start: i, end: r.end, text: r.name)); i = r.end
            } else if c >= 48 && c <= 57 {
                var j = i
                while j < n, (s[j] >= 48 && s[j] <= 57) || s[j] == 46 || s[j] == 101 || s[j] == 69 { j += 1 }
                out.append(DAXToken(kind: .number, start: i, end: j, text: str(i, j))); i = j
            } else if isWordStart(c) {
                var j = i
                while j < n, isWordPart(s[j]) { j += 1 }
                out.append(DAXToken(kind: .word, start: i, end: j, text: str(i, j))); i = j
            } else {
                // Keep surrogate pairs together so offsets stay valid.
                let len = (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) ? 2 : 1
                out.append(DAXToken(kind: .symbol, start: i, end: i + len, text: str(i, i + len))); i += len
            }
        }
        return out
    }
}

/// Text helpers shared by the query builder, the `DEFINE` parser and the editor commands.
enum DAXText {
    /// Canonical form of an expression for comparison and storage: no surrounding blank lines,
    /// no trailing whitespace, and continuation lines without their shared indentation.
    static func normalize(_ expression: String) -> String {
        var lines = expression.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { line -> String in
                var l = line
                while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                return l
            }
        while let f = lines.first, f.isEmpty { lines.removeFirst() }
        while let l = lines.last, l.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        func indent(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
        lines[0] = String(lines[0].dropFirst(indent(lines[0])))
        let rest = lines.dropFirst().filter { !$0.isEmpty }
        let common = rest.map(indent).min() ?? 0
        if common > 0 {
            for i in 1..<lines.count where !lines[i].isEmpty { lines[i] = String(lines[i].dropFirst(common)) }
        }
        return lines.joined(separator: "\n")
    }

    /// The first non-empty line, for history and summaries.
    static func firstLine(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    /// Comments or uncomments the lines touched by `range` (UTF-16). Returns the line range to replace and its replacement.
    static func toggleComment(in text: String, range: NSRange) -> (range: NSRange, replacement: String) {
        let ns = text as NSString
        let safe = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        var lineRange = ns.lineRange(for: safe)
        var block = ns.substring(with: lineRange)
        var trailingNewline = ""
        if block.hasSuffix("\r\n") { trailingNewline = "\r\n"; block.removeLast() }
        else if block.hasSuffix("\n") { trailingNewline = "\n"; block.removeLast() }
        lineRange.length -= (trailingNewline as NSString).length
        let lines = block.components(separatedBy: "\n")
        func body(_ l: String) -> Substring { l.drop { $0 == " " || $0 == "\t" } }
        let meaningful = lines.filter { !body($0).isEmpty }
        let allCommented = !meaningful.isEmpty && meaningful.allSatisfy { body($0).hasPrefix("//") || body($0).hasPrefix("--") }
        let out = lines.map { line -> String in
            let b = body(line)
            let lead = String(line.prefix(line.count - b.count))
            if b.isEmpty { return line }
            if allCommented {
                var rest = b.dropFirst(2)
                if rest.first == " " { rest = rest.dropFirst() }
                return lead + rest
            }
            return lead + "// " + b
        }
        return (lineRange, out.joined(separator: "\n"))
    }
}
