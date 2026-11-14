import XCTest
@testable import FacetCloud

/// One-shot completions (`AssistantClient.complete`): the whole answer comes back as text; a declined or
/// truncated answer is an error, never a result; nothing is sent without a key. Answered in-process.
final class AssistantCompletionTests: XCTestCase {
    override func tearDown() {
        SelfCheckURLProtocol.handler = nil
    }

    private func stream(text: String, stop: String, details: String = "null") -> String {
        """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":20}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\(JSONValue.string(text).serialized())}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"\(stop)","stop_details":\(details)},"usage":{"output_tokens":4}}

        event: message_stop
        data: {"type":"message_stop"}


        """
    }

    private func client(key: String? = "sk-ant-test") -> AssistantClient {
        let keys = InMemorySecretStore()
        if let key { try? keys.setString(key, account: "anthropic-api-key") }
        let c = AssistantClient(configuration: AssistantConfiguration(), keyStore: keys, sessionConfiguration: SelfCheckURLProtocol.configuration())
        c.maxRetries = 0
        return c
    }

    private final class Box: @unchecked Sendable { var bodies: [JSONValue] = [] }

    private func answer(_ sse: String) -> Box {
        let box = Box()
        SelfCheckURLProtocol.handler = { _, body in
            box.bodies.append((try? JSONValue.parse(body)) ?? .null)
            return SelfCheckURLProtocol.Response(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(sse.utf8))
        }
        return box
    }

    func testCompleteReturnsTheTrimmedTextAndSendsContextAsACachedSystemBlock() async throws {
        let box = answer(stream(text: "  Total sales by region.\n", stop: "end_turn"))
        let result = try await client().complete(instructions: "Be brief.", context: "Model: Sales", prompt: "Explain")
        XCTAssertEqual(result.text, "Total sales by region.")
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(result.usage.outputTokens, 4)

        let body = try XCTUnwrap(box.bodies.first)
        let system = body["system"]?.arrayValue ?? []
        XCTAssertEqual(system.map { $0["text"]?.stringValue }, ["Be brief.", "Model: Sales"])
        XCTAssertNil(system[0]["cache_control"], "the breakpoint sits on the last stable block only")
        XCTAssertEqual(system[1]["cache_control"]?["type"]?.stringValue, "ephemeral")
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["stream"]?.boolValue, true, "one-shot answers still stream")
    }

    func testDeclinedAnswerThrowsWithTheExplanation() async {
        _ = answer(stream(text: "", stop: "refusal", details: #"{"type":"refusal","category":"cyber","explanation":"Not something I can help with."}"#))
        do {
            _ = try await client().complete(instructions: "x", prompt: "y")
            XCTFail("a refusal is not an answer")
        } catch {
            XCTAssertEqual(error as? AssistantError, .declined("Not something I can help with."))
            XCTAssertEqual((error as? AssistantError)?.errorDescription, "The assistant declined this request. Not something I can help with.")
        }
    }

    func testTruncatedOrEmptyAnswersAreErrors() async {
        _ = answer(stream(text: "EVALUATE SUMMARIZECOLUMNS(", stop: "max_tokens"))
        do { _ = try await client().complete(instructions: "x", prompt: "y"); XCTFail("cut-off text must not be used") }
        catch { guard case .invalidResponse? = error as? AssistantError else { return XCTFail("\(error)") } }

        _ = answer(stream(text: "   ", stop: "end_turn"))
        do { _ = try await client().complete(instructions: "x", prompt: "y"); XCTFail("an empty answer is not a result") }
        catch { guard case .invalidResponse? = error as? AssistantError else { return XCTFail("\(error)") } }
    }

    func testWithoutAKeyNothingIsSent() async {
        let box = answer(stream(text: "unused", stop: "end_turn"))
        do {
            _ = try await client(key: nil).complete(instructions: "x", prompt: "y")
            XCTFail("no key, no request")
        } catch {
            XCTAssertEqual(error as? AssistantError, .notConfigured)
        }
        XCTAssertTrue(box.bodies.isEmpty)
    }
}
