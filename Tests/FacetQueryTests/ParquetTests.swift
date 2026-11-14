import XCTest
import FacetCore
@testable import FacetQuery

/// `Parquet.Document` over hand-built files (see `ParquetFixture`), plus a cross-check against pyarrow when present.
final class ParquetTests: FixtureTestCase {
    private func load(_ data: Data) throws -> MValue {
        let path = try write("t.parquet", data)
        return try eval("Parquet.Document(File.Contents(\(MSyntax.text(path))))")
    }

    /// id INT64 required, name UTF8 optional with a null, PLAIN, uncompressed, one data page each.
    private func plainFile(codec: Int64 = 0, compress: ([UInt8]) -> [UInt8] = { $0 }) -> Data {
        var id = ParquetFixture.Column(name: "id", physical: 2)
        let idBody = ParquetFixture.plainInt64([1, 2, 3])
        id.pages = [ParquetFixture.dataPageV1(count: 3, body: compress(idBody), uncompressed: idBody.count)]
        id.valueCount = 3; id.codec = codec
        var name = ParquetFixture.Column(name: "name", physical: 6, optional: true, converted: 0)
        let defs = ParquetFixture.bitPacked([1, 0, 1], bitWidth: 1)
        let nameBody = ParquetFixture.le32(defs.count) + defs + ParquetFixture.plainStrings(["Ana", "Zoë"])
        name.pages = [ParquetFixture.dataPageV1(count: 3, body: compress(nameBody), uncompressed: nameBody.count)]
        name.valueCount = 3; name.codec = codec
        return ParquetFixture.file(schema: [id, name], rowGroups: [[id, name]], rows: [3])
    }

    func testPlainValuesWithNulls() throws {
        let v = try load(plainFile())
        XCTAssertEqual(columnNames(v), ["id", "name"])
        XCTAssertEqual(try tableRows(v), [["1", "Ana"], ["2", "null"], ["3", "Zoë"]])
        let types = v.tableValue?.columnTypes ?? []
        XCTAssertEqual(types.first, .int64)
        XCTAssertEqual(types.last, .nullable(.text))
    }

    func testSnappyPages() throws {
        XCTAssertEqual(try tableRows(try load(plainFile(codec: 1, compress: ParquetFixture.snappyLiterals))), [["1", "Ana"], ["2", "null"], ["3", "Zoë"]])
    }

    func testGzipPages() throws {
        XCTAssertEqual(try tableRows(try load(plainFile(codec: 2, compress: ParquetFixture.gzip))), [["1", "Ana"], ["2", "null"], ["3", "Zoë"]])
    }

    func testSnappyCopiesOverlapTheirOutput() throws {
        // "abc" then a 1-byte-offset copy of 9 bytes from 3 back: abcabcabcabc.
        let stream: [UInt8] = [12, 0x08] + Array("abc".utf8) + [0x15, 0x03]
        XCTAssertEqual(String(decoding: try ParquetCodecs.snappy(stream, expectedSize: 12), as: UTF8.self), "abcabcabcabc")
        // A 2-byte-offset copy (tag 10): "xy" then copy 4 from offset 2.
        let two: [UInt8] = [6, 0x04] + Array("xy".utf8) + [0x0E, 0x02, 0x00]
        XCTAssertEqual(String(decoding: try ParquetCodecs.snappy(two, expectedSize: 6), as: UTF8.self), "xyxyxy")
        XCTAssertThrowsError(try ParquetCodecs.snappy([12, 0x08] + Array("abc".utf8) + [0x15, 0x09], expectedSize: 12), "offset beyond output")
        XCTAssertThrowsError(try ParquetCodecs.snappy([12, 0x08] + Array("abc".utf8), expectedSize: 99), "length disagrees with the page")
    }

    func testDictionaryEncodingWithRLEAndBitPackedIndices() throws {
        var c = ParquetFixture.Column(name: "city", physical: 6, logical: [(1, .strct([]))])
        let dict = ParquetFixture.plainStrings(["Harare", "Bulawayo"])
        // 3 × index 0 as an RLE run, then 1, 0 bit-packed: Harare ×3, Bulawayo, Harare.
        let ids: [UInt8] = [1] + ParquetFixture.rleRun(0, count: 3, bitWidth: 1) + ParquetFixture.bitPacked([1, 0], bitWidth: 1)
        c.pages = [ParquetFixture.dictionaryPage(count: 2, body: dict), ParquetFixture.dataPageV1(count: 5, encoding: 8, body: ids)]
        c.valueCount = 5
        let v = try load(ParquetFixture.file(schema: [c], rowGroups: [[c]], rows: [5]))
        XCTAssertEqual(try tableRows(v).map { $0[0] }, ["Harare", "Harare", "Harare", "Bulawayo", "Harare"])
    }

    func testLogicalTypesAndDataPageV2() throws {
        // DATE (int32 days), TIMESTAMP(micros, not UTC), DECIMAL(9,2) in int32, BOOLEAN with RLE in a v2 page.
        var day = ParquetFixture.Column(name: "day", physical: 1, converted: 6)
        day.pages = [ParquetFixture.dataPageV1(count: 2, body: ParquetFixture.plainInt32([0, 19_723]))]      // 1970-01-01, 2024-01-01
        day.valueCount = 2
        var at = ParquetFixture.Column(name: "at", physical: 2, logical: [(8, .strct([(1, .bool(false)), (2, .strct([(2, .strct([]))]))]))])
        at.pages = [ParquetFixture.dataPageV1(count: 2, body: ParquetFixture.plainInt64([0, 1_704_110_400_000_000]))]   // 2024-01-01 12:00:00
        at.valueCount = 2
        var price = ParquetFixture.Column(name: "price", physical: 1, converted: 5, scale: 2)
        price.pages = [ParquetFixture.dataPageV1(count: 2, body: ParquetFixture.plainInt32([1999, -5]))]
        price.valueCount = 2
        var flag = ParquetFixture.Column(name: "flag", physical: 0)
        let rle = ParquetFixture.bitPacked([1, 0], bitWidth: 1)
        let values = ParquetFixture.le32(rle.count) + rle
        let gz = ParquetFixture.gzip(values)
        flag.pages = [ParquetFixture.Page([(1, .i32(3)), (2, .i32(Int64(values.count))), (3, .i32(Int64(gz.count))),
                        (8, .strct([(1, .i32(2)), (2, .i32(0)), (3, .i32(2)), (4, .i32(3)), (5, .i32(0)), (6, .i32(0))]))], gz)]
        flag.valueCount = 2; flag.codec = 2
        let v = try load(ParquetFixture.file(schema: [day, at, price, flag], rowGroups: [[day, at, price, flag]], rows: [2]))
        XCTAssertEqual(try tableRows(v), [
            ["#date(1970, 1, 1)", "#datetime(1970, 1, 1, 0, 0, 0)", "19.99", "true"],
            ["#date(2024, 1, 1)", "#datetime(2024, 1, 1, 12, 0, 0)", "-0.05", "false"],
        ])
    }

    func testRowGroupsAreConcatenated() throws {
        func group(_ xs: [Double]) -> ParquetFixture.Column {
            var c = ParquetFixture.Column(name: "x", physical: 5)
            c.pages = [ParquetFixture.dataPageV1(count: xs.count, body: ParquetFixture.plainDouble(xs))]
            c.valueCount = Int64(xs.count)
            return c
        }
        let file = ParquetFixture.file(schema: [group([])], rowGroups: [[group([1.5, 2])], [group([-3])]], rows: [2, 1])
        XCTAssertEqual(try tableRows(try load(file)).map { $0[0] }, ["1.5", "2", "-3"])
    }

    // MARK: Damaged and hostile input

    func testDamagedFilesFailWithDataFormatErrors() throws {
        let good = plainFile()
        for bad in [Data("PAR1".utf8), good.prefix(good.count - 3), Data("PAR1xxxxxxxx\u{FF}\u{FF}\u{FF}\u{7F}PAR1".utf8), Data(repeating: 0, count: 64)] {
            let path = try write("bad.parquet", bad)
            let e = failure("Parquet.Document(File.Contents(\(MSyntax.text(path))))")
            XCTAssertEqual(e?.reason, "DataFormat.Error", e?.message ?? "no error")
        }
    }

    func testADictionaryIndexOutOfRangeIsAnError() throws {
        var c = ParquetFixture.Column(name: "c", physical: 6, converted: 0)
        c.pages = [ParquetFixture.dictionaryPage(count: 1, body: ParquetFixture.plainStrings(["only"])), ParquetFixture.dataPageV1(count: 1, encoding: 8, body: [2] + ParquetFixture.rleRun(3, count: 1, bitWidth: 2))]
        c.valueCount = 1
        let path = try write("d.parquet", ParquetFixture.file(schema: [c], rowGroups: [[c]], rows: [1]))
        XCTAssertTrue(failure("Parquet.Document(File.Contents(\(MSyntax.text(path))))")?.message.contains("out of range") ?? false)
    }

    func testDeclaredSizesAboveTheLimitAreRefusedBeforeDecoding() throws {
        env.maxSourceBytes = 1 << 20
        var c = ParquetFixture.Column(name: "c", physical: 2)
        c.pages = [ParquetFixture.dataPageV1(count: 1, body: ParquetFixture.plainInt64([7]), uncompressed: 50 << 20)]
        c.valueCount = 1
        let e = failure("Parquet.Document(\(MSyntax.literal(.binary(ParquetFixture.file(schema: [c], rowGroups: [[c]], rows: [1])))))")
        XCTAssertTrue(e?.message.contains("limit") ?? false, e?.message ?? "no error")
    }

    func testUnsupportedCodecsSaySo() throws {
        var c = ParquetFixture.Column(name: "c", physical: 2)
        c.pages = [ParquetFixture.dataPageV1(count: 1, body: ParquetFixture.plainInt64([7]))]
        c.valueCount = 1; c.codec = 6
        let path = try write("z.parquet", ParquetFixture.file(schema: [c], rowGroups: [[c]], rows: [1]))
        XCTAssertTrue(failure("Parquet.Document(File.Contents(\(MSyntax.text(path))))")?.message.contains("Zstandard") ?? false)
    }

    // MARK: pyarrow cross-check (skipped when python3 with pyarrow isn't installed)

    func testMatchesPyarrowWhenAvailable() throws {
        let script = dir.appendingPathComponent("write.py")
        let out = dir.appendingPathComponent("arrow")
        try """
        import sys, datetime, decimal
        import pyarrow as pa, pyarrow.parquet as pq
        t = pa.table({
            "i": pa.array([1, None, 3, 4], pa.int32()),
            "s": pa.array(["a", "b", None, "a"]),
            "d": pa.array([1.25, 2.5, None, -1.0]),
            "b": pa.array([True, False, None, True]),
            "day": pa.array([datetime.date(2024, 2, 29), None, datetime.date(1999, 12, 31), datetime.date(1970, 1, 1)]),
            "ts": pa.array([datetime.datetime(2024, 1, 1, 8, 30), None, None, datetime.datetime(2000, 1, 1)], pa.timestamp("ms")),
            "dec": pa.array([decimal.Decimal("12.34"), None, decimal.Decimal("-0.01"), decimal.Decimal("0")], pa.decimal128(9, 2)),
        })
        for codec in ["snappy", "gzip", "none"]:
            for v in ["1.0", "2.0"]:
                pq.write_table(t, sys.argv[1] + "-" + codec + "-" + v + ".parquet", compression=codec, data_page_version=v)
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", script.path, out.path]
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run() } catch { throw XCTSkip("python3 is not available") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("pyarrow is not installed") }
        let expected = [
            ["1", "a", "1.25", "true", "#date(2024, 2, 29)", "#datetime(2024, 1, 1, 8, 30, 0)", "12.34"],
            ["null", "b", "2.5", "false", "null", "null", "null"],
            ["3", "null", "null", "null", "#date(1999, 12, 31)", "null", "-0.01"],
            ["4", "a", "-1", "true", "#date(1970, 1, 1)", "#datetime(2000, 1, 1, 0, 0, 0)", "0"],
        ]
        for codec in ["snappy", "gzip", "none"] {
            for v in ["1.0", "2.0"] {
                let path = out.path + "-\(codec)-\(v).parquet"
                XCTAssertEqual(try rows("Parquet.Document(File.Contents(\(MSyntax.text(path))))"), expected, "\(codec) v\(v)")
            }
        }
    }
}
