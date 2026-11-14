import Foundation

/// Which hosts a token for a given Entra resource may be sent to.
///
/// A token is bound to its audience: an Azure SQL token only goes to SQL servers, a Storage token only to storage
/// accounts and OneLake, and a token for a per-tenant resource (a Dataverse environment, a Kusto cluster, a SharePoint
/// tenant) only to that resource's own host, which must itself belong to the service's domain.
///
/// Suffix rules are exact: the host must end with the suffix *including its leading dot*, have at least one label
/// before it, and be a plain DNS name (letters, digits, hyphens; no empty labels, no IP literals, no port, no user).
/// So `contoso.database.windows.net` passes, while `database.windows.net.evil.com`, `evildatabase.windows.net` and
/// `contoso.database.windows.net.` do not.
public enum TokenAudiencePolicy {
    /// Hosts a resource's token may reach, for resources served from fixed or suffix-matched hosts (global cloud).
    struct Rule {
        var exact: Set<String> = []
        var suffixes: [String] = []
        func allows(_ host: String) -> Bool {
            exact.contains(host) || suffixes.contains { TokenAudiencePolicy.hasExactSuffix(host, $0) }
        }
    }

    static let sqlSuffixes = [".database.windows.net", ".datawarehouse.fabric.microsoft.com", ".database.fabric.microsoft.com", ".sql.azuresynapse.net"]
    static let storageSuffixes = [".blob.core.windows.net", ".dfs.core.windows.net", ".dfs.fabric.microsoft.com", ".onelake.fabric.microsoft.com"]
    static let ossSuffixes = [".postgres.database.azure.com", ".mysql.database.azure.com"]

    /// Rules keyed by the resource's host (the audience), global cloud.
    static let fixed: [String: Rule] = [
        "graph.microsoft.com": Rule(exact: ["graph.microsoft.com"]),
        "analysis.windows.net": Rule(exact: ["api.powerbi.com"]),
        "api.fabric.microsoft.com": Rule(exact: ["api.fabric.microsoft.com"]),
        "database.windows.net": Rule(suffixes: sqlSuffixes),
        "storage.azure.com": Rule(exact: ["onelake.dfs.fabric.microsoft.com"], suffixes: storageSuffixes),
        "ossrdbms-aad.database.windows.net": Rule(suffixes: ossSuffixes),
    ]

    /// Whether a token for `resource` (a `/.default` scope, scope list, or resource URL) may be sent to `host`.
    public static func allows(resource: String, host rawHost: String, cloud: MicrosoftCloud = .public) -> Bool {
        let host = rawHost.lowercased()
        guard isPlainHostName(host), let audience = audienceHost(of: resource) else { return false }
        if cloud != .public {
            // National clouds: only the services their own endpoints name (Graph, Power BI, Fabric).
            let policy = EndpointPolicy(cloud: cloud)
            let graph = cloud.graphEndpoint.host?.lowercased(), pbiResource = URL(string: cloud.powerBIResource)?.host?.lowercased()
            if audience == graph { return host == graph }
            if audience == pbiResource { return host == cloud.powerBIEndpoint.host?.lowercased() }
            return policy.hosts.contains(host) && audience == host
        }
        if let rule = fixed[audience] { return rule.allows(host) }
        // Per-tenant resources: the token goes only to the resource's own host, inside the service's domain.
        guard host == audience else { return false }
        return isDataverseHost(host) || hasExactSuffix(host, ".kusto.windows.net") || isSharePointHost(host)
    }

    /// The audience host of a resource string: `https://contoso.crm.dynamics.com/.default` → `contoso.crm.dynamics.com`.
    /// Graph-style scopes (`User.Read`, `offline_access`) mean Graph.
    static func audienceHost(of resource: String) -> String? {
        let first = resource.split(separator: " ").map(String.init).first { $0 != "offline_access" && $0 != "openid" && $0 != "profile" } ?? ""
        if !first.contains("://") { return first.isEmpty ? nil : "graph.microsoft.com" }
        guard let c = URLComponents(string: first), c.scheme?.lowercased() == "https", c.user == nil, c.port == nil,
              let host = c.host?.lowercased(), isPlainHostName(host) else { return nil }
        return host
    }

    /// `<org>.crm.dynamics.com` or a regional `<org>.crm<N>.dynamics.com`.
    public static func isDataverseHost(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4, isPlainHostName(host.lowercased()),
              labels[labels.count - 1] == "com", labels[labels.count - 2] == "dynamics" else { return false }
        let crm = labels[labels.count - 3]
        guard crm.hasPrefix("crm") else { return false }
        let digits = crm.dropFirst(3)
        return digits.count <= 2 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    /// `<tenant>.sharepoint.com` or `<tenant>-my.sharepoint.com` (one label before the suffix).
    public static func isSharePointHost(_ host: String) -> Bool {
        let h = host.lowercased()
        guard hasExactSuffix(h, ".sharepoint.com") else { return false }
        return !h.dropLast(".sharepoint.com".count).contains(".")
    }

    /// `host` ends with `suffix` (which starts with a dot) and has a non-empty label before it.
    public static func hasExactSuffix(_ host: String, _ suffix: String) -> Bool {
        let h = host.lowercased()
        guard suffix.hasPrefix("."), h.hasSuffix(suffix), h.count > suffix.count, isPlainHostName(h) else { return false }
        return !h.dropLast(suffix.count).hasSuffix(".")
    }

    /// A DNS name of letters, digits and hyphens: no empty labels, no trailing dot, no IP literal.
    public static func isPlainHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        }
    }
}
