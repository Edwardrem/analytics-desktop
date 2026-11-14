import Foundation
import FacetCore

/// Dataverse (`CommonDataService.Database`) through its Web API, with the signed-in organizational account.
/// Power BI's own connector uses the environment's TDS endpoint; the tables and columns here come from the Web API,
/// so lookup columns appear as `_<name>_value` ids, as the Web API names them.
enum DataverseSource {
    static let service = "Dataverse"
    static let apiPath = ["api", "data", "v9.2"]

    /// `<org>.crm.dynamics.com` or a regional `<org>.crm<N>.dynamics.com`.
    static func isEnvironmentHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4, labels.suffix(2) == ["dynamics", "com"], labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let crm = labels[labels.count - 3]
        guard crm.hasPrefix("crm") else { return false }
        let digits = crm.dropFirst(3)
        return digits.count <= 2 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func environment(_ ctx: MInterpreter, _ server: String) throws -> String {
        let (host, _) = try CloudSource.parse(server, function: "CommonDataService.Database")
        guard isEnvironmentHost(host) else {
            throw MError.dataSource("CommonDataService.Database needs a Dataverse environment such as contoso.crm.dynamics.com; '\(host)' isn't one.")
        }
        try ctx.noteDataSource(kind: "CommonDataService", location: host)
        return host
    }

    static func auth(_ host: String) -> CloudHTTP.Auth { .entra(resource: EntraResource.dataverse("https://" + host)) }

    static func database(_ ctx: MInterpreter, server: String) throws -> MTable {
        let host = try environment(ctx, server)
        guard let url = CloudSource.url(host: host, path: apiPath + ["EntityDefinitions"],
                                        query: [URLQueryItem(name: "$select", value: "LogicalName,EntitySetName,IsPrivate")]) else {
            throw MError.dataSource("Couldn't build the Dataverse address for '\(host)'.")
        }
        let entities = try CloudSource.pagedRecords(ctx, service: service, url: url, auth: auth(host))
            .filter { (try? $0.logical("IsPrivate")) ?? nil != true }
            .compactMap { e -> (String, String)? in
                guard let logical = CloudSource.text(e, "LogicalName"), let set = CloudSource.text(e, "EntitySetName"), !set.isEmpty else { return nil }
                return (logical, set)
            }
            .sorted { $0.0 < $1.0 }
        return CloudSource.navigation(entities.map { logical, set in
            (logical, "Table", [("Schema", .text("dbo"))], { .table(try rows(ctx, host: host, entitySet: set)) })
        })
    }

    /// Every row of an entity set, following the Web API's paging.
    static func rows(_ ctx: MInterpreter, host: String, entitySet: String) throws -> MTable {
        guard let url = CloudSource.url(host: host, path: apiPath + [entitySet]) else {
            throw MError.dataSource("Couldn't build the Dataverse address for '\(entitySet)'.")
        }
        let records = try CloudSource.pagedRecords(ctx, service: service, url: url,
                                                   headers: ["Prefer": "odata.maxpagesize=5000", "OData-MaxVersion": "4.0", "OData-Version": "4.0"],
                                                   auth: auth(host))
        return CloudSource.table(from: records)
    }
}

extension MLibrary {
    static func registerDataverse(_ lib: MLibrary) {
        lib.fn("CommonDataService.Database", 1...2) { a, ctx in .table(try DataverseSource.database(ctx, server: try a.text(0))) }
    }
}
