import Foundation
import FacetCore

/// PostgreSQL (and Amazon Redshift, Azure Database for PostgreSQL, Aurora PostgreSQL) for the query engine.
final class PostgreSQLDatabase: RemoteDatabase {
    let source: ServerSource
    private let user: String
    private let password: String
    private let trace: (String) -> Void

    init(source: ServerSource, user: String, password: String, trace: @escaping (String) -> Void) {
        self.source = source; self.user = user; self.password = password; self.trace = trace
    }

    var dialect: SQLDialect { source.product.dialect }
    var kind: String { source.kind }
    var location: String { source.location }
    var connectionKey: String { "\(source.product.rawValue)|\(source.address.description)|\(source.database)|\(user)" }

    private func transport() throws -> WireSocket {
        try WireSocket(address: source.address, tls: source.encrypt ? .init(trustServerCertificate: source.trustServerCertificate) : nil,
                       negotiator: source.encrypt ? PGStartTLS() : nil, timeout: source.limits.connectTimeout)
    }

    private func session<T>(_ body: (PGConnection) throws -> T) throws -> T {
        do {
            let connection = try PGConnection(transport: try transport(),
                                              login: .init(user: user, password: password, database: source.database),
                                              limits: source.limits, notice: trace)
            connection.cancelTransport = { [weak self] in
                guard let self else { throw WireError("The connection is gone.") }
                return try self.transport()
            }
            defer { connection.close() }
            return try body(connection)
        } catch let e as WireError {
            throw MError.dataSource(e.message)
        }
    }

    func describe(_ sql: String, parameters: [MValue]) throws -> [RemoteColumn] {
        try session { c in
            let d = try c.describe(sql)
            return (d.fields ?? []).map { RemoteColumn(name: $0.name, type: PGType.mType($0.typeOID)) }
        }
    }

    func query(_ sql: String, parameters: [MValue], limit: Int?) throws -> RemoteResult {
        let texts = try parameters.map(PGType.parameterText)
        return try session { try $0.query(sql, parameters: texts, limit: limit) }
    }
}
