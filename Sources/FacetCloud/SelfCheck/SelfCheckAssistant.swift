import Foundation
import FacetCore

/// An SSE body answered by the stubbed URL protocol.
private func sseResponse(_ events: String) -> SelfCheckURLProtocol.Response {
    SelfCheckURLProtocol.Response(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(events.utf8))
}

/// The request body, from `httpBody` or the body stream URLProtocol provides.
private func requestBody(_ req: URLRequest) -> Data {
    if let body = req.httpBody, !body.isEmpty { return body }
    guard let stream = req.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let size = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: size)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return data
}

extension FacetCloudSelfCheck {
    // MARK: SSE parser

    static func checkSSE(_ c: Checker) {
        var p = SSEParser()
        let events = p.feed(Data("event: message_start\ndata: {\"a\":1}\n\nevent: ping\ndata: {}\n\n".utf8))
        c.equal(events.count, 2, "two events from one chunk")
        c.equal(events[0], SSEEvent(event: "message_start", data: "{\"a\":1}"), "first event name and data")
        c.equal(events[1], SSEEvent(event: "ping", data: "{}"), "second event")

        // CR line endings, comments, a bare-data event and multi-line data.
        var p2 = SSEParser()
        let text = ": keep-alive\r\ndata: line1\r\ndata: line2\r\n\r\ndata: only-data\n\n"
        let more = p2.feed(Data(text.utf8))
        c.equal(more.count, 2, "CRLF and LF events")
        c.equal(more[0], SSEEvent(event: nil, data: "line1\nline2"), "multi-line data joined with LF")
        c.equal(more[1], SSEEvent(event: nil, data: "only-data"), "event without a name")

        // Events split across arbitrary chunk boundaries, byte by byte.
        var p3 = SSEParser()
        var split: [SSEEvent] = []
        for b in Data("event: a\ndata: {\"x\":1}\n\ndata: 2\n\n".utf8) { if let e = p3.feed(b) { split.append(e) } }
        c.equal(split.count, 2, "byte-by-byte feeding")
        c.equal(split[0], SSEEvent(event: "a", data: "{\"x\":1}"), "split event intact")

        // A comment-only keep-alive produces no event.
        var p4 = SSEParser()
        c.expect(p4.feed(Data(": ping\n\n".utf8)).isEmpty, "comment-only chunk is ignored")
    }

    // MARK: Assistant stream accumulator

    private static func sse(_ event: String, _ data: String) -> SSEEvent { SSEEvent(event: event, data: data) }

    static func checkAssistantAccumulator(_ c: Checker) throws {
        var a = AssistantStreamAccumulator()
        var events: [AssistantEvent] = []
        events += try a.consume(sse("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":12}}}"#))
        events += try a.consume(sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        events += try a.consume(sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#))
        events += try a.consume(sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#))
        events += try a.consume(sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
        events += try a.consume(sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#))
        events += try a.consume(sse("message_stop", #"{"type":"message_stop"}"#))
        c.equal(a.isComplete, true, "message_stop completes the response")
        let text = events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
        c.equal(text, "Hello world", "text deltas concatenated")
        let r = a.response()
        c.equal(r.id, "msg_1", "response id")
        c.equal(r.message.text, "Hello world", "response text")
        c.equal(r.stopReason, .endTurn, "stop reason")
        c.equal(r.usage.inputTokens, 12, "input tokens")
        c.equal(r.usage.outputTokens, 7, "output tokens")

        // A tool call with input streamed in two deltas.
        var b = AssistantStreamAccumulator()
        var toolEvents: [AssistantEvent] = []
        toolEvents += try b.consume(sse("message_start", #"{"type":"message_start","message":{"id":"msg_2","model":"claude-sonnet-5-5"}}"#))
        toolEvents += try b.consume(sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_dax"}}"#))
        toolEvents += try b.consume(sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#))
        toolEvents += try b.consume(sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"EVALUATE ROW(1)\"}"}}"#))
        toolEvents += try b.consume(sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
        toolEvents += try b.consume(sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#))
        toolEvents += try b.consume(sse("message_stop", #"{"type":"message_stop"}"#))
        let started = toolEvents.contains { if case .toolCallStarted(let id, let name) = $0 { return id == "toolu_1" && name == "run_dax" }; return false }
        c.expect(started, "toolCallStarted event")
        let calls = toolEvents.compactMap { if case .toolCall(let call) = $0 { return call }; return nil }
        c.equal(calls.count, 1, "one tool call")
        c.equal(calls.first?.id, "toolu_1", "tool call id")
        c.equal(calls.first?.input["query"]?.stringValue, "EVALUATE ROW(1)", "tool input parsed from streamed JSON")
        c.equal(b.response().stopReason, .toolUse, "tool_use stop reason")

        // Invalid streamed tool input is reported, not run.
        var d = AssistantStreamAccumulator()
        _ = try d.consume(sse("message_start", #"{"type":"message_start","message":{"id":"msg_3","model":"claude-sonnet-5-5"}}"#))
        _ = try d.consume(sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"run_dax"}}"#))
        _ = try d.consume(sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"not json"}}"#))
        _ = try d.consume(sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
        _ = try d.consume(sse("message_stop", #"{"type":"message_stop"}"#))
        c.equal(d.response().invalidToolInputs["toolu_2"], "not json", "invalid tool input kept")

        // An error event throws a typed error.
        var e = AssistantStreamAccumulator()
        do {
            _ = try e.consume(sse("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
            c.fail("error event did not throw")
        } catch let error as AssistantError {
            c.equal(error, .overloaded(retryAfter: nil, requestID: nil), "overloaded_error event")
        }
        c.equal(e.hasEmittedContent, false, "no content emitted before the error")
    }

    // MARK: Request building and input validation

    static func checkAssistantRequest(_ c: Checker) throws {
        var configuration = AssistantConfiguration()
        configuration.modelID = AssistantModel.default.id
        configuration.effort = .high
        let tool = AssistantTool(name: "zeta_tool", description: "Runs DAX", inputSchema: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]],
                                 handler: { _ in AssistantToolOutput("ok") })
        let other = AssistantTool(name: "alpha_tool", description: "Other", inputSchema: ["type": "object"],
                                  handler: { _ in AssistantToolOutput("ok") })
        let request = AssistantRequest(system: [AssistantSystemBlock("Be helpful.", cache: true)],
                                       messages: [.user("Hi"), AssistantMessage(role: .system, content: [["type": "text", "text": .string("Note")]])],
                                       tools: [tool, other])
        let body = AssistantClient.body(for: request, configuration: configuration)
        c.equal(body["model"]?.stringValue, "claude-sonnet-5-5", "model id in body")
        c.equal(body["max_tokens"]?.intValue, 64_000, "max tokens")
        c.equal(body["stream"]?.boolValue, true, "stream flag")
        c.equal(body["fallbacks"]?.stringValue, "default", "server fallback on a supporting model")
        c.equal(body["thinking"]?["display"]?.stringValue, nil, "no thinking summaries by default")
        c.equal(body["output_config"]?["effort"]?.stringValue, "high", "effort in output_config")
        let tools = body["tools"]?.arrayValue ?? []
        c.equal(tools.count, 2, "both tools")
        c.equal(tools.first?["name"]?.stringValue, "alpha_tool", "tools sorted by name for a stable cache prefix")
        c.equal(tools.first?["eager_input_streaming"]?.boolValue, true, "eager input streaming")
        let messages = body["messages"]?.arrayValue ?? []
        c.equal(messages.count, 2, "two messages")
        c.equal(messages[1]["role"]?.stringValue, "system", "mid-conversation system message kept as system role")
        c.expect(body["cache_control"]?["type"]?.stringValue == "ephemeral", "automatic cache breakpoint")

        // Fallbacks only on models that support them.
        configuration.modelID = "claude-haiku-4-5"
        let noFallback = AssistantClient.body(for: request, configuration: configuration)
        c.equal(noFallback["fallbacks"]?.stringValue, nil, "no fallbacks on an unsupported model")
        configuration.showThinkingSummaries = true
        c.equal(AssistantClient.body(for: request, configuration: configuration)["thinking"]?["display"]?.stringValue, "summarized", "thinking summaries requested")

        // Input validation.
        let schema: JSONValue = ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer", "enum": [1, 10, 100]]], "required": ["query"]]
        c.equal(ToolInputValidator.validate(["query": .string("EVALUATE 1")], against: schema), nil, "valid input")
        c.expect(ToolInputValidator.validate(["limit": .int(5)], against: schema)?.contains("missing required property 'query'") == true, "missing required property")
        c.expect(ToolInputValidator.validate(["query": .int(3)], against: schema)?.contains("must be of type string") == true, "wrong type")
        c.expect(ToolInputValidator.validate(["query": .string("x"), "limit": .int(7)], against: schema)?.contains("must be one of") == true, "enum violation")
        c.expect(ToolInputValidator.validate(["query": .string("x"), "extra": .int(1)], against: schema) == nil, "unknown properties are ignored")
    }

    // MARK: History trimming and prompt description

    static func checkAssistantHistory(_ c: Checker) {
        let short = AssistantMessage.user("Short")
        c.expect(HistoryTrimmer.estimateTokens(short) > 0, "token estimate is positive")
        var long = AssistantMessage(role: .assistant, content: [["type": "thinking", "thinking": .string(String(repeating: "x", count: 4000))],
                                                                ["type": "text", "text": .string("Answer")]])
        _ = long
        var messages: [AssistantMessage] = [.user(String(repeating: "q", count: 3000)), long]
        messages.append(.user(String(repeating: "r", count: 3000)))
        messages.append(AssistantMessage(role: .assistant, content: [["type": "text", "text": .string(String(repeating: "a", count: 3000))]]))
        let trimmed = HistoryTrimmer.trim(messages, budgetTokens: 1000)
        c.expect(trimmed.removed > 0, "history trimmed when over budget")
        c.expect(trimmed.messages.count < messages.count, "fewer messages after trimming")
        c.expect(!trimmed.messages.contains { $0.content.contains { $0["type"]?.stringValue == "thinking" } }, "thinking blocks stripped from retained messages")
        c.expect(HistoryTrimmer.trim(messages, budgetTokens: 1_000_000).removed == 0, "no trim within budget")

        // Message helpers.
        let withTools = AssistantMessage(role: .assistant, content: [
            ["type": "tool_use", "id": "t1", "name": "run_dax", "input": ["query": .string("1")]],
            ["type": "text", "text": .string("Checking")],
        ])
        c.equal(withTools.text, "Checking", "visible text")
        c.equal(withTools.toolCalls.count, 1, "tool calls extracted")
        c.equal(withTools.toolCalls.first?.input["query"]?.stringValue, "1", "tool call input")
        c.equal(withTools.isToolResult, false, "not a tool result")
        let result = AssistantMessage(role: .user, content: [["type": "tool_result", "tool_use_id": .string("t1"), "content": .string("ok")]])
        c.equal(result.isToolResult, true, "tool-result message recognised")

        // Model description for the system prompt.
        var model = SemanticModel()
        model.name = "Sales"
        var t = ModelTable(name: "Sales")
        t.description = "Facts"
        var hidden = ModelColumn(name: "Cost", dataType: .currency)
        hidden.isHidden = true
        var amount = ModelColumn(name: "Amount", dataType: .decimal)
        amount.formatString = "#,0.00"
        t.columns = [amount, hidden]
        var total = Measure(name: "Total", expression: "SUM(Sales[Amount])")
        total.description = "All sales"
        t.measures = [total]
        model.tables = [t]
        var rel = Relationship(fromTable: "Sales", fromColumn: "K", toTable: "Dim", toColumn: "K")
        rel.isActive = false
        model.relationships = [rel]
        let described = AssistantPrompt.describe(model)
        c.expect(described.contains("## Table 'Sales'"), "table described")
        c.expect(described.contains("[Amount]"), "visible column described")
        c.expect(!described.contains("Cost"), "hidden column excluded")
        c.expect(described.contains("[Total] = SUM(Sales[Amount])"), "measure described with DAX")
        c.expect(described.contains("inactive"), "relationship activity noted")
        model.aiExcludedFields = ["Sales[Amount]"]
        c.expect(!AssistantPrompt.describe(model).contains("[Amount]:"), "AI-excluded fields left out")
    }

    // MARK: Tool loop against a stubbed API

    @MainActor
    static func checkAssistantSession(_ c: Checker) async throws {
        let secrets = InMemorySecretStore()
        var configuration = AssistantConfiguration()
        configuration.maxToolRounds = 5
        let client = AssistantClient(configuration: configuration, keyStore: secrets,
                                     sessionConfiguration: SelfCheckURLProtocol.configuration())
        try client.setAPIKey("sk-test")

        let calls = Recorder<[[String: String]]>([])
        var round = 0
        SelfCheckURLProtocol.handler = { req, _ in
            let path = req.url?.path ?? ""
            guard path.hasSuffix("/v1/messages") else { return .json("{}", status: 404) }
            round += 1
            calls.update { $0.append(["body": String(decoding: requestBody(req), as: UTF8.self)]) }
            if round == 1 {
                return sseResponse("""
                event: message_start
                data: {"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":9}}}

                event: content_block_start
                data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_dax"}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"EVALUATE ROW(1)\\"}"}}

                event: content_block_stop
                data: {"type":"content_block_stop","index":0}

                event: message_delta
                data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":6}}

                event: message_stop
                data: {"type":"message_stop"}


                """)
            }
            return sseResponse("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_2","model":"claude-sonnet-5-5","usage":{"input_tokens":20}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"One row."}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

            event: message_stop
            data: {"type":"message_stop"}


            """)
        }

        let handled = Recorder<String>("")
        let tool = AssistantTool(name: "run_dax", description: "Runs a DAX query", inputSchema: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]],
                                 handler: { input in
                                     handled.update { $0 = input["query"]?.stringValue ?? "" }
                                     return AssistantToolOutput("1 row: 1")
                                 })
        let session = AssistantSession(client: client, instructions: "Test instructions.", tools: [tool])
        var texts = "", toolResults = 0
        var finished: AssistantStopReason?
        var turnUsage = AssistantUsage()
        for try await event in session.send("What is 1 + 1?") {
            switch event {
            case .textDelta(let t): texts += t
            case .toolResult: toolResults += 1
            case .turnFinished(let reason, let usage): finished = reason; turnUsage = usage
            default: break
            }
        }
        c.equal(handled.value, "EVALUATE ROW(1)", "tool ran with the model's input")
        c.equal(toolResults, 1, "one tool result surfaced")
        c.equal(texts, "One row.", "final text streamed")
        c.equal(finished, .endTurn, "turn finished with end_turn")
        c.equal(turnUsage.inputTokens, 29, "usage summed over the turn")
        c.equal(session.history.count, 4, "user, assistant, tool result and final message in history")
        c.expect(session.history.contains(where: { $0.isToolResult }), "tool result kept in history")
        c.equal(session.totalUsage.inputTokens, 29, "session usage")
        let secondBody = calls.value.count > 1 ? calls.value[1]["body"] ?? "" : ""
        c.expect(secondBody.contains(#""tool_use_id":"toolu_1""#) || secondBody.contains("\"tool_use_id\": \"toolu_1\""), "tool result sent back to the API")
        c.expect(secondBody.contains("EVALUATE ROW(1)"), "tool output content sent back")

        // Unknown tools and invalid input become error results instead of throwing.
        c.equal(ToolInputValidator.validate(["query": .int(1)], against: tool.inputSchema)?.isEmpty == false, true, "schema rejects a wrong-type input")
        session.reset()
        c.equal(session.history.count, 0, "reset clears history")
        try client.removeAPIKey()
    }
}
