import Foundation

public extension MScript {
    // MARK: Free identifiers

    /// Identifiers a script refers to but does not define (other queries, parameters, library functions),
    /// in first-use order. With `excludingLibrary`, names of the standard library are dropped.
    static func referencedIdentifiers(in script: String, excludingLibrary: Bool = true) -> [String] {
        guard let ast = try? MParser.parse(script) else { return [] }
        var out: [String] = [], seen = Set<String>()
        free(ast, bound: [], &out, &seen)
        if excludingLibrary { out.removeAll { MLibrary.shared.values[$0] != nil || $0 == "#shared" || $0 == "#sections" } }
        return out
    }
    internal static func referencedIdentifiers(inExpression text: String) -> [String] {
        referencedIdentifiers(in: text, excludingLibrary: true)
    }

    private static func free(_ e: MExpr, bound: Set<String>, _ out: inout [String], _ seen: inout Set<String>) {
        func visit(_ x: MExpr, _ b: Set<String>? = nil) { free(x, bound: b ?? bound, &out, &seen) }
        func visitType(_ t: MTypeExpr?) {
            guard let t else { return }
            switch t {
            case .primitive: break
            case .nullable(let i), .list(let i), .table(let i): visitType(i)
            case .record(let fields, _): for f in fields { visitType(f.type) }
            case .function(let params, let ret): for p in params { visitType(p.type) }; visitType(ret)
            case .expr(let x): visit(x)
            }
        }
        switch e {
        case .literal, .notImplemented: break
        case .identifier(let n, _):
            if !bound.contains(n), !seen.contains(n) { seen.insert(n); out.append(n) }
        case .list(let items): items.forEach { visit($0) }
        case .range(let a, let b): visit(a); visit(b)
        case .record(let fields):
            let b = bound.union(fields.map(\.name))
            fields.forEach { visit($0.value, b) }
        case .fieldAccess(let t, _, _), .projection(let t, _, _): if let t { visit(t) }
        case .itemAccess(let t, let i, _): visit(t); visit(i)
        case .invoke(let f, let args): visit(f); args.forEach { visit($0) }
        case .function(let params, let ret, let body):
            params.forEach { visitType($0.type) }; visitType(ret)
            visit(body, bound.union(params.map(\.name)))
        case .each(let body): visit(body, bound.union(["_"]))
        case .letIn(let bindings, let body):
            let b = bound.union(bindings.map(\.name))
            bindings.forEach { visit($0.expr, b) }
            visit(body, b)
        case .section(let members):
            let b = bound.union(members.map(\.name))
            members.forEach { visit($0.expr, b) }
        case .ifThenElse(let c, let a, let b): visit(c); visit(a); visit(b)
        case .tryOtherwise(let a, let h): visit(a); if let h { visit(h) }
        case .tryCatch(let a, let p, let h): visit(a); visit(h, p.map { bound.union([$0]) } ?? bound)
        case .raise(let x), .unary(_, let x): visit(x)
        case .binary(_, let a, let b), .meta(let a, let b): visit(a); visit(b)
        case .asType(let x, let t), .isType(let x, let t): visit(x); visitType(t)
        case .typeValue(let t): visitType(t)
        }
    }

    // MARK: Validation

    /// Syntax errors (lexer + parser) and warnings: duplicate step names, unknown identifiers, unused steps.
    /// `knownNames` are other query / parameter names that are valid references.
    static func validate(_ text: String, knownNames: Set<String> = []) -> [MDiagnostic] {
        let (toks, lexDiags) = MLexer.tokenize(text)
        if !lexDiags.isEmpty { return lexDiags }
        let ast: MExpr
        do { ast = try MParser.parse(text) } catch let d as MDiagnostic { return [d] } catch {
            return [MDiagnostic(message: "\(error)", line: 1, column: 1, location: 0, length: 1)]
        }
        var diags: [MDiagnostic] = []
        func warn(_ msg: String, at tok: MToken?) {
            diags.append(MDiagnostic(message: msg, line: tok?.line ?? 1, column: tok?.column ?? 1,
                                     location: tok?.location ?? 0, length: max(1, tok?.length ?? 1), severity: .warning))
        }
        func token(named n: String, from: Int = 0) -> MToken? {
            toks.first { ($0.kind == .identifier || $0.kind == .quotedIdentifier) && $0.value == n && $0.location >= from }
        }
        if case .letIn(let bindings, let body) = ast {
            var seen = Set<String>()
            for b in bindings {
                if !seen.insert(b.name).inserted {
                    warn("The step name '\(b.name)' is defined more than once.", at: toks.first { $0.location == b.nameRange.lowerBound })
                }
            }
            // unused steps: not referenced by any other binding or the result
            var used = Set<String>()
            for b in bindings {
                var o: [String] = [], s = Set<String>()
                free(b.expr, bound: [], &o, &s)
                used.formUnion(o.filter { $0 != b.name })
            }
            var o: [String] = [], s = Set<String>()
            free(body, bound: [], &o, &s)
            used.formUnion(o)
            for b in bindings where !used.contains(b.name) {
                warn("The step '\(b.name)' is never used.", at: toks.first { $0.location == b.nameRange.lowerBound })
            }
        }
        for name in referencedIdentifiers(in: text, excludingLibrary: true) where !knownNames.contains(name) && name != "_" {
            warn("The name '\(name)' wasn't recognized. Make sure it's spelled correctly.", at: token(named: name))
        }
        return diags
    }

    // MARK: Formatting

    /// Pretty-print M: one `let` binding per line (4-space indent), `in` on its own line, long bracketed
    /// groups broken one item per line, normalised spacing. Comments are preserved. Idempotent; never changes tokens.
    static func format(_ text: String) -> String {
        let (all, diags) = MLexer.tokenize(text, includeTrivia: true)
        if !diags.isEmpty { return text }
        let toks = all.filter { $0.kind != .whitespace && $0.kind != .eof }
        if toks.isEmpty { return "" }
        // matching brackets and whether a group must break
        var match = [Int: Int](), stack: [Int] = []
        for (i, t) in toks.enumerated() where t.kind == .punctuation {
            if "([{".contains(t.text) { stack.append(i) }
            else if ")]}".contains(t.text), let o = stack.popLast() { match[o] = i }
        }
        func inlineLength(_ a: Int, _ b: Int) -> Int { toks[a...b].reduce(0) { $0 + $1.text.count + 1 } }
        func mustBreak(_ open: Int, column: Int) -> Bool {
            guard let close = match[open], close > open + 1 else { return false }
            let inner = toks[(open + 1)..<close]
            if inner.contains(where: { $0.kind == .comment || ($0.kind == .keyword && $0.text == "let") }) { return true }
            return column + inlineLength(open, close) > 100
        }
        var out = "", indent = 0, col = 0
        var lineStart = true
        // contexts: let blocks (track bracket depth) and broken groups
        enum Ctx { case letBlock(depth: Int), group(broken: Bool) }
        var ctx: [Ctx] = []
        var depth = 0
        func newline() {
            while out.hasSuffix(" ") { out.removeLast() }
            out += "\n" + String(repeating: "    ", count: max(0, indent))
            col = indent * 4; lineStart = true
        }
        func emit(_ s: String) { out += s; col += s.count; lineStart = false }
        func isExprEnd(_ t: MToken?) -> Bool {
            guard let t else { return false }
            switch t.kind {
            case .identifier, .quotedIdentifier, .number, .text: return true
            case .punctuation: return ")]}".contains(t.text)
            case .operator: return t.text == "?"
            case .keyword: return ["true", "false", "null", "#infinity", "#nan", "#date", "#datetime", "#datetimezone", "#duration", "#time", "#table", "#binary", "#shared", "#sections"].contains(t.text)
            default: return false
            }
        }
        var prev: MToken?
        var prevSig: MToken? // previous non-comment token
        var unaryPending = false
        for (i, t) in toks.enumerated() {
            let next: MToken? = i + 1 < toks.count ? toks[i + 1] : nil
            if t.kind == .comment {
                if !lineStart { emit(" ") }
                emit(t.text.trimmingCharacters(in: .newlines))
                if t.text.hasPrefix("//") || next != nil { newline() }
                prev = t
                continue
            }
            var spaceBefore = !lineStart
            if t.kind == .keyword, t.text == "in", case .letBlock? = ctx.last {
                ctx.removeLast()
                indent -= 1; newline(); emit("in"); indent += 1; newline()
                // the `in` body is indented one level; restore after the expression ends (handled by closers / EOF)
                indent -= 1
                // keep body indented by emitting at +1 for this line only
                out += "    "; col += 4
                prev = t; prevSig = t
                continue
            }
            if t.kind == .punctuation {
                switch t.text {
                case ",":
                    emit(",")
                    if case .letBlock(let d)? = ctx.last, d == depth { newline() }
                    else if case .group(true)? = ctx.last { newline() }
                    prev = t; prevSig = t
                    continue
                case ")", "]", "}":
                    depth -= 1
                    // close any let block opened inside this group
                    while case .letBlock(let d)? = ctx.last, d > depth { ctx.removeLast(); indent -= 1 }
                    if case .group(let broken)? = ctx.last {
                        ctx.removeLast()
                        if broken { indent -= 1; newline() }
                    }
                    emit(t.text)
                    prev = t; prevSig = t
                    continue
                case "(", "[", "{":
                    let attach = isExprEnd(prevSig) && !(prevSig?.kind == .keyword)
                    if spaceBefore, !attach, !(prevSig?.kind == .punctuation && "([{".contains(prevSig?.text ?? "")), !unaryPending { emit(" ") }
                    emit(t.text)
                    depth += 1
                    let broken = mustBreak(i, column: col)
                    ctx.append(.group(broken: broken))
                    if broken { indent += 1; newline() }
                    prev = t; prevSig = t; unaryPending = false
                    continue
                default: break // ;
                }
            }
            // spacing
            if let p = prevSig {
                if p.kind == .punctuation, "([{".contains(p.text) { spaceBefore = false }
                if unaryPending { spaceBefore = false }
                if p.kind == .operator, p.text == "@" || p.text == ".." { spaceBefore = false }
            }
            if t.kind == .operator {
                if t.text == "?" || t.text == ".." { spaceBefore = false }
                if t.text == "..." , let p = prevSig, p.kind == .punctuation, "([{".contains(p.text) { spaceBefore = false }
            }
            if t.kind == .punctuation, t.text == ";" { spaceBefore = false }
            if spaceBefore { emit(" ") }
            emit(t.text)
            unaryPending = false
            if t.kind == .operator, t.text == "-" || t.text == "+" {
                // unary when the previous token does not end an expression
                if !isExprEnd(prevSig) { unaryPending = true }
            }
            if t.kind == .operator, t.text == "@" { unaryPending = true }
            if t.kind == .keyword, t.text == "let" {
                ctx.append(.letBlock(depth: depth)); indent += 1; newline()
            }
            if t.kind == .punctuation, t.text == ";" { newline() }
            prev = t; prevSig = t
        }
        _ = prev
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
