import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class PortResourceLoader: ResourceLoader {
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

private final class PortTerminal: Terminal {
    var writes = ""
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var input: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { input = onInput }
    func stop() {}
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) { writes += data }
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

private func portSession() -> AgentSession {
    let settings = SettingsManager.inMemory()
    let agent = Agent()
    agent.model = Model(id: "test", name: "test", api: .anthropicMessages, provider: "anthropic", baseUrl: "https://example.invalid", reasoning: true, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 200_000, maxTokens: 20_000)
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: .inMemory("/tmp"), settingsManager: settings, resourceLoader: PortResourceLoader(), modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)))
}

private func diagnosticMessage(count: Int = 1) -> AssistantMessage {
    let drops = (0..<count).map { index in
        ["type": "thinking_dropped", "reason": "prefix_binding_mismatch", "path": "messages.2.content.\(index)"]
    }
    return AssistantMessage(content: [.text(TextContent(text: "survived"))], api: .anthropicMessages, provider: "anthropic", model: "test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop,
                     diagnostics: [AssistantMessageDiagnostic(type: "anthropic_input_transformations", details: ["transformations": AnyCodable(drops)])])
}

@MainActor
@Suite struct InteractiveV085Tests {
    @Test func startupSubmitRestoresText() {
        let session = portSession(); defer { session.dispose() }
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.handleStartupSubmit("early prompt")
        #expect(editor.getText() == "early prompt")
        #expect(mode.chatContainer.render(width: 120).joined().contains("Startup is still in progress"))
        #expect(session.agent.state.messages.isEmpty)
    }

    @Test func turnStartsEmbeddedIndicatorOnlyOnce() {
        let session = portSession(); defer { session.dispose() }
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory(), embedWorkingStatus: true)
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.handleAgentEvent(.agentStart)
        #expect(mode.loadingAnimation == nil)
        mode.handleAgentEvent(.turnStart)
        let indicator = mode.loadingAnimation
        #expect(indicator != nil)
        #expect(mode.activeWorkingIndicatorEmbedded)
        #expect(editor.render(width: 80).joined().contains("Working"))
        mode.handleAgentEvent(.turnStart)
        #expect(mode.loadingAnimation === indicator)
        mode.handleAgentEvent(.agentEnd(messages: []))
        #expect(mode.loadingAnimation == nil)
        #expect(!editor.render(width: 80).joined().contains("Working"))
    }

    @Test func editorWithoutOptInKeepsStandaloneIndicator() {
        let session = portSession(); defer { session.dispose() }
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.handleAgentEvent(.turnStart)
        #expect(mode.loadingAnimation != nil)
        #expect(!mode.activeWorkingIndicatorEmbedded)
        mode.handleAgentEvent(.agentEnd(messages: []))
    }

    @Test func thinkingToggleRetainsPendingToolAndBashOutput() {
        let session = portSession(); defer { session.dispose() }
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        let tool = ToolExecutionComponent(toolName: "bash", args: ["command": AnyCodable("echo first; sleep 10")], options: ToolExecutionOptions(showImages: false), ui: tui)
        tool.updateResult(ToolResultMessage(toolCallId: "test", toolName: "bash", content: [.text(TextContent(text: "first"))], isError: false), isPartial: true)
        mode.chatContainer.addChild(tool)
        let bash = BashExecutionComponent(command: "echo pending", ui: tui)
        bash.appendOutput("pending output")
        mode.chatContainer.addChild(bash)
        mode.toggleThinkingBlockVisibility()
        #expect(mode.chatContainer.children.contains { $0 === tool })
        #expect(mode.chatContainer.children.contains { $0 === bash })
        #expect(mode.chatContainer.render(width: 120).joined().contains("first"))
        #expect(mode.chatContainer.render(width: 120).joined().contains("pending output"))
    }

    @Test func diagnosticsRespectSettingAndSurviveRebuild() {
        let session = portSession(); defer { session.dispose() }
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        let message = diagnosticMessage()
        session.settingsManager.setShowCacheMissNotices(false)
        mode.maybeShowAssistantDiagnostics(message)
        #expect(mode.chatContainer.children.isEmpty)
        session.settingsManager.setShowCacheMissNotices(true)
        mode.maybeShowAssistantDiagnostics(message)
        let expected = "Anthropic dropped 1 thinking block (details in session)"
        #expect(mode.chatContainer.render(width: 160).joined().contains(expected))
        _ = session.sessionManager.appendMessage(.assistant(message))
        mode.renderInitialMessages()
        #expect(mode.chatContainer.render(width: 160).joined().contains(expected))
    }

    @Test func thinkingCommandIsSessionOnlyUntilSaved() {
        let session = portSession(); defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        session.settingsManager.setDefaultThinkingLevel("medium")
        mode.handleThinkingCommand("high")
        #expect(session.agent.state.thinkingLevel == .high)
        #expect(session.settingsManager.getDefaultThinkingLevel() == "medium")
        mode.selectThinkingLevel(.low, persist: true)
        #expect(session.settingsManager.getDefaultThinkingLevel() == "low")
        mode.handleThinkingCommand("bogus")
        #expect(mode.chatContainer.render(width: 160).joined().contains("Unknown thinking level"))
        #expect(session.agent.state.thinkingLevel == .low)
    }

    @Test func summaryCostsUseAllBilledTokensAndHideSubCentCosts() {
        let usage = Usage(input: 100, output: 20, cacheRead: 30, cacheWrite: 50, totalTokens: 200, cost: UsageCost(total: 0.02))
        #expect(summaryCostNotice(usage: usage) == "Compaction: 200 tokens billed (~$0.02)")
        #expect(summaryCostNotice(usage: Usage(input: 2, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 2), branch: true) == "Branch summary: 2 tokens billed")
    }

    @Test func contextEntriesKeepLatestCompactionAndRetainedBranch() {
        let manager = SessionManager.inMemory("/tmp")
        _ = manager.appendMessage(.user(UserMessage(content: .text("old"))))
        let keep = manager.appendMessage(.user(UserMessage(content: .text("keep"))))
        _ = manager.appendCompaction("summary", keep, 100, usage: Usage(input: 2, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 2))
        _ = manager.appendMessage(.user(UserMessage(content: .text("new"))))
        let entries = interactiveContextEntries(manager)
        #expect(entries.count == 3)
        guard case .compaction = entries.first else { Issue.record("Compaction must lead context"); return }
        #expect(entries[1].id == keep)
    }

    @Test func thinkingDropNoticeSuppressesCumulativeRepeat() {
        let session = portSession(); defer { session.dispose() }
        session.settingsManager.setShowCacheMissNotices(true)
        let mode = InteractiveMode(session: session, version: "test")
        let first = diagnosticMessage()
        mode.maybeShowAssistantDiagnostics(first)
        _ = session.sessionManager.appendMessage(.assistant(first))
        mode.maybeShowAssistantDiagnostics(first)
        let increased = diagnosticMessage(count: 2)
        mode.maybeShowAssistantDiagnostics(increased)
        let output = mode.chatContainer.render(width: 160).joined(separator: "\n")
        #expect(output.components(separatedBy: "Anthropic dropped").count == 3)
        #expect(output.contains("Anthropic dropped 2 thinking blocks"))
        #expect(!output.contains("prefix_binding_mismatch"))
    }

    @Test func boundaryCompactionReplaysInOrderAndSuppressesDuplicateEntryEvent() throws {
        let session = portSession(); defer { session.dispose() }
        let manager = session.sessionManager
        _ = manager.appendMessage(.user(UserMessage(content: .text("DISCARDED_SENTINEL"))))
        let kept = manager.appendMessage(.user(UserMessage(content: .text("KEPT_SENTINEL"))))
        let compactionID = manager.appendCompaction("SUMMARY_SENTINEL", kept, 100)
        let afterID = manager.appendCustomMessage("notice", .text("AFTER_SENTINEL"), true)
        let branch = manager.getBranch()
        let compaction = try #require(branch.first { $0.id == compactionID })
        let after = try #require(branch.first { $0.id == afterID })
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.handleSessionEvent(.entryAppended(compaction))
        mode.handleSessionEvent(.entryAppended(after))
        let output = mode.chatContainer.render(width: 160).joined(separator: "\n")
        #expect(!output.contains("DISCARDED_SENTINEL"))
        let keptRange = try #require(output.range(of: "KEPT_SENTINEL"))
        let summaryRange = try #require(output.range(of: "[compaction]"))
        let afterRange = try #require(output.range(of: "AFTER_SENTINEL"))
        #expect(keptRange.lowerBound < summaryRange.lowerBound)
        #expect(summaryRange.lowerBound < afterRange.lowerBound)
        #expect(output.components(separatedBy: "AFTER_SENTINEL").count == 2)
    }

    @Test func replayRendersPersistedCacheWarmingUsageOnce() {
        let session = portSession(); defer { session.dispose() }
        session.settingsManager.setShowCacheMissNotices(true)
        let usage = Usage(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1, cost: UsageCost(total: 0.002))
        _ = session.sessionManager.appendUsage("cache_warm", "anthropic", "test", usage, note: "test")
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.renderInitialMessages()
        let output = mode.chatContainer.render(width: 160).joined(separator: "\n")
        #expect(output.components(separatedBy: "Cache warmed (test): $0.002").count == 2)
    }

    @Test func copyCommandPrefersExplicitFullscreenSelection() async {
        let session = portSession(); defer { session.dispose() }
        let terminal = PortTerminal()
        let tui = TUI(terminal: terminal)
        var copied: [String] = []
        let renderer = tui.enableAltScreen(options: AltScreenRendererOptions(copyOnSelect: false, copySelection: { copied.append($0); return true }))
        let document = Text("alpha\nbeta", paddingX: 0, paddingY: 0)
        renderer.setLayoutRoot(ScrollView(document, options: ScrollViewOptions(follow: .end, primary: true)))
        _ = tui.switchRenderer(to: .altScreen)
        tui.start()
        defer { tui.stop() }
        await tui.waitForRender()
        terminal.input?("\u{1B}[<0;1;1M")
        terminal.input?("\u{1B}[<32;4;2M")
        terminal.input?("\u{1B}[<0;4;2m")
        await Task.yield()
        await tui.waitForRender()
        await Task.yield()
        await tui.waitForRender()
        #expect(renderer.hasActiveSelection())
        #expect(copied.isEmpty)
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor, renderer: renderer)
        mode.handleCopyCommand(preferSelection: true)
        for _ in 0..<50 where copied.isEmpty { await Task.yield() }
        #expect(copied == ["alpha\nbeta"])
        #expect(!mode.chatContainer.render(width: 80).joined().contains("No agent messages"))
    }

    @Test(arguments: [FullscreenExitOutput.transcript, .resumeHint])
    func fullscreenExitOutputMatchesSetting(_ output: FullscreenExitOutput) async {
        let session = portSession(); defer { session.dispose() }
        let terminal = PortTerminal()
        let tui = TUI(terminal: terminal)
        let renderer = tui.enableAltScreen()
        renderer.setLayoutRoot(Text("TRANSCRIPT_SENTINEL", paddingX: 0, paddingY: 0))
        _ = tui.switchRenderer(to: .altScreen)
        tui.start()
        await tui.waitForRender()
        terminal.writes = ""
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor, renderer: renderer)
        mode.stopInteractiveTui(output)
        #expect(terminal.writes.contains("TRANSCRIPT_SENTINEL") == (output == .transcript))
        #expect(terminal.writes.contains("Resume this session with:") == (output == .resumeHint))
    }

    @Test func completedCompactionRendersRetainedMessagesThenSummaryAndCost() throws {
        let session = portSession(); defer { session.dispose() }
        session.settingsManager.setShowCacheMissNotices(true)
        let manager = session.sessionManager
        _ = manager.appendMessage(.user(UserMessage(content: .text("discarded"))))
        let keep = manager.appendMessage(.user(UserMessage(content: .text("retained"))))
        let usage = Usage(input: 100, output: 20, cacheRead: 0, cacheWrite: 0, totalTokens: 120, cost: UsageCost(total: 0.05))
        _ = manager.appendCompaction("SUMMARY_SENTINEL", keep, 500, usage: usage)
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.handleSessionEvent(.autoCompactionEnd(result: CompactionResult(summary: "SUMMARY_SENTINEL", firstKeptEntryId: keep, tokensBefore: 500, usage: usage), aborted: false, willRetry: false))
        let output = mode.chatContainer.render(width: 160).joined(separator: "\n")
        #expect(!output.contains("discarded"))
        #expect(output.contains("Compaction: 120 tokens billed (~$0.05)"))
        let retained = try #require(output.range(of: "retained"))
        let summary = try #require(output.range(of: "[compaction]"))
        #expect(retained.lowerBound < summary.lowerBound)
        session.settingsManager.setShowCacheMissNotices(false)
        mode.renderInitialMessages()
        #expect(!mode.chatContainer.render(width: 160).joined().contains("tokens billed"))
    }

    @Test func branchSummaryCostSurvivesRebuild() {
        let session = portSession(); defer { session.dispose() }
        session.settingsManager.setShowCacheMissNotices(true)
        _ = session.sessionManager.appendBranchSummary("from", "branch", usage: Usage(input: 3, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 3))
        let tui = TUI(terminal: PortTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.renderInitialMessages()
        #expect(mode.chatContainer.render(width: 160).joined().contains("Branch summary: 3 tokens billed"))
    }

    @Test func managedToolWarningsHaveWarningPrefix() {
        let session = portSession(); defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        mode.showManagedToolStatus(ToolStatus(type: .warning, message: "offline"))
        #expect(mode.chatContainer.render(width: 80).joined().contains("Warning: offline"))
    }
}
