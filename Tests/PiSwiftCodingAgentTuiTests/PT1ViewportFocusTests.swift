import Foundation
import MiniTui
import PiSwiftAI
@testable import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class PT1ViewportTerminal: Terminal {
    var columns = 80
    var rows = 8
    var kittyProtocolActive = false
    private var input: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { input = onInput }
    func stop() { input = nil }
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) {}
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
    func send(_ data: String) { input?(data) }
}

@MainActor @Suite(.serialized)
struct PT1ViewportFocusTests {
    private func fullscreen(_ selector: Component) -> (TUI, AltScreenRenderer, PT1ViewportTerminal) {
        let terminal = PT1ViewportTerminal()
        let content = Container()
        for index in 0..<30 { content.addChild(Text("transcript \(index)", paddingX: 0, paddingY: 0)) }
        content.addChild(selector)
        let scrollView = ScrollView(content, options: ScrollViewOptions(primary: true))
        let tui = TUI(terminal: terminal)
        let renderer = tui.enableAltScreen()
        renderer.setLayoutRoot(scrollView)
        #expect(tui.switchRenderer(to: .altScreen))
        tui.start()
        return (tui, renderer, terminal)
    }

    private func pageInputStaysWithFocusedSelector(_ selector: Component,
        selectionAfterPage: () -> Bool) async {
        let (tui, renderer, terminal) = fullscreen(selector)
        defer { tui.stop() }
        await tui.waitForRender()
        terminal.send("\u{1B}[6~")
        await Task.yield()
        await tui.waitForRender()
        let scrolledTop = renderer.viewportTop
        #expect(scrolledTop > 0)
        tui.setFocus(selector)
        #expect(selector.capturesViewportInput)
        terminal.send("\u{1B}[5~")
        await Task.yield()
        await tui.waitForRender()
        #expect(renderer.viewportTop == scrolledTop)
        terminal.send("\u{1B}[6~")
        await Task.yield()
        await tui.waitForRender()
        #expect(renderer.viewportTop == scrolledTop)
        #expect(selectionAfterPage())
    }

    // v1.5.2 PT1: tui-alt-screen.test.ts:2205 and session-selector.ts page ownership.
    @Test func sessionSelectorOwnsPageKeysInFullscreen() async throws {
        let sessions = (0..<18).map { index in
            SessionInfo(path: "/tmp/session-\(index).jsonl", id: "session-\(index)", cwd: "/tmp",
                name: "Session \(index)", created: .distantPast, modified: .now,
                messageCount: 1, firstMessage: "hello", allMessagesText: "hello")
        }
        var selected: String?
        let selector = SessionSelectorComponent(currentSessionsLoader: { _ in sessions },
            allSessionsLoader: { _ in sessions }, onSelect: { selected = $0 },
            onCancel: {}, onExit: {}, requestRender: {})
        defer { selector.closeSelector() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !toolTestText(selector).contains("Session 0") && ContinuousClock.now < deadline { await Task.yield() }
        try #require(toolTestText(selector).contains("Session 0"))
        await pageInputStaysWithFocusedSelector(selector) {
            selector.handleInput("\r")
            return selected == "/tmp/session-5.jsonl"
        }
    }

    // v1.5.2 PT1: tui-alt-screen.test.ts:2205 and tree-selector.ts page ownership.
    @Test func treeSelectorOwnsPageKeysInFullscreen() async {
        let tree = (0..<18).map { index in
            SessionTreeNode(entry: .message(SessionMessageEntry(id: "node-\(index)",
                timestamp: "2026-11-11T12:00:00.000Z",
                message: .user(UserMessage(content: .text("node \(index)"))))), children: [], label: nil)
        }
        let selector = TreeSelectorComponent(tree: tree, currentLeafId: "node-0",
            terminalHeight: 12, onSelect: { _ in }, onCancel: {})
        await pageInputStaysWithFocusedSelector(selector) {
            selector.getSelectedEntryId() == "node-6"
        }
    }
}
