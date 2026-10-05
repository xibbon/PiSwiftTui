import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum PipedInputModeTestError: Error {
    case processTimedOut
    case cleanupTimedOut
}

private func waitForPipedInputCLI(_ process: Process, seconds: TimeInterval) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    return !process.isRunning
}

@Test(.timeLimit(.minutes(1)))
func pipedInputWithoutPrintFlagUsesPrintMode() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-piped-input-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let agentDir = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

    let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        .deletingLastPathComponent()
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        binaryDirectory.appendingPathComponent("pi-coding-agent"),
        repo.appendingPathComponent(".build/debug/pi-coding-agent"),
        repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent"),
    ]
    let cliURL = try #require(candidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }, "The built pi-coding-agent executable was not found.")

    // Files keep output available for checks without a full pipe blocking the child.
    let stdoutURL = root.appendingPathComponent("stdout")
    let stderrURL = root.appendingPathComponent("stderr")
    try Data().write(to: stdoutURL)
    try Data().write(to: stderrURL)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    defer { try? stdout.close() }
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stderr.close() }
    let stdin = Pipe()
    defer {
        try? stdin.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
    }

    let process = Process()
    process.executableURL = cliURL
    // No print flag: the descriptors must select print mode.
    process.arguments = [
        "--offline", "--no-session", "--no-extensions",
        "--no-skills", "--no-prompt-templates", "--nc",
    ]
    process.currentDirectoryURL = root
    // Do not inherit provider keys or user configuration from the test runner.
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PI_CODING_AGENT_DIR": agentDir.path,
        "TERM": "xterm-256color",
    ]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    defer {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = waitForPipedInputCLI(process, seconds: 1)
        }
    }
    try stdin.fileHandleForWriting.write(contentsOf: Data("Explain this project.\n".utf8))
    try stdin.fileHandleForWriting.close()

    if !waitForPipedInputCLI(process, seconds: 15) {
        process.terminate()
        if !waitForPipedInputCLI(process, seconds: 1) {
            _ = kill(process.processIdentifier, SIGKILL)
            guard waitForPipedInputCLI(process, seconds: 1) else {
                throw PipedInputModeTestError.cleanupTimedOut
            }
        }
        throw PipedInputModeTestError.processTimedOut
    }
    let stdoutText = try String(contentsOf: stdoutURL, encoding: .utf8)
    let stderrText = try String(contentsOf: stderrURL, encoding: .utf8)
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 1, "Unexpected CLI result: \(stderrText)")
    // Both texts come only from the print-mode startup checks (no model, or a model without a
    // key); which one appears depends on the catalog default, not on the mode.
    #expect(stderrText.contains("No models available.") || stderrText.contains("No API key found"),
            "Expected a print-mode diagnostic: \(stderrText)")
    #expect(!stdoutText.contains("\u{001B}[?2004h"))
    for sequence in ["\u{001B}[?1049h", "\u{001B}[?1047h", "\u{001B}[?47h"] {
        #expect(!stdoutText.contains(sequence), "The CLI started an alternate screen.")
    }
}
