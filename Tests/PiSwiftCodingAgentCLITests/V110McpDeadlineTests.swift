import Foundation
import PiSwiftCodingAgent
import PiSwiftMCP
import Testing
import Synchronization
@testable import PiSwiftCodingAgentCLI

private actor V110DeadlineHTTP: McpOAuthHTTPClient {
    let stall: Bool
    private(set) var started = false
    private(set) var stopped = false
    init(stall: Bool) { self.stall = stall }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let origin = "http://127.0.0.1:45454"
        let body: [String: Any]
        if request.url!.path.hasPrefix("/.well-known/oauth-protected-resource") {
            body = ["resource": origin + "/mcp", "authorization_servers": [origin]]
        } else {
            started = true
            if stall {
                defer { stopped = true }
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            body = ["issuer": origin, "authorization_endpoint": origin + "/authorize",
                    "token_endpoint": origin + "/token", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code"],
                    "token_endpoint_auth_methods_supported": ["none"],
                    "code_challenge_methods_supported": ["S256"]]
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!,
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

private actor V110UnapprovedPresenter: McpSignInPresenter {
    private(set) var presented = false
    private(set) var cancelled = false
    func redirectURL(for state: String) -> URL { URL(string: "http://127.0.0.1:6000/callback")! }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        presented = true
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func cancel() { cancelled = true }
}

// Upstream v1.1.0 agent-session-mcp-oauth.test.ts:220-249.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func v110McpLoginDeadlineStopsBrowserWaitAndMetadataRequest(_ stall: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-v110-mcp-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try addMcpServerConfig(path: root.appendingPathComponent("mcp.json"), name: "docs",
        config: McpServerConfig(url: "http://127.0.0.1:45454/mcp", oauth: .init(clientId: "fixture-client"), timeout: 1))
    let http = V110DeadlineHTTP(stall: stall)
    let presenter = V110UnapprovedPresenter()
    let lines = Mutex<[String]>([])
    let options = McpCommandOptions(cwd: root, agentDir: root,
        credentials: McpOAuthCredentialStore(agentDir: root), openURL: { _ in },
        log: { line in lines.withLock { $0.append(line) } },
        error: { line in lines.withLock { $0.append(line) } },
        createTransport: { _, _, _ in throw McpOAuthError.authorizationRequired },
        makePresenter: { _, _, _ in presenter }, oauthHTTP: http)
    let start = ContinuousClock.now
    let code = await runMcpCommand(["login", "docs", "--timeout", "0.5"], options: options)
    #expect(code == 1)
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(lines.withLock { $0.last } == "Sign-in to MCP server \"docs\" was cancelled or not completed within 1 seconds.")
    #expect(await http.started)
    #expect(await http.stopped == stall)
    #expect(await presenter.presented == !stall)
    #expect(await presenter.cancelled)
}
