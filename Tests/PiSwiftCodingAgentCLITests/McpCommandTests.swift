import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgentCLI

private struct McpFixtureFailure: Error, LocalizedError, Sendable {
    var errorDescription: String? { "spawn pi-test-missing-mcp-server ENOENT" }
}

// Use the same paired transport and protocol replies as the PiSwift MCP tests.
private func mcpFixtureTransport(_ entry: McpServerEntry, _ cwd: URL,
                                 _ auth: (any McpAuthProvider)?) throws -> any McpTransport {
    if entry.name == "broken" { throw McpFixtureFailure() }
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

private struct McpCommandTestContext {
    let root: URL
    var configPath: URL { root.appendingPathComponent("mcp.json") }
    var projectPath: URL { root.appendingPathComponent(".pi/mcp.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func close() { try? FileManager.default.removeItem(at: root) }

    func write(_ servers: [String: Any], path: URL? = nil) throws {
        let destination = path ?? configPath
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: .sortedKeys).write(to: destination)
    }

    func read(_ path: URL? = nil) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path ?? configPath)) as? [String: Any])
    }

    func run(_ args: [String], customize: (inout McpCommandOptions) -> Void = { _ in }) async -> (code: Int32, output: String) {
        let lines = LockedState<[String]>([])
        var options = McpCommandOptions(cwd: root, agentDir: root,
            log: { line in lines.withLock { $0.append(line) } },
            error: { line in lines.withLock { $0.append(line) } }, createTransport: mcpFixtureTransport)
        customize(&options)
        let code = await runMcpCommand(args, options: options)
        return (code, lines.withLock { $0.joined(separator: "\n") })
    }
}

private var mcpCommandServers: [String: Any] {
    ["fixture": ["command": "fixture", "timeout": 1],
     "broken": ["command": "pi-test-missing-mcp-server", "timeout": 1],
     "parked": ["command": "fixture", "enabled": false],
     "bad": ["args": ["no command"]]]
}

@Suite("MCP command port", .timeLimit(.minutes(1)))
struct McpCommandTests {
    // Upstream mcp-command.test.ts: lists servers with state, tools, and errors.
    @Test func listsServersWithStateToolsAndErrorsAndFailsWhileAnythingIsWrong() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(mcpCommandServers)
        let result = await context.run(["list"])
        #expect(result.code == 1)
        #expect(result.output.contains("fixture: connected, 1 tool (codemode, global)\n"))
        #expect(result.output.contains("  tools: echo"))
        #expect(result.output.contains("broken: failed (codemode, global)\n  pi-test-missing-mcp-server\n  spawn pi-test-missing-mcp-server ENOENT"))
        #expect(result.output.contains("parked: disabled (codemode, global)"))
        #expect(result.output.contains("config error: "))
        #expect(result.output.contains("server \"bad\": needs either \"command\""))
        try context.write(["fixture": mcpCommandServers["fixture"]!])
        #expect(await context.run(["list"]).code == 0)
    }

    // Upstream: prints JSON for scripts.
    @Test func printsJSONForScripts() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(["fixture": mcpCommandServers["fixture"]!, "parked": mcpCommandServers["parked"]!])
        let result = await context.run(["list", "--json"])
        #expect(result.code == 0)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let servers = try #require(payload["servers"] as? [[String: Any]])
        #expect(servers.compactMap { $0["name"] as? String } == ["fixture", "parked"])
        #expect(servers.compactMap { $0["state"] as? String } == ["connected", "disabled"])
        #expect(servers.compactMap { $0["tools"] as? [String] } == [["echo"], []])
        #expect(payload["errors"] as? [String] == [])
        #expect(payload["note"] == nil)
    }

    // Upstream: rejects unknown servers and servers without OAuth.
    @Test func rejectsUnknownServersAndServersWithoutOAuthForLoginAndLogout() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(mcpCommandServers)
        let unknown = await context.run(["login", "nope"])
        #expect(unknown.code == 1)
        // The shared Swift config loader sorts names. Upstream retains JSON insertion order.
        #expect(unknown.output == "No MCP server named \"nope\". Configured: broken, fixture, parked.")
        let stdio = await context.run(["logout", "fixture"])
        #expect(stdio.code == 1)
        #expect(stdio.output == "MCP server \"fixture\" does not use OAuth. Only HTTP servers without an Authorization header do.")
        #expect(await context.run(["frobnicate"]).code == 1)
    }

    // Upstream: adds stdio servers and passes options after the command through.
    @Test func addsStdioServersAndPassesOptionsAfterTheCommandThrough() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        let added = await context.run(["add", "--env", "A=1", "--env", "B=x=y", "files", "--", "npx", "-y", "server", "--root", "."])
        #expect(added.code == 0)
        #expect(added.output.contains("Added global MCP server \"files\""))
        var root = try context.read()
        var servers = try #require(root["mcpServers"] as? [String: [String: Any]])
        #expect(servers["files"]?["command"] as? String == "npx")
        #expect(servers["files"]?["args"] as? [String] == ["-y", "server", "--root", "."])
        #expect(servers["files"]?["env"] as? [String: String] == ["A": "1", "B": "x=y"])
        let replaced = await context.run(["add", "files", "node", "server.js", "--port", "1"])
        #expect(replaced.code == 0)
        #expect(replaced.output.contains("Replaced global MCP server \"files\""))
        root = try context.read()
        servers = try #require(root["mcpServers"] as? [String: [String: Any]])
        #expect(servers["files"]?["command"] as? String == "node")
        #expect(servers["files"]?["args"] as? [String] == ["server.js", "--port", "1"])
        #expect(servers["files"]?["env"] == nil)
    }

    // Upstream: adds HTTP servers and keeps other content of the file.
    @Test func addsHTTPServersAndKeepsOtherContentOfTheFile() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(["fixture": mcpCommandServers["fixture"]!])
        let result = await context.run(["add", "docs", "--url", "https://example.com/mcp", "--bearer-token-env-var", "DOCS_TOKEN", "--header", "X-Team=core", "--exposure", "direct"])
        #expect(result.code == 0)
        #expect(!result.output.contains("mcp login"))
        var servers = try #require(context.read()["mcpServers"] as? [String: [String: Any]])
        #expect(servers["fixture"]?["command"] as? String == "fixture")
        #expect(servers["docs"]?["url"] as? String == "https://example.com/mcp")
        #expect(servers["docs"]?["headers"] as? [String: String] == ["X-Team": "core", "Authorization": "Bearer ${DOCS_TOKEN}"])
        #expect(servers["docs"]?["exposure"] as? String == "direct")
        let oauth = await context.run(["add", "sentry", "--url", "https://mcp.sentry.dev/mcp", "--oauth-client-id", "pi"])
        #expect(oauth.code == 0)
        #expect(oauth.output.contains("If it requires sign-in: pi mcp login sentry"))
        servers = try #require(context.read()["mcpServers"] as? [String: [String: Any]])
        #expect(servers["sentry"]?["oauth"] as? [String: String] == ["clientId": "pi"])
    }

    // Upstream: rejects invalid add invocations without writing.
    @Test func rejectsInvalidAddInvocationsWithoutWriting() async throws {
        let cases = [["add", "x"], ["add", "x", "--url", "https://example.com", "--", "cmd"],
            ["add", "bad name", "--", "cmd"], ["add", "x", "--url", "ftp://example.com"],
            ["add", "x", "--env", "A=1", "--url", "https://example.com"],
            ["add", "x", "--header", "A=1", "--", "cmd"], ["add", "x", "--env", "NOVALUE", "--", "cmd"],
            ["add", "x", "--exposure", "loud", "--", "cmd"]]
        for args in cases {
            let context = try McpCommandTestContext()
            defer { context.close() }
            #expect(await context.run(args).code == 1, "\(args)")
            #expect(!FileManager.default.fileExists(atPath: context.configPath.path))
        }
    }

    // Upstream: adds and removes project servers.
    @Test func addsAndRemovesProjectServers() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        let added = await context.run(["add", "-l", "local", "--", "node", "server.js"])
        #expect(added.code == 0)
        #expect(added.output.contains("The project is not trusted"))
        let servers = try #require(context.read(context.projectPath)["mcpServers"] as? [String: [String: Any]])
        #expect(servers["local"]?["command"] as? String == "node")
        #expect(servers["local"]?["args"] as? [String] == ["server.js"])
        let wrong = await context.run(["remove", "local"])
        #expect(wrong.code == 1)
        #expect(wrong.output.contains("It is defined in \(context.projectPath.path); use --local."))
        let removed = await context.run(["remove", "local", "--local"])
        #expect(removed.code == 0)
        #expect(removed.output.contains("Removed project MCP server \"local\""))
        #expect((try context.read(context.projectPath)["mcpServers"] as? [String: Any])?.isEmpty == true)
    }

    // Upstream: removes global servers.
    @Test func removesGlobalServers() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(mcpCommandServers)
        let removed = await context.run(["remove", "broken"])
        #expect(removed.code == 0)
        let servers = try #require(context.read()["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["fixture", "parked", "bad"])
        let missing = await context.run(["remove", "broken"])
        #expect(missing.code == 1)
        #expect(missing.output.contains("No global MCP server named \"broken\""))
    }

    @Test func parserGroupAcceptsAllOptionsAndBothCommandForms() throws {
        func parse(_ args: [String]) throws -> any ParsableCommand {
            try PiCodingAgentCLI.parseAsRoot(PiCodingAgentCLI.preprocessArguments(args))
        }
        let stdio = try #require(parse(["mcp", "add", "-l", "files", "--env", "A=1", "--env", "B=2", "--cwd", "src", "--", "node", "--flag"]) as? McpAddSubcommand)
        #expect(stdio.local)
        #expect(stdio.environment == ["A=1", "B=2"])
        #expect(stdio.cwd == "src")
        #expect(stdio.command == ["node", "--flag"])
        let implicit = try #require(parse(["mcp", "add", "files", "node", "-ne", "--mode", "server-value"]) as? McpAddSubcommand)
        #expect(implicit.command == ["node", "-ne", "--mode", "server-value"])
        let http = try #require(parse(["mcp", "add", "docs", "--url", "https://example.com", "--header", "A=1", "--bearer-token-env-var", "TOKEN", "--oauth-client-id", "pi", "--oauth-client-secret", "${SECRET}", "--oauth-callback-port", "8765", "--exposure", "hidden"]) as? McpAddSubcommand)
        #expect(http.url == "https://example.com")
        #expect(http.headers == ["A=1"])
        #expect(http.bearerTokenEnvVar == "TOKEN")
        #expect(http.oauthClientID == "pi")
        #expect(http.oauthClientSecret == "${SECRET}")
        #expect(http.oauthCallbackPort == "8765")
        #expect(http.exposure == "hidden")
        #expect(try (parse(["mcp", "list", "--json"]) as? McpListSubcommand)?.json == true)
        #expect(try (parse(["mcp", "login", "docs"]) as? McpLoginSubcommand)?.timeout == "300")
        #expect(try (parse(["mcp", "login", "docs", "--timeout", "600.5"]) as? McpLoginSubcommand)?.timeout == "600.5")
        #expect(try parse(["mcp", "logout", "docs"]) is McpLogoutSubcommand)
        #expect(try (parse(["mcp", "remove", "docs", "-l"]) as? McpRemoveSubcommand)?.local == true)
        #expect(PiCodingAgentCLI.preprocessArguments(["--no-extensions", "mcp", "list"]) == ["mcp", "--no-extensions", "list"])
    }

    @Test func diagnosticsHelpAndTrustNotesMatchUpstream() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        let cases: [([String], String)] = [
            (["list", "--bogus"], "Unknown option --bogus.\nUse \"pi mcp --help\" for usage."),
            (["add", "x", "--url"], "--url needs a value."),
            (["list", "x"], "Usage: pi mcp list [--json]\nUse \"pi mcp --help\" for usage."),
            (["login"], "Usage: pi mcp login <server>\nUse \"pi mcp --help\" for usage."),
            (["logout", "a", "b"], "Usage: pi mcp logout <server>\nUse \"pi mcp --help\" for usage."),
            (["add", "x", "--env", "A", "--", "cmd"], "--env expects KEY=VALUE, got \"A\"."),
            (["add", "x", "--url", "https://example.com", "--cwd", "src"], "--cwd only applies to stdio servers."),
            (["add", "x", "--oauth-client-id", "pi", "--", "cmd"], "--oauth-client-id only applies to HTTP servers (--url).")]
        for (args, expected) in cases {
            let result = await context.run(args)
            #expect(result.code == 1)
            #expect(result.output == expected)
        }
        for args in [[], ["help"], ["frobnicate", "--help"], ["add", "x", "cmd", "-h"]] {
            let result = await context.run(args)
            #expect(result.code == 0)
            #expect(result.output == mcpCommandHelp)
        }
        try context.write(["local": ["command": "fixture", "enabled": false]], path: context.projectPath)
        let untrusted = await context.run(["list", "--json"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(untrusted.output.utf8)) as? [String: Any])
        #expect((payload["servers"] as? [Any])?.isEmpty == true)
        #expect((payload["note"] as? String)?.contains("is ignored because the project is not trusted") == true)
        let missing = await context.run(["login", "local"])
        #expect(missing.output.contains("is ignored because the project is not trusted"))
        SettingsManager.create(context.root.path, context.root.path, projectTrusted: false).setProjectTrust(context.root.path, trusted: true)
        let trusted = await context.run(["list"])
        #expect(trusted.output.contains("local: disabled (codemode, project)"))
        #expect(!trusted.output.contains("is ignored"))
    }

    @Test func allOAuthAndStdioOptionsAreStoredAndInvalidPortsDoNotWrite() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        let result = await context.run(["add", "oauth", "--url", "https://example.com/mcp", "--oauth-client-id", "client", "--oauth-client-secret", "${SECRET}", "--oauth-callback-port", "8765", "--header", "A=1", "--header", "A=last=part", "--exposure", "codemode-deferred"])
        #expect(result.code == 0)
        let servers = try #require(context.read()["mcpServers"] as? [String: [String: Any]])
        let oauth = try #require(servers["oauth"]?["oauth"] as? [String: Any])
        #expect(oauth["clientId"] as? String == "client")
        #expect(oauth["clientSecret"] as? String == "${SECRET}")
        #expect(oauth["callbackPort"] as? Int == 8765)
        #expect(servers["oauth"]?["headers"] as? [String: String] == ["A": "last=part"])
        #expect(servers["oauth"]?["exposure"] as? String == "codemode-deferred")
        let before = try Data(contentsOf: context.configPath)
        for port in ["nope", "0", "65536", "1.5"] {
            let invalid = await context.run(["add", "invalid", "--url", "https://example.com", "--oauth-callback-port", port])
            #expect(invalid.code == 1)
            #expect(invalid.output == "server \"invalid\": oauth.callbackPort must be a port number")
            #expect(try Data(contentsOf: context.configPath) == before)
        }
        let stdio = await context.run(["add", "files", "--cwd", "src", "--env", "EMPTY=", "--", "serve"])
        #expect(stdio.code == 0)
        let files = try #require((context.read()["mcpServers"] as? [String: [String: Any]])?["files"])
        #expect(files["cwd"] as? String == "src")
        #expect(files["env"] as? [String: String] == ["EMPTY": ""])
    }

    @Test func loginValidationAlreadySignedInAndLogoutUseLibraryCredentials() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(["docs": ["url": "https://example.com/mcp", "timeout": 1],
                           "token": ["url": "https://example.com/mcp", "headers": ["authorization": "Bearer x"]]])
        for timeout in ["0", "-1", "NaN", "Infinity", "bad"] {
            let invalid = await context.run(["login", "docs", "--timeout", timeout])
            #expect(invalid.code == 1)
            #expect(invalid.output == "--timeout must be a positive number of seconds.")
        }
        let already = await context.run(["login", "docs", "--timeout", "600.5"])
        #expect(already.code == 0)
        #expect(already.output == "Already signed in to MCP server \"docs\" (1 tools).")
        let noOAuth = await context.run(["login", "token"])
        #expect(noOAuth.code == 1)
        #expect(noOAuth.output.contains("does not use OAuth"))
        let url = URL(string: "https://example.com/mcp")!
        let credentials = McpOAuthCredentialStore(agentDir: context.root)
        try await credentials.forServer(url).save(McpOAuthState(serverURL: url.absoluteString,
            tokens: McpOAuthTokens(accessToken: "secret", tokenType: "Bearer")))
        let removed = await context.run(["logout", "docs"])
        #expect(removed.code == 0)
        #expect(removed.output == "Signed out of MCP server \"docs\".")
        #expect(try credentials.state(for: url) == nil)
        let missing = await context.run(["logout", "docs"])
        #expect(missing.code == 0)
        #expect(missing.output == "No stored credentials for MCP server \"docs\".")
    }

    @Test func loginResolvesSettingsAndPassesLargeFractionalAndRadixTimeouts() async throws {
        let context = try McpCommandTestContext()
        defer { context.close() }
        try context.write(["docs": ["url": "https://example.com/mcp", "oauth": ["clientId": "client",
            "clientSecret": "!printf mcp-cli-resolved-secret", "callbackPort": 8765]]])
        for (input, expected, messageSeconds) in [("600.5", 600.5, "601"),
            ("0x10000000000000000", 18_446_744_073_709_551_616.0, "18446744073709552000"),
            ("0b101", 5.0, "5"), ("0o10", 8.0, "8"), ("1e21", 1e21, "1e+21"),
            ("1.25e21", 1.25e21, "1.25e+21"), ("1e308", 1e308, "Infinity"),
            ("0.49999999999999994", 0.49999999999999994, "0"), ("0.5", 0.5, "1")] {
            let captured = LockedState<(McpOAuthConfig, Double)?>(nil)
            let result = await context.run(["login", "docs", "--timeout", input]) { options in
                options.createTransport = { _, _, _ in throw McpOAuthError.authorizationRequired }
                options.makePresenter = { settings, timeout, _ in
                    captured.withLock { $0 = (settings, timeout) }
                    throw CancellationError()
                }
            }
            #expect(result.code == 1)
            #expect(result.output == "Sign-in to MCP server \"docs\" was cancelled or not completed within \(messageSeconds) seconds.")
            let value = try #require(captured.withLock { $0 })
            #expect(value.0.clientId == "client")
            #expect(value.0.clientSecret == "mcp-cli-resolved-secret")
            #expect(value.0.callbackPort == 8765)
            #expect(value.1 == expected)
        }
        for input in ["+0x10", "-0x10", "+0b10", "-0o10", "0x", "0x1p4", "0b2", "0o8"] {
            #expect(await context.run(["login", "docs", "--timeout", input]).output == "--timeout must be a positive number of seconds.")
        }
    }
}
