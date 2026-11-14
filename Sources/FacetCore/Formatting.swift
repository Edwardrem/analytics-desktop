import Foundation

/// Formats values using Power BI / Excel-style format strings:
/// "0", "0.00", "#,0", "#,0.00", "0%", "0.0%", "$#,0.00", "#,0.0,,\"M\"", "General Number",
/// "Currency", "Percent", "Scientific", "Short Date", "Long Date", "yyyy-MM-dd", "mmm yyyy", …
public enum ValueFormatter {
    private static let cultureLock = NSLock()
    private static var currentCulture = FormatCulture.enUS
    /// The culture values are shown in when no culture is given: the active document's model language.
    public static var culture: FormatCulture {
        get { cultureLock.lock(); defer { cultureLock.unlock() }; return currentCulture }
        set { cultureLock.lock(); currentCulture = newValue; cultureLock.unlock() }
    }

    public static func format(_ value: Value, _ fmt: String = "") -> String {
        format(value, fmt, culture: culture)
    }

    public static func format(_ value: Value, _ fmt: String, culture c: FormatCulture) -> String {
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .date(let d): return formatDate(d, fmt, culture: c)
        case .int(let i):
            // General format, as in Power BI: a whole number with no format string has no separators (a year is 2024).
            if fmt.isEmpty { return String(i) }
            if isDateFormat(fmt) { return formatDate(Value.date(fromSerial: Double(i)), fmt, culture: c) }
            return formatNumber(Double(i), fmt, culture: c)
        case .double(let d):
            if !d.isFinite { return d.isNaN ? "NaN" : (d > 0 ? "∞" : "-∞") }
            if fmt.isEmpty { return c.localize(general(d)) }
            if isDateFormat(fmt) { return formatDate(Value.date(fromSerial: d), fmt, culture: c) }
            return formatNumber(d, fmt, culture: c)
        }
    }

    /// Compact display for axes and callouts: 1.2K, 3.4M, 5.6bn.
    public static func compact(_ d: Double, decimals: Int = 1) -> String {
        let a = abs(d)
        func f(_ v: Double, _ suffix: String) -> String {
            var s = String(format: "%.\(decimals)f", v)
            if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
            return culture.localize(s) + suffix
        }
        switch a {
        case 1e12...: return f(d / 1e12, "T")
        case 1e9...: return f(d / 1e9, "bn")
        case 1e6...: return f(d / 1e6, "M")
        case 1e3...: return f(d / 1e3, "K")
        default: return a < 10 && a != a.rounded() ? f(d, "") : f(d.rounded() == d ? d : (d * 10).rounded() / 10, "")
        }
    }

    static func general(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return grouped(d, decimals: 0) }
        let s = grouped(d, decimals: 2)
        return s
    }

    static func grouped(_ d: Double, decimals: Int, grouping: Bool = true) -> String {
        let neg = d < 0
        let s = String(format: "%.\(decimals)f", abs(d))
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var intPart = String(parts[0])
        if grouping, intPart.count > 3 {
            var out = ""
            for (i, ch) in intPart.reversed().enumerated() {
                if i > 0, i % 3 == 0 { out.append(",") }
                out.append(ch)
            }
            intPart = String(out.reversed())
        }
        let body = parts.count > 1 ? intPart + "." + parts[1] : intPart
        let isZero = !body.contains(where: { $0 != "0" && $0 != "." && $0 != "," })
        return (neg && !isZero ? "-" : "") + body
    }

    public static func formatNumber(_ value: Double, _ fmt: String) -> String {
        formatNumber(value, fmt, culture: culture)
    }

    public static func formatNumber(_ value: Double, _ fmt: String, culture c: FormatCulture) -> String {
        switch fmt.lowercased() {
        case "general number", "general": return c.localize(general(value))
        case "currency": return c.isUS ? (value < 0 ? "-$" : "$") + grouped(abs(value), decimals: 2) : c.currency(value)
        case "fixed": return c.localize(grouped(value, decimals: 2, grouping: false))
        case "standard": return c.localize(grouped(value, decimals: 2))
        case "percent": return c.localize(grouped(value * 100, decimals: 2, grouping: false)) + "%"
        case "scientific": return c.localize(String(format: "%.2E", value))
        case "yes/no": return value != 0 ? "Yes" : "No"
        case "true/false": return value != 0 ? "True" : "False"
        case "on/off": return value != 0 ? "On" : "Off"
        default: break
        }
        // Sections: positive;negative;zero
        let sections = splitSections(fmt)
        var section = sections[0]
        var v = value
        if value < 0, sections.count > 1 { section = sections[1]; v = abs(value) }
        else if value == 0, sections.count > 2 { section = sections[2] }

        // Tokenise into literal prefix, numeric pattern, literal suffix.
        var prefix = "", suffix = "", pattern = ""
        var inQuote = false, seenPattern = false, escaped = false
        for ch in section {
            if escaped { if seenPattern { suffix.append(ch) } else { prefix.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { if seenPattern { suffix.append(ch) } else { prefix.append(ch) }; continue }
            if "0#.,".contains(ch) && suffix.isEmpty { pattern.append(ch); seenPattern = true }
            else if ch == "%" { v *= 100; if seenPattern { suffix.append(ch) } else { prefix.append(ch) } }
            else if seenPattern { suffix.append(ch) } else { prefix.append(ch) }
        }
        if pattern.isEmpty { return prefix + suffix }
        // Trailing commas scale by thousands.
        var scaleCommas = 0
        while pattern.hasSuffix(",") { pattern.removeLast(); scaleCommas += 1 }
        if scaleCommas > 0 { v /= pow(1000, Double(scaleCommas)) }
        let pieces = pattern.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPattern = String(pieces[0])
        let fracPattern = pieces.count > 1 ? String(pieces[1]) : ""
        let grouping = intPattern.contains(",")
        let maxDecimals = fracPattern.filter { $0 == "0" || $0 == "#" }.count
        let minDecimals = fracPattern.filter { $0 == "0" }.count
        var body = grouped(v, decimals: maxDecimals, grouping: grouping)
        if maxDecimals > minDecimals, body.contains(".") {
            var trim = maxDecimals - minDecimals
            while trim > 0, body.hasSuffix("0") { body.removeLast(); trim -= 1 }
            if body.hasSuffix(".") { body.removeLast() }
        }
        let minInts = intPattern.filter { $0 == "0" }.count
        if minInts == 0, body.hasPrefix("0."), v != 0 { body.removeFirst() }
        var neg = false
        if body.hasPrefix("-") { neg = true; body.removeFirst() }
        let digits = body.prefix { $0 != "." }.filter(\.isNumber).count
        if digits < minInts { body = String(repeating: "0", count: minInts - digits) + body }
        return (neg ? "-" : "") + prefix + c.localize(body) + suffix
    }

    static func splitSections(_ fmt: String) -> [String] {
        var out: [String] = [], cur = "", inQuote = false
        for ch in fmt {
            if ch == "\"" { inQuote.toggle() }
            if ch == ";", !inQuote { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    static func isDateFormat(_ fmt: String) -> Bool {
        let l = fmt.lowercased()
        if ["general date", "short date", "long date", "medium date", "short time", "long time", "medium time"].contains(l) { return true }
        if l.contains("0") || l.contains("#") { return false }
        return l.contains("yy") || l.contains("mm") || l.contains("dd") || l.contains("hh")
    }

    public static func formatDate(_ d: Date, _ fmt: String) -> String {
        formatDate(d, fmt, culture: culture)
    }

    public static func formatDate(_ d: Date, _ fmt: String, culture c: FormatCulture) -> String {
        let hasTime = d.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) != 0
        let pattern: String
        switch fmt.lowercased() {
        case "": pattern = hasTime ? "d MMM yyyy HH:mm" : "d MMM yyyy"
        case "general date":
            pattern = c.isUS ? (hasTime ? "M/d/yyyy h:mm:ss a" : "M/d/yyyy")
                : c.datePattern("ddMMyyyy") + (hasTime ? " " + c.datePattern("jjmmss") : "")
        case "short date": pattern = c.isUS ? "M/d/yyyy" : c.datePattern("ddMMyyyy")
        case "medium date": pattern = c.isUS ? "d MMM yyyy" : c.datePattern("dMMMyyyy")
        case "long date": pattern = c.isUS ? "EEEE, MMMM d, yyyy" : c.datePattern("EEEEdMMMMyyyy")
        case "short time": pattern = c.isUS ? "HH:mm" : c.datePattern("HHmm")
        case "medium time": pattern = c.isUS ? "h:mm a" : c.datePattern("jjmm")
        case "long time": pattern = c.isUS ? "h:mm:ss a" : c.datePattern("jjmmss")
        default: pattern = translateDatePattern(fmt)
        }
        return c.isUS ? DateParsing.string(d, format: pattern) : DateParsing.string(d, format: pattern, locale: c.locale)
    }

    /// Translate an Excel/DAX date pattern (case-insensitive, "m" ambiguous) to a Unicode pattern.
    static func translateDatePattern(_ fmt: String) -> String {
        var out = ""
        let chars = Array(fmt)
        var i = 0
        var lastWasHour = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" || ch == "'" {
                var j = i + 1; var lit = ""
                while j < chars.count, chars[j] != ch { lit.append(chars[j]); j += 1 }
                out += "'" + lit.replacingOccurrences(of: "'", with: "''") + "'"
                i = j + 1; continue
            }
            var run = 1
            while i + run < chars.count, chars[i + run].lowercased() == ch.lowercased() { run += 1 }
            let lower = Character(ch.lowercased())
            switch lower {
            case "y": out += String(repeating: "y", count: run <= 2 ? 2 : 4); lastWasHour = false
            case "d":
                out += run >= 3 ? String(repeating: "E", count: run == 3 ? 3 : 4) : String(repeating: "d", count: run)
                lastWasHour = false
            case "m":
                // Minutes when following hours or preceding seconds; otherwise months.
                let nextIsSeconds = chars[(i + run)...].first(where: { $0.isLetter })?.lowercased() == "s"
                if (lastWasHour || nextIsSeconds) && run <= 2 && ch == "m" { out += String(repeating: "m", count: run) }
                else { out += String(repeating: "M", count: min(run, 4)) }
                lastWasHour = false
            case "h":
                let hasAMPM = fmt.lowercased().contains("am/pm") || fmt.lowercased().contains("a/p") || fmt.contains(" a")
                out += String(repeating: hasAMPM ? "h" : "H", count: min(run, 2)); lastWasHour = true
            case "s": out += String(repeating: "s", count: min(run, 2)); lastWasHour = false
            case "q": out += "Q"; lastWasHour = false
            case "a":
                let rest = String(chars[i...]).lowercased()
                if rest.hasPrefix("am/pm") { out += "a"; i += 5; continue }
                if rest.hasPrefix("a/p") { out += "a"; i += 3; continue }
                out += "a"
            default:
                if ch.isLetter { out += "'\(ch)'" } else { out.append(ch) }
            }
            i += run
        }
        return out
    }
}

/// Hex colour helpers shared by engines that can't import SwiftUI.
public enum HexColor {
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
        }
        return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    public static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
    /// Linear interpolation between two hex colours; `t` in 0…1.
    public static func lerp(_ a: String, _ b: String, _ t: Double) -> String {
        guard let x = rgb(a), let y = rgb(b) else { return a }
        let k = max(0, min(1, t))
        return hex(r: x.r + (y.r - x.r) * k, g: x.g + (y.g - x.g) * k, b: x.b + (y.b - x.b) * k)
    }
}
