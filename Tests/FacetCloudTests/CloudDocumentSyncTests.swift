import XCTest
@testable import FacetCloud

/// Opening documents from OneDrive / SharePoint into working copies and saving them back by eTag.
/// Every request is answered in-process by `SelfCheckURLProtocol`.
final class CloudDocumentSyncTests: XCTestCase {
    private typealias Seen = (method: String, url: String, headers: [String: String], body: Data)
    private let seen = Recorder<[Seen]>([])
    private var sync: CloudDocumentSync!
    private var work: URL!

    override func setUpWithError() throws {
        sync = CloudDocumentSync(graph: GraphClient(tokenProvider: StubTokenProvider(), sessionConfiguration: SelfCheckURLProtocol.configuration()))
        work = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SelfCheckURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: work)
    }

    private func stub(_ respond: @escaping @Sendable (String, String, URLRequest) -> SelfCheckURLProtocol.Response) {
        let seen = self.seen
        SelfCheckURLProtocol.handler = { request, body in
            let method = request.httpMethod ?? "GET", url = request.url?.absoluteString ?? ""
            seen.update { $0.append((method, url, request.allHTTPHeaderFields ?? [:], body)) }
            return respond(method, url, request)
        }
    }

    private func item(_ json: String) throws -> DriveItem {
        try HTTPHelpers.makeDecoder().decode(DriveItem.self, from: Data(json.utf8))
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static let sales = #"{"id":"i1","name":"Sales.facet","size":5,"file":{},"eTag":"\"e1\"","webUrl":"https://contoso-my.sharepoint.com/Sales.facet","parentReference":{"driveId":"d1","id":"p1","path":"/drive/root:/Reports/2026"}}"#

    func testOnlyRegularFilesAreUploaded() async throws {
        stub { _, _, _ in .json(#"{"id":"x","name":"x"}"#) }
        let pipe = work.appendingPathComponent("pipe.facet")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let device = work.appendingPathComponent("zero.facet")
        try FileManager.default.createSymbolicLink(atPath: device.path, withDestinationPath: "/dev/zero")
        let graph = GraphClient(tokenProvider: StubTokenProvider(), sessionConfiguration: SelfCheckURLProtocol.configuration())
        let folder: URL = work
        for url in [pipe, device, folder] {
            do { _ = try await graph.upload(fileAt: url, named: "x.facet"); XCTFail("uploaded \(url.lastPathComponent)") }
            catch let e as CloudAPIError { XCTAssertTrue(e.message.contains("not a file that can be uploaded"), e.message) }
            do { _ = try await graph.replaceContent(of: .item(driveID: "d1", itemID: "i1"), withFileAt: url); XCTFail("replaced with \(url.lastPathComponent)") }
            catch let e as CloudAPIError { XCTAssertTrue(e.message.contains("not a file that can be uploaded"), e.message) }
        }
        XCTAssertTrue(seen.value.isEmpty, "nothing was sent")
        // A link to a real file is followed.
        let real = try file("real.facet", "PK")
        let link = work.appendingPathComponent("link.facet")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        _ = try await graph.upload(fileAt: link, named: "link.facet")
        XCTAssertEqual(seen.value.last?.body, Data("PK".utf8))
    }

    // MARK: Open

    func testDownloadMakesAWorkingCopyAndRemembersTheVersion() async throws {
        stub { _, url, _ in
            url.hasSuffix("/drives/d1/items/i1/content") ? SelfCheckURLProtocol.Response(status: 200, headers: [:], body: Data("hello".utf8))
                : .json(#"{"error":{"code":"unexpected"}}"#, status: 500)
        }
        let (local, ref) = try await sync.download(try item(Self.sales), into: work)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "hello")
        XCTAssertEqual(local.lastPathComponent, "Sales.facet")
        XCTAssertEqual(ref, CloudFileReference(driveID: "d1", itemID: "i1", name: "Sales.facet", eTag: "\"e1\"",
                                               webURL: "https://contoso-my.sharepoint.com/Sales.facet", parentItemID: "p1",
                                               parentPath: "/drive/root:/Reports/2026"))
        XCTAssertEqual(ref.folderDisplayName, "Reports ▸ 2026")
        XCTAssertEqual(seen.value.first?.headers["Authorization"], "Bearer stale-token")
    }

    func testOversizedFilesAreNotDownloaded() async throws {
        stub { _, _, _ in SelfCheckURLProtocol.Response(status: 200, headers: [:], body: Data(repeating: 0x41, count: 4096)) }
        // The listing already says it is too large: nothing is requested.
        do { _ = try await sync.download(try item(Self.sales), into: work, maxBytes: 4); XCTFail("downloaded a file above the limit") }
        catch let e as CloudSaveError { XCTAssertEqual(e, .tooLarge(name: "Sales.facet", limit: 4)) }
        XCTAssertTrue(seen.value.isEmpty)
        // The listing gave no size, the body is larger than the limit: the download stops.
        let unsized = try item(#"{"id":"i1","name":"Sales.facet","file":{},"parentReference":{"driveId":"d1"}}"#)
        do { _ = try await sync.download(unsized, into: work, maxBytes: 1024); XCTFail("kept reading past the limit") }
        catch let e as CloudSaveError { XCTAssertEqual(e, .tooLarge(name: "Sales.facet", limit: 1024)) }
    }

    func testFoldersAndItemsWithoutADriveCannotBeOpened() async throws {
        let folder = try item(#"{"id":"f","name":"Reports","folder":{"childCount":2},"parentReference":{"driveId":"d1"}}"#)
        do { _ = try await sync.download(folder, into: work); XCTFail("opened a folder") } catch let e as CloudAPIError { XCTAssertEqual(e.kind, .badRequest) }
        XCTAssertNil(CloudFileReference(item: try item(#"{"id":"x","name":"x.facet","file":{}}"#)))
    }

    func testLocalNamesNeverEscapeTheWorkingFolder() {
        XCTAssertEqual(CloudDocumentSync.safeFileName("../a/b:c"), "_a_b_c")
        XCTAssertEqual(CloudDocumentSync.safeFileName(".hidden"), "hidden")
        XCTAssertEqual(CloudDocumentSync.safeFileName("  "), "download")
        XCTAssertEqual(CloudDocumentSync.safeFileName("Q1\nReport.facet"), "Q1_Report.facet")
        XCTAssertFalse(CloudDocumentSync.isSafeComponent(".."))
        XCTAssertFalse(CloudDocumentSync.isSafeComponent("a/b"))
        XCTAssertTrue(CloudDocumentSync.isSafeComponent("Sales.Report"))
    }

    // MARK: Save back

    private var reference: CloudFileReference {
        CloudFileReference(driveID: "d1", itemID: "i1", name: "Sales.facet", eTag: "\"e1\"", parentItemID: "p1")
    }

    func testSaveBackIsConditionalOnTheOpenedVersion() async throws {
        stub { method, _, _ in
            method == "PUT" ? .json(#"{"id":"i1","name":"Sales.facet","eTag":"\"e2\"","parentReference":{"driveId":"d1"}}"#) : .json("{}", status: 500)
        }
        let saved = try await sync.saveBack(fileAt: try file("Sales.facet", "v2"), to: reference)
        XCTAssertEqual(saved.eTag, "\"e2\"")
        let put = try XCTUnwrap(seen.value.first)
        XCTAssertEqual(put.url, "https://graph.microsoft.com/v1.0/drives/d1/items/i1/content")
        XCTAssertEqual(put.headers["If-Match"], "\"e1\"")
        XCTAssertEqual(String(decoding: put.body, as: UTF8.self), "v2")
    }

    func testANewerCloudVersionIsReportedNotOverwritten() async throws {
        stub { method, _, _ in
            if method == "PUT" { return .json(#"{"error":{"code":"resourceModified","message":"ETag does not match"}}"#, status: 412) }
            return .json(#"{"id":"i1","name":"Sales.facet","eTag":"\"e3\"","lastModifiedDateTime":"2026-11-13T09:30:00Z","lastModifiedBy":{"user":{"displayName":"Ana Lopes"}},"parentReference":{"driveId":"d1"}}"#)
        }
        do {
            _ = try await sync.saveBack(fileAt: try file("Sales.facet", "mine"), to: reference)
            XCTFail("overwrote a newer version")
        } catch let e as CloudSaveError {
            guard case .conflict(let name, let who, let when, let etag) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(name, "Sales.facet")
            XCTAssertEqual(who, "Ana Lopes")
            XCTAssertEqual(when, ISO8601DateFormatter().date(from: "2026-11-13T09:30:00Z"))
            XCTAssertEqual(etag, "\"e3\"")
            XCTAssertTrue(e.localizedDescription.contains("Ana Lopes"))
        }
        // Only one write was attempted, and it was conditional.
        XCTAssertEqual(seen.value.filter { $0.method == "PUT" }.count, 1)
    }

    func testOverwriteIsUnconditionalAndAMissingFileIsExplained() async throws {
        stub { _, _, _ in .json(#"{"id":"i1","name":"Sales.facet","eTag":"\"e9\"","parentReference":{"driveId":"d1"}}"#) }
        _ = try await sync.saveBack(fileAt: try file("Sales.facet", "x"), to: reference, overwrite: true)
        XCTAssertNil(seen.value.first?.headers["If-Match"])

        stub { _, _, _ in .json(#"{"error":{"code":"itemNotFound","message":"Item not found"}}"#, status: 404) }
        do { _ = try await sync.saveBack(fileAt: try file("Sales.facet", "x"), to: reference); XCTFail("no error") }
        catch let e as CloudSaveError { XCTAssertEqual(e, .missing(name: "Sales.facet")) }
    }

    func testNewFilesDoNotReplaceAnExistingOneAndCopiesAreRenamed() async throws {
        stub { _, _, _ in .json(#"{"error":{"code":"nameAlreadyExists","message":"The specified item name already exists."}}"#, status: 409) }
        do {
            _ = try await sync.saveNew(fileAt: try file("Sales.facet", "x"), in: .myRoot, named: "Sales.facet", replace: false)
            XCTFail("replaced an existing file")
        } catch let e as CloudSaveError { XCTAssertEqual(e, .nameTaken(name: "Sales.facet")) }
        XCTAssertEqual(seen.value.last?.url, "https://graph.microsoft.com/v1.0/me/drive/root:/Sales.facet:/content?@microsoft.graph.conflictBehavior=fail")

        stub { _, _, _ in .json(#"{"id":"c1","name":"Sales 1.facet","eTag":"\"c\"","parentReference":{"driveId":"d1","id":"p1"}}"#, status: 201) }
        let copy = try await sync.saveCopy(fileAt: try file("Sales.facet", "x"), named: "Sales.facet", nextTo: reference)
        XCTAssertEqual(copy.itemID, "c1")
        XCTAssertEqual(copy.name, "Sales 1.facet")
        XCTAssertEqual(seen.value.last?.url, "https://graph.microsoft.com/v1.0/drives/d1/items/p1:/Sales.facet:/content?@microsoft.graph.conflictBehavior=rename")
    }

    // MARK: Project folders

    private func projectStub(currentETag: String = "\"a1\"") {
        stub { method, url, _ in
            switch (method, url) {
            case ("GET", let u) where u.contains("/drives/d1/items/root1/children"):
                return .json(#"{"value":[{"id":"f1","name":"Sales.pbip","size":3,"file":{},"eTag":"\"a1\""},{"id":"r1","name":"Sales.Report","folder":{"childCount":1}},{"id":"f9","name":"Notes.txt","size":3,"file":{}}]}"#)
            case ("GET", let u) where u.contains("/drives/d1/items/r1/children"):
                return .json(#"{"value":[{"id":"f2","name":"definition.pbir","size":3,"file":{},"eTag":"\"b1\""}]}"#)
            case ("GET", let u) where u.hasSuffix("/items/f1/content"): return SelfCheckURLProtocol.Response(status: 200, headers: [:], body: Data("pbp".utf8))
            case ("GET", let u) where u.hasSuffix("/items/f2/content"): return SelfCheckURLProtocol.Response(status: 200, headers: [:], body: Data("pbr".utf8))
            case ("GET", let u) where u.hasSuffix("/drives/d1/items/f1"): return .json(#"{"id":"f1","name":"Sales.pbip","eTag":"\#(currentETag.replacingOccurrences(of: "\"", with: "\\\""))","lastModifiedBy":{"user":{"displayName":"Sam"}}}"#)
            case ("GET", let u) where u.hasSuffix("/drives/d1/items/f2"): return .json(#"{"id":"f2","name":"definition.pbir","eTag":"\"b1\""}"#)
            case ("PUT", let u) where u.hasSuffix("/items/f1/content"): return .json(#"{"id":"f1","name":"Sales.pbip","eTag":"\"a2\""}"#)
            case ("PUT", _): return .json(#"{"id":"n1","name":"new.json","eTag":"\"n\""}"#, status: 201)
            case ("DELETE", _): return SelfCheckURLProtocol.Response(status: 204, headers: [:], body: Data())
            default: return .json(#"{"error":{"code":"unexpected"}}"#, status: 500)
            }
        }
    }

    private func downloadProject() async throws -> (URL, CloudFolderMirror) {
        let root = work.appendingPathComponent("project")
        let mirror = try await sync.downloadFolder(driveID: "d1", folderItemID: "root1", folderPath: "Reports/P",
                                                   only: ["Sales.pbip", "Sales.Report"], into: root)
        return (root, mirror)
    }

    func testAProjectFolderIsMirroredAndOnlyEditsAreSentBack() async throws {
        projectStub()
        let (root, mirror) = try await downloadProject()
        XCTAssertEqual(Set(mirror.files.keys), ["Sales.pbip", "Sales.Report/definition.pbir"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Sales.Report/definition.pbir"), encoding: .utf8), "pbr")

        try Data("edited".utf8).write(to: root.appendingPathComponent("Sales.pbip"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("Sales.Report/new.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sales.Report/definition.pbir"))
        try Data("x".utf8).write(to: root.appendingPathComponent("Sales.Report/localSettings.json"))
        let relevant: (String) -> Bool = { !$0.hasSuffix("localSettings.json") }
        XCTAssertEqual(try CloudDocumentSync.changes(in: root, since: mirror, relevant: relevant),
                       .init(changed: ["Sales.pbip"], added: ["Sales.Report/new.json"], removed: ["Sales.Report/definition.pbir"]))

        seen.update { $0.removeAll() }
        let updated = try await sync.uploadChanges(from: root, mirror: mirror, relevant: relevant)
        let writes = seen.value.filter { $0.method != "GET" }
        XCTAssertEqual(writes.map(\.method), ["PUT", "PUT", "DELETE"])
        XCTAssertEqual(writes[0].headers["If-Match"], "\"a1\"")
        XCTAssertEqual(writes[1].url, "https://graph.microsoft.com/v1.0/drives/d1/root:/Reports/P/Sales.Report/new.json:/content?@microsoft.graph.conflictBehavior=fail")
        XCTAssertEqual(writes[2].headers["If-Match"], "\"b1\"")
        XCTAssertEqual(updated.files["Sales.pbip"]?.eTag, "\"a2\"")
        XCTAssertEqual(updated.files["Sales.Report/new.json"]?.itemID, "n1")
        XCTAssertNil(updated.files["Sales.Report/definition.pbir"])
        XCTAssertTrue(try CloudDocumentSync.changes(in: root, since: updated, relevant: relevant).isEmpty)
    }

    func testNothingIsWrittenWhenAProjectFileChangedInTheCloud() async throws {
        projectStub()
        let (root, mirror) = try await downloadProject()
        try Data("edited".utf8).write(to: root.appendingPathComponent("Sales.pbip"))
        projectStub(currentETag: "\"a7\"")
        seen.update { $0.removeAll() }
        do {
            _ = try await sync.uploadChanges(from: root, mirror: mirror, relevant: { _ in true })
            XCTFail("wrote over a newer cloud version")
        } catch let e as CloudSaveError {
            XCTAssertEqual(e, .conflict(name: "Sales.pbip", modifiedBy: "Sam", modified: nil, currentETag: "\"a7\""))
        }
        XCTAssertEqual(seen.value.filter { $0.method != "GET" }.count, 0)
    }

    func testUnsafeNamesInACloudFolderAreRefused() async throws {
        stub { _, _, _ in .json(#"{"value":[{"id":"f1","name":"..","size":1,"file":{}}]}"#) }
        do {
            _ = try await sync.downloadFolder(driveID: "d1", folderItemID: "root1", folderPath: nil, only: [".."], into: work.appendingPathComponent("p"))
            XCTFail("accepted an unsafe name")
        } catch let e as CloudAPIError { XCTAssertEqual(e.kind, .invalidResponse) }
    }

    func testGraphFolderPathsBecomeDrivePaths() {
        XCTAssertEqual(CloudDocumentSync.relativeFolderPath(fromGraphPath: "/drive/root:/Reports/My%20Team"), "Reports/My Team")
        XCTAssertEqual(CloudDocumentSync.relativeFolderPath(fromGraphPath: "/drives/b!x/root:"), "")
        XCTAssertNil(CloudDocumentSync.relativeFolderPath(fromGraphPath: nil))
    }
}
