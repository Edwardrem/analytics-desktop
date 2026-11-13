import Foundation
import FacetCore

/// A lexical token for syntax colouring. `range` is in UTF-16 offsets (use `nsRange` with NSTextView).
public struct DAXToken: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case number, string, identifier, keyword, function, table, column, `operator`, punctuation, comment, variable
    }
    public var kind: Kind
    public var range: Range<Int>
    public init(kind: Kind, range: Range<Int>) { self.kind = kind; self.range = range }
    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

public enum DAXSyntax {
    /// Tokens for syntax colouring, including comments. Never throws: malformed input still yields tokens.
    public static func tokens(_ text: String) -> [DAXToken] {
        var lexer = Lexer(text)
        let raw = lexer.lexAll(keepComments: true)
        var varNames = Set<String>()
        for (i, t) in raw.enumerated() where t.kind == .keyword && t.text.uppercased() == "VAR" {
            if let n = raw[safe: i + 1], n.kind == .identifier { varNames.insert(n.text.lowercased()) }
        }
        var out: [DAXToken] = []
        for (i, t) in raw.enumerated() {
            let kind: DAXToken.Kind
            switch t.kind {
            case .number: kind = .number
            case .string: kind = .string
            case .quotedName: kind = .table
            case .bracket: kind = .column
            case .keyword: kind = .keyword
            case .comment, .docComment: kind = .comment
            case .op: kind = .operator
            case .punct: kind = .punctuation
            case .eof: continue
            case .identifier:
                let next = raw[safe: i + 1]
                if let n = next, n.kind == .punct, n.text == "(" { kind = .function }
                else if varNames.contains(t.text.lowercased()) { kind = .variable }
                else if let n = next, n.kind == .bracket { kind = .table }
                else { kind = .identifier }
            }
            out.append(DAXToken(kind: kind, range: t.range))
        }
        return out
    }
}

/// Internal token.
struct Tok {
    enum Kind { case number, string, identifier, quotedName, bracket, keyword, op, punct, comment, docComment, eof }
    var kind: Kind
    /// Decoded content: string body, name without quotes/brackets, operator text.
    var text: String
    var range: Range<Int>
}

struct Lexer {
    static let keywords: Set<String> = ["VAR", "RETURN", "IN", "NOT", "DEFINE", "EVALUATE", "MEASURE", "ORDER", "BY", "START", "AT",
                                        "COLUMN", "TABLE", "FUNCTION"]
    /// Keywords that are only special at query level; inside expressions they behave as identifiers.
    static let softKeywords: Set<String> = ["MEASURE", "ORDER", "BY", "START", "AT", "COLUMN", "TABLE", "FUNCTION", "DEFINE", "EVALUATE"]

    let u: [UInt16]
    var i = 0

    init(_ text: String) { u = Array(text.utf16) }

    private func ch(_ k: Int) -> UInt16 { k < u.count ? u[k] : 0 }
    private func str(_ r: Range<Int>) -> String { String(utf16CodeUnits: Array(u[r]), count: r.count) }

    private static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
    }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || c == 46 }

    mutating func lexAll(keepComments: Bool = false) -> [Tok] {
        var out: [Tok] = []
        while true {
            let t = next()
            if t.kind == .comment && !keepComments { continue }
            out.append(t)
            if t.kind == .eof { break }
        }
        return out
    }

    mutating func next() -> Tok {
        // whitespace
        while i < u.count, u[i] == 32 || u[i] == 9 || u[i] == 10 || u[i] == 13 || u[i] == 0xA0 { i += 1 }
        guard i < u.count else { return Tok(kind: .eof, text: "", range: u.count..<u.count) }
        let start = i
        let c = u[i]
        // comments
        if (c == 47 && ch(i + 1) == 47) || (c == 45 && ch(i + 1) == 45) {
            let isDoc = c == 47 && ch(i + 2) == 47
            while i < u.count, u[i] != 10 { i += 1 }
            let bodyStart = start + (isDoc ? 3 : 2)
            return Tok(kind: isDoc ? .docComment : .comment, text: str(min(bodyStart, i)..<i).trimmingCharacters(in: .whitespaces), range: start..<i)
        }
        if c == 47 && ch(i + 1) == 42 {
            i += 2
            while i < u.count, !(u[i] == 42 && ch(i + 1) == 47) { i += 1 }
            i = min(i + 2, u.count)
            return Tok(kind: .comment, text: "", range: start..<i)
        }
        // numbers
        if Lexer.isDigit(c) || (c == 46 && Lexer.isDigit(ch(i + 1))) {
            while Lexer.isDigit(ch(i)) { i += 1 }
            if ch(i) == 46, Lexer.isDigit(ch(i + 1)) || !Lexer.isIdentStart(ch(i + 1)) {
                i += 1
                while Lexer.isDigit(ch(i)) { i += 1 }
            }
            if ch(i) == 69 || ch(i) == 101 {
                var j = i + 1
                if ch(j) == 43 || ch(j) == 45 { j += 1 }
                if Lexer.isDigit(ch(j)) {
                    i = j
                    while Lexer.isDigit(ch(i)) { i += 1 }
                }
            }
            return Tok(kind: .number, text: str(start..<i), range: start..<i)
        }
        // strings and quoted names
        if c == 34 || c == 39 {
            i += 1
            var body: [UInt16] = []
            while i < u.count {
                if u[i] == c {
                    if ch(i + 1) == c { body.append(c); i += 2; continue }
                    i += 1; break
                }
                body.append(u[i]); i += 1
            }
            return Tok(kind: c == 34 ? .string : .quotedName, text: String(utf16CodeUnits: body, count: body.count), range: start..<i)
        }
        if c == 91 {
            i += 1
            var body: [UInt16] = []
            while i < u.count {
                if u[i] == 93 {
                    if ch(i + 1) == 93 { body.append(93); i += 2; continue }
                    i += 1; break
                }
                body.append(u[i]); i += 1
            }
            return Tok(kind: .bracket, text: String(utf16CodeUnits: body, count: body.count), range: start..<i)
        }
        if Lexer.isIdentStart(c) {
            while Lexer.isIdentPart(ch(i)) { i += 1 }
            // A trailing dot belongs to what follows (e.g. Table[Date].[Year] is handled via brackets, not here).
            while i > start + 1, u[i - 1] == 46 { i -= 1 }
            let s = str(start..<i)
            return Tok(kind: Lexer.keywords.contains(s.uppercased()) ? .keyword : .identifier, text: s, range: start..<i)
        }
        // operators
        let two = ch(i + 1)
        func op(_ n: Int, _ kind: Tok.Kind = .op) -> Tok { i += n; return Tok(kind: kind, text: str(start..<i), range: start..<i) }
        switch c {
        case 38: return op(two == 38 ? 2 : 1)           // & &&
        case 124: return op(two == 124 ? 2 : 1)         // ||
        case 61: return op(two == 61 || two == 62 ? 2 : 1) // = == =>
        case 60: return op(two == 61 || two == 62 ? 2 : 1) // < <= <>
        case 62: return op(two == 61 ? 2 : 1)           // > >=
        case 43, 45, 42, 47, 94: return op(1)
        case 40, 41, 123, 125, 44, 58, 59, 46: return op(1, .punct)
        default: return op(1, .punct)
        }
    }
}
