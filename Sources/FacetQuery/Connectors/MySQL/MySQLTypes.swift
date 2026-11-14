import Foundation

/// MySQL column types and value decoding (text and binary protocol) into M values.
enum MySQLType {
    static let decimal: UInt8 = 0, tiny: UInt8 = 1, short: UInt8 = 2, long: UInt8 = 3, float: UInt8 = 4, double: UInt8 = 5
    static let null: UInt8 = 6, timestamp: UInt8 = 7, longlong: UInt8 = 8, int24: UInt8 = 9, date: UInt8 = 10, time: UInt8 = 11
    static let datetime: UInt8 = 12, year: UInt8 = 13, varchar: UInt8 = 15, bit: UInt8 = 16, json: UInt8 = 245
    static let newDecimal: UInt8 = 246, blob: UInt8 = 252, varString: UInt8 = 253, string: UInt8 = 254, geometry: UInt8 = 255

    /// TINYINT(1) reads as logical, as Connector/NET does by default; BIT(1) too.
    private static func isFlag(_ c: MySQLProtocol.Column) -> Bool {
        (c.type == tiny && c.length == 1) || (c.type == bit && c.length == 1)
    }

    static func mType(_ c: MySQLProtocol.Column) -> MType {
        if isFlag(c) { return .nullable(.logical) }
        switch c.type {
        case tiny: return .nullable(.number(c.isUnsigned ? .byte : .int8))
        case short, year: return .nullable(.number(.int16))
        case long, int24: return .nullable(.number(c.isUnsigned ? .int64 : .int32))
        case longlong: return .nullable(.int64)
        case float: return .nullable(.number(.single))
        case double: return .nullable(.plainNumber)
        case decimal, newDecimal: return .nullable(.number(.decimal))
        case date: return .nullable(.date)
        case datetime, timestamp: return .nullable(.datetime)
        case time: return .nullable(.time)
        case bit, geometry: return .nullable(.binary)
        case json: return .nullable(.text)
        default: return c.isBinary ? .nullable(.binary) : .nullable(.text)
        }
    }

    private static func failed(_ what: String) -> MValue { .error(MError.dataFormat("MySQL sent a \(what) value that couldn't be read.")) }

    private static func bitValue(_ d: Data, _ c: MySQLProtocol.Column) -> MValue {
        isFlag(c) ? .logical(d.contains { $0 != 0 }) : .binary(d)
    }

    // MARK: Text protocol

    static func decodeText(_ c: MySQLProtocol.Column, _ d: Data) -> MValue {
        if c.type == bit { return bitValue(d, c) }
        if c.type == geometry || (c.isBinary && ![tiny, short, long, int24, longlong, float, double, decimal, newDecimal, year,
                                                  date, datetime, timestamp, time].contains(c.type)) {
            return .binary(d)
        }
        guard let s = String(data: d, encoding: .utf8) else { return failed("text") }
        switch c.type {
        case tiny where isFlag(c): return s == "0" ? .logical(false) : .logical(true)
        case tiny, short, long, int24, longlong, year, float, double, decimal, newDecimal:
            return Double(s).map(MValue.number) ?? failed("number")
        case date:
            if s.hasPrefix("0000-00-00") { return .null }
            return PGText.date(s).map(MValue.date) ?? failed("date")
        case datetime, timestamp:
            if s.hasPrefix("0000-00-00") { return .null }
            if !s.contains(" ") { return PGText.date(s).map(MValue.datetime) ?? failed("datetime") }
            return PGText.timestamp(s).map { .datetime($0.wall) } ?? failed("datetime")
        case time:
            guard let secs = timeSeconds(s) else { return failed("time") }
            return timeOfDay(secs)
        default: return .text(s)
        }
    }

    /// `[-]HHH:MM:SS[.ffffff]` as signed seconds.
    static func timeSeconds(_ s: String) -> Double? {
        let negative = s.hasPrefix("-")
        let p = (negative ? String(s.dropFirst()) : s).split(separator: ":")
        guard p.count == 3, let h = Int(p[0]), let m = Int(p[1]), let sec = Double(p[2]), h >= 0, m >= 0, m < 60, sec >= 0, sec < 60 else { return nil }
        let total = Double(h) * 3600 + Double(m) * 60 + sec
        return negative ? -total : total
    }

    /// M `time` is a time of day; a MySQL TIME outside 00:00–24:00 (an elapsed time) can't be one.
    private static func timeOfDay(_ secs: Double) -> MValue {
        guard secs >= 0, secs < 86_400 else {
            return .error(MError.dataFormat("The MySQL TIME \(MConvert.durationText(secs)) is outside a day, so it can't be an M time."))
        }
        return .time(secs)
    }

    // MARK: Binary protocol

    /// Decodes one binary-protocol value at the reader.
    static func decodeBinary(_ c: MySQLProtocol.Column, _ r: inout ByteReader) throws -> MValue {
        func int(_ n: Int) throws -> Double {
            let raw = try r.uintLE(n)
            if c.isUnsigned { return Double(raw) }
            let shift = UInt64(64 - n * 8)
            return Double(Int64(bitPattern: raw << shift) >> Int64(shift))
        }
        switch c.type {
        case tiny:
            let v = try int(1)
            return isFlag(c) ? .logical(v != 0) : .number(v)
        case short, year: return .number(try int(2))
        case long, int24: return .number(try int(4))
        case longlong: return .number(try int(8))
        case float: return .number(Double(Float(bitPattern: UInt32(try r.uintLE(4)))))
        case double: return .number(Double(bitPattern: try r.uintLE(8)))
        case date, datetime, timestamp:
            let n = Int(try r.u8())
            guard [0, 4, 7, 11].contains(n) else { throw WireError.malformed("date value") }
            if n == 0 { return .null }
            let y = Int(try r.u16LE()), mo = Int(try r.u8()), d = Int(try r.u8())
            var secs = 0.0
            if n >= 7 { secs = Double(try r.u8()) * 3600 + Double(try r.u8()) * 60 + Double(try r.u8()) }
            if n == 11 { secs += Double(try r.u32LE()) / 1_000_000 }
            if y == 0 && mo == 0 && d == 0 { return .null }
            guard let day = try? MLibrary.makeDate(y, mo, d) else { return failed("date") }
            return c.type == date ? .date(day) : .datetime(day.addingTimeInterval(secs))
        case time:
            let n = Int(try r.u8())
            guard [0, 8, 12].contains(n) else { throw WireError.malformed("time value") }
            if n == 0 { return .time(0) }
            let negative = try r.u8() != 0
            let days = Double(try r.u32LE())
            var secs = days * 86_400 + Double(try r.u8()) * 3600 + Double(try r.u8()) * 60 + Double(try r.u8())
            if n == 12 { secs += Double(try r.u32LE()) / 1_000_000 }
            return timeOfDay(negative ? -secs : secs)
        default:
            guard let bytes = try MySQLProtocol.readLenencBytes(&r) else { throw WireError.malformed("value") }
            return decodeText(c, bytes)
        }
    }

    // MARK: Parameters

    /// A prepared-statement parameter: type code, unsigned flag and value bytes (nil = NULL).
    static func parameter(_ v: MValue) throws -> (type: UInt8, value: Data?) {
        var w = ByteWriter()
        func string(_ s: String) -> (UInt8, Data?) {
            let b = Data(s.utf8)
            return (varString, MySQLProtocol.lenenc(b.count) + b)
        }
        switch v.forcedCell() {
        case .null: return (null, nil)
        case .logical(let b): w.uintLE(b ? 1 : 0, 8); return (longlong, w.data)
        case .number(let d):
            if d == d.rounded(), abs(d) < 9.0e15 { w.uintLE(UInt64(bitPattern: Int64(d)), 8); return (longlong, w.data) }
            w.uintLE(d.bitPattern, 8); return (double, w.data)
        case .text(let s): return string(s)
        case .binary(let d): return (blob, MySQLProtocol.lenenc(d.count) + d)
        case .datetimezone(let instant, _):
            // MySQL DATETIME has no zone: send the UTC time.
            return string(try PGType.parameterText(.datetime(instant)) ?? "")
        case .date, .datetime, .time:
            return string(try PGType.parameterText(v.forcedCell()) ?? "")
        case let other: return string(try MConvert.text(other))
        }
    }
}
