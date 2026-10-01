import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgentCLI

// These replies use the OAuth metadata and token shapes from PiSwift's MCP fixtures.
private actor T3bLoginHTTP: McpOAuthHTTPClient {
    let origin = "http://127.0.0.1:45454"
    private(set) var tokenRequests = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body: [String: Any]
        if path.hasPrefix("/.well-known/oauth-protected-resource") {
            body = ["resource": origin + "/mcp", "authorization_servers": [origin]]
        } else if path == "/.well-known/oauth-authorization-server" {
            body = ["issuer": origin, "authorization_endpoint": origin + "/authorize",
                    "token_endpoint": origin + "/token", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code"],
                    "token_endpoint_auth_methods_supported": ["none"],
                    "code_challenge_methods_supported": ["S256"]]
        } else if path == "/token" {
            tokenRequests += 1
            body = ["access_token": "fixture-token", "token_type": "Bearer", "expires_in": 3600]
        } else {
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!,
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

private struct T3bLoginPresenter: McpSignInPresenter {
    let open: @Sendable (URL) async throws -> Void

    func redirectURL(for state: String) async throws -> URL {
        URL(string: "http://127.0.0.1:6000/callback")!
    }

    func present(authorizationURL: URL, state: String) async throws -> URL {
        try await open(authorizationURL)
        var callback = URLComponents(string: "http://127.0.0.1:6000/callback")!
        callback.queryItems = [URLQueryItem(name: "code", value: "fixture-code"),
                               URLQueryItem(name: "state", value: state)]
        return callback.url!
    }
}

private func t3bLoggedInTransport() -> any McpTransport {
    let (client, server) = InMemoryTransport.pair()
    Task {
        while let data = try? await server.receive() {
            guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
            let result: [String: Any]
            switch request.method {
            case "initialize":
                result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "fixture", "version": "1"]]
            case "tools/list":
                result = ["tools": [["name": "echo", "inputSchema": ["type": "object"]]]]
            default: result = [:]
            }
            try? await server.send(JsonRpc.encodeServerResponseToLine(
                JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
        }
        await server.close()
    }
    return client
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func t3bMcpLoginSignsInAndReportsReconnectResult(_ reconnectFails: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-t3b-login-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    try addMcpServerConfig(path: root.appendingPathComponent("mcp.json"), name: "docs",
        config: McpServerConfig(url: serverURL.absoluteString, oauth: .init(clientId: "fixture-client"), timeout: 1))
    let credentials = McpOAuthCredentialStore(agentDir: root)
    let http = T3bLoginHTTP()
    let lines = LockedState<[String]>([])
    let attempts = LockedState(0)
    let options = McpCommandOptions(cwd: root, agentDir: root, credentials: credentials,
        openURL: { _ in }, log: { text in lines.withLock { $0.append(text) } },
        error: { text in lines.withLock { $0.append(text) } },
        createTransport: { _, _, _ in
            attempts.withLock { $0 += 1 }
            guard try credentials.tokens(for: serverURL) != nil else { throw McpOAuthError.authorizationRequired }
            if reconnectFails { throw McpRuntimeError.connectionFailed("fixture reconnect failed") }
            return t3bLoggedInTransport()
        }, makePresenter: { _, _, open in T3bLoginPresenter(open: open) }, oauthHTTP: http)
    let code = await runMcpCommand(["login", "docs", "--timeout", "600.5"], options: options)
    let output = lines.withLock { $0.joined(separator: "\n") }
    #expect(try credentials.tokens(for: serverURL)?.accessToken == "fixture-token")
    #expect(await http.tokenRequests == 1)
    #expect(attempts.withLock { $0 } == 2)
    #expect(output.contains("Sign in to MCP server \"docs\" in your browser:\nhttp://127.0.0.1:45454/authorize?"))
    if reconnectFails {
        #expect(code == 1)
        #expect(output.hasSuffix("Signed in, but MCP server \"docs\" failed to connect: fixture reconnect failed"))
    } else {
        #expect(code == 0)
        #expect(output.hasSuffix("Signed in to MCP server \"docs\" (1 tools)."))
    }
}
