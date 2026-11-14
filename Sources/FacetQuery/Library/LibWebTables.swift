import Foundation
import FacetCore

/// The tables of an HTML page, read with the system's tidy HTML parser (`Web.Page`).
enum HtmlTables {
    struct Found {
        var caption: String?
        var className: String?
        var id: String?
        var table: MTable
    }

    static func tables(in data: Data) throws -> [Found] {
        guard let document = try? XMLDocument(data: data, options: [.documentTidyHTML]), let root = document.rootElement() else {
            throw MError.dataFormat("The page couldn't be read as HTML.")
        }
        var elements: [XMLElement] = []
        collect("table", under: root, into: &elements, stopAtNested: false)
        return elements.compactMap(read)
    }

    private static func name(_ e: XMLElement) -> String { (e.localName ?? e.name ?? "").lowercased() }
    private static func childElements(_ e: XMLElement) -> [XMLElement] { (e.children ?? []).compactMap { $0 as? XMLElement } }

    private static func collect(_ tag: String, under e: XMLElement, into out: inout [XMLElement], stopAtNested: Bool) {
        for child in childElements(e) {
            let n = name(child)
            if n == tag { out.append(child); if stopAtNested { continue } }
            if stopAtNested, n == "table" { continue }
            collect(tag, under: child, into: &out, stopAtNested: stopAtNested)
        }
    }

    /// Visible text of a node: scripts and styles dropped, line breaks and runs of white space become one space.
    static func text(_ node: XMLNode) -> String {
        var out = ""
        func walk(_ n: XMLNode) {
            if let e = n as? XMLElement {
                let tag = name(e)
                if tag == "script" || tag == "style" { return }
                if tag == "br" { out += " " }
                for c in e.children ?? [] { walk(c) }
            } else if n.kind == .text {
                out += n.stringValue ?? ""
            }
        }
        walk(node)
        return out.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    private static func span(_ e: XMLElement, _ attribute: String) -> Int {
        let n = Int(e.attribute(forName: attribute)?.stringValue?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1
        return min(max(n, 1), 1000)
    }

    private static func read(_ table: XMLElement) -> Found? {
        var rowElements: [XMLElement] = []
        collect("tr", under: table, into: &rowElements, stopAtNested: true)
        var grid: [[String]] = [], headerRows = 0
        var carried: [Int: (remaining: Int, text: String)] = [:]
        for tr in rowElements {
            let cells = childElements(tr).filter { ["td", "th"].contains(name($0)) }
            var row: [String] = [], column = 0
            func takeCarried() {
                while let c = carried[column] {
                    row.append(c.text)
                    carried[column] = c.remaining > 1 ? (c.remaining - 1, c.text) : nil
                    column += 1
                }
            }
            for cell in cells {
                takeCarried()
                let value = text(cell), rows = span(cell, "rowspan")
                for _ in 0..<span(cell, "colspan") {
                    row.append(value)
                    if rows > 1 { carried[column] = (rows - 1, value) }
                    column += 1
                }
            }
            takeCarried()
            if row.isEmpty { continue }
            let inHead = (tr.parent as? XMLElement).map(name) == "thead"
            let allHeaderCells = !cells.isEmpty && cells.allSatisfy { name($0) == "th" }
            if grid.isEmpty, inHead || allHeaderCells { headerRows = 1 }
            grid.append(row)
        }
        guard !grid.isEmpty else { return nil }
        let width = grid.map(\.count).max() ?? 0
        var names = (1...max(width, 1)).map { "Column\($0)" }
        var body = grid
        if headerRows == 1, let header = grid.first {
            for (i, h) in header.enumerated() where !h.isEmpty { names[i] = h }
            names = MLib.uniqued(names)
            body.removeFirst()
        }
        let rows: [[MValue]] = body.map { r in (0..<width).map { $0 < r.count ? .text(r[$0]) : .null } }
        let caption = childElements(table).first { name($0) == "caption" }.map { text($0) }
        return Found(caption: caption.flatMap { $0.isEmpty ? nil : $0 },
                     className: table.attribute(forName: "class")?.stringValue, id: table.attribute(forName: "id")?.stringValue,
                     table: MTable(names: Array(names.prefix(width)), types: Array(repeating: .text, count: width), rows: rows))
    }
}

/// OData feeds read as JSON: OData v4, and v2/v3 services that answer `Accept: application/json`.
enum ODataFeed {
    static let maxPages = 10_000

    /// The value of a feed address: a navigation table (Name, Data, Signature) for a service document, otherwise the
    /// table of entities with every page followed. `fetch` returns the parsed JSON of an address.
    static func value(at address: String, fetch: @escaping (String) throws -> MValue) throws -> MValue {
        guard case .record(let doc) = try fetch(address) else {
            throw MError.dataFormat("The OData service at '\(address)' didn't return a JSON object.")
        }
        var rows: [MValue] = [], next: String?
        if let d = try doc.get("d") {                                   // OData v2 / v3 verbose JSON
            if case .record(let r) = d, case .list(let sets)? = try r.get("EntitySets") {
                return navigation(sets.compactMap { $0.forcedCell().textValue }.map { ($0, $0) }, base: address, fetch: fetch)
            }
            if case .record(let r) = d, case .list(let results)? = try r.get("results") { rows = results; next = try r.text("__next") }
            else if case .list(let results) = d { rows = results }
            else { rows = [d] }
        } else if case .list(let value)? = try doc.get("value") {       // OData v4
            let records = value.compactMap { $0.forcedCell().recordValue }
            let isServiceDocument = !value.isEmpty && records.count == value.count && records.allSatisfy { r in
                r.has("url") && r.has("name") && r.names.allSatisfy { ["name", "kind", "url", "title"].contains($0) }
            }
            if isServiceDocument {
                let sets = try records.compactMap { r -> (String, String)? in
                    let kind = try r.text("kind") ?? "EntitySet"
                    guard kind == "EntitySet" || kind == "Singleton", let n = try r.text("name"), let u = try r.text("url") else { return nil }
                    return (n, u)
                }
                return navigation(sets, base: address, fetch: fetch)
            }
            rows = value
            next = try doc.text("@odata.nextLink") ?? doc.text("odata.nextLink")
        } else {
            rows = [.record(doc)]
        }
        var current = address, pages = 1
        while let link = next {
            guard pages < maxPages else { throw MError.dataSource("The OData feed at '\(address)' has more than \(maxPages) pages.") }
            current = resolve(link, against: current)
            guard case .record(let page) = try fetch(current) else { break }
            next = nil
            if case .record(let r)? = try page.get("d") {
                if case .list(let more)? = try r.get("results") { rows += more }
                next = try r.text("__next")
            } else if case .list(let more)? = try page.get("value") {
                rows += more
                next = try page.text("@odata.nextLink") ?? page.text("odata.nextLink")
            }
            pages += 1
        }
        return .table(table(of: rows))
    }

    /// Annotations (`@odata.etag`, `Name@odata.navigationLink`, `odata.type`, `__metadata`) are not data.
    static func isAnnotation(_ field: String) -> Bool {
        field.contains("@odata.") || field.hasPrefix("odata.") || field == "__metadata"
    }

    static func table(of rows: [MValue]) -> MTable {
        var names: [String] = [], seen = Set<String>()
        let records = rows.map { $0.forcedCell().recordValue }
        for r in records { for n in r?.names ?? [] where !isAnnotation(n) && seen.insert(n).inserted { names.append(n) } }
        if names.isEmpty, records.contains(where: { $0 == nil }) {
            return MTable(names: ["Value"], columns: [rows.map { $0.forcedCell() }])
        }
        let body: [[MValue]] = records.map { r in
            names.map { n in
                guard let r, let i = r.fields.index[n] else { return .null }
                return r.cell(at: i)
            }
        }
        return MTable(names: names, rows: body)
    }

    static func resolve(_ link: String, against address: String) -> String {
        if link.lowercased().hasPrefix("http://") || link.lowercased().hasPrefix("https://") { return link }
        return URL(string: link, relativeTo: URL(string: address))?.absoluteString ?? link
    }

    /// The address of an entity set named in a service document (relative to the service root).
    static func entitySetAddress(_ url: String, root: String) -> String {
        if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") { return url }
        var parts = URLComponents(string: root) ?? URLComponents()
        let query = parts.percentEncodedQuery
        parts.percentEncodedQuery = nil
        let base = parts.string ?? root
        let joined = (base.hasSuffix("/") ? base : base + "/") + url
        return query.map { "\(joined)?\($0)" } ?? joined
    }

    private static func navigation(_ sets: [(name: String, url: String)], base: String, fetch: @escaping (String) throws -> MValue) -> MValue {
        let rows: [[MValue]] = sets.map { set in
            [.text(set.name), .lazy(MThunk { try value(at: entitySetAddress(set.url, root: base), fetch: fetch) }), .text("table")]
        }
        return .table(MTable(names: ["Name", "Data", "Signature"], types: [.text, .anyTable, .text], rows: rows))
    }
}

extension MLibrary {
    static func registerWebTables(_ lib: MLibrary) {
        lib.fn("Web.Page", 1) { a, ctx in
            let data: Data
            switch a[0] {
            case .text(let s): data = Data(s.utf8)
            default: data = try a.binary(0)
            }
            try ctx.checkSize(data.count, of: "The HTML page")
            let found = try HtmlTables.tables(in: data)
            let rows: [[MValue]] = found.map { [.optText($0.caption), .text("Table"), .optText($0.className), .optText($0.id), .table($0.table)] }
            return .table(MTable(names: ["Caption", "Source", "ClassName", "Id", "Data"], types: [.text, .text, .text, .text, .anyTable], rows: rows))
        }
        lib.fn("OData.Feed", 1...3) { [weak lib] a, ctx in
            let address = try a.text(0)
            guard let parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = parts.host, !host.isEmpty else {
                throw MError.dataSource("OData.Feed needs an http or https address; '\(address)' isn't one.")
            }
            try ctx.noteDataSource(kind: "OData", location: "\(scheme)://\(host)")
            guard case .function(let contents)? = (lib ?? .shared).values["Web.Contents"] else {
                throw MError.dataSource("OData.Feed needs Web.Contents, which this library doesn't define.")
            }
            var names = ["Accept", "OData-MaxVersion"], values: [MValue] = [.text("application/json"), .text("4.0")]
            if let extra = try a.optRecord(1) {
                for (n, v) in zip(extra.names, try extra.forcedValues()) {
                    if let i = names.firstIndex(of: n) { values[i] = v } else { names.append(n); values.append(v) }
                }
            }
            let options = MValue.record(MRecord([("Headers", .record(MRecord(names: names, values: values)))]))
            return try ODataFeed.value(at: address) { url in
                guard case .binary(let data) = try ctx.call(contents, [.text(url), options]) else {
                    throw MError.dataSource("The OData service at '\(url)' returned no content.")
                }
                do { return try JsonParser.parse(data) } catch {
                    throw MError.dataSource("The OData service at '\(url)' didn't answer with JSON. \(AppIdentity.name) reads OData feeds as JSON "
                        + "(OData v4, or older services that honour 'Accept: application/json').")
                }
            }
        }
    }
}
