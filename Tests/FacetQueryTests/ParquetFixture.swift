import Foundation
@testable import FacetQuery

enum PQThrift {
    case bool(Bool), i32(Int64), i64(Int64), bin([UInt8]), list(UInt8, [PQThrift]), strct([(Int16, PQThrift)])
    static func str(_ s: String) -> PQThrift { .bin(Array(s.utf8)) }
    var typeCode: UInt8 {
        switch self {
        case .bool(let b): return b ? 1 : 2
        case .i32: return 5
        case .i64: return 6
        case .bin: return 8
        case .list: return 9
        case .strct: return 12
        }
    }
}

/// Builds Parquet files byte by byte for the reader tests: a Thrift compact-protocol writer, the PLAIN and
/// RLE/bit-packed encoders, and page / column-chunk / footer assembly. Written from the Parquet format
/// specification (parquet-format `parquet.thrift`, Encodings.md), independently of the reader.
enum ParquetFixture {
    // MARK: Thrift compact protocol

    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }
    static func zigzag(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }

    static func encode(_ value: PQThrift) -> [UInt8] {
        switch value {
        case .bool(let b): return [b ? 1 : 0]
        case .i32(let v), .i64(let v): return varint(zigzag(v))
        case .bin(let b): return varint(UInt64(b.count)) + b
        case .list(let type, let items):
            var out: [UInt8] = items.count < 15 ? [UInt8(items.count) << 4 | type] : [0xF0 | type] + varint(UInt64(items.count))
            for i in items { out += encode(i) }
            return out
        case .strct(let fields):
            var out: [UInt8] = [], last: Int16 = 0
            for (id, v) in fields.sorted(by: { $0.0 < $1.0 }) {
                let delta = id - last
                if delta > 0, delta <= 15 { out.append(UInt8(delta) << 4 | v.typeCode) } else { out.append(v.typeCode); out += varint(zigzag(Int64(id))) }
                last = id
                if case .bool = v { continue }
                out += encode(v)
            }
            out.append(0)
            return out
        }
    }

    // MARK: Encodings

    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func le64(_ v: Int64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * Int64($0))) } }

    static func plainInt32(_ xs: [Int32]) -> [UInt8] { xs.flatMap { le32(Int($0)) } }
    static func plainInt64(_ xs: [Int64]) -> [UInt8] { xs.flatMap(le64) }
    static func plainDouble(_ xs: [Double]) -> [UInt8] { xs.flatMap { le64(Int64(bitPattern: $0.bitPattern)) } }
    static func plainStrings(_ xs: [String]) -> [UInt8] { xs.flatMap { le32($0.utf8.count) + Array($0.utf8) } }
    static func plainBools(_ xs: [Bool]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (xs.count + 7) / 8)
        for (i, b) in xs.enumerated() where b { out[i / 8] |= 1 << (i % 8) }
        return out
    }

    /// One RLE run (`count` copies of `value`).
    static func rleRun(_ value: Int, count: Int, bitWidth: Int) -> [UInt8] {
        varint(UInt64(count << 1)) + (0..<((bitWidth + 7) / 8)).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
    /// One bit-packed run; `values` is padded with zeros to a multiple of 8.
    static func bitPacked(_ values: [Int], bitWidth: Int) -> [UInt8] {
        let padded = values + [Int](repeating: 0, count: (8 - values.count % 8) % 8)
        var bits = [UInt8](repeating: 0, count: padded.count * bitWidth / 8)
        for (i, v) in padded.enumerated() {
            for k in 0..<bitWidth where (v >> k) & 1 == 1 {
                let bit = i * bitWidth + k
                bits[bit / 8] |= 1 << (bit % 8)
            }
        }
        return varint(UInt64((padded.count / 8) << 1 | 1)) + bits
    }

    // MARK: Files

    struct Page {
        var header: [(Int16, PQThrift)]
        var body: [UInt8]
        init(_ header: [(Int16, PQThrift)], _ body: [UInt8]) { self.header = header; self.body = body }
    }

    struct Column {
        var name: String
        var physical: Int64
        var optional: Bool
        var converted: Int64?
        var logical: [(Int16, PQThrift)]?
        var scale: Int64?
        var typeLength: Int64?
        /// Each page's header fields and (already compressed) body, in file order.
        var pages: [Page] = []
        var codec: Int64 = 0
        var valueCount: Int64 = 0
        init(name: String, physical: Int64, optional: Bool = false, converted: Int64? = nil, logical: [(Int16, PQThrift)]? = nil,
             scale: Int64? = nil, typeLength: Int64? = nil) {
            self.name = name; self.physical = physical; self.optional = optional; self.converted = converted
            self.logical = logical; self.scale = scale; self.typeLength = typeLength
        }
    }

    static func dataPageV1(count: Int, encoding: Int64 = 0, body: [UInt8], uncompressed: Int? = nil) -> Page {
        Page([(1, .i32(0)), (2, .i32(Int64(uncompressed ?? body.count))), (3, .i32(Int64(body.count))),
              (5, .strct([(1, .i32(Int64(count))), (2, .i32(encoding)), (3, .i32(3)), (4, .i32(3))]))], body)
    }
    static func dictionaryPage(count: Int, body: [UInt8], uncompressed: Int? = nil) -> Page {
        Page([(1, .i32(2)), (2, .i32(Int64(uncompressed ?? body.count))), (3, .i32(Int64(body.count))),
              (7, .strct([(1, .i32(Int64(count))), (2, .i32(0))]))], body)
    }

    /// A file with one row group per entry of `rowGroups` (each a list of columns with their pages).
    static func file(schema: [Column], rowGroups: [[Column]], rows: [Int]) -> Data {
        var out = Array("PAR1".utf8)
        var groups: [PQThrift] = []
        for (g, columns) in rowGroups.enumerated() {
            var chunks: [PQThrift] = []
            for c in columns {
                let first = Int64(out.count)
                var dictionaryOffset: Int64?
                var dataOffset: Int64?
                var uncompressedTotal: Int64 = 0
                for page in c.pages {
                    let offset = Int64(out.count)
                    if case .i32(2)? = page.header.first(where: { $0.0 == 1 })?.1 { dictionaryOffset = offset } else if dataOffset == nil { dataOffset = offset }
                    if case .i32(let u)? = page.header.first(where: { $0.0 == 2 })?.1 { uncompressedTotal += u }
                    out += encode(.strct(page.header)) + page.body
                }
                var meta: [(Int16, PQThrift)] = [(1, .i32(c.physical)), (2, .list(5, [.i32(0)])), (3, .list(8, [.str(c.name)])), (4, .i32(c.codec)),
                                          (5, .i64(c.valueCount)), (6, .i64(uncompressedTotal)), (7, .i64(Int64(out.count) - first)),
                                          (9, .i64(dataOffset ?? first))]
                if let dictionaryOffset { meta.append((11, .i64(dictionaryOffset))) }
                chunks.append(.strct([(2, .i64(first)), (3, .strct(meta))]))
            }
            groups.append(.strct([(1, .list(12, chunks)), (2, .i64(0)), (3, .i64(Int64(rows[g])))]))
        }
        var elements: [PQThrift] = [.strct([(4, .str("schema")), (5, .i32(Int64(schema.count)))])]
        for c in schema {
            var e: [(Int16, PQThrift)] = [(1, .i32(c.physical)), (3, .i32(c.optional ? 1 : 0)), (4, .str(c.name))]
            if let t = c.typeLength { e.append((2, .i32(t))) }
            if let v = c.converted { e.append((6, .i32(v))) }
            if let s = c.scale { e.append((7, .i32(s))) }
            if let l = c.logical { e.append((10, .strct(l))) }
            elements.append(.strct(e))
        }
        let footer = encode(.strct([(1, .i32(1)), (2, .list(12, elements)), (3, .i64(Int64(rows.reduce(0, +)))), (4, .list(12, groups))]))
        out += footer + le32(footer.count) + Array("PAR1".utf8)
        return Data(out)
    }

    // MARK: Compression for fixtures

    /// Snappy with literals only (valid: a compressor may always emit literals).
    static func snappyLiterals(_ bytes: [UInt8]) -> [UInt8] {
        var out = varint(UInt64(bytes.count))
        var i = 0
        while i < bytes.count {
            let n = min(60, bytes.count - i)
            out.append(UInt8(n - 1) << 2)
            out += bytes[i..<(i + n)]
            i += n
        }
        return out
    }

    /// Gzip member around the system's raw deflate output.
    static func gzip(_ bytes: [UInt8]) -> [UInt8] {
        let deflated = [UInt8]((try? (Data(bytes) as NSData).compressed(using: .zlib) as Data) ?? Data())
        return [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + deflated + le32(Int(TestZip.crc32(Data(bytes)))) + le32(bytes.count)
    }
}
