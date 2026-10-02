import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

struct T3aFooterData: FooterDataProviding {
    func getGitBranch() -> String? { nil }
    func getExtensionStatuses() -> [String: String] { [:] }
    func onBranchChange(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void { {} }
}

func t3aUsage(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
              totalTokens: Int? = nil, cost: UsageCost = UsageCost()) -> Usage {
    Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
          totalTokens: totalTokens ?? input + output + cacheRead + cacheWrite, cost: cost)
}

func t3aModel(_ id: String = "selected", contextWindow: Int = 10_000) -> Model {
    Model(id: id, name: id, api: .openAIResponses, provider: "test", baseUrl: "https://example.invalid",
        reasoning: true, input: [.text], cost: ModelCost(input: 1, output: 1, cacheRead: 0.1, cacheWrite: 1),
        contextWindow: contextWindow, maxTokens: 1000)
}

func t3aAssistant(_ model: Model = t3aModel(), usage: Usage = t3aUsage(), thinking: ModelThinkingLevel? = nil, responseModel: String? = nil, timestamp: Int64 = 0) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "answer"))], api: model.api, provider: model.provider,
        model: model.id, responseModel: responseModel, usage: usage, stopReason: .stop, timestamp: timestamp, thinkingLevel: thinking)
}

func t3aSession(model: Model = t3aModel(), manager: SessionManager = .inMemory("/tmp"), registry: ModelRegistry? = nil, runner: HookRunner? = nil) -> AgentSession {
    let settings = SettingsManager.inMemory()
    let auth = AuthStorage.inMemory()
    auth.setRuntimeApiKey(model.provider, "test-key")
    let registry = registry ?? ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, thinkingLevel: .high)))
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager, settingsManager: settings,
        resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: settings)),
        hookRunner: runner, modelRegistry: registry))
}

@MainActor @Suite(.serialized) struct T3aInteractiveTests {
    private func config() -> SettingsConfig {
        SettingsConfig(autoCompact: true, showImages: true, autoResizeImages: true, blockImages: false,
            enableSkillCommands: true, steeringMode: "all", followUpMode: "all", transport: .sse,
            thinkingLevel: .high, availableThinkingLevels: [.off, .high], currentTheme: "dark", availableThemes: ["dark"],
            // Upstream v1.0.0: quietStartup now uses QuietStartup.
            hideThinkingBlock: false, showCacheMissNotices: true, collapseChangelog: false, quietStartup: .off,
            doubleEscapeAction: "tree", editorPaddingX: 0, autocompleteMaxVisible: 5,
            tuiMode: .fullscreen, fullscreenScrollbar: .auto, mouseWheelStep: 1,
            mermaidEnabled: false, mermaidRenderWhileStreaming: false, latexEnabled: false, outputPad: 1)
    }

    private func callbacks() -> SettingsCallbacks {
        SettingsCallbacks(onAutoCompactChange: { _ in }, onShowImagesChange: { _ in }, onAutoResizeImagesChange: { _ in },
            onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in }, onSteeringModeChange: { _ in },
            onFollowUpModeChange: { _ in }, onTransportChange: { _ in }, onThinkingLevelChange: { _ in }, onThemeChange: { _ in },
            onHideThinkingBlockChange: { _ in }, onShowCacheMissNoticesChange: { _ in }, onCollapseChangelogChange: { _ in },
            onQuietStartupChange: { _ in }, onDoubleEscapeActionChange: { _ in }, onEditorPaddingXChange: { _ in },
            onAutocompleteMaxVisibleChange: { _ in }, onTuiModeChange: { _ in }, onFullscreenScrollbarChange: { _ in },
            onMouseWheelStepChange: { _ in }, onMermaidEnabledChange: { _ in }, onMermaidRenderWhileStreamingChange: { _ in },
            onLatexEnabledChange: { _ in }, onOutputPadChange: { _ in }, onCancel: {})
    }

    // settings-selector.test.ts: a custom value is kept in the cycle.
    @Test func wheelSelectorCyclesCustomValueAutoAndOne() {
        var config = config()
        config.fullscreenWheelScrollLines = .lines(7)
        var callbacks = callbacks()
        var changes: [PiSwiftCodingAgent.WheelScrollLines] = []
        callbacks.onFullscreenWheelScrollLinesChange = { changes.append($0) }
        let selector = SettingsSelectorComponent(config: config, callbacks: callbacks)
        let list = selector.getSettingsList()
        list.selectItem(id: "fullscreen-wheel-scroll-lines")
        for _ in 0..<3 { list.handleInput("\r") }
        #expect(changes == [.lines(10), .auto, .lines(1)])
        #expect(toolTestText(selector).contains("Fullscreen wheel scrolling"))
        #expect(!toolTestText(selector).contains("Mouse wheel step"))
    }

    @Test func wheelUsesAutoDefaultAndChangesLiveRenderer() async {
        let settings = SettingsManager.inMemory()
        #expect(InteractiveTuiConfiguration(settingsManager: settings).fullscreenWheelScrollLines == .auto)
        #expect(interactiveAltScreenOptions().wheelScrollLines == .auto)
        #expect(interactiveAltScreenOptions(fullscreenWheelScrollLines: .auto).wheelScrollLines == .auto)
        #expect(interactiveAltScreenOptions(fullscreenWheelScrollLines: .lines(7)).wheelScrollLines == .lines(7))
        let session = t3aSession()
        defer { session.dispose() }
        let tui = TUI(terminal: ToolTestTerminal())
        let renderer = tui.enableAltScreen(options: interactiveAltScreenOptions(fullscreenWheelScrollLines: .auto))
        let root = ScrollView(Text((0..<100).map { "line\($0)" }.joined(separator: "\n"), paddingX: 0, paddingY: 0), options: ScrollViewOptions(follow: .end, primary: true))
        renderer.setLayoutRoot(root)
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor, renderer: renderer)
        #expect(tui.switchRenderer(to: .altScreen))
        tui.start()
        defer { tui.stop() }
        await tui.waitForRender()
        mode.setFullscreenWheelScrollLines(.lines(7))
        let before = root.scrollTop
        _ = renderer.handleInput("\u{001B}[<64;1;1M")
        #expect(before - root.scrollTop == 7)
        mode.setFullscreenWheelScrollLines(.auto)
        await tui.waitForRender()
        let after = root.scrollTop
        _ = renderer.handleInput("\u{001B}[<64;1;1M")
        #expect(after - root.scrollTop > 0)
    }

    // footer-width.test.ts: usage append invalidates the cache; frames do not.
    @Test func footerCacheTracksEntriesLeafSessionAndLimits() throws {
        let session = t3aSession()
        defer { session.dispose() }
        let manager = session.sessionManager
        let usage = t3aUsage(input: 100, output: 10, cacheRead: 50, cacheWrite: 50, totalTokens: 210, cost: UsageCost(total: 0.5))
        let first = manager.appendMessage(.assistant(t3aAssistant(usage: usage)))
        let footer = FooterComponent(session: session, footerData: T3aFooterData())
        #expect(toolTestText(footer).contains("$0.500"))
        #expect(toolTestText(footer).contains("CH25.0%"))
        #expect(footer.statsScanCount == 1)
        manager.appendUsage("cache_warm", "test", "selected", usage)
        #expect(toolTestText(footer).contains("$1.000"))
        #expect(footer.statsScanCount == 2)
        try manager.branch(first)
        _ = footer.render(width: 120)
        #expect(footer.statsScanCount == 3)
        session.agent.model = t3aModel(contextWindow: 20_000)
        #expect(toolTestText(footer).contains("/20k"))
        #expect(footer.statsScanCount == 4)
        _ = manager.newSession()
        _ = footer.render(width: 120)
        #expect(footer.statsScanCount == 5)
        let other = t3aSession()
        defer { other.dispose() }
        footer.setSession(other)
        _ = footer.render(width: 120)
        #expect(footer.statsScanCount == 6)
    }

    @Test func footerAndSelectorShowVirtualRouteAndPhysicalContext() throws {
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        registry.registerProvider(HookProviderConfig(provider: "test", api: .openAIResponses,
            baseUrl: "https://example.invalid", apiKey: "test", models: [HookProviderModel(id: "physical", reasoning: true, contextWindow: 50_000, maxTokens: 1000)]), sourceId: "test")
        let physical = try #require(registry.find("test", "physical"))
        let virtual = VirtualModelDefinition(provider: "router", id: "auto", name: "Auto", thinkingLevels: [.high], contextWindow: 1000,
            route: { _ in ModelRoute(model: physical, thinkingLevel: .medium) })
        try registry.registerVirtualModel(virtual, sourceId: "test")
        let manager = SessionManager.inMemory("/tmp")
        manager.appendModelChange("router", "auto")
        manager.appendMessage(.assistant(t3aAssistant(physical, usage: t3aUsage(input: 100, output: 10, totalTokens: 110), thinking: .medium)))
        let session = t3aSession(model: virtual.model, manager: manager, registry: registry)
        defer { session.dispose() }
        let footer = FooterComponent(session: session, footerData: T3aFooterData())
        let text = toolTestText(footer, width: 160)
        #expect(text.contains("auto • high → physical • medium"))
        #expect(text.contains("/50k"))
        let selector = ModelSelectorComponent(tui: TUI(terminal: ToolTestTerminal()), currentModel: virtual.model,
            modelRegistry: registry, scopedModels: [ScopedModel(model: virtual.model)], onSelect: { _ in }, onCancel: {})
        #expect(toolTestText(selector).contains("virtual"))
        selector.closeSelector()
    }

    // interactive-mode.ts /session: one other model is listed; selected-only is hidden.
    @Test func sessionCostsUsePhysicalResponseAndSplitCacheTokens() async throws {
        let manager = SessionManager.inMemory("/tmp")
        manager.appendMessage(.assistant(t3aAssistant(usage: t3aUsage(input: 100, output: 10, cacheRead: 50, cacheWrite: 50, totalTokens: 210, cost: UsageCost(total: 1.25)), responseModel: "physical")))
        let session = t3aSession(manager: manager)
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        await mode.handleSessionCommand()
        let text = toolTestText(mode.chatContainer, width: 160)
        #expect(text.contains("Input: 200"))
        #expect(text.contains("Cached: 50 (25.0%)"))
        #expect(text.contains("Uncached: 150 (50 written to cache)"))
        #expect(text.contains("Total: $1.250"))
        #expect(text.contains("test/physical: $1.250 (210 tokens)"))
        #expect(mode.chatContainer.children.last is ThemedText)
        let info = try #require(mode.chatContainer.children.last as? ThemedText)
        let previousTheme = theme.name
        // Fix the color mode: with TERM=dumb and no COLORTERM the dark and light dim colors
        // quantize to the same 256-color index, and the dark/light comparison below fails.
        let previousMode = theme.colorMode
        setTerminalColorMode(.truecolor)
        defer { setTerminalColorMode(previousMode); initTheme(previousTheme) }
        initTheme("dark")
        info.invalidate()
        let dark = info.render(width: 160)
        initTheme("light")
        info.invalidate()
        let light = info.render(width: 160)
        #expect(dark != light)
        #expect(dark.map(toolTestPlain) == light.map(toolTestPlain))
        let selected = t3aSession()
        defer { selected.dispose() }
        selected.sessionManager.appendMessage(.assistant(t3aAssistant(usage: t3aUsage(input: 1, totalTokens: 1, cost: UsageCost(total: 0.5)))))
        let other = InteractiveMode(session: selected, version: "test")
        await other.handleSessionCommand()
        #expect(!toolTestText(other.chatContainer).contains("test/selected:"))
    }

    @Test func sessionShowsMultipleCostsAndCacheRebilled() async {
        let manager = SessionManager.inMemory("/tmp")
        manager.appendMessage(.assistant(t3aAssistant(usage: t3aUsage(input: 4000, cacheWrite: 4000, totalTokens: 8000, cost: UsageCost(input: 0.004, cacheWrite: 0.004, total: 0.008)))))
        manager.appendMessage(.assistant(t3aAssistant(usage: t3aUsage(input: 4000, cacheRead: 4000, totalTokens: 8000, cost: UsageCost(input: 0.004, cacheRead: 0.0004, total: 0.0044)), timestamp: 1000)))
        manager.appendUsage("cache_warm", "other", "model", t3aUsage(input: 10, totalTokens: 10, cost: UsageCost(total: 0.5)))
        let session = t3aSession(manager: manager)
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        await mode.handleSessionCommand()
        let text = toolTestText(mode.chatContainer, width: 160)
        #expect(text.contains("test/selected:"))
        #expect(text.contains("other/model:"))
        #expect(text.contains("Cache Re-billed: $0.004 (4,000 tokens, 1 miss)"))
    }

    // footer-width.test.ts and agent-session-stats.test.ts: include every usage entry.
    @Test func footerAndSessionIncludeToolAndSummaryUsage() async {
        let manager = SessionManager.inMemory("/tmp")
        let first = manager.appendMessage(.assistant(t3aAssistant(usage: t3aUsage(input: 100, output: 10, cost: UsageCost(total: 0.5)))))
        manager.appendBranchSummary(first, "branch", usage: t3aUsage(input: 20, output: 5, cost: UsageCost(total: 0.25)))
        manager.appendCompaction("summary", first, 100, usage: t3aUsage(input: 5, output: 2, cost: UsageCost(total: 0.125)))
        manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "call", toolName: "tool", content: [.text(TextContent(text: "done"))],
            usage: t3aUsage(input: 15, output: 3, cost: UsageCost(total: 0.375)), isError: false, timestamp: 0)))
        let session = t3aSession(manager: manager)
        defer { session.dispose() }
        let footer = FooterComponent(session: session, footerData: T3aFooterData())
        let footerText = toolTestText(footer)
        #expect(footerText.contains("↑140 ↓20"))
        #expect(footerText.contains("$1.250"))
        let mode = InteractiveMode(session: session, version: "test")
        await mode.handleSessionCommand()
        let text = toolTestText(mode.chatContainer, width: 160)
        #expect(text.contains("Total: $1.250"))
        #expect(text.contains("Tools/summaries: $0.750 (50 tokens)"))
        #expect(text.contains("test/selected: $0.500 (110 tokens)"))
    }

    // footer-width.test.ts: wide model and session names must fit the terminal.
    @Test func footerWideNamesStayWithinWidth() {
        let session = t3aSession(model: t3aModel(String(repeating: "模", count: 30)))
        defer { session.dispose() }
        session.sessionManager.appendSessionInfo(String(repeating: "한글", count: 30))
        session.sessionManager.appendMessage(.assistant(t3aAssistant(usage: t3aUsage(input: 12_345, output: 6789, cost: UsageCost(total: 1.234)))))
        let footer = FooterComponent(session: session, footerData: T3aFooterData())
        for width in [30, 60, 93] {
            #expect(footer.render(width: width).allSatisfy { visibleWidth($0) <= width })
        }
    }

    // clipboard-paste-file-paths.test.ts: copied files precede Finder icon images.
    @Test func finderFilesPrecedeImagesAndAddSpace() {
        let session = t3aSession()
        defer { session.dispose() }
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        editor.setText("Review:")
        let mode = InteractiveMode(session: session, tui: TUI(terminal: ToolTestTerminal()), editor: editor)
        mode.clipboardFiles = { ["/tmp/photo.png", "/tmp/second.png"] }
        var imageRead = false
        mode.clipboardImage = { imageRead = true; return .content(Data([1])) }
        mode.handleClipboardImagePaste()
        #expect(editor.getExpandedText() == "Review: /tmp/photo.png\n/tmp/second.png")
        #expect(!imageRead)
    }

    @Test func filePasteQuotesBashAndHandlesUnicodeCursor() throws {
        let paths = ["/tmp/My Photos/photo.png", "/tmp/$(touch hacked).png", "/tmp/plain.png"]
        #expect(try clipboardFileInsertion(paths, bashMode: true, text: "!catX", cursor: (0, 4)) == " '/tmp/My Photos/photo.png' '/tmp/$(touch hacked).png' /tmp/plain.png ")
        #expect(quoteIfNeeded("/tmp/a'b") == "'/tmp/a'\\''b'")
        #expect(try clipboardFileInsertion(["/tmp/photo.png"], bashMode: false, text: "確認", cursor: (0, 2)) == " /tmp/photo.png")
        #expect(try clipboardFileInsertion(["/tmp/photo.png"], bashMode: false, text: "😀 rest", cursor: (0, 1)) == " /tmp/photo.png")
    }

    @Test func clipboardErrorsStopFallbackAndAreShown() {
        let session = t3aSession()
        defer { session.dispose() }
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        let mode = InteractiveMode(session: session, tui: TUI(terminal: ToolTestTerminal()), editor: editor)
        var imageRead = false
        mode.clipboardFiles = { ["/tmp/a\u{0001}b"] }
        mode.clipboardImage = { imageRead = true; return .empty }
        mode.handleClipboardImagePaste()
        #expect(!imageRead)
        #expect(toolTestText(mode.chatContainer).contains("Failed to paste from clipboard: Clipboard file path contains control characters"))
        mode.clipboardFiles = { nil }
        mode.clipboardImage = { .content(Data([1])) }
        mode.writeClipboardImage = { _, _ in throw ClipboardPasteError.read("write failed") }
        mode.handleClipboardImagePaste()
        #expect(toolTestText(mode.chatContainer).contains("Failed to paste from clipboard: write failed"))
        mode.clipboardFiles = { throw ClipboardPasteError.read("native read failed") }
        mode.handleClipboardImagePaste()
        #expect(toolTestText(mode.chatContainer).contains("Failed to paste from clipboard: native read failed"))
    }

    @Test func clipboardImageAndTextFallbackWork() {
        let session = t3aSession()
        defer { session.dispose() }
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        let mode = InteractiveMode(session: session, tui: TUI(terminal: ToolTestTerminal()), editor: editor)
        mode.clipboardFiles = { nil }
        mode.clipboardImage = { .empty }
        mode.clipboardText = { .content("text") }
        mode.handleClipboardImagePaste()
        #expect(editor.getText() == "text")
        var written: URL?
        mode.clipboardImage = { .content(Data([1])) }
        mode.writeClipboardImage = { _, url in written = url }
        mode.handleClipboardImagePaste()
        #expect(written?.lastPathComponent.hasPrefix("pi-clipboard-") == true)
        #expect(editor.getText().contains(written?.path ?? "missing"))
    }

    @Test func loginChoiceUsesLabelAndDialogUsesProviderName() {
        let registry = ModelRegistry(.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let provider = registry.getLoginProvider("openai")
        #expect(provider?.oauth?.loginLabel == "Sign in with ChatGPT")
        // Upstream v1.0.0: the method menu uses loginLabel; selectors and dialogs use the provider name.
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "openai", providerName: "OpenAI", onComplete: { _, _ in })
        #expect(toolTestText(dialog).contains("Login to OpenAI"))
        let selector = OAuthSelectorComponent(mode: .login,
            providers: [AuthSelectorProvider(id: "openai", name: "OpenAI", authType: .oauth)],
            onSelect: { _, _ in }, onCancel: {})
        #expect(toolTestText(selector).contains("OpenAI"))
        #expect(buildStartupHeader(version: "test", keybindings: KeybindingsManager.create(), expanded: true).contains("to paste files on macOS, images, or text"))
    }

    @Test func loginDeviceIdCallbackUsesPersistedGlobalId() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t3a-device-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectSettings = project.appendingPathComponent(".pi")
        try FileManager.default.createDirectory(at: projectSettings, withIntermediateDirectories: true)
        try #"{"deviceId":"project-device"}"#.write(to: projectSettings.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let globalSettings = agent.appendingPathComponent("settings.json")
        try #"{"theme":"dark"}"#.write(to: globalSettings, atomically: true, encoding: .utf8)
        let settings = SettingsManager.create(project.path, agent.path)
        let callback = interactiveOAuthDeviceIdProvider(settings)
        let first = callback()
        #expect(first == callback())
        #expect(UUID(uuidString: first) != nil)
        #expect(first != "project-device")
        let reloaded = SettingsManager.create(project.path, agent.path)
        #expect(interactiveOAuthDeviceIdProvider(reloaded)() == first)
        #expect(reloaded.getTheme() == "dark")
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: globalSettings)) as? [String: String])
        #expect(saved == ["theme": "dark", "deviceId": first])
    }

    @Test func builtinOverridesUseLibraryResolve() async throws {
        let settings = SettingsManager.inMemory()
        settings.setExtensionPaths(["-builtin:codemode", "-builtin:mcp"])
        settings.setProjectExtensionPaths(["+builtin:codemode"])
        let paths = try await resolveBuiltinExtensionPaths(settingsManager: settings, names: ["codemode", "mcp"], cwd: "/tmp", agentDir: "/tmp")
        let builtins = paths.extensions.filter { $0.metadata.source == "builtin" }
        #expect(builtins.first { $0.path == "builtin:codemode" }?.enabled == true)
        #expect(builtins.first { $0.path == "builtin:codemode" }?.metadata.scope == "project")
        #expect(builtins.first { $0.path == "builtin:mcp" }?.enabled == false)
        let global = try await resolveBuiltinExtensionPaths(settingsManager: settings, names: ["codemode", "mcp"], cwd: "/tmp", agentDir: "/tmp", projectTrusted: false)
        #expect(global.extensions.filter { $0.metadata.source == "builtin" }.allSatisfy { !$0.enabled })
    }
}
