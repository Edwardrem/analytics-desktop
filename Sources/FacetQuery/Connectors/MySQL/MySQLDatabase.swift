import Foundation
import FacetCore

/// MySQL and MariaDB (including Azure Database for MySQL and Amazon RDS / Aurora MySQL) for the query engine.
final class MySQLDatabase: RemoteDatabase {
    let source: ServerSource
    private let user: String
    private let password: String
    private let trace: (String) -> Void

    init(source: ServerSource, user: String, password: String, trace: @escaping (String) -> Void) {
        self.source = source; self.user = user; self.password = password; self.trace = trace
    }

    var dialect: SQLDialect { .mysql }
    var kind: String { source.kind }
    var location: String { source.location }
    var connectionKey: String { "\(source.product.rawValue)|\(source.address.description)|\(source.database)|\(user)" }

    private func session<T>(_ body: (MySQLConnection) throws -> T) throws -> T {
        do {
            let login = MySQLConnection.Login(user: user, password: password, database: source.database)
            let connection: MySQLConnection
            if source.encrypt {
                let tls = MySQLStartTLS()
                let socket = try WireSocket(address: source.address, tls: .init(trustServerCertificate: source.trustServerCertificate),
                                            negotiator: tls, timeout: source.limits.connectTimeout)
                guard let greeting = tls.greeting else { throw WireError("The server's greeting was lost during the TLS handshake.") }
                connection = try MySQLConnection(transport: socket, login: login, limits: source.limits, greeting: greeting, capabilities: tls.capabilities)
            } else {
                let socket = try WireSocket(address: source.address, tls: nil, negotiator: nil, timeout: source.limits.connectTimeout)
                connection = try MySQLConnection(transport: socket, login: login, limits: source.limits)
            }
            defer { connection.close() }
            return try body(connection)
        } catch let e as WireError {
            throw MError.dataSource(e.message)
        }
    }

    func describe(_ sql: String, parameters: [MValue]) throws -> [RemoteColumn] {
        try session { c in try c.describe(sql).columns.map { RemoteColumn(name: $0.name, type: MySQLType.mType($0)) } }
    }

    func query(_ sql: String, parameters: [MValue], limit: Int?) throws -> RemoteResult {
        try session { c in parameters.isEmpty ? try c.query(sql, limit: limit) : try c.execute(sql, parameters: parameters, limit: limit) }
    }
}
