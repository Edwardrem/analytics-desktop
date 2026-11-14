import Foundation
import FacetCore

/// One applied step of a query: a `let` binding's name and the exact source text of its expression, with the
/// comments written around it.
public struct MStep: Equatable, Sendable {
    public var name: String
    public var expression: String
    /// The comments on the lines just above the step, as written (`// …` or `/* … */`). Power Query keeps a step's
    /// description there.
    public var comments: [String]
    /// Comments after the step on the line where it ends (`Source = …, // note`), as written.
    public var trailingComment: String?
    public init(name: String, expression: String, comments: [String] = [], trailingComment: String? = nil) {
        self.name = name; self.expression = expression; self.comments = comments; self.trailingComment = trailingComment
    }

    /// The step's description (Step Properties ▸ Description): the text of the comments above it. Setting it
    /// writes one `// ` line per line of text, as Power Query does; an empty description removes them.
    public var description: String {
        get { comments.map(Self.commentText).joined(separator: "\n") }
        set {
            let text = newValue.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            comments = text.isEmpty ? [] : text.components(separatedBy: "\n").map { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l.isEmpty ? "//" : "// " + l
            }
        }
    }

    /// The text of one comment, without its markers.
    static func commentText(_ comment: String) -> String {
        if comment.hasPrefix("//") {
            let body = comment.dropFirst(2)
            return String(body.hasPrefix(" ") ? body.dropFirst() : body).trimmingCharacters(in: .whitespaces)
        }
        if comment.hasPrefix("/*") {
            var body = comment.dropFirst(2)
            if body.hasSuffix("*/") { body = body.dropLast(2) }
            return body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return comment
    }
}

/// Classification of a token for syntax colouring.
public enum MTokenClass: String, Sendable {
    case keyword, identifier, function, type, number, string, comment, `operator`, punctuation, whitespace, invalid
}

/// Tools for reading and editing a query's M script. The script (`let … in …`) is the source of truth;
/// the Power Query Editor lists its top-level `let` bindings as Applied Steps and edits by rewriting the script.
/// Edit operations re-emit the script in canonical layout and keep its comments: those above a step (its
/// description) and at the end of its line travel with the step, comments inside a step stay in its expression,
/// and comments above `let` or after the last step stay there.
public enum MScript {
    // MARK: Steps

    /// A script read as steps, with the comments that belong to no step.
    struct Parsed {
        var steps: [MStep]
        /// Comments above `let`.
        var header: [String] = []
        /// Comments on their own lines after the last step (before `in`, or after it when the result is a step name).
        var footer: [String] = []

        /// The script for `steps` (edited), keeping this script's header and footer.
        func script(_ steps: [MStep], result: String? = nil) -> String {
            MScript.script(from: steps, result: result, header: header, footer: footer)
        }
    }

    static func parsed(_ script: String) -> Parsed {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ast = try? MParser.parse(script), case .letIn(let bindings, let body) = ast, !bindings.isEmpty else {
            return Parsed(steps: [MStep(name: "Source", expression: trimmed)])
        }
        let u = Array(script.utf16)
        func slice(_ r: Range<Int>) -> String { String(utf16CodeUnits: Array(u[r]), count: r.count) }
        var p = Parsed(steps: bindings.map { MStep(name: $0.name, expression: slice($0.exprRange)) })
        let (toks, _) = MLexer.tokenize(script, includeTrivia: true)
        let lastEnd = bindings[bindings.count - 1].exprRange.upperBound
        let inTok = toks.first { $0.location >= lastEnd && $0.kind == .keyword && $0.text == "in" }
        let resultIsStep: Bool = { if case .identifier(let n, _) = body { return bindings.contains { $0.name == n } }; return false }()
        placeComments(toks.filter { $0.kind == .comment }, bindings: bindings, in: toks, inAt: inTok?.location,
                      keepAfterIn: resultIsStep, script: u, into: &p)
        if case .identifier(let n, _) = body, n == bindings.last?.name { return p }
        // The `in` expression isn't the last step's name: it becomes a final step so that nothing is lost.
        if let inTok {
            let bodyText = slice((inTok.location + inTok.length)..<u.count).trimmingCharacters(in: .whitespacesAndNewlines)
            var name = "Result", k = 1
            while p.steps.contains(where: { $0.name == name }) { name = "Result\(k)"; k += 1 }
            p.steps.append(MStep(name: name, expression: bodyText))
        }
        return p
    }

    /// Gives each comment outside the steps' expressions its place: above a step (that step's), at the end of a
    /// step's line, above `let` (header) or after the last step (footer). Comments after `in` are kept only when the
    /// result is a step name; otherwise they are part of the final step's expression.
    private static func placeComments(_ comments: [MToken], bindings: [MBinding], in toks: [MToken], inAt: Int?, keepAfterIn: Bool,
                                      script u: [UInt16], into p: inout Parsed) {
        let letAt = toks.first { $0.kind == .keyword && $0.text == "let" }?.location ?? 0
        func sameLine(_ from: Int, _ to: Int) -> Bool {
            from <= to && !u[from..<to].contains { $0 == 10 || $0 == 13 }
        }
        func trail(_ i: Int, _ text: String) { p.steps[i].trailingComment = p.steps[i].trailingComment.map { $0 + " " + text } ?? text }
        for c in comments {
            let at = c.location
            if at < letAt { p.header.append(c.text); continue }
            if bindings.contains(where: { $0.exprRange.contains(at) }) { continue }   // inside a step: part of its expression
            if let i = bindings.firstIndex(where: { $0.nameRange.lowerBound > at }) {
                if i > 0, at < bindings[i - 1].exprRange.upperBound {
                    p.steps[i - 1].comments.append(c.text)                            // between a step's name and its expression
                } else if i > 0, sameLine(bindings[i - 1].exprRange.upperBound, at) {
                    trail(i - 1, c.text)
                } else {
                    p.steps[i].comments.append(c.text)
                }
                continue
            }
            let last = bindings.count - 1
            if at < bindings[last].exprRange.lowerBound { p.steps[last].comments.append(c.text) }
            else if sameLine(bindings[last].exprRange.upperBound, at) { trail(last, c.text) }
            else if let inAt, at > inAt, !keepAfterIn { continue }
            else { p.footer.append(c.text) }
        }
    }

    /// The applied steps of a script: its top-level `let` bindings in order, each with its comments. A script that
    /// is not a `let` (or does not parse) is a single step named "Source". When the `in` expression is not simply
    /// the last step's name, it becomes a final step so that `script(from:)` preserves meaning.
    public static func steps(of script: String) -> [MStep] { parsed(script).steps }

    /// The name of the step the script returns (nil when the `in` expression is not a plain step reference).
    public static func resultName(of script: String) -> String? {
        guard let ast = try? MParser.parse(script), case .letIn(_, let body) = ast, case .identifier(let n, _) = body else { return nil }
        return n
    }

    /// Build a script in canonical layout, with each step's comments. `result` defaults to the last step.
    public static func script(from steps: [MStep], result: String? = nil) -> String {
        script(from: steps, result: result, header: [], footer: [])
    }

    static func script(from steps: [MStep], result: String?, header: [String], footer: [String]) -> String {
        guard !steps.isEmpty else { return "let\n    Source = \"\"\nin\n    Source" }
        var out = header.map { $0 + "\n" }.joined() + "let\n"
        for (i, step) in steps.enumerated() {
            for c in step.comments { out += "    " + c + "\n" }
            var line = "    " + MSyntax.identifier(step.name) + " = " + step.expression
            // A line comment at the end of an expression would swallow the comma after it.
            if endsWithLineComment(step.expression) { line += "\n   " }
            if i < steps.count - 1 { line += "," }
            if let t = step.trailingComment { line += " " + t }
            out += line + "\n"
        }
        for c in footer { out += "    " + c + "\n" }
        return out + "in\n    " + MSyntax.identifier(result ?? steps[steps.count - 1].name)
    }

    private static func endsWithLineComment(_ expression: String) -> Bool {
        guard expression.contains("//") else { return false }
        let last = MLexer.tokenize(expression, includeTrivia: true).tokens.last { $0.kind != .whitespace && $0.kind != .eof }
        return last?.kind == .comment && last?.text.hasPrefix("//") == true
    }

    /// Set a step's description (the comment lines above it, as Power Query keeps it).
    public static func settingStepDescription(_ name: String, to description: String, in script: String) -> String {
        let p = parsed(script)
        var s = p.steps
        guard let i = s.firstIndex(where: { $0.name == name }) else { return script }
        s[i].description = description
        guard s[i] != p.steps[i] else { return script }
        return p.script(s, result: resultIfPresent(resultName(of: script), s))
    }

    /// A step name not yet used in the script: "Filtered Rows", "Filtered Rows1", "Filtered Rows2", …
    public static func uniqueStepName(_ base: String, in script: String) -> String {
        let used = Set(steps(of: script).map(\.name))
        if !used.contains(base) { return base }
        var k = 1
        while used.contains("\(base)\(k)") { k += 1 }
        return "\(base)\(k)"
    }

    /// Append a step. `expression` receives the M identifier text of the current last step (quoted when needed).
    public static func appendingStep(named base: String, expression: (_ previous: String) -> String, to script: String) -> String {
        let p = parsed(script)
        var s = p.steps
        let prev = MSyntax.identifier(s.last?.name ?? "Source")
        s.append(MStep(name: uniqueStepName(base, in: script), expression: expression(prev)))
        return p.script(s)
    }

    /// Append a UI transformation as a new, uniquely named step.
    public static func appending(_ transform: Transform, to script: String) -> String {
        appendingStep(named: transform.stepName, expression: { transform.expression(previous: $0) }, to: script)
    }

    /// Rename a step and every later reference to it.
    public static func renamingStep(_ old: String, to new: String, in script: String) -> String {
        let p = parsed(script)
        var s = p.steps
        guard let i = s.firstIndex(where: { $0.name == old }), !s.contains(where: { $0.name == new }) else { return script }
        let result = resultName(of: script)
        s[i].name = new
        for j in s.indices where j != i { s[j].expression = replacingIdentifier(old, with: new, in: s[j].expression) }
        return p.script(s, result: result == old ? new : resultIfPresent(result, s))
    }

    /// Delete a step. Later references to it are re-pointed to its predecessor.
    public static func deletingStep(_ name: String, in script: String) -> String {
        let p = parsed(script)
        var s = p.steps
        guard let i = s.firstIndex(where: { $0.name == name }), s.count > 1 else { return script }
        let result = resultName(of: script)
        s.remove(at: i)
        if i > 0 {
            let pred = s[i - 1].name
            for j in i..<s.count { s[j].expression = replacingIdentifier(name, with: pred, in: s[j].expression) }
        }
        return p.script(s, result: result == name ? nil : resultIfPresent(result, s))
    }

    /// Move a step to a new position. In a linear chain, each step's reference to its predecessor follows the new order.
    public static func movingStep(_ name: String, to index: Int, in script: String) -> String {
        let p = parsed(script)
        let old = p.steps
        guard let from = old.firstIndex(where: { $0.name == name }) else { return script }
        let to = max(0, min(index, old.count - 1))
        if to == from { return script }
        let result = resultName(of: script)
        let wasLast = result == old.last?.name
        // which steps referenced their immediate predecessor?
        var chained: [String: String] = [:]
        for i in 1..<max(1, old.count) where referencedIdentifiers(inExpression: old[i].expression).contains(old[i - 1].name) {
            chained[old[i].name] = old[i - 1].name
        }
        var s = old
        let moved = s.remove(at: from)
        s.insert(moved, at: to)
        for i in s.indices {
            guard let oldPred = chained[s[i].name] else { continue }
            if i > 0, s[i - 1].name != oldPred {
                s[i].expression = replacingIdentifier(oldPred, with: s[i - 1].name, in: s[i].expression)
            }
        }
        return p.script(s, result: wasLast ? nil : resultIfPresent(result, s))
    }

    /// Replace the expression of a step (formula-bar edit).
    public static func replacingStepExpression(_ name: String, with expression: String, in script: String) -> String {
        let p = parsed(script)
        var s = p.steps
        guard let i = s.firstIndex(where: { $0.name == name }) else { return script }
        let result = resultName(of: script)
        s[i].expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.script(s, result: resultIfPresent(result, s))
    }

    /// Insert a step after `name` (nil = at the start). The step that followed `name` and referenced it now references the new step.
    public static func insertingStep(_ step: MStep, after name: String?, in script: String) -> String {
        let p = parsed(script)
        var s = p.steps
        let result = resultName(of: script)
        var new = step
        var n = new.name, k = 1
        while s.contains(where: { $0.name == n }) { n = "\(new.name)\(k)"; k += 1 }
        new.name = n
        guard let name, let i = s.firstIndex(where: { $0.name == name }) else {
            s.insert(new, at: 0)
            return p.script(s, result: resultIfPresent(result, s))
        }
        s.insert(new, at: i + 1)
        if i + 2 < s.count { s[i + 2].expression = replacingIdentifier(name, with: new.name, in: s[i + 2].expression) }
        let wasLast = i + 2 == s.count && (result == nil || result == name)
        return p.script(s, result: wasLast ? nil : resultIfPresent(result, s))
    }

    /// A script that evaluates only steps `0...index` (for previewing an intermediate step, or Delete Until End).
    public static func truncating(_ script: String, upToStep index: Int) -> String {
        let p = parsed(script)
        guard index >= 0, index < p.steps.count - 1 else { return script }
        return p.script(Array(p.steps.prefix(index + 1)))
    }

    private static func resultIfPresent(_ result: String?, _ steps: [MStep]) -> String? {
        guard let result, steps.contains(where: { $0.name == result }) else { return nil }
        return result
    }

    // MARK: Identifier rewriting

    /// Replace references to identifier `old` with `new` in M text. Token-aware: text literals, comments,
    /// field selectors (`[old]`) and record field names (`[old = …]`) are left alone.
    public static func replacingIdentifier(_ old: String, with new: String, in text: String) -> String {
        let (toks, _) = MLexer.tokenize(text, includeTrivia: true)
        let sig = toks.enumerated().filter { $0.element.kind != .whitespace && $0.element.kind != .comment && $0.element.kind != .eof }
        var replace = Set<Int>() // token indices to rewrite
        // bracket context stack: nil = ( or {, "field" = selector, "record" = record literal (expecting name until '=')
        var stack: [(kind: Character, expectName: Bool)] = []
        for (pos, entry) in sig.enumerated() {
            let (i, t) = entry
            let prev = pos > 0 ? sig[pos - 1].element : nil
            if t.kind == .punctuation {
                switch t.text {
                case "(", "{": stack.append(("p", false))
                case "[":
                    let prevEndsExpr: Bool = {
                        guard let p = prev else { return false }
                        switch p.kind {
                        case .identifier, .quotedIdentifier, .number, .text: return true
                        case .punctuation: return p.text == ")" || p.text == "]" || p.text == "}"
                        case .operator: return p.text == "?"
                        default: return false
                        }
                    }()
                    var isRecord = false
                    if !prevEndsExpr {
                        // look ahead like the parser: `]` → empty record, `[` → projection, first of `=` / `]` decides
                        var k = pos + 1
                        if k < sig.count, sig[k].element.text == "]", sig[k].element.kind == .punctuation { isRecord = true }
                        else if k < sig.count, sig[k].element.text == "[", sig[k].element.kind == .punctuation { isRecord = false }
                        else {
                            while k < sig.count {
                                let x = sig[k].element
                                if x.kind == .operator, x.text == "=" { isRecord = true; break }
                                if x.kind == .punctuation { isRecord = x.text != "]"; break }
                                k += 1
                            }
                        }
                    }
                    stack.append((isRecord ? "r" : "f", isRecord))
                case ")", "}", "]": if !stack.isEmpty { stack.removeLast() }
                case ",": if let top = stack.last, top.kind == "r" { stack[stack.count - 1].expectName = true }
                default: break
                }
                continue
            }
            if t.kind == .operator, t.text == "=", let top = stack.last, top.kind == "r", top.expectName {
                stack[stack.count - 1].expectName = false
                continue
            }
            guard t.kind == .identifier || t.kind == .quotedIdentifier, t.value == old else { continue }
            if let top = stack.last, top.kind == "f" || (top.kind == "r" && top.expectName) { continue }
            replace.insert(i)
        }
        if replace.isEmpty { return text }
        let newText = MSyntax.identifier(new)
        return toks.enumerated().map { replace.contains($0.offset) ? newText : $0.element.text }.joined()
    }

    // MARK: Tokens

    /// All tokens including comments and whitespace (for syntax colouring). Offsets are UTF-16.
    public static func tokens(_ text: String) -> [MToken] {
        MLexer.tokenize(text, includeTrivia: true).tokens.filter { $0.kind != .eof }
    }

    private static let typeWords: Set<String> = ["any", "anynonnull", "binary", "date", "datetime", "datetimezone", "duration", "function",
                                                  "list", "logical", "none", "number", "record", "table", "text", "time", "nullable", "optional", "action"]
    public static func classify(_ token: MToken) -> MTokenClass {
        switch token.kind {
        case .keyword: return .keyword
        case .identifier:
            if typeWords.contains(token.text) || token.text.hasSuffix(".Type") { return .type }
            if case .function? = MLibrary.shared.values[token.text] { return .function }
            return .identifier
        case .quotedIdentifier: return .identifier
        case .number: return .number
        case .text: return .string
        case .comment: return .comment
        case .operator: return .operator
        case .punctuation: return .punctuation
        case .whitespace: return .whitespace
        case .invalid, .eof: return .invalid
        }
    }

    // MARK: Queries

    /// "Duplicate": an independent copy of the query.
    public static func duplicateQuery(_ q: QueryDefinition, newName: String) -> QueryDefinition {
        var c = q
        c.id = UUID(); c.name = newName
        return c
    }
    /// "Reference": a new query whose source is the original query.
    public static func referenceQuery(_ q: QueryDefinition, newName: String) -> QueryDefinition {
        var c = QueryDefinition(name: newName, mScript: "let\n    Source = \(MSyntax.identifier(q.name))\nin\n    Source")
        c.group = q.group
        return c
    }
    /// The M script Power BI stores for a parameter query: `<value> meta [IsParameterQuery=true, …]`.
    public static func parameterScript(_ p: QueryParameter) -> String {
        let typeName: String
        switch p.type {
        case .text: typeName = "Text"
        case .integer, .decimal, .currency: typeName = "Number"
        case .boolean: typeName = "Logical"
        case .date: typeName = "Date"
        case .dateTime: typeName = "DateTime"
        case .time: typeName = "Time"
        case .duration: typeName = "Duration"
        case .binary: typeName = "Binary"
        case .any: typeName = "Any"
        }
        var meta = "IsParameterQuery=true, Type=\(MSyntax.text(typeName)), IsParameterQueryRequired=\(p.isRequired)"
        if !p.suggestedValues.isEmpty {
            meta += ", List={" + p.suggestedValues.map { MSyntax.literal(MValue($0, type: p.type)) }.joined(separator: ", ") + "}"
        }
        if !p.defaultValue.isNull { meta += ", DefaultValue=" + MSyntax.literal(MValue(p.defaultValue, type: p.type)) }
        return MSyntax.literal(MValue(p.currentValue, type: p.type)) + " meta [\(meta)]"
    }

    /// "Convert to function": wrap the query as a function of `parameters`, replacing references to the
    /// identifiers named by the keys of `replacing` (e.g. parameter queries or a sample-file step) with parameter names.
    public static func toFunction(_ script: String, parameters: [(name: String, type: String?)], replacing: [String: String] = [:]) -> String {
        var body = script.trimmingCharacters(in: .whitespacesAndNewlines)
        for (old, new) in replacing.sorted(by: { $0.key < $1.key }) { body = replacingIdentifier(old, with: new, in: body) }
        let params = parameters.map { MSyntax.identifier($0.name) + ($0.type.map { " as " + $0 } ?? "") }.joined(separator: ", ")
        return "(\(params)) =>\n" + body
    }
}
