import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
}

/// Incremental Server-Sent Events parser (WHATWG event-stream format): handles LF, CR and CRLF line endings,
/// comment lines, multi-line `data:` fields, and events split across arbitrary chunk boundaries.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastWasCR = false

    public init() {}

    /// Feeds one byte; returns an event when a blank line completes one.
    public mutating func feed(_ byte: UInt8) -> SSEEvent? {
        if byte == 0x0A {
            if lastWasCR { lastWasCR = false; return nil } // LF of a CRLF pair
            return endLine()
        }
        lastWasCR = byte == 0x0D
        if byte == 0x0D { return endLine() }
        line.append(byte)
        return nil
    }

    public mutating func feed(_ data: Data) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in data { if let e = feed(b) { out.append(e) } }
        return out
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { eventName = nil; dataLines.removeAll() }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        }
        if line[0] == UInt8(ascii: ":") { return nil } // comment / keep-alive
        let text = String(decoding: line, as: UTF8.self)
        let field: String
        var value: String
        if let colon = text.firstIndex(of: ":") {
            field = String(text[..<colon])
            value = String(text[text.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = text
            value = ""
        }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break // id / retry are not used by this API
        }
        return nil
    }
}

/// Folds the Messages API streaming events into UI events and the final response.
///
/// Content blocks are kept as raw JSON so unknown block types and thinking signatures survive unchanged.
struct AssistantStreamAccumulator {
    private var blocks: [Int: JSONValue] = [:]
    private var partialJSON: [Int: String] = [:]
    private var id: String?
    private var model: String?
    private var stopReason: String?
    private var stopDetails: JSONValue?
    private var usage = AssistantUsage()
    private var invalidToolInputs: [String: String] = [:]
    private(set) var isComplete = false
    /// True once any content has been surfaced (after which a request must not be transparently retried).
    private(set) var hasEmittedContent = false

    /// Consumes one SSE event. Throws `AssistantError` for `error` events and malformed data.
    mutating func consume(_ sse: SSEEvent) throws -> [AssistantEvent] {
        let json: JSONValue
        do { json = try JSONValue.parse(sse.data) }
        catch { throw AssistantError.invalidResponse("a stream event was not valid JSON") }
        let type = json["type"]?.stringValue ?? sse.event ?? ""
        switch type {
        case "message_start":
            let m = json["message"]
            id = m?["id"]?.stringValue
            model = m?["model"]?.stringValue
            usage.merge(m?["usage"])
            return []
        case "content_block_start":
            guard let index = json["index"]?.intValue.map(Int.init), let block = json["content_block"] else { return [] }
            blocks[index] = block
            hasEmittedContent = true
            let kind = block["type"]?.stringValue
            if kind == "tool_use" || kind == "server_tool_use" { partialJSON[index] = "" }
            if kind == "tool_use", let id = block["id"]?.stringValue, let name = block["name"]?.stringValue {
                return [.toolCallStarted(id: id, name: name)]
            }
            if kind == "text", let t = block["text"]?.stringValue, !t.isEmpty { return [.textDelta(t)] }
            return []
        case "content_block_delta":
            guard let index = json["index"]?.intValue.map(Int.init), let delta = json["delta"], let block = blocks[index] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let t = delta["text"]?.stringValue ?? ""
                blocks[index] = block.setting("text", to: .string((block["text"]?.stringValue ?? "") + t))
                return t.isEmpty ? [] : [.textDelta(t)]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
                return []
            case "thinking_delta":
                let t = delta["thinking"]?.stringValue ?? ""
                blocks[index] = block.setting("thinking", to: .string((block["thinking"]?.stringValue ?? "") + t))
                return t.isEmpty ? [] : [.thinkingDelta(t)]
            case "signature_delta":
                blocks[index] = block.setting("signature", to: .string((block["signature"]?.stringValue ?? "") + (delta["signature"]?.stringValue ?? "")))
                return []
            case "citations_delta":
                if let c = delta["citation"] {
                    blocks[index] = block.setting("citations", to: .array((block["citations"]?.arrayValue ?? []) + [c]))
                }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let index = json["index"]?.intValue.map(Int.init), let block = blocks[index], let raw = partialJSON[index] else { return [] }
            partialJSON[index] = nil
            // Strict parse: with eager input streaming the server does not validate tool input.
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                blocks[index] = block.setting("input", to: [:])
            } else if let parsed = try? JSONValue.parse(text), parsed.members != nil {
                blocks[index] = block.setting("input", to: parsed)
            } else {
                blocks[index] = block.setting("input", to: [:])
                if let id = block["id"]?.stringValue { invalidToolInputs[id] = raw }
                return []
            }
            guard block["type"]?.stringValue == "tool_use", let b = blocks[index], let id = b["id"]?.stringValue,
                  let name = b["name"]?.stringValue else { return [] }
            return [.toolCall(AssistantToolCall(id: id, name: name, input: b["input"] ?? [:]))]
        case "message_delta":
            if let r = json["delta"]?["stop_reason"]?.stringValue { stopReason = r }
            if let d = json["delta"]?["stop_details"], !d.isNull { stopDetails = d }
            usage.merge(json["usage"])
            return []
        case "message_stop":
            isComplete = true
            return []
        case "error":
            let e = json["error"]
            throw AssistantError.classify(status: 500, type: e?["type"]?.stringValue ?? "api_error",
                                          message: e?["message"]?.stringValue ?? "The stream reported an error.",
                                          requestID: json["request_id"]?.stringValue, retryAfter: nil)
        default:
            return [] // ping and future event types
        }
    }

    /// The assembled response. Call after `message_stop`.
    func response() -> AssistantResponse {
        let content = blocks.keys.sorted().compactMap { blocks[$0] }
        return AssistantResponse(id: id, model: model, message: AssistantMessage(role: .assistant, content: content),
                                 stopReason: AssistantStopReason(stopReason),
                                 refusalCategory: stopDetails?["category"]?.stringValue,
                                 refusalExplanation: stopDetails?["explanation"]?.stringValue,
                                 usage: usage, invalidToolInputs: invalidToolInputs)
    }
}

/// Minimal JSON Schema validation for tool inputs (type, required, properties, items, enum).
/// Unsupported keywords are ignored rather than rejected.
enum ToolInputValidator {
    /// Returns a description of the first problem, or `nil` when the value conforms.
    static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "input") -> String? {
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(where: { matches($0, value) }) {
            return "\(path) must be one of \(allowed.map { $0.serialized() }.joined(separator: ", "))"
        }
        let types: [String]
        if let t = schema["type"]?.stringValue { types = [t] }
        else { types = (schema["type"]?.arrayValue ?? []).compactMap(\.stringValue) }
        if !types.isEmpty, !types.contains(where: { isType($0, value) }) {
            return "\(path) must be of type \(types.joined(separator: " or "))"
        }
        switch value {
        case .object(let members):
            for req in schema["required"]?.arrayValue ?? [] {
                if let key = req.stringValue, !members.contains(where: { $0.key == key }) { return "\(path) is missing required property '\(key)'" }
            }
            if let props = schema["properties"] {
                for m in members {
                    if let sub = props[m.key] {
                        if let problem = validate(m.value, against: sub, path: "\(path).\(m.key)") { return problem }
                    } else if schema["additionalProperties"]?.boolValue == false {
                        return "\(path) has unexpected property '\(m.key)'"
                    }
                }
            }
        case .array(let items):
            if let itemSchema = schema["items"], itemSchema.members != nil {
                for (i, item) in items.enumerated() {
                    if let problem = validate(item, against: itemSchema, path: "\(path)[\(i)]") { return problem }
                }
            }
        default: break
        }
        return nil
    }

    private static func matches(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.doubleValue, let y = b.doubleValue { return x == y }
        return a == b
    }

    private static func isType(_ type: String, _ v: JSONValue) -> Bool {
        switch (type, v) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): return true
        case ("number", .int), ("number", .double), ("integer", .int): return true
        case ("integer", .double(let d)): return d == d.rounded()
        default: return false
        }
    }
}
