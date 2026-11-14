import Foundation
import FacetCore

/// A run of tokens of one step's M text (no whitespace or comments), with the source it came from.
/// The step recogniser takes calls apart with it: arguments, list items, record fields, `each` bodies, literals.
struct StepFragment {
    let tokens: ArraySlice<MToken>
    let source: [UInt16]

    /// Tokenises M text; nil when it does not lex cleanly or is empty.
    init?(_ text: String) {
        let (all, diagnostics) = MLexer.tokenize(text)
        let tokens = all.filter { $0.kind != .eof }
        guard diagnostics.isEmpty, !tokens.isEmpty else { return nil }
        self.tokens = tokens[...]
        source = Array(text.utf16)
    }
    private init(tokens: ArraySlice<MToken>, source: [UInt16]) { self.tokens = tokens; self.source = source }

    func sub(_ range: Range<Int>) -> StepFragment { StepFragment(tokens: tokens[range], source: source) }

    /// The source text the tokens span.
    var text: String {
        guard let a = tokens.first, let b = tokens.last else { return "" }
        let range = a.location..<(b.location + b.length)
        return String(utf16CodeUnits: Array(source[range]), count: range.count)
    }

    private func isPunct(_ i: Int, _ s: String) -> Bool { tokens[i].kind == .punctuation && tokens[i].text == s }

    /// Index of the bracket that closes the one at `open`.
    func closing(_ open: Int) -> Int? {
        var depth = 0
        for i in open..<tokens.endIndex where tokens[i].kind == .punctuation {
            switch tokens[i].text {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    /// The fragment split at commas (or at a keyword such as `and`) outside brackets; empty for an empty range.
    func split(_ range: Range<Int>, at separator: String = ",") -> [StepFragment]? {
        guard !range.isEmpty else { return [] }
        var parts: [StepFragment] = [], start = range.lowerBound, i = range.lowerBound
        while i < range.upperBound {
            let t = tokens[i]
            if t.kind == .punctuation, "([{".contains(t.text) {
                guard let close = closing(i), close < range.upperBound else { return nil }
                i = close + 1
                continue
            }
            if t.kind == .punctuation || t.kind == .keyword, t.text == separator {
                guard i > start else { return nil }
                parts.append(sub(start..<i))
                start = i + 1
            }
            i += 1
        }
        guard start < range.upperBound else { return nil }
        parts.append(sub(start..<range.upperBound))
        return parts
    }

    // MARK: Shapes

    /// `Name(arg, …)` spanning the whole fragment.
    var call: (name: String, args: [StepFragment])? {
        let s = tokens.startIndex
        guard tokens.count >= 3, tokens[s].kind == .identifier || tokens[s].kind == .quotedIdentifier, isPunct(s + 1, "("),
              closing(s + 1) == tokens.endIndex - 1, let args = split((s + 2)..<(tokens.endIndex - 1)) else { return nil }
        return (tokens[s].value, args)
    }
    /// `{a, b, …}` spanning the whole fragment.
    var items: [StepFragment]? {
        let s = tokens.startIndex
        guard tokens.count >= 2, isPunct(s, "{"), closing(s) == tokens.endIndex - 1 else { return nil }
        return split((s + 1)..<(tokens.endIndex - 1))
    }
    /// `[name = value, …]` spanning the whole fragment.
    var fields: [(name: String, value: StepFragment)]? {
        let s = tokens.startIndex
        guard tokens.count >= 2, isPunct(s, "["), closing(s) == tokens.endIndex - 1,
              let parts = split((s + 1)..<(tokens.endIndex - 1)) else { return nil }
        var out: [(String, StepFragment)] = []
        for p in parts {
            let a = p.tokens.startIndex
            guard p.tokens.count >= 3, p.tokens[a].kind == .identifier || p.tokens[a].kind == .quotedIdentifier,
                  p.tokens[a + 1].kind == .operator, p.tokens[a + 1].text == "=" else { return nil }
            out.append((p.tokens[a].value, p.sub((a + 2)..<p.tokens.endIndex)))
        }
        return out
    }
    /// The body of `each body`.
    var eachBody: StepFragment? {
        let s = tokens.startIndex
        guard tokens.count >= 2, tokens[s].kind == .keyword, tokens[s].text == "each" else { return nil }
        return sub((s + 1)..<tokens.endIndex)
    }
    /// A single identifier: its decoded name and its source text (`#"Changed Type"`).
    var identifier: (name: String, source: String)? {
        guard tokens.count == 1, let t = tokens.first, t.kind == .identifier || t.kind == .quotedIdentifier else { return nil }
        return (t.value, t.text)
    }
    var textValue: String? {
        guard tokens.count == 1, let t = tokens.first, t.kind == .text else { return nil }
        return t.value
    }
    var numberValue: Double? {
        let s = tokens.startIndex
        if tokens.count == 1, tokens[s].kind == .number { return Double(tokens[s].text) }
        if tokens.count == 2, tokens[s].kind == .operator, tokens[s].text == "-", tokens[s + 1].kind == .number {
            return Double(tokens[s + 1].text).map { -$0 }
        }
        return nil
    }
    var intValue: Int? {
        guard let d = numberValue, d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
    var boolValue: Bool? {
        guard tokens.count == 1, let t = tokens.first, t.kind == .keyword else { return nil }
        return t.text == "true" ? true : t.text == "false" ? false : nil
    }
    var texts: [String]? { items.flatMap { list in list.compactMap(\.textValue).count == list.count ? list.compactMap(\.textValue) : nil } }
    /// A text list, or a single text literal (both are accepted where M takes column names).
    var names: [String]? { texts ?? textValue.map { [$0] } }
    /// `[Column]` (the implicit `_` field access) spanning the whole fragment.
    var fieldName: String? {
        guard let (name, end) = Self.fieldName(tokens, at: tokens.startIndex), end == tokens.endIndex - 1 else { return nil }
        return name
    }
    /// `target[Column]`: the target's identifier source text and the column.
    var fieldAccess: (target: String, column: String)? {
        let s = tokens.startIndex
        guard tokens.count >= 3, let target = sub(s..<(s + 1)).identifier,
              let (name, end) = Self.fieldName(tokens, at: s + 1), end == tokens.endIndex - 1 else { return nil }
        return (target.source, name)
    }

    /// Columns read through `[Column]` anywhere in the fragment, in order, without duplicates.
    var columnReferences: [String] {
        var out: [String] = [], i = tokens.startIndex
        while i < tokens.endIndex {
            if let (name, end) = Self.fieldName(tokens, at: i) {
                if !out.contains(name) { out.append(name) }
                i = end + 1
            } else { i += 1 }
        }
        return out
    }
    /// Numbers in the fragment (each also negated, so `- 3` and `-3` are both found).
    var numbers: [Double] {
        var out: [Double] = []
        for t in tokens where t.kind == .number {
            guard let d = Double(t.text) else { continue }
            for v in [d, -d] where !out.contains(v) { out.append(v) }
        }
        return out
    }
    var textLiterals: [String] {
        var out: [String] = []
        for t in tokens where t.kind == .text && !out.contains(t.value) { out.append(t.value) }
        return out
    }

    /// `[name]` starting at `i`: a quoted identifier, or a generalized identifier of words. Returns the name and the `]` index.
    static func fieldName(_ tokens: ArraySlice<MToken>, at i: Int) -> (String, Int)? {
        guard i < tokens.endIndex, tokens[i].kind == .punctuation, tokens[i].text == "[" else { return nil }
        var words: [String] = [], j = i + 1
        while j < tokens.endIndex {
            let t = tokens[j]
            if t.kind == .punctuation, t.text == "]" {
                guard !words.isEmpty else { return nil }
                return (words.joined(separator: " "), j)
            }
            switch t.kind {
            case .quotedIdentifier:
                guard words.isEmpty, j + 1 < tokens.endIndex, tokens[j + 1].text == "]" else { return nil }
                words = [t.value]
            case .identifier, .keyword, .number: words.append(t.text)
            default: return nil
            }
            j += 1
        }
        return nil
    }

    // MARK: Values

    /// A literal value (text, number, logical, null, `#date(…)`, `#datetime(…)`, `#time(…)`, `#duration(…)`) and the
    /// data type its literal form implies.
    var literal: (value: Value, type: DataType)? {
        let s = tokens.startIndex
        let t = tokens[s]
        var isLiteral = false
        if tokens.count == 1 {
            isLiteral = t.kind == .text || t.kind == .number || (t.kind == .keyword && ["null", "true", "false", "#nan", "#infinity"].contains(t.text))
        } else if numberValue != nil {
            isLiteral = true
        } else if t.kind == .keyword, ["#date", "#datetime", "#time", "#duration"].contains(t.text), isPunct(s + 1, "("),
                  closing(s + 1) == tokens.endIndex - 1 {
            isLiteral = tokens[(s + 2)..<(tokens.endIndex - 1)].allSatisfy { tok in
                tok.kind == .number || (tok.kind == .punctuation && tok.text == ",") || (tok.kind == .operator && tok.text == "-")
            }
        }
        guard isLiteral, let v = try? MInterpreter().evaluate(text) else { return nil }
        switch v {
        case .null: return (.null, .any)
        case .logical(let b): return (.bool(b), .any)
        case .number: return (v.toValue(), .any)
        case .text(let s): return (.string(s), .any)
        case .date(let d): return (.date(d), .date)
        case .datetime(let d): return (.date(d), .dateTime)
        case .time: return (v.toValue(), .time)
        case .duration: return (v.toValue(), .duration)
        default: return nil
        }
    }
    /// Literal values anywhere in the fragment, in order.
    var literals: [(value: Value, type: DataType)] {
        var out: [(Value, DataType)] = [], i = tokens.startIndex
        while i < tokens.endIndex {
            let t = tokens[i]
            var end = i
            if t.kind == .keyword, ["#date", "#datetime", "#time", "#duration"].contains(t.text), i + 1 < tokens.endIndex,
               let close = closing(i + 1) { end = close }
            else if t.kind == .operator, t.text == "-", i + 1 < tokens.endIndex, tokens[i + 1].kind == .number { end = i + 1 }
            if let l = sub(i..<(end + 1)).literal { out.append(l); i = end + 1 } else { i += 1 }
        }
        return out
    }
    /// A type expression (`Int64.Type`, `type nullable number`, `Currency.Type`) as a model data type.
    var dataType: DataType? {
        let s = tokens.startIndex
        let isType = (tokens.count == 1 && tokens[s].kind == .identifier && tokens[s].text.hasSuffix(".Type"))
            || (tokens[s].kind == .keyword && tokens[s].text == "type")
        guard isType, case .type(let t)? = try? MInterpreter().evaluate(text) else { return nil }
        return t.dataType
    }

    // MARK: Comparison

    /// Tokens reduced to what matters for equality: identifiers by name (quoted or not), text and numbers by value,
    /// `[field]` by field name, and `type nullable x` as `type x`.
    var key: [String] {
        var out: [String] = [], i = tokens.startIndex
        while i < tokens.endIndex {
            let t = tokens[i]
            if let (name, end) = Self.fieldName(tokens, at: i) { out.append("f:" + name); i = end + 1; continue }
            if t.kind == .identifier, t.text == "nullable", out.last == "k:type" { i += 1; continue }
            switch t.kind {
            case .identifier, .quotedIdentifier: out.append("i:" + t.value)
            case .text: out.append("t:" + t.value)
            case .number: out.append("n:" + (Double(t.text).map { "\($0)" } ?? t.text))
            default: out.append("k:" + t.text)
            }
            i += 1
        }
        return out
    }
    static func key(_ text: String) -> [String]? { StepFragment(text)?.key }
}
