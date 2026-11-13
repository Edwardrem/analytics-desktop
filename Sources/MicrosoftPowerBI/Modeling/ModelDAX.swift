import Foundation
import FacetCore

/// Small, lexically careful helpers for generating and rewriting DAX text.
enum ModelDAX {
    /// `'Table name'` — always quoted, so any name is safe.
    static func table(_ name: String) -> String { "'" + name.replacingOccurrences(of: "'", with: "''") + "'" }
    /// `'Table'[Column]`.
    static func column(_ table: String, _ column: String) -> String { "\(self.table(table))[\(bracket(column))]" }
    /// `[Measure]`.
    static func measure(_ name: String) -> String { "[\(bracket(name))]" }
    /// A DAX string literal.
    static func string(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func bracket(_ name: String) -> String { name.replacingOccurrences(of: "]", with: "]]") }

    /// A DAX literal for a value (dates as `DATE(y, m, d)`).
    static func literal(_ v: Value) -> String {
        switch v {
        case .null: return "BLANK()"
        case .bool(let b): return b ? "TRUE()" : "FALSE()"
        case .int(let i): return String(i)
        case .double(let d): return number(d)
        case .string(let s): return string(s)
        case .date(let d):
            let c = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            let date = "DATE(\(c.year ?? 1900), \(c.month ?? 1), \(c.day ?? 1))"
            if (c.hour ?? 0) == 0, (c.minute ?? 0) == 0, (c.second ?? 0) == 0 { return date }
            return "\(date) + TIME(\(c.hour ?? 0), \(c.minute ?? 0), \(c.second ?? 0))"
        }
    }
    /// A number without exponent noise or a trailing ".0".
    static func number(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        var s = String(format: "%.10f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A field as DAX: measures as `[Name]`, columns as `'Table'[Name]`.
    static func reference(_ f: FieldRef) -> String { f.kind == .measure ? measure(f.name) : column(f.table, f.name) }
    /// A field as a scalar expression: measures as-is, columns wrapped in their aggregation (default SUM / COUNTA by type).
    static func aggregate(_ f: FieldRef, model: SemanticModel) -> String {
        if f.kind == .measure { return measure(f.name) }
        var agg = f.aggregation
        if agg == .none {
            let col = model.table(f.table)?.column(f.name)
            agg = col?.summarizeBy ?? .none
            if agg == .none { agg = (col?.dataType.isNumeric ?? false) ? .sum : .count }
        }
        let reference = column(f.table, f.name)
        switch agg {
        // First and Last take the column and an expression that marks a row as not blank.
        case .first: return "FIRSTNONBLANK(\(reference), 1)"
        case .last: return "LASTNONBLANK(\(reference), 1)"
        default: return "\(agg.daxFunction ?? "SUM")(\(reference))"
        }
    }

    /// Splits formula-bar text `Name = expression` at the first `=`.
    static func splitFormula(_ text: String) -> (name: String, expression: String)? {
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let name = text[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
        let expr = text[text.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, expr)
    }

    /// Model names compare case-insensitively.
    static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// Rewrites table names and bracketed names in an expression, leaving strings, comments and
    /// function names untouched.
    /// - Parameters:
    ///   - mapTable: new name for a referenced table, or nil to keep it.
    ///   - mapBracket: new name for `[name]`, given the table qualifier before it (nil when unqualified).
    static func rewrite(_ expr: String, mapTable: (String) -> String?, mapBracket: (_ table: String?, _ name: String) -> String?) -> String {
        let s = Array(expr)
        let n = s.count
        var out = ""
        out.reserveCapacity(expr.count + 16)
        var i = 0
        var lastTable: String?
        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }
        while i < n {
            let c = s[i]
            if c == "\"" {
                var j = i + 1
                while j < n { if s[j] == "\"" { if j + 1 < n, s[j + 1] == "\"" { j += 2; continue }; break }; j += 1 }
                j = min(n, j + 1)
                out += String(s[i..<j]); i = j; lastTable = nil
            } else if (c == "/" && i + 1 < n && s[i + 1] == "/") || (c == "-" && i + 1 < n && s[i + 1] == "-") {
                var j = i; while j < n, s[j] != "\n" { j += 1 }
                out += String(s[i..<j]); i = j
            } else if c == "/", i + 1 < n, s[i + 1] == "*" {
                var j = i + 2; while j < n, !(s[j] == "*" && j + 1 < n && s[j + 1] == "/") { j += 1 }
                j = min(n, j + 2)
                out += String(s[i..<j]); i = j
            } else if c == "'" {
                var j = i + 1
                var name = ""
                while j < n { if s[j] == "'" { if j + 1 < n, s[j + 1] == "'" { name.append("'"); j += 2; continue }; break }; name.append(s[j]); j += 1 }
                j = min(n, j + 1)
                out += table(mapTable(name) ?? name); i = j; lastTable = name
            } else if c == "[" {
                var j = i + 1
                var name = ""
                while j < n { if s[j] == "]" { if j + 1 < n, s[j + 1] == "]" { name.append("]"); j += 2; continue }; break }; name.append(s[j]); j += 1 }
                j = min(n, j + 1)
                out += "[" + bracket(mapBracket(lastTable, name) ?? name) + "]"; i = j; lastTable = nil
            } else if isIdentStart(c) {
                var j = i; while j < n, isIdent(s[j]) { j += 1 }
                let word = String(s[i..<j])
                var k = j; while k < n, s[k] == " " { k += 1 }
                if k < n, s[k] == "(" { out += word; lastTable = nil }
                else if let mapped = mapTable(word) { out += table(mapped); lastTable = word }
                else { out += word; lastTable = word }
                i = j
            } else {
                out.append(c)
                if !c.isWhitespace { lastTable = nil }
                i += 1
            }
        }
        return out
    }
}

