import ArgumentParser
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

private struct PT5McpFixture {
    let root: URL
    var global: URL { root.appendingPathComponent("mcp.json") }
    var project: URL { root.appendingPathComponent(".pi/mcp.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pt5-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func close() { try? FileManager.default.removeItem(at: root) }

    func write(_ servers: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: .sortedKeys)
        try data.write(to: path)
    }

    func run(_ args: [String]) async -> (Int32, String) {
        let lines = LockedState<[String]>([])
        let options = McpCommandOptions(cwd: root, agentDir: root,
            log: { line in lines.withLock { $0.append(line) } },
            error: { line in lines.withLock { $0.append(line) } })
        let code = await runMcpCommand(args, options: options)
        return (code, lines.withLock { $0.joined(separator: "\n") })
    }
}

@Suite("PT5 MCP command", .timeLimit(.minutes(1)))
struct PT5McpCommandTests {
    // Upstream mcp-command.test.ts: rejects unknown servers and servers without OAuth for login and logout.
    @Test func rejectsUnknownAndNonOAuthServers() async throws {
        let fixture = try PT5McpFixture()
        defer { fixture.close() }
        try fixture.write(["files": ["command": "fixture"]], to: fixture.global)
        let unknown = await fixture.run(["login", "absent"])
        #expect(unknown.0 == 1)
        #expect(unknown.1 == "No MCP server named \"absent\". Configured: files.")
        let noOAuth = await fixture.run(["logout", "files"])
        #expect(noOAuth.0 == 1)
        #expect(noOAuth.1 == "MCP server \"files\" does not use OAuth. Only HTTP servers without an Authorization header do.")
    }

    // Upstream mcp-command.test.ts: restricts login and logout to project servers with --local.
    @Test func localFlagRestrictsBothCredentialCommands() async throws {
        let fixture = try PT5McpFixture()
        defer { fixture.close() }
        try fixture.write(["global": ["url": "https://example.com/mcp"]], to: fixture.global)
        try fixture.write(["project": ["command": "fixture"]], to: fixture.project)
        SettingsManager.create(fixture.root.path, fixture.root.path, projectTrusted: false)
            .setProjectTrust(fixture.root.path, trusted: true)
        for command in ["login", "logout"] {
            let global = await fixture.run([command, "-l", "global"])
            #expect(global.0 == 1)
            #expect(global.1 == "MCP server \"global\" is defined in \(fixture.global.path), not in the project; omit --local.")
            let project = await fixture.run([command, "-l", "project"])
            #expect(project.0 == 1)
            #expect(project.1.contains("does not use OAuth"))
        }
    }

    // Upstream mcp-command.test.ts: adds stdio servers and passes options after the command through.
    // Upstream mcp-command.test.ts: rejects invalid add invocations without writing.
    @Test func addPassesCommandOptionsAndRejectsInvalidWithoutWriting() async throws {
        let fixture = try PT5McpFixture()
        defer { fixture.close() }
        let added = await fixture.run(["add", "files", "node", "--flag", "value"])
        #expect(added.0 == 0)
        let before = try Data(contentsOf: fixture.global)
        let object = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: [String: Any]])
        #expect(servers["files"]?["command"] as? String == "node")
        #expect(servers["files"]?["args"] as? [String] == ["--flag", "value"])
        let invalid = await fixture.run(["add", "bad", "--url", "https://example.com", "--oauth-callback-port", "bad"])
        #expect(invalid.0 == 1)
        #expect(try Data(contentsOf: fixture.global) == before)
    }

    @Test func parserAcceptsLocalAndRegistrationOptions() throws {
        let login = try #require(PiCodingAgentCLI.parseAsRoot(["mcp", "login", "-l", "docs"]) as? McpLoginSubcommand)
        #expect(login.local)
        let logout = try #require(PiCodingAgentCLI.parseAsRoot(["mcp", "logout", "--local", "docs"]) as? McpLogoutSubcommand)
        #expect(logout.local)
        let add = try #require(PiCodingAgentCLI.parseAsRoot(["mcp", "add", "docs", "--url", "https://example.com", "--oauth-client-registration", "dcr"]) as? McpAddSubcommand)
        #expect(add.oauthClientRegistration == "dcr")
    }
}

@Suite("PT5 package and model update text")
struct PT5UpdateTextTests {
    // Upstream package-command-paths.test.ts: does not report packages as up to date when npm left an older version installed.
    @Test func warnsForUnchangedPackageAfterWarning() {
        #expect(packageUpdateSummaryText(updated: [], warningCount: 1, skippedOffline: false, source: nil)
            == "No packages were updated, see the warnings above")
        #expect(packageUpdateSummaryText(updated: [], warningCount: 1, skippedOffline: false, source: "npm:one")
            == "npm:one was not updated, see the warnings above")
    }

    // Upstream package-command-paths.test.ts: does not report packages as up to date in offline mode.
    @Test func reportsOfflineAndOrderedChanges() {
        #expect(packageUpdateSummaryText(updated: [], warningCount: 0, skippedOffline: true, source: nil)
            == "Skipped package updates (offline mode)")
        #expect(packageUpdateSummaryText(updated: [], warningCount: 0, skippedOffline: false, source: nil)
            == "Packages are already up to date")
        #expect(packageUpdateSummaryText(updated: ["npm:a 1 -> 2", "git:b aaa -> bbb"],
            warningCount: 0, skippedOffline: false, source: nil)
            == "Updated 2 packages:\n  npm:a 1 -> 2\n  git:b aaa -> bbb")
    }

    // Upstream package-command-paths.test.ts: warns about a stale provider login during update --models and keeps the refresh successful.
    @Test func staleLoginIsWarningAndRefreshSucceeds() async {
        let result = await runModelsUpdate { _ in
            ModelsRefreshResult(aborted: false, errors: ["openai": OAuthError.refreshFailed("invalid_grant")])
        }
        #expect(result.exitCode == 0)
        #expect(result.stdout == "Model catalogs refreshed")
        #expect(result.stderr?.contains("Warning: skipped model catalog for openai:") == true)
        #expect(result.stderr?.contains("pi auth login openai") == true)
    }

    // Upstream package-command-paths.test.ts: fails update --models when a catalog refresh fails for a reason other than a stale login.
    @Test func catalogFailureExcludesStaleLoginFromFailureDetail() async {
        let result = await runModelsUpdate { _ in
            ModelsRefreshResult(aborted: false, errors: [
                "openai": OAuthError.refreshFailed("invalid_grant"),
                "other": PT5CatalogFailure()
            ])
        }
        #expect(result.exitCode == 1)
        #expect(result.stderr?.contains("Could not refresh model catalogs: other: unavailable") == true)
        #expect(result.stderr?.contains("Warning: skipped model catalog for openai:") == true)
    }
}

private struct PT5CatalogFailure: Error, LocalizedError {
    var errorDescription: String? { "unavailable" }
}
