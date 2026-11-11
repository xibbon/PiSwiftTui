import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct PT2PendingBashTests {
    @Test func ctrlOExpandsPendingBashAndSettleMovesItToChat() {
        let session = t3aSession()
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        let pending = Container()
        mode.pendingMessagesContainer = pending
        let row = BashExecutionComponent(command: "echo hi", ui: tui)
        row.appendOutput((0..<30).map(String.init).joined(separator: "\n"))
        row.setComplete(exitCode: 0, cancelled: false)
        mode.pendingBashComponents.append(row)
        mode.updatePendingMessagesDisplay()
        #expect(pending.children.contains { $0 === row })
        #expect(!row.render(width: 80).joined().contains("\n0\n"))
        mode.setToolsExpanded(true)
        #expect(row.render(width: 80).joined(separator: "\n").contains("0"))
        mode.updatePendingMessagesDisplay()
        #expect(pending.children.contains { $0 === row })
        mode.flushPendingBashComponents()
        #expect(mode.pendingBashComponents.isEmpty)
        #expect(!pending.children.contains { $0 === row })
        #expect(mode.chatContainer.children.contains { $0 === row })
    }

    @Test func sessionReplacementDropsOldPendingBash() async {
        let old = t3aSession()
        let next = t3aSession()
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: old, tui: tui, editor: editor)
        let pending = Container()
        mode.pendingMessagesContainer = pending
        let row = BashExecutionComponent(command: "old", ui: tui)
        mode.pendingBashComponents.append(row)
        mode.updatePendingMessagesDisplay()
        await mode.rebindSession(next)
        #expect(mode.pendingBashComponents.isEmpty)
        #expect(!mode.chatContainer.children.contains { $0 === row })
    }
}
