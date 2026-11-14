import Foundation
import FacetCore
import FacetQuery

/// What a web address serves, decided from its bytes (and, failing that, its extension).
enum WebContentKind: String, Sendable { case csv, json, xml, html, excel }

/// The connection details typed into Get Data.
struct SourceRequest: Equatable, Sendable {
    var kind: SourceKind
    /// File or folder path, web address, or script text.
    var location = ""
    var delimiter = ","
    /// Code page for text files (65001 = UTF-8).
    var encoding = 65001
    /// Optional SQL statement for database sources.
    var nativeQuery = ""
    var directQuery = false
    var webContent: WebContentKind = .csv

    init(kind: SourceKind, location: String = "") { self.kind = kind; self.location = location }
}

/// One object offered by the Navigator (a sheet, a database table, an entity set, an HTML table…).
struct NavigatorItem: Identifiable, Hashable, Sendable {
    var name: String
    /// "Sheet", "Table", "View", "DefinedName"…
    var kind: String
    /// M applied to the `Source` step to reach the object, e.g. `{[Item = "Sales", Kind = "Sheet"]}[Data]`.
    var selector: String
    /// Name of the navigation step in the generated query.
    var stepName: String
    var id: String { selector }

    var symbol: String {
        switch kind {
        case "Sheet": return "tablecells"
        case "View": return "eye"
        case "DefinedName": return "character.textbox"
        default: return "tablecells.badge.ellipsis"
        }
    }
}

/// Pure logic behind Get Data: M generation for sources and navigator objects, content sniffing, naming.
enum SourcePlanner {
    static let encodings: [(name: String, codePage: Int)] = [
        ("65001: Unicode (UTF-8)", 65001), ("1200: Unicode (UTF-16 LE)", 1200), ("1252: Western European (Windows)", 1252),
        ("28591: Western European (ISO)", 28591), ("10000: Western European (Mac)", 10000),
    ]
    static let delimiters: [(name: String, value: String)] = [
        ("Comma", ","), ("Semicolon", ";"), ("Tab", "\t"), ("Pipe", "|"), ("Space", " "), ("Colon", ":"),
    ]

    // MARK: Source step

    /// The M expression of the `Source` step.
    static func sourceExpression(_ r: SourceRequest) -> String {
        let location = MSyntax.text(r.location.trimmingCharacters(in: .whitespacesAndNewlines))
        func csv(_ binary: String) -> String {
            "Csv.Document(\(binary), [Delimiter = \(MSyntax.text(r.delimiter)), Encoding = \(r.encoding), QuoteStyle = QuoteStyle.Csv])"
        }
        switch r.kind {
        case .csv: return csv("File.Contents(\(location))")
        case .excel: return "Excel.Workbook(File.Contents(\(location)), null, true)"
        case .json: return "Json.Document(File.Contents(\(location)))"
        case .xml: return "Xml.Tables(File.Contents(\(location)))"
        case .folder: return "Folder.Files(\(location))"
        case .sqlite: return "Sqlite.Database(\(location))"
        case .odata: return "OData.Feed(\(location), null, [Implementation = \"2.0\"])"
        case .python: return "Python.Execute(\(MSyntax.text(r.location)))"
        case .r: return "R.Execute(\(MSyntax.text(r.location)))"
        case .blank: return "\"\""
        case .web:
            let contents = "Web.Contents(\(location))"
            switch r.webContent {
            case .csv: return csv(contents)
            case .json: return "Json.Document(\(contents))"
            case .xml: return "Xml.Tables(\(contents))"
            case .html: return "Web.Page(\(contents))"
            case .excel: return "Excel.Workbook(\(contents), null, true)"
            }
        }
    }

    /// The steps every query of this source starts with: `Source`, plus the native query when one was typed.
    static func sourceSteps(_ r: SourceRequest) -> [MStep] {
        var steps = [MStep(name: "Source", expression: sourceExpression(r))]
        let sql = r.nativeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.kind == .sqlite, !sql.isEmpty {
            steps.append(MStep(name: "Query", expression: "Value.NativeQuery(Source, \(MSyntax.text(sql)), null, [EnableFolding = true])"))
        }
        return steps
    }

    /// The query for a navigator object (or for the source itself when `item` is nil), before shaping steps.
    static func baseSteps(_ r: SourceRequest, item: NavigatorItem?) -> [MStep] {
        var steps = sourceSteps(r)
        if let item, let last = steps.last {
            steps.append(MStep(name: item.stepName, expression: MSyntax.identifier(last.name) + item.selector))
        }
        return steps
    }

    // MARK: Navigator

    /// The objects of a navigation table (a table with a label column and a column of tables), or nil when the
    /// value is ordinary data.
    static func navigatorItems(from value: MValue) throws -> [NavigatorItem]? {
        guard case .table(let t) = value, !t.isLazy else { return nil }
        let columns = try t.columns, rowCount = try t.rowCount
        guard rowCount > 0 else { return nil }
        guard let dataName = ["Data", "Table", "Value"].first(where: { name in
            guard let i = t.columnIndex(name) else { return false }
            if case .table = t.columnTypes[i] { return true }
            return columns[i].allSatisfy { cell in
                switch cell { case .table, .lazy: return true; default: return false }
            }
        }) else { return nil }
        guard let labelName = ["Name", "Caption", "Item"].first(where: { t.columnIndex($0) != nil }), let label = t.columnIndex(labelName) else { return nil }
        func text(_ column: String, _ row: Int) -> String? {
            guard let i = t.columnIndex(column) else { return nil }
            return columns[i][row].forcedCell().textValue
        }
        let labels = (0..<rowCount).map { columns[label][$0].forcedCell().textValue }
        let labelsAreKeys = labels.allSatisfy { $0 != nil } && Set(labels).count == labels.count
        var items: [NavigatorItem] = []
        for row in 0..<rowCount {
            let kind = text("Kind", row) ?? "Table"
            let name = labels[row] ?? "Table \(row + 1)"
            let key: String, step: String
            if let item = text("Item", row), text("Kind", row) != nil, labelName == "Name" {
                key = "[Item = \(MSyntax.text(item)), Kind = \(MSyntax.text(kind))]"
                step = "\(item)_\(kind)"
            } else if let schema = text("Schema", row), let item = text("Item", row) {
                key = "[Schema = \(MSyntax.text(schema)), Item = \(MSyntax.text(item))]"
                step = "\(schema)_\(item)"
            } else if labelsAreKeys, let l = labels[row] {
                key = "[\(labelName) = \(MSyntax.text(l))]"
                step = l
            } else {
                key = "\(row)"
                step = "\(dataName)\(row)"
            }
            items.append(NavigatorItem(name: name, kind: kind, selector: "{\(key)}[\(dataName)]", stepName: step == "Source" ? "Navigation" : step))
        }
        return items
    }

    // MARK: Shaping

    /// Steps that turn a non-table source value (JSON list, record, scalar) into a table; none for tables.
    static func tableConversion(of value: MValue, previous: String) -> [MStep] {
        let p = MSyntax.identifier(previous)
        switch value {
        case .table: return []
        case .list(let items):
            let records = items.map { $0.forcedCell().recordValue }
            if !items.isEmpty, records.allSatisfy({ $0 != nil }) {
                var names: [String] = [], seen = Set<String>()
                for r in records { for n in r?.names ?? [] where seen.insert(n).inserted { names.append(n) } }
                let list = "{" + names.map { MSyntax.text($0) }.joined(separator: ", ") + "}"
                return [MStep(name: "Converted to Table", expression: "Table.FromRecords(\(p), \(list), MissingField.UseNull)")]
            }
            return [MStep(name: "Converted to Table", expression: "Table.FromColumns({\(p)}, {\"Value\"})")]
        case .record:
            return [MStep(name: "Converted to Table", expression: "Record.ToTable(\(p))")]
        default:
            return [MStep(name: "Converted to Table", expression: "#table({\"Value\"}, {{\(p)}})")]
        }
    }

    /// True when the first row of a headerless table (columns still named Column1, Column2…) reads as headers:
    /// every cell is distinct, non-empty text that is not a number, and there is data below it.
    static func looksLikeHeaderRow(_ table: DataTable) -> Bool {
        guard table.rowCount >= 2, table.columnCount > 0 else { return false }
        guard table.columnNames.enumerated().allSatisfy({ $1 == "Column\($0 + 1)" }) else { return false }
        var seen = Set<String>()
        for column in table.columns {
            guard case .string(let s)? = column.values.first else { return false }
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || Double(t) != nil || !seen.insert(t).inserted { return false }
        }
        return true
    }

    // MARK: Text files

    /// The delimiter of delimited text: the candidate that splits the first lines into the same number of
    /// fields (most fields wins); comma when nothing fits.
    static func detectDelimiter(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).prefix(10).map(String.init)
        guard !lines.isEmpty else { return "," }
        var best: (delimiter: String, count: Int)?
        for candidate in [",", ";", "\t", "|"] {
            let counts = lines.map { fieldSeparators(in: $0, delimiter: Character(candidate)) }
            guard let first = counts.first, first > 0, counts.allSatisfy({ $0 == first }) else { continue }
            if first > (best?.count ?? 0) { best = (candidate, first) }
        }
        return best?.delimiter ?? ","
    }

    /// Occurrences of a delimiter outside double quotes.
    private static func fieldSeparators(in line: String, delimiter: Character) -> Int {
        var quoted = false, n = 0
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == delimiter, !quoted { n += 1 }
        }
        return n
    }

    // MARK: Web

    static func sniffWeb(_ data: Data, address: String) -> WebContentKind {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .excel }
        var head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.hasPrefix("\u{FEFF}") { head.removeFirst() }
        let trimmed = head.drop(while: { $0.isWhitespace })
        if let first = trimmed.first {
            if first == "{" || first == "[" { return .json }
            if first == "<" {
                let lower = trimmed.lowercased()
                return lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<table") ? .html : .xml
            }
        }
        switch (URLComponents(string: address)?.path as NSString?)?.pathExtension.lowercased() {
        case "json": return .json
        case "xml": return .xml
        case "htm", "html": return .html
        case "xlsx", "xlsm": return .excel
        default: return .csv
        }
    }

    /// The connection details of a `Source` step written as `sourceExpression` writes it (and as Power BI writes
    /// the same calls): the inverse used by the Source step's settings gear. Nil for any other expression.
    static func request(fromSource expression: String) -> SourceRequest? {
        guard let ast = try? MParser.parse(expression), case .invoke(.identifier(let fn, _), let args) = ast else { return nil }
        func text(_ e: MExpr?) -> String? { if case .literal(.text(let t))? = e { return t }; return nil }
        /// `File.Contents("…")` or `Web.Contents("…")`.
        func contents(_ e: MExpr?) -> (web: Bool, location: String)? {
            guard case .invoke(.identifier(let inner, _), let a)? = e, let location = text(a.first) else { return nil }
            switch inner {
            case "File.Contents": return (false, location)
            case "Web.Contents": return (true, location)
            default: return nil
            }
        }
        func make(_ kind: SourceKind, _ location: String) -> SourceRequest { SourceRequest(kind: kind, location: location) }
        switch fn {
        case "Folder.Files", "Folder.Contents": return text(args.first).map { make(.folder, $0) }
        case "Sqlite.Database": return text(args.first).map { make(.sqlite, $0) }
        case "OData.Feed": return text(args.first).map { make(.odata, $0) }
        case "Python.Execute": return text(args.first).map { make(.python, $0) }
        case "R.Execute": return text(args.first).map { make(.r, $0) }
        case "Csv.Document":
            guard let c = contents(args.first) else { return nil }
            var r = make(c.web ? .web : .csv, c.location)
            r.webContent = .csv
            if case .record(let fields)? = args[safe: 1] {
                for (name, value) in fields {
                    if name == "Delimiter", let d = text(value) { r.delimiter = d }
                    if name == "Encoding", case .literal(.number(let n)) = value { r.encoding = Int(n) }
                }
            } else if let d = text(args[safe: 1]) {
                r.delimiter = d
            }
            return r
        case "Excel.Workbook", "Json.Document", "Xml.Tables", "Xml.Document", "Web.Page":
            guard let c = contents(args.first) else { return nil }
            let file: SourceKind = fn == "Excel.Workbook" ? .excel : fn == "Json.Document" ? .json : .xml
            if fn == "Web.Page" && !c.web { return nil }
            var r = make(c.web ? .web : file, c.location)
            r.webContent = fn == "Excel.Workbook" ? .excel : fn == "Json.Document" ? .json : fn == "Web.Page" ? .html : .xml
            return r
        default:
            return nil
        }
    }

    // MARK: Names

    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Query" : trimmed
        if !taken.contains(root) { return root }
        var k = 2
        while taken.contains("\(root) (\(k))") { k += 1 }
        return "\(root) (\(k))"
    }

    /// The query name Power Query would pick: the object's name, or the file / host name for single-table sources.
    static func queryName(_ r: SourceRequest, item: NavigatorItem?) -> String {
        if let item { return item.name }
        let location = r.location.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.kind {
        case .csv, .json, .xml, .excel, .sqlite:
            return ((location as NSString).lastPathComponent as NSString).deletingPathExtension
        case .folder: return (location as NSString).lastPathComponent
        case .web, .odata:
            let parts = URLComponents(string: location)
            let last = ((parts?.path ?? "") as NSString).lastPathComponent
            let stem = (last as NSString).deletingPathExtension
            return stem.isEmpty || stem == "/" ? (parts?.host ?? "Web") : stem
        case .python: return "Python"
        case .r: return "R"
        case .blank: return "Query1"
        }
    }

    /// The data source a request reads, as the engine records it (`kind` + `location`).
    static func dataSource(_ r: SourceRequest) -> QueryDataSource? {
        let location = r.location.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.kind {
        case .csv, .excel, .json, .xml: return QueryDataSource(kind: "File", location: location)
        case .folder: return QueryDataSource(kind: "Folder", location: location)
        case .sqlite: return QueryDataSource(kind: "SQLite", location: location)
        case .web, .odata:
            guard let parts = URLComponents(string: location), let scheme = parts.scheme?.lowercased(), let host = parts.host else { return nil }
            return QueryDataSource(kind: r.kind == .web ? "Web" : "OData", location: "\(scheme)://\(host)")
        case .python, .r, .blank: return nil
        }
    }

    /// Why a request cannot be started yet (nil when it can).
    static func validationMessage(_ r: SourceRequest) -> String? {
        let location = r.location.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.kind {
        case .blank: return nil
        case .python, .r: return location.isEmpty ? "Type the script to run." : nil
        case .web, .odata:
            guard !location.isEmpty else { return "Type the address." }
            guard let parts = URLComponents(string: location), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  !(parts.host ?? "").isEmpty else { return "The address must start with http:// or https://." }
            return nil
        case .csv, .excel, .json, .xml, .folder, .sqlite:
            guard !location.isEmpty else { return r.kind == .folder ? "Choose a folder." : "Choose a file." }
            if r.kind == .excel, ["xls", "xlsb"].contains((location as NSString).pathExtension.lowercased()) {
                return DataConnector.Missing.legacyExcel
            }
            return nil
        }
    }

    // MARK: Folder

    /// How to combine the files of a folder listing: the format of the most common supported extension, and
    /// that extension (the combine step keeps only those files). Nil when no file can be combined.
    static func combinePlan(extensions: [String], sampleText: (String) -> String?) -> (extension: String, format: CombineFilesFormat)? {
        var counts: [String: Int] = [:], order: [String] = []
        for e in extensions.map({ $0.lowercased() }) where [".csv", ".txt", ".tsv", ".json", ".xlsx", ".xlsm"].contains(e) {
            if counts[e] == nil { order.append(e) }
            counts[e, default: 0] += 1
        }
        guard let winner = order.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) else { return nil }
        switch winner {
        case ".json": return (winner, .json)
        case ".xlsx", ".xlsm": return (winner, .excel(sheet: nil))
        default:
            let delimiter = winner == ".tsv" ? "\t" : sampleText(winner).map(detectDelimiter) ?? ","
            return (winner, .csv(delimiter: delimiter, promoteHeaders: true))
        }
    }

    static func combineSteps(extension ext: String, format: CombineFilesFormat) -> [MStep] {
        let filter = MStep(name: "Filtered Files", expression: "Table.SelectRows(Source, each Text.Lower([Extension]) = \(MSyntax.text(ext)))")
        let combine = Transform.combineFiles(format)
        return [filter, MStep(name: "Combined Files", expression: combine.expression(previous: MSyntax.identifier(filter.name)))]
    }

    // MARK: Data source settings

    /// A query's M with one source location replaced by another ("Change Source"): only whole text literals
    /// equal to the old location change.
    static func replacingLocation(_ old: String, with new: String, in script: String) -> String {
        guard !old.isEmpty, old != new else { return script }
        return script.replacingOccurrences(of: MSyntax.text(old), with: MSyntax.text(new))
    }
}

/// A table typed or pasted into Enter Data.
struct EnteredTable: Equatable {
    var header: [String]
    var rows: [[String]]

    /// Parses pasted text: the first line is the header; cells are separated by tabs, or by the detected
    /// delimiter when there are no tabs. Short rows are padded; blank lines are skipped.
    static func parse(_ text: String) -> EnteredTable? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return nil }
        let delimiter: Character = text.contains("\t") ? "\t" : Character(SourcePlanner.detectDelimiter(text))
        func cells(_ line: String) -> [String] {
            var out: [String] = [], current = "", quoted = false
            for ch in line {
                if ch == "\"" { quoted.toggle() }
                else if ch == delimiter, !quoted { out.append(current); current = "" }
                else { current.append(ch) }
            }
            out.append(current)
            return out.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var header = cells(first)
        for i in header.indices where header[i].isEmpty { header[i] = "Column\(i + 1)" }
        var seen = Set<String>()
        for i in header.indices {
            var name = header[i], k = 2
            while !seen.insert(name).inserted { name = "\(header[i]) \(k)"; k += 1 }
            header[i] = name
        }
        let rows = lines.dropFirst().map { line -> [String] in
            let c = cells(line)
            return header.indices.map { $0 < c.count ? c[$0] : "" }
        }
        return EnteredTable(header: header, rows: rows)
    }

    /// The table as text columns (empty cells are null).
    var textTable: DataTable {
        DataTable(columnNames: header, rows: rows.map { $0.map { $0.isEmpty ? .null : .string($0) } }, types: header.map { _ in .text })
    }

    /// The query: every row as text in `#table`, then a Changed Type step for the detected column types.
    var script: String {
        func list(_ items: [String]) -> String { "{" + items.joined(separator: ", ") + "}" }
        let body = rows.map { list($0.map { $0.isEmpty ? "null" : MSyntax.text($0) }) }
        let source = "#table(\(list(header.map { MSyntax.text($0) })), \(list(body)))"
        let base = MScript.script(from: [MStep(name: "Source", expression: source)])
        guard let types = Transform.detectTypes(in: textTable) else { return base }
        return MScript.appending(types, to: base)
    }
}
