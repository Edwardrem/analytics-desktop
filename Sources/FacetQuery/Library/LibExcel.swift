import Foundation
import FacetCore

/// Reads the parts of an .xlsx / .xlsm workbook that Power Query exposes: sheets, tables and defined names.
final class XlsxWorkbook {
    struct Sheet { var name: String; var path: String; var hidden: Bool }
    struct Range { var firstRow: Int; var firstColumn: Int; var lastRow: Int; var lastColumn: Int }
    struct TablePart { var name: String; var sheet: Int; var range: Range; var headerRows: Int; var totalsRows: Int; var columns: [String] }

    private let zip: ZipReader
    private let limit: Int
    private(set) var sheets: [Sheet] = []
    private(set) var tables: [TablePart] = []
    private(set) var definedNames: [(name: String, sheet: Int, range: Range)] = []
    private var sharedStrings: [String] = []
    /// Per cell style index: 0 = not a date, 1 = date/time, 2 = time only.
    private var styleKinds: [Int] = []
    private var date1904 = false
    private var cellCache: [Int: [Int: [Int: MValue]]] = [:]

    private static let what = "The Excel workbook"
    private static func invalid(_ detail: String) -> MError { MError.dataFormat("\(what) couldn't be read: \(detail).") }

    init(_ data: Data, limit: Int) throws {
        zip = try ZipReader(data, describedAs: XlsxWorkbook.what)
        self.limit = limit
        guard let book = try xml("xl/workbook.xml") else {
            throw XlsxWorkbook.invalid(zip.contains("Workbook") || zip.contains("Book")
                ? "legacy .xls workbooks are not supported; save it as .xlsx" : "it has no workbook part (is it an .xlsx file?)")
        }
        let rels = try relationships("xl/_rels/workbook.xml.rels", base: "xl/")
        date1904 = ["1", "true"].contains(book.child("workbookPr")?.attribute("date1904") ?? "")
        for s in book.child("sheets")?.children(named: "sheet") ?? [] {
            guard let name = s.attribute("name"), let id = s.attribute("r:id"), let path = rels[id], path.contains("worksheets/") else { continue }
            sheets.append(Sheet(name: name, path: path, hidden: (s.attribute("state") ?? "visible") != "visible"))
        }
        if let sst = try xml("xl/sharedStrings.xml") { sharedStrings = sst.children(named: "si").map(XlsxWorkbook.richText) }
        if let styles = try xml("xl/styles.xml") { loadStyles(styles) }
        for (i, sheet) in sheets.enumerated() {
            let folder = (sheet.path as NSString).deletingLastPathComponent + "/"
            let relPath = folder + "_rels/" + (sheet.path as NSString).lastPathComponent + ".rels"
            for (_, target) in try relationships(relPath, base: folder) where target.contains("tables/") {
                guard let t = try xml(target), let ref = t.attribute("ref"), let range = XlsxWorkbook.range(ref) else { continue }
                tables.append(TablePart(name: t.attribute("displayName") ?? t.attribute("name") ?? "Table", sheet: i, range: range,
                                        headerRows: Int(t.attribute("headerRowCount") ?? "1") ?? 1, totalsRows: Int(t.attribute("totalsRowCount") ?? "0") ?? 0,
                                        columns: t.child("tableColumns")?.children(named: "tableColumn").compactMap { $0.attribute("name") } ?? []))
            }
        }
        tables.sort { $0.name < $1.name }
        for d in book.child("definedNames")?.children(named: "definedName") ?? [] {
            guard let name = d.attribute("name"), !name.hasPrefix("_xlnm."), let bang = d.text.lastIndex(of: "!") else { continue }
            var sheetName = String(d.text[..<bang])
            if sheetName.hasPrefix("'"), sheetName.hasSuffix("'"), sheetName.count >= 2 { sheetName = String(sheetName.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            guard let sheet = sheets.firstIndex(where: { $0.name == sheetName }),
                  let range = XlsxWorkbook.range(String(d.text[d.text.index(after: bang)...]).replacingOccurrences(of: "$", with: "")) else { continue }
            definedNames.append((name, sheet, range))
        }
    }

    private func xml(_ path: String) throws -> XmlElement? {
        guard let data = try zip.read(path, limit: limit) else { return nil }
        do { return try XmlElement.parse(data, namespaces: true) } catch { throw XlsxWorkbook.invalid("the part '\(path)' is damaged") }
    }
    /// Relationship id → archive path of its target.
    private func relationships(_ path: String, base: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for r in try xml(path)?.children(named: "Relationship") ?? [] {
            guard let id = r.attribute("Id"), let target = r.attribute("Target") else { continue }
            if target.hasPrefix("/") { out[id] = String(target.dropFirst()); continue }
            var parts = base.split(separator: "/").map(String.init)
            for p in target.split(separator: "/") { if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(String(p)) } }
            out[id] = parts.joined(separator: "/")
        }
        return out
    }
    /// Text of a shared-string item or inline string: all `<t>` runs, ignoring phonetic hints.
    private static func richText(_ si: XmlElement) -> String {
        var out = ""
        for c in si.children {
            if c.name == "t" { out += c.text } else if c.name == "r" { out += c.children(named: "t").map(\.text).joined() }
        }
        return out
    }
    private func loadStyles(_ styles: XmlElement) {
        var custom: [Int: String] = [:]
        for f in styles.child("numFmts")?.children(named: "numFmt") ?? [] {
            if let id = Int(f.attribute("numFmtId") ?? ""), let code = f.attribute("formatCode") { custom[id] = code }
        }
        styleKinds = (styles.child("cellXfs")?.children(named: "xf") ?? []).map { xf in
            let id = Int(xf.attribute("numFmtId") ?? "0") ?? 0
            if let code = custom[id] { return XlsxWorkbook.dateKind(formatCode: code) }
            if (14...17).contains(id) || id == 22 || (27...31).contains(id) || (34...36).contains(id) || (50...58).contains(id) { return 1 }
            if (18...21).contains(id) || id == 32 || id == 33 || (45...47).contains(id) { return 2 }
            return 0
        }
    }
    /// 0 = number format, 1 = has date parts, 2 = time parts only.
    static func dateKind(formatCode: String) -> Int {
        var bare = "", bracket = "", inQuote = false, inBracket = false, skip = false
        for ch in formatCode.lowercased() {
            if skip { skip = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket {
                if ch != "]" { bracket.append(ch); continue }
                inBracket = false
                // [h], [mm] and [ss] are elapsed-time parts; other brackets hold colours, conditions and locales
                if !bracket.isEmpty, bracket.allSatisfy({ "hms".contains($0) }) { bare += bracket.replacingOccurrences(of: "m", with: "") }
                bracket = ""
                continue
            }
            switch ch {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\", "_", "*": skip = true
            default: bare.append(ch)
            }
        }
        if bare.contains("general") { return 0 }
        if bare.contains("y") || bare.contains("d") { return 1 }
        if bare.contains("h") || bare.contains("s") { return 2 }
        return bare.contains("m") ? 1 : 0
    }

    /// "B2" → (row 1, column 1), zero-based.
    static func cell(_ ref: String) -> (row: Int, column: Int)? {
        var column = 0, row = 0, sawDigit = false
        for u in ref.unicodeScalars {
            if u.value >= 65, u.value <= 90, !sawDigit { column = column * 26 + Int(u.value - 64) }
            else if u.value >= 97, u.value <= 122, !sawDigit { column = column * 26 + Int(u.value - 96) }
            else if u.value >= 48, u.value <= 57 { row = row * 10 + Int(u.value - 48); sawDigit = true }
            else { return nil }
        }
        return column > 0 && row > 0 ? (row - 1, column - 1) : nil
    }
    static func range(_ ref: String) -> Range? {
        let parts = ref.split(separator: ":").map(String.init)
        guard let a = parts.first.flatMap(cell), let b = parts.last.flatMap(cell) else { return nil }
        return Range(firstRow: min(a.row, b.row), firstColumn: min(a.column, b.column), lastRow: max(a.row, b.row), lastColumn: max(a.column, b.column))
    }

    /// Cells of a sheet: row → column → value.
    private func cells(_ sheet: Int) throws -> [Int: [Int: MValue]] {
        if let c = cellCache[sheet] { return c }
        guard let root = try xml(sheets[sheet].path) else { throw XlsxWorkbook.invalid("the sheet '\(sheets[sheet].name)' is missing") }
        var out: [Int: [Int: MValue]] = [:]
        var nextRow = 0
        for r in root.child("sheetData")?.children(named: "row") ?? [] {
            let rowIndex = (Int(r.attribute("r") ?? "").map { $0 - 1 }) ?? nextRow
            nextRow = rowIndex + 1
            var nextColumn = 0
            for c in r.children(named: "c") {
                let column = c.attribute("r").flatMap(XlsxWorkbook.cell)?.column ?? nextColumn
                nextColumn = column + 1
                if let v = value(of: c) { out[rowIndex, default: [:]][column] = v }
            }
        }
        cellCache[sheet] = out
        return out
    }
    private func value(of c: XmlElement) -> MValue? {
        let type = c.attribute("t") ?? "n"
        if type == "inlineStr" { return c.child("is").map { .text(XlsxWorkbook.richText($0)) } }
        guard let raw = c.child("v")?.text else { return nil }
        switch type {
        case "s":
            guard let i = Int(raw), i >= 0, i < sharedStrings.count else { return .error(XlsxWorkbook.invalid("a cell refers to a missing shared string")) }
            return .text(sharedStrings[i])
        case "str": return .text(raw)
        case "b": return .logical(raw == "1")
        case "e": return .error(MError("The cell contains the Excel error \(raw).", reason: "DataFormat.Error", detail: .text(raw)))
        case "d": return (try? MConvert.toDateTime(.text(raw))) ?? .text(raw)
        default:
            guard let d = Double(raw) else { return .text(raw) }
            let style = Int(c.attribute("s") ?? "").flatMap { $0 >= 0 && $0 < styleKinds.count ? styleKinds[$0] : nil } ?? 0
            if style == 0 { return .number(d) }
            let seconds = ((d + (date1904 ? 1462 : 0)) * 86400 * 1000).rounded() / 1000
            if style == 2, d >= 0, d < 1 { return .time(seconds) }
            return .datetime(Value.date(fromSerial: 0).addingTimeInterval(seconds))
        }
    }

    /// The cells of a rectangle as a table with generated or given column names.
    func table(sheet: Int, range: Range?, names: [String]? = nil) throws -> MTable {
        let cells = try self.cells(sheet)
        var r = range
        if r == nil, let minRow = cells.keys.min(), let maxRow = cells.keys.max() {
            let columns = cells.values.flatMap(\.keys)
            r = Range(firstRow: minRow, firstColumn: columns.min() ?? 0, lastRow: maxRow, lastColumn: columns.max() ?? 0)
        }
        guard let r, r.lastRow >= r.firstRow else { return MTable(names: names ?? [], columns: (names ?? []).map { _ in [] }, rowCount: 0) }
        let width = r.lastColumn - r.firstColumn + 1
        var cols = [[MValue]](repeating: [], count: width)
        for row in r.firstRow...r.lastRow {
            let line = cells[row]
            for c in 0..<width { cols[c].append(line?[r.firstColumn + c] ?? .null) }
        }
        var header = (0..<width).map { "Column\($0 + 1)" }
        if let names { header = MLib.uniqued((0..<width).map { $0 < names.count ? names[$0] : "Column\($0 + 1)" }) }
        return MTable(names: header, columns: cols, rowCount: r.lastRow - r.firstRow + 1)
    }
    func table(_ t: TablePart) throws -> MTable {
        var r = t.range
        r.firstRow += t.headerRows; r.lastRow -= t.totalsRows
        return try table(sheet: t.sheet, range: r, names: t.columns)
    }
}

extension MLibrary {
    static func registerExcel(_ lib: MLibrary) {
        lib.fn("Excel.Workbook", 1...3) { a, ctx in
            var useHeaders = false
            if case .record(let o) = a[1] { useHeaders = try o.logical("UseHeaders") ?? false } else { useHeaders = try a.optLogical(1) ?? false }
            let data = try a.binary(0)
            try ctx.checkSize(data.count, of: "The Excel workbook")
            let book = try XlsxWorkbook(data, limit: ctx.environment.maxSourceBytes)
            func lazy(_ build: @escaping () throws -> MTable) -> MValue { .lazy(MThunk { .table(try build()) }) }
            func promoted(_ t: MTable) throws -> MTable {
                guard useHeaders, case .function(let f)? = lib.values["Table.PromoteHeaders"],
                      case .table(let p) = try ctx.call(f, [.table(t), .record(MRecord(names: ["PromoteAllScalars"], values: [.logical(true)]))]) else { return t }
                return p
            }
            var rows: [[MValue]] = []
            for (i, s) in book.sheets.enumerated() {
                rows.append([.text(s.name), lazy { try promoted(try book.table(sheet: i, range: nil)) }, .text(s.name), .text("Sheet"), .logical(s.hidden)])
            }
            for t in book.tables { rows.append([.text(t.name), lazy { try book.table(t) }, .text(t.name), .text("Table"), .logical(false)]) }
            for d in book.definedNames {
                rows.append([.text(d.name), lazy { try promoted(try book.table(sheet: d.sheet, range: d.range)) }, .text(d.name), .text("DefinedName"), .logical(false)])
            }
            return .table(MTable(names: ["Name", "Data", "Item", "Kind", "Hidden"], types: [.text, .anyTable, .text, .text, .logical], rows: rows))
        }
    }
}
