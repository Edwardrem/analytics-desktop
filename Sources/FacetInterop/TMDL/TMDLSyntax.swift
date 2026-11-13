import Foundation
import FacetCore

/// One TMDL document: a relative path inside the `definition` folder and its text.
public struct TMDLFile: Hashable, Sendable {
    public var path: String
    public var text: String
    public init(path: String, text: String) { self.path = path; self.text = text }
}

/// A syntax or semantic error in TMDL text.
public struct TMDLError: LocalizedError, Hashable {
    public var message: String
    public var file: String?
    public var line: Int?
    public init(_ message: String, file: String? = nil, line: Int? = nil) { self.message = message; self.file = file; self.line = line }
    public var errorDescription: String? {
        var where_ = ""
        if let file { where_ += file }
        if let line { where_ += (where_.isEmpty ? "line \(line)" : ":\(line)") }
        return where_.isEmpty ? message : "\(where_): \(message)"
    }
}

// MARK: - Names

enum TMDLName {
    /// Quotes a name with single quotes when TMDL requires it.
    static func quote(_ name: String) -> String {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Reads a (possibly quoted) name from the start of `s`; returns the name and the remaining text.
    static func read(_ s: Substring) -> (name: String, rest: Substring)? {
        guard let first = s.first else { return nil }
        if first == "'" {
            var name = ""
            var i = s.index(after: s.startIndex)
            while i < s.endIndex {
                let ch = s[i]
                if ch == "'" {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == "'" { name.append("'"); i = s.index(after: next); continue }
                    return (name, s[next...])
                }
                name.append(ch)
                i = s.index(after: i)
            }
            return nil
        }
        var i = s.startIndex
        while i < s.endIndex, !s[i].isWhitespace, s[i] != "=" { i = s.index(after: i) }
        return i == s.startIndex ? nil : (String(s[s.startIndex..<i]), s[i...])
    }

    /// Unquotes a whole-value name ("'My Col'" → "My Col").
    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("'"), let r = read(Substring(t)), r.rest.trimmingCharacters(in: .whitespaces).isEmpty { return r.name }
        return t
    }

    /// "Table.Column" with quoting.
    static func qualified(_ parts: String...) -> String { parts.map(quote).joined(separator: ".") }

    /// Splits "Sales.'Customer Key'" into its parts.
    static func splitQualified(_ s: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(s.trimmingCharacters(in: .whitespaces))
        while !rest.isEmpty {
            if rest.first == "'" {
                guard let r = read(rest) else { parts.append(String(rest)); break }
                parts.append(r.name); rest = r.rest
            } else {
                let end = rest.firstIndex(of: ".") ?? rest.endIndex
                parts.append(String(rest[rest.startIndex..<end])); rest = rest[end...]
            }
            if rest.first == "." { rest = rest.dropFirst() }
        }
        return parts
    }
}

// MARK: - Emitter

/// Builds TMDL text with tab indentation.
final class TMDLEmitter {
    private(set) var text = ""

    func raw(_ level: Int, _ s: String) { text += String(repeating: "\t", count: level) + s + "\n" }
    func blank() { if !text.hasSuffix("\n\n"), !text.isEmpty { text += "\n" } }

    func description(_ level: Int, _ d: String) {
        guard !d.isEmpty else { return }
        for l in d.components(separatedBy: "\n") { raw(level, l.isEmpty ? "///" : "/// " + l) }
    }

    /// `key: value`, quoting the value when a bare value would not survive.
    func prop(_ level: Int, _ key: String, _ value: String) {
        let needsQuote = value.isEmpty || value != value.trimmingCharacters(in: .whitespacesAndNewlines) || value.hasPrefix("\"")
            || value.contains("\n") || value.contains("\r")
        raw(level, "\(key): " + (needsQuote ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value))
    }
    func flag(_ level: Int, _ key: String) { raw(level, key) }

    /// `declaration = expression`, single-line, indented block, or ``` fenced block as needed to preserve the text exactly.
    func expression(_ level: Int, _ declaration: String, _ expr: String) {
        if expr.isEmpty { raw(level, declaration + " ="); return }
        let lines = expr.components(separatedBy: "\n")
        let trimmedSame = expr == expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if lines.count == 1, trimmedSame, !expr.hasPrefix("```") { raw(level, "\(declaration) = \(expr)"); return }
        let nonBlank = lines.filter { !$0.isEmpty }
        let commonIndent = nonBlank.allSatisfy { $0.first == " " || $0.first == "\t" }
        let whitespaceOnly = lines.contains { !$0.isEmpty && $0.allSatisfy(\.isWhitespace) }
        let fenced = !trimmedSame || commonIndent || whitespaceOnly || expr.contains("\r")
        raw(level, declaration + (fenced ? " = ```" : " ="))
        let pad = String(repeating: "\t", count: level + 2)
        for l in lines { text += (l.isEmpty ? "" : pad + l) + "\n" }
        if fenced { text += pad + "```\n" }
    }

    func annotation(_ level: Int, _ name: String, _ value: String) {
        expression(level, "annotation \(TMDLName.quote(name))", value)
    }
    func facet(_ level: Int, _ name: String, _ value: JSONValue) {
        annotation(level, "Facet_" + name, value.compactString)
    }
    func facet<T: Encodable>(_ level: Int, _ name: String, encoding value: T) {
        if let j = try? JSONValue(encoding: value) { facet(level, name, j) }
    }
}

// MARK: - Syntax tree

/// A parsed TMDL object: `keyword name = expression` with properties and child objects.
struct TMDLNode {
    var keyword: String
    var name: String = ""
    var isRef = false
    var expression: String?
    var description: String = ""
    /// `key: value` and bare boolean properties (value "true").
    var properties: [(key: String, value: String)] = []
    /// `key = expression` properties.
    var expressionProperties: [(key: String, value: String)] = []
    var children: [TMDLNode] = []
    var line: Int = 0

    func prop(_ key: String) -> String? {
        properties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    func flag(_ key: String) -> Bool? {
        guard let v = prop(key) else { return nil }
        return v.lowercased() != "false"
    }
    func expr(_ key: String) -> String? {
        expressionProperties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    func children(_ keyword: String) -> [TMDLNode] { children.filter { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame } }
    func annotation(_ name: String) -> String? {
        children("annotation").first { $0.name == name }?.expression
    }
    /// A `Facet_<name>` annotation decoded from JSON.
    func facet(_ name: String) -> JSONValue? {
        annotation("Facet_" + name).flatMap { try? JSONValue.parse($0) }
    }
    func facet<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        facet(name).flatMap { try? $0.decode(type) }
    }
}

/// Indentation-aware TMDL parser producing a generic object tree.
struct TMDLParser {
    private struct Line {
        var raw: String          // whole line
        var indent: String       // leading whitespace
        var level: Int
        var content: Substring   // after indentation
        var isBlank: Bool { content.isEmpty }
    }

    private var lines: [Line] = []
    private var pos = 0
    private let file: String?
    private var unitWidth = 1
    private var usesTabs = true

    /// Parses `text` into top-level nodes. A `createOrReplace` script yields its contained objects with `isScript` true.
    static func parse(_ text: String, file: String? = nil) throws -> (nodes: [TMDLNode], isScript: Bool) {
        var p = TMDLParser(text: text, file: file)
        let nodes = try p.parseBlock(level: 0)
        var out: [TMDLNode] = []
        var script = false
        for n in nodes {
            if n.keyword.caseInsensitiveCompare("createOrReplace") == .orderedSame { script = true; out += n.children }
            else { out.append(n) }
        }
        return (out, script)
    }

    private init(text: String, file: String?) {
        self.file = file
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        // Files written with CRLF line ends are normalised; a CR inside an LF file is kept as data.
        let scalars = t.unicodeScalars
        if let nl = scalars.firstIndex(of: "\n"), nl > scalars.startIndex, scalars[scalars.index(before: nl)] == "\r" {
            t = t.replacingOccurrences(of: "\r\n", with: "\n")
        }
        let rawLines = t.components(separatedBy: "\n")
        // Detect the indentation unit from the first indented line.
        for l in rawLines {
            guard let f = l.first, f == " " || f == "\t", !l.allSatisfy(\.isWhitespace) else { continue }
            if f == "\t" { usesTabs = true; unitWidth = 1 }
            else { usesTabs = false; unitWidth = max(1, l.prefix { $0 == " " }.count) }
            break
        }
        lines = rawLines.map { l in
            let indent = String(l.prefix { $0 == " " || $0 == "\t" })
            let content = l.dropFirst(indent.count)
            let trimmedContent = content.allSatisfy(\.isWhitespace) ? Substring("") : content
            return Line(raw: l, indent: indent, level: level(of: indent), content: trimmedContent)
        }
    }

    private func level(of indent: String) -> Int {
        var tabs = 0, spaces = 0
        for ch in indent { if ch == "\t" { tabs += 1 } else { spaces += 1 } }
        return tabs + (usesTabs ? spaces / 4 : spaces / unitWidth)
    }

    private func error(_ m: String, _ line: Int) -> TMDLError { TMDLError(m, file: file, line: line + 1) }

    private mutating func skipBlank() { while pos < lines.count, lines[pos].isBlank { pos += 1 } }

    /// Parses sibling objects at `level` (used for the top level and `createOrReplace`).
    private mutating func parseBlock(level: Int) throws -> [TMDLNode] {
        var container = TMDLNode(keyword: "")
        try parseBody(into: &container, level: level)
        if let p = container.properties.first {
            throw TMDLError("Unexpected property “\(p.key)” outside an object.", file: file)
        }
        return container.children
    }

    /// Parses properties and child objects at exactly `level` into `node`.
    private mutating func parseBody(into node: inout TMDLNode, level: Int) throws {
        var pendingDescription: [String] = []
        while true {
            skipBlank()
            guard pos < lines.count else { return }
            let line = lines[pos]
            if line.level < level { return }
            let lineNo = pos
            let content = line.content
            if content.hasPrefix("///") {
                var d = content.dropFirst(3)
                if d.first == " " { d = d.dropFirst() }
                pendingDescription.append(String(d))
                pos += 1
                continue
            }
            if content.hasPrefix("//") { pos += 1; continue }   // tolerate comments
            pos += 1
            let declLevel = line.level

            // Leading keyword.
            var rest = content
            var isRef = false
            guard var kw = readIdentifier(&rest) else { throw error("Expected an object or property, found “\(content)”.", lineNo) }
            if kw == "ref", rest.first?.isWhitespace == true {
                let save = rest
                rest = rest.drop(while: \.isWhitespace)
                if let k2 = readIdentifier(&rest) { kw = k2; isRef = true } else { rest = save }
            }
            let afterKw = rest.drop(while: \.isWhitespace)

            if !isRef, rest.first == ":" {
                // key: value
                let v = rest.dropFirst().drop(while: \.isWhitespace)
                node.properties.append((kw, try readValue(v, line: lineNo)))
                pendingDescription = []
                continue
            }
            if !isRef, afterKw.first == "=" {
                // key = expression
                let e = try readExpression(afterKw.dropFirst(), declLevel: declLevel, minLevel: declLevel + 1, line: lineNo)
                node.expressionProperties.append((kw, e))
                pendingDescription = []
                continue
            }
            if !isRef, afterKw.isEmpty {
                // Bare word: a boolean property, or a nameless object if it has an indented body.
                var look = pos
                while look < lines.count, lines[look].isBlank { look += 1 }
                if look < lines.count, lines[look].level > declLevel {
                    var child = TMDLNode(keyword: kw, description: pendingDescription.joined(separator: "\n"), line: lineNo + 1)
                    try parseBody(into: &child, level: declLevel + 1)
                    node.children.append(child)
                } else {
                    node.properties.append((kw, "true"))
                }
                pendingDescription = []
                continue
            }
            // keyword name [= expression]
            guard let named = TMDLName.read(afterKw) else { throw error("Couldn't read the name of the \(kw).", lineNo) }
            var child = TMDLNode(keyword: kw, name: named.name, isRef: isRef,
                                 description: pendingDescription.joined(separator: "\n"), line: lineNo + 1)
            pendingDescription = []
            let tail = named.rest.drop(while: \.isWhitespace)
            if tail.first == "=" {
                child.expression = try readExpression(tail.dropFirst(), declLevel: declLevel, minLevel: declLevel + 2, line: lineNo)
            } else if !tail.isEmpty {
                throw error("Unexpected text “\(tail)” after \(kw) \(TMDLName.quote(named.name)).", lineNo)
            }
            try parseBody(into: &child, level: declLevel + 1)
            node.children.append(child)
        }
    }

    private func readIdentifier(_ s: inout Substring) -> String? {
        let id = s.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !id.isEmpty else { return nil }
        s = s.dropFirst(id.count)
        return String(id)
    }

    /// A property value: bare text to end of line, or a double-quoted string (which may span lines).
    private mutating func readValue(_ v: Substring, line: Int) throws -> String {
        guard v.first == "\"" else { return String(v).trimmingCharacters(in: .whitespaces) }
        var out = ""
        var cur = v.dropFirst()
        while true {
            var i = cur.startIndex
            while i < cur.endIndex {
                if cur[i] == "\"" {
                    let n = cur.index(after: i)
                    if n < cur.endIndex, cur[n] == "\"" { out.append("\""); i = cur.index(after: n); continue }
                    return out
                }
                out.append(cur[i])
                i = cur.index(after: i)
            }
            guard pos < lines.count else { throw error("Unterminated quoted value.", line) }
            out.append("\n")
            cur = Substring(lines[pos].raw)
            pos += 1
        }
    }

    /// Reads the expression following `=`: inline text, a ``` fenced block, or an indented block.
    private mutating func readExpression(_ afterEquals: Substring, declLevel: Int, minLevel: Int, line: Int) throws -> String {
        let inline = String(afterEquals).trimmingCharacters(in: .whitespaces)
        if inline == "```" {
            var body: [String] = []
            while pos < lines.count {
                let l = lines[pos]
                pos += 1
                if l.content.trimmingCharacters(in: .whitespaces) == "```" {
                    return body.map { strip($0, prefix: l.indent) }.joined(separator: "\n")
                }
                body.append(l.raw)
            }
            throw error("The ``` block is never closed.", line)
        }
        if !inline.isEmpty { return inline }
        // Indented block: lines deeper than the object's properties; interior blank lines belong to it.
        var block: [Line] = []
        var look = pos
        var lastContent = pos
        while look < lines.count {
            let l = lines[look]
            if l.isBlank { look += 1; continue }
            if l.level < minLevel { break }
            look += 1
            lastContent = look
        }
        block = Array(lines[pos..<lastContent])
        pos = lastContent
        guard !block.isEmpty else { return "" }
        // Strip the smallest common indentation.
        let common = block.filter { !$0.isBlank }.map(\.indent).min { $0.count < $1.count } ?? ""
        return block.map { $0.isBlank && !$0.raw.hasPrefix(common) ? "" : strip($0.raw, prefix: common) }.joined(separator: "\n")
    }

    private func strip(_ raw: String, prefix: String) -> String {
        if raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
        return raw.allSatisfy(\.isWhitespace) ? "" : String(raw.drop { $0 == " " || $0 == "\t" })
    }
}
