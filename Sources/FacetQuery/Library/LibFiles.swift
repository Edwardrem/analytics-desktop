import Foundation
import FacetCore

extension MInterpreter {
    /// Read a local file for a connector: records the data source, enforces the size limit, and reports
    /// missing or unreadable files as `DataSource.Error`.
    /// `kind` nil reads a file that belongs to a source already recorded (a file inside a `Folder.Files` listing).
    func readFile(_ path: String, kind: String? = "File") throws -> Data {
        let url = resolvePath(path)
        if let kind { try noteDataSource(kind: kind, location: url.path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MError.dataSource("Could not find the file '\(url.path)'.")
        }
        if isDirectory.boolValue { throw MError.dataSource("'\(url.path)' is a folder, not a file. Use Folder.Files to read a folder.") }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        try checkSize(size, of: "The file '\(url.path)'")
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw MError.dataSource("Could not read the file '\(url.path)': \(error.localizedDescription)")
        }
    }
    func checkSize(_ bytes: Int, of what: String) throws {
        if bytes > environment.maxSourceBytes {
            throw MError.dataSource("\(what) is too large to load (\(bytes) bytes; the limit is \(environment.maxSourceBytes) bytes).")
        }
    }
}

extension MLibrary {
    /// The bytes of a "binary or text" source argument.
    static func sourceData(_ a: MArgs, _ i: Int) throws -> Data {
        switch a[i] {
        case .binary(let d): return d
        case .text(let s): return Data(s.utf8)
        default: throw MError.typeMismatch(expected: "binary", got: a[i])
        }
    }
    static func sourceText(_ a: MArgs, _ i: Int, codePage: Int?) throws -> String {
        if case .text(let s) = a[i] { return s }
        return try MText.decode(try a.binary(i), codePage: codePage)
    }

    static func registerFiles(_ lib: MLibrary) {
        lib.enumeration("BinaryEncoding", [("Base64", 0), ("Hex", 1)])
        lib.enumeration("Compression", [("None", -1), ("GZip", 0), ("Deflate", 1), ("Snappy", 2), ("Brotli", 3), ("LZ4", 4), ("Zstandard", 5)])
        lib.enumeration("CsvStyle", [("QuoteAfterDelimiter", 0), ("QuoteAlways", 1)])

        lib.fn("File.Contents", 1...2) { a, ctx in .binary(try ctx.readFile(try a.text(0))) }
        func listing(_ name: String, recursive: Bool) {
            lib.fn(name, 1...2) { a, ctx in
                let root = ctx.resolvePath(try a.text(0))
                try ctx.noteDataSource(kind: "Folder", location: root.path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MError.dataSource("Could not find the folder '\(root.path)'.")
                }
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentAccessDateKey, .isHiddenKey]
                var urls: [URL] = []
                if recursive {
                    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
                        throw MError.dataSource("Could not read the folder '\(root.path)'.")
                    }
                    for case let u as URL in walker where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { urls.append(u) }
                } else {
                    do { urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) } catch {
                        throw MError.dataSource("Could not read the folder '\(root.path)': \(error.localizedDescription)")
                    }
                }
                urls.sort { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
                let offset = Double(ctx.environment.timeZone.secondsFromGMT())
                func stamp(_ d: Date?) -> MValue { d.map { .datetime($0.addingTimeInterval(offset)) } ?? .null }
                let rows = urls.map { u -> [MValue] in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    let isFolder = v?.isDirectory ?? false, path = u.standardizedFileURL.path
                    let content: MValue = isFolder
                        ? .lazy(MThunk { try ctx.invoke(lib.values[name] ?? .null, [.text(path)]) })
                        : .lazy(MThunk { .binary(try ctx.readFile(path, kind: nil)) })
                    let attributes = MRecord(names: ["Hidden", "Directory", "Size", "Kind"],
                                             values: [.logical(v?.isHidden ?? false), .logical(isFolder), .int(v?.fileSize ?? 0), .text(isFolder ? "Folder" : "File")])
                    let ext = u.pathExtension
                    var folder = u.deletingLastPathComponent().standardizedFileURL.path
                    if !folder.hasSuffix("/") { folder += "/" }
                    return [content, .text(u.lastPathComponent), .text(ext.isEmpty ? "" : "." + ext), stamp(v?.contentAccessDate),
                            stamp(v?.contentModificationDate), stamp(v?.creationDate), .record(attributes), .text(folder)]
                }
                return .table(MTable(names: ["Content", "Name", "Extension", "Date accessed", "Date modified", "Date created", "Attributes", "Folder Path"],
                                     types: [.any, .text, .text, .nullable(.datetime), .nullable(.datetime), .nullable(.datetime), .anyRecord, .text], rows: rows))
            }
        }
        listing("Folder.Files", recursive: true)
        listing("Folder.Contents", recursive: false)

        // MARK: Binary and lines
        lib.fn("Binary.Length", 1) { a, _ in .int(try a.binary(0).count) }
        lib.fn("Binary.Buffer", 1) { a, _ in a[0] }
        lib.fn("Binary.ToList", 1) { a, _ in .list(try a.binary(0).map { .int(Int($0)) }) }
        lib.fn("Binary.FromList", 1) { a, _ in
            .binary(Data(try a.forcedList(0).map { v -> UInt8 in
                guard case .number(let n) = v, n >= 0, n <= 255 else { throw MError("Binary bytes must be numbers 0-255.") }
                return UInt8(n)
            }))
        }
        lib.fn("Binary.Combine", 1) { a, _ in
            .binary(try a.forcedList(0).reduce(into: Data()) { acc, v in
                guard case .binary(let d) = v else { throw MError.typeMismatch(expected: "binary", got: v) }
                acc.append(d)
            })
        }
        lib.fn("Binary.FromText", 1...2) { a, _ in
            if a[0].isNull { return .null }
            let s = try a.text(0)
            if (try a.optInt(1) ?? 0) == 1 {
                let hex = Array(s.utf8)
                guard hex.count % 2 == 0, let bytes = Optional(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(decoding: hex[$0..<($0 + 2)], as: UTF8.self), radix: 16) }),
                      !bytes.contains(nil) else { throw MError("The text is not valid hexadecimal.") }
                return .binary(Data(bytes.compactMap { $0 }))
            }
            guard let d = Data(base64Encoded: s) else { throw MError("The text is not valid Base64.") }
            return .binary(d)
        }
        lib.fn("Binary.ToText", 1...2) { a, _ in
            if a[0].isNull { return .null }
            let d = try a.binary(0)
            return .text((try a.optInt(1) ?? 0) == 1 ? d.map { String(format: "%02X", $0) }.joined() : d.base64EncodedString())
        }
        lib.fn("Binary.From", 1...2) { a, _ in
            switch a[0] {
            case .null, .binary: return a[0]
            case .text(let s):
                guard let d = Data(base64Encoded: s) else { throw MError("The text is not valid Base64.") }
                return .binary(d)
            default: throw MError.typeMismatch(expected: "binary", got: a[0])
            }
        }
        func lines(_ s: String) -> [MValue] {
            var out = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            if out.last == "" { out.removeLast() }
            return out.map(MValue.text)
        }
        lib.fn("Lines.FromBinary", 1...4) { a, _ in .list(lines(try sourceText(a, 0, codePage: try a.optInt(3)))) }
        lib.fn("Lines.FromText", 1...3) { a, _ in .list(lines(try a.text(0))) }
        lib.fn("Lines.ToText", 1...2) { a, _ in
            let sep = try a.optText(1) ?? "\r\n"
            return .text(try a.textList(0).map { $0 + sep }.joined())
        }
        lib.fn("Lines.ToBinary", 1...4) { a, _ in
            let sep = try a.optText(1) ?? "\r\n"
            return .binary(try MText.encode(try a.textList(0).map { $0 + sep }.joined(), codePage: try a.optInt(2)))
        }

        // MARK: Csv
        lib.fn("Csv.Document", 1...5) { a, ctx in
            var delimiter = ",", codePage: Int?, quoteStyle = 1
            var columns: (names: [String], types: [MType]?)?
            if case .record(let o) = a[1] {
                delimiter = try o.text("Delimiter") ?? delimiter
                codePage = try o.number("Encoding").map { Int($0) }
                quoteStyle = try o.number("QuoteStyle").map { Int($0) } ?? quoteStyle
                if let c = try o.get("Columns"), !c.isNull { columns = try MLib.columnSpec(c, defaultCount: 0) }
            } else if !a[1].isNull { columns = try MLib.columnSpec(a[1], defaultCount: 0) }
            if case .text(let d) = a[2] { delimiter = d }
            if let e = try a.optInt(4) { codePage = e }
            guard !delimiter.isEmpty else { throw MError("Csv.Document: the delimiter can't be empty.") }
            try ctx.checkSize(try sourceData(a, 0).count, of: "The CSV document")
            let rows = CsvParser.parse(try sourceText(a, 0, codePage: codePage), delimiter: delimiter, quotedLineBreaks: quoteStyle == 1)
            let width = columns?.names.count ?? rows.map(\.count).max() ?? 0
            let names = columns?.names ?? (0..<width).map { "Column\($0 + 1)" }
            var cols = [[MValue]](repeating: [], count: width)
            for c in 0..<width {
                cols[c].reserveCapacity(rows.count)
                for r in rows { cols[c].append(c < r.count ? .text(r[c]) : .null) }
            }
            return .table(try MTable.make(names, columns?.types ?? names.map { _ in .text }, cols, rows: rows.count))
        }
        registerJson(lib)
        registerXml(lib)
        registerExcel(lib)
        for (name, what) in [("Parquet.Document", "Parquet files"), ("Pdf.Tables", "PDF files"), ("Access.Database", "Access databases")] {
            lib.fn(name, 0...4) { _, _ in
                throw MError.dataSource("\(what) can't be read by this version of \(AppIdentity.name): the \(name) connector isn't available.")
            }
        }
    }
}

/// RFC 4180-style delimited text reader: quoted fields, doubled quotes, CR / LF / CRLF row ends.
enum CsvParser {
    /// Rows of fields. With `quotedLineBreaks` a line break inside quotes is data (`QuoteStyle.Csv`);
    /// otherwise every line break ends the row (`QuoteStyle.None`). An unterminated quote runs to the end of the input.
    static func parse(_ text: String, delimiter: String, quotedLineBreaks: Bool) -> [[String]] {
        let u = Array(text.utf8), d = Array(delimiter.utf8)
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = [], i = 0, inQuotes = false, sawAnything = false
        func endField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true) }
        func endRow() { endField(); rows.append(row); row = []; sawAnything = false }
        while i < u.count {
            let b = u[i]
            if inQuotes {
                if b == 34 {
                    if i + 1 < u.count, u[i + 1] == 34 { field.append(34); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                if !quotedLineBreaks, b == 10 || b == 13 { inQuotes = false; continue }
                field.append(b); i += 1; continue
            }
            if b == 34, field.isEmpty { inQuotes = true; sawAnything = true; i += 1; continue }
            if b == d[0], i + d.count <= u.count, d.count == 1 || Array(u[i..<(i + d.count)]) == d {
                endField(); sawAnything = true; i += d.count; continue
            }
            if b == 13 || b == 10 {
                if b == 13, i + 1 < u.count, u[i + 1] == 10 { i += 1 }
                endRow(); i += 1; continue
            }
            field.append(b); sawAnything = true; i += 1
        }
        if sawAnything || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
