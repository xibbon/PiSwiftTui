import Darwin
import Foundation
import Testing

@Suite("PT5 auth executable", .timeLimit(.minutes(1)))
struct PT5AuthExecutableTests {
    @Test func rejectedApiKeyValuesDoNotAppearInErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt5-auth-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = try #require([
            binaryDirectory.appendingPathComponent("pi-coding-agent"),
            repo.appendingPathComponent(".build/debug/pi-coding-agent"),
            repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) })

        for arguments in [["auth", "login", "groq", "--api-key", "test-key"],
                          ["auth", "login", "groq", "--api-key=test-key"]] {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            environment["PI_CODING_AGENT_DIR"] = root.path
            environment["PI_OFFLINE"] = "1"
            environment["NO_COLOR"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let outputReader = TestPipeReader(output)
            let errorReader = TestPipeReader(error)
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let out = outputReader.wait()
            let err = errorReader.wait()
            process.waitUntilExit()
            #expect(process.terminationStatus == 1)
            #expect(out.isEmpty)
            let message = String(decoding: err, as: UTF8.self)
            #expect(message == "Usage: pi auth login <provider> [--api-key] [--no-browser]\n")
            #expect(!message.contains("test-key"))
        }
    }
}
