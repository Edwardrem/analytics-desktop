import Foundation

/// A column's TYPE_INFO (MS-TDS 2.2.5.6).
struct TDSTypeInfo: Equatable {
    var code: UInt8
    var maxLength = 0
    var precision: UInt8 = 0
    var scale: UInt8 = 0
    /// The 5-byte collation of character types.
    var collation: [UInt8]?
    /// Partially length-prefixed: `(max)` types, xml and CLR types.
    var isPLP = false

    enum Code {
        static let null: UInt8 = 0x1F, int1: UInt8 = 0x30, bit: UInt8 = 0x32, int2: UInt8 = 0x34, int4: UInt8 = 0x38
        static let datetime4: UInt8 = 0x3A, float4: UInt8 = 0x3B, money: UInt8 = 0x3C, datetime: UInt8 = 0x3D
        static let float8: UInt8 = 0x3E, money4: UInt8 = 0x7A, int8: UInt8 = 0x7F
        static let guid: UInt8 = 0x24, intN: UInt8 = 0x26, decimal: UInt8 = 0x37, numeric: UInt8 = 0x3F
        static let bitN: UInt8 = 0x68, decimalN: UInt8 = 0x6A, numericN: UInt8 = 0x6C, floatN: UInt8 = 0x6D
        static let moneyN: UInt8 = 0x6E, datetimeN: UInt8 = 0x6F
        static let date: UInt8 = 0x28, time: UInt8 = 0x29, datetime2: UInt8 = 0x2A, datetimeOffset: UInt8 = 0x2B
        static let char: UInt8 = 0x2F, varchar: UInt8 = 0x27, binary: UInt8 = 0x2D, varbinary: UInt8 = 0x25
        static let bigVarBinary: UInt8 = 0xA5, bigVarChar: UInt8 = 0xA7, bigBinary: UInt8 = 0xAD, bigChar: UInt8 = 0xAF
        static let nvarchar: UInt8 = 0xE7, nchar: UInt8 = 0xEF, text: UInt8 = 0x23, ntext: UInt8 = 0x63, image: UInt8 = 0x22
        static let xml: UInt8 = 0xF1, udt: UInt8 = 0xF0, variant: UInt8 = 0x62
    }

    /// Byte size of the fixed-length types.
    static func fixedSize(_ code: UInt8) -> Int? {
        switch code {
        case Code.null: return 0
        case Code.int1, Code.bit: return 1
        case Code.int2: return 2
        case Code.int4, Code.datetime4, Code.float4, Code.money4: return 4
        case Code.money, Code.datetime, Code.float8, Code.int8: return 8
        default: return nil
        }
    }

    var isLongLength: Bool { [Code.text, Code.ntext, Code.image].contains(code) }

    static func read(_ r: TDSMessageReader) throws -> TDSTypeInfo {
        var t = TDSTypeInfo(code: try r.u8())
        if let size = fixedSize(t.code) { t.maxLength = size; return t }
        switch t.code {
        case Code.guid, Code.intN, Code.bitN, Code.floatN, Code.moneyN, Code.datetimeN, Code.char, Code.varchar, Code.binary, Code.varbinary:
            t.maxLength = Int(try r.u8())
        case Code.decimal, Code.numeric, Code.decimalN, Code.numericN:
            t.maxLength = Int(try r.u8()); t.precision = try r.u8(); t.scale = try r.u8()
            guard t.maxLength <= 17, t.scale <= 38 else { throw TDSError.protocolViolation("decimal length") }
        case Code.date: t.maxLength = 3
        case Code.time, Code.datetime2, Code.datetimeOffset:
            t.scale = try r.u8()
            guard t.scale <= 7 else { throw TDSError.protocolViolation("time scale \(t.scale)") }
        case Code.bigVarBinary, Code.bigBinary:
            t.maxLength = Int(try r.u16()); t.isPLP = t.maxLength == 0xFFFF
        case Code.bigVarChar, Code.bigChar, Code.nvarchar, Code.nchar:
            t.maxLength = Int(try r.u16()); t.isPLP = t.maxLength == 0xFFFF
            t.collation = try r.bytes(5)
        case Code.text, Code.ntext:
            t.maxLength = Int(try r.u32()); t.collation = try r.bytes(5)
        case Code.image:
            t.maxLength = Int(try r.u32())
        case Code.xml:
            if try r.u8() == 1 { _ = try r.bVarchar(); _ = try r.bVarchar(); _ = try r.usVarchar() }
            t.isPLP = true
        case Code.udt:
            t.maxLength = Int(try r.u16())
            for _ in 0..<3 { _ = try r.bVarchar() }
            _ = try r.usVarchar()
            t.isPLP = true
        case Code.variant:
            t.maxLength = Int(try r.u32())
        default:
            throw TDSError(kind: .unsupported, message: "The server returned a column of an unknown type (0x\(String(t.code, radix: 16))).")
        }
        return t
    }

    /// The M type of a column of this type.
    var mType: MType {
        switch code {
        case Code.int1: return .number(.byte)
        case Code.int2: return .number(.int16)
        case Code.int4: return .number(.int32)
        case Code.int8: return .int64
        case Code.intN:
            switch maxLength { case 1: return .number(.byte); case 2: return .number(.int16); case 4: return .number(.int32); default: return .int64 }
        case Code.bit, Code.bitN: return .logical
        case Code.float4: return .number(.single)
        case Code.float8: return .plainNumber
        case Code.floatN: return maxLength == 4 ? .number(.single) : .plainNumber
        case Code.money, Code.money4, Code.moneyN: return .number(.currency)
        case Code.decimal, Code.numeric, Code.decimalN, Code.numericN: return .number(.decimal)
        case Code.datetime, Code.datetime4, Code.datetimeN, Code.datetime2: return .datetime
        case Code.date: return .date
        case Code.time: return .time
        case Code.datetimeOffset: return .datetimezone
        case Code.guid, Code.char, Code.varchar, Code.bigVarChar, Code.bigChar, Code.nvarchar, Code.nchar, Code.text, Code.ntext, Code.xml:
            return .text
        case Code.binary, Code.varbinary, Code.bigVarBinary, Code.bigBinary, Code.image, Code.udt: return .binary
        default: return .any
        }
    }
}

/// Decodes column values from a row. Every length is checked against the type's limits before it is read.
enum TDSValues {
    /// Largest single value (a `(max)` column) this client accepts.
    static let maxValueBytes = 1 << 30

    static func read(_ t: TDSTypeInfo, _ r: TDSMessageReader) throws -> MValue {
        guard let bytes = try readBytes(t, r) else { return .null }
        return try convert(t, bytes)
    }

    /// The raw bytes of one value, or nil for null.
    static func readBytes(_ t: TDSTypeInfo, _ r: TDSMessageReader) throws -> [UInt8]? {
        typealias C = TDSTypeInfo.Code
        if t.isPLP { return try readPLP(r) }
        if let size = TDSTypeInfo.fixedSize(t.code) { return t.code == C.null ? nil : try r.bytes(size) }
        switch t.code {
        case C.bigVarBinary, C.bigBinary, C.bigVarChar, C.bigChar, C.nvarchar, C.nchar:
            let n = Int(try r.u16())
            if n == 0xFFFF { return nil }
            guard n <= max(t.maxLength, 8000) else { throw TDSError.protocolViolation("value length \(n)") }
            return try r.bytes(n)
        case C.text, C.ntext, C.image:
            let pointer = Int(try r.u8())
            if pointer == 0 { return nil }
            try r.skip(pointer + 8)                                   // text pointer + timestamp
            let n = Int(try r.i32())
            guard n >= 0, n <= maxValueBytes else { throw TDSError.protocolViolation("text length \(n)") }
            return try r.bytes(n)
        case C.variant:
            let n = Int(try r.u32())
            if n == 0 { return nil }
            guard n <= 8016 else { throw TDSError.protocolViolation("sql_variant length \(n)") }
            return try r.bytes(n)
        case C.varchar, C.char, C.varbinary, C.binary:
            let n = Int(try r.u8())
            if n == 0xFF { return nil }
            return try r.bytes(n)
        default:
            // BYTELEN types and the date/time types: one length byte, 0 = null.
            let n = Int(try r.u8())
            if n == 0 { return nil }
            guard n <= 17 else { throw TDSError.protocolViolation("value length \(n) for type 0x\(String(t.code, radix: 16))") }
            return try r.bytes(n)
        }
    }

    static func readPLP(_ r: TDSMessageReader) throws -> [UInt8]? {
        let total = try r.u64()
        if total == UInt64.max { return nil }
        guard total == UInt64.max - 1 || total <= UInt64(maxValueBytes) else { throw TDSError.protocolViolation("PLP length \(total)") }
        var out: [UInt8] = []
        if total != UInt64.max - 1 { out.reserveCapacity(Int(total)) }
        while true {
            let chunk = Int(try r.u32())
            if chunk == 0 { break }
            guard out.count + chunk <= maxValueBytes else { throw TDSError.protocolViolation("PLP chunk") }
            out += try r.bytes(chunk)
        }
        if total != UInt64.max - 1, out.count != Int(total) { throw TDSError.protocolViolation("PLP length mismatch") }
        return out
    }

    private static func int(_ b: [UInt8]) -> Int64 {
        // Little-endian two's complement of 1, 2, 4 or 8 bytes.
        var v: UInt64 = 0
        for (i, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(i)) }
        switch b.count {
        case 2: return Int64(Int16(truncatingIfNeeded: v))
        case 4: return Int64(Int32(truncatingIfNeeded: v))
        case 8: return Int64(bitPattern: v)
        default: return Int64(v)
        }
    }
    private static func unsigned(_ b: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for (i, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(i)) }
        return v
    }

    /// Days from 0001-01-01 to 1970-01-01 in the proleptic Gregorian calendar.
    static let unixEpochDay = 719_162
    /// Days from 0001-01-01 to 1900-01-01, the base of `datetime` and `smalldatetime`.
    static let datetimeEpochDay = 693_595

    static func date(days: Int, seconds: Double = 0) -> Date {
        Date(timeIntervalSince1970: Double(days - unixEpochDay) * 86_400 + seconds)
    }
    private static func timeSeconds(_ b: ArraySlice<UInt8>, scale: UInt8) -> Double {
        Double(unsigned(b)) / pow(10, Double(scale))
    }
    static func timeLength(scale: UInt8) -> Int { scale <= 2 ? 3 : scale <= 4 ? 4 : 5 }

    static func convert(_ t: TDSTypeInfo, _ b: [UInt8]) throws -> MValue {
        typealias C = TDSTypeInfo.Code
        func expect(_ sizes: Set<Int>) throws {
            guard sizes.contains(b.count) else { throw TDSError.protocolViolation("value of \(b.count) bytes for type 0x\(String(t.code, radix: 16))") }
        }
        switch t.code {
        case C.int1, C.int2, C.int4, C.int8, C.intN:
            try expect([1, 2, 4, 8])
            return .number(Double(int(b)))
        case C.bit, C.bitN: try expect([1]); return .logical(b[0] != 0)
        case C.float4, C.float8, C.floatN:
            try expect([4, 8])
            let bits = unsigned(b[...])
            return .number(b.count == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits))
        case C.money, C.money4, C.moneyN:
            try expect([4, 8])
            let raw = b.count == 4 ? Int64(int(b)) : Int64(int(Array(b[0..<4]))) << 32 | Int64(unsigned(b[4..<8]))
            return .number(NSDecimalNumber(decimal: Decimal(raw) / 10_000).doubleValue)
        case C.decimal, C.numeric, C.decimalN, C.numericN:
            guard b.count >= 2, b.count <= 17 else { throw TDSError.protocolViolation("decimal of \(b.count) bytes") }
            var magnitude = Decimal(0)
            for x in b[1...].reversed() { magnitude = magnitude * 256 + Decimal(Int(x)) }
            var value = Decimal(sign: b[0] == 1 ? .plus : .minus, exponent: -Int(t.scale), significand: magnitude)
            if b[0] != 1, magnitude == 0 { value = 0 }
            return .number(NSDecimalNumber(decimal: value).doubleValue)
        case C.datetimeN where b.count == 4, C.datetime4:
            try expect([4])
            let days = Int(unsigned(b[0..<2])), minutes = Int(unsigned(b[2..<4]))
            return .datetime(date(days: datetimeEpochDay + days, seconds: Double(minutes * 60)))
        case C.datetime, C.datetimeN:
            try expect([8])
            let days = Int(int(Array(b[0..<4]))), ticks = unsigned(b[4..<8])
            // Ticks are 1/300 s; SQL Server rounds them to .000, .003 or .007.
            let seconds = (Double(ticks) * 10 / 3).rounded() / 1000
            return .datetime(date(days: datetimeEpochDay + days, seconds: seconds))
        case C.date:
            try expect([3])
            return .date(date(days: Int(unsigned(b[...]))))
        case C.time:
            try expect([timeLength(scale: t.scale)])
            return .time(timeSeconds(b[...], scale: t.scale))
        case C.datetime2:
            let tl = timeLength(scale: t.scale)
            try expect([tl + 3])
            return .datetime(date(days: Int(unsigned(b[tl...])), seconds: timeSeconds(b[..<tl], scale: t.scale)))
        case C.datetimeOffset:
            let tl = timeLength(scale: t.scale)
            try expect([tl + 5])
            let utc = date(days: Int(unsigned(b[tl..<tl + 3])), seconds: timeSeconds(b[..<tl], scale: t.scale))
            return .datetimezone(utc, offsetMinutes: Int(int(Array(b[(tl + 3)...]))))
        case C.guid:
            try expect([16])
            let order = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
            var s = ""
            for (i, k) in order.enumerated() {
                if [4, 6, 8, 10].contains(i) { s += "-" }
                s += String(format: "%02x", b[k])
            }
            return .text(s)
        case C.nvarchar, C.nchar, C.ntext, C.xml:
            return .text(TDSText.utf16(b))
        case C.bigVarChar, C.bigChar, C.text, C.varchar, C.char:
            return .text(TDSCollation.decode(b, collation: t.collation))
        case C.bigVarBinary, C.bigBinary, C.image, C.varbinary, C.binary, C.udt:
            return .binary(Data(b))
        case C.variant:
            return try variant(b)
        default:
            throw TDSError(kind: .unsupported, message: "Values of type 0x\(String(t.code, radix: 16)) can't be read.")
        }
    }

    /// sql_variant: base type, property bytes, then the value without a length prefix.
    private static func variant(_ b: [UInt8]) throws -> MValue {
        guard b.count >= 2 else { throw TDSError.protocolViolation("sql_variant header") }
        let code = b[0], propCount = Int(b[1])
        guard 2 + propCount <= b.count else { throw TDSError.protocolViolation("sql_variant properties") }
        let props = Array(b[2..<2 + propCount]), value = Array(b[(2 + propCount)...])
        var t = TDSTypeInfo(code: code)
        typealias C = TDSTypeInfo.Code
        switch code {
        case C.decimalN, C.numericN: guard props.count == 2 else { throw TDSError.protocolViolation("sql_variant decimal") }; t.precision = props[0]; t.scale = props[1]
        case C.time, C.datetime2, C.datetimeOffset: guard props.count == 1, props[0] <= 7 else { throw TDSError.protocolViolation("sql_variant time") }; t.scale = props[0]
        case C.bigVarChar, C.bigChar, C.nvarchar, C.nchar: guard props.count == 7 else { throw TDSError.protocolViolation("sql_variant text") }; t.collation = Array(props[0..<5])
        default: break
        }
        return try convert(t, value)
    }
}

/// Code pages of SQL Server collations, for `char`/`varchar`/`text` columns.
enum TDSCollation {
    static func codePage(_ collation: [UInt8]?) -> UInt32? {
        guard let c = collation, c.count == 5 else { return 1252 }
        let info = UInt32(c[0]) | UInt32(c[1]) << 8 | UInt32(c[2]) << 16 | UInt32(c[3]) << 24
        if info & (1 << 26) != 0 { return nil }                      // UTF-8 collation
        let sortId = c[4]
        if sortId != 0 {
            switch sortId {
            case 30...34: return 437
            case 40...49: return 850
            case 80...98: return 1250
            case 104...108: return 1251
            case 112...124: return 1253
            case 128...130: return 1254
            case 136...138: return 1255
            case 144...146: return 1256
            case 152...160: return 1257
            default: return 1252
            }
        }
        let lcid = info & 0xFFFFF, language = lcid & 0x3FF
        switch language {
        case 0x05, 0x0E, 0x15, 0x18, 0x1A, 0x1B, 0x1C, 0x24: return 1250
        case 0x02, 0x19, 0x22, 0x23, 0x2F, 0x3F, 0x44: return 1251
        case 0x08: return 1253
        case 0x1F, 0x2C, 0x43: return 1254
        case 0x0D: return 1255
        case 0x01, 0x20, 0x29: return 1256
        case 0x25, 0x26, 0x27: return 1257
        case 0x2A: return 1258
        case 0x1E: return 874
        case 0x11: return 932
        case 0x12: return 949
        case 0x04: return [0x0804, 0x1004].contains(lcid) ? 936 : 950
        default: return 1252
        }
    }

    static func decode(_ bytes: [UInt8], collation: [UInt8]?) -> String {
        guard let page = codePage(collation) else { return String(decoding: bytes, as: UTF8.self) }
        let cf = CFStringConvertWindowsCodepageToEncoding(page)
        if cf != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(data: Data(bytes), encoding: encoding) { return s }
        }
        return String(data: Data(bytes), encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}
