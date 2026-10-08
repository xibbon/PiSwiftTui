import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor private final class V110PadProbe: Component, OutputPaddingSetting {
    var changes: [Int] = []
    func setOutputPad(_ padding: Int) { changes.append(padding) }
    func render(width: Int) -> [String] { [] }
}

@MainActor @Suite(.serialized) struct V110TranscriptTests {
    private func host(_ session: AgentSession) -> InteractiveMode {
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        return InteractiveMode(session: session, tui: tui, editor: editor)
    }

    @Test func liveToolEndUsesRecordedDurationAndRebuildKeepsIt() throws {
        let session = t3aSession(); defer { session.dispose() }
        let mode = host(session)
        mode.handleSessionEvent(.agent(.toolExecutionStart(toolCallId: "clock", toolName: "bash", args: ["command": AnyCodable("sleep 4")])))
        mode.handleSessionEvent(.agent(.toolExecutionEnd(toolCallId: "clock", toolName: "bash", result: AgentToolResult(content: []), isError: false, durationMs: 4200)))
        #expect(toolTestText(mode.chatContainer).contains("Took 4.2s"))
        _ = session.sessionManager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "clock", toolName: "bash", content: [], isError: false, durationMs: 4200)))
        mode.renderInitialMessages()
        #expect(toolTestText(mode.chatContainer).contains("Took 4.2s"))
    }

    @Test(arguments: [false, true]) func excludedCommandIsStoredAndDimAfterRebuild(_ excluded: Bool) async throws {
        initTheme("dark")
        let session = t3aSession(); defer { session.dispose() }
        let mode = host(session)
        await mode.handleEditorSubmit((excluded ? "!!" : "!") + "printf 'v110-command-output'")
        let stored = session.sessionManager.getEntries().compactMap { entry -> [String: Any]? in
            guard case .message(let message) = entry, case .custom(let custom) = message.message else { return nil }
            guard custom.role == "bashExecution" else { return nil }
            return custom.payload?.value as? [String: Any]
        }
        let result = try #require(stored.last)
        #expect(result["output"] as? String == "v110-command-output")
        #expect(((result["excludeFromContext"] as? Bool) ?? false) == excluded)
        let color: ThemeColor = excluded ? .dim : .bashMode
        let header = theme.fg(color, theme.bold("$ printf 'v110-command-output'"))
        #expect(mode.chatContainer.render(width: 120).joined().contains(header))
        mode.renderInitialMessages()
        #expect(mode.chatContainer.render(width: 120).joined().contains(header))
        #expect(toolTestText(mode.chatContainer).contains("v110-command-output"))
    }

    @Test func storedComponentsUseConfiguredPadding() {
        let session = t3aSession(); defer { session.dispose() }
        session.settingsManager.setOutputPad(0)
        _ = session.sessionManager.appendMessage(makeBashExecutionAgentMessage(BashExecutionMessage(command: "pwd", output: "output", exitCode: 0, cancelled: false, truncated: false)))
        _ = session.sessionManager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "pad", toolName: "unknown", content: [.text(TextContent(text: "tool output"))], isError: false)))
        let mode = host(session)
        mode.renderInitialMessages()
        let lines = mode.chatContainer.render(width: 120).map(toolTestPlain)
        #expect(lines.contains { $0.hasPrefix("$ pwd") })
        #expect(lines.contains { $0.hasPrefix("output") })
        #expect(lines.contains { $0.hasPrefix("tool output") })
    }
    @Test func settingsPaddingUpdatesChildrenAndRebuildsMessages() async throws {
        let session = t3aSession(); defer { session.dispose() }
        session.settingsManager.setOutputPad(0)
        _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text("padding message"))))
        let mode = host(session)
        mode.renderInitialMessages()
        let probe = V110PadProbe()
        mode.chatContainer.addChild(probe)
        await mode.handleEditorSubmit("/settings")
        let selector = try #require(mode.editorContainer?.children.first as? SettingsSelectorComponent)
        selector.getSettingsList().selectItem(id: "output-padding")
        selector.getSettingsList().handleInput("\r")
        #expect(probe.changes == [1])
        #expect(session.settingsManager.getOutputPad() == 1)
        #expect(mode.tuiConfiguration.outputPad == 1)
        #expect(mode.chatContainer.render(width: 120).map(toolTestPlain).contains { $0.hasPrefix(" padding message") })
        selector.getSettingsList().handleInput("\u{1B}")
    }

}
