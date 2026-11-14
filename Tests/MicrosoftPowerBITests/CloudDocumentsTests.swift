import XCTest
import FacetCore
import FacetInterop
@testable import FacetCloud
@testable import MicrosoftPowerBI

/// Documents in OneDrive and SharePoint, through the app: which entries open as documents, the working copies they
/// open into, and saving back by eTag. Graph is answered in-process by `SelfCheckURLProtocol`.
@MainActor
final class CloudDocumentsTests: XCTestCase {
    private typealias Seen = (method: String, url: String, headers: [String: String], body: Data)
    private let seen = Recorder<[Seen]>([])
    private var work: URL!

    override func setUpWithError() throws {
        Features.registerAll()
        work = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        CloudDocuments.services = { CloudServices(cloud: .public, tokens: StubTokenProvider(), session: SelfCheckURLProtocol.configuration()) }
    }

    override func tearDownWithError() throws {
        SelfCheckURLProtocol.handler = nil
        CloudDocuments.services = { MicrosoftRuntime.shared.services }
        try? FileManager.default.removeItem(at: work)
    }

    private func stub(_ respond: @escaping @Sendable (String, String) -> SelfCheckURLProtocol.Response) {
        let seen = self.seen
        SelfCheckURLProtocol.handler = { request, body in
            let method = request.httpMethod ?? "GET", url = request.url?.absoluteString ?? ""
            seen.update { $0.append((method, url, request.allHTTPHeaderFields ?? [:], body)) }
            return respond(method, url)
        }
    }

    private func item(_ json: String) throws -> DriveItem { try HTTPHelpers.makeDecoder().decode(DriveItem.self, from: Data(json.utf8)) }

    private func sampleDocument() -> FacetDocument {
        var doc = FacetDocument()
        var t = ModelTable(name: "Sales")
        t.columns = [ModelColumn(name: "Amount", dataType: .decimal)]
        t.measures = [Measure(name: "Total", expression: "SUM ( Sales[Amount] )")]
        doc.model.tables = [t]
        doc.data["Sales"] = DataTable(name: "Sales", columns: [DataColumn(name: "Amount", type: .decimal, values: [.double(4), .double(6)])])
        return doc
    }

    /// The bytes of `doc` as it travels in the cloud: a zipped package.
    private func zipped(_ doc: FacetDocument) throws -> Data {
        let package = work.appendingPathComponent("src/Sales.facet")
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DocumentPackage.write(doc, to: package)
        let zip = work.appendingPathComponent("src/Sales.zip")
        try FacetArchive.pack(package: package, to: zip)
        return try Data(contentsOf: zip)
    }

    func testWhatOpensAsADocument() throws {
        XCTAssertTrue(CloudDocuments.isDocument(try item(#"{"id":"1","name":"Sales.facet","file":{}}"#)))
        XCTAssertTrue(CloudDocuments.isDocument(try item(#"{"id":"2","name":"Sales.FACET","folder":{"childCount":5}}"#)), "a package synced as a folder")
        XCTAssertTrue(CloudDocuments.isDocument(try item(#"{"id":"3","name":"Q1.pbip","file":{}}"#)))
        XCTAssertTrue(CloudDocuments.isDocument(try item(#"{"id":"4","name":"Q1.pbix","file":{}}"#)))
        XCTAssertFalse(CloudDocuments.isDocument(try item(#"{"id":"5","name":"Q1.Report","folder":{}}"#)))
        XCTAssertFalse(CloudDocuments.isDocument(try item(#"{"id":"6","name":"data.csv","file":{}}"#)))
        XCTAssertTrue(CloudDocuments.isSyncedFile("Sales.Report/definition/report.json"))
        XCTAssertFalse(CloudDocuments.isSyncedFile("Sales.SemanticModel/.pbi/localSettings.json"))
        XCTAssertFalse(CloudDocuments.isSyncedFile("Sales.Report/.DS_Store"))
    }

    func testProjectSaveBackStaysInsideTheProjectsFolders() {
        let mirror = CloudFolderMirror(driveID: "d", folderItemID: "f", folderPath: "Reports", files: [
            "Sales.pbip": CloudTrackedFile(itemID: "1", eTag: nil, sha256: ""),
            "Sales.Report/definition.pbir": CloudTrackedFile(itemID: "2", eTag: nil, sha256: ""),
        ])
        let project = CloudDocuments.syncedPaths(of: mirror, wholeFolder: false)
        XCTAssertTrue(project("Sales.Report/definition/pages/p1/page.json"))
        XCTAssertTrue(project("Sales.pbip"))
        XCTAssertFalse(project(".gitignore"), "files written beside the project stay on this Mac")
        XCTAssertFalse(project("Other.Report/x.json"))
        XCTAssertFalse(project("Sales.Report/.pbi/localSettings.json"))
        XCTAssertTrue(CloudDocuments.syncedPaths(of: mirror, wholeFolder: true)("data/Budget.json"), "a package folder goes back whole")
    }

    func testConflictChoicesDependOnHowTheDocumentTravels() {
        let conflict = CloudSaveError.conflict(name: "Sales.facet", modifiedBy: "Ana", modified: nil, currentETag: "e2")
        XCTAssertEqual(CloudDocuments.choices(for: conflict, packed: true), [.saveCopy, .replace, .cancel])
        XCTAssertEqual(CloudDocuments.choices(for: conflict, packed: false), [.replace, .cancel], "a project folder can't be copied in one step")
        XCTAssertEqual(CloudDocuments.choices(for: .missing(name: "Sales.facet"), packed: true), [.saveCopy, .cancel])
        XCTAssertEqual(CloudDocuments.choices(for: .missing(name: "x"), packed: false), [.cancel])
    }

    func testAZippedDocumentOpensFromItsUnpackedWorkingCopyAndSavesBackConditionally() async throws {
        let bytes = try zipped(sampleDocument())
        stub { method, url in
            if method == "GET", url.hasSuffix("/drives/d1/items/i1/content") { return SelfCheckURLProtocol.Response(status: 200, headers: [:], body: bytes) }
            if method == "PUT" { return .json(#"{"id":"i1","name":"Sales.facet","eTag":"\"e2\"","parentReference":{"driveId":"d1"}}"#) }
            return .json(#"{"error":{"code":"unexpected"}}"#, status: 500)
        }
        let cloudItem = try item(#"{"id":"i1","name":"Sales.facet","size":100,"file":{},"eTag":"\"e1\"","parentReference":{"driveId":"d1","id":"p1","path":"/drive/root:/Reports"}}"#)
        let (local, link, note) = try await CloudDocuments.download(cloudItem, sync: CloudDocuments.services().sync)
        addTeardownBlock { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        XCTAssertNil(note)
        XCTAssertEqual(local.lastPathComponent, "Sales.facet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("manifest.json").path), "unpacked into a package")
        guard case .packedDocument(let ref)? = link else { return XCTFail("\(String(describing: link))") }
        XCTAssertEqual(ref.eTag, "\"e1\"")

        // Open it the way the panel does, then edit and save.
        let store = DocumentStore(services: .live())
        DocumentFiles.pending[local.standardizedFileURL] = .cloud(link!)
        FileOperations.open(local, into: store)
        XCTAssertEqual(store.model.tables.map(\.name), ["Sales"])
        XCTAssertEqual(store.fileURL, local)
        XCTAssertEqual(DocumentFiles.of(store).cloud, link)
        store.updateModel("Rename") { $0.tables[0].description = "Edited" }
        XCTAssertTrue(FileOperations.save(store))
        XCTAssertFalse(store.isDirty)

        let files = DocumentFiles.of(store)
        let deadline = Date().addingTimeInterval(5)
        while files.cloudState == .uploading || files.cloudState == .idle, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .uploaded = files.cloudState else { return XCTFail("\(files.cloudState)") }
        let put = try XCTUnwrap(seen.value.first { $0.method == "PUT" })
        XCTAssertEqual(put.url, "https://graph.microsoft.com/v1.0/drives/d1/items/i1/content")
        XCTAssertEqual(put.headers["If-Match"], "\"e1\"")
        // What went up is the edited document, zipped.
        let uploaded = work.appendingPathComponent("up.zip")
        try put.body.write(to: uploaded)
        let check = work.appendingPathComponent("check.facet")
        try FacetArchive.unpack(uploaded, to: check)
        XCTAssertEqual(try DocumentPackage.read(from: check).model.tables.first?.description, "Edited")
        guard case .packedDocument(let after)? = files.cloud else { return XCTFail() }
        XCTAssertEqual(after.eTag, "\"e2\"", "the next save is conditional on the version just written")

        // A window reopened for the working copy without its cloud link (restored at launch) doesn't save into the cache.
        XCTAssertTrue(CloudDocumentSync.isWorkingCopy(local))
        let restored = DocumentStore(services: .live())
        FileOperations.open(local, into: restored)
        XCTAssertNil(restored.fileURL)
        XCTAssertNil(DocumentFiles.of(restored).cloud)
        XCTAssertEqual(restored.status?.kind, .warning)
    }

    func testReportsAndTemplatesOpenAsNewDocuments() async throws {
        let template = work.appendingPathComponent("T.pbit")
        try PBIXPackage.writeTemplate(sampleDocument(), to: template)
        let bytes = try Data(contentsOf: template)
        stub { _, _ in SelfCheckURLProtocol.Response(status: 200, headers: [:], body: bytes) }
        let cloudItem = try item(#"{"id":"t1","name":"Budget.pbit","size":10,"file":{},"parentReference":{"driveId":"d1"}}"#)
        let (local, link, note) = try await CloudDocuments.download(cloudItem, sync: CloudDocuments.services().sync)
        addTeardownBlock { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        XCTAssertNil(link, "a template isn't written back")
        XCTAssertTrue(note?.contains("new document from the template") == true)
        let store = DocumentStore(services: .live())
        FileOperations.open(local, into: store)
        XCTAssertNil(store.fileURL)
        XCTAssertEqual(store.model.tables.map(\.name), ["Sales"], store.status?.text ?? "")
        XCTAssertEqual(DocumentFiles.of(store).importedFrom, local)
    }

    func testCloudNamesNeverBecomePathsOutsideTheWorkingFolder() async throws {
        let root = CloudDocumentSync.workingRoot.standardizedFileURL.path
        for name in ["../../../Documents/Sales.facet", "/etc/Sales.facet", "..", "a\\b:c\u{0}.facet", String(repeating: "数", count: 200) + ".facet"] {
            let url = try CloudDocuments.stagingFile(named: name)
            addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            XCTAssertTrue(CloudDocumentSync.isWorkingCopy(url), url.path)
            XCTAssertEqual(url.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().path, root, name)
            XCTAssertFalse(url.lastPathComponent.contains("/") || url.lastPathComponent.hasPrefix("."), url.lastPathComponent)
            XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255, "fits in one file name")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)), url.lastPathComponent)
        }

        // A project opens from the mirror under its own name, so a name that isn't a safe file name is refused first.
        stub { _, _ in .json("{}", status: 500) }
        let project = try item(#"{"id":"p","name":"../../Sales.pbip","file":{},"parentReference":{"driveId":"d1","id":"folder","path":"/drive/root:/Reports"}}"#)
        do { _ = try await CloudDocuments.download(project, sync: CloudDocuments.services().sync); XCTFail("opened") }
        catch let e as CloudAPIError { XCTAssertTrue(e.message.contains("can't be used as a file name"), e.message) }
        XCTAssertTrue(seen.value.isEmpty, "nothing was requested")
    }

    func testOtherFilesAreNotOpenedAsDocuments() async throws {
        stub { _, _ in .json("{}", status: 500) }
        let csv = try item(#"{"id":"c","name":"data.csv","file":{},"parentReference":{"driveId":"d1"}}"#)
        do { _ = try await CloudDocuments.download(csv, sync: CloudDocuments.services().sync); XCTFail() }
        catch let e as CloudAPIError { XCTAssertTrue(e.message.contains(".pbip")) }
        XCTAssertTrue(seen.value.isEmpty)
    }
}
