import XCTest
import SQLite3
import FacetCore
@testable import FacetQuery

/// A temporary directory per test case, removed afterwards. Connector tests create every fixture here.
class FixtureTestCase: XCTestCase {
    var dir: URL!
    var env: QueryEnvironment!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FacetQueryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env = QueryEnvironment(baseDirectory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ name: String, _ data: Data) throws -> String {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }
    @discardableResult
    func write(_ name: String, _ text: String, encoding: String.Encoding = .utf8) throws -> String {
        try write(name, try XCTUnwrap(text.data(using: encoding)))
    }
    func eval(_ text: String) throws -> MValue { try MInterpreter(environment: env).evaluate(text) }
    /// The M error (reason and message) raised by an expression, or nil when it succeeds.
    func failure(_ text: String) -> MError? {
        do { _ = try eval(text); return nil } catch { return MError.wrap(error) }
    }
    /// Evaluate a table expression and render it row-major (see `show`).
    func rows(_ text: String) throws -> [[String]] { try tableRows(try eval(text)) }
    func engine(_ queries: [(String, String)]) -> QueryEngine {
        QueryEngine(queries: queries.map { QueryDefinition(name: $0.0, mScript: $0.1) }, environment: env)
    }
}

/// A compact, unambiguous rendering of a cell for assertions.
func show(_ v: MValue) -> String {
    switch v.forcedCell() {
    case .null: return "null"
    case .text(let s): return s
    case .number(let d): return MSyntax.number(d)
    case .logical(let b): return b ? "true" : "false"
    case .error: return "<error>"
    case .table: return "<table>"
    case .list(let l): return "{" + l.map(show).joined(separator: ",") + "}"
    case .record(let r): return "[" + zip(r.names, r.cells).map { "\($0)=\(show($1))" }.joined(separator: ",") + "]"
    case .binary(let d): return "<binary \(d.count)>"
    case let other: return MSyntax.literal(other)
    }
}
func tableRows(_ v: MValue) throws -> [[String]] {
    guard case .table(let t) = v else { XCTFail("not a table: \(v.typeName)"); return [] }
    return try t.rows.map { $0.map(show) }
}
func columnNames(_ v: MValue) -> [String] { v.tableValue?.columnNames ?? [] }

/// Writes ZIP archives with stored (uncompressed) entries.
enum TestZip {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    static func archive(_ entries: [(String, String)]) -> Data {
        var out = Data(), directory = Data()
        func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func put32(_ d: inout Data, _ v: Int) { put16(&d, v & 0xFFFF); put16(&d, (v >> 16) & 0xFFFF) }
        for (name, text) in entries {
            let body = Data(text.utf8), nameBytes = Data(name.utf8), offset = out.count, crc = Int(crc32(body))
            func sizes(_ d: inout Data) {
                put32(&d, crc); put32(&d, body.count); put32(&d, body.count); put16(&d, nameBytes.count); put16(&d, 0)
            }
            put32(&out, 0x04034b50)
            for _ in 0..<5 { put16(&out, 0) } // version, flags, method (stored), time, date
            sizes(&out)
            out.append(nameBytes); out.append(body)
            put32(&directory, 0x02014b50)
            for _ in 0..<6 { put16(&directory, 0) } // versions, flags, method, time, date
            sizes(&directory)
            for _ in 0..<3 { put16(&directory, 0) } // comment length, disk, internal attributes
            put32(&directory, 0); put32(&directory, offset)
            directory.append(nameBytes)
        }
        let start = out.count
        out.append(directory)
        put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0); put16(&out, entries.count); put16(&out, entries.count)
        put32(&out, directory.count); put32(&out, start); put16(&out, 0)
        return out
    }
}

/// Builds small SQLite databases for tests.
enum TestSQLite {
    static func create(at path: String, _ statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw MError("could not create the test database") }
        defer { sqlite3_close(db) }
        for s in statements {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, s, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "?"
                sqlite3_free(message)
                throw MError("test database: \(text) in \(s)")
            }
        }
    }
}
