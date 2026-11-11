import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

private final class PT3ChoiceTerminal: Terminal {
    var columns = 100
    var rows = 24
    var kittyProtocolActive = false
    var onInput: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { self.onInput = onInput }
    func stop() { onInput = nil }
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) {}
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
    func send(_ data: String) { onInput?(data) }
}

@MainActor @Suite("PT3 startup missing cwd", .serialized)
struct PT3MissingCwdStartupTests {
    // v1.5.2 4ea883792, main.ts:745-769.
    @Test("startup dialog maps all three choices", arguments: [
        (0, MissingSessionCwdChoice.continueHere),
        (1, MissingSessionCwdChoice.fork),
        (2, MissingSessionCwdChoice.cancel),
    ])
    func startupDialog(index: Int, expected: MissingSessionCwdChoice) async {
        let terminal = PT3ChoiceTerminal()
        let issue = SessionCwdIssue(sessionFile: "/tmp/old.jsonl", sessionCwd: "/tmp/gone",
            fallbackCwd: "/tmp/current")
        let choice = Task { await selectMissingSessionCwd(issue, settingsManager: .inMemory(),
            terminal: terminal, prepareTheme: false, startUI: { ui, _ in ui.start() }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while terminal.onInput == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(terminal.onInput != nil)
        guard terminal.onInput != nil else { return }
        for _ in 0..<index { terminal.send("\u{001B}[B") }
        terminal.send("\r")
        #expect(await choice.value == expected)
    }

    @Test("continue keeps the source, fork creates a new ID, cancel writes nothing")
    func startupChoiceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-choice-\(UUID())")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        let missing = root.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = SessionManager.create(missing.path, sessions.path)
        source.appendMessage(.user(UserMessage(content: .text("original"))))
        let sourcePath = try #require(source.getSessionFile())
        let original = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let issue = try #require(getMissingSessionCwdIssue(source, fallbackCwd: current.path))

        let continuedValue = try openMissingSessionCwdChoice(.continueHere, issue: issue,
            sessionDir: sessions.path)
        let continued = try #require(continuedValue)
        #expect(continued.getSessionId() == source.getSessionId())
        #expect(continued.getCwd() == current.path)
        #expect(continued.getSessionFile() == sourcePath)
        let afterContinue = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        #expect(afterContinue == original)

        let forkedValue = try openMissingSessionCwdChoice(.fork, issue: issue,
            sessionDir: sessions.path)
        let forked = try #require(forkedValue)
        let forkPath = try #require(forked.getSessionFile())
        #expect(forked.getSessionId() != source.getSessionId())
        #expect(forked.getCwd() == current.path)
        #expect(forkPath != sourcePath)
        #expect(FileManager.default.fileExists(atPath: forkPath))
        let afterFork = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        #expect(afterFork == original)
        let cancelled = try openMissingSessionCwdChoice(.cancel, issue: issue, sessionDir: sessions.path)
        #expect(cancelled == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path).filter { $0.hasSuffix(".jsonl") }
        #expect(files.count == 2)
    }
}
