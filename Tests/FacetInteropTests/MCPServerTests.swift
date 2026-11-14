import XCTest
import FacetCore
@testable import FacetInterop

final class MCPServerTests: XCTestCase {
    private func dispatcher() -> MCPDispatcher {
        MCPDispatcher(serverName: "Analytics Desktop", serverVersion: "1.0") {
            [MCPTool(name: "echo", description: "Echoes its text.",
                     inputSchema: .object(["type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])])])) { args in
                guard let text = args["text"]?.stringValue else { throw InteropError.invalidFormat("text is required") }
                return "you said " + text
            }]
        }
    }

    private func rpc(_ text: String) async throws -> JSONValue? {
        await dispatcher().handle(try JSONValue.parse(text))
    }

    // MARK: Protocol

    func testInitializeListAndCall() async throws {
        let initialized = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(initialized?["result"]?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(initialized?["result"]?["serverInfo"]?["name"]?.stringValue, "Analytics Desktop")
        XCTAssertEqual(initialized?["id"]?.intValue, 1)
        // An unknown version is answered with the newest one the server speaks.
        let other = try await rpc(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(other?["result"]?["protocolVersion"]?.stringValue, "2025-06-18")

        let list = try await rpc(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        XCTAssertEqual(list?["result"]?["tools"]?.arrayValue?.count, 1)
        XCTAssertEqual(list?["result"]?["tools"]?[0]?["name"]?.stringValue, "echo")
        XCTAssertEqual(list?["id"]?.stringValue, "a")

        let call = try await rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        XCTAssertEqual(call?["result"]?["content"]?[0]?["text"]?.stringValue, "you said hi")
        XCTAssertEqual(call?["result"]?["isError"]?.boolValue, false)

        // A failing tool is a tool result with isError, not a protocol error.
        let failed = try await rpc(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        XCTAssertEqual(failed?["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(failed?["result"]?["content"]?[0]?["text"]?.stringValue, "text is required")
    }

    func testErrorsAndNotifications() async throws {
        let unknownTool = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rm"}}"#)
        XCTAssertEqual(unknownTool?["error"]?["code"]?.intValue, -32602)
        let unknownMethod = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        XCTAssertEqual(unknownMethod?["error"]?["code"]?.intValue, -32601)
        let invalid = try await rpc(#"{"id":1,"method":"ping"}"#)
        XCTAssertEqual(invalid?["error"]?["code"]?.intValue, -32600)
        let notification = try await rpc(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification, "notifications are never answered")
        let batch = try await rpc(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
        XCTAssertEqual(batch?.arrayValue?.count, 1)
    }

    // MARK: Request checks

    func testRequestHeadEvaluation() {
        let token = "tok-123"
        func eval(_ lines: [String]) -> MCPServer.Evaluation {
            MCPServer.evaluate(head: lines.joined(separator: "\r\n"), port: 5000, token: token)
        }
        func status(_ e: MCPServer.Evaluation) -> String {
            if case .reject(let s, _, _) = e { return String(s.prefix(3)) }
            return "ok"
        }
        let good = ["POST /mcp HTTP/1.1", "Host: 127.0.0.1:5000", "Authorization: Bearer tok-123", "Content-Type: application/json", "Content-Length: 12"]
        XCTAssertEqual(eval(good), .accept(contentLength: 12))
        XCTAssertEqual(status(eval(good + ["Origin: http://localhost:3000"])), "ok")

        func replacing(_ prefix: String, with line: String?) -> [String] {
            good.filter { !$0.hasPrefix(prefix) } + (line.map { [$0] } ?? [])
        }
        XCTAssertEqual(status(eval(replacing("Authorization", with: nil))), "401")
        XCTAssertEqual(status(eval(replacing("Authorization", with: "Authorization: Bearer tok-124"))), "401")
        XCTAssertEqual(status(eval(replacing("Authorization", with: "Authorization: Bearer "))), "401")
        XCTAssertEqual(status(eval(replacing("Authorization", with: "Authorization: Basic tok-123"))), "401")
        // DNS rebinding: the browser sends the attacker's host name.
        XCTAssertEqual(status(eval(replacing("Host", with: "Host: evil.example:5000"))), "403")
        XCTAssertEqual(status(eval(replacing("Host", with: "Host: 127.0.0.1:5001"))), "403")
        XCTAssertEqual(status(eval(replacing("Host", with: nil))), "403")
        // A web page calling the server.
        XCTAssertEqual(status(eval(good + ["Origin: https://evil.example"])), "403")
        XCTAssertEqual(status(eval(good + ["Origin: null"])), "403")
        XCTAssertEqual(status(eval(["GET /mcp HTTP/1.1"] + good.dropFirst())), "405")
        XCTAssertEqual(status(eval(["POST /other HTTP/1.1"] + good.dropFirst())), "404")
        XCTAssertEqual(status(eval(replacing("Content-Length", with: "Content-Length: \(MCPServer.maxBodyBytes + 1)"))), "413")
        XCTAssertEqual(status(eval(replacing("Content-Length", with: nil))), "411")
        XCTAssertEqual(status(eval(replacing("Content-Length", with: "Content-Length: -5"))), "411")
        XCTAssertEqual(status(eval(good + ["Transfer-Encoding: chunked"])), "411")
        XCTAssertEqual(status(eval(replacing("Content-Type", with: "Content-Type: text/plain"))), "415")
        XCTAssertEqual(status(eval(good + ["Authorization: Bearer tok-123"])), "400", "a repeated credential header is refused")
        XCTAssertEqual(status(eval(["garbage"])), "400")
        // Without a session token nothing is ever accepted.
        XCTAssertEqual(String(describing: MCPServer.evaluate(head: good.joined(separator: "\r\n"), port: 5000, token: "")).contains("401"), true)
        // A caller without the token learns nothing about paths or methods.
        XCTAssertEqual(status(eval(["GET /secret HTTP/1.1", "Host: 127.0.0.1:5000"])), "401")
    }

    // MARK: Over a real loopback socket

    private func post(_ server: MCPServer, body: String, token: String?, host: String? = nil) async throws -> (Int, String) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: server.endpoint)))
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testServesOnLoopbackWithAPerSessionToken() async throws {
        let server = MCPServer(dispatcher: dispatcher())
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(server.token, "")
        let port = try await server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(port, 1023)
        XCTAssertEqual(server.endpoint, "http://127.0.0.1:\(port)/mcp")
        let token = server.token
        XCTAssertEqual(token.count, 43, "32 random bytes, base64url")

        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":{"text":"socket"}}}"#
        let (ok, body) = try await post(server, body: call, token: token)
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(try JSONValue.parse(body)["result"]?["content"]?[0]?["text"]?.stringValue, "you said socket")

        let (unauthorized, leaked) = try await post(server, body: call, token: nil)
        XCTAssertEqual(unauthorized, 401)
        XCTAssertFalse(leaked.contains("you said"))
        let (wrong, _) = try await post(server, body: call, token: token + "x")
        XCTAssertEqual(wrong, 401)
        let (notification, empty) = try await post(server, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, token: token)
        XCTAssertEqual(notification, 202)
        XCTAssertEqual(empty, "")
        let (parse, _) = try await post(server, body: "{not json", token: token)
        XCTAssertEqual(parse, 400)

        // Restarting issues a new token; the old one stops working.
        try await server.start()
        XCTAssertNotEqual(server.token, token)
        let (stale, _) = try await post(server, body: call, token: token)
        XCTAssertEqual(stale, 401)

        // Stopped: the token is forgotten and the port is closed.
        let endpoint = server.endpoint
        server.stop()
        XCTAssertEqual(server.token, "")
        var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        do { _ = try await URLSession(configuration: .ephemeral).data(for: request); XCTFail("the server still answers after stop()") }
        catch { XCTAssertTrue(error is URLError) }
    }

    func testDoesNotListenOnIPv6OrOtherInterfaces() async throws {
        let server = MCPServer(dispatcher: dispatcher())
        let port = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://[::1]:\(port)/mcp")))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        do { _ = try await URLSession(configuration: .ephemeral).data(for: request); XCTFail("reachable over ::1") }
        catch { XCTAssertTrue(error is URLError) }
    }
}
