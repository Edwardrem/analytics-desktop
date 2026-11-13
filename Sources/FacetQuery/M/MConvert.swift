import Foundation
import FacetCore

/// Culture-aware conversions between M values (the engine behind `Text.From`, `Number.From`,
/// `Date.FromText`, `Table.TransformColumnTypes`, …).
public enum MConvert {
    // MARK: Culture
    private static let cacheLock = NSLock()
    private static var localeCache: [String: Locale] = [:]
    private static var formatterCache: [String: DateFormatter] = [:]

    public static func locale(_ culture: String?) -> Locale {
        let id = (culture?.isEmpty ?? true) ? "en-US" : culture!
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let l = localeCache[id] { return l }
        let l = Locale(identifier: id.replacingOccurrences(of: "-", with: "_"))
        localeCache[id] = l
        return l
    }
    /// Day-before-month cultures parse `1/2/2024` as 1 February.
    static func dayFirst(_ culture: String?) -> Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale(culture)) ?? "M/d/y"
        guard let d = fmt.firstIndex(of: "d"), let m = fmt.firstIndex(of: "M") else { return false }
        return d < m
    }
    static func formatter(_ pattern: String, _ culture: String?) -> DateFormatter {
        let key = (culture ?? "") + "|" + pattern
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let f = formatterCache[key] { return f }
        let f = DateFormatter()
        let id = (culture?.isEmpty ?? true) ? "en-US" : culture!
        f.locale = Locale(identifier: id.replacingOccurrences(of: "-", with: "_"))
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar.utc
        f.dateFormat = pattern
        formatterCache[key] = f
        return f
    }
    private static func withFormatter<T>(_ pattern: String, _ culture: String?, _ body: (DateFormatter) -> T) -> T {
        let f = formatter(pattern, culture)
        objc_sync_enter(f); defer { objc_sync_exit(f) }
        return body(f)
    }

    // MARK: Numbers
    /// Parse number text using the culture's separators. Accepts thousands separators, %, currency symbols,
    /// parentheses for negatives, exponents, `NaN`/`Infinity`.
    public static func parseNumber(_ s: String, culture: String? = nil) -> Double? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let d = fastDouble(t) { return d }
        let loc = locale(culture)
        let dec = loc.decimalSeparator ?? ".", grp = loc.groupingSeparator ?? ","
        var negative = false, percent = false
        if t.hasPrefix("("), t.hasSuffix(")") { negative = true; t = String(t.dropFirst().dropLast()) }
        if t.hasSuffix("%") { percent = true; t.removeLast(); t = t.trimmingCharacters(in: .whitespaces) }
        if let sym = loc.currencySymbol, !sym.isEmpty { t = t.replacingOccurrences(of: sym, with: "") }
        for sym in ["$", "€", "£", "¥"] { t = t.replacingOccurrences(of: sym, with: "") }
        t = t.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: " ", with: "")
        if t.hasPrefix("-") { negative.toggle(); t.removeFirst() } else if t.hasSuffix("-") { negative.toggle(); t.removeLast() } else if t.hasPrefix("+") { t.removeFirst() }
        switch t.lowercased() {
        case "nan": return .nan
        case "infinity", "∞", "inf": return negative ? -.infinity : .infinity
        default: break
        }
        if !grp.isEmpty { t = t.replacingOccurrences(of: grp, with: "") }
        if dec != "." { t = t.replacingOccurrences(of: dec, with: ".") }
        guard let f = t.unicodeScalars.first, (f.value >= 48 && f.value <= 57) || f == ".", var d = Double(t) else { return nil }
        if negative { d = -d }
        if percent { d /= 100 }
        return d
    }
    /// Plain ASCII decimal fast path (no separators), avoiding locale work for the common case.
    private static func fastDouble(_ t: String) -> Double? {
        var sawDigit = false
        for c in t.utf8 {
            if c >= 48 && c <= 57 { sawDigit = true; continue }
            if c == 46 || c == 45 || c == 43 || c == 101 || c == 69 { continue }
            return nil
        }
        return sawDigit ? Double(t) : nil
    }

    public static func toNumber(_ v: MValue, culture: String? = nil) throws -> MValue {
        switch v {
        case .null: return .null
        case .number: return v
        case .logical(let b): return .number(b ? 1 : 0)
        case .text(let s):
            guard let d = parseNumber(s, culture: culture) else {
                throw MError.dataFormat("We couldn't convert to Number.").with(detail: v)
            }
            return .number(d)
        case .date(let d), .datetime(let d): return .number(Value.serial(from: d))
        case .datetimezone(let d, let off): return .number(Value.serial(from: d.addingTimeInterval(Double(off) * 60)))
        case .time(let t): return .number(t / 86400)
        case .duration(let s): return .number(s / 86400)
        default: throw MError.typeMismatch(expected: "number", got: v)
        }
    }

    public static func toLogical(_ v: MValue) throws -> MValue {
        switch v {
        case .null: return .null
        case .logical: return v
        case .number(let d): return .logical(d != 0)
        case .text(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return .logical(true)
            case "false": return .logical(false)
            default: throw MError.dataFormat("We couldn't convert to Logical.").with(detail: v)
            }
        default: throw MError.typeMismatch(expected: "logical", got: v)
        }
    }

    // MARK: Text
    /// `Text.From`: null stays null; structured values are an error.
    public static func toText(_ v: MValue, culture: String? = nil, format: String? = nil) throws -> MValue {
        if v.isNull { return .null }
        return .text(try text(v, culture: culture, format: format))
    }
    public static func text(_ v: MValue, culture: String? = nil, format: String? = nil) throws -> String {
        switch v {
        case .text(let s): return s
        case .logical(let b): return b ? "true" : "false"
        case .number(let d): return formatNumber(d, format: format, culture: culture)
        case .date(let d): return formatDate(d, format: format ?? "d", culture: culture)
        case .datetime(let d): return formatDate(d, format: format ?? "G", culture: culture)
        case .datetimezone(let d, let off):
            let local = d.addingTimeInterval(Double(off) * 60)
            if let f = format { return formatDate(local, format: f, culture: culture, offsetMinutes: off) }
            return formatDate(local, format: "G", culture: culture) + " " + offsetText(off)
        case .time(let t): return formatDate(Date(timeIntervalSince1970: t), format: format ?? "T", culture: culture)
        case .duration(let s): return durationText(s)
        case .null: return ""
        default: throw MError.typeMismatch(expected: "text", got: v)
        }
    }
    public static func offsetText(_ minutes: Int) -> String {
        String(format: "%@%02d:%02d", minutes < 0 ? "-" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
    /// `d.hh:mm:ss[.fffffff]` as M renders durations.
    public static func durationText(_ seconds: Double) -> String {
        let neg = seconds < 0
        var s = abs(seconds)
        let days = Int(s / 86400); s -= Double(days) * 86400
        let h = Int(s / 3600); s -= Double(h) * 3600
        let m = Int(s / 60); s -= Double(m) * 60
        let whole = Int(s), frac = s - Double(whole)
        var out = (neg ? "-" : "") + (days > 0 ? "\(days)." : "") + String(format: "%02d:%02d:%02d", h, m, whole)
        if frac > 1e-7 { out += String(format: "%.7f", frac).dropFirst(1) }
        return out
    }

    // MARK: Number formatting (.NET-style format strings)
    public static func formatNumber(_ d: Double, format: String? = nil, culture: String? = nil) -> String {
        let loc = locale(culture)
        let dec = loc.decimalSeparator ?? ".", grp = loc.groupingSeparator ?? ","
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-∞" : "∞" }
        guard let format, !format.isEmpty else { return general(d, dec) }
        // Standard format: one letter + optional precision
        if let first = format.first, first.isLetter, format.dropFirst().allSatisfy(\.isNumber), format.count <= 3 {
            let prec = Int(format.dropFirst())
            switch first.uppercased() {
            case "G", "R": return general(d, dec)
            case "F": return fixed(d, prec ?? 2, dec, nil)
            case "N": return fixed(d, prec ?? 2, dec, grp)
            case "P": return fixed(d * 100, prec ?? 2, dec, grp) + " %"
            case "C":
                let sym = loc.currencySymbol ?? "$"
                let body = fixed(abs(d), prec ?? 2, dec, grp)
                return (d < 0 ? "-" : "") + sym + body
            case "D":
                let i = Int64(d.rounded())
                let digits = String(abs(i))
                return (i < 0 ? "-" : "") + String(repeating: "0", count: max(0, (prec ?? 0) - digits.count)) + digits
            case "E":
                let s = String(format: "%.\(prec ?? 6)e", d) // 1.234560e+03
                guard let eIdx = s.firstIndex(of: "e") else { return s }
                let mant = s[..<eIdx].replacingOccurrences(of: ".", with: dec)
                let expPart = s[s.index(after: eIdx)...]
                let sign = expPart.first == "-" ? "-" : "+"
                let digits = expPart.dropFirst().drop { $0 == "0" }
                let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
                return mant + (first == "e" ? "e" : "E") + sign + padded
            case "X":
                let h = String(Int64(d), radix: 16, uppercase: first == "X")
                return String(repeating: "0", count: max(0, (prec ?? 0) - h.count)) + h
            default: break
            }
        }
        return custom(d, format, dec, grp)
    }
    private static func general(_ d: Double, _ dec: String) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        var s = "\(d)"
        if s.contains("e") { s = s.replacingOccurrences(of: "e", with: "E") }
        return dec == "." ? s : s.replacingOccurrences(of: ".", with: dec)
    }
    private static func fixed(_ d: Double, _ places: Int, _ dec: String, _ grp: String?) -> String {
        let s = String(format: "%.\(max(0, min(places, 15)))f", roundHalfAway(abs(d), places))
        var parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let g = grp { parts[0] = group(parts[0], g) }
        let body = parts.count > 1 ? parts[0] + dec + parts[1] : parts[0]
        let isZero = !body.contains { $0.isNumber && $0 != "0" }
        return (d < 0 && !isZero ? "-" : "") + body
    }
    static func roundHalfAway(_ d: Double, _ places: Int) -> Double {
        let p = pow(10.0, Double(places))
        let scaled = d * p
        guard scaled.isFinite, abs(scaled) < 1e15 else { return d }
        // nudge to counter binary representation (e.g. 2.675 → 2.68)
        return (scaled + (scaled >= 0 ? 1e-9 : -1e-9) * max(1, abs(scaled)) * 1e-3).rounded(.toNearestOrAwayFromZero) / p
    }
    private static func group(_ digits: String, _ sep: String) -> String {
        var out = "", n = 0
        for ch in digits.reversed() {
            if n > 0, n % 3 == 0 { out = sep + out }
            out = String(ch) + out; n += 1
        }
        return out
    }
    /// Custom numeric format: `0`, `#`, `.`, `,`, `%`, literals, quoted text, and `;` sections.
    private static func custom(_ value: Double, _ format: String, _ dec: String, _ grp: String) -> String {
        let sections = splitSections(format)
        var fmt = sections[0], d = value
        if value < 0, sections.count > 1 { fmt = sections[1]; d = -value }
        else if value == 0, sections.count > 2 { fmt = sections[2] }
        var intPat: [Character] = [], fracPat: [Character] = []
        var prefix = "", suffix = "", useGroup = false, seenDot = false, percent = false, seenDigit = false
        var chars = Array(fmt), i = 0
        chars.append(" "); chars.removeLast()
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "0", "#":
                seenDigit = true
                if seenDot { fracPat.append(c) } else { intPat.append(c) }
            case ".": if seenDot { suffix.append(c) } else { seenDot = true }
            case ",": if seenDigit && !seenDot { useGroup = true }
            case "%": percent = true; if seenDigit { suffix.append("%") } else { prefix.append("%") }
            case "'", "\"":
                var j = i + 1, lit = ""
                while j < chars.count, chars[j] != c { lit.append(chars[j]); j += 1 }
                if seenDigit { suffix += lit } else { prefix += lit }
                i = j
            case "\\":
                if i + 1 < chars.count { i += 1; if seenDigit { suffix.append(chars[i]) } else { prefix.append(chars[i]) } }
            default: if seenDigit { suffix.append(c) } else { prefix.append(c) }
            }
            i += 1
        }
        if percent { d *= 100 }
        let places = fracPat.count
        let s = String(format: "%.\(places)f", roundHalfAway(abs(d), places))
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var intDigits = parts[0]
        let minInt = intPat.filter { $0 == "0" }.count
        if intDigits == "0", minInt == 0 { intDigits = "" }
        if intDigits.count < minInt { intDigits = String(repeating: "0", count: minInt - intDigits.count) + intDigits }
        if useGroup { intDigits = group(intDigits, grp) }
        var frac = parts.count > 1 ? parts[1] : ""
        // trim optional (#) trailing digits
        var k = fracPat.count
        while k > 0, fracPat[k - 1] == "#", frac.hasSuffix("0") { frac.removeLast(); k -= 1 }
        let neg = d < 0 && (intDigits + frac).contains { $0.isNumber && $0 != "0" }
        return (neg ? "-" : "") + prefix + intDigits + (frac.isEmpty ? "" : dec + frac) + suffix
    }
    private static func splitSections(_ f: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for c in f {
            if let q = quote { cur.append(c); if c == q { quote = nil }; continue }
            if c == "'" || c == "\"" { quote = c; cur.append(c); continue }
            if c == ";" { out.append(cur); cur = "" } else { cur.append(c) }
        }
        out.append(cur)
        return out
    }

    // MARK: Date formatting
    /// Format a wall-clock date with a .NET-style standard (`d`, `D`, `t`, `T`, `g`, `G`, `s`, `o`, `M`, `Y`, `f`, `F`, `u`)
    /// or custom (`yyyy-MM-dd`, `ddd`, `MMMM`, `tt`, …) format string.
    public static func formatDate(_ date: Date, format: String, culture: String? = nil, offsetMinutes: Int? = nil) -> String {
        let pattern: String
        if format.count == 1 {
            let loc = locale(culture)
            func tpl(_ t: String) -> String { DateFormatter.dateFormat(fromTemplate: t, options: 0, locale: loc) ?? t }
            let shortDate = tpl("yMd").replacingOccurrences(of: "yy", with: "y").replacingOccurrences(of: "y", with: "yyyy")
            let longTime = tpl("jmmss"), shortTime = tpl("jmm")
            switch format {
            case "d": pattern = shortDate
            case "D": pattern = tpl("yMMMMEEEEd")
            case "t": pattern = shortTime
            case "T": pattern = longTime
            case "g": pattern = shortDate + " " + shortTime
            case "G": pattern = shortDate + " " + longTime
            case "f": pattern = tpl("yMMMMEEEEd") + " " + shortTime
            case "F": pattern = tpl("yMMMMEEEEd") + " " + longTime
            case "M", "m": pattern = tpl("MMMMd")
            case "Y", "y": pattern = tpl("yMMMM")
            case "s": pattern = "yyyy-MM-dd'T'HH:mm:ss"
            case "u": pattern = "yyyy-MM-dd HH:mm:ss'Z'"
            case "o", "O": pattern = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
            default: pattern = icuPattern(fromDotNet: format)
            }
        } else { pattern = icuPattern(fromDotNet: format) }
        var s = withFormatter(pattern, culture) { $0.string(from: date) }
        s = s.replacingOccurrences(of: "\u{202F}", with: " ")
        if let off = offsetMinutes, pattern.contains("\u{1}") { s = s.replacingOccurrences(of: "\u{1}", with: offsetText(off)) }
        else if s.contains("\u{1}") { s = s.replacingOccurrences(of: "\u{1}", with: "+00:00") }
        return s
    }
    /// Translate a .NET custom date format into an ICU pattern.
    static func icuPattern(fromDotNet f: String) -> String {
        var out = "", lit = ""
        let chars = Array(f)
        var i = 0
        func flush() { if !lit.isEmpty { out += "'" + lit.replacingOccurrences(of: "'", with: "''") + "'"; lit = "" } }
        while i < chars.count {
            let c = chars[i]
            var run = 1
            while i + run < chars.count, chars[i + run] == c { run += 1 }
            switch c {
            case "y": flush(); out += run == 2 ? "yy" : (run == 1 ? "y" : String(repeating: "y", count: max(4, run)))
            case "M": flush(); out += String(repeating: "M", count: min(run, 4))
            case "d":
                flush()
                out += run >= 4 ? "EEEE" : (run == 3 ? "EEE" : String(repeating: "d", count: run))
            case "H", "h", "m", "s": flush(); out += String(repeating: String(c), count: min(run, 2))
            case "f", "F": flush(); out += String(repeating: "S", count: run)
            case "t": flush(); out += "a"
            case "z": flush(); lit += "\u{1}"; flush()
            case "'", "\"":
                var j = i + 1
                while j < chars.count, chars[j] != c { lit.append(chars[j]); j += 1 }
                i = j + 1; continue
            case "\\":
                if i + 1 < chars.count { lit.append(chars[i + 1]) }
                i += 2; continue
            default:
                if c.isLetter { lit.append(contentsOf: String(repeating: String(c), count: run)) }
                else { flush(); out += String(repeating: String(c), count: run) }
            }
            i += run
        }
        flush()
        return out
    }

    // MARK: Date parsing
    /// Result of parsing date/time text.
    public struct ParsedDateTime {
        /// Wall-clock components as a UTC-stored date (date part is 1899-12-30-free: midnight when no date present → 1970-01-01).
        public var date: Date
        public var hasDate: Bool
        public var hasTime: Bool
        public var offsetMinutes: Int?
    }

    /// Parse date/time text. With `format` (a .NET custom format) parsing is exact; otherwise ISO 8601 and the
    /// culture's numeric and month-name forms are accepted.
    public static func parseDateTime(_ s: String, culture: String? = nil, format: String? = nil) -> ParsedDateTime? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let format {
            let pattern = icuPattern(fromDotNet: format)
            guard let d = withFormatter(pattern, culture, { $0.date(from: t) }) else { return nil }
            let hasDate = pattern.contains("y") || pattern.contains("M") || pattern.contains("d")
            let hasTime = pattern.contains("H") || pattern.contains("h") || pattern.contains("m")
            return ParsedDateTime(date: d, hasDate: hasDate, hasTime: hasTime, offsetMinutes: nil)
        }
        if let r = fastParse(Array(t.utf8), dayFirst: dayFirst(culture)) { return r }
        // Month-name forms via ICU
        for (p, time) in [("d MMM yyyy", false), ("d MMMM yyyy", false), ("MMM d, yyyy", false), ("MMMM d, yyyy", false),
                          ("dd-MMM-yyyy", false), ("dd-MMM-yy", false), ("MMM yyyy", false), ("MMMM yyyy", false),
                          ("EEEE, MMMM d, yyyy", false), ("EEEE, d MMMM yyyy", false),
                          ("d MMM yyyy HH:mm:ss", true), ("MMM d, yyyy h:mm:ss a", true), ("MMMM d, yyyy h:mm:ss a", true),
                          ("d MMMM yyyy HH:mm:ss", true), ("MMM d, yyyy h:mm a", true), ("d MMM yyyy HH:mm", true)] {
            if let d = withFormatter(p, culture, { $0.date(from: t) }) {
                return ParsedDateTime(date: d, hasDate: true, hasTime: time, offsetMinutes: nil)
            }
        }
        return nil
    }

    /// Hand-written parser for numeric forms: `yyyy-MM-dd`, `yyyy/MM/dd`, `M/d/yyyy`, `d.M.yyyy`, `yyyyMMdd`,
    /// optional `T`/space time `H:mm[:ss[.f…]] [AM|PM]`, optional `Z` / `±hh[:mm]`; or a bare time.
    private static func fastParse(_ b: [UInt8], dayFirst: Bool) -> ParsedDateTime? {
        var i = 0
        let n = b.count
        func digit(_ k: Int) -> Bool { k < n && b[k] >= 48 && b[k] <= 57 }
        func readInt(max: Int = 9) -> (Int, Int)? {
            var v = 0, c = 0
            while digit(i), c < max { v = v * 10 + Int(b[i] - 48); i += 1; c += 1 }
            return c == 0 ? nil : (v, c)
        }
        var year = 1970, month = 1, day = 1, hasDate = false
        let save = i
        if let (a, alen) = readInt() {
            if i < n, b[i] == 45 || b[i] == 47 || b[i] == 46 { // - / .
                let sep = b[i]; i += 1
                if let (m2, _) = readInt(), i < n, b[i] == sep {
                    i += 1
                    if let (c, clen) = readInt() {
                        if alen == 4 { year = a; month = m2; day = c }
                        else {
                            year = clen <= 2 ? (c < 50 ? 2000 + c : 1900 + c) : c
                            if sep == 46 || dayFirst { day = a; month = m2 } else { month = a; day = m2 }
                            if month > 12, day <= 12 { swap(&month, &day) }
                        }
                        hasDate = true
                    }
                }
            } else if alen == 8, i == n || b[i] == 84 || b[i] == 32 {
                year = a / 10000; month = (a / 100) % 100; day = a % 100; hasDate = true
            }
        }
        if !hasDate { i = save }
        else {
            guard month >= 1, month <= 12, day >= 1, day <= 31, year >= 1, year <= 9999 else { return nil }
            if i < n { guard b[i] == 84 || b[i] == 32 else { return nil }; i += 1 }
        }
        var secs = 0.0, hasTime = false, offset: Int?
        if i < n {
            guard let (h, _) = readInt(max: 2), i < n, b[i] == 58 else { return nil }
            i += 1
            guard let (mi, _) = readInt(max: 2) else { return nil }
            var s = 0.0
            if i < n, b[i] == 58 {
                i += 1
                guard let (sv, _) = readInt(max: 2) else { return nil }
                s = Double(sv)
                if i < n, b[i] == 46 || b[i] == 44 {
                    i += 1
                    var scale = 0.1
                    while digit(i) { s += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
                }
            }
            var hour = h
            while i < n, b[i] == 32 { i += 1 }
            if i + 1 < n, (b[i] | 32) == 97 || (b[i] | 32) == 112, (b[i + 1] | 32) == 109 { // am / pm
                let pm = (b[i] | 32) == 112
                guard hour >= 1, hour <= 12 else { return nil }
                hour = (hour % 12) + (pm ? 12 : 0)
                i += 2
                while i < n, b[i] == 32 { i += 1 }
            }
            guard hour < 24 || (hour == 24 && mi == 0 && s == 0), mi < 60, s < 61 else { return nil }
            secs = Double(hour) * 3600 + Double(mi) * 60 + s
            hasTime = true
            if i < n {
                if b[i] == 90 || b[i] == 122 { offset = 0; i += 1 }
                else if b[i] == 43 || b[i] == 45 {
                    let neg = b[i] == 45; i += 1
                    guard let (oh, ohLen) = readInt(max: 4) else { return nil }
                    var om = 0, hh = oh
                    if ohLen == 4 { hh = oh / 100; om = oh % 100 }
                    else if i < n, b[i] == 58 { i += 1; guard let (m3, _) = readInt(max: 2) else { return nil }; om = m3 }
                    offset = (hh * 60 + om) * (neg ? -1 : 1)
                }
            }
        }
        guard i == n, hasDate || hasTime else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let base = Calendar.utc.date(from: comps) else { return nil }
        // reject impossible days (e.g. Feb 30) — Calendar would roll them over
        if hasDate, Calendar.utc.component(.day, from: base) != day { return nil }
        return ParsedDateTime(date: base.addingTimeInterval(secs), hasDate: hasDate, hasTime: hasTime, offsetMinutes: offset)
    }

    private static func startOfDay(_ d: Date) -> Date { MOps.dayFloor(d) }
    private static func timeOfDay(_ d: Date) -> Double { d.timeIntervalSince(MOps.dayFloor(d)) }
    private static func localOffsetMinutes(_ d: Date) -> Int { TimeZone.current.secondsFromGMT(for: d) / 60 }

    public static func toDate(_ v: MValue, culture: String? = nil, format: String? = nil) throws -> MValue {
        switch v {
        case .null: return .null
        case .date: return v
        case .datetime(let d): return .date(startOfDay(d))
        case .datetimezone(let d, let off): return .date(startOfDay(d.addingTimeInterval(Double(off) * 60)))
        case .number(let n): return .date(startOfDay(Value.date(fromSerial: n)))
        case .text(let s):
            guard let p = parseDateTime(s, culture: culture, format: format), p.hasDate else {
                throw MError.dataFormat("We couldn't parse the input provided as a Date value.").with(detail: v)
            }
            return .date(startOfDay(p.date))
        default: throw MError.typeMismatch(expected: "date", got: v)
        }
    }
    public static func toDateTime(_ v: MValue, culture: String? = nil, format: String? = nil) throws -> MValue {
        switch v {
        case .null: return .null
        case .datetime: return v
        case .date(let d): return .datetime(d)
        case .datetimezone(let d, let off): return .datetime(d.addingTimeInterval(Double(off) * 60))
        case .time(let t): return .datetime(Value.date(fromSerial: 0).addingTimeInterval(t))
        case .number(let n): return .datetime(Value.date(fromSerial: n))
        case .text(let s):
            guard let p = parseDateTime(s, culture: culture, format: format), p.hasDate else {
                throw MError.dataFormat("We couldn't parse the input provided as a DateTime value.").with(detail: v)
            }
            return .datetime(p.date)
        default: throw MError.typeMismatch(expected: "datetime", got: v)
        }
    }
    public static func toDateTimeZone(_ v: MValue, culture: String? = nil, format: String? = nil) throws -> MValue {
        switch v {
        case .null: return .null
        case .datetimezone: return v
        case .date(let d), .datetime(let d):
            let guess = localOffsetMinutes(d)
            return .datetimezone(d.addingTimeInterval(-Double(guess) * 60), offsetMinutes: guess)
        case .number(let n): return try toDateTimeZone(.datetime(Value.date(fromSerial: n)))
        case .text(let s):
            guard let p = parseDateTime(s, culture: culture, format: format), p.hasDate else {
                throw MError.dataFormat("We couldn't parse the input provided as a DateTimeZone value.").with(detail: v)
            }
            let off = p.offsetMinutes ?? localOffsetMinutes(p.date)
            return .datetimezone(p.date.addingTimeInterval(-Double(off) * 60), offsetMinutes: off)
        default: throw MError.typeMismatch(expected: "datetimezone", got: v)
        }
    }
    public static func toTime(_ v: MValue, culture: String? = nil, format: String? = nil) throws -> MValue {
        switch v {
        case .null: return .null
        case .time: return v
        case .datetime(let d): return .time(timeOfDay(d))
        case .datetimezone(let d, let off): return .time(timeOfDay(d.addingTimeInterval(Double(off) * 60)))
        case .number(let n):
            let f = n - n.rounded(.down)
            return .time((f * 86400).rounded())
        case .text(let s):
            guard let p = parseDateTime(s, culture: culture, format: format), p.hasTime else {
                throw MError.dataFormat("We couldn't parse the input provided as a Time value.").with(detail: v)
            }
            return .time(timeOfDay(p.date))
        default: throw MError.typeMismatch(expected: "time", got: v)
        }
    }
    /// Parse `d.hh:mm:ss`, `hh:mm:ss`, `hh:mm`, `d` and ISO 8601 `PnDTnHnMnS` durations.
    public static func parseDuration(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() }
        if t.hasPrefix("P") {
            var total = 0.0, num = "", inTime = false
            for c in t.dropFirst() {
                if c == "T" { inTime = true; continue }
                if c.isNumber || c == "." { num.append(c); continue }
                guard let v = Double(num) else { return nil }
                num = ""
                switch (c, inTime) {
                case ("D", false): total += v * 86400
                case ("W", false): total += v * 7 * 86400
                case ("H", true): total += v * 3600
                case ("M", true): total += v * 60
                case ("S", true): total += v
                default: return nil
                }
            }
            return num.isEmpty ? sign * total : nil
        }
        var days = 0.0
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return Double(parts[0]).map { sign * $0 * 86400 } }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var hourPart = parts[0]
        if let dot = hourPart.firstIndex(of: ".") {
            guard let d = Double(hourPart[..<dot]) else { return nil }
            days = d; hourPart = String(hourPart[hourPart.index(after: dot)...])
        }
        guard let h = Double(hourPart), let m = Double(parts[1]) else { return nil }
        let sec = parts.count == 3 ? Double(parts[2]) : 0
        guard let sec else { return nil }
        return sign * (days * 86400 + h * 3600 + m * 60 + sec)
    }
    public static func toDuration(_ v: MValue) throws -> MValue {
        switch v {
        case .null: return .null
        case .duration: return v
        case .number(let n): return .duration(n * 86400)
        case .text(let s):
            guard let d = parseDuration(s) else {
                throw MError.dataFormat("We couldn't parse the Duration literal.").with(detail: v)
            }
            return .duration(d)
        default: throw MError.typeMismatch(expected: "duration", got: v)
        }
    }

    // MARK: Typed conversion (Table.TransformColumnTypes, Value.As-style coercion)
    /// Convert `v` to `type` the way "Change type" does. Throws (→ cell error) when the value can't be converted.
    public static func convert(_ v: MValue, to type: MType, culture: String? = nil) throws -> MValue {
        if v.isNull { return .null }
        switch type.nonNullable {
        case .any, .anynonnull: return v
        case .text: return try toText(v, culture: culture)
        case .number(let kind):
            guard case .number(let d) = try toNumber(v, culture: culture) else { return .null }
            if kind.isInteger {
                guard d.isFinite else { throw MError.dataFormat("We couldn't convert to Int64.").with(detail: v) }
                return .number(d.rounded(.toNearestOrEven))
            }
            if kind == .currency { return .number((d * 10000).rounded() / 10000) }
            return .number(d)
        case .logical: return try toLogical(v)
        case .date: return try toDate(v, culture: culture)
        case .datetime: return try toDateTime(v, culture: culture)
        case .datetimezone: return try toDateTimeZone(v, culture: culture)
        case .time: return try toTime(v, culture: culture)
        case .duration: return try toDuration(v)
        case .binary:
            if case .binary = v { return v }
            if case .text(let s) = v { return .binary(Data(s.utf8)) }
            throw MError.typeMismatch(expected: "binary", got: v)
        default:
            guard type.matches(v) else { throw MError.typeMismatch(expected: type.mText, got: v) }
            return v
        }
    }
}

extension MError {
    func with(detail: MValue) -> MError { var e = self; e.detail = detail; return e }
}
