import Foundation
import Compression

/// Decompressors for Parquet pages. Every output size is known in advance (the page header gives it), so no codec
/// can be made to allocate more than the page claims, and the claim itself is checked against the source limit.
enum ParquetCodecs {
    struct Corrupt: Error { let message: String }

    /// Snappy raw format (no framing): a varint uncompressed length, then literal and copy elements.
    static func snappy(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        var p = 0
        func byte() throws -> UInt8 {
            guard p < input.count else { throw Corrupt(message: "snappy data ends early") }
            defer { p += 1 }
            return input[p]
        }
        var length = 0, shift = 0
        while true {
            let b = try byte()
            length |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            guard shift <= 28 else { throw Corrupt(message: "snappy length is too long") }
        }
        guard length == expectedSize else { throw Corrupt(message: "snappy length \(length) doesn't match the page size \(expectedSize)") }
        var out = [UInt8]()
        out.reserveCapacity(length)
        while p < input.count {
            let tag = try byte()
            switch tag & 3 {
            case 0:
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    n = 0
                    for i in 0..<extra { n |= Int(try byte()) << (8 * i) }
                }
                n += 1
                guard n <= input.count - p, out.count + n <= length else { throw Corrupt(message: "snappy literal runs past the data") }
                out.append(contentsOf: input[p..<(p + n)])
                p += n
            default:
                let n: Int, offset: Int
                switch tag & 3 {
                case 1:
                    n = Int((tag >> 2) & 7) + 4
                    offset = Int(tag >> 5) << 8 | Int(try byte())
                case 2:
                    n = Int(tag >> 2) + 1
                    offset = Int(try byte()) | Int(try byte()) << 8
                default:
                    n = Int(tag >> 2) + 1
                    offset = Int(try byte()) | Int(try byte()) << 8 | Int(try byte()) << 16 | Int(try byte()) << 24
                }
                guard offset > 0, offset <= out.count, out.count + n <= length else { throw Corrupt(message: "snappy copy is out of range") }
                let start = out.count - offset
                // Copies may overlap their own output (offset < length), so copy byte by byte.
                for i in 0..<n { out.append(out[start + i]) }
            }
        }
        guard out.count == length else { throw Corrupt(message: "snappy data is shorter than its length") }
        return out
    }

    /// Gzip (RFC 1952) members, decoded with the system deflate decoder into a buffer of exactly `expectedSize` bytes.
    static func gzip(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard input.count >= 18, input[0] == 0x1F, input[1] == 0x8B, input[2] == 8 else {
            // Some writers emit a zlib stream (RFC 1950) for GZIP; accept it too.
            if input.count >= 2, input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0 {
                return try inflate(Array(input[2...]), expectedSize: expectedSize)
            }
            throw Corrupt(message: "gzip header is missing")
        }
        let flags = input[3]
        var p = 10
        if flags & 4 != 0 {
            guard p + 2 <= input.count else { throw Corrupt(message: "gzip header ends early") }
            p += 2 + (Int(input[p]) | Int(input[p + 1]) << 8)
        }
        for bit in [UInt8(8), 16] where flags & bit != 0 {
            while p < input.count, input[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 2 != 0 { p += 2 }
        guard p < input.count - 8 else { throw Corrupt(message: "gzip header ends early") }
        return try inflate(Array(input[p..<(input.count - 8)]), expectedSize: expectedSize)
    }

    /// Raw deflate into exactly `expectedSize` bytes.
    static func inflate(_ input: [UInt8], expectedSize: Int) throws -> [UInt8] {
        if expectedSize == 0 { return [] }
        var out = [UInt8](repeating: 0, count: expectedSize + 1)
        let n = input.withUnsafeBufferPointer { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return -1 }
                return compression_decode_buffer(d, dst.count, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expectedSize else { throw Corrupt(message: "deflate data gave \(n) bytes, not the page's \(expectedSize)") }
        out.removeLast()
        return out
    }
}
