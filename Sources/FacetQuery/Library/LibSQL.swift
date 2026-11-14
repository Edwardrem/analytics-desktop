import Foundation
import FacetCore

extension MLibrary {
    /// Metadata field that marks a navigation table as a SQLite database (holds the resolved file path).
    static let sqlitePathField = "Facet.SqliteDatabase"

    static func registerSQL(_ lib: MLibrary) {
        lib.fn("Sqlite.Database", 1...2) { a, ctx in
            let url: URL
            switch a[0] {
            case .text(let p): url = ctx.resolvePath(p)
            default: throw MError("Sqlite.Database needs the path of a database file. (File.Contents binaries can't be opened as a database.)", detail: nil)
            }
            try ctx.noteDataSource(kind: "SQLite", location: url.path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MError.dataSource("Could not find the SQLite database '\(url.path)'.") }
            let objects = try SQLiteRunner.run(path: url.path, sql: "select name, type from sqlite_master where type in ('table', 'view') and name not like 'sqlite_%' order by name")
            var rows: [[MValue]] = []
            for i in 0..<(objects.columns.first?.count ?? 0) {
                guard case .text(let name) = objects.columns[0][i], case .text(let kind) = objects.columns[1][i] else { continue }
                let data = MValue.lazy(MThunk {
                    let info = try SQLiteRunner.run(path: url.path, sql: "select * from \(SQLiteRunner.quote(name))", describeOnly: true)
                    let query = SQLiteSource.Query(from: SQLiteRunner.quote(name), columns: info.names, types: info.declaredTypes.map(SQLiteRunner.type))
                    return .table(MTable(source: SQLiteSource(path: url.path, query: query, interpreter: ctx)))
                })
                rows.append([.text(name), .text("main"), .text(name), .text(kind == "view" ? "View" : "Table"), data])
            }
            let nav = MTable(names: ["Name", "Schema", "Item", "Kind", "Data"], types: [.text, .text, .text, .text, .anyTable], rows: rows)
            nav.meta = MRecord(names: [sqlitePathField], values: [.text(url.path)])
            return .table(nav)
        }
        lib.fn("Value.NativeQuery", 2...4) { a, ctx in
            if let server = try serverNativeQuery(a, ctx) { return server }
            guard case .table(let target) = a[0], let path = try target.meta?.text(sqlitePathField) else {
                throw MError("Value.NativeQuery needs a database from a connector that supports native queries (Sqlite.Database, PostgreSQL.Database, MySQL.Database, …).")
            }
            let sql = try a.text(1)
            var parameters: [(name: String?, value: MValue)] = []
            switch a[2] {
            case .null: break
            case .record(let r): parameters = try zip(r.names, r.forcedValues()).map { ($0, $1) }
            case .list(let l): parameters = try l.map { (nil, try $0.forced()) }
            default: throw MError.typeMismatch(expected: "record", got: a[2])
            }
            try ctx.approveNativeQuery(sql, kind: "SQLite", location: path)
            if try a.optRecord(3)?.logical("EnableFolding") ?? false {
                let info = try SQLiteRunner.run(path: path, sql: sql, parameters: parameters, describeOnly: true)
                let trimmed = sql.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
                let query = SQLiteSource.Query(from: "(\(trimmed)) as \"_\"", columns: info.names, types: info.declaredTypes.map(SQLiteRunner.type), parameters: parameters)
                return .table(MTable(source: SQLiteSource(path: path, query: query, interpreter: ctx)))
            }
            let result = try SQLiteRunner.run(path: path, sql: sql, parameters: parameters)
            return .table(try MTable.make(result.names, result.declaredTypes.map(SQLiteRunner.type), result.columns, rows: result.columns.first?.count ?? 0))
        }
        // Connectors that need a client driver this build does not ship: fail with an actionable message.
        let unavailable: [(String, String)] = [
            ("Oracle.Database", "Oracle"), ("Odbc.DataSource", "ODBC"), ("Odbc.Query", "ODBC"), ("OleDb.DataSource", "OLE DB"),
            ("AnalysisServices.Database", "Analysis Services"), ("Snowflake.Databases", "Snowflake"), ("GoogleBigQuery.Database", "Google BigQuery"),
        ]
        for (name, product) in unavailable {
            lib.fn(name, 0...4) { _, _ in
                throw MError.dataSource("The \(product) connector (\(name)) isn't available in this version of \(AppIdentity.name). "
                    + "Export the data to CSV, Excel or a SQLite database and connect to that instead.")
            }
        }
    }
}
