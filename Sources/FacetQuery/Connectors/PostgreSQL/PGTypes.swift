import Foundation
import FacetCore

/// PostgreSQL type OIDs and value decoding (text and binary formats) into M values.
enum PGType {
    static let bool: Int32 = 16, bytea: Int32 = 17, char: Int32 = 18, name: Int32 = 19, int8: Int32 = 20, int2: Int32 = 21
    static let int4: Int32 = 23, text: Int32 = 25, oid: Int32 = 26, json: Int32 = 114, float4: Int32 = 700, float8: Int32 = 701
    static let bpchar: Int32 = 1042, varchar: Int32 = 1043, date: Int32 = 1082, time: Int32 = 1083, timestamp: Int32 = 1114
    static let timestamptz: Int32 = 1184, interval: Int32 = 1186, numeric: Int32 = 1700, uuid: Int32 = 2950, jsonb: Int32 = 3802

    /// Seconds from 1970-01-01 to PostgreSQL's epoch, 2000-01-01.
    static let epoch: Double = 946_684_800

    static func mType(_ type: Int32) -> MType {
        switch type {
        case bool: return .nullable(.logical)
        case int2: return .nullable(.number(.int16))
        case int4: return .nullable(.number(.int32))
        case int8, oid: return .nullable(.int64)
        case float4: return .nullable(.number(.single))
        case float8: return .nullable(.plainNumber)
        case numeric: return .nullable(.number(.decimal))
        case bytea: return .nullable(.binary)
        case date: return .nullable(.date)
        case time: return .nullable(.time)
        case timestamp: return .nullable(.datetime)
        case timestamptz: return .nullable(.datetimezone)
        case interval: return .nullable(.duration)
        default: return .nullable(.text)
        }
    }

    /// Types read in the binary format; everything else is read as text.
    static func readsBinary(_ type: Int32) -> Bool {
        [bool, bytea, int2, int4, int8, oid, float4, float8, numeric, date, time, timestamp, timestamptz, interval, uuid,
         text, varchar, bpchar, name, json, jsonb].contains(type)
    }

    private static func failed(_ what: String) -> MValue {
        .error(MError.dataFormat("PostgreSQL sent a \(what) value that couldn't be read."))
    }
    private static func infinite(_ what: String) -> MValue {
        .error(MError.dataFormat("The PostgreSQL \(what) 'infinity' has no M equivalent."))
    }

    /// A parameter in PostgreSQL's text input format (nil = NULL); the server infers its type from the statement.
    static func parameterText(_ v: MValue) throws -> String? {
        switch v.forcedCell() {
        case .null: return nil
        case .logical(let b): return b ? "true" : "false"
        case .number(let d): return MSyntax.number(d)
        case .text(let s):
            guard !s.contains("\u{0}") else { throw MError.dataSource("PostgreSQL text can't contain the NUL character.") }
            return s
        case .binary(let d): return "\\x" + d.hexString
        case .date(let d): return iso(d, "yyyy-MM-dd")
        case .datetime(let d): return iso(d, "yyyy-MM-dd HH:mm:ss.SSSSSS")
        case .datetimezone(let d, let offset):
            let m = abs(offset)
            return iso(d.addingTimeInterval(Double(offset) * 60), "yyyy-MM-dd HH:mm:ss.SSSSSS") + (offset < 0 ? "-" : "+") + String(format: "%02d:%02d", m / 60, m % 60)
        case .time(let s): return iso(Date(timeIntervalSince1970: s), "HH:mm:ss.SSSSSS")
        case .duration(let s): return "\(s) seconds"
        case let other: return try MConvert.text(other)
        }
    }

    private static func iso(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = pattern
        return f.string(from: d)
    }

    // MARK: Binary

    static func decodeBinary(_ type: Int32, _ d: Data) -> MValue {
        var r = ByteReader(d, what: "value")
        func exact(_ n: Int) -> Bool { d.count == n }
        switch type {
        case bool: return exact(1) ? .logical(d[d.startIndex] != 0) : failed("bool")
        case int2: return exact(2) ? .number(Double((try? r.i16BE()) ?? 0)) : failed("int2")
        case int4: return exact(4) ? .number(Double((try? r.i32BE()) ?? 0)) : failed("int4")
        case oid: return exact(4) ? .number(Double((try? r.uintBE(4)) ?? 0)) : failed("oid")
        case int8: return exact(8) ? .number(Double((try? r.i64BE()) ?? 0)) : failed("int8")
        case float4: return exact(4) ? .number(Double(Float(bitPattern: UInt32((try? r.uintBE(4)) ?? 0)))) : failed("float4")
        case float8: return exact(8) ? .number(Double(bitPattern: (try? r.uintBE(8)) ?? 0)) : failed("float8")
        case numeric: return numericBinary(d)
        case bytea: return .binary(d)
        case date:
            guard exact(4), let days = try? r.i32BE() else { return failed("date") }
            if days == Int32.max || days == Int32.min { return infinite("date") }
            return .date(Date(timeIntervalSince1970: epoch + Double(days) * 86_400))
        case time:
            guard exact(8), let us = try? r.i64BE() else { return failed("time") }
            return .time(Double(us) / 1_000_000)
        case timestamp, timestamptz:
            guard exact(8), let us = try? r.i64BE() else { return failed("timestamp") }
            if us == Int64.max || us == Int64.min { return infinite("timestamp") }
            let instant = Date(timeIntervalSince1970: epoch + Double(us) / 1_000_000)
            return type == timestamp ? .datetime(instant) : .datetimezone(instant, offsetMinutes: 0)
        case interval:
            guard exact(16), let us = try? r.i64BE(), let days = try? r.i32BE(), let months = try? r.i32BE() else { return failed("interval") }
            return .duration(Double(us) / 1_000_000 + Double(days) * 86_400 + Double(months) * 30 * 86_400)
        case uuid:
            guard exact(16) else { return failed("uuid") }
            let h = d.hexString
            let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range -> String in
                let a = h.index(h.startIndex, offsetBy: range.lowerBound), b = h.index(h.startIndex, offsetBy: range.upperBound)
                return String(h[a..<b])
            }
            return .text(parts.joined(separator: "-"))
        case jsonb:
            // Version byte 1, then the JSON text.
            guard d.first == 1 else { return failed("jsonb") }
            return utf8(d.dropFirst())
        default:
            return utf8(d)
        }
    }

    private static func utf8(_ d: Data) -> MValue {
        guard let s = String(data: d, encoding: .utf8) else { return failed("text") }
        return .text(s)
    }

    /// `numeric` binary: digit count, weight (of the first base-10000 digit), sign, display scale, digits.
    static func numericBinary(_ d: Data) -> MValue {
        var r = ByteReader(d, what: "numeric")
        guard let count = try? r.i16BE(), let weight = try? r.i16BE(), let sign = try? r.uintBE(2), (try? r.i16BE()) != nil,
              count >= 0, r.remaining == Int(count) * 2 else { return failed("numeric") }
        switch sign {
        case 0xC000: return .number(.nan)
        case 0xD000: return .number(.infinity)
        case 0xF000: return .number(-.infinity)
        case 0x0000, 0x4000: break
        default: return failed("numeric")
        }
        var digits: [Int] = []
        for _ in 0..<count {
            guard let v = try? r.i16BE(), v >= 0, v < 10_000 else { return failed("numeric") }
            digits.append(Int(v))
        }
        // Build the decimal text and let the standard parser round it once.
        var text = ""
        let w = Int(weight)
        if digits.isEmpty { return .number(0) }
        if w < 0 {
            text = "0." + String(repeating: "0000", count: -w - 1)
            for v in digits { text += String(format: "%04d", v) }
        } else {
            for i in 0...w { text += i < digits.count ? (i == 0 ? String(digits[i]) : String(format: "%04d", digits[i])) : "0000" }
            if digits.count > w + 1 {
                text += "."
                for v in digits[(w + 1)...] { text += String(format: "%04d", v) }
            }
        }
        guard let value = Double(text) else { return failed("numeric") }
        return .number(sign == 0x4000 ? -value : value)
    }

    // MARK: Text

    static func decodeText(_ type: Int32, _ s: String) -> MValue {
        switch type {
        case bool: return s == "t" ? .logical(true) : s == "f" ? .logical(false) : failed("bool")
        case int2, int4, int8, oid, float4, float8, numeric:
            switch s {
            case "NaN": return .number(.nan)
            case "Infinity": return .number(.infinity)
            case "-Infinity": return .number(-.infinity)
            default: return Double(s).map(MValue.number) ?? failed("number")
            }
        case bytea:
            guard s.hasPrefix("\\x"), let d = Data(hex: String(s.dropFirst(2))) else { return failed("bytea") }
            return .binary(d)
        case date:
            if s == "infinity" || s == "-infinity" { return infinite("date") }
            return PGText.date(s).map(MValue.date) ?? failed("date")
        case time: return PGText.seconds(ofTime: s).map(MValue.time) ?? failed("time")
        case timestamp:
            if s.hasSuffix("infinity") { return infinite("timestamp") }
            return PGText.timestamp(s).map { .datetime($0.wall) } ?? failed("timestamp")
        case timestamptz:
            if s.hasSuffix("infinity") { return infinite("timestamp") }
            guard let t = PGText.timestamp(s), let offset = t.offsetMinutes else { return failed("timestamptz") }
            return .datetimezone(t.wall.addingTimeInterval(-Double(offset) * 60), offsetMinutes: offset)
        case interval: return PGText.interval(s).map(MValue.duration) ?? failed("interval")
        default: return .text(s)
        }
    }
}

/// Parsers for PostgreSQL's text output with `DateStyle = ISO` and the default `IntervalStyle = postgres`.
enum PGText {
    static func date(_ s: String) -> Date? {
        let p = s.split(separator: "-")
        guard p.count == 3, p[0].count >= 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return try? MLibrary.makeDate(y, m, d)
    }
    /// `HH:MM:SS[.ffffff]` as seconds.
    static func seconds(ofTime s: String) -> Double? {
        let p = s.split(separator: ":")
        guard p.count == 3, let h = Int(p[0]), let m = Int(p[1]), let sec = Double(p[2]), h >= 0, m >= 0, m < 60, sec >= 0, sec < 61 else { return nil }
        return Double(h) * 3600 + Double(m) * 60 + sec
    }
    /// `YYYY-MM-DD HH:MM:SS[.ffffff][±HH[:MM[:SS]]]`: wall-clock time and the offset in minutes, if any.
    static func timestamp(_ s: String) -> (wall: Date, offsetMinutes: Int?)? {
        let parts = s.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let day = date(String(parts[0])) else { return nil }
        var clock = String(parts[1]), offset: Int?
        if let i = clock.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = clock[clock.index(after: i)...].split(separator: ":").compactMap { Int($0) }
            guard (1...3).contains(zone.count) else { return nil }
            let minutes = zone[0] * 60 + (zone.count > 1 ? zone[1] : 0)
            offset = clock[i] == "-" ? -minutes : minutes
            clock = String(clock[..<i])
        }
        guard let t = seconds(ofTime: clock) else { return nil }
        return (day.addingTimeInterval(t), offset)
    }
    /// `[N year[s]] [N mon[s]] [N day[s]] [[-]HH:MM:SS[.f]]` as seconds (a month counts as 30 days).
    static func interval(_ s: String) -> Double? {
        let tokens = s.split(separator: " ").map(String.init)
        var total = 0.0, i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.contains(":") {
                let negative = t.hasPrefix("-")
                guard let secs = seconds(ofTime: negative || t.hasPrefix("+") ? String(t.dropFirst()) : t) else { return nil }
                total += negative ? -secs : secs
                i += 1
                continue
            }
            guard i + 1 < tokens.count, let n = Double(t) else { return nil }
            let unit = tokens[i + 1]
            switch true {
            case unit.hasPrefix("year"): total += n * 360 * 86_400
            case unit.hasPrefix("mon"): total += n * 30 * 86_400
            case unit.hasPrefix("day"): total += n * 86_400
            default: return nil
            }
            i += 2
        }
        return tokens.isEmpty ? nil : total
    }
}
