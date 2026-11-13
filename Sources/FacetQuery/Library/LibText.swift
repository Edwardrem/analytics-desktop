import Foundation
import FacetCore

/// Text helpers working on `Character` arrays (M text positions count characters).
enum MText {
    /// Start offsets of non-overlapping occurrences of `needle` in `hay`.
    static func occurrences(of needle: [Character], in hay: [Character], ignoreCase: Bool = false) -> [Int] {
        guard !needle.isEmpty, needle.count <= hay.count else { return [] }
        let h = ignoreCase ? hay.map { Character($0.lowercased()) } : hay
        let n = ignoreCase ? needle.map { Character($0.lowercased()) } : needle
        var out: [Int] = [], i = 0
        while i + n.count <= h.count {
            if h[i] == n[0], Array(h[i..<(i + n.count)]) == n { out.append(i); i += n.count } else { i += 1 }
        }
        return out
    }
    /// Interpret a delimiter index argument: a number (from the start) or `{n, RelativePosition.FromEnd}`.
    static func pick(_ hits: [Int], _ index: MValue) throws -> Int? {
        var n = 0, fromEnd = false
        switch index {
        case .null: break
        case .number(let d): n = Int(d)
        case .list(let l) where l.count == 2:
            n = Int(try l[0].forced().numberValue ?? 0)
            fromEnd = try l[1].forced().numberValue == 1
        default: throw MError.typeMismatch(expected: "number", got: index)
        }
        guard n >= 0, n < hits.count else { return nil }
        return fromEnd ? hits[hits.count - 1 - n] : hits[n]
    }
    /// The characters named by a "characters" argument: a text (each character) or a list of texts.
    static func charSet(_ v: MValue) throws -> Set<Character> {
        switch v {
        case .text(let s): return Set(s)
        case .list(let l): return Set(try l.flatMap { Array(try $0.forced().textValue ?? "") })
        default: throw MError.typeMismatch(expected: "text", got: v)
        }
    }
    static func proper(_ s: String) -> String {
        var out = "", startOfWord = true
        for ch in s {
            if ch.isLetter {
                out += startOfWord ? ch.uppercased() : ch.lowercased()
                startOfWord = false
            } else { out.append(ch); startOfWord = !(ch.isNumber || ch == "'" || ch == "\u{2019}") }
        }
        return out
    }
    /// Windows code page → `String.Encoding` (65001 UTF-8, 1200 UTF-16 LE, 1252 Windows-1252, …).
    static func encoding(codePage: Int) -> String.Encoding? {
        switch codePage {
        case 65001: return .utf8
        case 1200: return .utf16LittleEndian
        case 1201: return .utf16BigEndian
        case 12000: return .utf32LittleEndian
        case 12001: return .utf32BigEndian
        case 20127: return .ascii
        default:
            let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }
    /// Decode bytes as text. A byte-order mark wins over the requested code page; the default is UTF-8.
    static func decode(_ data: Data, codePage: Int?) throws -> String {
        let bytes = [UInt8](data.prefix(4))
        var body = data, enc: String.Encoding?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { body = data.dropFirst(3); enc = .utf8 }
        else if bytes.starts(with: [0xFF, 0xFE, 0, 0]) { body = data.dropFirst(4); enc = .utf32LittleEndian }
        else if bytes.starts(with: [0xFF, 0xFE]) { body = data.dropFirst(2); enc = .utf16LittleEndian }
        else if bytes.starts(with: [0xFE, 0xFF]) { body = data.dropFirst(2); enc = .utf16BigEndian }
        if enc == nil {
            guard let e = encoding(codePage: codePage ?? 65001) else {
                throw MError("The text encoding \(codePage ?? 65001) isn't supported.")
            }
            enc = e
        }
        if enc == .utf8 { return String(decoding: body, as: UTF8.self) } // invalid sequences become U+FFFD, as in Power Query
        guard let s = String(data: Data(body), encoding: enc ?? .utf8) else {
            throw MError.dataFormat("The data couldn't be decoded with text encoding \(codePage ?? 65001).")
        }
        return s
    }
    static func encode(_ s: String, codePage: Int?) throws -> Data {
        guard let e = encoding(codePage: codePage ?? 65001), let d = s.data(using: e) else {
            throw MError("The text can't be encoded with text encoding \(codePage ?? 65001).")
        }
        return d
    }
}

extension MLibrary {
    static func registerText(_ lib: MLibrary) {
        lib.enumeration("QuoteStyle", [("None", 0), ("Csv", 1)])
        lib.enumeration("RelativePosition", [("FromStart", 0), ("FromEnd", 1)])
        lib.enumeration("TextEncoding", [("Utf8", 65001), ("Utf16", 1200), ("Unicode", 1200), ("BigEndianUnicode", 1201),
                                          ("Ascii", 20127), ("Windows", 1252)])

        /// Register a function whose first argument is text; null text gives null.
        func text(_ name: String, _ arity: ClosedRange<Int>, _ body: @escaping (String, MArgs, MInterpreter) throws -> MValue) {
            lib.fn(name, arity) { a, ctx in a[0].isNull ? .null : try body(try a.text(0), a, ctx) }
        }
        func chars(_ a: MArgs, _ i: Int) throws -> [Character] { Array(try a.text(i)) }

        lib.fn("Text.From", 1...2) { a, ctx in try MConvert.toText(a[0], culture: try a.optText(1) ?? ctx.culture) }
        text("Text.Length", 1...1) { s, _, _ in .int(s.count) }
        text("Text.Upper", 1...2) { s, _, _ in .text(s.uppercased()) }
        text("Text.Lower", 1...2) { s, _, _ in .text(s.lowercased()) }
        text("Text.Proper", 1...2) { s, _, _ in .text(MText.proper(s)) }
        text("Text.Reverse", 1...1) { s, _, _ in .text(String(s.reversed())) }
        text("Text.ToList", 1...1) { s, _, _ in .list(s.map { .text(String($0)) }) }
        text("Text.Clean", 1...1) { s, _, _ in
            .text(String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })))
        }
        func trim(_ name: String, start: Bool, end: Bool) {
            text(name, 1...2) { s, a, _ in
                let set: Set<Character>? = a.has(1) ? try MText.charSet(a[1]) : nil
                func drop(_ c: Character) -> Bool { set?.contains(c) ?? c.isWhitespace }
                var cs = Array(s)[...]
                if start { cs = cs.drop(while: drop) }
                if end { while let l = cs.last, drop(l) { cs.removeLast() } }
                return .text(String(cs))
            }
        }
        trim("Text.Trim", start: true, end: true)
        trim("Text.TrimStart", start: true, end: false)
        trim("Text.TrimEnd", start: false, end: true)

        // MARK: Extraction
        text("Text.Start", 2...2) { s, a, _ in .text(String(s.prefix(try MLib.index(a, 1)))) }
        text("Text.End", 2...2) { s, a, _ in .text(String(s.suffix(try MLib.index(a, 1)))) }
        text("Text.Middle", 2...3) { s, a, _ in
            let rest = s.dropFirst(try MLib.index(a, 1))
            return .text(String(try a.optInt(2).map { rest.prefix(max(0, $0)) } ?? rest))
        }
        text("Text.Range", 2...3) { s, a, _ in
            let cs = Array(s), offset = try MLib.index(a, 1), n = try a.optInt(2) ?? (cs.count - offset)
            guard offset <= cs.count, n >= 0, offset + n <= cs.count else {
                throw MError("The 'offset' and 'count' arguments are out of range.", detail: a[1])
            }
            return .text(String(cs[offset..<(offset + n)]))
        }
        text("Text.At", 2...2) { s, a, _ in
            let cs = Array(s), i = try MLib.index(a, 1)
            guard i < cs.count else { throw MError("The 'index' argument is out of range.", detail: a[1]) }
            return .text(String(cs[i]))
        }
        text("Text.BeforeDelimiter", 2...3) { s, a, _ in
            let cs = Array(s)
            guard let at = try MText.pick(MText.occurrences(of: try chars(a, 1), in: cs), a[2]) else { return .text(s) }
            return .text(String(cs[..<at]))
        }
        text("Text.AfterDelimiter", 2...3) { s, a, _ in
            let cs = Array(s), d = try chars(a, 1)
            guard let at = try MText.pick(MText.occurrences(of: d, in: cs), a[2]) else { return .text("") }
            return .text(String(cs[(at + d.count)...]))
        }
        text("Text.BetweenDelimiters", 3...5) { s, a, _ in
            let cs = Array(s), d1 = try chars(a, 1), d2 = try chars(a, 2)
            guard let at = try MText.pick(MText.occurrences(of: d1, in: cs), a[3]) else { return .text("") }
            let rest = Array(cs[(at + d1.count)...])
            guard let end = try MText.pick(MText.occurrences(of: d2, in: rest), a[4]) else { return .text(String(rest)) }
            return .text(String(rest[..<end]))
        }
        text("Text.Select", 2...2) { s, a, _ in
            let keep = try MText.charSet(a[1])
            return .text(String(s.filter(keep.contains)))
        }
        text("Text.Remove", 2...2) { s, a, _ in
            let drop = try MText.charSet(a[1])
            return .text(String(s.filter { !drop.contains($0) }))
        }

        // MARK: Search
        func ignoreCase(_ a: MArgs, _ i: Int) -> Bool { MLib.ignoresCase(a[i]) }
        text("Text.Contains", 2...3) { s, a, _ in
            if a[1].isNull { return .null }
            let n = try a.text(1)
            return .logical(n.isEmpty || !MText.occurrences(of: Array(n), in: Array(s), ignoreCase: ignoreCase(a, 2)).isEmpty)
        }
        text("Text.StartsWith", 2...3) { s, a, _ in
            if a[1].isNull { return .null }
            let n = try a.text(1)
            return .logical(ignoreCase(a, 2) ? s.lowercased().hasPrefix(n.lowercased()) : s.hasPrefix(n))
        }
        text("Text.EndsWith", 2...3) { s, a, _ in
            if a[1].isNull { return .null }
            let n = try a.text(1)
            return .logical(ignoreCase(a, 2) ? s.lowercased().hasSuffix(n.lowercased()) : s.hasSuffix(n))
        }
        text("Text.PositionOf", 2...4) { s, a, _ in
            let hits = MText.occurrences(of: try chars(a, 1), in: Array(s), ignoreCase: ignoreCase(a, 3))
            return MLibrary.occurrence(hits, try a.optInt(2) ?? 0)
        }
        text("Text.PositionOfAny", 2...3) { s, a, _ in
            let set = try MText.charSet(a[1])
            return MLibrary.occurrence(Array(s).enumerated().filter { set.contains($0.element) }.map(\.offset), try a.optInt(2) ?? 0)
        }

        // MARK: Modification
        text("Text.Replace", 3...3) { s, a, _ in
            let old = try a.text(1)
            return .text(old.isEmpty ? s : s.replacingOccurrences(of: old, with: try a.text(2)))
        }
        text("Text.Insert", 3...3) { s, a, _ in
            var cs = Array(s)
            let i = try MLib.index(a, 1)
            guard i <= cs.count else { throw MError("The 'offset' argument is out of range.", detail: a[1]) }
            cs.insert(contentsOf: try chars(a, 2), at: i)
            return .text(String(cs))
        }
        text("Text.RemoveRange", 2...3) { s, a, _ in
            var cs = Array(s)
            let i = try MLib.index(a, 1), n = try a.optInt(2) ?? 1
            guard n >= 0, i + n <= cs.count else { throw MError("The 'offset' and 'count' arguments are out of range.", detail: a[1]) }
            cs.removeSubrange(i..<(i + n))
            return .text(String(cs))
        }
        text("Text.ReplaceRange", 4...4) { s, a, _ in
            var cs = Array(s)
            let i = try MLib.index(a, 1), n = try MLib.index(a, 2)
            guard i + n <= cs.count else { throw MError("The 'offset' and 'count' arguments are out of range.", detail: a[1]) }
            cs.replaceSubrange(i..<(i + n), with: try chars(a, 3))
            return .text(String(cs))
        }
        text("Text.PadStart", 2...3) { s, a, _ in
            let pad = try a.optText(2) ?? " "
            guard pad.count == 1 else { throw MError("The pad character must be a single character.") }
            return .text(String(repeating: pad, count: max(0, try a.int(1) - s.count)) + s)
        }
        text("Text.PadEnd", 2...3) { s, a, _ in
            let pad = try a.optText(2) ?? " "
            guard pad.count == 1 else { throw MError("The pad character must be a single character.") }
            return .text(s + String(repeating: pad, count: max(0, try a.int(1) - s.count)))
        }
        text("Text.Repeat", 2...2) { s, a, _ in .text(String(repeating: s, count: try MLib.index(a, 1))) }
        text("Text.Split", 2...2) { s, a, _ in
            let sep = try a.text(1)
            return .list((sep.isEmpty ? [s] : s.components(separatedBy: sep)).map(MValue.text))
        }
        text("Text.SplitAny", 2...2) { s, a, _ in
            let set = try MText.charSet(a[1])
            return .list(s.split(omittingEmptySubsequences: false, whereSeparator: set.contains).map { .text(String($0)) })
        }
        lib.fn("Text.Combine", 1...2) { a, _ in
            let parts = try a.forcedList(0).filter { !$0.isNull }.map { v -> String in
                guard case .text(let s) = v else { throw MError.typeMismatch(expected: "text", got: v) }
                return s
            }
            return .text(parts.joined(separator: try a.optText(1) ?? ""))
        }
        lib.fn("Text.Format", 2...3) { a, ctx in
            let template = Array(try a.text(0))
            var out = "", i = 0
            func value(_ key: String, positional: Bool) throws -> String {
                let v: MValue
                if positional {
                    guard let n = Int(key), case .list(let l) = a[1], n >= 0, n < l.count else { throw MError("Text.Format: no argument #{\(key)}.") }
                    v = try l[n].forced()
                } else {
                    guard case .record(let r) = a[1] else { throw MError("Text.Format: #[\(key)] needs a record of arguments.") }
                    v = try r.require(key)
                }
                return try MConvert.text(v, culture: try a.optText(2) ?? ctx.culture)
            }
            while i < template.count {
                if template[i] == "#", i + 1 < template.count, template[i + 1] == "{" || template[i + 1] == "[" {
                    let close: Character = template[i + 1] == "{" ? "}" : "]"
                    if let end = template[(i + 2)...].firstIndex(of: close) {
                        out += try value(String(template[(i + 2)..<end]), positional: close == "}")
                        i = end + 1
                        continue
                    }
                }
                out.append(template[i]); i += 1
            }
            return .text(out)
        }
        lib.fn("Text.NewGuid", 0) { _, _ in .text(UUID().uuidString.lowercased()) }
        lib.fn("Text.ToBinary", 1...3) { a, _ in a[0].isNull ? .null : .binary(try MText.encode(try a.text(0), codePage: try a.optInt(1))) }
        lib.fn("Text.FromBinary", 1...2) { a, _ in a[0].isNull ? .null : .text(try MText.decode(try a.binary(0), codePage: try a.optInt(1))) }
        lib.fn("Character.FromNumber", 1) { a, _ in
            if a[0].isNull { return .null }
            guard let sc = Unicode.Scalar(UInt32(max(0, try a.int(0)))) else { throw MError("The number isn't a valid character code.", detail: a[0]) }
            return .text(String(Character(sc)))
        }
        lib.fn("Character.ToNumber", 1) { a, _ in
            if a[0].isNull { return .null }
            guard let sc = try a.text(0).unicodeScalars.first else { throw MError("Character.ToNumber needs a character.") }
            return .int(Int(sc.value))
        }
        lib.fn("Replacer.ReplaceText", 3) { a, _ in
            if a[0].isNull { return .null }
            let old = try a.text(1)
            return .text(old.isEmpty ? try a.text(0) : try a.text(0).replacingOccurrences(of: old, with: try a.text(2)))
        }
        lib.fn("Replacer.ReplaceValue", 3) { a, _ in MValue.equals(a[0], a[1]) ? a[2] : a[0] }
        registerSplitters(lib)
    }
}
