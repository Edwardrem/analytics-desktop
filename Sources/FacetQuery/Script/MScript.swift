import Foundation
import FacetCore

/// One applied step of a query: a `let` binding's name and the exact source text of its expression.
public struct MStep: Equatable, Sendable {
    public var name: String
    public var expression: String
    public init(name: String, expression: String) { self.name = name; self.expression = expression }
}

/// Classification of a token for syntax colouring.
public enum MTokenClass: String, Sendable {
    case keyword, identifier, function, type, number, string, comment, `operator`, punctuation, whitespace, invalid
}

/// Tools for reading and editing a query's M script. The script (`let … in …`) is the source of truth;
/// the Power Query Editor lists its top-level `let` bindings as Applied Steps and edits by rewriting the script.
/// Edit operations re-emit the script in canonical layout (comments between steps are not preserved).
public enum MScript {
    // MARK: Steps

    /// The applied steps of a script: its top-level `let` bindings in order. A script that is not a `let`
    /// (or does not parse) is a single step named "Source". When the `in` expression is not simply the last
    /// step's name, it becomes a final step so that `script(from:)` preserves meaning.
    public static func steps(of script: String) -> [MStep] {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ast = try? MParser.parse(script), case .letIn(let bindings, let body) = ast, !bindings.isEmpty else {
            return [MStep(name: "Source", expression: trimmed)]
        }
        let u = Array(script.utf16)
        func slice(_ r: Range<Int>) -> String { String(utf16CodeUnits: Array(u[r]), count: r.count) }
        var steps = bindings.map { MStep(name: $0.name, expression: slice($0.exprRange)) }
        if case .identifier(let n, _) = body, n == bindings.last?.name { return steps }
        // find the top-level `in` after the last binding
        let (toks, _) = MLexer.tokenize(script)
        let lastEnd = bindings[bindings.count - 1].exprRange.upperBound
        if let inTok = toks.first(where: { $0.location >= lastEnd && $0.kind == .keyword && $0.text == "in" }) {
            let bodyText = slice((inTok.location + inTok.length)..<u.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if case .identifier(let n, _) = body, let i = steps.firstIndex(where: { $0.name == n }) {
                // result is an earlier step: keep the steps and remember via a trailing reference step
                _ = i
            }
            var name = "Result", k = 1
            while steps.contains(where: { $0.name == name }) { name = "Result\(k)"; k += 1 }
            steps.append(MStep(name: name, expression: bodyText))
        }
        return steps
    }

    /// The name of the step the script returns (nil when the `in` expression is not a plain step reference).
    public static func resultName(of script: String) -> String? {
        guard let ast = try? MParser.parse(script), case .letIn(_, let body) = ast, case .identifier(let n, _) = body else { return nil }
        return n
    }

    /// Build a script in canonical layout. `result` defaults to the last step.
    public static func script(from steps: [MStep], result: String? = nil) -> String {
        guard !steps.isEmpty else { return "let\n    Source = \"\"\nin\n    Source" }
        let lines = steps.map { "    " + MSyntax.identifier($0.name) + " = " + $0.expression }
        return "let\n" + lines.joined(separator: ",\n") + "\nin\n    " + MSyntax.identifier(result ?? steps[steps.count - 1].name)
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
        var s = steps(of: script)
        let prev = MSyntax.identifier(s.last?.name ?? "Source")
        s.append(MStep(name: uniqueStepName(base, in: script), expression: expression(prev)))
        return self.script(from: s)
    }

    /// Append a UI transformation as a new, uniquely named step.
    public static func appending(_ transform: Transform, to script: String) -> String {
        appendingStep(named: transform.stepName, expression: { transform.expression(previous: $0) }, to: script)
    }

    /// Rename a step and every later reference to it.
    public static func renamingStep(_ old: String, to new: String, in script: String) -> String {
        var s = steps(of: script)
        guard let i = s.firstIndex(where: { $0.name == old }), !s.contains(where: { $0.name == new }) else { return script }
        let result = resultName(of: script)
        s[i].name = new
        for j in s.indices where j != i { s[j].expression = replacingIdentifier(old, with: new, in: s[j].expression) }
        return self.script(from: s, result: result == old ? new : resultIfPresent(result, s))
    }

    /// Delete a step. Later references to it are re-pointed to its predecessor.
    public static func deletingStep(_ name: String, in script: String) -> String {
        var s = steps(of: script)
        guard let i = s.firstIndex(where: { $0.name == name }), s.count > 1 else { return script }
        let result = resultName(of: script)
        s.remove(at: i)
        if i > 0 {
            let pred = s[i - 1].name
            for j in i..<s.count { s[j].expression = replacingIdentifier(name, with: pred, in: s[j].expression) }
        }
        return self.script(from: s, result: result == name ? nil : resultIfPresent(result, s))
    }

    /// Move a step to a new position. In a linear chain, each step's reference to its predecessor follows the new order.
    public static func movingStep(_ name: String, to index: Int, in script: String) -> String {
        let old = steps(of: script)
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
        return self.script(from: s, result: wasLast ? nil : resultIfPresent(result, s))
    }

    /// Replace the expression of a step (formula-bar edit).
    public static func replacingStepExpression(_ name: String, with expression: String, in script: String) -> String {
        var s = steps(of: script)
        guard let i = s.firstIndex(where: { $0.name == name }) else { return script }
        let result = resultName(of: script)
        s[i].expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.script(from: s, result: resultIfPresent(result, s))
    }

    /// Insert a step after `name` (nil = at the start). The step that followed `name` and referenced it now references the new step.
    public static func insertingStep(_ step: MStep, after name: String?, in script: String) -> String {
        var s = steps(of: script)
        let result = resultName(of: script)
        var new = step
        var n = new.name, k = 1
        while s.contains(where: { $0.name == n }) { n = "\(new.name)\(k)"; k += 1 }
        new.name = n
        guard let name, let i = s.firstIndex(where: { $0.name == name }) else {
            s.insert(new, at: 0)
            return self.script(from: s, result: resultIfPresent(result, s))
        }
        s.insert(new, at: i + 1)
        if i + 2 < s.count { s[i + 2].expression = replacingIdentifier(name, with: new.name, in: s[i + 2].expression) }
        let wasLast = i + 2 == s.count && (result == nil || result == name)
        return self.script(from: s, result: wasLast ? nil : resultIfPresent(result, s))
    }

    /// A script that evaluates only steps `0...index` (for previewing an intermediate step).
    public static func truncating(_ script: String, upToStep index: Int) -> String {
        let s = steps(of: script)
        guard index >= 0, index < s.count - 1 else { return script }
        return self.script(from: Array(s.prefix(index + 1)))
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
