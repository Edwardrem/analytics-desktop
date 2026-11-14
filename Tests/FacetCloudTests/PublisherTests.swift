import XCTest
@testable import FacetCloud

/// Publishing to the Power BI service: Fabric item definitions for the model and report, and the import API for
/// files the service reads. Every request is answered in-process by `SelfCheckURLProtocol`.
final class PublisherTests: XCTestCase {
    private typealias Seen = (method: String, url: String, body: Data)
    private let seen = Recorder<[Seen]>([])
    private var publisher: PowerBIPublisher!
    private let workspace = PublishWorkspace(id: "w1", name: "Finance", isPersonal: false)

    override func setUp() {
        let tokens = StubTokenProvider()
        let cfg = SelfCheckURLProtocol.configuration()
        let fabric = FabricClient(tokenProvider: tokens, sessionConfiguration: cfg)
        fabric.rest.sleeper = { _ in }
        let powerBI = PowerBIClient(tokenProvider: tokens, sessionConfiguration: cfg)
        powerBI.rest.sleeper = { _ in }
        publisher = PowerBIPublisher(fabric: fabric, powerBI: powerBI)
    }

    override func tearDown() { SelfCheckURLProtocol.handler = nil }

    private func stub(_ respond: @escaping @Sendable (String, String, Data) -> SelfCheckURLProtocol.Response) {
        let seen = self.seen
        SelfCheckURLProtocol.handler = { request, body in
            let method = request.httpMethod ?? "GET", url = request.url?.absoluteString ?? ""
            seen.update { $0.append((method, url, body)) }
            return respond(method, url, body)
        }
    }

    private let modelParts = [FabricDefinitionPart(path: "definition.pbism", text: "{}"),
                              FabricDefinitionPart(path: "definition/model.tmdl", text: "model Model")]
    private let reportParts = [FabricDefinitionPart(path: "definition.pbir", text: #"{"datasetReference":{"byPath":{"path":"../Sales.SemanticModel"}}}"#),
                               FabricDefinitionPart(path: "definition/report.json", text: "{}")]

    /// The decoded parts of a create/update body.
    private func parts(_ body: Data) throws -> [String: String] {
        let json = try JSONValue.parse(body)
        var out: [String: String] = [:]
        for p in json["definition"]?["parts"]?.arrayValue ?? [] {
            let payload = try XCTUnwrap(p["payload"]?.stringValue.flatMap { Data(base64Encoded: $0) })
            out[p["path"]?.stringValue ?? ""] = String(decoding: payload, as: UTF8.self)
        }
        return out
    }

    func testANewModelIsCreatedAndTheReportIsBoundToIt() async throws {
        stub { method, url, body in
            if method == "GET", url.contains("/v1/workspaces/w1/items") { return .json(#"{"value":[]}"#) }
            if method == "POST", url.hasSuffix("/v1/workspaces/w1/items") {
                let type = (try? JSONValue.parse(body))?["type"]?.stringValue
                return type == "SemanticModel" ? .json(#"{"id":"m1","displayName":"Sales","type":"SemanticModel"}"#, status: 201)
                    : .json(#"{"id":"rep1","displayName":"Sales","type":"Report"}"#, status: 201)
            }
            if url.hasSuffix("/v1.0/myorg/groups/w1/reports") {
                return .json(#"{"value":[{"id":"rep1","name":"Sales","webUrl":"https://app.powerbi.com/groups/w1/reports/rep1"}]}"#)
            }
            return .json(#"{"error":{"code":"unexpected"}}"#, status: 500)
        }
        let outcome = try await publisher.publishDefinition(name: "Sales", workspace: workspace, modelParts: modelParts,
                                                            reportParts: reportParts, replaceExisting: false)
        XCTAssertEqual(outcome, PublishOutcome(semanticModelID: "m1", reportID: "rep1",
                                               reportURL: URL(string: "https://app.powerbi.com/groups/w1/reports/rep1"), replacedExisting: false))
        let posts = seen.value.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        let model = try JSONValue.parse(posts[0].body)
        XCTAssertEqual(model["type"]?.stringValue, "SemanticModel")
        XCTAssertEqual(model["displayName"]?.stringValue, "Sales")
        XCTAssertEqual(try parts(posts[0].body)["definition/model.tmdl"], "model Model")
        // The report goes up with a connection to the new model in place of the project's relative path.
        let report = try parts(posts[1].body)
        XCTAssertEqual(Set(report.keys), ["definition.pbir", "definition/report.json"])
        let pbir = try JSONValue.parse(Data(try XCTUnwrap(report["definition.pbir"]).utf8))
        XCTAssertNil(pbir["datasetReference"]?["byPath"])
        let connection = try XCTUnwrap(pbir["datasetReference"]?["byConnection"]?["connectionString"]?.stringValue)
        XCTAssertTrue(connection.hasSuffix("semanticmodelid=m1"), connection)
        XCTAssertTrue(connection.contains(#"Data Source="powerbi://api.powerbi.com/v1.0/myorg/Finance""#), connection)
    }

    func testItemsOfTheSameNameAreLeftAloneUnlessReplacing() async throws {
        stub { method, url, _ in
            if method == "GET", url.contains("type=SemanticModel") { return .json(#"{"value":[{"id":"m0","displayName":"sales","type":"SemanticModel"}]}"#) }
            if method == "GET", url.contains("type=Report") { return .json(#"{"value":[{"id":"r0","displayName":"Sales","type":"Report"}]}"#) }
            if method == "POST", url.hasSuffix("/updateDefinition") { return .json("{}") }
            if url.contains("/reports") { return .json(#"{"value":[]}"#) }
            return .json(#"{"error":{"code":"unexpected"}}"#, status: 500)
        }
        do {
            _ = try await publisher.publishDefinition(name: "Sales", workspace: workspace, modelParts: modelParts, reportParts: reportParts, replaceExisting: false)
            XCTFail("replaced without being asked")
        } catch let e as PublishError { XCTAssertEqual(e, .alreadyExists(name: "Sales", workspace: "Finance")) }
        XCTAssertTrue(seen.value.allSatisfy { $0.method == "GET" })

        seen.update { $0.removeAll() }
        let outcome = try await publisher.publishDefinition(name: "Sales", workspace: workspace, modelParts: modelParts, reportParts: reportParts, replaceExisting: true)
        XCTAssertTrue(outcome.replacedExisting)
        XCTAssertEqual(seen.value.filter { $0.method == "POST" }.map(\.url), [
            "https://api.fabric.microsoft.com/v1/workspaces/w1/items/m0/updateDefinition",
            "https://api.fabric.microsoft.com/v1/workspaces/w1/items/r0/updateDefinition",
        ])
        let updated = try parts(try XCTUnwrap(seen.value.last { $0.url.hasSuffix("r0/updateDefinition") }).body)
        XCTAssertTrue(updated["definition.pbir"]?.contains("semanticmodelid=m0") == true)
    }

    func testDefinitionsNeedAFabricWorkspaceAndContent() async throws {
        stub { _, _, _ in .json("{}", status: 500) }
        let personal = PublishWorkspace(id: PowerBIWorkspace.myWorkspace.id, name: "My workspace", isPersonal: true)
        do { _ = try await publisher.publishDefinition(name: "S", workspace: personal, modelParts: modelParts, reportParts: reportParts, replaceExisting: true); XCTFail() }
        catch let e as PublishError { XCTAssertEqual(e, .workspaceNotInFabric("My workspace")) }
        do { _ = try await publisher.publishDefinition(name: "S", workspace: workspace, modelParts: [], reportParts: reportParts, replaceExisting: true); XCTFail() }
        catch let e as PublishError { XCTAssertEqual(e, .emptyDefinition("semantic model")) }
        XCTAssertTrue(seen.value.isEmpty)
    }

    func testAPbixIsImportedAndFollowedUntilTheServiceFinishes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pub-\(UUID().uuidString).pbix")
        try Data("PK".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let polls = Recorder(0)
        stub { method, url, _ in
            if method == "POST", url.contains("/v1.0/myorg/groups/w1/imports?") { return .json(#"{"id":"imp1"}"#, status: 202) }
            if method == "GET", url.hasSuffix("/imports/imp1") {
                polls.update { $0 += 1 }
                return polls.value < 2 ? .json(#"{"id":"imp1","importState":"Publishing"}"#)
                    : .json(#"{"id":"imp1","importState":"Succeeded","reports":[{"id":"r9","webUrl":"https://app.powerbi.com/groups/w1/reports/r9"}],"datasets":[{"id":"d9"}]}"#)
            }
            return .json(#"{"error":{"code":"unexpected"}}"#, status: 500)
        }
        let outcome = try await publisher.publishFile(at: file, name: "Sales", workspace: workspace, replaceExisting: true, pollInterval: 0)
        XCTAssertEqual(outcome.reportID, "r9")
        XCTAssertEqual(outcome.semanticModelID, "d9")
        XCTAssertEqual(polls.value, 2)
        XCTAssertTrue(seen.value[0].url.contains("datasetDisplayName=Sales.pbix&nameConflict=CreateOrOverwrite"), seen.value[0].url)
        XCTAssertTrue(String(decoding: seen.value[0].body, as: UTF8.self).contains("filename=\"\(file.lastPathComponent)\""))
    }

    func testTheImportAPIIsNotSentFilesItCannotRead() async throws {
        stub { _, _, _ in .json("{}", status: 500) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pub-\(UUID().uuidString).facet")
        do { _ = try await publisher.publishFile(at: file, name: "S", workspace: workspace, replaceExisting: false); XCTFail() }
        catch let e as CloudAPIError { XCTAssertEqual(e.kind, .badRequest); XCTAssertTrue(e.message.contains(".pbix")) }
        XCTAssertTrue(seen.value.isEmpty)
    }

    func testReportBindingQuotesNames() throws {
        let data = PowerBIPublisher.reportBinding(workspaceName: "Sales \"EMEA\"", modelName: "Q;1", modelID: "abc", cloud: .usGovernment)
        let connection = try XCTUnwrap(try JSONValue.parse(data)["datasetReference"]?["byConnection"]?["connectionString"]?.stringValue)
        XCTAssertEqual(connection, #"Data Source="powerbi://api.high.powerbigov.us/v1.0/myorg/Sales ""EMEA""";Initial Catalog="Q;1";Integrated Security=ClaimsToken;semanticmodelid=abc"#)
    }
}
