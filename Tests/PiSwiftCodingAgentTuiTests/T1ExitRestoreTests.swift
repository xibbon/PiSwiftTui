import Darwin
import Foundation
import MiniTui
import Testing
@testable import PiSwiftCodingAgentTui

private final class T1ExitBundleMarker {}

private func t1ExitCloseOnExec(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFD)
    try #require(flags >= 0)
    try #require(fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0)
}

// Run only this test in the child. This uses the host's mounted TUI with a real terminal.
// It needs no fixture target or change to the production executable.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_T1_EXIT_FIXTURE"] != nil))
func t1EmergencyExitFixture() async throws {
    let mode = try #require(ProcessInfo.processInfo.environment["PI_T1_EXIT_FIXTURE"])
    let session = t3aSession()
    let terminal = ProcessTerminal()
    let tui = TUI(terminal: terminal)
    let renderer = mode.contains("alt")
        ? tui.enableAltScreen(options: interactiveAltScreenOptions()) : nil
    if renderer != nil { _ = tui.switchRenderer(to: .altScreen) }
    let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
    let host = InteractiveMode(session: session, tui: tui, editor: editor, renderer: renderer)
    host.registerTerminalIOErrorHandler()
    tui.start()
    await tui.waitForRender()
    terminal.write("\u{001B}[>3u\u{001B}[>4;2m")
    tui.setProgress(true)
    if mode.hasPrefix("stop") { tui.stop() }
    if mode.hasPrefix("restart") {
        tui.stop()
        tui.start()
        await tui.waitForRender()
        terminal.write("\u{001B}[>3u\u{001B}[>4;2m")
        tui.setProgress(true)
    }
    terminal.write("T1-HOST-EXIT\n")
    withExtendedLifetime(host) { Darwin.exit(0) }
}

@Suite("T1 host exit restore", .serialized)
struct T1ExitRestoreTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["exit-main", "exit-alt", "stop-alt", "restart-alt"])
    func processExitRestoresMountedHost(_ mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var master: Int32 = -1
        var slave: Int32 = -1
        var result: Int32 = -1
        var savedError: Int32 = 0
        for _ in 0..<8 {
            result = openpty(&master, &slave, nil, nil, nil)
            savedError = errno
            // XNU requests a new allocation with EREDRIVEOPEN after a pty allocation race.
            if result == 0 || savedError != -6 { break }
        }
        try #require(result == 0, "openpty failed: errno \(savedError)")
        defer { close(master); close(slave) }
        try t1ExitCloseOnExec(master)
        try t1ExitCloseOnExec(slave)
        var saved = termios()
        try #require(tcgetattr(slave, &saved) == 0)

        let process = Process()
        let runner = URL(fileURLWithPath: CommandLine.arguments[0])
        try #require(runner.lastPathComponent == "swiftpm-testing-helper",
                     "This subprocess test needs the Swift Package Manager test runner.")
        process.executableURL = runner
        let testBinary = try #require(Bundle(for: T1ExitBundleMarker.self).executableURL)
        process.arguments = ["--test-bundle-path", testBinary.path,
                             "--testing-library", "swift-testing", "--filter", "t1EmergencyExitFixture"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["TMUX", "STY", "ZELLIJ", "PI_TUI_WRITE_LOG"] { environment.removeValue(forKey: key) }
        environment["PI_T1_EXIT_FIXTURE"] = mode
        environment["TERM"] = "xterm-256color"
        environment["PI_OFFLINE"] = "1"
        environment["PI_PROGRAM_STATUS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning, "The exit fixture did not stop within 15 seconds.")
        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(text)")
        let marker = try #require(text.range(of: "T1-HOST-EXIT\n"), "\(text)")
        let afterExit = String(text[marker.upperBound...])
        let escape = "\u{001B}"
        let count = mode.hasPrefix("restart") ? 2 : 1
        for reset in ["[?2004l", "[<u", "[>4;0m"] {
            #expect(text.components(separatedBy: escape + reset).count - 1 == count, "\(text)")
        }
        if mode.hasPrefix("stop") {
            #expect(afterExit.isEmpty)
        } else {
            #expect(afterExit.contains(escape + "[?2004l"))
            #expect(afterExit.contains(escape + "[?25h"))
            if mode.contains("alt") {
                let pop = try #require(afterExit.range(of: escape + "[<u"))
                let leave = try #require(afterExit.range(of: escape + "[?1049l"))
                #expect(pop.lowerBound < leave.lowerBound)
                #expect(afterExit.hasSuffix(escape + "[?1049l" + escape + "[?25h"))
            } else {
                #expect(!afterExit.contains(escape + "[?1049l"))
            }
        }
        var final = termios()
        try #require(tcgetattr(slave, &final) == 0)
        // Darwin can set PENDIN after it restores cooked input.
        #expect(final.c_lflag & ~tcflag_t(PENDIN) == saved.c_lflag & ~tcflag_t(PENDIN))
        #expect(final.c_iflag == saved.c_iflag)
        #expect(final.c_oflag == saved.c_oflag)
        #expect(final.c_cflag == saved.c_cflag)
    }
}
