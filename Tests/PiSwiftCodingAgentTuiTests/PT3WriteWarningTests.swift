import Darwin
import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class PT3WriteTerminal: Terminal {
    var columns = 100
    var rows = 24
    var kittyProtocolActive = false
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {}
    func stop() {}
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) {}
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor @Suite("PT3 session write warning")
struct PT3WriteWarningTests {
    // v1.5.2 807a5c051, session-manager.ts:1189-1208.
    @Test("failed append produces one persistent warning row")
    func failedAppendWarnsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-write-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SessionManager.create(root.path, root.path)
        manager.appendMessage(.user(UserMessage(content: .text("first"))))
        let file = try #require(manager.getSessionFile())
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        let session = t3aSession(manager: manager)
        defer { session.dispose() }
        let tui = TUI(terminal: PT3WriteTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        #expect(chmod(file, 0o444) == 0)
        defer { _ = chmod(file, 0o644) }
        manager.appendMessage(.user(UserMessage(content: .text("failed"))))
        #expect(manager.getLastWriteError() != nil)
        mode.handleSessionEvent(.agentSettled(aborted: false))
        var transcript = mode.chatContainer.render(width: 160).joined(separator: "\n")
        #expect(transcript.contains("Session file could not be written:"))
        #expect(transcript.components(separatedBy: "Session file could not be written:").count == 2)
        mode.handleSessionEvent(.agentSettled(aborted: false))
        transcript = mode.chatContainer.render(width: 160).joined(separator: "\n")
        #expect(transcript.components(separatedBy: "Session file could not be written:").count == 2)
        let afterFailure = try Data(contentsOf: URL(fileURLWithPath: file))
        #expect(afterFailure == original)
    }
}
