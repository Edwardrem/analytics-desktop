import Foundation

/// Recursive-descent parser for Power Query M.
public struct MParser {
    private let tokens: [MToken]
    private let source: [UInt16]
    private var p = 0

    /// Parse a complete M expression (or section document). Throws `MDiagnostic` on syntax errors.
    public static func parse(_ text: String) throws -> MExpr {
        let (toks, diags) = MLexer.tokenize(text)
        if let d = diags.first { throw d }
        var parser = MParser(tokens: toks, source: Array(text.utf16))
        let e: MExpr
        if parser.peek.kind == .keyword, parser.peek.text == "section" { e = try parser.parseSection() }
        else { e = try parser.parseExpression() }
        guard parser.peek.kind == .eof else { throw parser.fail("Token '\(parser.peek.text)' was not expected here.") }
        return e
    }

    private init(tokens: [MToken], source: [UInt16]) { self.tokens = tokens; self.source = source }

    // MARK: Token helpers
    private var peek: MToken { tokens[p] }
    private func peekAt(_ k: Int) -> MToken { tokens[min(p + k, tokens.count - 1)] }
    @discardableResult private mutating func advance() -> MToken { let t = tokens[p]; if p < tokens.count - 1 { p += 1 }; return t }
    private func isSym(_ s: String, at k: Int = 0) -> Bool {
        let t = peekAt(k); return (t.kind == .operator || t.kind == .punctuation) && t.text == s
    }
    private func isKw(_ s: String, at k: Int = 0) -> Bool { let t = peekAt(k); return t.kind == .keyword && t.text == s }
    private mutating func acceptSym(_ s: String) -> Bool { if isSym(s) { advance(); return true }; return false }
    private mutating func acceptKw(_ s: String) -> Bool { if isKw(s) { advance(); return true }; return false }
    private mutating func expectSym(_ s: String) throws {
        guard acceptSym(s) else { throw fail("Token '\(s)' expected" + (peek.kind == .eof ? " but the expression ended." : ", found '\(peek.text)'.")) }
    }
    private mutating func expectKw(_ s: String) throws {
        guard acceptKw(s) else { throw fail("Token '\(s)' expected" + (peek.kind == .eof ? " but the expression ended." : ", found '\(peek.text)'.")) }
    }
    private func fail(_ msg: String) -> MDiagnostic {
        let t = peek
        return MDiagnostic(message: msg, line: t.line, column: t.column, location: t.location, length: max(1, t.length))
    }
    private func slice(_ a: Int, _ b: Int) -> String { String(utf16CodeUnits: Array(source[a..<b]), count: b - a) }

    // MARK: Section documents
    private mutating func parseSection() throws -> MExpr {
        try expectKw("section")
        if peek.kind == .identifier { advance() }
        try expectSym(";")
        var members: [MBinding] = []
        while peek.kind != .eof {
            _ = acceptKw("shared")
            let b = try parseBinding()
            members.append(b)
            try expectSym(";")
        }
        return .section(members)
    }

    // MARK: Expressions
    private mutating func parseExpression() throws -> MExpr {
        let t = peek
        if t.kind == .keyword {
            switch t.text {
            case "let": return try parseLet()
            case "if":
                advance()
                let c = try parseExpression(); try expectKw("then")
                let a = try parseExpression(); try expectKw("else")
                let b = try parseExpression()
                return .ifThenElse(c, a, b)
            case "each": advance(); return .each(try parseExpression())
            case "error": advance(); return .raise(try parseExpression())
            case "try":
                advance()
                let body = try parseExpression()
                if acceptKw("otherwise") { return .tryOtherwise(body, try parseExpression()) }
                if peek.kind == .identifier, peek.text == "catch" {
                    advance()
                    try expectSym("(")
                    var param: String?
                    if !isSym(")") { param = try parseIdentifierName() }
                    try expectSym(")"); try expectSym("=>")
                    return .tryCatch(body, param: param, handler: try parseExpression())
                }
                return .tryOtherwise(body, nil)
            default: break
            }
        }
        if isSym("("), isFunctionLiteralAhead() { return try parseFunctionLiteral() }
        return try parseCoalesce()
    }

    private mutating func parseLet() throws -> MExpr {
        try expectKw("let")
        var bindings: [MBinding] = []
        if !isKw("in") {
            repeat { bindings.append(try parseBinding()) } while acceptSym(",")
        }
        try expectKw("in")
        return .letIn(bindings, try parseExpression())
    }

    private mutating func parseBinding() throws -> MBinding {
        let nameTok = peek
        let name = try parseIdentifierName()
        try expectSym("=")
        let start = peek.location
        let e = try parseExpression()
        let endTok = tokens[max(0, p - 1)]
        return MBinding(name: name, expr: e, nameRange: nameTok.location..<(nameTok.location + nameTok.length),
                        exprRange: start..<(endTok.location + endTok.length))
    }

    private mutating func parseIdentifierName() throws -> String {
        let t = peek
        if t.kind == .identifier { advance(); return t.text }
        if t.kind == .quotedIdentifier { advance(); return t.value }
        throw fail("Identifier expected" + (t.kind == .eof ? "." : ", found '\(t.text)'."))
    }

    /// Decide whether `(` starts a function literal: scan to the matching `)` and look for `=>` (optionally after `as type`).
    private func isFunctionLiteralAhead() -> Bool {
        var depth = 0, k = 0
        while true {
            let t = peekAt(k)
            if t.kind == .eof { return false }
            if t.kind == .punctuation {
                if t.text == "(" || t.text == "[" || t.text == "{" { depth += 1 }
                if t.text == ")" || t.text == "]" || t.text == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            k += 1
        }
        if isSym("=>", at: k + 1) { return true }
        guard isKw("as", at: k + 1) else { return false }
        // `) as <type> =>` — scan a short distance for `=>` before anything that ends a type.
        var j = k + 2, d = 0
        while j < k + 64 {
            let t = peekAt(j)
            if t.kind == .eof { return false }
            if d == 0, t.kind == .operator, t.text == "=>" { return true }
            if t.kind == .punctuation {
                if "([{".contains(t.text) { d += 1 }
                else if ")]}".contains(t.text) { d -= 1; if d < 0 { return false } }
                else if d == 0 { return false }
            } else if d == 0, t.kind == .keyword, !["nullable", "type", "table", "function", "null"].contains(t.text) { return false }
            else if d == 0, t.kind == .operator { return false }
            j += 1
        }
        return false
    }

    private mutating func parseFunctionLiteral() throws -> MExpr {
        let params = try parseParameterList()
        var ret: MTypeExpr?
        if acceptKw("as") { ret = try parseType() }
        try expectSym("=>")
        return .function(params: params, returns: ret, body: try parseExpression())
    }

    private mutating func parseParameterList() throws -> [MParamDecl] {
        try expectSym("(")
        var params: [MParamDecl] = []
        if !isSym(")") {
            repeat {
                var optional = false
                if peek.kind == .identifier, peek.text == "optional", peekAt(1).kind == .identifier || peekAt(1).kind == .quotedIdentifier {
                    advance(); optional = true
                }
                let name = try parseIdentifierName()
                var type: MTypeExpr?
                if acceptKw("as") { type = try parseType() }
                params.append(MParamDecl(name: name, type: type, isOptional: optional))
            } while acceptSym(",")
        }
        try expectSym(")")
        return params
    }

    private mutating func parseCoalesce() throws -> MExpr {
        let l = try parseOr()
        if acceptSym("??") { return .binary(.coalesce, l, try parseCoalesce()) }
        return l
    }
    private mutating func parseOr() throws -> MExpr {
        var l = try parseAnd()
        while acceptKw("or") { l = .binary(.or, l, try parseAnd()) }
        return l
    }
    private mutating func parseAnd() throws -> MExpr {
        var l = try parseIsAs()
        while acceptKw("and") { l = .binary(.and, l, try parseIsAs()) }
        return l
    }
    private mutating func parseIsAs() throws -> MExpr {
        var l = try parseEquality()
        while true {
            if acceptKw("is") { l = .isType(l, try parseType()) }
            else if acceptKw("as") { l = .asType(l, try parseType()) }
            else { return l }
        }
    }
    private mutating func parseEquality() throws -> MExpr {
        var l = try parseRelational()
        while true {
            if acceptSym("=") { l = .binary(.equal, l, try parseRelational()) }
            else if acceptSym("<>") { l = .binary(.notEqual, l, try parseRelational()) }
            else { return l }
        }
    }
    private mutating func parseRelational() throws -> MExpr {
        var l = try parseAdditive()
        while true {
            if acceptSym("<") { l = .binary(.less, l, try parseAdditive()) }
            else if acceptSym("<=") { l = .binary(.lessEqual, l, try parseAdditive()) }
            else if acceptSym(">") { l = .binary(.greater, l, try parseAdditive()) }
            else if acceptSym(">=") { l = .binary(.greaterEqual, l, try parseAdditive()) }
            else { return l }
        }
    }
    private mutating func parseAdditive() throws -> MExpr {
        var l = try parseMultiplicative()
        while true {
            if acceptSym("+") { l = .binary(.add, l, try parseMultiplicative()) }
            else if acceptSym("-") { l = .binary(.subtract, l, try parseMultiplicative()) }
            else if acceptSym("&") { l = .binary(.concat, l, try parseMultiplicative()) }
            else { return l }
        }
    }
    private mutating func parseMultiplicative() throws -> MExpr {
        var l = try parseMeta()
        while true {
            if acceptSym("*") { l = .binary(.multiply, l, try parseMeta()) }
            else if acceptSym("/") { l = .binary(.divide, l, try parseMeta()) }
            else { return l }
        }
    }
    private mutating func parseMeta() throws -> MExpr {
        let l = try parseUnary()
        if acceptKw("meta") { return .meta(l, try parseUnary()) }
        return l
    }
    private mutating func parseUnary() throws -> MExpr {
        if acceptSym("+") { return .unary(.plus, try parseUnary()) }
        if acceptSym("-") { return .unary(.minus, try parseUnary()) }
        if acceptKw("not") { return .unary(.not, try parseUnary()) }
        if isKw("type") {
            // `type` followed by a primary type; otherwise `type` is not valid here.
            advance()
            return .typeValue(try parseType())
        }
        return try parsePrimary()
    }

    // MARK: Types
    private static let primitiveTypes: [String: MType] = [
        "any": .any, "anynonnull": .anynonnull, "binary": .binary, "date": .date, "datetime": .datetime,
        "datetimezone": .datetimezone, "duration": .duration, "function": .function, "list": .anyList,
        "logical": .logical, "none": .none, "null": .null, "number": .plainNumber, "record": .anyRecord,
        "table": .anyTable, "text": .text, "time": .time, "type": .type, "action": .action,
    ]

    private mutating func parseType() throws -> MTypeExpr {
        let t = peek
        if t.kind == .identifier, t.text == "nullable" { advance(); return .nullable(try parseType()) }
        if isSym("{") {
            advance()
            let item = try parseType()
            try expectSym("}")
            return .list(item)
        }
        if isSym("[") { return try parseRecordType() }
        if (t.kind == .identifier && t.text == "table") {
            advance()
            if isSym("[") { return .table(try parseRecordType()) }
            // `table <row type expression>` — only when a primary clearly follows
            if peek.kind == .identifier || peek.kind == .quotedIdentifier || isSym("(") {
                if peek.kind == .identifier, MParser.primitiveTypes[peek.text] != nil { return .primitive(.anyTable) }
                return .table(.expr(try parsePrimary()))
            }
            return .primitive(.anyTable)
        }
        if t.kind == .identifier, t.text == "function" || t.text == "list" || t.text == "record", true {
            if t.text == "function", isSym("(", at: 1) {
                advance()
                let params = try parseParameterList()
                var ret: MTypeExpr?
                if acceptKw("as") { ret = try parseType() }
                return .function(params: params, returns: ret)
            }
        }
        if t.kind == .keyword, t.text == "null" { advance(); return .primitive(.null) }
        if t.kind == .keyword, t.text == "type" { advance(); return .primitive(.type) }
        if t.kind == .identifier, let prim = MParser.primitiveTypes[t.text] { advance(); return .primitive(prim) }
        return .expr(try parsePrimary())
    }

    private mutating func parseRecordType() throws -> MTypeExpr {
        try expectSym("[")
        var fields: [(name: String, type: MTypeExpr?, optional: Bool)] = []
        var open = false
        if !isSym("]") {
            repeat {
                if acceptSym("...") { open = true; break }
                var optional = false
                if peek.kind == .identifier, peek.text == "optional", !isSym("=", at: 1), !isSym("]", at: 1), !isSym(",", at: 1) {
                    advance(); optional = true
                }
                let name = try parseGeneralizedIdentifier(terminators: ["=", "]", ","])
                var type: MTypeExpr?
                if acceptSym("=") { type = try parseType() }
                fields.append((name, type, optional))
            } while acceptSym(",")
        }
        try expectSym("]")
        return .record(fields: fields, open: open)
    }

    /// A generalized identifier: the raw source text of consecutive word tokens (may contain spaces),
    /// or a single quoted identifier.
    private mutating func parseGeneralizedIdentifier(terminators: Set<String>) throws -> String {
        if peek.kind == .quotedIdentifier { return advance().value }
        let first = peek
        var last: MToken?
        while true {
            let t = peek
            if t.kind == .eof { break }
            if (t.kind == .operator || t.kind == .punctuation), terminators.contains(t.text) { break }
            guard t.kind == .identifier || t.kind == .keyword || t.kind == .number || (t.kind == .operator && [".", "-", "/", "&", "?", "!", "@"].contains(t.text)) || t.kind == .text else {
                throw fail("Invalid field name near '\(t.text)'.")
            }
            last = advance()
        }
        guard let l = last else { throw fail("Field name expected.") }
        return slice(first.location, l.location + l.length).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Primary
    private mutating func parsePrimary() throws -> MExpr {
        var e = try parsePrimaryHead()
        while true {
            if isSym("(") {
                advance()
                var args: [MExpr] = []
                if !isSym(")") { repeat { args.append(try parseExpression()) } while acceptSym(",") }
                try expectSym(")")
                e = .invoke(e, args)
            } else if isSym("{") {
                advance()
                let idx = try parseExpression()
                try expectSym("}")
                e = .itemAccess(e, idx, optional: acceptSym("?"))
            } else if isSym("[") {
                e = try parseFieldSelection(target: e)
            } else { return e }
        }
    }

    /// `[name]`, `[name]?`, `[[a],[b]]`, `[[a],[b]]?` applied to `target` (nil = implicit `_`).
    private mutating func parseFieldSelection(target: MExpr?) throws -> MExpr {
        try expectSym("[")
        if isSym("[") {
            var names: [String] = []
            repeat {
                try expectSym("[")
                names.append(try parseGeneralizedIdentifier(terminators: ["]"]))
                try expectSym("]")
            } while acceptSym(",")
            try expectSym("]")
            return .projection(target, names, optional: acceptSym("?"))
        }
        let name = try parseGeneralizedIdentifier(terminators: ["]"])
        try expectSym("]")
        return .fieldAccess(target, name, optional: acceptSym("?"))
    }

    /// At `[`: is this a record literal (true) or an implicit field access / projection (false)?
    private func bracketIsRecordLiteral() -> Bool {
        if isSym("]", at: 1) { return true }
        if isSym("[", at: 1) { return false }
        var k = 1
        while true {
            let t = peekAt(k)
            if t.kind == .eof { return true }
            if t.kind == .operator, t.text == "=" { return true }
            if t.kind == .punctuation, t.text == "]" { return false }
            if t.kind == .punctuation, t.text != "]" { return true }
            k += 1
        }
    }

    private mutating func parsePrimaryHead() throws -> MExpr {
        let t = peek
        switch t.kind {
        case .number:
            advance()
            if t.text.hasPrefix("0x") || t.text.hasPrefix("0X") {
                guard let v = UInt64(t.text.dropFirst(2), radix: 16) else { throw fail("Invalid hexadecimal number '\(t.text)'.") }
                return .literal(.number(Double(v)))
            }
            guard let d = Double(t.text) else { throw fail("Invalid number '\(t.text)'.") }
            return .literal(.number(d))
        case .text: advance(); return .literal(.text(t.value))
        case .quotedIdentifier: advance(); return .identifier(t.value, inclusive: false)
        case .identifier: advance(); return .identifier(t.text, inclusive: false)
        case .keyword:
            switch t.text {
            case "true": advance(); return .literal(.logical(true))
            case "false": advance(); return .literal(.logical(false))
            case "null": advance(); return .literal(.null)
            case "#infinity": advance(); return .literal(.number(.infinity))
            case "#nan": advance(); return .literal(.number(.nan))
            case "#date", "#datetime", "#datetimezone", "#duration", "#time", "#table", "#binary", "#shared", "#sections":
                advance(); return .identifier(t.text, inclusive: false)
            default: throw fail("Token '\(t.text)' was not expected here.")
            }
        case .operator:
            if t.text == "@" {
                advance()
                return .identifier(try parseIdentifierName(), inclusive: true)
            }
            if t.text == "..." { advance(); return .notImplemented }
            throw fail("Token '\(t.text)' was not expected here.")
        case .punctuation:
            if t.text == "(" {
                advance()
                let e = try parseExpression()
                try expectSym(")")
                return e
            }
            if t.text == "{" {
                advance()
                var items: [MExpr] = []
                if !isSym("}") {
                    repeat {
                        let a = try parseExpression()
                        if acceptSym("..") { items.append(.range(a, try parseExpression())) } else { items.append(a) }
                    } while acceptSym(",")
                }
                try expectSym("}")
                return .list(items)
            }
            if t.text == "[" {
                if !bracketIsRecordLiteral() { return try parseFieldSelection(target: nil) }
                advance()
                var fields: [(name: String, value: MExpr)] = []
                if !isSym("]") {
                    repeat {
                        let name = try parseGeneralizedIdentifier(terminators: ["="])
                        try expectSym("=")
                        fields.append((name, try parseExpression()))
                    } while acceptSym(",")
                }
                try expectSym("]")
                return .record(fields)
            }
            throw fail("Token '\(t.text)' was not expected here.")
        case .eof: throw fail("The expression is incomplete.")
        default: throw fail("Token '\(t.text)' was not expected here.")
        }
    }
}
