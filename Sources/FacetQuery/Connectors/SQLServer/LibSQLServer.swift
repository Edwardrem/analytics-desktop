import Foundation
import FacetCore

extension MLibrary {
    /// Metadata field of a SQL Server navigation table: `[Server, Database, Options]`, for `Value.NativeQuery`.
    static let sqlServerField = "Facet.SqlServerDatabase"

    static func registerSQLServer(_ lib: MLibrary) {
        lib.fn("Sql.Database", 2...3) { a, ctx in
            let server = try a.text(0), database = try a.text(1), options = try a.optRecord(2)
            let db = try sqlServerDatabase(server, database, options, ctx)
            if let query = try options?.text("Query"), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try ctx.approveNativeQuery(query, kind: "SQL", location: db.location)
                return .table(try db.resultSet(query).table())
            }
            return .table(try sqlServerNavigation(db, options: options, ctx))
        }
        lib.fn("Sql.Databases", 1...2) { a, ctx in
            let server = try a.text(0), options = try a.optRecord(1)
            let db = try sqlServerDatabase(server, "", options, ctx)
            let names = try db.resultSet("select [name] from sys.databases where [state] = 0 order by [name]")
            var rows: [[MValue]] = []
            for cell in names.values.first ?? [] {
                guard case .text(let name) = cell else { continue }
                let data = MValue.lazy(MThunk {
                    .table(try sqlServerNavigation(try sqlServerDatabase(server, name, options, ctx), options: options, ctx))
                })
                rows.append([.text(name), data, .text("Database")])
            }
            return .table(MTable(names: ["Name", "Data", "Kind"], types: [.text, .anyTable, .text], rows: rows))
        }
        // SQL Server targets here; every other target goes to the previously registered implementation (SQLite).
        let previous = lib.values["Value.NativeQuery"]?.functionValue
        lib.fn("Value.NativeQuery", 2...4) { a, ctx in
            guard case .table(let target) = a[0], case .record(let info)? = try target.meta?.get(sqlServerField) else {
                guard let previous else { throw MError("Value.NativeQuery needs a database from a connector that supports native queries.") }
                return try ctx.call(previous, a.values)
            }
            let db = try sqlServerDatabase(try info.text("Server") ?? "", try info.text("Database") ?? "",
                                           try info.get("Options")?.recordValue, ctx)
            let sql = try a.text(1)
            let parameters = try sqlServerParameters(a[2])
            try ctx.approveNativeQuery(sql, kind: "SQL", location: db.location)
            if try a.optRecord(3)?.logical("EnableFolding") ?? false {
                let trimmed = sql.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
                let from = "(\(trimmed)) as [_]"
                let shape = try db.describe(from, parameters: parameters)
                let query = TSQLQuery(from: from, columns: shape.names, types: shape.types, parameters: parameters)
                return .table(MTable(source: SQLServerSource(database: db, query: query, interpreter: ctx)))
            }
            return .table(try db.resultSet(sql, parameters: parameters).table())
        }
    }

    /// The database a `Sql.Database` call names, with its sign-in. Windows authentication does not exist on macOS, so
    /// a source needs a stored database user and password, or a Microsoft account for Azure SQL, Synapse and Fabric.
    static func sqlServerDatabase(_ server: String, _ database: String, _ options: MRecord?, _ ctx: MInterpreter) throws -> SQLServerDatabase {
        let address: TDSServerAddress
        do { address = try TDSServerAddress(server) } catch let e as TDSError { throw MError.dataSource("Microsoft SQL: " + e.message) }
        let location = database.isEmpty ? server : server + ";" + database
        try ctx.noteDataSource(kind: "SQL", location: location)
        let identity: String
        let authenticate: () throws -> TDSAuthentication
        let host = address.host
        switch ctx.credential(kind: "SQL", location: location) {
        case .basic(let user, let password)?:
            identity = "sql:" + user.lowercased()
            authenticate = { .sql(user: user, password: password) }
        case .bearer(let token)?:
            identity = "token"
            authenticate = { .accessToken(token) }
        case .oauth?:
            identity = "entra"
            authenticate = { .accessToken(try ctx.accessToken(resource: EntraResource.azureSQL, host: host)) }
        case nil where address.isMicrosoftCloud:
            identity = "entra"
            authenticate = { .accessToken(try ctx.accessToken(resource: EntraResource.azureSQL, host: host)) }
        default:
            throw MError.dataSource("Microsoft SQL: '\(location)' needs a sign-in. In Data source settings, enter a database user name and password"
                + (address.isMicrosoftCloud ? ", or sign in with a Microsoft account" : "") + ". Windows authentication isn't available on macOS.")
        }
        let db = SQLServerDatabase(server: server, database: database, address: address, identity: identity, authenticate: authenticate)
        db.trustServerCertificate = ctx.environment.trustServerCertificateHosts.contains(host.lowercased())
        db.maxResultBytes = ctx.environment.maxSourceBytes
        db.connectTimeout = 30
        if let options {
            if let t = try seconds(options, "CommandTimeout") { db.commandTimeout = t }
            if let t = try seconds(options, "ConnectionTimeout") { db.connectTimeout = t }
            if let encrypt = try options.text("Encrypt") {
                switch encrypt.lowercased() {
                case "strict": db.strictEncryption = true
                case "mandatory", "true", "yes": break
                default: throw MError("Sql.Database: Encrypt must be \"Mandatory\" or \"Strict\"; \(AppIdentity.name) always encrypts the connection.")
                }
            }
        }
        return db
    }

    private static func seconds(_ options: MRecord, _ name: String) throws -> TimeInterval? {
        guard let v = try options.get(name), !v.isNull else { return nil }
        guard case .duration(let s) = v, s > 0, s <= 86_400 else {
            throw MError("Sql.Database: \(name) must be a duration between 0 and 1 day, such as #duration(0, 0, 10, 0).")
        }
        return s
    }

    /// The navigation table of a database: `Name, Data, Schema, Item, Kind`, or with `HierarchicalNavigation` one row per schema.
    static func sqlServerNavigation(_ db: SQLServerDatabase, options: MRecord?, _ ctx: MInterpreter) throws -> MTable {
        let objects = try db.resultSet("select [TABLE_SCHEMA], [TABLE_NAME], [TABLE_TYPE] from [INFORMATION_SCHEMA].[TABLES] order by [TABLE_SCHEMA], [TABLE_NAME]")
        var entries: [(schema: String, name: String, kind: String)] = []
        for i in 0..<objects.rowCount where objects.values.count >= 3 {
            guard case .text(let schema) = objects.values[0][i], case .text(let name) = objects.values[1][i] else { continue }
            let kind = objects.values[2][i].textValue == "VIEW" ? "View" : "Table"
            entries.append((schema, name, kind))
        }
        func data(_ schema: String, _ name: String) -> MValue {
            .lazy(MThunk {
                let from = TSQL.quote(schema) + "." + TSQL.quote(name)
                let shape = try db.describe(from)
                return .table(MTable(source: SQLServerSource(database: db, query: TSQLQuery(from: from, columns: shape.names, types: shape.types), interpreter: ctx)))
            })
        }
        let names = ["Name", "Data", "Schema", "Item", "Kind"], types: [MType] = [.text, .anyTable, .text, .text, .text]
        let nav: MTable
        if try options?.logical("HierarchicalNavigation") ?? false {
            var schemas: [String] = []
            for e in entries where !schemas.contains(e.schema) { schemas.append(e.schema) }
            nav = MTable(names: names, types: types, rows: schemas.map { schema in
                let inner = MTable(names: names, types: types, rows: entries.filter { $0.schema == schema }.map {
                    [.text($0.name), data($0.schema, $0.name), .text($0.schema), .text($0.name), .text($0.kind)]
                })
                return [.text(schema), .table(inner), .text(schema), .null, .text("Schema")]
            })
        } else {
            nav = MTable(names: names, types: types, rows: entries.map {
                [.text($0.name), data($0.schema, $0.name), .text($0.schema), .text($0.name), .text($0.kind)]
            })
        }
        nav.meta = MRecord(names: [sqlServerField], values: [.record(MRecord(names: ["Server", "Database", "Options"],
                                                                              values: [.text(db.server), .text(db.database), options.map(MValue.record) ?? .null]))])
        return nav
    }

    /// `Value.NativeQuery` parameters: a record whose field names are the `@names` in the query.
    static func sqlServerParameters(_ v: MValue) throws -> [TDSParameter] {
        switch v {
        case .null: return []
        case .record(let r):
            return try zip(r.names, r.forcedValues()).map { name, value in
                TDSParameter(name: name.hasPrefix("@") ? name : "@" + name, value: try sqlServerParameter(value, name: name))
            }
        default:
            throw MError("SQL Server native query parameters are a record, such as [Region = \"West\"], used in the query as @Region.")
        }
    }

    static func sqlServerParameter(_ v: MValue, name: String) throws -> TDSParameter.Value {
        func split(_ d: Date) -> (days: Int, ticks: UInt64) {
            let s = d.timeIntervalSince1970, day = (s / 86_400).rounded(.down)
            return (Int(day) + TDSValues.unixEpochDay, UInt64(((s - day * 86_400) * 10_000_000).rounded()))
        }
        switch v {
        case .null: return .null
        case .logical(let b): return .bit(b)
        case .number(let d):
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return .bigint(Int64(d)) }
            guard d.isFinite else { throw MError("The parameter \(name) isn't a finite number.") }
            return .float(d)
        case .text(let s): return .text(s)
        case .binary(let b): return .binary(b)
        case .date(let d): return .date(days: split(d).days)
        case .datetime(let d): let p = split(d); return .datetime2(days: p.days, ticks: p.ticks)
        case .datetimezone(let d, let offset): let p = split(d); return .datetimeoffset(days: p.days, ticks: p.ticks, offsetMinutes: offset)
        case .time(let s): return .time(ticks: UInt64(max(0, s) * 10_000_000))
        default: throw MError("The parameter \(name) is a \(v.typeName), which SQL Server parameters can't hold.")
        }
    }
}
