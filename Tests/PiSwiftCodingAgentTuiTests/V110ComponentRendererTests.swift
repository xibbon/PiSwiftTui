import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct V110ComponentRendererTests {
    private func textLines(_ component: Component) -> [String] {
        component.render(width: 60).map {
            toolTestPlain($0).replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }.filter { $0.range(of: "[\\w$(]", options: .regularExpression) != nil }
    }

    @Test(arguments: 0..<5) func outputPaddingChangesEachTextLine(_ kind: Int) {
        let ui = TUI(terminal: ToolTestTerminal())
        let component: any Component & OutputPaddingSetting
        switch kind {
        case 0:
            let bash = BashExecutionComponent(command: "pwd", ui: ui, outputPad: 0)
            bash.appendOutput("/tmp")
            bash.setComplete(exitCode: 1, cancelled: false)
            component = bash
        case 1, 2:
            let tool = ToolExecutionComponent(toolName: "custom_tool", args: [:], options: ToolExecutionOptions(outputPad: 0), customTool: kind == 1 ? toolTestDefinition() : nil, ui: ui)
            tool.updateResult(toolTestResult("ok"))
            component = tool
        case 3:
            let tool = ToolExecutionComponent(toolName: "edit", args: ["path": AnyCodable("file.txt"), "oldText": AnyCodable("old"), "newText": AnyCodable("new")], options: ToolExecutionOptions(outputPad: 0), ui: ui, cwd: "/")
            tool.updateResult(toolTestResult("Could not find old text", tool: "edit", isError: true))
            component = tool
        default:
            component = CompactionSummaryMessageComponent(message: CompactionSummaryMessage(summary: "summary", tokensBefore: 10, timestamp: 0), outputPad: 0)
        }
        let initial = textLines(component)
        #expect(!initial.isEmpty)
        #expect(initial.allSatisfy { !$0.hasPrefix(" ") })
        component.setOutputPad(1)
        #expect(textLines(component) == initial.map { " " + $0 })
    }

    @Test func bashPreviewUsesRenderWidthAndResizes() {
        let terminal = ToolTestTerminal()
        terminal.columns = 200
        let bash = BashExecutionComponent(command: "pwd", ui: TUI(terminal: terminal))
        bash.appendOutput(String(repeating: "x", count: 150) + "\n" + String(repeating: "x", count: 150))
        bash.setComplete(exitCode: 0, cancelled: false)
        #expect(bash.render(width: 80).allSatisfy { visibleWidth($0) <= 80 })
        let wide = bash.render(width: 200)
        let narrow = bash.render(width: 60)
        #expect(wide.allSatisfy { visibleWidth($0) <= 200 })
        #expect(narrow.allSatisfy { visibleWidth($0) <= 60 })
        #expect(narrow.count > wide.count)
    }

    @Test func bashPreviewFitsNarrowWidthFromConstruction() {
        let terminal = ToolTestTerminal()
        terminal.columns = 200
        let bash = BashExecutionComponent(command: "pwd", ui: TUI(terminal: terminal))
        bash.appendOutput(String(repeating: "x", count: 150) + "\n" + String(repeating: "x", count: 150) + "\n")
        bash.setComplete(exitCode: 0, cancelled: false)
        #expect(bash.render(width: 80).allSatisfy { visibleWidth($0) <= 80 })
    }

    @Test func hookDefaultAndExtensionReceivePadding() {
        let message = HookMessage(customType: "probe", content: .text("message"), display: true)
        let row = HookMessageComponent(message: message, outputPad: 0)
        let initial = textLines(row)
        row.setOutputPad(1)
        #expect(textLines(row) == initial.map { " " + $0 })
        let custom = HookMessageComponent(message: message, customRenderer: { _, options, _ in
            MainActor.assumeIsolated { Text("pad=\(options.outputPad)", paddingX: 0, paddingY: 0) }
        }, outputPad: 0)
        #expect(toolTestText(custom).contains("pad=0"))
        custom.setOutputPad(1)
        #expect(toolTestText(custom).contains("pad=1"))
    }

    @Test(arguments: [false, true]) func branchAndSkillPaddingChanges(_ skill: Bool) {
        let row: any Component & OutputPaddingSetting
        if skill {
            row = SkillInvocationMessageComponent(skillBlock: ParsedSkillBlock(name: "test", location: "/tmp/test", content: "detail"), outputPad: 0)
        } else {
            row = BranchSummaryMessageComponent(message: BranchSummaryMessage(summary: "detail", timestamp: 0), outputPad: 0)
        }
        let initial = textLines(row)
        #expect(!initial.isEmpty)
        #expect(initial.allSatisfy { !$0.hasPrefix(" ") })
        row.setOutputPad(1)
        #expect(textLines(row) == initial.map { " " + $0 })
        row.setOutputPad(0)
        #expect(textLines(row) == initial)
    }

    @Test func customEntryPaddingSetterRebuildsRenderer() throws {
        let session = SessionManager.inMemory()
        let id = session.appendCustomEntry("probe", ["value": "data"])
        let stored = try #require(session.getEntry(id))
        guard case .custom(let entry) = stored else {
            Issue.record("Expected custom entry")
            return
        }
        let state = V110EntryRenderState()
        let row = CustomEntryComponent(entry: entry, renderer: { entry, options, _ in
            MainActor.assumeIsolated { () -> Text in
                state.calls += 1
                return Text("\(entry.customType) expanded=\(options.expanded) call=\(state.calls)", paddingX: 0, paddingY: 0)
            }
        }, outputPad: 0)
        #expect(state.calls == 1)
        row.setExpanded(true)
        #expect(state.calls == 2)
        row.setOutputPad(1)
        #expect(state.calls == 3)
        #expect(toolTestText(row).contains("probe expanded=true call=3"))
    }

    @Test func settingsDescribeCommandAndToolPadding() {
        let config = SettingsConfig(autoCompact: true, showImages: true, autoResizeImages: true, blockImages: false,
            enableSkillCommands: true, steeringMode: "one-at-a-time", followUpMode: "one-at-a-time", transport: .sse,
            thinkingLevel: .high, availableThinkingLevels: [.off, .high], currentTheme: "dark", availableThemes: ["dark"],
            hideThinkingBlock: false, showCacheMissNotices: true, collapseChangelog: false, quietStartup: .off,
            doubleEscapeAction: "tree", editorPaddingX: 0, autocompleteMaxVisible: 5, tuiMode: .regular,
            fullscreenScrollbar: .auto, mouseWheelStep: 1, mermaidEnabled: true, mermaidRenderWhileStreaming: true,
            latexEnabled: false, outputPad: 1)
        let callbacks = SettingsCallbacks(onAutoCompactChange: { _ in }, onShowImagesChange: { _ in }, onAutoResizeImagesChange: { _ in },
            onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in }, onSteeringModeChange: { _ in },
            onFollowUpModeChange: { _ in }, onTransportChange: { _ in }, onThinkingLevelChange: { _ in },
            onThemeChange: { _ in }, onHideThinkingBlockChange: { _ in }, onShowCacheMissNoticesChange: { _ in },
            onCollapseChangelogChange: { _ in }, onQuietStartupChange: { _ in }, onDoubleEscapeActionChange: { _ in },
            onEditorPaddingXChange: { _ in }, onAutocompleteMaxVisibleChange: { _ in }, onTuiModeChange: { _ in },
            onFullscreenScrollbarChange: { _ in }, onMouseWheelStepChange: { _ in }, onMermaidEnabledChange: { _ in },
            onMermaidRenderWhileStreamingChange: { _ in }, onLatexEnabledChange: { _ in }, onOutputPadChange: { _ in }, onCancel: {})
        let list = SettingsSelectorComponent(config: config, callbacks: callbacks).getSettingsList()
        list.selectItem(id: "output-padding")
        #expect(toolTestText(list, width: 160).contains("Horizontal padding for messages, tool output, and command output"))
    }

    @Test func htmlContextUsesDefaultDurationAndPadding() async {
        var seen = false
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/", getRenderers: { _ in
            ToolRenderers(renderResult: { _, options, _, context in
                seen = true
                #expect(context.durationMs == nil)
                #expect(context.outputPad == 1)
                #expect(options.durationMs == nil)
                #expect(options.outputPad == 1)
                return Text("result", paddingX: 0, paddingY: 0)
            })
        })
        _ = await renderer.renderResult(toolCallId: "id", name: "probe", result: [], details: nil, isError: false)
        #expect(seen)
    }

    @Test(arguments: [false, true]) func bashColorStaysSetAfterOutput(_ excluded: Bool) {
        let bash = BashExecutionComponent(command: "pwd", ui: TUI(terminal: ToolTestTerminal()), excludeFromContext: excluded)
        let color: ThemeColor = excluded ? .dim : .bashMode
        func check() {
            let lines = bash.render(width: 60)
            let prefix = String(theme.fg(color, "X").prefix(while: { $0 != "X" }))
            #expect(lines[1].contains(prefix))
            #expect(lines.last?.contains(prefix) == true)
            #expect(lines.contains { $0.contains(theme.fg(color, theme.bold("$ pwd"))) })
            let spinner = lines.first { toolTestPlain($0).contains("Running...") }
            #expect(spinner != nil)
            // Loader puts the spinner color before the muted message color.
            #expect(spinner?.contains(String(theme.fg(color, "X").prefix(while: { $0 != "X" }))) == true)
        }
        check()
        bash.appendOutput("/tmp")
        check()
        bash.setComplete(exitCode: 0, cancelled: false)
    }

    @Test(arguments: [false, true]) func finalRecordedDurationWorksLiveAndRestored(_ live: Bool) {
        let row = ToolExecutionComponent(toolName: "bash", args: ["command": AnyCodable("sleep 4")], ui: TUI(terminal: ToolTestTerminal()))
        if live { row.markExecutionStarted() }
        row.updateResult(ToolResultMessage(toolCallId: "id", toolName: "bash", content: [], isError: false, durationMs: 4200))
        #expect(toolTestText(row).contains("Took 4.2s"))
    }

    @Test func contextDefaultsAndPartialDuration() throws {
        let defaults = ToolRenderContext()
        #expect(defaults.durationMs == nil)
        #expect(defaults.outputPad == 1)
        var recorded: [(Int?, Int)] = []
        let renderers = ToolRenderers(renderResult: { _, options, _, context in
            recorded.append((context.durationMs, context.outputPad))
            #expect(options.durationMs == context.durationMs)
            #expect(options.outputPad == context.outputPad)
            return Text("ok")
        })
        let row = ToolExecutionComponent(toolName: "probe", args: [:], options: ToolExecutionOptions(outputPad: 0), renderers: renderers, ui: TUI(terminal: ToolTestTerminal()))
        let result = ToolResultMessage(toolCallId: "id", toolName: "probe", content: [], isError: false, durationMs: 4200)
        row.updateResult(result, isPartial: true)
        #expect(recorded.last?.0 == nil)
        row.updateResult(result)
        #expect(recorded.last?.0 == 4200)
        row.setOutputPad(1)
        #expect(recorded.last?.1 == 1)
    }

    @Test func extensionResultGetsDurationAndPadding() {
        var definition = toolTestDefinition("probe")
        definition.renderResult = { _, options, _ in
            MainActor.assumeIsolated { Text("duration=\(options.durationMs ?? -1) pad=\(options.outputPad)", paddingX: 0, paddingY: 0) }
        }
        let row = ToolExecutionComponent(toolName: "probe", args: [:], options: ToolExecutionOptions(outputPad: 0), customTool: definition, ui: TUI(terminal: ToolTestTerminal()))
        row.updateResult(ToolResultMessage(toolCallId: "id", toolName: "probe", content: [], isError: false, durationMs: 4200))
        #expect(toolTestText(row).contains("duration=4200 pad=0"))
        row.setOutputPad(1)
        #expect(toolTestText(row).contains("duration=4200 pad=1"))
    }

    @Test func partialShellErrorKeepsTookLabel() throws {
        let renderers = createShellRenderers(prompt: "$")
        let state = ToolRenderState()
        let context = ToolRenderContext(state: state, executionStarted: true, isPartial: true, isError: true, durationMs: 4200)
        _ = try renderers.renderCall?([:], theme, context)
        let result = try #require(try renderers.renderResult?(AgentToolResult(content: [], details: nil), RenderResultOptions(expanded: false, isPartial: true), theme, context))
        #expect(toolTestText(result).contains("Took"))
        #expect(!toolTestText(result).contains("Elapsed"))
        #expect(!toolTestText(result).contains("4.2s"))
    }
}

@MainActor private final class V110EntryRenderState {
    var calls = 0
}
