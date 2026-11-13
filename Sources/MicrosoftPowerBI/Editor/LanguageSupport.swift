import SwiftUI
import FacetCore

/// A coloured span of source text.
struct CodeToken {
    enum Kind { case keyword, function, string, number, comment, identifier, field, op, type, plain }
    var range: NSRange
    var kind: Kind
}

struct CodeCompletion: Hashable {
    enum Kind { case function, keyword, table, column, measure, snippet }
    var text: String
    var kind: Kind
    var detail: String = ""
}

struct FunctionDoc: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var category: String
    var signature: String
    var summary: String
}

/// Language services for a code editor. The defaults are simple lexical fallbacks; the engine
/// bridge replaces them with the real tokenizers, catalogs and formatters.
struct LanguageSupport {
    var name: String
    var tokens: (String) -> [CodeToken]
    /// Completions for the partial word at the cursor, given the model for field names.
    var completions: (_ prefix: String, _ model: SemanticModel) -> [CodeCompletion]
    var format: (String) -> String = { $0 }
    var functions: [FunctionDoc] = []

    @MainActor static var dax = LanguageSupport.lexical(name: "DAX", keywords: ["VAR", "RETURN", "DEFINE", "MEASURE", "EVALUATE", "ORDER", "BY", "ASC", "DESC", "START", "AT", "IN", "NOT", "TRUE", "FALSE", "COLUMN", "TABLE", "FUNCTION"],
                                                lineComments: ["//", "--"], fieldsInBrackets: true, caseInsensitive: true)
    @MainActor static var m = LanguageSupport.lexical(name: "M", keywords: ["let", "in", "each", "if", "then", "else", "try", "otherwise", "error", "and", "or", "not", "as", "is", "type", "meta", "section", "shared", "true", "false", "null"],
                                              lineComments: ["//"], fieldsInBrackets: false, caseInsensitive: false)
    @MainActor static var tmdl = LanguageSupport.lexical(name: "TMDL", keywords: ["model", "table", "column", "measure", "partition", "relationship", "role", "hierarchy", "level", "expression", "annotation", "calculationGroup", "calculationItem", "perspective", "cultureInfo", "function", "createOrReplace", "ref", "database"],
                                                 lineComments: ["//", "///"], fieldsInBrackets: false, caseInsensitive: false)
    @MainActor static var python = LanguageSupport.lexical(name: "Python", keywords: ["import", "from", "def", "return", "for", "in", "if", "else", "elif", "while", "as", "with", "class", "None", "True", "False", "lambda", "and", "or", "not"],
                                                   lineComments: ["#"], fieldsInBrackets: false, caseInsensitive: false)

    /// A regex-free lexical highlighter good enough for any C-like expression language.
    static func lexical(name: String, keywords: [String], lineComments: [String], fieldsInBrackets: Bool, caseInsensitive: Bool) -> LanguageSupport {
        let keywordSet = Set(caseInsensitive ? keywords.map { $0.uppercased() } : keywords)
        return LanguageSupport(name: name, tokens: { text in
            var out: [CodeToken] = []
            let s = Array(text.utf16)
            let n = s.count
            var i = 0
            func ch(_ k: Int) -> UInt16 { k < n ? s[k] : 0 }
            func isIdent(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 46 || c > 127 }
            func starts(_ p: String, at k: Int) -> Bool {
                let u = Array(p.utf16)
                guard k + u.count <= n else { return false }
                for j in 0..<u.count where s[k + j] != u[j] { return false }
                return true
            }
            while i < n {
                let c = s[i]
                if lineComments.contains(where: { starts($0, at: i) }) {
                    var j = i; while j < n, s[j] != 10 { j += 1 }
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .comment)); i = j
                } else if c == 47, ch(i + 1) == 42 { // /* */
                    var j = i + 2; while j < n, !(s[j] == 42 && ch(j + 1) == 47) { j += 1 }
                    j = min(n, j + 2)
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .comment)); i = j
                } else if c == 34 { // "string" with "" escapes
                    var j = i + 1
                    while j < n { if s[j] == 34 { if ch(j + 1) == 34 { j += 2; continue }; break }; j += 1 }
                    j = min(n, j + 1)
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .string)); i = j
                } else if c == 39, fieldsInBrackets { // 'Table name'
                    var j = i + 1; while j < n, s[j] != 39, s[j] != 10 { j += 1 }
                    j = min(n, j + 1)
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .type)); i = j
                } else if c == 91, fieldsInBrackets { // [Field]
                    var j = i + 1; while j < n, s[j] != 93, s[j] != 10 { j += 1 }
                    j = min(n, j + 1)
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .field)); i = j
                } else if c >= 48 && c <= 57 {
                    var j = i; while j < n, (s[j] >= 48 && s[j] <= 57) || s[j] == 46 || s[j] == 101 || s[j] == 69 { j += 1 }
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: .number)); i = j
                } else if isIdent(c), c != 46 {
                    var j = i; while j < n, isIdent(s[j]) { j += 1 }
                    let word = String(utf16CodeUnits: Array(s[i..<j]), count: j - i)
                    var k = j; while k < n, s[k] == 32 { k += 1 }
                    let isKeyword = keywordSet.contains(caseInsensitive ? word.uppercased() : word)
                    let kind: CodeToken.Kind = isKeyword ? .keyword : (ch(k) == 40 ? .function : .identifier)
                    out.append(CodeToken(range: NSRange(location: i, length: j - i), kind: kind)); i = j
                } else { i += 1 }
            }
            return out
        }, completions: { prefix, model in
            let p = prefix.lowercased()
            guard !p.isEmpty else { return [] }
            var out = keywords.filter { $0.lowercased().hasPrefix(p) }.map { CodeCompletion(text: $0, kind: .keyword) }
            if fieldsInBrackets {
                for t in model.tables {
                    if t.name.lowercased().hasPrefix(p) { out.append(CodeCompletion(text: t.name.contains(" ") ? "'\(t.name)'" : t.name, kind: .table)) }
                    for m in t.measures where m.name.lowercased().hasPrefix(p) { out.append(CodeCompletion(text: "[\(m.name)]", kind: .measure)) }
                }
            }
            return out
        })
    }
}

extension CodeToken.Kind {
    /// Syntax colours: system colours so they adapt to light, dark and increased contrast.
    var color: NSColor {
        switch self {
        case .keyword: return .systemPink
        case .function: return .systemBlue
        case .string: return .systemRed
        case .number: return .systemOrange
        case .comment: return .secondaryLabelColor
        case .field: return .systemTeal
        case .type: return .systemPurple
        case .identifier, .op, .plain: return .labelColor
        }
    }
}
