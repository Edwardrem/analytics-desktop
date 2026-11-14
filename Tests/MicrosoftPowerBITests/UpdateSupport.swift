import Foundation
@testable import MicrosoftPowerBI

/// Stands in for the network in updater tests: answers registered URLs, follows registered redirects,
/// and records every request. Nothing here ever reaches a real host.
final class UpdateStubProtocol: URLProtocol {
    enum Reply {
        case respond(status: Int, headers: [String: String], body: Data)
        case redirect(to: String)
    }
    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var log: [URLRequest] = []

    static func reset() { lock.lock(); replies = [:]; log = []; lock.unlock() }
    static func on(_ url: String, _ reply: Reply) { lock.lock(); replies[url] = reply; lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.log.append(request)
        let reply = Self.replies[url]
        Self.lock.unlock()
        guard let u = request.url else { return }
        switch reply {
        case .respond(let status, let headers, let body)?:
            let response = HTTPURLResponse(url: u, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target)?:
            guard let t = URL(string: target),
                  let response = HTTPURLResponse(url: u, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]) else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: t), redirectResponse: response)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
    override func stopLoading() {}
}

/// Temporary app bundles, zips and keys for updater tests.
enum UpdateFixtures {
    static func temporaryFolder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A minimal app bundle: Info.plist, an executable shell script and a code signature folder.
    @discardableResult
    static func makeApp(at url: URL, identifier: String = "io.github.edwardrem.AnalyticsDesktop", version: String,
                        executable: String = "MicrosoftPowerBI", signed: Bool = true, marker: String = "") throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
                                   "CFBundleExecutable": executable, "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let exe = macOS.appendingPathComponent(executable)
        try Data("#!/bin/sh\n# \(marker)\nexit 0\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        if signed {
            let sig = contents.appendingPathComponent("_CodeSignature")
            try FileManager.default.createDirectory(at: sig, withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: sig.appendingPathComponent("CodeResources"))
        }
        return url
    }

    /// Zips a bundle the way `Scripts/release.sh` does (`ditto -c -k --keepParent`).
    static func zip(_ app: URL, to zip: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
}
