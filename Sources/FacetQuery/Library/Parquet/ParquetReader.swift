import Foundation

/// A Parquet file read into M values: flat (and struct-nested) columns of the common physical and logical types,
/// PLAIN, RLE and dictionary encodings, data pages v1 and v2, and uncompressed, Snappy and Gzip pages.
///
/// Memory is bounded: the declared uncompressed size of the column data is checked against `limit` before any page
/// is decoded, every offset and length is checked against the file, and each page decompresses into a buffer of
/// exactly the size its header states.
struct ParquetReader {
    struct Unsupported: Error { let message: String }

    struct Column {
        var name: String
        var physical: Int
        var typeLength: Int
        var converted: Int?
        var logical: (id: Int16, value: ThriftStruct)?
        var scale: Int
        var maxDefinition: Int
        var maxRepetition: Int
    }

    let bytes: [UInt8]
    let columns: [Column]
    let rowGroups: [ThriftStruct]
    let rowCount: Int
    let limit: Int

    init(_ data: Data, limit: Int) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        self.limit = limit
        guard bytes.count >= 12, bytes.prefix(4).elementsEqual(Array("PAR1".utf8)), bytes.suffix(4).elementsEqual(Array("PAR1".utf8)) else {
            throw Unsupported(message: "the binary isn't a Parquet file (it doesn't start and end with PAR1)")
        }
        let n = bytes.count
        let footerLength = Int(bytes[n - 8]) | Int(bytes[n - 7]) << 8 | Int(bytes[n - 6]) << 16 | Int(bytes[n - 5]) << 24
        guard footerLength > 0, footerLength <= n - 12 else { throw Unsupported(message: "the file's footer length is invalid") }
        var reader = ThriftReader(bytes, at: n - 8 - footerLength)
        let meta = try reader.readStruct()
        if meta.structure(8) != nil || meta[9] != nil {
            // Field 8 is EncryptionAlgorithm in encrypted-footer-plaintext files.
            throw Unsupported(message: "encrypted Parquet files can't be read")
        }
        let schema = meta.list(2).compactMap(\.structure)
        guard let root = schema.first else { throw Unsupported(message: "the file has no schema") }
        var leaves: [Column] = []
        var index = 1
        func walk(prefix: [String], children: Int, definition: Int, repetition: Int) throws {
            for _ in 0..<children {
                guard index < schema.count else { throw Unsupported(message: "the schema is shorter than it says") }
                let e = schema[index]
                index += 1
                let rep = e.int(3) ?? 0
                let def = definition + (rep == 1 ? 1 : 0) + (rep == 2 ? 1 : 0)
                let repe = repetition + (rep == 2 ? 1 : 0)
                let path = prefix + [e.string(4) ?? "Column\(leaves.count + 1)"]
                if let kids = e.int(5), kids > 0 {
                    guard path.count < 32 else { throw Unsupported(message: "the schema is nested too deeply") }
                    try walk(prefix: path, children: kids, definition: def, repetition: repe)
                } else {
                    leaves.append(Column(name: path.joined(separator: "."), physical: e.int(1) ?? -1, typeLength: e.int(2) ?? 0,
                                         converted: e.int(6), logical: e.structure(10)?.unionMember, scale: e.int(7) ?? 0,
                                         maxDefinition: def, maxRepetition: repe))
                }
            }
        }
        try walk(prefix: [], children: root.int(5) ?? 0, definition: 0, repetition: 0)
        if let nested = leaves.first(where: { $0.maxRepetition > 0 }) {
            throw Unsupported(message: "the column '\(nested.name)' is a list or map, and nested repeated columns aren't supported")
        }
        columns = leaves
        rowGroups = meta.list(4).compactMap(\.structure)
        let total = meta.int64(3) ?? 0
        guard total >= 0, total <= Int64(Int32.max) else { throw Unsupported(message: "the row count is out of range") }
        rowCount = Int(total)
        var declared: Int64 = 0
        for g in rowGroups { for c in g.list(1).compactMap(\.structure) { declared += max(0, c.structure(3)?.int64(6) ?? 0) } }
        guard declared <= Int64(limit) else {
            throw Unsupported(message: "its column data is \(declared) bytes uncompressed, more than the limit of \(limit) bytes")
        }
    }

    /// The whole file as an M table.
    func table() throws -> MTable {
        var data = [[MValue]](repeating: [], count: columns.count)
        for c in data.indices { data[c].reserveCapacity(rowCount) }
        for group in rowGroups {
            let groupRows = group.int(3) ?? 0
            let chunks = group.list(1).compactMap(\.structure)
            guard chunks.count == columns.count else { throw Unsupported(message: "a row group has \(chunks.count) columns, not \(columns.count)") }
            for (i, chunk) in chunks.enumerated() {
                let values = try readChunk(chunk, column: columns[i], rows: groupRows)
                data[i].append(contentsOf: values)
            }
        }
        let n = data.first?.count ?? 0
        return MTable(names: MLib.uniqued(columns.map(\.name)), types: columns.map(Self.mType), columns: data, rowCount: n)
    }

    // MARK: Pages

    private func readChunk(_ chunk: ThriftStruct, column: Column, rows: Int) throws -> [MValue] {
        if chunk.string(1) != nil { throw Unsupported(message: "the column '\(column.name)' is stored in another file") }
        guard let meta = chunk.structure(3) else { throw Unsupported(message: "the column '\(column.name)' has no metadata") }
        let codec = meta.int(4) ?? 0
        guard [0, 1, 2].contains(codec) else {
            let names = [3: "LZO", 4: "Brotli", 5: "LZ4", 6: "Zstandard", 7: "LZ4"]
            throw Unsupported(message: "the column '\(column.name)' is compressed with \(names[codec] ?? "an unknown codec"); only uncompressed, Snappy and Gzip are supported")
        }
        let total = meta.int(5) ?? 0
        guard total >= 0, total <= rows else { throw Unsupported(message: "the column '\(column.name)' has more values than rows") }
        var offset = meta.int(9) ?? 0
        if let d = meta.int(11), d > 0, d < offset { offset = d }
        var dictionary: [MValue]?
        var out: [MValue] = []
        out.reserveCapacity(total)
        let convert = Self.converter(column)
        while out.count < total {
            guard offset >= 4, offset < bytes.count - 8 else { throw Unsupported(message: "a page of '\(column.name)' lies outside the file") }
            var r = ThriftReader(bytes, at: offset)
            let header = try r.readStruct()
            let compressed = header.int(3) ?? -1, uncompressed = header.int(2) ?? -1
            let start = r.position
            guard compressed >= 0, uncompressed >= 0, compressed <= bytes.count - 8 - start, uncompressed <= limit else {
                throw Unsupported(message: "a page of '\(column.name)' has an invalid size")
            }
            let body = Array(bytes[start..<(start + compressed)])
            offset = start + compressed
            switch header.int(1) ?? -1 {
            case 2:
                let values = try decompress(body, codec: codec, size: uncompressed)
                let count = header.structure(7)?.int(1) ?? 0
                guard count >= 0, count <= uncompressed * 8 + 8 else { throw Unsupported(message: "the dictionary of '\(column.name)' is invalid") }
                var p = 0
                dictionary = try plain(values, &p, count: count, column: column).map(convert)
            case 0:
                guard let h = header.structure(5) else { throw Unsupported(message: "a data page of '\(column.name)' has no header") }
                let page = try decompress(body, codec: codec, size: uncompressed)
                let count = h.int(1) ?? 0
                guard count >= 0, count <= total - out.count else { throw Unsupported(message: "a data page of '\(column.name)' has too many values") }
                var p = 0
                var defs: [Int]?
                if column.maxDefinition > 0 {
                    let n = try Self.uint32(page, &p)
                    guard n <= page.count - p else { throw Unsupported(message: "the definition levels of '\(column.name)' run past the page") }
                    defs = try Self.hybrid(page, p..<(p + n), bitWidth: Self.bitWidth(column.maxDefinition), count: count)
                    p += n
                }
                out += try values(page, &p, encoding: h.int(2) ?? 0, count: count, defs: defs, column: column, dictionary: dictionary, convert: convert)
            case 3:
                guard let h = header.structure(8) else { throw Unsupported(message: "a data page of '\(column.name)' has no header") }
                let count = h.int(1) ?? 0, defLength = h.int(5) ?? 0, repLength = h.int(6) ?? 0
                guard count >= 0, count <= total - out.count, defLength >= 0, repLength >= 0, defLength + repLength <= min(body.count, uncompressed) else {
                    throw Unsupported(message: "a data page of '\(column.name)' has invalid sizes")
                }
                var defs: [Int]?
                if column.maxDefinition > 0 {
                    defs = try Self.hybrid(body, repLength..<(repLength + defLength), bitWidth: Self.bitWidth(column.maxDefinition), count: count)
                }
                let rest = Array(body[(repLength + defLength)...])
                let isCompressed = h[7]?.bool ?? true
                let page = isCompressed ? try decompress(rest, codec: codec, size: uncompressed - repLength - defLength) : rest
                var p = 0
                out += try values(page, &p, encoding: h.int(4) ?? 0, count: count, defs: defs, column: column, dictionary: dictionary, convert: convert)
            default:
                continue  // index pages carry no values
            }
        }
        return out
    }

    private func decompress(_ body: [UInt8], codec: Int, size: Int) throws -> [UInt8] {
        do {
            switch codec {
            case 1: return try ParquetCodecs.snappy(body, expectedSize: size)
            case 2: return try ParquetCodecs.gzip(body, expectedSize: size)
            default:
                guard body.count == size else { throw Unsupported(message: "an uncompressed page's size doesn't match its header") }
                return body
            }
        } catch let e as ParquetCodecs.Corrupt { throw Unsupported(message: "a page is damaged (\(e.message))") }
    }

    /// The values of a data page, with nulls placed where the definition level is below the maximum.
    private func values(_ page: [UInt8], _ p: inout Int, encoding: Int, count: Int, defs: [Int]?, column: Column,
                        dictionary: [MValue]?, convert: (Raw) -> MValue) throws -> [MValue] {
        let present = defs.map { $0.filter { $0 == column.maxDefinition }.count } ?? count
        var decoded: [MValue]
        switch encoding {
        case 0:
            decoded = try plain(page, &p, count: present, column: column).map(convert)
        case 2, 8:
            guard let dictionary else { throw Unsupported(message: "'\(column.name)' uses a dictionary it doesn't define") }
            guard p < page.count || present == 0 else { throw Unsupported(message: "the dictionary indices of '\(column.name)' are missing") }
            let width = present == 0 ? 0 : Int(page[p])
            let ids = try Self.hybrid(page, min(p + 1, page.count)..<page.count, bitWidth: width, count: present)
            decoded = try ids.map { id in
                guard id >= 0, id < dictionary.count else { throw Unsupported(message: "a dictionary index of '\(column.name)' is out of range") }
                return dictionary[id]
            }
        case 3 where column.physical == 0:
            let n = try Self.uint32(page, &p)
            guard n <= page.count - p else { throw Unsupported(message: "the values of '\(column.name)' run past the page") }
            decoded = try Self.hybrid(page, p..<(p + n), bitWidth: 1, count: present).map { convert(.bool($0 == 1)) }
        default:
            let names = [5: "DELTA_BINARY_PACKED", 6: "DELTA_LENGTH_BYTE_ARRAY", 7: "DELTA_BYTE_ARRAY", 9: "BYTE_STREAM_SPLIT"]
            throw Unsupported(message: "the column '\(column.name)' uses the \(names[encoding] ?? "unknown") encoding; PLAIN, RLE and dictionary encodings are supported")
        }
        guard let defs else { return decoded }
        var out: [MValue] = []
        out.reserveCapacity(count)
        var next = 0
        for d in defs {
            if d == column.maxDefinition { out.append(decoded[next]); next += 1 } else { out.append(.null) }
        }
        return out
    }

    // MARK: Encodings

    enum Raw {
        case bool(Bool), i32(Int32), i64(Int64), i96(nanos: Int64, julianDay: Int32), f32(Float), f64(Double), bytes(ArraySlice<UInt8>)
    }

    private func plain(_ b: [UInt8], _ p: inout Int, count: Int, column: Column) throws -> [Raw] {
        func need(_ n: Int) throws {
            guard n >= 0, n <= b.count - p else { throw Unsupported(message: "the values of '\(column.name)' run past the page") }
        }
        func le(_ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v |= UInt64(b[p + i]) << (8 * UInt64(i)) }
            p += n
            return v
        }
        var out: [Raw] = []
        out.reserveCapacity(count)
        switch column.physical {
        case 0:
            try need((count + 7) / 8)
            for i in 0..<count { out.append(.bool(b[p + i / 8] >> (i % 8) & 1 == 1)) }
            p += (count + 7) / 8
        case 1: try need(4 * count); for _ in 0..<count { out.append(.i32(Int32(truncatingIfNeeded: le(4)))) }
        case 2: try need(8 * count); for _ in 0..<count { out.append(.i64(Int64(bitPattern: le(8)))) }
        case 3: try need(12 * count); for _ in 0..<count { let n = Int64(bitPattern: le(8)); out.append(.i96(nanos: n, julianDay: Int32(truncatingIfNeeded: le(4)))) }
        case 4: try need(4 * count); for _ in 0..<count { out.append(.f32(Float(bitPattern: UInt32(le(4))))) }
        case 5: try need(8 * count); for _ in 0..<count { out.append(.f64(Double(bitPattern: le(8)))) }
        case 6:
            for _ in 0..<count {
                try need(4)
                let n = Int(le(4))
                try need(n)
                out.append(.bytes(b[p..<(p + n)]))
                p += n
            }
        case 7:
            let n = column.typeLength
            guard n > 0 else { throw Unsupported(message: "the fixed-length column '\(column.name)' has no length") }
            try need(n * count)
            for _ in 0..<count { out.append(.bytes(b[p..<(p + n)])); p += n }
        default: throw Unsupported(message: "the column '\(column.name)' has an unknown physical type")
        }
        return out
    }

    static func uint32(_ b: [UInt8], _ p: inout Int) throws -> Int {
        guard b.count - p >= 4 else { throw Unsupported(message: "a page ends early") }
        defer { p += 4 }
        return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
    }

    static func bitWidth(_ maxValue: Int) -> Int { maxValue <= 0 ? 0 : Int.bitWidth - maxValue.leadingZeroBitCount }

    /// The RLE / bit-packing hybrid: runs of a repeated value, and groups of 8 bit-packed values (LSB first).
    static func hybrid(_ b: [UInt8], _ range: Range<Int>, bitWidth: Int, count: Int) throws -> [Int] {
        guard (0...32).contains(bitWidth) else { throw Unsupported(message: "a bit width is out of range") }
        var out: [Int] = []
        out.reserveCapacity(count)
        if bitWidth == 0 { return [Int](repeating: 0, count: count) }
        var p = range.lowerBound
        let end = range.upperBound
        let valueBytes = (bitWidth + 7) / 8
        while out.count < count {
            var header = 0, shift = 0
            while true {
                guard p < end else { throw Unsupported(message: "RLE data ends early") }
                let byte = b[p]; p += 1
                header |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                guard shift <= 28 else { throw Unsupported(message: "an RLE header is too long") }
            }
            if header & 1 == 0 {
                let run = header >> 1
                guard valueBytes <= end - p else { throw Unsupported(message: "RLE data ends early") }
                var v = 0
                for i in 0..<valueBytes { v |= Int(b[p + i]) << (8 * i) }
                p += valueBytes
                out.append(contentsOf: repeatElement(v, count: min(run, count - out.count)))
            } else {
                let values = (header >> 1) * 8
                let byteCount = (values * bitWidth + 7) / 8
                guard byteCount <= end - p else { throw Unsupported(message: "bit-packed data ends early") }
                let mask = bitWidth == 32 ? 0xFFFF_FFFF : (1 << bitWidth) - 1
                for i in 0..<values where out.count < count {
                    let bit = i * bitWidth
                    var v = 0
                    for k in 0..<((bit % 8 + bitWidth + 7) / 8) { v |= Int(b[p + bit / 8 + k]) << (8 * k) }
                    out.append((v >> (bit % 8)) & mask)
                }
                p += byteCount
            }
        }
        return out
    }
}
