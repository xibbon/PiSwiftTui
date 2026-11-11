import Darwin
import Foundation
import PiSwiftCodingAgent
import Testing

private enum PT3ProcessError: Error {
    case timedOut(String)
}

private func pt3WaitForFile(_ path: String, timeout: TimeInterval = 20) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return }
        usleep(20_000)
    }
    throw PT3ProcessError.timedOut(path)
}

private func pt3WaitForExit(_ process: Process, timeout: TimeInterval = 5) throws {
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    if !process.isRunning { return }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        // The child may have exited before Foundation delivered its termination callback.
        if !process.isRunning { return }
        _ = kill(process.processIdentifier, SIGKILL)
        throw PT3ProcessError.timedOut("process exit")
    }
}

enum PT3SignalPair: String, CaseIterable, Sendable {
    case termTerm
    case termHup
    case hupTerm

    var first: Int32 { self == .hupTerm ? SIGHUP : SIGTERM }
    var second: Int32 { self == .termHup ? SIGHUP : SIGTERM }
    var exitCode: Int32 { second == SIGHUP ? 129 : 143 }
}

@Suite("PT3 signal process", .serialized)
struct PT3SignalProcessTests {
    // v1.5.2 4ea883792, main.ts:745-769: print and RPC cannot open a dialog.
    @Test("noninteractive missing cwd prints the tagged error", arguments: ["print", "rpc"])
    func missingSessionCwdWithoutDialog(_ mode: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-no-dialog-\(UUID())")
        let cwd = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        let missing = root.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agent"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sessions.appendingPathComponent("source.jsonl")
        let header: [String: Any] = ["type": "session", "version": 3, "id": UUID().uuidString,
            "timestamp": "2026-11-11T10:00:00.000Z", "cwd": missing.path]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        try (headerData + Data([0x0A])).write(to: source)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")
        let errorPath = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorPath.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorPath)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = cli
        process.arguments = [mode == "rpc" ? "--mode" : "--print"] +
            (mode == "rpc" ? ["rpc"] : []) +
            ["--offline", "--no-extensions", "--no-approve", "--session", source.path,
             "--session-dir", sessions.path]
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment[ENV_AGENT_DIR] = root.appendingPathComponent("agent").path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        try pt3WaitForExit(process)
        try errors.synchronize()
        let diagnostic = try String(contentsOf: errorPath, encoding: .utf8)
        let physicalCwd = try #require(cwd.path.withCString { realpath($0, nil) })
        defer { free(physicalCwd) }
        #expect(process.terminationStatus == 1)
        #expect(diagnostic.contains("Stored session working directory does not exist: \(missing.path)"))
        #expect(diagnostic.contains("Session file: \(source.path)"))
        #expect(diagnostic.contains("Current working directory: \(String(cString: physicalCwd))"))
    }

    // v1.5.2 4ea883792, main.ts:631-641, deleted-cwd.test.ts:10.
    @Test("a deleted current directory prints the tagged diagnostic and exits 1")
    func deletedCurrentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-deleted-cwd-\(UUID())")
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")
        let errorPath = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorPath.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorPath)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "rmdir \"$PT3_CWD\"; exec \"$PT3_CLI\" --offline --print --no-extensions --no-session"]
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["PT3_CWD"] = cwd.path
        environment["PT3_CLI"] = cli.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        try pt3WaitForExit(process)
        try errors.synchronize()
        let diagnostic = try String(contentsOf: errorPath, encoding: .utf8)
        #expect(process.terminationStatus == 1)
        #expect(diagnostic.contains("Error: The current working directory no longer exists. Change to an existing directory and try again."))
    }

    // v1.5.2 ace560c30, print-mode.test.ts:157 and rpc-mode.ts:377-391.
    @Test("one signal during disposal waits; a second exits", .timeLimit(.minutes(1)),
          arguments: ["print", "rpc"], PT3SignalPair.allCases)
    func repeatedSignalEndsSlowShutdown(_ mode: String, _ pair: PT3SignalPair) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-signal-\(UUID())")
        let cwd = root.appendingPathComponent("project")
        let agentDir = root.appendingPathComponent("agent")
        let extensions = cwd.appendingPathComponent(".pi/extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"anthropic":{"type":"api_key","key":"test-key"}}"#.write(
            to: agentDir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let extensionSource = """
        import PiExtensionSDK
        import Foundation

        @_cdecl("piExtensionMain")
        public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
            withExtensionAPI(raw) { pi in
                pi.on("session_start") { (_: SessionStartEvent, _: HookContext) in
                    if let path = ProcessInfo.processInfo.environment["PT3_READY"] {
                        try? Data("ready".utf8).write(to: URL(fileURLWithPath: path))
                    }
                    return nil
                }
                pi.on("session_shutdown") { (_: SessionShutdownEvent, _: HookContext) in
                    if let path = ProcessInfo.processInfo.environment["PT3_CLOSING"] {
                        try? Data("closing".utf8).write(to: URL(fileURLWithPath: path))
                    }
                    let release = ProcessInfo.processInfo.environment["PT3_RELEASE"] ?? ""
                    while !FileManager.default.fileExists(atPath: release) {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    return nil
                }
            }
        }
        """
        try extensionSource.write(to: extensions.appendingPathComponent("slow-shutdown.swift"),
            atomically: true, encoding: .utf8)

        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")
        #expect(FileManager.default.isExecutableFile(atPath: cli.path))
        let outputPath = root.appendingPathComponent("output.txt")
        let errorPath = root.appendingPathComponent("error.txt")
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        FileManager.default.createFile(atPath: errorPath.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputPath)
        let errors = try FileHandle(forWritingTo: errorPath)
        defer { try? output.close(); try? errors.close() }
        let stdin = Pipe()
        let process = Process()
        process.executableURL = cli
        process.arguments = [mode == "rpc" ? "--mode" : "--print"] +
            (mode == "rpc" ? ["rpc"] : []) +
            ["--offline", "--approve", "--provider", "anthropic", "--model", "claude-sonnet-4-5",
             "--no-session", "--no-skills", "--no-prompt-templates", "--nc"]
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment[ENV_AGENT_DIR] = agentDir.path
        environment["PI_EXTENSION_SDK_PATH"] = "/Users/miguel/cvs/pi/PiSwift/.build/out/Products/Debug"
        environment["PI_HYPERLINKS"] = "0"
        environment["PT3_READY"] = root.appendingPathComponent("ready").path
        environment["PT3_CLOSING"] = root.appendingPathComponent("closing").path
        environment["PT3_RELEASE"] = root.appendingPathComponent("release").path
        environment["PT3_FIRST_SIGNAL"] = root.appendingPathComponent("first-signal").path
        environment["PT3_SIGNAL_TRACE"] = "1"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        func send(_ signalNumber: Int32) {
            let line = String(format: "%.6f parent send signal=%d pid=%d\n",
                Date().timeIntervalSince1970, signalNumber, process.processIdentifier)
            errors.write(Data(line.utf8))
            let result = kill(process.processIdentifier, signalNumber)
            let sent = String(format: "%.6f parent kill result=%d errno=%d\n",
                Date().timeIntervalSince1970, result, errno)
            errors.write(Data(sent.utf8))
        }
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        if mode == "print" { stdin.fileHandleForWriting.closeFile() }
        if mode == "rpc" {
            try pt3WaitForFile(environment["PT3_READY"]!)
            send(pair.first)
        }
        try pt3WaitForFile(environment["PT3_CLOSING"]!)
        #expect(process.isRunning)
        if mode == "print" {
            send(pair.first)
        }
        // The child has entered its first signal handler before the second is sent.
        try pt3WaitForFile(environment["PT3_FIRST_SIGNAL"]!)
        #expect(process.isRunning)
        send(pair.second)
        do {
            try pt3WaitForExit(process)
        } catch {
            try? errors.synchronize()
            let trace = (try? String(contentsOf: errorPath, encoding: .utf8)) ?? "<unreadable>"
            print("PT3 signal failure trace:\n\(trace)")
            throw error
        }
        #expect(process.terminationStatus == pair.exitCode)
        if mode == "rpc" { stdin.fileHandleForWriting.closeFile() }
    }
}
