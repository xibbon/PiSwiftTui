import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgentCLI

private enum CLIParityV100Error: Error { case timeout }

private func runCLIParityV100(_ arguments: [String], root: URL) throws -> (code: Int32, output: String, error: String) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
    let candidates = [binaryDirectory.appendingPathComponent("pi-coding-agent"),
        repo.appendingPathComponent(".build/debug/pi-coding-agent"),
        repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")]
    let process = Process()
    process.executableURL = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    process.arguments = arguments
    process.currentDirectoryURL = root
    var environment = ProcessInfo.processInfo.environment
    environment[ENV_AGENT_DIR] = root.path
    environment["NO_COLOR"] = "1"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        throw CLIParityV100Error.timeout
    }
    process.waitUntilExit()
    return (process.terminationStatus,
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private func cliParityV100Root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-cli-v100-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("CLI v1.0.0 parity", .timeLimit(.minutes(1)))
struct CLIParityV100Tests {
    @Test func tuiModeUsesSettingWithoutFlagAndKeepsExplicitOverride() throws {
        let settings = SettingsManager.inMemory()
        let defaults = try CLIOptions.parse([])
        #expect(defaults.parsedTuiModeOverride == nil)
        #expect(defaults.resolvedTuiMode(settingsManager: settings) == .fullscreen)
        settings.setTuiMode("regular")
        #expect(defaults.resolvedTuiMode(settingsManager: settings) == .regular)
        let explicit = try CLIOptions.parse(["--tui-mode", "fullscreen"])
        #expect(explicit.parsedTuiModeOverride == .fullscreen)
        #expect(explicit.resolvedTuiMode(settingsManager: settings) == .fullscreen)
        #expect(settings.getTuiMode() == "regular")
    }

    // Upstream interactive-mode.ts: Model scope uses shouldShowStartupDetails.
    @Test func modelScopeUsesQuietStartupDetailsRule() {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let models = [ScopedModel(model: model, thinkingLevel: .high, isThinkingExplicit: true)]
        let expected = "Model scope: gpt-4o-mini:high (Ctrl+P to cycle)"
        #expect(startupModelScopeMessage(models, quietStartup: .off, verbose: false, keybindings: .inMemory()) == expected)
        for quiet in [QuietStartup.on, .header] {
            #expect(startupModelScopeMessage(models, quietStartup: quiet, verbose: false) == nil)
            #expect(startupModelScopeMessage(models, quietStartup: quiet, verbose: true, keybindings: .inMemory()) == expected)
        }
        #expect(startupModelScopeMessage([], quietStartup: .off, verbose: true) == nil)
    }

    @Test func modelScopeUsesConfiguredCycleKeys() {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let keys = KeybindingsManager.inMemory(config: [AppAction.cycleModelForward.rawValue: ["ctrl+n"]])
        #expect(startupModelScopeMessage([ScopedModel(model: model)], quietStartup: .off,
            verbose: false, keybindings: keys)?.contains("(Ctrl+N to cycle)") == true)
    }

    // Upstream main.ts: --provider without --model is a runtime error, with exit code 1.
    @Test func providerWithoutModelFailsWithUpstreamMessage() throws {
        let root = try cliParityV100Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runCLIParityV100(["--provider", "openai", "--print", "--no-session", "--no-extensions", "--no-approve", "--offline"], root: root)
        #expect(result.code == 1)
        #expect(result.error.contains("Error: --provider requires --model (for example: --provider openai --model <pattern>)\n"))
    }

    @Test func sessionHelpUsesUpstreamProviderAndTuiModeDescriptions() {
        let help = SessionSubcommand.helpMessage(columns: 120)
        #expect(help.contains("Provider to search for --model (requires --model)"))
        #expect(help.contains("TUI mode: fullscreen (default) or regular"))
    }

    @Test func mcpAddParserAcceptsDescriptionAndClientName() throws {
        let args = ["mcp", "add", "docs", "--description", "Product docs", "--oauth-client-name", "Claude Code", "--url", "https://example.com/mcp"]
        let parsed = try #require(PiCodingAgentCLI.parseAsRoot(PiCodingAgentCLI.preprocessArguments(args)) as? McpAddSubcommand)
        #expect(parsed.description == "Product docs")
        #expect(parsed.oauthClientName == "Claude Code")
        #expect(parsed.command.isEmpty)
        #expect(mcpCommandHelp.contains("--description <text>    What the server offers, shown in the system prompt"))
        #expect(mcpCommandHelp.contains("--oauth-client-name <name>"))
    }

    // Upstream mcp-command.test.ts: add stores description and oauth.clientName.
    @Test func mcpAddStoresDescriptionAndClientName() async throws {
        let root = try cliParityV100Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let options = McpCommandOptions(cwd: root, agentDir: root, log: { _ in }, error: { _ in })
        let code = await runMcpCommand(["add", "docs", "--url", "https://example.com/mcp",
            "--description", "Product docs", "--oauth-client-name", "Claude Code"], options: options)
        #expect(code == 0)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mcp.json"))) as? [String: Any])
        let servers = try #require(payload["mcpServers"] as? [String: [String: Any]])
        #expect(servers["docs"]?["description"] as? String == "Product docs")
        #expect(servers["docs"]?["oauth"] as? [String: String] == ["clientName": "Claude Code"])
    }

    @Test func mcpClientNameRequiresHTTPWhileDescriptionWorksForStdio() async throws {
        let root = try cliParityV100Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = LockedState<[String]>([])
        let options = McpCommandOptions(cwd: root, agentDir: root, log: { _ in }, error: { line in lines.withLock { $0.append(line) } })
        #expect(await runMcpCommand(["add", "files", "--oauth-client-name", "Claude Code", "--", "fixture"], options: options) == 1)
        #expect(lines.withLock { $0 } == ["--oauth-client-name only applies to HTTP servers (--url)."])
        #expect(await runMcpCommand(["add", "files", "--description", "Local files", "--", "fixture"], options: options) == 0)
        let loaded = loadMcpConfig(agentDir: root, cwd: root, projectTrusted: false)
        #expect(loaded.servers.first?.config.description == "Local files")
    }

    @Test func mcpLogoutRemovesOnlyNamedServerAtSharedURL() async throws {
        let root = try cliParityV100Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://example.com/mcp")!
        let credentials = McpOAuthCredentialStore(agentDir: root)
        for name in ["docs", "other"] {
            try addMcpServerConfig(path: root.appendingPathComponent("mcp.json"), name: name,
                config: McpServerConfig(url: url.absoluteString))
            try await credentials.forServer(name: name, url: url).save(McpOAuthState(serverURL: url.absoluteString,
                tokens: McpOAuthTokens(accessToken: name, tokenType: "Bearer")))
        }
        let lines = LockedState<[String]>([])
        let options = McpCommandOptions(cwd: root, agentDir: root, credentials: credentials,
            log: { line in lines.withLock { $0.append(line) } }, error: { _ in })
        #expect(await runMcpCommand(["logout", "docs"], options: options) == 0)
        #expect(try credentials.tokens(name: "docs", url: url) == nil)
        #expect(try credentials.tokens(name: "other", url: url)?.accessToken == "other")
        #expect(lines.withLock { $0 } == ["Signed out of MCP server \"docs\"."])
    }
}

// These replies use the OAuth metadata and token shapes from PiSwift's MCP fixtures.
private actor CLIParityV100LoginHTTP: McpOAuthHTTPClient {
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

private struct CLIParityV100LoginPresenter: McpSignInPresenter {
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

private func cliParityV100LoggedInTransport() -> any McpTransport {
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


// Named MCP login must not share tokens with another server at the same URL.
@Test(.timeLimit(.minutes(1)))
func mcpV100LoginStoresTokensUnderServerName() async throws {
    let root = try cliParityV100Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    try addMcpServerConfig(path: root.appendingPathComponent("mcp.json"), name: "docs",
        config: McpServerConfig(url: serverURL.absoluteString, oauth: .init(clientId: "fixture-client"), timeout: 1))
    let credentials = McpOAuthCredentialStore(agentDir: root)
    let http = CLIParityV100LoginHTTP()
    let lines = LockedState<[String]>([])
    let options = McpCommandOptions(cwd: root, agentDir: root, credentials: credentials,
        openURL: { _ in }, log: { text in lines.withLock { $0.append(text) } },
        error: { text in lines.withLock { $0.append(text) } },
        createTransport: { entry, _, _ in
            guard try credentials.tokens(name: entry.name, url: serverURL) != nil else { throw McpOAuthError.authorizationRequired }
            return cliParityV100LoggedInTransport()
        }, makePresenter: { _, _, open in CLIParityV100LoginPresenter(open: open) }, oauthHTTP: http)
    #expect(await runMcpCommand(["login", "docs"], options: options) == 0)
    #expect(try credentials.tokens(name: "docs", url: serverURL)?.accessToken == "fixture-token")
    #expect(try credentials.tokens(name: "other", url: serverURL) == nil)
    #expect(await http.tokenRequests == 1)
    #expect(lines.withLock { $0.last } == "Signed in to MCP server \"docs\" (1 tools).")
}
