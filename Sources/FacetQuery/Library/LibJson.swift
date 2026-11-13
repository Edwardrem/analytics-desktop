import Foundation
import FacetCore

/// A JSON reader that keeps object fields in document order (M records are ordered).
struct JsonParser {
    private let u: [UInt8]
    private var i = 0
    private var depth = 0
    static let maxDepth = 512

    init(_ data: Data) { u = [UInt8](data) }

    static func parse(_ data: Data) throws -> MValue {
        var p = JsonParser(data)
        if p.u.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        p.skipSpace()
        guard p.i < p.u.count else { throw MError.dataFormat("The JSON document is empty.") }
        let v = try p.value()
        p.skipSpace()
        if p.i < p.u.count { throw p.fail("We found extra characters at the end of the JSON input") }
        return v
    }

    private func fail(_ what: String) -> MError { MError.dataFormat("\(what) (position \(i)).") }
    private mutating func skipSpace() { while i < u.count, u[i] == 32 || u[i] == 9 || u[i] == 10 || u[i] == 13 { i += 1 } }
    private mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= u.count, Array(u[i..<(i + w.count)]) == w else { throw fail("We found an unexpected character in the JSON input") }
        i += w.count
    }

    private mutating func value() throws -> MValue {
        guard i < u.count else { throw fail("We reached the end of the buffer while reading the JSON input") }
        switch u[i] {
        case UInt8(ascii: "{"):
            depth += 1; defer { depth -= 1 }
            if depth > JsonParser.maxDepth { throw fail("The JSON input is nested too deeply") }
            i += 1
            var names: [String] = [], values: [MValue] = [], seen: [String: Int] = [:]
            skipSpace()
            if i < u.count, u[i] == UInt8(ascii: "}") { i += 1; return .record(.empty) }
            while true {
                skipSpace()
                guard i < u.count, u[i] == UInt8(ascii: "\"") else { throw fail("We expected a field name in the JSON input") }
                let name = try string()
                skipSpace()
                guard i < u.count, u[i] == UInt8(ascii: ":") else { throw fail("We expected ':' in the JSON input") }
                i += 1; skipSpace()
                let v = try value()
                if let at = seen[name] { values[at] = v } else { seen[name] = names.count; names.append(name); values.append(v) }
                skipSpace()
                guard i < u.count else { throw fail("We reached the end of the buffer while reading the JSON input") }
                if u[i] == UInt8(ascii: ",") { i += 1; continue }
                if u[i] == UInt8(ascii: "}") { i += 1; break }
                throw fail("We expected ',' or '}' in the JSON input")
            }
            return .record(MRecord(names: names, values: values))
        case UInt8(ascii: "["):
            depth += 1; defer { depth -= 1 }
            if depth > JsonParser.maxDepth { throw fail("The JSON input is nested too deeply") }
            i += 1
            var items: [MValue] = []
            skipSpace()
            if i < u.count, u[i] == UInt8(ascii: "]") { i += 1; return .list([]) }
            while true {
                skipSpace()
                items.append(try value())
                skipSpace()
                guard i < u.count else { throw fail("We reached the end of the buffer while reading the JSON input") }
                if u[i] == UInt8(ascii: ",") { i += 1; continue }
                if u[i] == UInt8(ascii: "]") { i += 1; break }
                throw fail("We expected ',' or ']' in the JSON input")
            }
            return .list(items)
        case UInt8(ascii: "\""): return .text(try string())
        case UInt8(ascii: "t"): try expect("true"); return .logical(true)
        case UInt8(ascii: "f"): try expect("false"); return .logical(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default:
            let start = i
            while i < u.count, "+-0123456789.eE".utf8.contains(u[i]) { i += 1 }
            guard i > start, let d = Double(String(decoding: u[start..<i], as: UTF8.self)) else {
                i = start
                throw fail("We found an unexpected character in the JSON input")
            }
            return .number(d)
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= u.count, let v = UInt32(String(decoding: u[i..<(i + 4)], as: UTF8.self), radix: 16) else { throw fail("The JSON input has an invalid \\u escape") }
        i += 4
        return v
    }
    private mutating func string() throws -> String {
        i += 1 // opening quote
        var out: [UInt8] = []
        while true {
            guard i < u.count else { throw fail("We reached the end of the buffer inside a JSON string") }
            let b = u[i]
            if b == UInt8(ascii: "\"") { i += 1; break }
            if b != UInt8(ascii: "\\") { out.append(b); i += 1; continue }
            i += 1
            guard i < u.count else { throw fail("We reached the end of the buffer inside a JSON string") }
            let e = u[i]; i += 1
            switch e {
            case UInt8(ascii: "n"): out.append(10)
            case UInt8(ascii: "t"): out.append(9)
            case UInt8(ascii: "r"): out.append(13)
            case UInt8(ascii: "b"): out.append(8)
            case UInt8(ascii: "f"): out.append(12)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), i + 1 < u.count, u[i] == UInt8(ascii: "\\"), u[i + 1] == UInt8(ascii: "u") {
                    i += 2
                    let low = try hex4()
                    code = 0x10000 + ((code - 0xD800) << 10) + (low &- 0xDC00)
                }
                out.append(contentsOf: Array(String(Character(Unicode.Scalar(code) ?? "\u{FFFD}")).utf8))
            default: out.append(e) // \" \\ \/
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Serialise an M value as JSON text (`Json.FromValue`).
    static func write(_ v: MValue) throws -> String {
        switch try v.forced() {
        case .null: return "null"
        case .logical(let b): return b ? "true" : "false"
        case .number(let d):
            guard d.isFinite else { return "\"\(d.isNaN ? "NaN" : (d > 0 ? "Infinity" : "-Infinity"))\"" }
            return MSyntax.number(d)
        case .text(let s): return quote(s)
        case .list(let l): return "[" + (try l.map(write)).joined(separator: ",") + "]"
        case .record(let r): return "{" + (try zip(r.names, r.forcedValues()).map { quote($0) + ":" + (try write($1)) }).joined(separator: ",") + "}"
        case .table(let t): return "[" + (try t.records().map { try write(.record($0)) }).joined(separator: ",") + "]"
        case .date(let d): return quote(MConvert.formatDate(d, format: "yyyy-MM-dd"))
        case .datetime(let d): return quote(MConvert.formatDate(d, format: "yyyy-MM-ddTHH:mm:ss"))
        case .datetimezone(let d, let off):
            return quote(MConvert.formatDate(d.addingTimeInterval(Double(off) * 60), format: "yyyy-MM-ddTHH:mm:ss") + MConvert.offsetText(off))
        case .time(let t): return quote(MConvert.formatDate(Date(timeIntervalSince1970: t), format: "HH:mm:ss"))
        case .duration(let s): return quote(MConvert.durationText(s))
        case .binary(let d): return quote(d.base64EncodedString())
        case let other: throw MError("A value of type \(other.typeName) can't be written as JSON.")
        }
    }
    private static func quote(_ s: String) -> String {
        var out = "\""
        for sc in s.unicodeScalars {
            switch sc {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if sc.value < 32 { out += String(format: "\\u%04x", sc.value) } else { out.unicodeScalars.append(sc) }
            }
        }
        return out + "\""
    }
}

extension MLibrary {
    static func registerJson(_ lib: MLibrary) {
        lib.fn("Json.Document", 1...2) { a, ctx in
            var data: Data
            if case .text(let s) = a[0] { data = Data(s.utf8) } else {
                data = try a.binary(0)
                if let cp = try a.optInt(1), cp != 65001 { data = Data(try MText.decode(data, codePage: cp).utf8) }
                else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { data = Data(try MText.decode(data, codePage: nil).utf8) }
            }
            try ctx.checkSize(data.count, of: "The JSON document")
            return try JsonParser.parse(data)
        }
        lib.fn("Json.FromValue", 1...2) { a, _ in .binary(try MText.encode(try JsonParser.write(a[0]), codePage: try a.optInt(1))) }
    }
}
