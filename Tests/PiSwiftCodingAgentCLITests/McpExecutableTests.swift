import Darwin
import Foundation
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

private enum McpExecutableTestError: Error { case timeout }

private struct McpExecutableResult {
    var code: Int32
    var output: String
    var error: String
}

private func runMcpExecutable(_ arguments: [String], root: URL) throws -> McpExecutableResult {
    let fm = FileManager.default
    let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [binaryDirectory.appendingPathComponent("pi-coding-agent"),
        repo.appendingPathComponent(".build/debug/pi-coding-agent"),
        repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")]
    let process = Process()
    process.executableURL = try #require(candidates.first { fm.isExecutableFile(atPath: $0.path) })
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
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        throw McpExecutableTestError.timeout
    }
    process.waitUntilExit()
    return McpExecutableResult(code: process.terminationStatus,
        output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private func mcpExecutableDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-executable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("MCP executable", .timeLimit(.minutes(1)))
struct McpExecutableTests {
    @Test func executableUsesUpstreamErrorsAndExitCodes() throws {
        let root = try mcpExecutableDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (args, expected) in [
            (["mcp", "list", "--bogus"], "Unknown option --bogus.\nUse \"pi mcp --help\" for usage.\n"),
            (["mcp", "add", "x", "--url"], "--url needs a value.\n"),
            (["mcp", "login"], "Usage: pi mcp login <server>\nUse \"pi mcp --help\" for usage.\n"),
            (["mcp", "frobnicate"], "Unknown mcp command \"frobnicate\".\nUse \"pi mcp --help\" for usage.\n"),
            (["mcp", "add", "x", "--url=https://example.com"], "Unknown option --url=https://example.com.\nUse \"pi mcp --help\" for usage.\n")
        ] {
            let result = try runMcpExecutable(args, root: root)
            #expect(result.code == 1)
            #expect(result.output.isEmpty)
            #expect(result.error == expected)
        }
        let help = try runMcpExecutable(["mcp", "--help"], root: root)
        #expect(help.code == 0)
        #expect(help.output == mcpCommandHelp + "\n")
        #expect(help.error.isEmpty)
        let empty = try runMcpExecutable(["mcp", "list", "--json"], root: root)
        #expect(empty.code == 0)
        #expect(empty.error.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(empty.output.utf8)) as? [String: Any])
        #expect((payload["servers"] as? [Any])?.isEmpty == true)
    }

    @Test func executablePreservesCommandOptionsAndGlobalHelpRule() throws {
        let root = try mcpExecutableDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for separator in [[], ["--"]] {
            let added = try runMcpExecutable(["mcp", "add", "files"] + separator +
                ["node", "server.js", "--mode", "server-mode", "-ne", "--print"], root: root)
            #expect(added.code == 0)
            #expect(added.error.isEmpty)
            let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mcp.json"))) as? [String: Any])
            let servers = try #require(payload["mcpServers"] as? [String: [String: Any]])
            #expect(servers["files"]?["args"] as? [String] == ["server.js", "--mode", "server-mode", "-ne", "--print"])
        }
        let help = try runMcpExecutable(["mcp", "add", "files", "node", "-h"], root: root)
        #expect(help.code == 0)
        #expect(help.output == mcpCommandHelp + "\n")
    }

    @Test func executableListReportsDisabledAndBrokenServers() throws {
        let root = try mcpExecutableDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config: [String: Any] = ["mcpServers": [
            "broken": ["command": root.appendingPathComponent("missing-command").path, "timeout": 0.1],
            "parked": ["command": "fixture", "enabled": false]]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("mcp.json"))
        let result = try runMcpExecutable(["mcp", "list"], root: root)
        #expect(result.code == 1)
        #expect(result.error.isEmpty)
        #expect(result.output.contains("broken: failed (codemode, global)"))
        #expect(result.output.contains("parked: disabled (codemode, global)"))
    }
}
