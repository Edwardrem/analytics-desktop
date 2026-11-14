import Foundation
import FacetCore
import FacetInterop

/// The file formats Export data writes, registered as `VisualExport.dataExporters`: CSV (RFC 4180,
/// UTF-8 with a byte-order mark so Excel reads accents correctly), Excel (.xlsx, one sheet) and JSON
/// (an array of row objects, UTF-8).
/// Values are written unformatted, as Power BI's "Underlying data" and "Summarized data" exports do.
enum DataExporters {
    @MainActor
    static func register() {
        VisualExport.dataExporters["csv"] = { table, _, url in
            try Data(("\u{FEFF}" + csv(table)).utf8).write(to: url, options: .atomic)
        }
        VisualExport.dataExporters["xlsx"] = { table, _, url in
            try xlsx(table).write(to: url, options: .atomic)
        }
        VisualExport.dataExporters["json"] = { table, _, url in
            try json(table).write(to: url, options: .atomic)
        }
    }

    // MARK: JSON

    /// One object per row, keys in column order (a repeated column name gets " 2", " 3"…). Numbers and
    /// true/false stay typed, dates are ISO 8601 text ("2024-03-01", "2024-03-01T10:30:00" with a
    /// time of day), blanks and non-finite numbers are null.
    static func json(_ table: DataTable) -> Data {
        var taken = Set<String>()
        let keys = table.columns.map { column -> String in
            var name = column.name, n = 2
            while taken.contains(name) { name = "\(column.name) \(n)"; n += 1 }
            taken.insert(name)
            return jsonString(name)
        }
        var out = "["
        for r in 0..<table.rowCount {
            let fields = table.columns.indices.map { c in "\(keys[c]): \(jsonValue(table.columns[c].values[safe: r] ?? .null))" }
            out += (r == 0 ? "\n" : ",\n") + "  {" + fields.joined(separator: ", ") + "}"
        }
        out += table.rowCount == 0 ? "]\n" : "\n]\n"
        return Data(out.utf8)
    }

    static func jsonValue(_ value: Value) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            guard d.isFinite else { return "null" }
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return jsonString(s)
        case .date(let d):
            let hasTime = d.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) != 0
            return jsonString(ValueFormatter.formatDate(d, hasTime ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"))
        }
    }

    /// A JSON string literal: quotes, backslashes and control characters escaped.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    // MARK: CSV

    static func csv(_ table: DataTable) -> String {
        var out = table.columns.map { DAXResultFormat.csvField($0.name) }.joined(separator: ",") + "\r\n"
        for r in 0..<table.rowCount {
            out += table.columns.map { DAXResultFormat.csvField(DAXResultFormat.raw($0.values[r])) }.joined(separator: ",") + "\r\n"
        }
        return out
    }

    // MARK: Excel

    /// A minimal Office Open XML workbook: one sheet named "Data", a header row, numbers as
    /// numbers, dates as serial days with a date format, text as inline strings.
    static func xlsx(_ table: DataTable) throws -> Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var sheet = header + "<worksheet xmlns=\"\(main)\"><sheetData>"
        func text(_ s: String, _ ref: String) -> String { "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(s))</t></is></c>" }
        sheet += "<row r=\"1\">" + table.columns.enumerated().map { text($1.name, "\(column($0))1") }.joined() + "</row>"
        for r in 0..<table.rowCount {
            let line = r + 2
            sheet += "<row r=\"\(line)\">"
            for (c, col) in table.columns.enumerated() {
                let ref = "\(column(c))\(line)"
                switch col.values[r] {
                case .null: continue
                case .bool(let b): sheet += "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .int(let i): sheet += "<c r=\"\(ref)\"><v>\(i)</v></c>"
                case .double(let d):
                    sheet += d.isFinite ? "<c r=\"\(ref)\"><v>\(d)</v></c>" : ""
                case .date(let d):
                    let serial = Value.serial(from: d)
                    let style = serial == serial.rounded() ? 1 : 2
                    sheet += "<c r=\"\(ref)\" s=\"\(style)\"><v>\(serial)</v></c>"
                case .string(let s): sheet += text(s, ref)
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", header + """
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
                </Types>
                """),
            ("_rels/.rels", header + """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
                """),
            ("xl/workbook.xml", header + """
                <workbook xmlns="\(main)" xmlns:r="\(rel)"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>
                """),
            ("xl/_rels/workbook.xml.rels", header + """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="\(rel)/styles" Target="styles.xml"/></Relationships>
                """),
            ("xl/styles.xml", header + """
                <styleSheet xmlns="\(main)"><numFmts count="2">\
                <numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm:ss"/></numFmts>\
                <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
                <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
                <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
                <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
                <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
                <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
                <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs></styleSheet>
                """),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        return try ZipWriter.archive(parts.map { (path: $0.0, data: Data($0.1.utf8)) })
    }

    /// Column letters: 0 → A, 25 → Z, 26 → AA.
    static func column(_ index: Int) -> String {
        var n = index + 1, out = ""
        while n > 0 {
            let r = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + r))) + out
            n = (n - 1) / 26
        }
        return out
    }

    /// Text safe inside XML: markup characters escaped, characters XML 1.0 forbids dropped.
    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
