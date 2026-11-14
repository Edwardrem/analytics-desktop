import XCTest
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Paginated report, Power Apps, Metrics and Power Automate visuals: an ID or https address in
/// Format › Source, turned into the service's address; a flow's button posts the visual's rows.
@MainActor
final class EmbedSetupTests: XCTestCase {
    private let id = "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
    private let ws = "0f0e0d0c-0b0a-0908-0706-050403020100"

    private func address(_ type: VisualType, _ entry: String, workspace: String = "") -> String? {
        if case .success(let url) = EmbedSetup.url(for: type, entry: entry, workspace: workspace) { return url.absoluteString }
        return nil
    }
    private func problem(_ type: VisualType, _ entry: String, workspace: String = "") -> EmbedSetup.Problem? {
        if case .failure(let p) = EmbedSetup.url(for: type, entry: entry, workspace: workspace) { return p }
        return nil
    }

    func testIDsBecomeTheServicesAddresses() {
        XCTAssertEqual(address(.paginatedReport, id),
                       "https://app.powerbi.com/rdlEmbed?reportId=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d&autoAuth=true")
        XCTAssertEqual(address(.powerApps, "  \(id)\n"),
                       "https://apps.powerapps.com/play/1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d?source=iframe")
        XCTAssertEqual(address(.metrics, id, workspace: ws),
                       "https://app.powerbi.com/groups/0f0e0d0c-0b0a-0908-0706-050403020100/scorecards/1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d")
        // A scorecard ID alone is not enough; a flow is never called by an ID.
        if case .missing(let m)? = problem(.metrics, id) { XCTAssertTrue(m.contains("workspace ID")) } else { XCTFail("metrics needs a workspace") }
        if case .unrecognised? = problem(.powerAutomate, id) {} else { XCTFail("a flow needs its URL") }
    }

    func testAddressesMustBeHTTPS() {
        let flow = "https://prod-01.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?api-version=2016-06-01&sig=xyz"
        XCTAssertEqual(address(.powerAutomate, flow), flow)
        XCTAssertEqual(address(.paginatedReport, "https://reports.contoso.com/reports/powerbi/Sales"), "https://reports.contoso.com/reports/powerbi/Sales")
        for bad in ["http://app.powerbi.com/x", "javascript:alert(1)", "file:///etc/passwd", "https://"] {
            XCTAssertEqual(problem(.powerApps, bad), .notHTTPS, bad)
        }
        if case .missing? = problem(.paginatedReport, "   ") {} else { XCTFail("an empty entry asks for one") }
        if case .unrecognised? = problem(.paginatedReport, "my report") {} else { XCTFail("text that is no ID or address") }
        XCTAssertNil(EmbedAddress.httpsURL(from: "http://example.com"))
        XCTAssertEqual(EmbedAddress.httpsURL(from: " https://example.com/a ")?.absoluteString, "https://example.com/a")
    }

    func testTheSourceCardIsForEmbeddedVisualsOnly() throws {
        let frame = Frame(x: 0, y: 0, width: 300, height: 200)
        for type in EmbedSetup.types {
            let cards = FormatCatalog.cards(for: [VisualSpec(type: type, frame: frame)], tab: .visual)
            XCTAssertEqual(cards.first?.role, .embed, type.displayName)
            XCTAssertEqual(cards.first?.properties.first?.label, EmbedSetup.entryLabel(type))
        }
        XCTAssertFalse(FormatCatalog.cards(for: [ReportFixture.chart()], tab: .visual).contains { $0.role == .embed })
        // Two embedded visuals share format cards only.
        let two = [VisualSpec(type: .powerApps, frame: frame), VisualSpec(type: .powerApps, frame: frame)]
        XCTAssertFalse(FormatCatalog.cards(for: two, tab: .visual).contains { $0.role == .embed })

        var spec = VisualSpec(type: .metrics, frame: frame)
        let card = try XCTUnwrap(FormatCatalog.embedCard(for: .metrics))
        XCTAssertFalse(FormatCatalog.isOverridden(card, in: spec))
        spec.content = "https://app.powerbi.com/groups/x/scorecards/y"
        XCTAssertTrue(FormatCatalog.isOverridden(card, in: spec))
    }

    func testTheCanvasOffersSetUpAndRunningFlows() {
        let store = ReportFixture.store()
        let flow = VisualSpec(type: .powerAutomate, frame: Frame(x: 0, y: 0, width: 200, height: 80))
        XCTAssertNotNil(store.context(for: flow).onSetUp)
        XCTAssertNotNil(store.context(for: flow).onRunFlow)
        XCTAssertNil(store.context(for: flow, interactive: false).onSetUp)
        XCTAssertNil(store.context(for: flow, interactive: false).onRunFlow)
        let report = VisualSpec(type: .paginatedReport, frame: Frame(x: 0, y: 0, width: 200, height: 80))
        XCTAssertNotNil(store.context(for: report).onSetUp)
        XCTAssertNil(store.context(for: report).onRunFlow)
        XCTAssertNil(store.context(for: ReportFixture.chart()).onSetUp)
    }

    func testFlowRequestPostsTheRowsWithCaptions() throws {
        let data = ReportFixture.engine().visualData(spec: ReportFixture.chart(), request: VisualRequest())
        let url = try XCTUnwrap(URL(string: "https://flow.test/invoke?sig=abc"))
        let request = EmbedSetup.flowRequest(url: url, data: data)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [[String: Any]])
        // North 10 + 20, South 30 + 40, East 50.
        let byRegion = Dictionary(uniqueKeysWithValues: rows.compactMap { r in (r["Region"] as? String).map { ($0, r["Sum of Amount"] as? Int) } })
        XCTAssertEqual(byRegion, ["North": 30, "South": 70, "East": 50])
    }

    func testFlowOutcomesSayWhatHappened() {
        XCTAssertEqual(EmbedSetup.flowResult(status: 202, error: nil, rows: 3, name: "Flow").kind, .success)
        XCTAssertEqual(EmbedSetup.flowResult(status: 202, error: nil, rows: 1, name: "Flow").text, "Started the flow for “Flow” with 1 row.")
        let denied = EmbedSetup.flowResult(status: 401, error: nil, rows: 3, name: "Flow")
        XCTAssertEqual(denied.kind, .warning)
        XCTAssertTrue(denied.text.contains("signature"))
        XCTAssertTrue(EmbedSetup.flowResult(status: 500, error: nil, rows: 3, name: "Flow").text.contains("HTTP 500"))
        let offline = EmbedSetup.flowResult(status: nil, error: URLError(.notConnectedToInternet), rows: 3, name: "Flow")
        XCTAssertEqual(offline.kind, .error)
    }

    func testRunningAFlowPostsTheVisualsDataAndReports() async throws {
        URLProtocol.registerClass(FlowStub.self)
        defer { URLProtocol.unregisterClass(FlowStub.self) }
        FlowStub.received = nil
        let store = ReportFixture.store()
        var flow = VisualSpec(type: .powerAutomate, frame: Frame(x: 0, y: 0, width: 200, height: 80))
        flow.setFields(.values, [ReportFixture.region, ReportFixture.amount])
        flow.content = "https://flow.test/invoke?sig=abc"
        store.mutate("Add", invalidates: .model) { $0.report.pages[0].visuals = [flow] }
        for _ in 0..<200 where store.visualData[flow.id]?.table.rowCount != 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        store.runFlow(flow)
        for _ in 0..<200 where store.status?.kind != .success {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.status?.text, "Started the flow for “\(flow.name)” with 3 rows.")
        let body = try XCTUnwrap(FlowStub.received)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["Region"] as? String }), ["North", "South", "East"])

        // No address: nothing is sent and the author is told what to set.
        var empty = flow
        empty.content = "http://flow.test/insecure"
        FlowStub.received = nil
        store.runFlow(empty)
        XCTAssertEqual(store.status?.kind, .warning)
        XCTAssertNil(FlowStub.received)
    }
}

/// Answers requests to flow.test with 202 Accepted and keeps the body it was sent.
final class FlowStub: URLProtocol {
    static var received: Data?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "flow.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.received = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}
