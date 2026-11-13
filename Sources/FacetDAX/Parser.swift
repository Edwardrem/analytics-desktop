import Foundation
import FacetCore

enum BinOp: String { case add = "+", sub = "-", mul = "*", div = "/", pow = "^", concat = "&", eq = "=", strictEq = "==", ne = "<>",
                     lt = "<", le = "<=", gt = ">", ge = ">=", and = "&&", or = "||", `in` = "IN" }
enum UnOp: String { case neg = "-", plus = "+", not = "NOT" }

/// AST node. A class so evaluation can cache name resolution on it.
final class Node {
    indirect enum Kind {
        case const(Value)
        /// `Table[Column]`, `[Name]`, or `Table[Column].[Level]` (auto date/time variation).
        case column(table: String?, name: String, sub: String?)
        /// Bare identifier: table, variable, parameter, or keyword argument (ASC, DAY, ROWS…).
        case ident(String)
        /// Function call; name is upper-cased.
        case call(String, [Node])
        case binary(BinOp, Node, Node)
        case unary(UnOp, Node)
        case vars([(name: String, expr: Node)], Node)
        case tableCtor([[Node]])
        /// An omitted argument.
        case missing
    }
    let kind: Kind
    let range: Range<Int>
    /// Evaluation-time cache (resolved column / function implementation). Owned by one engine.
    var cache: AnyObject?
    var cache2: AnyObject?

    init(_ kind: Kind, _ range: Range<Int>) { self.kind = kind; self.range = range }

    var isMissing: Bool { if case .missing = kind { return true }; return false }
    var callName: String? { if case .call(let n, _) = kind { return n }; return nil }
    var callArgs: [Node] { if case .call(_, let a) = kind { return a }; return [] }
    var identName: String? { if case .ident(let n) = kind { return n.uppercased() }; return nil }
    var stringConst: String? { if case .const(.string(let s)) = kind { return s }; return nil }

    /// Visits this node and all descendants.
    func walk(_ visit: (Node) -> Void) {
        visit(self)
        switch kind {
        case .call(_, let args): args.forEach { $0.walk(visit) }
        case .binary(_, let l, let r): l.walk(visit); r.walk(visit)
        case .unary(_, let e): e.walk(visit)
        case .vars(let vs, let body): vs.forEach { $0.expr.walk(visit) }; body.walk(visit)
        case .tableCtor(let rows): rows.forEach { $0.forEach { $0.walk(visit) } }
        default: break
        }
    }
}

struct ParsedParam {
    var name: String
    var type: String = "anyval"
    var mode: String = "val"
    var defaultExpr: Node?
}
struct ParsedFunction {
    var name: String
    var params: [ParsedParam]
    var body: Node
    var description: String = ""
}
struct ParsedMeasure { var table: String; var name: String; var expr: Node; var description: String; var source: String }
struct ParsedEvaluate { var expr: Node; var orderBy: [(expr: Node, descending: Bool)]; var startAt: [Node] }
struct ParsedQuery {
    var measures: [ParsedMeasure] = []
    var vars: [(name: String, expr: Node)] = []
    var tables: [(name: String, expr: Node)] = []
    var columns: [(table: String, name: String, expr: Node)] = []
    var functions: [ParsedFunction] = []
    var evaluates: [ParsedEvaluate] = []
}

struct Parser {
    let toks: [Tok]
    let source: String
    var p = 0

    init(_ text: String) {
        var lx = Lexer(text)
        let all = lx.lexAll()
        // Doc comments only matter directly before a definition; elsewhere they are ordinary comments.
        var kept: [Tok] = []
        for (i, t) in all.enumerated() {
            if t.kind == .docComment {
                var k = i + 1
                while k < all.count, all[k].kind == .docComment { k += 1 }
                let n = all[min(k, all.count - 1)]
                guard n.kind == .keyword, ["MEASURE", "FUNCTION", "VAR", "TABLE", "COLUMN"].contains(n.text.uppercased()) else { continue }
            }
            kept.append(t)
        }
        toks = kept
        source = text
    }

    private var cur: Tok { toks[min(p, toks.count - 1)] }
    private func peek(_ k: Int = 1) -> Tok { toks[min(p + k, toks.count - 1)] }
    private mutating func advance() { if p < toks.count - 1 { p += 1 } }
    private func isPunct(_ s: String) -> Bool { cur.kind == .punct && cur.text == s }
    private func isOp(_ s: String) -> Bool { cur.kind == .op && cur.text == s }
    private func isKeyword(_ s: String) -> Bool { cur.kind == .keyword && cur.text.uppercased() == s }
    private func err(_ m: String, _ r: Range<Int>? = nil) -> DAXError { DAXError(m, range: r ?? cur.range) }
    private mutating func expectPunct(_ s: String) throws {
        guard isPunct(s) else {
            throw err(cur.kind == .eof ? "Expected '\(s)' but the expression ended." : "Expected '\(s)' but found '\(describe(cur))'.")
        }
        advance()
    }
    private func describe(_ t: Tok) -> String {
        switch t.kind {
        case .eof: return "end of expression"
        case .bracket: return "[\(t.text)]"
        case .quotedName: return "'\(t.text)'"
        case .string: return "\"\(t.text)\""
        default: return t.text
        }
    }
    private mutating func skipDocComments() -> String {
        var doc: [String] = []
        while cur.kind == .docComment { doc.append(cur.text); advance() }
        return doc.joined(separator: "\n")
    }

    // MARK: Entry points

    /// Parses a standalone expression (measure, column, table expression).
    static func parseExpression(_ text: String) throws -> Node {
        var ps = Parser(text)
        _ = ps.skipDocComments()
        if ps.cur.kind == .op, ps.cur.text == "=" { ps.advance() }   // tolerate a leading "="
        if ps.cur.kind == .eof { throw DAXError("The expression is empty.", range: 0..<0) }
        let n = try ps.expr()
        _ = ps.skipDocComments()
        if ps.cur.kind != .eof { throw ps.err("Unexpected '\(ps.describe(ps.cur))'.") }
        return n
    }

    /// Parses a user-function definition body: either `(params) => body` or a bare body.
    static func parseFunctionBody(_ text: String) throws -> (params: [ParsedParam]?, body: Node) {
        var ps = Parser(text)
        _ = ps.skipDocComments()
        if ps.looksLikeLambda() {
            let params = try ps.lambdaParams()
            let body = try ps.expr()
            if ps.cur.kind != .eof { throw ps.err("Unexpected '\(ps.describe(ps.cur))'.") }
            return (params, body)
        }
        return (nil, try parseExpression(text))
    }

    static func parseQuery(_ text: String) throws -> ParsedQuery {
        var ps = Parser(text)
        return try ps.query()
    }

    // MARK: Query

    private mutating func query() throws -> ParsedQuery {
        var q = ParsedQuery()
        var doc = skipDocComments()
        if isKeyword("DEFINE") {
            advance()
            while true {
                let d = skipDocComments()
                if !d.isEmpty { doc = d }
                if isKeyword("MEASURE") {
                    advance()
                    let start = cur.range.lowerBound
                    let (table, name) = try qualifiedName()
                    try expectEquals()
                    let exprStart = cur.range.lowerBound
                    let e = try expr()
                    let end = toks[max(0, p - 1)].range.upperBound
                    _ = start
                    q.measures.append(ParsedMeasure(table: table ?? "", name: name, expr: e, description: doc, source: slice(exprStart..<end)))
                } else if isKeyword("VAR") {
                    advance()
                    guard cur.kind == .identifier || cur.kind == .keyword else { throw err("Expected a variable name after VAR.") }
                    let name = cur.text; advance()
                    try expectEquals()
                    q.vars.append((name, try expr()))
                } else if isKeyword("TABLE") {
                    advance()
                    let name: String
                    if cur.kind == .identifier || cur.kind == .quotedName { name = cur.text; advance() }
                    else { throw err("Expected a table name after TABLE.") }
                    try expectEquals()
                    q.tables.append((name, try expr()))
                } else if isKeyword("COLUMN") {
                    advance()
                    let (table, name) = try qualifiedName()
                    guard let t = table else { throw err("DEFINE COLUMN needs a table-qualified name such as Sales[Margin].") }
                    try expectEquals()
                    q.columns.append((t, name, try expr()))
                } else if isKeyword("FUNCTION") {
                    advance()
                    guard cur.kind == .identifier else { throw err("Expected a function name after FUNCTION.") }
                    let name = cur.text; advance()
                    try expectEquals()
                    guard looksLikeLambda() else { throw err("Expected a parameter list, e.g. FUNCTION F = (x) => x * 2.") }
                    let params = try lambdaParams()
                    let body = try expr()
                    q.functions.append(ParsedFunction(name: name, params: params, body: body, description: doc))
                } else { break }
                doc = ""
            }
        }
        _ = skipDocComments()
        guard isKeyword("EVALUATE") else {
            throw err(cur.kind == .eof ? "A query needs at least one EVALUATE statement." : "Expected EVALUATE but found '\(describe(cur))'.")
        }
        while isKeyword("EVALUATE") {
            advance()
            let e = try expr()
            var ev = ParsedEvaluate(expr: e, orderBy: [], startAt: [])
            if isKeyword("ORDER") {
                advance()
                guard isKeyword("BY") else { throw err("Expected BY after ORDER.") }
                advance()
                while true {
                    let o = try expr()
                    var desc = false
                    if cur.kind == .identifier, ["ASC", "DESC"].contains(cur.text.uppercased()) {
                        desc = cur.text.uppercased() == "DESC"; advance()
                    }
                    ev.orderBy.append((o, desc))
                    if isPunct(",") { advance() } else { break }
                }
            }
            if isKeyword("START") {
                advance()
                guard isKeyword("AT") else { throw err("Expected AT after START.") }
                advance()
                while true {
                    ev.startAt.append(try expr())
                    if isPunct(",") { advance() } else { break }
                }
            }
            if isPunct(";") { advance() }
            q.evaluates.append(ev)
            _ = skipDocComments()
        }
        if cur.kind != .eof { throw err("Unexpected '\(describe(cur))' after the query.") }
        return q
    }

    private func slice(_ r: Range<Int>) -> String {
        let u = Array(source.utf16)
        guard r.lowerBound >= 0, r.upperBound <= u.count, r.lowerBound <= r.upperBound else { return "" }
        return String(utf16CodeUnits: Array(u[r]), count: r.count)
    }
    private mutating func expectEquals() throws {
        guard isOp("=") else { throw err("Expected '=' but found '\(describe(cur))'.") }
        advance()
    }
    /// `Table[Name]`, `'Table'[Name]` or `[Name]`.
    private mutating func qualifiedName() throws -> (String?, String) {
        var table: String?
        if cur.kind == .identifier || cur.kind == .quotedName || cur.kind == .keyword { table = cur.text; advance() }
        guard cur.kind == .bracket else { throw err("Expected a name in square brackets.") }
        let name = cur.text; advance()
        return (table, name)
    }

    private func looksLikeLambda() -> Bool {
        guard cur.kind == .punct, cur.text == "(" else { return false }
        var depth = 0, k = p
        while k < toks.count {
            let t = toks[k]
            if t.kind == .punct, t.text == "(" { depth += 1 }
            if t.kind == .punct, t.text == ")" {
                depth -= 1
                if depth == 0 { let n = toks[min(k + 1, toks.count - 1)]; return n.kind == .op && n.text == "=>" }
            }
            if t.kind == .eof { return false }
            k += 1
        }
        return false
    }
    private mutating func lambdaParams() throws -> [ParsedParam] {
        try expectPunct("(")
        var out: [ParsedParam] = []
        while !isPunct(")") {
            guard cur.kind == .identifier || cur.kind == .keyword else { throw err("Expected a parameter name.") }
            var prm = ParsedParam(name: cur.text); advance()
            if isPunct(":") {
                advance()
                var words: [String] = []
                while cur.kind == .identifier || cur.kind == .keyword { words.append(cur.text.lowercased()); advance() }
                if words.isEmpty { throw err("Expected a parameter type after ':'.") }
                let modeWords = words.filter { $0 == "val" || $0 == "expr" }
                let typeWords = words.filter { $0 != "val" && $0 != "expr" }
                prm.type = typeWords.isEmpty ? "anyval" : typeWords.joined(separator: " ")
                if let m = modeWords.last { prm.mode = m }
                else if typeWords.contains(where: { $0.hasSuffix("ref") }) { prm.mode = "expr" }
            }
            if isOp("=") { advance(); prm.defaultExpr = try expr() }
            out.append(prm)
            if isPunct(",") { advance() } else { break }
        }
        try expectPunct(")")
        guard isOp("=>") else { throw err("Expected '=>' after the parameter list.") }
        advance()
        return out
    }

    // MARK: Expressions

    mutating func expr() throws -> Node {
        if isKeyword("VAR") { return try varBlock() }
        return try orExpr()
    }

    private mutating func varBlock() throws -> Node {
        let start = cur.range.lowerBound
        var vs: [(name: String, expr: Node)] = []
        while isKeyword("VAR") {
            advance()
            guard cur.kind == .identifier || (cur.kind == .keyword && Lexer.softKeywords.contains(cur.text.uppercased())) else {
                throw err("Expected a variable name after VAR.")
            }
            let name = cur.text; advance()
            try expectEquals()
            vs.append((name, try expr()))
        }
        guard isKeyword("RETURN") else { throw err("Expected RETURN after the variable definitions.") }
        advance()
        let body = try expr()
        return Node(.vars(vs, body), start..<body.range.upperBound)
    }

    private mutating func orExpr() throws -> Node {
        var l = try andExpr()
        while isOp("||") { advance(); let r = try andExpr(); l = Node(.binary(.or, l, r), l.range.lowerBound..<r.range.upperBound) }
        return l
    }
    private mutating func andExpr() throws -> Node {
        var l = try notExpr()
        while isOp("&&") { advance(); let r = try notExpr(); l = Node(.binary(.and, l, r), l.range.lowerBound..<r.range.upperBound) }
        return l
    }
    private mutating func notExpr() throws -> Node {
        if isKeyword("NOT") {
            let s = cur.range.lowerBound
            advance()
            let e = try notExpr()
            return Node(.unary(.not, e), s..<e.range.upperBound)
        }
        return try comparison()
    }
    private mutating func comparison() throws -> Node {
        var l = try concat()
        while true {
            if cur.kind == .op, let op = ["=": BinOp.eq, "==": .strictEq, "<>": .ne, "<": .lt, "<=": .le, ">": .gt, ">=": .ge][cur.text] {
                advance()
                let r = try concat()
                l = Node(.binary(op, l, r), l.range.lowerBound..<r.range.upperBound)
            } else if isKeyword("IN") {
                advance()
                let r = try concat()
                l = Node(.binary(.in, l, r), l.range.lowerBound..<r.range.upperBound)
            } else { return l }
        }
    }
    private mutating func concat() throws -> Node {
        var l = try additive()
        while isOp("&") { advance(); let r = try additive(); l = Node(.binary(.concat, l, r), l.range.lowerBound..<r.range.upperBound) }
        return l
    }
    private mutating func additive() throws -> Node {
        var l = try multiplicative()
        while isOp("+") || isOp("-") {
            let op: BinOp = cur.text == "+" ? .add : .sub
            advance()
            let r = try multiplicative()
            l = Node(.binary(op, l, r), l.range.lowerBound..<r.range.upperBound)
        }
        return l
    }
    private mutating func multiplicative() throws -> Node {
        var l = try unary()
        while isOp("*") || isOp("/") {
            let op: BinOp = cur.text == "*" ? .mul : .div
            advance()
            let r = try unary()
            l = Node(.binary(op, l, r), l.range.lowerBound..<r.range.upperBound)
        }
        return l
    }
    private mutating func unary() throws -> Node {
        if isOp("-") || isOp("+") {
            let s = cur.range.lowerBound
            let op: UnOp = cur.text == "-" ? .neg : .plus
            advance()
            let e = try unary()
            return Node(.unary(op, e), s..<e.range.upperBound)
        }
        return try power()
    }
    private mutating func power() throws -> Node {
        let l = try primary()
        if isOp("^") {
            advance()
            let r = try unary()
            return Node(.binary(.pow, l, r), l.range.lowerBound..<r.range.upperBound)
        }
        return l
    }

    private static let modifierFirst: Set<String> = ["ROWS", "COLUMNS", "ASC", "DESC", "BLANKS"]
    private static let modifierNext: Set<String> = ["ROWS", "COLUMNS", "BLANKS", "FIRST", "LAST"]

    private mutating func primary() throws -> Node {
        let t = cur
        switch t.kind {
        case .number:
            advance()
            if let i = Int64(t.text) { return Node(.const(.int(i)), t.range) }
            guard let d = Double(t.text) else { throw err("'\(t.text)' is not a valid number.", t.range) }
            return Node(.const(.double(d)), t.range)
        case .string:
            advance()
            return Node(.const(.string(t.text)), t.range)
        case .bracket:
            advance()
            return Node(.column(table: nil, name: t.text, sub: nil), t.range)
        case .quotedName:
            advance()
            return try afterTableName(t)
        case .keyword where isKeyword("VAR"):
            return try varBlock()
        case .identifier, .keyword:
            if t.kind == .keyword {
                let k = t.text.uppercased()
                guard Lexer.softKeywords.contains(k), k != "DEFINE", k != "EVALUATE" else {
                    throw err("Unexpected keyword '\(t.text)'.")
                }
            }
            advance()
            if isPunct("(") { return try call(t) }
            if cur.kind == .bracket { return try afterTableName(t) }
            var name = t.text
            var end = t.range.upperBound
            if Parser.modifierFirst.contains(name.uppercased()) {
                while cur.kind == .identifier, Parser.modifierNext.contains(cur.text.uppercased()) {
                    name += " " + cur.text; end = cur.range.upperBound; advance()
                }
            }
            return Node(.ident(name), t.range.lowerBound..<end)
        case .punct where t.text == "(":
            advance()
            let first = try expr()
            if isPunct(",") {
                var items = [first]
                while isPunct(",") { advance(); items.append(try expr()) }
                let endTok = cur
                try expectPunct(")")
                return Node(.call("__TUPLE", items), t.range.lowerBound..<endTok.range.upperBound)
            }
            try expectPunct(")")
            return first
        case .punct where t.text == "{":
            advance()
            var rows: [[Node]] = []
            while !isPunct("}") {
                let e = try expr()
                if case .call("__TUPLE", let items) = e.kind { rows.append(items) } else { rows.append([e]) }
                if isPunct(",") { advance() } else { break }
            }
            let endTok = cur
            try expectPunct("}")
            return Node(.tableCtor(rows), t.range.lowerBound..<endTok.range.upperBound)
        case .eof:
            throw err("The expression ended unexpectedly.")
        default:
            throw err("Unexpected '\(describe(t))'.")
        }
    }

    private mutating func afterTableName(_ t: Tok) throws -> Node {
        if cur.kind == .bracket {
            let c = cur
            advance()
            var sub: String?
            var end = c.range.upperBound
            if isPunct("."), peek().kind == .bracket {
                advance()
                sub = cur.text; end = cur.range.upperBound
                advance()
            }
            return Node(.column(table: t.text, name: c.text, sub: sub), t.range.lowerBound..<end)
        }
        return Node(.ident(t.text), t.range)
    }

    private mutating func call(_ nameTok: Tok) throws -> Node {
        try expectPunct("(")
        var args: [Node] = []
        if !isPunct(")") {
            while true {
                if isPunct(",") || isPunct(")") {
                    args.append(Node(.missing, cur.range.lowerBound..<cur.range.lowerBound))
                } else {
                    args.append(try expr())
                }
                if isPunct(",") { advance() } else { break }
            }
        }
        let endTok = cur
        try expectPunct(")")
        return Node(.call(nameTok.text.uppercased(), args), nameTok.range.lowerBound..<endTok.range.upperBound)
    }
}
