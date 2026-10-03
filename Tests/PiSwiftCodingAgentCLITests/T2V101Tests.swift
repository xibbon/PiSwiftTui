import Foundation
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentCLI

@Suite("T2 v1.0.1 CLI changes")
struct T2V101Tests {
    @Test func ignoresEmptyModelEntries() throws {
        let options = try CLIOptions.parse(["--models", "gpt-4o, ,claude-sonnet,"])
        #expect(options.toArgs().models == ["gpt-4o", "claude-sonnet"])
    }

    @Test func listShowsProjectOverrideAfterTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-t2-list-\(UUID())")
        let project = root.appendingPathComponent(".pi/mcp.json")
        try FileManager.default.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"mcpServers":{"docs":{"command":"fixture","enabled":false}}}"#.utf8)
            .write(to: root.appendingPathComponent("mcp.json"))
        try Data(#"{"mcpServers":{"docs":{"enabled":false}}}"#.utf8).write(to: project)
        SettingsManager.create(root.path, root.path, projectTrusted: false).setProjectTrust(root.path, trusted: true)
        let lines = Mutex<[String]>([])
        let options = McpCommandOptions(cwd: root, agentDir: root,
            log: { line in lines.withLock { $0.append(line) } },
            error: { line in lines.withLock { $0.append(line) } })
        #expect(await runMcpCommand(["list"], options: options) == 0)
        #expect(lines.withLock { $0 } == [
            "docs: disabled (codemode, global)", "  fixture", "  project override: \(project.path)",
        ])
    }
}
