import Darwin
import Foundation
import Testing

private enum RpcShutdownProcessError: Error {
    case timedOut
}

@Suite("RPC extension shutdown process", .serialized)
struct RpcShutdownProcessTests {
    @Test("writes the extension command response before exit 0", .timeLimit(.minutes(2)))
    func commandResponsePrecedesProcessExit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-rpc-shutdown-process-\(UUID())")
        let cwd = root.appendingPathComponent("project")
        let agentDir = root.appendingPathComponent("agent")
        let extensions = cwd.appendingPathComponent(".pi/extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"anthropic":{"type":"api_key","key":"test-key"}}"#.write(
            to: agentDir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let source = """
        import PiExtensionSDK

        @_cdecl("piExtensionMain")
        public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
            withExtensionAPI(raw) { pi in
                pi.registerCommand("bye", description: "End this RPC process") { _, ctx in
                    ctx.shutdown()
                }
            }
        }
        """
        try source.write(to: extensions.appendingPathComponent("shutdown.swift"),
            atomically: true, encoding: .utf8)

        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")
        #expect(FileManager.default.isExecutableFile(atPath: cli.path))
        let stdoutPath = root.appendingPathComponent("stdout.jsonl")
        let stderrPath = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutPath.path, contents: nil)
        FileManager.default.createFile(atPath: stderrPath.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutPath)
        let stderr = try FileHandle(forWritingTo: stderrPath)
        defer { try? stdout.close(); try? stderr.close() }
        let stdin = Pipe()
        defer { try? stdin.fileHandleForWriting.close() }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["--mode", "rpc", "--offline", "--approve", "--provider", "anthropic",
            "--model", "claude-sonnet-4-5", "--no-session", "--no-skills",
            "--no-prompt-templates", "--nc"]
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = agentDir.path
        environment["PI_EXTENSION_SDK_PATH"] = "/Users/miguel/cvs/pi/PiSwift/.build/out/Products/Debug"
        environment["PI_HYPERLINKS"] = "0"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        stdin.fileHandleForWriting.write(Data(#"{"type":"prompt","id":"shutdown-command","message":"/bye"}"#.utf8 + [0x0A]))
        if ended.wait(timeout: .now() + 45) == .timedOut, process.isRunning {
            throw RpcShutdownProcessError.timedOut
        }
        try stdout.synchronize()
        try stderr.synchronize()
        let lines = try String(contentsOf: stdoutPath, encoding: .utf8)
            .split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        #expect(process.terminationStatus == 0)
        #expect(lines.contains { $0["id"] as? String == "shutdown-command" &&
            $0["success"] as? Bool == true })
    }
}
