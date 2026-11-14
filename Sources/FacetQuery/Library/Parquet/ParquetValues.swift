import Foundation

extension ParquetReader {
    /// What a column holds, from its logical type (or the older converted type) and physical type.
    enum Meaning {
        case logical, number, integer(unsigned: Bool), decimal(scale: Int), text, binary, date
        case time(unitsPerSecond: Double), timestamp(unitsPerSecond: Double, utc: Bool), legacyTimestamp, uuid, float16
    }

    static func meaning(_ c: Column) -> Meaning {
        if let (id, v) = c.logical {
            switch id {
            case 1, 4, 12: return .text
            case 5: return .decimal(scale: v.int(1) ?? c.scale)
            case 6: return .date
            case 7: return .time(unitsPerSecond: unitsPerSecond(v.structure(2)))
            case 8: return .timestamp(unitsPerSecond: unitsPerSecond(v.structure(2)), utc: v[1]?.bool ?? false)
            case 10: return .integer(unsigned: !(v[2]?.bool ?? true))
            case 14 where c.physical == 7: return .uuid
            case 15 where c.physical == 7: return .float16
            default: break
            }
        }
        switch c.converted {
        case 0?, 4?, 19?: return .text
        case 5?: return .decimal(scale: c.scale)
        case 6?: return .date
        case 7?: return .time(unitsPerSecond: 1e3)
        case 8?: return .time(unitsPerSecond: 1e6)
        case 9?: return .timestamp(unitsPerSecond: 1e3, utc: false)
        case 10?: return .timestamp(unitsPerSecond: 1e6, utc: false)
        case 11?, 12?, 13?, 14?: return .integer(unsigned: true)
        case 15?, 16?, 17?, 18?: return .integer(unsigned: false)
        default: break
        }
        switch c.physical {
        case 0: return .logical
        case 1, 2: return .integer(unsigned: false)
        case 3: return .legacyTimestamp
        case 4, 5: return .number
        default: return .binary
        }
    }

    private static func unitsPerSecond(_ unit: ThriftStruct?) -> Double {
        switch unit?.unionMember?.id { case 1?: return 1e3; case 2?: return 1e6; case 3?: return 1e9; default: return 1e6 }
    }

    static func mType(_ c: Column) -> MType {
        let t: MType
        switch meaning(c) {
        case .logical: t = .logical
        case .integer: t = .int64
        case .number, .decimal, .float16: t = .plainNumber
        case .text, .uuid: t = .text
        case .binary: t = .binary
        case .date: t = .date
        case .time: t = .time
        case .timestamp(_, let utc): t = utc ? .datetimezone : .datetime
        case .legacyTimestamp: t = .datetime
        }
        return c.maxDefinition > 0 ? .nullable(t) : t
    }

    /// Turns a decoded physical value into an M value for the column.
    static func converter(_ c: Column) -> (Raw) -> MValue {
        let m = meaning(c)
        return { raw in
            switch (m, raw) {
            case (.logical, .bool(let b)): return .logical(b)
            case (.integer(let unsigned), .i32(let v)): return .number(unsigned ? Double(UInt32(bitPattern: v)) : Double(v))
            case (.integer(let unsigned), .i64(let v)): return .number(unsigned ? Double(UInt64(bitPattern: v)) : Double(v))
            case (.decimal(let scale), .i32(let v)): return .number(Double(v) / pow(10, Double(scale)))
            case (.decimal(let scale), .i64(let v)): return .number(Double(v) / pow(10, Double(scale)))
            case (.decimal(let scale), .bytes(let b)): return .number(bigEndianSigned(b) / pow(10, Double(scale)))
            case (_, .f32(let v)): return .number(Double(v))
            case (_, .f64(let v)): return .number(v)
            case (.date, .i32(let days)): return .date(Date(timeIntervalSince1970: Double(days) * 86_400))
            case (.time(let u), .i32(let v)): return .time(Double(v) / u)
            case (.time(let u), .i64(let v)): return .time(Double(v) / u)
            case (.timestamp(let u, let utc), .i64(let v)):
                let d = Date(timeIntervalSince1970: Double(v) / u)
                return utc ? .datetimezone(d, offsetMinutes: 0) : .datetime(d)
            case (_, .i96(let nanos, let day)):
                return .datetime(Date(timeIntervalSince1970: Double(Int64(day) - 2_440_588) * 86_400 + Double(nanos) / 1e9))
            case (.text, .bytes(let b)): return .text(String(decoding: b, as: UTF8.self))
            case (.uuid, .bytes(let b)) where b.count == 16:
                let hex = b.map { String(format: "%02x", $0) }.joined()
                let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { r -> String in
                    let lo = hex.index(hex.startIndex, offsetBy: r.lowerBound), hi = hex.index(hex.startIndex, offsetBy: r.upperBound)
                    return String(hex[lo..<hi])
                }
                return .text(parts.joined(separator: "-"))
            case (.float16, .bytes(let b)) where b.count == 2:
                let bits = UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
                return .number(Double(Float16(bitPattern: bits)))
            case (_, .bytes(let b)): return .binary(Data(b))
            case (_, .bool(let b)): return .logical(b)
            case (_, .i32(let v)): return .number(Double(v))
            case (_, .i64(let v)): return .number(Double(v))
            }
        }
    }

    /// A big-endian two's-complement integer (decimal unscaled value) as a Double.
    static func bigEndianSigned(_ b: ArraySlice<UInt8>) -> Double {
        guard let first = b.first else { return 0 }
        let negative = first & 0x80 != 0
        var v = 0.0
        for byte in b { v = v * 256 + Double(negative ? ~byte : byte) }
        return negative ? -(v + 1) : v
    }
}

extension MLibrary {
    static func registerParquet(_ lib: MLibrary) {
        lib.fn("Parquet.Document", 1...2) { a, ctx in
            let data = try sourceData(a, 0)
            try ctx.checkSize(data.count, of: "The Parquet file")
            do { return .table(try ParquetReader(data, limit: ctx.environment.maxSourceBytes).table()) }
            catch let e as ParquetReader.Unsupported { throw MError.dataFormat("Parquet.Document couldn't read the file: \(e.message).") }
            catch let e as ThriftReader.Malformed { throw MError.dataFormat("Parquet.Document couldn't read the file: its metadata is damaged (\(e.message)).") }
        }
    }
}
