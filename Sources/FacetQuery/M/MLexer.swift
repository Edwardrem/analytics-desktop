import Foundation

/// A lexical token of M source text. `location`/`length` are UTF-16 offsets (NSRange-compatible).
public struct MToken: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case keyword, identifier, quotedIdentifier, number, text, `operator`, punctuation, comment, whitespace, invalid, eof
    }
    public var kind: Kind
    /// The raw source text of the token.
    public var text: String
    public var location: Int
    public var length: Int
    /// 1-based line and column of the token start.
    public var line: Int
    public var column: Int
    /// Decoded value for text literals and quoted identifiers (escapes resolved).
    public var value: String

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// A syntax or lexical problem found in M text.
public struct MDiagnostic: Error, LocalizedError, Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public var message: String
    public var line: Int
    public var column: Int
    public var location: Int
    public var length: Int
    public var severity: Severity = .error
    public var errorDescription: String? { "Expression.SyntaxError: \(message) (line \(line), column \(column))" }
}

enum MLexer {
    static let keywords: Set<String> = [
        "and", "as", "each", "else", "error", "false", "if", "in", "is", "let", "meta", "not", "null", "or",
        "otherwise", "section", "shared", "then", "true", "try", "type",
        "#binary", "#date", "#datetime", "#datetimezone", "#duration", "#infinity", "#nan", "#sections", "#shared", "#table", "#time",
    ]

    /// Tokenise. With `includeTrivia`, whitespace and comments are returned too (for colouring).
    /// Never throws: malformed input yields `.invalid` tokens plus diagnostics.
    static func tokenize(_ source: String, includeTrivia: Bool = false) -> (tokens: [MToken], diagnostics: [MDiagnostic]) {
        let u = Array(source.utf16)
        var tokens: [MToken] = []
        var diags: [MDiagnostic] = []
        var i = 0, line = 1, lineStart = 0
        let n = u.count

        @inline(__always) func ch(_ k: Int) -> UInt16 { k < n ? u[k] : 0 }
        func isLetter(_ c: UInt16) -> Bool {
            if c < 128 { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
            guard let s = Unicode.Scalar(UInt32(c)) else { return true } // surrogate halves: treat as letters
            return CharacterSet.letters.contains(s)
        }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func str(_ a: Int, _ b: Int) -> String { String(utf16CodeUnits: Array(u[a..<b]), count: b - a) }
        func emit(_ kind: MToken.Kind, _ start: Int, _ end: Int, value: String? = nil, startLine: Int, startCol: Int) {
            let t = str(start, end)
            tokens.append(MToken(kind: kind, text: t, location: start, length: end - start, line: startLine, column: startCol, value: value ?? t))
        }
        func bad(_ msg: String, _ start: Int, _ end: Int, _ l: Int, _ c: Int) {
            diags.append(MDiagnostic(message: msg, line: l, column: c, location: start, length: max(1, end - start)))
        }
        /// Reads a quoted text body starting at the opening quote index; returns (decoded, endIndexAfterClosingQuote, terminated).
        func readText(_ from: Int) -> (String, Int, Bool) {
            var k = from + 1
            var out: [UInt16] = []
            while k < n {
                let c = u[k]
                if c == 34 { // "
                    if ch(k + 1) == 34 { out.append(34); k += 2; continue }
                    return (String(utf16CodeUnits: out, count: out.count), k + 1, true)
                }
                if c == 35, ch(k + 1) == 40 { // #( escape
                    var e = k + 2
                    while e < n, u[e] != 41, u[e] != 34, u[e] != 10 { e += 1 }
                    if e < n, u[e] == 41 {
                        let body = str(k + 2, e)
                        var ok = true
                        var piece: [UInt16] = []
                        for part in body.split(separator: ",", omittingEmptySubsequences: false) {
                            let p = part.trimmingCharacters(in: .whitespaces)
                            switch p {
                            case "cr": piece.append(13)
                            case "lf": piece.append(10)
                            case "tab": piece.append(9)
                            case "#": piece.append(35)
                            default:
                                if (p.count == 4 || p.count == 8), let code = UInt32(p, radix: 16), let sc = Unicode.Scalar(code) {
                                    piece.append(contentsOf: Array(String(Character(sc)).utf16))
                                } else { ok = false }
                            }
                        }
                        if ok { out.append(contentsOf: piece); k = e + 1; continue }
                    }
                }
                if c == 10 { line += 1; lineStart = k + 1 }
                out.append(c); k += 1
            }
            return (String(utf16CodeUnits: out, count: out.count), k, false)
        }

        while i < n {
            let c = u[i]
            let startLine = line, startCol = i - lineStart + 1
            // whitespace
            if c == 32 || c == 9 || c == 13 || c == 10 || c == 0xA0 || c == 0xFEFF {
                let s = i
                while i < n, u[i] == 32 || u[i] == 9 || u[i] == 13 || u[i] == 10 || u[i] == 0xA0 || u[i] == 0xFEFF {
                    if u[i] == 10 { line += 1; lineStart = i + 1 }
                    i += 1
                }
                if includeTrivia { emit(.whitespace, s, i, startLine: startLine, startCol: startCol) }
                continue
            }
            // comments
            if c == 47, ch(i + 1) == 47 {
                let s = i
                while i < n, u[i] != 10 { i += 1 }
                if includeTrivia { emit(.comment, s, i, startLine: startLine, startCol: startCol) }
                continue
            }
            if c == 47, ch(i + 1) == 42 {
                let s = i
                i += 2
                var closed = false
                while i < n {
                    if u[i] == 42, ch(i + 1) == 47 { i += 2; closed = true; break }
                    if u[i] == 10 { line += 1; lineStart = i + 1 }
                    i += 1
                }
                if !closed { bad("Unterminated comment.", s, i, startLine, startCol) }
                if includeTrivia { emit(.comment, s, i, startLine: startLine, startCol: startCol) }
                continue
            }
            // text literal
            if c == 34 {
                let (v, end, ok) = readText(i)
                if !ok { bad("Unterminated text literal.", i, end, startLine, startCol) }
                emit(ok ? .text : .invalid, i, end, value: v, startLine: startLine, startCol: startCol)
                i = end; continue
            }
            // # forms
            if c == 35 {
                if ch(i + 1) == 34 {
                    let (v, end, ok) = readText(i + 1)
                    if !ok { bad("Unterminated quoted identifier.", i, end, startLine, startCol) }
                    emit(ok ? .quotedIdentifier : .invalid, i, end, value: v, startLine: startLine, startCol: startCol)
                    i = end; continue
                }
                var e = i + 1
                while e < n, isLetter(u[e]) { e += 1 }
                let word = str(i, e)
                if keywords.contains(word) {
                    emit(.keyword, i, e, startLine: startLine, startCol: startCol)
                } else {
                    bad("Invalid token '\(word)'.", i, e, startLine, startCol)
                    emit(.invalid, i, max(e, i + 1), startLine: startLine, startCol: startCol)
                }
                i = max(e, i + 1); continue
            }
            // numbers
            if isDigit(c) || (c == 46 && isDigit(ch(i + 1))) {
                let s = i
                if c == 48, ch(i + 1) == 120 || ch(i + 1) == 88 {
                    i += 2
                    while i < n, isDigit(u[i]) || (u[i] >= 97 && u[i] <= 102) || (u[i] >= 65 && u[i] <= 70) { i += 1 }
                } else {
                    while i < n, isDigit(u[i]) { i += 1 }
                    if ch(i) == 46, isDigit(ch(i + 1)) {
                        i += 1
                        while i < n, isDigit(u[i]) { i += 1 }
                    }
                    if ch(i) == 101 || ch(i) == 69 {
                        var k = i + 1
                        if ch(k) == 43 || ch(k) == 45 { k += 1 }
                        if isDigit(ch(k)) {
                            while k < n, isDigit(u[k]) { k += 1 }
                            i = k
                        }
                    }
                }
                emit(.number, s, i, startLine: startLine, startCol: startCol)
                continue
            }
            // identifiers / keywords (dots join identifier segments: Table.SelectRows)
            if isLetter(c) {
                let s = i
                i += 1
                while i < n {
                    if isLetter(u[i]) || isDigit(u[i]) { i += 1; continue }
                    if u[i] == 46, isLetter(ch(i + 1)) { i += 2; continue }
                    break
                }
                let word = str(s, i)
                emit(keywords.contains(word) ? .keyword : .identifier, s, i, startLine: startLine, startCol: startCol)
                continue
            }
            // operators & punctuation
            let two = str(i, min(n, i + 2)), three = str(i, min(n, i + 3))
            if three == "..." { emit(.operator, i, i + 3, startLine: startLine, startCol: startCol); i += 3; continue }
            if ["<=", ">=", "<>", "=>", "..", "??"].contains(two) {
                emit(.operator, i, i + 2, startLine: startLine, startCol: startCol); i += 2; continue
            }
            switch c {
            case 43, 45, 42, 47, 38, 61, 60, 62, 64, 63, 33: // + - * / & = < > @ ? !
                emit(.operator, i, i + 1, startLine: startLine, startCol: startCol)
            case 40, 41, 91, 93, 123, 125, 44, 59: // ( ) [ ] { } , ;
                emit(.punctuation, i, i + 1, startLine: startLine, startCol: startCol)
            default:
                // consume a full character (possibly a surrogate pair)
                let w = (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) ? 2 : 1
                bad("Unexpected character '\(str(i, i + w))'.", i, i + w, startLine, startCol)
                emit(.invalid, i, i + w, startLine: startLine, startCol: startCol)
                i += w; continue
            }
            i += 1
        }
        tokens.append(MToken(kind: .eof, text: "", location: n, length: 0, line: line, column: n - lineStart + 1, value: ""))
        return (tokens, diags)
    }
}

/// Helpers for generating M source text.
public enum MSyntax {
    /// An M text literal: quotes doubled, control characters as `#(..)` escapes.
    public static func text(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\"\""
            case "\n": out += "#(lf)"
            case "\r": out += "#(cr)"
            case "\t": out += "#(tab)"
            case "#": out += "#(#)"
            default:
                if ch.value < 32 { out += String(format: "#(%04X)", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }
    /// True when `name` can be written as a plain identifier.
    public static func isPlainIdentifier(_ name: String) -> Bool {
        let (toks, diags) = MLexer.tokenize(name)
        return diags.isEmpty && toks.count == 2 && toks[0].kind == .identifier && toks[0].text == name
    }
    /// An identifier reference: plain when possible, otherwise `#"quoted name"`.
    public static func identifier(_ name: String) -> String {
        isPlainIdentifier(name) ? name : "#" + text(name)
    }
    /// A field selector `[name]` (quoting only when the name contains brackets or other unsafe characters).
    public static func field(_ name: String) -> String {
        let safe = !name.isEmpty && name == name.trimmingCharacters(in: .whitespaces) && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "_" || $0 == "."
        } && !(name.first?.isNumber ?? false)
        if safe {
            // Each word must lex as an identifier or keyword so the generalized identifier re-parses identically.
            let words = name.split(separator: " ")
            let ok = words.allSatisfy { w in
                let (t, d) = MLexer.tokenize(String(w))
                return d.isEmpty && t.count == 2 && (t[0].kind == .identifier || t[0].kind == .keyword) && !t[0].text.hasPrefix("#")
            } && !name.contains("  ")
            if ok { return "[" + name + "]" }
        }
        return "[#" + text(name) + "]"
    }
    /// A list literal of text literals: `{"a", "b"}`.
    public static func textList(_ items: [String]) -> String {
        "{" + items.map(text).joined(separator: ", ") + "}"
    }
    /// An M number literal.
    public static func number(_ d: Double) -> String {
        if d.isNaN { return "#nan" }
        if d.isInfinite { return d < 0 ? "-#infinity" : "#infinity" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }
}
