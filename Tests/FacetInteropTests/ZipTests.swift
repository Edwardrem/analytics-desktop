import XCTest
import FacetCore
@testable import FacetInterop

final class ZipTests: XCTestCase {
    private func randomData(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    func testInMemoryRoundTrip() throws {
        let text = Data(String(repeating: "Facet makes BI pleasant. ", count: 4000).utf8)
        let noise = randomData(50_000)
        let w = ZipWriter()
        try w.add(path: "docs/readme.txt", data: text)
        try w.add(path: "bin/noise.dat", data: noise)
        try w.add(path: "empty.txt", data: Data())
        try w.add(path: "ünïcødé/名前.txt", data: Data("héllo".utf8), compression: .stored)
        try w.addDirectory(path: "folder")
        let bytes = try w.finish()

        let zip = try ZipArchive(data: bytes)
        XCTAssertEqual(zip.entries.map(\.path), ["docs/readme.txt", "bin/noise.dat", "empty.txt", "ünïcødé/名前.txt", "folder/"])
        XCTAssertEqual(try zip.data(named: "docs/readme.txt"), text)
        XCTAssertEqual(try zip.data(named: "bin/noise.dat"), noise)
        XCTAssertEqual(try zip.data(named: "empty.txt"), Data())
        XCTAssertEqual(String(decoding: try zip.data(named: "ünïcødé/名前.txt"), as: UTF8.self), "héllo")
        let readme = try XCTUnwrap(zip.entry(named: "docs/readme.txt"))
        XCTAssertEqual(readme.method, 8)
        XCTAssertLessThan(readme.compressedSize, readme.uncompressedSize / 10)
        XCTAssertEqual(zip.entry(named: "bin/noise.dat")?.method, 0, "incompressible data is stored")
        XCTAssertTrue(try XCTUnwrap(zip.entry(named: "folder/")).isDirectory)
        XCTAssertThrowsError(try zip.data(named: "missing")) { XCTAssertEqual($0 as? ZipError, .entryNotFound("missing")) }
    }

    func testStreamingEntryUsesDataDescriptorAndStreamsBack() throws {
        let url = Fixtures.tempDir("zip").appendingPathComponent("stream.zip")
        let w = try ZipWriter(url: url)
        var remaining = 200
        var expected = Data()
        try w.add(path: "big.csv") {
            guard remaining > 0 else { return nil }
            remaining -= 1
            let chunk = Data("row,\(remaining),some repeated payload\n".utf8)
            expected.append(chunk)
            return chunk
        }
        try w.add(path: "after.txt", data: Data("x".utf8))
        try w.finish()

        let zip = try ZipArchive(url: url)
        let e = try XCTUnwrap(zip.entry(named: "big.csv"))
        XCTAssertEqual(e.flags & 0x0008, 0x0008)
        XCTAssertEqual(e.uncompressedSize, UInt64(expected.count))
        var chunks = 0
        var got = Data()
        try zip.read(e, chunkSize: 512) { got.append($0); chunks += 1 }
        XCTAssertEqual(got, expected)
        XCTAssertGreaterThan(chunks, 3)
        XCTAssertEqual(try zip.data(named: "after.txt"), Data("x".utf8))
        // The system unzip agrees.
        let t = try Fixtures.run("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(t.status, 0, t.output)
    }

    func testReadsArchiveMadeBySystemZip() throws {
        let dir = Fixtures.tempDir("syszip")
        let src = dir.appendingPathComponent("src/sub")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let a = Data(String(repeating: "abc ", count: 5000).utf8)
        try a.write(to: dir.appendingPathComponent("src/a.txt"))
        try Data("tiny".utf8).write(to: src.appendingPathComponent("b.txt"))
        let r = try Fixtures.run("/usr/bin/zip", ["-r", "-q", "../out.zip", "."], cwd: dir.appendingPathComponent("src"))
        XCTAssertEqual(r.status, 0, r.output)
        let zip = try ZipArchive(url: dir.appendingPathComponent("out.zip"))
        XCTAssertEqual(try zip.data(named: "a.txt"), a)
        XCTAssertEqual(try zip.data(named: "sub/b.txt"), Data("tiny".utf8))
        XCTAssertTrue(zip.contains("sub/"))

        // Piped input makes zip emit a data descriptor (streaming entry).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf 'streamed content %s' 123 | /usr/bin/zip -q \"\(dir.path)/piped.zip\" -"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let piped = try ZipArchive(url: dir.appendingPathComponent("piped.zip"))
        XCTAssertEqual(piped.entries.count, 1)
        XCTAssertEqual(String(decoding: try piped.data(for: piped.entries[0]), as: UTF8.self), "streamed content 123")
    }

    func testSystemUnzipExtractsOurArchive() throws {
        let dir = Fixtures.tempDir("unzip")
        let url = dir.appendingPathComponent("ours.zip")
        let payload = randomData(10_000) + Data(String(repeating: "z", count: 30_000).utf8)
        let w = try ZipWriter(url: url)
        try w.add(path: "a/one.bin", data: payload)
        try w.add(path: "two.txt", data: Data("second".utf8))
        try w.finish()
        XCTAssertEqual(try Fixtures.run("/usr/bin/unzip", ["-t", url.path]).status, 0)
        let out = dir.appendingPathComponent("out")
        let r = try Fixtures.run("/usr/bin/unzip", ["-q", url.path, "-d", out.path])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a/one.bin")), payload)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("two.txt"), encoding: .utf8), "second")
    }

    func testZip64RoundTripAndSystemUnzip() throws {
        let dir = Fixtures.tempDir("zip64")
        let url = dir.appendingPathComponent("z64.zip")
        let w = try ZipWriter(url: url)
        w.forceZip64 = true
        let body = Data(String(repeating: "zip64 ", count: 2000).utf8)
        try w.add(path: "one.txt", data: body)
        var sent = false
        try w.add(path: "two.txt") { if sent { return nil }; sent = true; return body }
        try w.finish()
        let zip = try ZipArchive(url: url)
        XCTAssertEqual(zip.entries.count, 2)
        XCTAssertEqual(try zip.data(named: "one.txt"), body)
        XCTAssertEqual(try zip.data(named: "two.txt"), body)
        let t = try Fixtures.run("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(t.status, 0, t.output)
    }

    func testZipSlipIsRejected() throws {
        XCTAssertNil(ZipArchive.sanitizedPath("../evil.txt"))
        XCTAssertNil(ZipArchive.sanitizedPath("/etc/passwd"))
        XCTAssertNil(ZipArchive.sanitizedPath("a/../../b"))
        XCTAssertNil(ZipArchive.sanitizedPath("C:\\windows\\x"))
        XCTAssertNil(ZipArchive.sanitizedPath("..\\x"))
        XCTAssertEqual(ZipArchive.sanitizedPath("a/./b//c.txt"), "a/b/c.txt")
        XCTAssertThrowsError(try ZipWriter().add(path: "../x", data: Data()))

        // Hand-patch an entry name so the archive itself is malicious.
        var bytes = try ZipWriter.archive([(path: "aa/evil.txt", data: Data("boom".utf8))], compression: .stored)
        let needle = Data("aa/evil.txt".utf8), swap = Data("../evil.txt".utf8)
        var patched = 0
        while let r = bytes.range(of: needle) { bytes.replaceSubrange(r, with: swap); patched += 1 }
        XCTAssertEqual(patched, 2)
        let zip = try ZipArchive(data: bytes)
        XCTAssertEqual(zip.entries.first?.path, "../evil.txt")
        let dest = Fixtures.tempDir("slip").appendingPathComponent("inner")
        XCTAssertThrowsError(try zip.extractAll(to: dest)) { XCTAssertEqual($0 as? ZipError, .unsafePath("../evil.txt")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    func testDecompressionBombAndCorruptionAreRejected() throws {
        let big = Data(repeating: 0, count: 5_000_000)
        let bytes = try ZipWriter.archive([(path: "zeros.bin", data: big)])
        XCTAssertLessThan(bytes.count, 20_000)
        XCTAssertThrowsError(try ZipArchive(data: bytes, limits: .init(maxTotalUncompressedSize: 1_000_000))) {
            guard case ZipError.tooLarge = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNoThrow(try ZipArchive(data: bytes, limits: .init(maxTotalUncompressedSize: 6_000_000)))

        // An entry that lies about its size must not be allowed to expand past the declared size.
        var lying = bytes
        let cd = try XCTUnwrap(lying.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        let sizeOffset = cd.lowerBound + 24
        lying.replaceSubrange(sizeOffset..<(sizeOffset + 4), with: Data([0x10, 0, 0, 0]))
        let liar = try ZipArchive(data: lying)
        XCTAssertEqual(liar.entries[0].uncompressedSize, 16)
        XCTAssertThrowsError(try liar.data(for: liar.entries[0]))

        // Flip a payload byte: CRC must catch it.
        var corrupt = try ZipWriter.archive([(path: "s.txt", data: Data("stored payload".utf8))], compression: .stored)
        let at = try XCTUnwrap(corrupt.range(of: Data("stored".utf8))).lowerBound
        corrupt[at] = UInt8(ascii: "S")
        let bad = try ZipArchive(data: corrupt)
        XCTAssertThrowsError(try bad.data(named: "s.txt")) { XCTAssertEqual($0 as? ZipError, .crcMismatch("s.txt")) }

        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip at all, sorry".utf8))) { XCTAssertEqual($0 as? ZipError, .notAZip) }
    }

    func testExtractAll() throws {
        let bytes = try ZipWriter.archive([(path: "x/y/z.txt", data: Data("deep".utf8)), (path: "top.txt", data: Data("top".utf8))])
        let dest = Fixtures.tempDir("extract")
        try ZipArchive(data: bytes).extractAll(to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("x/y/z.txt"), encoding: .utf8), "deep")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("top.txt"), encoding: .utf8), "top")
    }
}
