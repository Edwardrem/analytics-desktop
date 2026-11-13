import Foundation
import zlib

/// Writes ZIP archives (deflate or stored, correct CRC-32, UTF-8 names, ZIP64 when needed).
/// Entries can be supplied whole or streamed chunk by chunk, to memory or straight to a file.
public final class ZipWriter {
    public enum Compression: Sendable { case stored, deflate }

    private struct Record {
        var path: String; var method: UInt16; var flags: UInt16; var crc: UInt32
        var csize: UInt64; var usize: UInt64; var offset: UInt64
        var dosDate: UInt16; var dosTime: UInt16; var zip64: Bool; var isDirectory: Bool
    }

    private var records: [Record] = []
    private var memory = Data()
    private let handle: FileHandle?
    private var offset: UInt64 = 0
    private var finished = false
    /// Forces ZIP64 records for every entry (mainly for testing interoperability).
    public var forceZip64 = false

    /// Creates a writer that builds the archive in memory; `finish()` returns the bytes.
    public init() { handle = nil }

    /// Creates a writer that streams the archive to `url` (replacing any existing file).
    public init(url: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw ZipError.io("Couldn't create “\(url.path)”.") }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw ZipError.io("Couldn't open “\(url.path)” for writing: \(error.localizedDescription)") }
    }

    private func emit(_ d: Data) throws {
        if let handle {
            do { try handle.write(contentsOf: d) } catch { throw ZipError.io("Couldn't write the archive: \(error.localizedDescription)") }
        } else { memory.append(d) }
        offset += UInt64(d.count)
    }

    private func checkPath(_ path: String) throws -> String {
        guard let safe = ZipArchive.sanitizedPath(path) else { throw ZipError.unsafePath(path) }
        guard safe.utf8.count <= 0xFFFF else { throw ZipError.unsupported("entry names longer than 65,535 bytes") }
        guard !finished else { throw ZipError.io("The archive is already finished.") }
        return safe
    }

    /// Adds a complete entry.
    public func add(path: String, data: Data, compression: Compression = .deflate, modified: Date = Date()) throws {
        let safe = try checkPath(path)
        var payload = data
        var method: UInt16 = 0
        if compression == .deflate, !data.isEmpty {
            var packed = Data()
            let c = try Deflate.Compressor()
            var off = 0
            let step = 1 << 20
            while off < data.count {
                let n = min(step, data.count - off)
                try c.compress(data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + n)), finish: false) { packed.append($0) }
                off += n
            }
            try c.compress(Data(), finish: true) { packed.append($0) }
            if packed.count < data.count { payload = packed; method = 8 }
        }
        let crc = UInt32(truncatingIfNeeded: Deflate.checksum(data))
        let dos = ZipArchive.dos(from: modified)
        let z64 = forceZip64 || data.count >= 0xFFFF_FFFF || payload.count >= 0xFFFF_FFFF || offset >= 0xFFFF_FFFF
        var rec = Record(path: safe, method: method, flags: 0x0800, crc: crc, csize: UInt64(payload.count), usize: UInt64(data.count),
                         offset: offset, dosDate: dos.date, dosTime: dos.time, zip64: z64, isDirectory: false)
        try emit(localHeader(rec, sizesKnown: true))
        try emit(payload)
        rec.flags = 0x0800
        records.append(rec)
    }

    /// Adds an entry whose content is pulled chunk by chunk from `source` (return nil when done).
    /// Sizes and CRC are written after the data in a data descriptor, so nothing is buffered.
    public func add(path: String, compression: Compression = .deflate, modified: Date = Date(), zip64: Bool = false,
                    source: () throws -> Data?) throws {
        let safe = try checkPath(path)
        let dos = ZipArchive.dos(from: modified)
        let z64 = zip64 || forceZip64 || offset >= 0xFFFF_FFFF
        var rec = Record(path: safe, method: compression == .deflate ? 8 : 0, flags: 0x0808, crc: 0, csize: 0, usize: 0,
                         offset: offset, dosDate: dos.date, dosTime: dos.time, zip64: z64, isDirectory: false)
        try emit(localHeader(rec, sizesKnown: false))
        var crc: uLong = crc32(0, nil, 0)
        var usize: UInt64 = 0, csize: UInt64 = 0
        let compressor = compression == .deflate ? try Deflate.Compressor() : nil
        while let chunk = try source() {
            if chunk.isEmpty { continue }
            crc = Deflate.checksum(chunk, seed: crc)
            usize += UInt64(chunk.count)
            if let compressor {
                try compressor.compress(chunk, finish: false) { csize += UInt64($0.count); try self.emit($0) }
            } else {
                csize += UInt64(chunk.count); try emit(chunk)
            }
        }
        if let compressor { try compressor.compress(Data(), finish: true) { csize += UInt64($0.count); try self.emit($0) } }
        guard z64 || (usize < 0xFFFF_FFFF && csize < 0xFFFF_FFFF) else {
            throw ZipError.tooLarge("“\(safe)” exceeds 4 GB; pass zip64: true for entries this large")
        }
        rec.crc = UInt32(truncatingIfNeeded: crc); rec.usize = usize; rec.csize = csize
        var d = Data()
        d.le32(0x0807_4b50); d.le32(rec.crc)
        if z64 { d.le64(csize); d.le64(usize) } else { d.le32(UInt32(csize)); d.le32(UInt32(usize)) }
        try emit(d)
        records.append(rec)
    }

    /// Adds an explicit directory entry.
    public func addDirectory(path: String, modified: Date = Date()) throws {
        var safe = try checkPath(path)
        if !safe.hasSuffix("/") { safe += "/" }
        let dos = ZipArchive.dos(from: modified)
        let rec = Record(path: safe, method: 0, flags: 0x0800, crc: 0, csize: 0, usize: 0, offset: offset,
                         dosDate: dos.date, dosTime: dos.time, zip64: forceZip64 || offset >= 0xFFFF_FFFF, isDirectory: true)
        try emit(localHeader(rec, sizesKnown: true))
        records.append(rec)
    }

    private func localHeader(_ r: Record, sizesKnown: Bool) -> Data {
        var d = Data()
        let name = Data(r.path.utf8)
        d.le32(0x0403_4b50)
        d.le16(r.zip64 ? 45 : 20); d.le16(r.flags); d.le16(r.method); d.le16(r.dosTime); d.le16(r.dosDate)
        d.le32(sizesKnown ? r.crc : 0)
        if r.zip64 {
            d.le32(0xFFFF_FFFF); d.le32(0xFFFF_FFFF)
            d.le16(UInt16(name.count)); d.le16(20)
            d.append(name)
            d.le16(0x0001); d.le16(16); d.le64(sizesKnown ? r.usize : 0); d.le64(sizesKnown ? r.csize : 0)
        } else {
            d.le32(sizesKnown ? UInt32(r.csize) : 0); d.le32(sizesKnown ? UInt32(r.usize) : 0)
            d.le16(UInt16(name.count)); d.le16(0)
            d.append(name)
        }
        return d
    }

    /// Writes the central directory. Returns the archive bytes for in-memory writers (empty for file writers).
    @discardableResult
    public func finish() throws -> Data {
        guard !finished else { return memory }
        let cdStart = offset
        for r in records {
            var d = Data()
            let name = Data(r.path.utf8)
            var extra = Data()
            let needOffset = r.offset >= 0xFFFF_FFFF
            if r.zip64 || needOffset {
                var body = Data()
                if r.zip64 { body.le64(r.usize); body.le64(r.csize) }
                if needOffset { body.le64(r.offset) }
                extra.le16(0x0001); extra.le16(UInt16(body.count)); extra.append(body)
            }
            d.le32(0x0201_4b50)
            d.le16(0x0300 | (r.zip64 || needOffset ? 45 : 20))   // made by: Unix
            d.le16(r.zip64 || needOffset ? 45 : 20)
            d.le16(r.flags); d.le16(r.method); d.le16(r.dosTime); d.le16(r.dosDate); d.le32(r.crc)
            d.le32(r.zip64 ? 0xFFFF_FFFF : UInt32(r.csize)); d.le32(r.zip64 ? 0xFFFF_FFFF : UInt32(r.usize))
            d.le16(UInt16(name.count)); d.le16(UInt16(extra.count)); d.le16(0); d.le16(0); d.le16(0)
            d.le32(r.isDirectory ? (0o40755 << 16) | 0x10 : (0o100644 << 16))
            d.le32(needOffset ? 0xFFFF_FFFF : UInt32(r.offset))
            d.append(name); d.append(extra)
            try emit(d)
        }
        let cdSize = offset - cdStart
        let needs64 = forceZip64 || records.count >= 0xFFFF || cdStart >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF
        var tail = Data()
        if needs64 {
            let z64Offset = offset
            tail.le32(0x0606_4b50); tail.le64(44); tail.le16(45); tail.le16(45); tail.le32(0); tail.le32(0)
            tail.le64(UInt64(records.count)); tail.le64(UInt64(records.count)); tail.le64(cdSize); tail.le64(cdStart)
            tail.le32(0x0706_4b50); tail.le32(0); tail.le64(z64Offset); tail.le32(1)
        }
        tail.le32(0x0605_4b50); tail.le16(0); tail.le16(0)
        let n16 = UInt16(min(records.count, 0xFFFF))
        tail.le16(n16); tail.le16(n16)
        tail.le32(cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize))
        tail.le32(cdStart >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdStart))
        tail.le16(0)
        try emit(tail)
        finished = true
        try? handle?.close()
        return memory
    }

    /// Convenience: builds an in-memory archive from path → data pairs (in the given order).
    public static func archive(_ files: [(path: String, data: Data)], compression: Compression = .deflate) throws -> Data {
        let w = ZipWriter()
        for f in files { try w.add(path: f.path, data: f.data, compression: compression) }
        return try w.finish()
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le16(_ v: Int) { le16(UInt16(truncatingIfNeeded: v)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
    mutating func le32(_ v: Int) { le32(UInt32(truncatingIfNeeded: v)) }
    mutating func le64(_ v: UInt64) { le32(UInt32(v & 0xFFFF_FFFF)); le32(UInt32(v >> 32)) }
}
