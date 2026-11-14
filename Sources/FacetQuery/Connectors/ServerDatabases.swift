import Foundation
import FacetCore

/// A database server named in M (`PostgreSQL.Database("host:5432", "sales", [CommandTimeout = #duration(0, 0, 5, 0)])`).
struct ServerSource {
    enum Product: String {
        case postgres = "PostgreSQL", redshift = "AmazonRedshift", mysql = "MySQL", mariadb = "MariaDB"
        var function: String {
            switch self {
            case .postgres: return "PostgreSQL.Database"
            case .redshift: return "AmazonRedshift.Database"
            case .mysql: return "MySQL.Database"
            case .mariadb: return "MariaDB.Contents"
            }
        }
        var defaultPort: UInt16 {
            switch self {
            case .postgres: return 5432
            case .redshift: return 5439
            case .mysql, .mariadb: return 3306
            }
        }
        var dialect: SQLDialect {
            switch self {
            case .postgres: return .postgres
            case .redshift: return .redshift
            case .mysql, .mariadb: return .mysql
            }
        }
        var displayName: String {
            switch self {
            case .postgres: return "PostgreSQL"
            case .redshift: return "Amazon Redshift"
            case .mysql: return "MySQL"
            case .mariadb: return "MariaDB"
            }
        }
    }

    var product: Product
    var server: String
    var database: String
    var options: MRecord?
    var address: ServerAddress
    var encrypt = true
    /// True when the user chose not to verify this host's certificate (`QueryEnvironment.trustServerCertificateHosts`).
    var trustServerCertificate = false
    var limits = WireLimits()
    /// Hand-written SQL from the `Query` option.
    var query: String?

    /// Kind and location as data source settings record them: "PostgreSQL" and "server;database".
    var kind: String { product.rawValue }
    var location: String { server + ";" + database }

    init(product: Product, server: String, database: String, options: MRecord?, maxBytes: Int, trustedHosts: Set<String> = []) throws {
        self.product = product; self.server = server; self.database = database; self.options = options
        address = try ServerAddress.parse(server, defaultPort: product.defaultPort)
        trustServerCertificate = trustedHosts.contains(address.host.lowercased())
        guard !database.trimmingCharacters(in: .whitespaces).isEmpty else { throw MError.dataSource("\(product.function) needs a database name.") }
        limits.maxResultBytes = maxBytes
        guard let options else { return }
        func seconds(_ name: String) throws -> TimeInterval? {
            switch try options.get(name) {
            case nil, .null?: return nil
            case .duration(let s)?: guard s > 0 else { throw MError("\(name) must be a positive duration.") }; return s
            case .number(let n)?: guard n > 0 else { throw MError("\(name) must be a positive number of seconds.") }; return n
            case let other?: throw MError.typeMismatch(expected: "duration", got: other)
            }
        }
        if let s = try seconds("CommandTimeout") { limits.commandTimeout = s }
        if let s = try seconds("ConnectionTimeout") { limits.connectTimeout = s }
        encrypt = try options.logical("EncryptConnection") ?? true
        query = try options.text("Query")
    }

    /// Options as kept in the navigation table's metadata, so `Value.NativeQuery` reconnects the same way.
    var metadata: MRecord {
        MRecord(names: ["Product", "Server", "Database", "Options"],
                values: [.text(product.rawValue), .text(server), .text(database), options.map(MValue.record) ?? .null])
    }
    static let metaField = "Facet.ServerDatabase"

    static func from(metadata r: MRecord, maxBytes: Int, trustedHosts: Set<String>) throws -> ServerSource? {
        guard let p = try r.text("Product"), let product = Product(rawValue: p), let server = try r.text("Server"),
              let database = try r.text("Database") else { return nil }
        var options: MRecord?
        if case .record(let o)? = try r.get("Options") { options = o }
        return try ServerSource(product: product, server: server, database: database, options: options, maxBytes: maxBytes, trustedHosts: trustedHosts)
    }

    // MARK: Credentials

    /// User and password (or Microsoft Entra token) for this server, from the credential provider.
    func login(_ ctx: MInterpreter) throws -> (user: String, password: String) {
        let missing = "\(product.displayName) needs credentials for '\(location)'. Enter a database user name and password "
            + "(or, for Azure Database, sign in with an organizational account) in Data source settings."
        switch ctx.credential(kind: kind, location: location) {
        case .basic(let user, let password)?:
            guard !user.isEmpty else { throw MError.dataSource(missing) }
            return (user, password)
        case .oauth(let resource)?:
            let token = try ctx.accessToken(resource: resource.isEmpty ? EntraResource.ossRDBMS : resource, host: address.host)
            return (try Self.tokenUser(token), token)
        case .bearer(let token)?:
            return (try Self.tokenUser(token), token)
        case nil, .anonymous?:
            throw MError.dataSource(missing)
        default:
            throw MError.dataSource("\(product.displayName) signs in with a user name and password or an organizational account; the credential stored for '\(location)' is neither.")
        }
    }

    /// The database user for a Microsoft Entra token: its `upn`, `preferred_username` or `unique_name` claim.
    static func tokenUser(_ token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard token.count <= 65_536, parts.count == 3 else { throw MError.dataSource("The organizational account token couldn't be read.") }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = ["upn", "preferred_username", "unique_name"].lazy.compactMap({ claims[$0] as? String }).first(where: { !$0.isEmpty }) else {
            throw MError.dataSource("The organizational account token names no user; sign in again with a work or school account.")
        }
        return user
    }

    // MARK: Opening

    /// The database for one evaluation (credentials are read now; connections open per statement).
    func open(_ ctx: MInterpreter) throws -> RemoteDatabase {
        let (user, password) = try login(ctx)
        switch product {
        case .postgres, .redshift:
            return PostgreSQLDatabase(source: self, user: user, password: password, trace: { ctx.addTrace($0) })
        case .mysql, .mariadb:
            return MySQLDatabase(source: self, user: user, password: password, trace: { ctx.addTrace($0) })
        }
    }
}

public extension MTable {
    /// True for the navigation table of a database server connector (`PostgreSQL.Database`, `MySQL.Database`, …),
    /// whose objects are addressed by `[Schema = …, Item = …]`.
    var isServerDatabaseNavigation: Bool { meta?.has(ServerSource.metaField) ?? false }
}

public enum ServerDatabaseHost {
    /// The lower-cased host of a server typed for `PostgreSQL.Database`, `MySQL.Database`, … (`host`, `host:port`,
    /// `host,port`, `[v6]:port`): the key the connectors look up in `QueryEnvironment.trustServerCertificateHosts`.
    public static func name(_ server: String) -> String? {
        guard let a = try? ServerAddress.parse(server, defaultPort: 1), !a.host.isEmpty else { return nil }
        return a.host.lowercased()
    }
}

/// Native query parameters: a list binds positionally; a record binds `@name` markers by name.
enum NativeParameters {
    static func bind(_ sql: String, _ value: MValue, dialect: SQLDialect) throws -> (sql: String, values: [MValue]) {
        switch value {
        case .null: return (sql, [])
        case .list(let items): return (sql, try items.map { try $0.forced() })
        case .record(let r):
            let names = r.names, values = try r.forcedValues()
            var used = Set<String>(), out: [MValue] = [], indexOf: [String: Int] = [:]
            var result = "", i = sql.startIndex
            func copy(until end: String.Index) { result += sql[i..<end]; i = end }
            while i < sql.endIndex {
                let c = sql[i]
                if c == "'" || c == "\"" || (c == "`" && dialect.isMySQL) {
                    var j = sql.index(after: i)
                    while j < sql.endIndex, sql[j] != c { j = sql.index(after: j) }
                    copy(until: j < sql.endIndex ? sql.index(after: j) : j)
                } else if c == "-", sql[i...].hasPrefix("--") {
                    copy(until: sql[i...].firstIndex(of: "\n") ?? sql.endIndex)
                } else if c == "/", sql[i...].hasPrefix("/*") {
                    copy(until: sql[sql.index(i, offsetBy: 2)...].range(of: "*/")?.upperBound ?? sql.endIndex)
                } else if c == "@" {
                    let start = sql.index(after: i)
                    var j = start
                    while j < sql.endIndex, sql[j].isLetter || sql[j].isNumber || sql[j] == "_" { j = sql.index(after: j) }
                    let name = String(sql[start..<j])
                    if let k = names.firstIndex(of: name) {
                        used.insert(name)
                        if dialect.isMySQL {
                            out.append(values[k]); result += "?"
                        } else {
                            if indexOf[name] == nil { out.append(values[k]); indexOf[name] = out.count }
                            result += "$\(indexOf[name] ?? 0)"
                        }
                        i = j
                    } else {
                        copy(until: j)
                    }
                } else {
                    copy(until: sql.index(after: i))
                }
            }
            if let unused = names.first(where: { !used.contains($0) }) {
                throw MError.dataSource("The native query has no parameter named '\(unused)' (write it as @\(unused)).")
            }
            return (result, out)
        default:
            throw MError.typeMismatch(expected: "record or list", got: value)
        }
    }
}

extension MLibrary {
    static func registerServerDatabases(_ lib: MLibrary) {
        for product in [ServerSource.Product.postgres, .redshift, .mysql, .mariadb] {
            lib.fn(product.function, 2...3) { a, ctx in
                let source = try ServerSource(product: product, server: try a.text(0), database: try a.text(1), options: try a.optRecord(2),
                                              maxBytes: ctx.environment.maxSourceBytes, trustedHosts: ctx.environment.trustServerCertificateHosts)
                try ctx.noteDataSource(kind: source.kind, location: source.location)
                let db = try source.open(ctx)
                if let sql = source.query {
                    try ctx.approveNativeQuery(sql, kind: source.kind, location: source.location)
                    let result = try db.query(sql, parameters: [], limit: nil)
                    return .table(try MTable.make(result.columns.map(\.name), result.columns.map(\.type), result.cells, rows: result.rowCount))
                }
                return .table(try navigation(db, source, ctx))
            }
        }
    }

    /// Schemas' tables and views: Name ("schema.table"), Data, Schema, Item, Kind.
    static func navigation(_ db: RemoteDatabase, _ source: ServerSource, _ ctx: MInterpreter) throws -> MTable {
        let d = db.dialect
        let sql: String
        if d.isMySQL {
            sql = "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME"
        } else {
            sql = "SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema NOT IN ('information_schema') "
                + "AND LEFT(table_schema, 3) <> 'pg_' ORDER BY table_schema, table_name"
        }
        let listing = try db.query(sql, parameters: [], limit: nil)
        guard listing.cells.count == 3 else { throw MError.dataSource("\(source.product.displayName) returned an unexpected list of tables.") }
        var rows: [[MValue]] = []
        for i in 0..<listing.rowCount {
            guard case .text(let schema) = listing.cells[0][i], case .text(let name) = listing.cells[1][i] else { continue }
            let kind = listing.cells[2][i].textValue?.uppercased().contains("VIEW") == true ? "View" : "Table"
            let data = MValue.lazy(MThunk {
                let from = d.qualified(schema, name)
                let columns = try wrap { try db.describe("SELECT * FROM " + from, parameters: []) }
                let q = RemoteSQLSource.Query(from: from, columns: columns.map(\.name), types: columns.map(\.type))
                return .table(MTable(source: RemoteSQLSource(database: db, query: q, interpreter: ctx)))
            })
            rows.append([.text(schema + "." + name), data, .text(schema), .text(name), .text(kind)])
        }
        let nav = MTable(names: ["Name", "Data", "Schema", "Item", "Kind"], types: [.text, .anyTable, .text, .text, .text], rows: rows)
        nav.meta = MRecord(names: [ServerSource.metaField], values: [.record(source.metadata)])
        return nav
    }

    /// `Value.NativeQuery` against a server database (nil when the target isn't one).
    static func serverNativeQuery(_ a: MArgs, _ ctx: MInterpreter) throws -> MValue? {
        guard case .table(let target) = a[0], case .record(let meta)? = try target.meta?.get(ServerSource.metaField),
              let source = try ServerSource.from(metadata: meta, maxBytes: ctx.environment.maxSourceBytes,
                                                          trustedHosts: ctx.environment.trustServerCertificateHosts) else { return nil }
        let db = try source.open(ctx)
        let (sql, parameters) = try NativeParameters.bind(try a.text(1), a[2], dialect: db.dialect)
        try ctx.approveNativeQuery(try a.text(1), kind: source.kind, location: source.location)
        if try a.optRecord(3)?.logical("EnableFolding") ?? false {
            let trimmed = sql.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
            let columns = try wrap { try db.describe(trimmed, parameters: parameters) }
            let q = RemoteSQLSource.Query(from: "(" + trimmed + ") AS " + db.dialect.quote("_"), columns: columns.map(\.name),
                                          types: columns.map(\.type), parameters: parameters)
            return .table(MTable(source: RemoteSQLSource(database: db, query: q, interpreter: ctx)))
        }
        let result = try wrap { try db.query(sql, parameters: parameters, limit: nil) }
        return .table(try MTable.make(result.columns.map(\.name), result.columns.map(\.type), result.cells, rows: result.rowCount))
    }

    /// Server failures surface as `DataSource.Error`.
    static func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as WireError { throw MError.dataSource(e.message) }
    }
}
