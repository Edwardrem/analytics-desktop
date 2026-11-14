import Foundation
import zlib

/// Errors raised by the ZIP reader and writer.
public enum ZipError: LocalizedError, Equatable {
    case notAZip
    case corrupt(String)
    case unsupported(String)
    case unsafePath(String)
    case tooLarge(String)
    case crcMismatch(String)
    case entryNotFound(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "The file is not a ZIP archive."
        case .corrupt(let m): return "The ZIP archive is damaged: \(m)."
        case .unsupported(let m): return "Unsupported ZIP feature: \(m)."
        case .unsafePath(let p): return "The archive contains an unsafe path (“\(p)”) and was not extracted."
        case .tooLarge(let m): return "The archive is too large to open safely: \(m)."
        case .crcMismatch(let p): return "“\(p)” failed its checksum; the archive is damaged."
        case .entryNotFound(let p): return "The archive has no entry named “\(p)”."
        case .io(let m): return m
        }
    }
}

/// One file or directory recorded in a ZIP central directory.
public struct ZipEntry: Hashable, Sendable {
    public var path: String
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var crc32: UInt32
    /// 0 = stored, 8 = deflate.
    public var method: UInt16
    public var flags: UInt16
    public var localHeaderOffset: UInt64
    public var modified: Date
    public var isDirectory: Bool { path.hasSuffix("/") }
}

/// Reads ZIP archives: central directory, stored and deflate entries, data descriptors, ZIP64, UTF-8 names.
/// Protects against zip-slip paths and decompression bombs.
public final class ZipArchive {
    /// Safety limits applied while opening and extracting.
    public struct Limits: Sendable {
        /// Maximum total uncompressed size of all entries, as declared and as actually produced while reading.
        public var maxTotalUncompressedSize: UInt64 = 4 * 1024 * 1024 * 1024
        /// Maximum uncompressed size of any one entry. An archive declaring a larger entry is refused when opened.
        public var maxEntrySize: UInt64 = 2 * 1024 * 1024 * 1024
        /// Maximum number of entries. Document formats hold tens to a few thousand; more is treated as hostile.
        public var maxEntryCount = 100_000
        /// Largest uncompressed-to-compressed ratio an entry may declare. Deflate can't exceed about 1,032:1, and the
        /// app's own documents reach 500–1,000:1 for constant columns, so this refuses only sizes no real stream yields.
        public var maxCompressionRatio: UInt64 = 1_100
        public init() {}
        public init(maxTotalUncompressedSize: UInt64) { self.maxTotalUncompressedSize = maxTotalUncompressedSize }
    }

    public let entries: [ZipEntry]
    public let limits: Limits
    private let data: Data
    private let byPath: [String: Int]
    private var producedTotal: UInt64 = 0
    private let lock = NSLock()

    /// Opens an archive file (memory-mapped, so large archives are not loaded up front).
    public convenience init(url: URL, limits: Limits = Limits()) throws {
        let d: Data
        do { d = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw ZipError.io("Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)") }
        try self.init(data: d, limits: limits)
    }

    /// Opens an archive held in memory.
    public init(data: Data, limits: Limits = Limits()) throws {
        // Rebase so offsets start at zero.
        self.data = data.startIndex == 0 ? data : Data(data)
        self.limits = limits
        let r = ByteReader(self.data)
        guard r.count >= 22 else { throw ZipError.notAZip }
        // End of central directory: search backwards (comment may follow it).
        var eocd = -1
        let lowest = max(0, r.count - 22 - 65535)
        var i = r.count - 22
        while i >= lowest {
            if r.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        var total = UInt64(r.u16(eocd + 10))
        var cdSize = UInt64(r.u32(eocd + 12))
        var cdOffset = UInt64(r.u32(eocd + 16))
        // ZIP64 locator sits immediately before the EOCD.
        if eocd >= 20, r.u32(eocd - 20) == 0x0706_4b50 {
            let z64 = r.u64(eocd - 20 + 8)
            guard r.count >= 56, z64 <= UInt64(r.count - 56), r.u32(Int(z64)) == 0x0606_4b50 else { throw ZipError.corrupt("bad ZIP64 directory") }
            let o = Int(z64)
            total = r.u64(o + 32); cdSize = r.u64(o + 40); cdOffset = r.u64(o + 48)
        }
        guard total <= UInt64(limits.maxEntryCount) else { throw ZipError.tooLarge("\(total) entries") }
        guard cdOffset <= UInt64(r.count), cdSize <= UInt64(r.count) - cdOffset else { throw ZipError.corrupt("central directory out of range") }

        var list: [ZipEntry] = []
        list.reserveCapacity(Int(total))
        var p = Int(cdOffset)
        var sum: UInt64 = 0
        for _ in 0..<total {
            guard p + 46 <= r.count, r.u32(p) == 0x0201_4b50 else { throw ZipError.corrupt("bad central directory entry") }
            let flags = r.u16(p + 8), method = r.u16(p + 10)
            let time = r.u16(p + 12), date = r.u16(p + 14)
            let crc = r.u32(p + 16)
            var csize = UInt64(r.u32(p + 20)), usize = UInt64(r.u32(p + 24))
            let nameLen = Int(r.u16(p + 28)), extraLen = Int(r.u16(p + 30)), commentLen = Int(r.u16(p + 32))
            var offset = UInt64(r.u32(p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= r.count else { throw ZipError.corrupt("truncated central directory") }
            let nameData = r.bytes(p + 46, nameLen)
            // ZIP64 extended information.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = r.u16(e), size = Int(r.u16(e + 2))
                var q = e + 4
                if id == 0x0001 {
                    if usize == 0xFFFF_FFFF, q + 8 <= extraEnd { usize = r.u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= extraEnd { csize = r.u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= extraEnd { offset = r.u64(q); q += 8 }
                }
                e += 4 + size
            }
            let name = ZipArchive.decodeName(nameData, utf8Flag: flags & 0x0800 != 0)
            guard usize <= limits.maxEntrySize else { throw ZipError.tooLarge("“\(name)” expands to \(usize) bytes") }
            let (ratioLimit, ratioOverflow) = max(csize, 1).multipliedReportingOverflow(by: limits.maxCompressionRatio)
            guard ratioOverflow || usize <= ratioLimit else {
                throw ZipError.tooLarge("“\(name)” claims to expand from \(csize) to \(usize) bytes")
            }
            let (next, overflow) = sum.addingReportingOverflow(usize)
            guard !overflow, next <= limits.maxTotalUncompressedSize else {
                throw ZipError.tooLarge("contents expand beyond the \(limits.maxTotalUncompressedSize)-byte limit")
            }
            sum = next
            list.append(ZipEntry(path: name, compressedSize: csize, uncompressedSize: usize, crc32: crc, method: method,
                                 flags: flags, localHeaderOffset: offset, modified: ZipArchive.date(dosDate: date, dosTime: time)))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
        var map: [String: Int] = [:]
        for (i, e) in list.enumerated() where map[e.path] == nil { map[e.path] = i }
        byPath = map
    }

    /// Finds an entry by exact path, falling back to a case-insensitive match.
    public func entry(named path: String) -> ZipEntry? {
        if let i = byPath[path] { return entries[i] }
        return entries.first { $0.path.caseInsensitiveCompare(path) == .orderedSame }
    }
    public func contains(_ path: String) -> Bool { entry(named: path) != nil }

    /// Reads an entry fully into memory, verifying its CRC-32.
    public func data(for entry: ZipEntry) throws -> Data {
        guard entry.uncompressedSize <= limits.maxEntrySize else { throw ZipError.tooLarge("“\(entry.path)” is \(entry.uncompressedSize) bytes") }
        var out = Data()
        out.reserveCapacity(Int(min(entry.uncompressedSize, 64 * 1024 * 1024)))
        try read(entry) { out.append($0) }
        return out
    }
    /// Reads the entry at `path`, or throws `.entryNotFound`.
    public func data(named path: String) throws -> Data {
        guard let e = entry(named: path) else { throw ZipError.entryNotFound(path) }
        return try data(for: e)
    }

    /// Streams an entry's uncompressed bytes to `consumer` in chunks, verifying size and CRC-32.
    public func read(_ entry: ZipEntry, chunkSize: Int = 1 << 16, consumer: (Data) throws -> Void) throws {
        guard entry.flags & 0x0001 == 0 else { throw ZipError.unsupported("encrypted entries") }
        let r = ByteReader(data)
        guard entry.localHeaderOffset <= UInt64(max(0, r.count - 30)) else { throw ZipError.corrupt("entry offset out of range") }
        let h = Int(entry.localHeaderOffset)
        guard r.u32(h) == 0x0403_4b50 else { throw ZipError.corrupt("bad local header for “\(entry.path)”") }
        let start = h + 30 + Int(r.u16(h + 26)) + Int(r.u16(h + 28))
        guard start <= r.count, entry.compressedSize <= UInt64(r.count - start) else { throw ZipError.corrupt("entry data out of range") }
        let compressed = data.subdata(in: start..<(start + Int(entry.compressedSize)))
        var crc: uLong = crc32(0, nil, 0)
        var produced: UInt64 = 0
        func emit(_ chunk: Data) throws {
            produced += UInt64(chunk.count)
            guard produced <= entry.uncompressedSize else { throw ZipError.corrupt("“\(entry.path)” expands beyond its declared size") }
            lock.lock(); producedTotal += UInt64(chunk.count); let overall = producedTotal; lock.unlock()
            guard overall <= limits.maxTotalUncompressedSize else { throw ZipError.tooLarge("extraction exceeded the safety limit") }
            crc = chunk.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            try consumer(chunk)
        }
        switch entry.method {
        case 0:
            var off = 0
            while off < compressed.count {
                let n = min(chunkSize, compressed.count - off)
                try emit(compressed.subdata(in: off..<(off + n)))
                off += n
            }
        case 8:
            try Deflate.inflate(compressed, chunkSize: chunkSize, consumer: emit)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard produced == entry.uncompressedSize else { throw ZipError.corrupt("“\(entry.path)” has the wrong length") }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else { throw ZipError.crcMismatch(entry.path) }
    }

    /// Extracts every entry beneath `directory`. Throws `.unsafePath` (before writing anything) if any entry would escape it.
    public func extractAll(to directory: URL) throws {
        let fm = FileManager.default
        let planned: [(ZipEntry, String)] = try entries.map { e in
            guard let safe = ZipArchive.sanitizedPath(e.path) else { throw ZipError.unsafePath(e.path) }
            return (e, safe)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (e, safe) in planned {
            let dest = directory.appendingPathComponent(safe)
            if e.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: dest.path, contents: nil) else { throw ZipError.io("Couldn't create “\(dest.path)”.") }
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }
            try read(e) { try handle.write(contentsOf: $0) }
        }
    }

    /// Returns a normalised relative path, or nil when the path is absolute, contains `..`, a drive letter, or NULs.
    public static func sanitizedPath(_ path: String) -> String? {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        if p.isEmpty || p.hasPrefix("/") || p.contains("\0") { return nil }
        var parts: [String] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == ".." { return nil }
            if c == "." { continue }
            if parts.isEmpty, c.count == 2, c.hasSuffix(":") { return nil }
            parts.append(String(c))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/") + (p.hasSuffix("/") ? "/" : "")
    }

    static func decodeName(_ d: Data, utf8Flag: Bool) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        return String(data: d, encoding: cp437) ?? String(decoding: d, as: UTF8.self)
    }

    static func date(dosDate: UInt16, dosTime: UInt16) -> Date {
        var c = DateComponents()
        c.year = Int(dosDate >> 9) + 1980; c.month = max(1, Int((dosDate >> 5) & 0xF)); c.day = max(1, Int(dosDate & 0x1F))
        c.hour = Int(dosTime >> 11); c.minute = Int((dosTime >> 5) & 0x3F); c.second = Int(dosTime & 0x1F) * 2
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }
    static func dos(from date: Date) -> (date: UInt16, time: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = max(1980, min(2107, c.year ?? 1980))
        let d = UInt16((y - 1980) << 9) | UInt16((c.month ?? 1) << 5) | UInt16(c.day ?? 1)
        let t = UInt16((c.hour ?? 0) << 11) | UInt16((c.minute ?? 0) << 5) | UInt16((c.second ?? 0) / 2)
        return (d, t)
    }
}

/// Bounds-checked little-endian reads over `Data` (out-of-range reads yield zero).
struct ByteReader {
    let data: Data
    let count: Int
    init(_ d: Data) { data = d.startIndex == 0 ? d : Data(d); count = data.count }
    func u8(_ o: Int) -> UInt8 { o >= 0 && o < count ? data[o] : 0 }
    func u16(_ o: Int) -> UInt16 { UInt16(u8(o)) | UInt16(u8(o + 1)) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
    func bytes(_ o: Int, _ n: Int) -> Data {
        guard o >= 0, n >= 0, o <= count, n <= count - o else { return Data() }
        return data.subdata(in: o..<(o + n))
    }
}

/// Raw deflate (no zlib header), as used inside ZIP, via the system zlib.
enum Deflate {
    static func inflate(_ input: Data, chunkSize: Int = 1 << 16, consumer: (Data) throws -> Void) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZipError.corrupt("couldn't start decompression")
        }
        defer { inflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: max(1024, chunkSize))
        var finished = false
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: Bytef.self).baseAddress
            var fed = 0
            let piece = 1 << 30   // zlib counts input in 32 bits; feed large entries in pieces
            while !finished {
                if stream.avail_in == 0, fed < raw.count, let base {
                    let n = min(piece, raw.count - fed)
                    stream.next_in = UnsafeMutablePointer(mutating: base + fed)
                    stream.avail_in = uInt(n)
                    fed += n
                }
                var status: Int32 = Z_OK
                let produced: Int = out.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return buf.count - Int(stream.avail_out)
                }
                if produced > 0 { try consumer(Data(out[0..<produced])) }
                if status == Z_STREAM_END { finished = true; break }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw ZipError.corrupt("invalid compressed data") }
                if produced == 0 && stream.avail_in == 0 && fed >= raw.count { throw ZipError.corrupt("compressed data ends early") }
            }
        }
        if !finished { throw ZipError.corrupt("compressed data ends early") }
    }

    /// Incremental raw-deflate compressor.
    final class Compressor {
        private var stream = z_stream()
        private var out = [UInt8](repeating: 0, count: 1 << 16)
        init(level: Int32 = Z_DEFAULT_COMPRESSION) throws {
            guard deflateInit2_(&stream, level, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZipError.io("Couldn't start compression.") }
        }
        deinit { deflateEnd(&stream) }

        /// Compresses `input`; pass `finish: true` on the last call (input may be empty).
        func compress(_ input: Data, finish: Bool, sink: (Data) throws -> Void) throws {
            try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(raw.count)
                while true {
                    var status: Int32 = Z_OK
                    let produced: Int = out.withUnsafeMutableBufferPointer { buf in
                        stream.next_out = buf.baseAddress
                        stream.avail_out = uInt(buf.count)
                        status = deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
                        return buf.count - Int(stream.avail_out)
                    }
                    if produced > 0 { try sink(Data(out[0..<produced])) }
                    if status == Z_STREAM_END { break }
                    guard status == Z_OK || status == Z_BUF_ERROR else { throw ZipError.io("Compression failed.") }
                    if !finish && stream.avail_in == 0 { break }
                    if status == Z_BUF_ERROR && produced == 0 && stream.avail_in == 0 && !finish { break }
                }
            }
        }
    }

    static func checksum(_ data: Data, seed: uLong = crc32(0, nil, 0)) -> uLong {
        data.withUnsafeBytes { crc32(seed, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
    }
}
