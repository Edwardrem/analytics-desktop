import Foundation
import FacetCore

/// A `MEASURE` or `FUNCTION` definition found in a query's `DEFINE` block.
struct DAXDefinition: Equatable {
    enum Kind { case measure, function }
    var kind: Kind
    /// Home table for measures (as written); empty for functions.
    var table: String
    var name: String
    /// Normalized expression (function body after `=>` for functions).
    var expression: String
    /// Text of the `///` lines directly above the definition, if any.
    var description: String?
    var parameters: [FunctionParameter] = []
    /// UTF-16 range of the definition, including its `///` lines.
    var range: Range<Int>
    /// 1-based line of the `MEASURE` / `FUNCTION` keyword.
    var line: Int
}

/// Tolerant parser for the `DEFINE` section of a DAX query. It never throws: anything it cannot
/// understand is skipped, so half-typed queries still yield the definitions that are complete.
enum DAXDefineParser {
    private static let terminators: Set<String> = ["MEASURE", "TABLE", "COLUMN", "FUNCTION", "EVALUATE", "DEFINE"]
    private static let operators: Set<String> = ["=", "+", "-", "*", "/", "&", "|", "<", ">", ",", "(", "{", "^"]

    static func definitions(in text: String) -> [DAXDefinition] {
        let tokens = DAXLexer.tokens(text)
        let utf16 = Array(text.utf16)
        func slice(_ a: Int, _ b: Int) -> String { a < b ? String(decoding: utf16[a..<b], as: UTF16.self) : "" }
        var out: [DAXDefinition] = []
        var i = 0
        var inDefine = false
        var depth = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .comment { i += 1; continue }
            if t.kind == .symbol {
                if t.text == "(" || t.text == "{" { depth += 1 } else if t.text == ")" || t.text == "}" { depth = max(0, depth - 1) }
                i += 1; continue
            }
            guard t.kind == .word, depth == 0 else { i += 1; continue }
            if t.isWord("DEFINE") { inDefine = true; i += 1; continue }
            if t.isWord("EVALUATE") { inDefine = false; i += 1; continue }
            guard inDefine else { i += 1; continue }

            if t.isWord("MEASURE") {
                let sig = significant(tokens, from: i + 1, count: 3)
                // MEASURE 'Table'[Name] =   or   MEASURE [Name] =
                var table = "", nameTok: DAXToken?, eq: Int?
                if sig.count == 3, tokens[sig[0]].kind == .quotedName || tokens[sig[0]].kind == .word,
                   tokens[sig[1]].kind == .bracket, tokens[sig[2]].isSymbol("=") {
                    table = tokens[sig[0]].text; nameTok = tokens[sig[1]]; eq = sig[2]
                } else if sig.count >= 2, tokens[sig[0]].kind == .bracket, tokens[sig[1]].isSymbol("=") {
                    nameTok = tokens[sig[0]]; eq = sig[1]
                }
                guard let nameTok, let eq else { i = bodyEnd(tokens, from: i + 1); continue }
                let end = bodyEnd(tokens, from: eq + 1)
                let stop = end < tokens.count ? tokens[end].start : utf16.count
                let expr = DAXText.normalize(strippingTrailingDocLines(slice(tokens[eq].end, stop)))
                let doc = docComment(tokens, before: i, source: utf16)
                if !expr.isEmpty, !nameTok.text.isEmpty {
                    out.append(DAXDefinition(kind: .measure, table: table, name: nameTok.text, expression: expr, description: doc.text,
                                             range: (doc.start ?? t.start)..<trimmedEnd(utf16, from: tokens[eq].end, to: stop, expr: expr),
                                             line: line(of: t.start, in: utf16)))
                }
                i = end; continue
            }
            if t.isWord("FUNCTION") {
                let sig = significant(tokens, from: i + 1, count: 2)
                guard sig.count == 2, tokens[sig[0]].kind == .word, tokens[sig[1]].isSymbol("=") else { i = bodyEnd(tokens, from: i + 1); continue }
                let end = bodyEnd(tokens, from: sig[1] + 1)
                let stop = end < tokens.count ? tokens[end].start : utf16.count
                let body = strippingTrailingDocLines(slice(tokens[sig[1]].end, stop))
                let (params, expr) = functionParts(body)
                let doc = docComment(tokens, before: i, source: utf16)
                if !expr.isEmpty {
                    out.append(DAXDefinition(kind: .function, table: "", name: tokens[sig[0]].text, expression: expr, description: doc.text,
                                             parameters: params, range: (doc.start ?? t.start)..<stop, line: line(of: t.start, in: utf16)))
                }
                i = end; continue
            }
            if t.isWord("VAR") || t.isWord("TABLE") || t.isWord("COLUMN") { i = bodyEnd(tokens, from: i + 1); continue }
            i += 1
        }
        return out
    }

    // MARK: Pieces

    private static func significant(_ tokens: [DAXToken], from: Int, count: Int) -> [Int] {
        var out: [Int] = []
        var j = from
        while j < tokens.count, out.count < count {
            if tokens[j].kind != .comment { out.append(j) }
            j += 1
        }
        return out
    }

    /// Index of the token that ends a definition body starting at `from`: the next definition keyword
    /// or `EVALUATE` outside brackets. A `VAR` only ends the body when the expression so far is complete,
    /// so `MEASURE T[M] = VAR x = 1 RETURN x` stays in one piece.
    private static func bodyEnd(_ tokens: [DAXToken], from: Int) -> Int {
        var depth = 0, openVars = 0
        var nonEmpty = false, afterOperator = true
        var j = from
        while j < tokens.count {
            let t = tokens[j]
            switch t.kind {
            case .comment: break
            case .symbol:
                if t.text == "(" || t.text == "{" { depth += 1 } else if t.text == ")" || t.text == "}" { depth = max(0, depth - 1) }
                afterOperator = operators.contains(t.text); nonEmpty = true
            case .word where depth == 0:
                let up = t.text.uppercased()
                if terminators.contains(up) { return j }
                if up == "VAR" {
                    if nonEmpty, openVars == 0, !afterOperator { return j }
                    openVars += 1; afterOperator = true; nonEmpty = true
                } else if up == "RETURN" {
                    openVars = 0; afterOperator = true; nonEmpty = true
                } else {
                    afterOperator = up == "IN" || up == "NOT"; nonEmpty = true
                }
            default:
                afterOperator = false; nonEmpty = true
            }
            j += 1
        }
        return tokens.count
    }

    /// The run of `///` lines directly above token `index` (each on its own line, no blank lines between).
    private static func docComment(_ tokens: [DAXToken], before index: Int, source: [UInt16]) -> (text: String?, start: Int?) {
        var lines: [String] = []
        var start: Int?
        var nextStart = tokens[index].start
        var j = index - 1
        while j >= 0, tokens[j].kind == .comment, tokens[j].text.hasPrefix("///") {
            let gap = source[tokens[j].end..<nextStart]
            guard gap.filter({ $0 == 10 }).count == 1, gap.allSatisfy({ $0 == 10 || $0 == 13 || $0 == 32 || $0 == 9 }) else { break }
            // The comment must start its line.
            var k = tokens[j].start - 1
            var ownLine = true
            while k >= 0, source[k] != 10 { if source[k] != 32 && source[k] != 9 { ownLine = false; break }; k -= 1 }
            guard ownLine else { break }
            var body = String(tokens[j].text.dropFirst(3))
            if body.hasPrefix(" ") { body.removeFirst() }
            lines.insert(body.trimmingCharacters(in: .whitespaces), at: 0)
            start = tokens[j].start; nextStart = tokens[j].start
            j -= 1
        }
        return (lines.isEmpty ? nil : lines.joined(separator: "\n"), start)
    }

    /// Drops trailing `///` lines: they describe the next definition, not this one.
    private static func strippingTrailingDocLines(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        while let last = lines.last {
            let t = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("///") { lines.removeLast() } else { break }
        }
        return lines.joined(separator: "\n")
    }

    private static func trimmedEnd(_ source: [UInt16], from: Int, to: Int, expr: String) -> Int {
        // End of the last non-whitespace character of the body, before any trailing doc lines.
        let body = strippingTrailingDocLines(String(decoding: source[from..<to], as: UTF16.self))
        var end = from + body.utf16.count
        while end > from, [32, 9, 10, 13].contains(source[end - 1]) { end -= 1 }
        return max(end, from)
    }

    private static func line(of offset: Int, in source: [UInt16]) -> Int {
        var n = 1
        for k in 0..<min(offset, source.count) where source[k] == 10 { n += 1 }
        return n
    }

    /// Splits `(a : type mode, b) => body` into parameters and body. Without that shape the whole text is the body.
    static func functionParts(_ body: String) -> ([FunctionParameter], String) {
        let tokens = DAXLexer.tokens(body).filter { $0.kind != .comment }
        guard let first = tokens.first, first.isSymbol("(") else { return ([], DAXText.normalize(body)) }
        var depth = 0
        var close: Int?
        for (i, t) in tokens.enumerated() where t.kind == .symbol {
            if t.text == "(" { depth += 1 } else if t.text == ")" { depth -= 1; if depth == 0 { close = i; break } }
        }
        guard let close, close + 2 < tokens.count, tokens[close + 1].isSymbol("="), tokens[close + 2].isSymbol(">"),
              tokens[close + 1].end == tokens[close + 2].start else { return ([], DAXText.normalize(body)) }
        var params: [FunctionParameter] = []
        var group: [DAXToken] = []
        func flush() {
            guard let nameTok = group.first, nameTok.kind == .word else { group = []; return }
            var p = FunctionParameter(name: nameTok.text)
            var words = group.dropFirst().filter { $0.kind == .word }.map { $0.text.lowercased() }
            if let last = words.last, last == "val" || last == "expr" { p.mode = last; words.removeLast() }
            if !words.isEmpty { p.type = words.joined(separator: " ") }
            params.append(p); group = []
        }
        for t in tokens[1..<close] {
            if t.isSymbol(",") { flush() } else { group.append(t) }
        }
        flush()
        let utf16 = Array(body.utf16)
        let rest = String(decoding: utf16[tokens[close + 2].end...], as: UTF16.self)
        return (params, DAXText.normalize(rest))
    }

    static func signature(_ parameters: [FunctionParameter]) -> String {
        "(" + parameters.map { p in
            var s = p.name
            if p.type != "anyval" || p.mode != "val" { s += " : \(p.type) \(p.mode)" }
            return s
        }.joined(separator: ", ") + ")"
    }
}

// MARK: - Model changes

/// One pending "update model" action derived from a definition that differs from the model.
struct DAXModelChange: Identifiable, Equatable {
    enum Action { case addMeasure, overwriteMeasure, addFunction, overwriteFunction }
    var action: Action
    var definition: DAXDefinition
    /// Table that will hold the measure (the existing home table when overwriting).
    var table: String
    /// Model-side text before the change (empty when adding) and the text after it, for the diff.
    var before: String
    var after: String

    var id: String { "\(definition.kind)|\(definition.name.lowercased())" }
    var isAddition: Bool { action == .addMeasure || action == .addFunction }
    var objectName: String {
        definition.kind == .measure ? DAXQueryBuilder.columnRef(table, definition.name) : definition.name
    }
    var title: String {
        switch action {
        case .addMeasure: return "Update model: add new measure"
        case .overwriteMeasure: return "Update model: overwrite measure"
        case .addFunction: return "Update model: add new function"
        case .overwriteFunction: return "Update model: overwrite function"
        }
    }
}

enum DAXModelUpdater {
    private static func text(description: String, body: String) -> String {
        let doc = description.components(separatedBy: "\n").filter { !$0.isEmpty }.map { "/// " + $0 }
        return (doc + [body]).joined(separator: "\n")
    }

    /// Definitions in `text` that would change the model. Measures whose table doesn't exist are left out.
    static func changes(in text: String, model: SemanticModel) -> [DAXModelChange] {
        var byID: [String: DAXModelChange] = [:]
        var order: [String] = []
        for def in DAXDefineParser.definitions(in: text) {
            var change: DAXModelChange?
            switch def.kind {
            case .measure:
                if let hit = model.measure(def.name) {
                    let newDescription = def.description ?? hit.measure.description
                    if DAXText.normalize(hit.measure.expression) != def.expression || newDescription != hit.measure.description {
                        change = DAXModelChange(action: .overwriteMeasure, definition: def, table: hit.table.name,
                                                before: self.text(description: hit.measure.description, body: DAXText.normalize(hit.measure.expression)),
                                                after: self.text(description: newDescription, body: def.expression))
                    }
                } else if let table = model.table(def.table) {
                    change = DAXModelChange(action: .addMeasure, definition: def, table: table.name, before: "",
                                            after: self.text(description: def.description ?? "", body: def.expression))
                }
            case .function:
                let newBody = DAXDefineParser.signature(def.parameters) + " =>\n" + def.expression
                if let f = model.functions.first(where: { $0.name.caseInsensitiveCompare(def.name) == .orderedSame }) {
                    let newDescription = def.description ?? f.description
                    if DAXText.normalize(f.expression) != def.expression || f.parameters != def.parameters || newDescription != f.description {
                        change = DAXModelChange(action: .overwriteFunction, definition: def, table: "",
                                                before: self.text(description: f.description, body: DAXDefineParser.signature(f.parameters) + " =>\n" + DAXText.normalize(f.expression)),
                                                after: self.text(description: newDescription, body: newBody))
                    }
                } else {
                    change = DAXModelChange(action: .addFunction, definition: def, table: "", before: "",
                                            after: self.text(description: def.description ?? "", body: newBody))
                }
            }
            let key = "\(def.kind)|\(def.name.lowercased())"
            if let change {
                if byID[key] == nil { order.append(key) }
                byID[key] = change // a later definition of the same object wins
            } else if byID[key] != nil {
                byID[key] = nil; order.removeAll { $0 == key }
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Writes the changes into the model. Existing measures keep their id, format and folder.
    static func apply(_ changes: [DAXModelChange], to model: inout SemanticModel) {
        for c in changes {
            let def = c.definition
            switch def.kind {
            case .measure:
                var done = false
                for t in model.tables.indices {
                    if let m = model.tables[t].measures.firstIndex(where: { $0.name.caseInsensitiveCompare(def.name) == .orderedSame }) {
                        model.tables[t].measures[m].expression = def.expression
                        if let d = def.description { model.tables[t].measures[m].description = d }
                        done = true; break
                    }
                }
                if !done, let t = model.tableIndex(c.table) {
                    var m = Measure(name: def.name, expression: def.expression)
                    m.description = def.description ?? ""
                    model.tables[t].measures.append(m)
                }
            case .function:
                if let i = model.functions.firstIndex(where: { $0.name.caseInsensitiveCompare(def.name) == .orderedSame }) {
                    model.functions[i].expression = def.expression
                    model.functions[i].parameters = def.parameters
                    if let d = def.description { model.functions[i].description = d }
                } else {
                    var f = UserFunction(name: def.name, parameters: def.parameters, expression: def.expression)
                    f.description = def.description ?? ""
                    model.functions.append(f)
                }
            }
        }
    }
}

// MARK: - Line diff

/// A plain line-by-line diff (longest common subsequence) for the update-model confirmation.
enum DAXLineDiff {
    enum Kind { case same, added, removed }
    struct Line: Identifiable, Equatable {
        var id: Int
        var kind: Kind
        var text: String
    }

    static func diff(old: String, new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        func add(_ k: Kind, _ s: String) { out.append(Line(id: out.count, kind: k, text: s)) }
        while i < n, j < m {
            if a[i] == b[j] { add(.same, a[i]); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { add(.removed, a[i]); i += 1 }
            else { add(.added, b[j]); j += 1 }
        }
        while i < n { add(.removed, a[i]); i += 1 }
        while j < m { add(.added, b[j]); j += 1 }
        return out
    }
}
