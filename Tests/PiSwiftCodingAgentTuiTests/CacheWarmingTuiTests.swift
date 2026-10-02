import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private struct CacheFooterData: FooterDataProviding {
    func getGitBranch() -> String? { nil }
    func getExtensionStatuses() -> [String: String] { [:] }
    func onBranchChange(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void { {} }
}

private func cacheTuiSession() -> AgentSession {
    let model = Model(id: "test", name: "test", api: .anthropicMessages, provider: "anthropic",
                      baseUrl: "https://example.invalid", reasoning: false, input: [.text],
                      cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                      contextWindow: 1000, maxTokens: 100)
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model)))
    return AgentSession(config: AgentSessionConfig(
        agent: agent, sessionManager: .inMemory("/tmp"), settingsManager: .inMemory(),
        resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: .inMemory())),
        modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    ))
}

@MainActor
@Suite("Cache warming TUI")
struct CacheWarmingTuiTests {
    @Test func selectorCyclesCacheWarmingMode() {
        let config = SettingsConfig(
            autoCompact: true, showImages: false, autoResizeImages: true, blockImages: false,
            enableSkillCommands: true, steeringMode: "all", followUpMode: "all", transport: .sse,
            cacheWarmingMode: .off, thinkingLevel: .off, availableThinkingLevels: [.off],
            currentTheme: "dark", availableThemes: ["dark"], hideThinkingBlock: false,
            // Upstream v1.0.0: quietStartup now uses QuietStartup.
            showCacheMissNotices: true, collapseChangelog: false, quietStartup: .off,
            doubleEscapeAction: "tree", editorPaddingX: 0, autocompleteMaxVisible: 5,
            tuiMode: .regular, fullscreenScrollbar: .auto, mouseWheelStep: 3,
            mermaidEnabled: false, mermaidRenderWhileStreaming: false, latexEnabled: false, outputPad: 1
        )
        var modes: [CacheWarmingMode] = []
        let callbacks = SettingsCallbacks(
            onAutoCompactChange: { _ in }, onShowImagesChange: { _ in }, onAutoResizeImagesChange: { _ in },
            onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in },
            onSteeringModeChange: { _ in }, onFollowUpModeChange: { _ in }, onTransportChange: { _ in },
            onCacheWarmingModeChange: { modes.append($0) }, onThinkingLevelChange: { _ in },
            onThemeChange: { _ in }, onHideThinkingBlockChange: { _ in },
            onShowCacheMissNoticesChange: { _ in }, onCollapseChangelogChange: { _ in },
            onQuietStartupChange: { _ in }, onDoubleEscapeActionChange: { _ in },
            onEditorPaddingXChange: { _ in }, onAutocompleteMaxVisibleChange: { _ in },
            onTuiModeChange: { _ in }, onFullscreenScrollbarChange: { _ in },
            onMouseWheelStepChange: { _ in }, onMermaidEnabledChange: { _ in },
            onMermaidRenderWhileStreamingChange: { _ in }, onLatexEnabledChange: { _ in },
            onOutputPadChange: { _ in }, onCancel: {}
        )
        let list = SettingsSelectorComponent(config: config, callbacks: callbacks).getSettingsList()
        list.selectItem(id: "cache-warming-mode")
        list.handleInput("\r")
        list.handleInput("\r")
        list.handleInput("\r")
        #expect(modes == [.streaming, .idle, .off])
    }

    @Test func persistedWarmUsageAppearsInFooterAndTranscript() {
        let session = cacheTuiSession()
        defer { session.dispose() }
        let usage = Usage(input: 120, output: 2, cacheRead: 80, cacheWrite: 40,
                          totalTokens: 242, cost: UsageCost(total: 0.125))
        session.settingsManager.setShowCacheMissNotices(true)
        _ = session.sessionManager.appendUsage("cache_warm", "anthropic", "test", usage, note: "extension override")
        let footer = FooterComponent(session: session, footerData: CacheFooterData())
        let output = footer.render(width: 120).joined(separator: "\n")
        #expect(output.contains("↑120"))
        #expect(output.contains("$0.125"))

        let mode = InteractiveMode(session: session, version: "test")
        guard case .usage(let entry) = session.sessionManager.getEntries().last else {
            Issue.record("Expected a usage entry")
            return
        }
        mode.handleSessionEvent(.entryAppended(.usage(entry)))
        let transcript = mode.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(transcript.contains("Cache warmed (extension override): $0.125"))
        session.settingsManager.setShowCacheMissNotices(false)
        mode.chatContainer.clear()
        mode.handleSessionEvent(.entryAppended(.usage(entry)))
        #expect(mode.chatContainer.children.isEmpty)
    }

    @Test func sessionCommandShowsModeAndStatus() async {
        let session = cacheTuiSession()
        defer { session.dispose() }
        await session.setCacheWarmingMode(.idle)
        let mode = InteractiveMode(session: session, version: "test")
        await mode.handleSessionCommand()
        let text = mode.chatContainer.render(width: 120).joined(separator: "\n")
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(text.contains("Cache Warming"))
        #expect(text.contains("Mode: idle"))
        #expect(text.contains("Status:"))
    }
}
