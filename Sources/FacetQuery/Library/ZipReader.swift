import Foundation
import Compression

/// Minimal read-only ZIP archive (stored and deflated entries; no ZIP64, no encryption) for Office Open XML files.
struct ZipReader {
    struct Entry { var method: Int; var compressedSize: Int; var size: Int; var headerOffset: Int }
    let data: Data
    private(set) var entries: [String: Entry] = [:]
    private let what: String

    private func invalid(_ detail: String) -> MError { MError.dataFormat("\(what) is not a valid ZIP archive: \(detail).") }
    private func u16(_ at: Int) throws -> Int {
        guard at >= 0, at + 2 <= data.count else { throw invalid("it is truncated") }
        let s = data.startIndex + at
        return Int(data[s]) | Int(data[s + 1]) << 8
    }
    private func u32(_ at: Int) throws -> Int {
        guard at >= 0, at + 4 <= data.count else { throw invalid("it is truncated") }
        let s = data.startIndex + at
        return Int(data[s]) | Int(data[s + 1]) << 8 | Int(data[s + 2]) << 16 | Int(data[s + 3]) << 24
    }

    init(_ data: Data, describedAs what: String) throws {
        self.data = data; self.what = what
        guard data.count >= 22 else { throw invalid("it is too small") }
        var eocd = -1, at = data.count - 22
        let stop = max(0, data.count - 22 - 65535)
        while at >= stop {
            if try u32(at) == 0x06054b50 { eocd = at; break }
            at -= 1
        }
        guard eocd >= 0 else { throw invalid("the end-of-archive record is missing") }
        let count = try u16(eocd + 10), directory = try u32(eocd + 16)
        if count == 0xFFFF || directory == 0xFFFF_FFFF { throw invalid("ZIP64 archives are not supported") }
        var p = directory
        for _ in 0..<count {
            guard try u32(p) == 0x02014b50 else { throw invalid("the central directory is damaged") }
            if try u16(p + 8) & 1 != 0 { throw invalid("it is encrypted") }
            let nameLength = try u16(p + 28), extra = try u16(p + 30), comment = try u16(p + 32)
            guard p + 46 + nameLength <= data.count else { throw invalid("it is truncated") }
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: try u16(p + 10), compressedSize: try u32(p + 20), size: try u32(p + 24), headerOffset: try u32(p + 42))
            p += 46 + nameLength + extra + comment
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// The decompressed bytes of an entry, or nil when it does not exist. Entries larger than `limit` are refused.
    func read(_ name: String, limit: Int) throws -> Data? {
        guard let e = entries[name] else { return nil }
        if e.size > limit { throw MError.dataSource("The entry '\(name)' of \(what) is too large to load (\(e.size) bytes; the limit is \(limit) bytes).") }
        guard try u32(e.headerOffset) == 0x04034b50 else { throw invalid("the entry '\(name)' is damaged") }
        let start = e.headerOffset + 30 + (try u16(e.headerOffset + 26)) + (try u16(e.headerOffset + 28))
        guard start + e.compressedSize <= data.count else { throw invalid("the entry '\(name)' is truncated") }
        let body = data[(data.startIndex + start)..<(data.startIndex + start + e.compressedSize)]
        switch e.method {
        case 0: return Data(body)
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                body.withUnsafeBytes { src -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, e.size, s, e.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { throw invalid("the entry '\(name)' could not be decompressed") }
            return out
        default: throw invalid("the entry '\(name)' uses an unsupported compression method (\(e.method))")
        }
    }
}
