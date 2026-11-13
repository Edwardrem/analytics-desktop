import Foundation
import FacetCore

/// Token-based DAX pretty-printer. It only changes whitespace, keyword/function-name case and
/// (for a line comment written just before a comma) the position of that comment; it never
/// changes meaning. Formatting is idempotent and never fails: malformed input is laid out best-effort.
public enum DAXFormatter {
    /// Target line width.
    public static let lineWidth = 80

    public static func format(_ dax: String) -> String {
        var builder = TreeBuilder(dax)
        let items = builder.build()
        let w = Writer()
        Renderer(w).renderSeq(items, indent: 0)
        return w.result()
    }
}

// MARK: - Tree

private enum AtomKind {
    case ident, funcName, keyword, value, bracket, binop, unop, comma, tight, semi
    /// Statement keyword: VAR, RETURN, DEFINE, EVALUATE, MEASURE, COLUMN, TABLE, FUNCTION, ORDER BY, START AT.
    case marker
    case comment(ownLine: Bool, line: Bool)
    /// A stray closing bracket at top level.
    case closer
}

private struct Atom {
    var text: String
    var kind: AtomKind
    var isComment: Bool { if case .comment = kind { return true }; return false }
    var isMarker: Bool { if case .marker = kind { return true }; return false }
}

private final class Group {
    var open: String
    var close = ""
    var closed = false
    var isCall: Bool
    var args: [Arg] = []
    init(open: String, isCall: Bool) { self.open = open; self.isCall = isCall }
}

private struct Arg {
    var items: [Item] = []
    /// Line comments that followed the comma ending this argument on the same line.
    var postComma: [String] = []
}

private enum Item {
    case atom(Atom)
    case group(Group)
}

private struct TreeBuilder {
    let toks: [Tok]
    let u: [UInt16]
    var p = 0
    var inDefine = false

    init(_ text: String) {
        var lx = Lexer(text)
        toks = lx.lexAll(keepComments: true)
        u = Array(text.utf16)
    }

    private var cur: Tok { toks[min(p, toks.count - 1)] }
    private func raw(_ r: Range<Int>) -> String {
        guard r.lowerBound >= 0, r.upperBound <= u.count, r.lowerBound <= r.upperBound else { return "" }
        return String(utf16CodeUnits: Array(u[r]), count: r.count)
    }
    private func isComment(_ t: Tok) -> Bool { t.kind == .comment || t.kind == .docComment }
    private func isLineComment(_ t: Tok) -> Bool {
        guard isComment(t), t.range.count >= 2 else { return false }
        return !(u[t.range.lowerBound] == 47 && u[t.range.lowerBound + 1] == 42)
    }
    /// True when the comment at index `k` starts on a line of its own.
    private func ownLine(_ k: Int) -> Bool {
        guard k > 0 else { return true }
        let a = toks[k - 1].range.upperBound, b = toks[k].range.lowerBound
        guard a <= b, b <= u.count else { return false }
        return u[a..<b].contains(10)
    }
    private func commentAtom(_ k: Int) -> Atom {
        var text = raw(toks[k].range)
        while let l = text.last, l == " " || l == "\t" || l == "\r" { text.removeLast() }
        return Atom(text: text, kind: .comment(ownLine: ownLine(k), line: isLineComment(toks[k])))
    }
    /// Previous / next token ignoring comments.
    private func significant(before k: Int) -> Tok? {
        var i = k - 1
        while i >= 0 { if !isComment(toks[i]) { return toks[i] }; i -= 1 }
        return nil
    }
    private func significant(after k: Int) -> Tok? {
        var i = k + 1
        while i < toks.count { if !isComment(toks[i]) { return toks[i] }; i += 1 }
        return nil
    }
    private func significantIndex(after k: Int) -> Int? {
        var i = k + 1
        while i < toks.count { if !isComment(toks[i]) { return i }; i += 1 }
        return nil
    }

    mutating func build() -> [Item] { parseItems(depth: 0) }

    private static func quote(_ s: String, _ q: String) -> String { q + s.replacingOccurrences(of: q, with: q + q) + q }

    /// Parses items until a comma or closer (inside a group) or the end of input.
    private mutating func parseItems(depth: Int) -> [Item] {
        var items: [Item] = []
        func lastAtomKind() -> AtomKind? {
            for it in items.reversed() {
                switch it {
                case .group: return nil
                case .atom(let a): if !a.isComment { return a.kind }
                }
            }
            return nil
        }
        func lastIsGroup() -> Bool {
            for it in items.reversed() {
                switch it {
                case .group: return true
                case .atom(let a): if !a.isComment { return false }
                }
            }
            return false
        }
        while true {
            let t = cur
            let k = p
            switch t.kind {
            case .eof:
                return items
            case .comment, .docComment:
                items.append(.atom(commentAtom(k))); p += 1
            case .number:
                items.append(.atom(Atom(text: raw(t.range), kind: .value))); p += 1
            case .string:
                items.append(.atom(Atom(text: TreeBuilder.quote(t.text, "\""), kind: .value))); p += 1
            case .quotedName:
                items.append(.atom(Atom(text: TreeBuilder.quote(t.text, "'"), kind: .ident))); p += 1
            case .bracket:
                items.append(.atom(Atom(text: "[" + t.text.replacingOccurrences(of: "]", with: "]]") + "]", kind: .bracket))); p += 1
            case .identifier:
                items.append(.atom(Atom(text: t.text, kind: .ident))); p += 1
            case .keyword:
                let up = t.text.uppercased()
                let prev = significant(before: k), next = significant(after: k)
                let prevIsOp = prev?.kind == .op
                let nextIsParen = next.map { $0.kind == .punct && $0.text == "(" } ?? false
                func nextIsKeyword(_ s: String) -> Bool { next.map { $0.kind == .keyword && $0.text.uppercased() == s } ?? false }
                p += 1
                switch up {
                case "VAR", "RETURN":
                    items.append(.atom(Atom(text: up, kind: .marker)))
                case "IN", "NOT":
                    items.append(.atom(Atom(text: up, kind: .keyword)))
                case "DEFINE" where depth == 0 && !prevIsOp && !nextIsParen:
                    inDefine = true
                    items.append(.atom(Atom(text: up, kind: .marker)))
                case "EVALUATE" where depth == 0 && !prevIsOp && !nextIsParen:
                    inDefine = false
                    items.append(.atom(Atom(text: up, kind: .marker)))
                case "MEASURE", "COLUMN", "TABLE", "FUNCTION":
                    if depth == 0, inDefine, !prevIsOp, !nextIsParen { items.append(.atom(Atom(text: up, kind: .marker))) }
                    else { items.append(.atom(Atom(text: t.text, kind: .ident))) }
                case "ORDER" where depth == 0 && nextIsKeyword("BY"):
                    if let n = significantIndex(after: k) {
                        // Comments between ORDER and BY (unlikely) are kept after the marker.
                        let between = (k + 1..<n).map { commentAtom($0) }
                        p = n + 1
                        items.append(.atom(Atom(text: "ORDER BY", kind: .marker)))
                        items.append(contentsOf: between.map { .atom($0) })
                    }
                case "START" where depth == 0 && nextIsKeyword("AT"):
                    if let n = significantIndex(after: k) {
                        let between = (k + 1..<n).map { commentAtom($0) }
                        p = n + 1
                        items.append(.atom(Atom(text: "START AT", kind: .marker)))
                        items.append(contentsOf: between.map { .atom($0) })
                    }
                default:
                    items.append(.atom(Atom(text: t.text, kind: .ident)))
                }
            case .op:
                let text = raw(t.range)
                var kind = AtomKind.binop
                if text == "-" || text == "+" {
                    if lastIsGroup() { kind = .binop }
                    else if let lk = lastAtomKind() {
                        switch lk {
                        case .binop, .unop, .comma, .keyword, .marker, .semi: kind = .unop
                        default: kind = .binop
                        }
                    } else { kind = .unop }
                }
                items.append(.atom(Atom(text: text, kind: kind))); p += 1
            case .punct:
                switch t.text {
                case "(", "{":
                    var isCall = false
                    if t.text == "(", !lastIsGroup(), case .ident? = lastAtomKind() {
                        // The identifier directly before "(" is a function name.
                        if let idx = items.lastIndex(where: { if case .atom(let a) = $0 { return !a.isComment }; return true }),
                           case .atom(var a) = items[idx], !a.text.hasPrefix("'") {
                            a.kind = .funcName; a.text = a.text.uppercased()
                            items[idx] = .atom(a)
                            isCall = true
                        }
                    }
                    p += 1
                    items.append(.group(parseGroup(open: t.text, isCall: isCall, depth: depth + 1)))
                case ")", "}":
                    if depth > 0 { return items }
                    items.append(.atom(Atom(text: t.text, kind: .closer))); p += 1
                case ",":
                    if depth > 0 { return items }
                    items.append(.atom(Atom(text: ",", kind: .comma))); p += 1
                case ".":
                    items.append(.atom(Atom(text: ".", kind: .tight))); p += 1
                case ";":
                    items.append(.atom(Atom(text: ";", kind: .semi))); p += 1
                case ":":
                    items.append(.atom(Atom(text: ":", kind: .binop))); p += 1
                default:
                    items.append(.atom(Atom(text: raw(t.range), kind: .value))); p += 1
                }
            }
        }
    }

    private mutating func parseGroup(open: String, isCall: Bool, depth: Int) -> Group {
        let g = Group(open: open, isCall: isCall)
        var sawComma = false
        while true {
            var arg = Arg(items: parseItems(depth: depth))
            let t = cur
            if t.kind == .punct, t.text == "," {
                sawComma = true
                p += 1
                // Trailing line comments before the comma move after it.
                while case .atom(let a)? = arg.items.last, case .comment(ownLine: false, line: true) = a.kind {
                    arg.postComma.insert(a.text, at: 0)
                    arg.items.removeLast()
                }
                // Line comments that follow the comma on the same line belong to this argument.
                while isLineComment(cur), !ownLine(p) {
                    arg.postComma.append(commentAtom(p).text)
                    p += 1
                }
                g.args.append(arg)
                continue
            }
            if !(arg.items.isEmpty && !sawComma) { g.args.append(arg) }
            if t.kind == .punct, t.text == ")" || t.text == "}" {
                g.close = t.text; g.closed = true; p += 1
            }
            return g
        }
    }
}

// MARK: - Output

private final class Writer {
    private var lines: [String] = []
    private var line = ""
    private var lineIndent = 0
    /// Set after a line comment: the next write must start a new line.
    var mustBreak = false

    var atLineStart: Bool { line.isEmpty }
    var col: Int { atLineStart ? lineIndent * 4 : line.count }

    func newline(_ indent: Int) {
        mustBreak = false
        if !line.isEmpty { lines.append(String(repeating: " ", count: lineIndent * 4) + line); line = "" }
        lineIndent = indent
    }
    func write(_ s: String, indent: Int) {
        if s.isEmpty { return }
        if mustBreak { newline(indent) }
        line += s
    }
    func result() -> String {
        var all = lines
        if !line.isEmpty { all.append(String(repeating: " ", count: lineIndent * 4) + line) }
        let trimmed = all.map { l -> String in
            var s = l
            while let c = s.last, c == " " || c == "\t" { s.removeLast() }
            return s
        }
        return trimmed.joined(separator: "\n")
    }
}

private struct Renderer {
    let w: Writer
    init(_ w: Writer) { self.w = w }

    // MARK: Spacing

    private enum Prev { case none, atom(AtomKind), group }

    private func needsSpace(_ prev: Prev, _ next: Item) -> Bool {
        guard case .none = prev else {
            switch next {
            case .atom(let a):
                switch a.kind {
                case .comma, .semi, .tight: return false
                case .closer: return false
                case .bracket:
                    if case .atom(let pk) = prev {
                        switch pk { case .ident, .tight, .unop: return false; default: return true }
                    }
                    return true
                default:
                    if case .atom(let pk) = prev {
                        switch pk { case .unop, .tight: return false; default: return true }
                    }
                    return true
                }
            case .group(let g):
                if case .atom(let pk) = prev {
                    switch pk {
                    case .funcName: return false
                    case .unop, .tight: return false
                    default: return true
                    }
                }
                return g.open == "(" || g.open == "{"
            }
        }
        return false
    }

    // MARK: Flat rendering

    private func flat(_ items: [Item]) -> String? {
        var out = ""
        var prev = Prev.none
        for it in items {
            switch it {
            case .atom(let a):
                if a.isComment || a.isMarker { return nil }
                if needsSpace(prev, it) { out += " " }
                out += a.text
                prev = .atom(a.kind)
            case .group(let g):
                guard let s = flat(g) else { return nil }
                if needsSpace(prev, it) { out += " " }
                out += s
                prev = .group
            }
        }
        return out
    }

    private func flat(_ g: Group) -> String? {
        var parts: [String] = []
        for a in g.args {
            if !a.postComma.isEmpty { return nil }
            guard let s = flat(a.items) else { return nil }
            parts.append(s)
        }
        return g.open + parts.joined(separator: ", ") + (g.closed ? g.close : "")
    }

    /// True when the items contain a call with two or more arguments.
    private func containsMultiArgCall(_ items: [Item]) -> Bool {
        for it in items {
            if case .group(let g) = it {
                if g.isCall, g.args.count >= 2 { return true }
                if g.args.contains(where: { containsMultiArgCall($0.items) }) { return true }
            }
        }
        return false
    }
    private func isComplex(_ g: Group) -> Bool {
        g.isCall && g.args.count >= 2 && g.args.contains { containsMultiArgCall($0.items) }
    }

    // MARK: Statements

    /// Renders a sequence that may contain statement keywords.
    func renderSeq(_ items: [Item], indent: Int) {
        // Split into (marker, chunk) segments.
        var segments: [(marker: String?, chunk: [Item])] = [(nil, [])]
        for it in items {
            if case .atom(let a) = it, a.isMarker { segments.append((a.text, [])) }
            else { segments[segments.count - 1].chunk.append(it) }
        }
        var inDefine = false
        // Extra indent for VAR/RETURN that form the body of a definition or of EVALUATE.
        var bodyExtra = 0
        for seg in segments {
            guard let m = seg.marker else {
                if !seg.chunk.isEmpty { renderExpr(seg.chunk, indent: indent) }
                continue
            }
            let defBase = indent + (inDefine ? 1 : 0)
            switch m {
            case "DEFINE":
                w.newline(indent)
                w.write("DEFINE", indent: indent)
                inDefine = true; bodyExtra = 0
                if !seg.chunk.isEmpty { w.newline(indent + 1); renderExpr(seg.chunk, indent: indent + 1) }
            case "EVALUATE", "ORDER BY", "START AT":
                inDefine = false
                w.newline(indent)
                w.write(m, indent: indent)
                bodyExtra = (m == "EVALUATE" && seg.chunk.isEmpty) ? 1 : 0
                if !seg.chunk.isEmpty { w.newline(indent + 1); renderExpr(seg.chunk, indent: indent + 1) }
            case "RETURN":
                let base = defBase + bodyExtra
                w.newline(base)
                w.write("RETURN", indent: base)
                if !seg.chunk.isEmpty { w.newline(base + 1); renderExpr(seg.chunk, indent: base + 1) }
                bodyExtra = 0
            case "VAR":
                let base = defBase + bodyExtra
                w.newline(base)
                w.write(m, indent: base)
                writeHead(seg.chunk, indent: base)
            default: // MEASURE, COLUMN, TABLE, FUNCTION
                w.newline(defBase)
                w.write(m, indent: defBase)
                writeHead(seg.chunk, indent: defBase)
                bodyExtra = endsWithEquals(seg.chunk) ? 1 : 0
            }
        }
    }

    /// Writes the remainder of a `VAR x = …` / `MEASURE T[m] = …` line.
    private func writeHead(_ chunk: [Item], indent: Int) {
        guard let first = chunk.first else { return }
        if case .atom(let a) = first, a.isComment {} else { w.write(" ", indent: indent) }
        renderExpr(chunk, indent: indent)
    }

    private func endsWithEquals(_ chunk: [Item]) -> Bool {
        for it in chunk.reversed() {
            switch it {
            case .group: return false
            case .atom(let a):
                if a.isComment { continue }
                if case .binop = a.kind { return a.text == "=" }
                return false
            }
        }
        return false
    }

    // MARK: Expressions

    /// Renders items that contain no statement keywords at their own level.
    private func renderExpr(_ items: [Item], indent: Int) {
        if let s = flat(items), w.col + s.count <= DAXFormatter.lineWidth, !items.contains(where: { if case .group(let g) = $0 { return isComplex(g) }; return false }) {
            w.write(s, indent: indent)
            return
        }
        var prev = Prev.none
        for it in items {
            switch it {
            case .atom(let a):
                if case .comment(let own, let line) = a.kind {
                    if own || w.atLineStart || w.mustBreak {
                        if !w.atLineStart || w.mustBreak { w.newline(indent) }
                        w.write(a.text, indent: indent)
                        w.mustBreak = true
                    } else {
                        w.write(" ", indent: indent)
                        w.write(a.text, indent: indent)
                        if line { w.mustBreak = true }
                    }
                    continue
                }
                if needsSpace(prev, it), !w.atLineStart, !w.mustBreak { w.write(" ", indent: indent) }
                w.write(a.text, indent: indent)
                prev = .atom(a.kind)
            case .group(let g):
                if needsSpace(prev, it), !w.atLineStart, !w.mustBreak { w.write(" ", indent: indent) }
                renderGroup(g, indent: indent)
                prev = .group
            }
        }
    }

    private func renderGroup(_ g: Group, indent: Int) {
        if let s = flat(g), !isComplex(g), w.col + s.count <= DAXFormatter.lineWidth {
            w.write(s, indent: indent)
            return
        }
        w.write(g.open, indent: indent)
        if g.args.isEmpty {
            if g.closed { w.write(g.close, indent: indent) }
            return
        }
        for (i, a) in g.args.enumerated() {
            w.newline(indent + 1)
            renderSeq(a.items, indent: indent + 1)
            if i < g.args.count - 1 {
                w.write(",", indent: indent + 1)
            }
            for c in a.postComma {
                if !w.atLineStart && !w.mustBreak { w.write(" ", indent: indent + 1) }
                w.write(c, indent: indent + 1)
                w.mustBreak = true
            }
        }
        if g.closed {
            w.newline(indent)
            w.write(g.close, indent: indent)
        }
    }
}
