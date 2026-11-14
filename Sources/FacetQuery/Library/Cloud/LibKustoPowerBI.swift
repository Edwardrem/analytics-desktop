import Foundation
import FacetCore

/// Azure Data Explorer (`AzureDataExplorer.Contents`) through the Kusto REST API (v1 query and management endpoints).
enum KustoSource {
    static let service = "Azure Data Explorer"

    /// `help` → `help.kusto.windows.net`; `https://help.westeurope.kusto.windows.net` stays as it is.
    static func clusterHost(_ cluster: String) throws -> String {
        let t = cluster.trimmingCharacters(in: .whitespacesAndNewlines)
        var (host, _) = try CloudSource.parse(t.contains("://") || t.contains(".") ? t : t + ".kusto.windows.net", function: "AzureDataExplorer.Contents")
        // `help.westeurope` is short for help.westeurope.kusto.windows.net; a full address is taken as typed.
        if !t.contains("://"), !host.hasSuffix(".kusto.windows.net") { host += ".kusto.windows.net" }
        guard CloudSource.hasSuffix(host, ".kusto.windows.net") else {
            throw MError.dataSource("AzureDataExplorer.Contents needs a cluster such as https://help.kusto.windows.net; '\(host)' isn't one.")
        }
        return host
    }

    static func run(_ ctx: MInterpreter, host: String, database: String, csl: String, management: Bool) throws -> MTable {
        guard let url = CloudSource.url(host: host, path: ["v1", "rest", management ? "mgmt" : "query"]) else {
            throw MError.dataSource("Couldn't build the Azure Data Explorer address for '\(host)'.")
        }
        let body = try JsonParser.write(.record(MRecord([("db", .text(database)), ("csl", .text(csl))])))
        let result = try CloudSource.json(ctx, service: service, url: url, method: "POST", body: Data(body.utf8),
                                          headers: ["Content-Type": "application/json; charset=utf-8"],
                                          auth: .entra(resource: EntraResource.kusto("https://" + host)))
        guard let first = try CloudSource.records(result, "Tables").first else { return MTable(names: [], columns: []) }
        let columns = try CloudSource.records(.record(first), "Columns")
        let names = MLib.uniqued(columns.enumerated().map { CloudSource.text($1, "ColumnName") ?? "Column\($0 + 1)" })
        let kinds = columns.map { (CloudSource.text($0, "ColumnType") ?? CloudSource.text($0, "DataType") ?? "string").lowercased() }
        guard case .list(let rows)? = try first.get("Rows") else { return MTable(names: names, types: kinds.map(type), rows: []) }
        let values = try rows.map { row -> [MValue] in
            guard case .list(let cells) = try row.forced() else { return [] }
            return try cells.enumerated().map { i, cell in convert(try cell.forced(), kinds[safe: i] ?? "string") }
        }
        return MTable(names: names, types: kinds.map(type), rows: values)
    }

    static func type(_ kind: String) -> MType {
        switch kind {
        case "int", "long", "int32", "int64", "sbyte", "int16": return .nullable(.int64)
        case "real", "double", "decimal", "single": return .nullable(.plainNumber)
        case "bool", "boolean": return .nullable(.logical)
        case "datetime", "date": return .nullable(.datetime)
        case "timespan", "time": return .nullable(.duration)
        default: return .nullable(.text)
        }
    }

    static func convert(_ v: MValue, _ kind: String) -> MValue {
        if v.isNull { return .null }
        switch kind {
        case "decimal": return v.textValue.flatMap(Double.init).map(MValue.number) ?? v
        case "bool", "boolean": if case .number(let n) = v { return .logical(n != 0) }; return v
        case "datetime", "date":
            return v.textValue.flatMap { CloudSource.isoDate($0.hasSuffix("Z") ? $0 : $0 + "Z") }.map(MValue.datetime) ?? v
        case "timespan", "time": return v.textValue.flatMap(timespan).map(MValue.duration) ?? v
        case "dynamic":
            if case .text = v { return v }
            return (try? JsonParser.write(v)).map(MValue.text) ?? .null
        default: return v
        }
    }

    /// `[-][d.]hh:mm:ss[.fffffff]` → seconds.
    static func timespan(_ s: String) -> Double? {
        var t = Substring(s)
        let negative = t.hasPrefix("-")
        if negative { t = t.dropFirst() }
        let parts = t.split(separator: ":")
        guard parts.count == 3, let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        let head = parts[0].split(separator: ".")
        guard let h = Double(head.last ?? ""), head.count <= 2 else { return nil }
        let days = head.count == 2 ? Double(head[0]) ?? 0 : 0
        let total = days * 86_400 + h * 3_600 + m * 60 + sec
        return negative ? -total : total
    }

    static func queryLocation(host: String, database: String) -> String { "https://\(host);\(database)" }

    static func bracket(_ name: String) -> String { "['" + name.replacingOccurrences(of: "'", with: "\\'") + "']" }

    static func contents(_ ctx: MInterpreter, cluster: String, database: String?, query: String?) throws -> MTable {
        let host = try clusterHost(cluster)
        try ctx.noteDataSource(kind: "AzureDataExplorer", location: "https://" + host)
        guard let database, !database.isEmpty else {
            let dbs = try run(ctx, host: host, database: "NetDefaultDB", csl: ".show databases", management: true)
            let names = try (dbs.columnIndex("DatabaseName").map { try dbs.columns[$0] } ?? []).compactMap { $0.forcedCell().textValue }
            return CloudSource.navigation(names.map { name in (name, "Database", [], { .table(try contents(ctx, cluster: cluster, database: name, query: nil)) }) })
        }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            try ctx.approveNativeQuery(q, kind: "AzureDataExplorer", location: queryLocation(host: host, database: database))
            return try run(ctx, host: host, database: database, csl: q, management: q.hasPrefix("."))
        }
        let tables = try run(ctx, host: host, database: database, csl: ".show tables", management: true)
        let names = try (tables.columnIndex("TableName").map { try tables.columns[$0] } ?? []).compactMap { $0.forcedCell().textValue }
        return CloudSource.navigation(names.sorted().map { name in
            (name, "Table", [], { .table(try run(ctx, host: host, database: database, csl: bracket(name), management: false)) })
        })
    }
}

/// Power BI semantic models imported with a DAX query through the Power BI REST `executeQueries` API
/// (`AnalysisServices.Database` with a `powerbi://` address). The rows are a snapshot taken at refresh; the
/// service returns at most 100,000 rows per query.
enum PowerBIModelSource {
    static let service = "Power BI"
    static let host = "api.powerbi.com"
    static var auth: CloudHTTP.Auth { .entra(resource: EntraResource.powerBI) }

    static func api(_ path: [String], _ query: [URLQueryItem] = []) throws -> URL {
        guard let u = CloudSource.url(host: host, path: ["v1.0", "myorg"] + path, query: query) else {
            throw MError.dataSource("Couldn't build the Power BI address.")
        }
        return u
    }

    /// The workspace named in `powerbi://api.powerbi.com/v1.0/myorg/<workspace>` (nil for My workspace).
    static func workspaceName(_ server: String) throws -> String? {
        let prefix = "powerbi://api.powerbi.com/v1.0/myorg"
        let t = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix(prefix) else {
            throw MError.dataSource("AnalysisServices.Database reads Power BI semantic models (powerbi://api.powerbi.com/v1.0/myorg/<workspace>). Other Analysis Services servers need XMLA, which \(AppIdentity.name) can't connect to.")
        }
        let rest = String(t.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = rest.removingPercentEncoding ?? rest
        return name.isEmpty || name.caseInsensitiveCompare("My workspace") == .orderedSame ? nil : name
    }

    static func datasetPath(_ ctx: MInterpreter, server: String, model: String) throws -> [String] {
        let workspace = try workspaceName(server)
        var base: [String] = []
        if let workspace {
            let escaped = workspace.replacingOccurrences(of: "'", with: "''")
            let groups = try CloudSource.pagedRecords(ctx, service: service, url: try api(["groups"], [URLQueryItem(name: "$filter", value: "name eq '\(escaped)'")]), auth: auth)
            guard let id = groups.first.flatMap({ CloudSource.text($0, "id") }) else {
                throw MError.dataSource("The Power BI workspace '\(workspace)' wasn't found, or the signed-in account can't open it.")
            }
            base = ["groups", id]
        }
        let datasets = try CloudSource.pagedRecords(ctx, service: service, url: try api(base + ["datasets"]), auth: auth)
        guard let id = datasets.first(where: { CloudSource.text($0, "name")?.caseInsensitiveCompare(model) == .orderedSame }).flatMap({ CloudSource.text($0, "id") }) else {
            throw MError.dataSource("The semantic model '\(model)' wasn't found in \(workspace.map { "the workspace '\($0)'" } ?? "My workspace").")
        }
        return base + ["datasets", id]
    }

    /// Runs one DAX query and returns its first table, with `Table[Column]` names kept as the service returns them.
    static func execute(_ ctx: MInterpreter, dataset: [String], dax: String) throws -> MTable {
        let body = try JsonParser.write(.record(MRecord([
            ("queries", .list([.record(MRecord([("query", .text(dax))]))])),
            ("serializerSettings", .record(MRecord([("includeNulls", .logical(true))]))),
        ])))
        let result = try CloudSource.json(ctx, service: service, url: try api(dataset + ["executeQueries"]), method: "POST", body: Data(body.utf8), auth: auth)
        let table = try CloudSource.records(result, "results").first.flatMap { try CloudSource.records(.record($0), "tables").first }
        guard let table else { throw MError.dataSource("Power BI returned no table for the DAX query.") }
        return CloudSource.table(from: try CloudSource.records(.record(table), "rows"), skip: { _ in false })
    }

    static func database(_ ctx: MInterpreter, server: String, model: String, query: String?) throws -> MTable {
        try ctx.noteDataSource(kind: "AnalysisServices", location: server.trimmingCharacters(in: .whitespacesAndNewlines))
        let dataset = try datasetPath(ctx, server: server, model: model)
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try ctx.approveNativeQuery(query, kind: "AnalysisServices", location: server)
            return try execute(ctx, dataset: dataset, dax: query)
        }
        let listing = try execute(ctx, dataset: dataset, dax: "EVALUATE DISTINCT(SELECTCOLUMNS(COLUMNSTATISTICS(), \"Table\", [Table Name]))")
        let names = try (listing.columnIndex("[Table]").map { try listing.columns[$0] } ?? []).compactMap { $0.forcedCell().textValue }
            .filter { !$0.hasPrefix("LocalDateTable_") && !$0.hasPrefix("DateTableTemplate_") }
            .sorted()
        return CloudSource.navigation(names.map { name in
            (name, "Table", [], { .table(try tableRows(ctx, dataset: dataset, table: name)) })
        })
    }

    /// `EVALUATE 'Table'`, with the `Table[` prefix taken off the column names.
    static func tableRows(_ ctx: MInterpreter, dataset: [String], table: String) throws -> MTable {
        let t = try execute(ctx, dataset: dataset, dax: "EVALUATE '\(table.replacingOccurrences(of: "'", with: "''"))'")
        let prefix = table + "["
        let names = t.columnNames.map { n in n.hasPrefix(prefix) && n.hasSuffix("]") ? String(n.dropFirst(prefix.count).dropLast()) : n }
        return MTable(names: MLib.uniqued(names), types: t.columnTypes, columns: try t.columns, rowCount: try t.rowCount)
    }
}

extension MLibrary {
    static func registerKustoPowerBI(_ lib: MLibrary) {
        lib.fn("AzureDataExplorer.Contents", 1...4) { a, ctx in
            .table(try KustoSource.contents(ctx, cluster: try a.text(0), database: try a.optText(1), query: try a.optText(2)))
        }
        lib.fn("AnalysisServices.Database", 2...3) { a, ctx in
            let options = try MLib.options(a, 2)
            return .table(try PowerBIModelSource.database(ctx, server: try a.text(0), model: try a.text(1), query: try options.text("Query")))
        }
    }
}
