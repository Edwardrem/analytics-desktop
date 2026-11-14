import Foundation
import FacetCore

extension MLibrary {
    static func registerWeb(_ lib: MLibrary) {
        lib.fn("Web.Contents", 1...2) { a, ctx in
            let options = try MLib.options(a, 1)
            var text = try a.text(0)
            if let relative = try options.text("RelativePath") { text = text.hasSuffix("/") || relative.hasPrefix("/") ? text + relative : text + "/" + relative }
            guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty else {
                throw MError.dataSource("Web.Contents needs an http or https address; '\(text)' isn't one.")
            }
            var items = parts.queryItems ?? []
            if case .record(let q)? = try options.get("Query") {
                for (n, v) in zip(q.names, try q.forcedValues()) { items.append(URLQueryItem(name: n, value: try MConvert.text(v, culture: "en-US"))) }
            }
            let location = "\(scheme)://\(host)"
            try ctx.noteDataSource(kind: "Web", location: location)
            var headers: [String: String] = [:]
            if case .record(let h)? = try options.get("Headers") {
                for (n, v) in zip(h.names, try h.forcedValues()) { headers[n] = try MConvert.text(v, culture: "en-US") }
            }
            switch ctx.credential(kind: "Web", location: text) ?? ctx.credential(kind: "Web", location: location) ?? .anonymous {
            case .anonymous, .accountKey, .sasToken: break
            case .basic(let user, let password): headers["Authorization"] = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
            case .bearer(let token): headers["Authorization"] = "Bearer " + token
            case .oauth(let resource): headers["Authorization"] = "Bearer " + (try ctx.accessToken(resource: resource))
            case .apiKey(let key, let header, let parameter):
                if let header { headers[header] = key } else if let parameter { items.append(URLQueryItem(name: parameter, value: key)) }
                else { throw MError.dataSource("The API key for '\(location)' has neither a header name nor a query parameter name.") }
            }
            if !items.isEmpty { parts.queryItems = items }
            guard let url = parts.url else { throw MError.dataSource("'\(text)' isn't a valid web address.") }
            var request = URLRequest(url: url)
            if case .duration(let s)? = try options.get("Timeout") { request.timeoutInterval = s } else { request.timeoutInterval = ctx.environment.networkTimeout }
            if case .binary(let body)? = try options.get("Content") { request.httpMethod = "POST"; request.httpBody = body }
            for (n, v) in headers { request.setValue(v, forHTTPHeaderField: n) }
            var manual = Set<Int>()
            if case .list(let l)? = try options.get("ManualStatusHandling") { manual = Set(l.compactMap { $0.forcedCell().numberValue.map { Int($0) } }) }

            let done = DispatchSemaphore(value: 0)
            var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
            URLSession.shared.dataTask(with: request) { d, r, e in result = (d, r, e); done.signal() }.resume()
            done.wait()
            if let e = result.2 { throw MError.dataSource("Web.Contents couldn't reach '\(location)': \(e.localizedDescription)") }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0, data = result.0 ?? Data()
            if status >= 400, !manual.contains(status) {
                throw MError.dataSource("Web.Contents failed to get contents from '\(url.absoluteString)' (\(status)): \(HTTPURLResponse.localizedString(forStatusCode: status)).")
            }
            try ctx.checkSize(data.count, of: "The response from '\(location)'")
            return .binary(data)
        }
        lib.fn("Uri.EscapeDataString", 1) { a, _ in
            .text(try a.text(0).addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? "")
        }
        lib.fn("Uri.Combine", 2) { a, _ in
            guard let base = URL(string: try a.text(0)), let u = URL(string: try a.text(1), relativeTo: base) else { throw MError("Uri.Combine: the addresses aren't valid.") }
            return .text(u.absoluteString)
        }
        lib.fn("Uri.BuildQueryString", 1) { a, _ in
            var c = URLComponents()
            let r = try a.record(0)
            c.queryItems = try zip(r.names, r.forcedValues()).map { URLQueryItem(name: $0, value: try MConvert.text($1, culture: "en-US")) }
            return .text(c.percentEncodedQuery ?? "")
        }
        let unavailable: [(String, String)] = [
            ("Web.BrowserContents", "browser-rendered page"),
            ("SharePoint.Files", "SharePoint folder"), ("SharePoint.Contents", "SharePoint folder"), ("SharePoint.Tables", "SharePoint list"),
            ("AzureStorage.Blobs", "Azure Blob Storage"), ("AzureStorage.DataLake", "Azure Data Lake Storage"),
            ("PowerBI.Dataflows", "Power BI dataflows"), ("PowerPlatform.Dataflows", "Power Platform dataflows"),
            ("CommonDataService.Database", "Dataverse"), ("Salesforce.Data", "Salesforce"), ("Exchange.Contents", "Exchange"),
            ("ActiveDirectory.Domains", "Active Directory"), ("Hdfs.Files", "Hadoop (HDFS)"),
        ]
        for (name, product) in unavailable {
            lib.fn(name, 0...4) { _, _ in
                throw MError.dataSource("The \(product) connector (\(name)) isn't available in this version of \(AppIdentity.name).")
            }
        }
    }
}
