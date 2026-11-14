import Foundation

/// PostgreSQL protocol 3.0 messages: what the client sends, and parsing of what the server sends.
enum PGMessage {
    static let protocolVersion: Int32 = 196_608 // 3.0
    static let sslRequestCode: Int32 = 80_877_103
    static let cancelRequestCode: Int32 = 80_877_102

    /// A typed frontend message: type byte, length (including itself), body.
    static func frame(_ type: UInt8, _ body: Data) -> Data {
        var w = ByteWriter()
        w.u8(type)
        w.i32BE(Int32(body.count + 4))
        w.append(body)
        return w.data
    }

    static func sslRequest() -> Data {
        var w = ByteWriter()
        w.i32BE(8); w.i32BE(sslRequestCode)
        return w.data
    }

    static func startup(_ parameters: [(String, String)]) -> Data {
        var body = ByteWriter()
        body.i32BE(protocolVersion)
        for (k, v) in parameters { body.cString(k); body.cString(v) }
        body.u8(0)
        var w = ByteWriter()
        w.i32BE(Int32(body.data.count + 4))
        w.append(body.data)
        return w.data
    }

    static func cancel(processID: Int32, secretKey: Data) -> Data {
        var w = ByteWriter()
        w.i32BE(Int32(12 + secretKey.count)); w.i32BE(cancelRequestCode); w.i32BE(processID); w.append(secretKey)
        return w.data
    }

    static func password(_ text: String) -> Data {
        var w = ByteWriter(); w.cString(text)
        return frame(UInt8(ascii: "p"), w.data)
    }
    static func saslInitial(mechanism: String, _ initial: String) -> Data {
        var w = ByteWriter()
        w.cString(mechanism)
        let bytes = Data(initial.utf8)
        w.i32BE(Int32(bytes.count)); w.append(bytes)
        return frame(UInt8(ascii: "p"), w.data)
    }
    static func saslResponse(_ text: String) -> Data { frame(UInt8(ascii: "p"), Data(text.utf8)) }

    static func query(_ sql: String) -> Data {
        var w = ByteWriter(); w.cString(sql)
        return frame(UInt8(ascii: "Q"), w.data)
    }
    /// Parse into the unnamed statement; parameter types are left for the server to infer.
    static func parse(_ sql: String) -> Data {
        var w = ByteWriter()
        w.cString(""); w.cString(sql); w.i16BE(0)
        return frame(UInt8(ascii: "P"), w.data)
    }
    /// Bind the unnamed portal: text parameters (nil = NULL) and a result format per column (1 = binary).
    static func bind(parameters: [String?], resultFormats: [Int16]) -> Data {
        var w = ByteWriter()
        w.cString(""); w.cString("")
        w.i16BE(0)
        w.i16BE(Int16(clamping: parameters.count))
        for p in parameters {
            if let p {
                let b = Data(p.utf8)
                w.i32BE(Int32(b.count)); w.append(b)
            } else {
                w.i32BE(-1)
            }
        }
        w.i16BE(Int16(clamping: resultFormats.count))
        for f in resultFormats { w.i16BE(f) }
        return frame(UInt8(ascii: "B"), w.data)
    }
    static func describeStatement() -> Data { frame(UInt8(ascii: "D"), Data([UInt8(ascii: "S"), 0])) }
    static func execute(maxRows: Int32) -> Data {
        var w = ByteWriter(); w.cString(""); w.i32BE(maxRows)
        return frame(UInt8(ascii: "E"), w.data)
    }
    static func sync() -> Data { frame(UInt8(ascii: "S"), Data()) }
    static func terminate() -> Data { frame(UInt8(ascii: "X"), Data()) }

    // MARK: Backend

    /// One field of a RowDescription.
    struct Field: Equatable {
        var name: String
        var typeOID: Int32
        var format: Int16
    }

    static func rowDescription(_ body: Data, maxColumns: Int) throws -> [Field] {
        var r = ByteReader(body, what: "row description")
        let n = Int(try r.i16BE())
        guard n >= 0, n <= maxColumns else { throw WireError("The result has more columns (\(n)) than the limit of \(maxColumns).") }
        var out: [Field] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let name = try r.cText()
            try r.skip(6) // table OID, column number
            let oid = try r.i32BE()
            try r.skip(6) // type size, type modifier
            out.append(Field(name: name, typeOID: oid, format: try r.i16BE()))
        }
        return out
    }

    /// The cells of a DataRow (nil = NULL), each bounded by the message.
    static func dataRow(_ body: Data, columns: Int) throws -> [Data?] {
        var r = ByteReader(body, what: "data row")
        let n = Int(try r.i16BE())
        guard n == columns else { throw WireError.malformed("data row (column count)") }
        var out: [Data?] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let len = Int(try r.i32BE())
            if len == -1 { out.append(nil) } else { out.append(try r.bytes(len)) }
        }
        return out
    }

    /// ErrorResponse / NoticeResponse fields by code ('S' severity, 'C' SQLSTATE, 'M' message, 'D' detail, 'H' hint).
    static func fields(_ body: Data) throws -> [Character: String] {
        var r = ByteReader(body, what: "error response")
        var out: [Character: String] = [:]
        while true {
            let code = try r.u8()
            if code == 0 { break }
            out[Character(UnicodeScalar(code))] = try r.cText()
        }
        return out
    }

    static func error(from fields: [Character: String]) -> WireError {
        var text = "PostgreSQL: " + (fields["M"] ?? "unknown error")
        if let d = fields["D"], !d.isEmpty { text += " " + d }
        if let h = fields["H"], !h.isEmpty { text += " Hint: " + h }
        if let c = fields["C"] { text += " (SQLSTATE \(c))" }
        return WireError(text, code: fields["C"])
    }
}
