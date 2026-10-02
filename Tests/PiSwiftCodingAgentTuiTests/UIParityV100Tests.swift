import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class V100Events: Sendable {
    let values = Mutex<[String]>([])
    func record(_ value: String) { values.withLock { $0.append(value) } }
    var entries: [String] { values.withLock { $0 } }
}

private final class V100Resources: ResourceLoader {
    let events: V100Events
    init(events: V100Events) { self.events = events }
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [ContextFile(path: "/tmp/AGENTS.md", content: "Rules")] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async { events.record("resources") }
}

private final class V100Terminal: Terminal {
    let columns = 100
    let rows = 30
    let kittyProtocolActive = false
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

@MainActor
private struct V100Host {
    let session: AgentSession
    let mode: InteractiveMode
    let editor: CustomEditor
    let events = V100Events()

    init(settings: SettingsManager, override: InteractiveTuiMode? = nil, verbose: Bool = false) {
        let model = Model(id: "test", name: "test", api: .openAIResponses, provider: "openai",
            baseUrl: "https://example.invalid", reasoning: true, input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1000, maxTokens: 100)
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([], "/tmp", manager, registry)
        let events = self.events
        session = AgentSession(config: AgentSessionConfig(
            agent: Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model))),
            sessionManager: manager, settingsManager: settings, resourceLoader: V100Resources(events: events),
            hookRunner: runner, modelRegistry: registry, reloadExtensionsHook: {
                events.record("extensions")
                return LoadExtensionsResult(hooks: [])
            }))
        let tui = TUI(terminal: V100Terminal())
        editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let renderer = tui.enableAltScreen()
        mode = InteractiveMode(session: session, tui: tui, editor: editor, renderer: renderer, tuiMode: override, verbose: verbose)
    }

    func close() { session.dispose() }
}

@MainActor
@Suite(.serialized)
struct UIParityV100Tests {
    // interactive-mode-status.test.ts: header-only startup keeps the header and hides resources.
    @Test func headerOnlyStartupHidesResourcesAndCompactResourceHint() throws {
        let settings = SettingsManager.inMemory()
        settings.setQuietStartup(.header)
        let host = V100Host(settings: settings)
        defer { host.close() }
        host.mode.refreshStartupHeader()
        let header = try #require(host.mode.builtInHeader)
        let text = stripTerminalSequences(header.render(width: 160).joined(separator: "\n"))
        #expect(text.contains("full startup help."))
        #expect(!text.contains("and loaded resources"))
        host.mode.showLoadedResources(.init(extensionPaths: [], force: false))
        #expect(host.mode.loadedResourcesContainer.children.isEmpty)
        host.mode.showLoadedResources(.init(extensionPaths: [], force: true))
        #expect(!host.mode.loadedResourcesContainer.children.isEmpty)
    }

    // interactive-mode-status.test.ts: verbose startup overrides full quiet startup.
    @Test(arguments: [false, true]) func fullQuietStartupHeaderAndDetailsFollowVerbose(_ verbose: Bool) {
        let settings = SettingsManager.inMemory()
        settings.setQuietStartup(.on)
        let host = V100Host(settings: settings, verbose: verbose)
        defer { host.close() }
        host.mode.refreshStartupHeader()
        #expect((host.mode.builtInHeader != nil) == verbose)
        host.mode.showLoadedResources(.init(extensionPaths: [], force: false))
        #expect(!host.mode.loadedResourcesContainer.children.isEmpty == verbose)
    }

    @Test func appleTerminalUsesBrandWordmarkAndHintsOnNextLine() {
        let env = ["TERM_PROGRAM": "Apple_Terminal"]
        #expect(!supportsPiLogo(environment: env))
        #expect(supportsPiLogo(environment: ["TERM_PROGRAM": "iTerm.app"]))
        let text = buildStartupHeader(version: "1.0.0", keybindings: .inMemory(), expanded: false, environment: env)
        let lines = text.components(separatedBy: "\n")
        #expect(stripTerminalSequences(lines[0]) == "Pi v1.0.0")
        #expect(lines[0].hasPrefix(piWordmark()))
        #expect(stripTerminalSequences(lines[1]).contains("interrupt"))
        #expect(!text.contains("▀"))
        let mode = MiniTui.TerminalColorMode(rawValue: theme.getColorMode()) ?? .color256
        #expect(piWordmark().contains(foregroundAnsi(try! rgbColor(228, 138, 122), mode) + "P"))
        #expect(piWordmark().contains(foregroundAnsi(try! rgbColor(234, 182, 93), mode) + "i"))
    }

    @Test func mcpRedirectURLAndClickHintUseHyperlinks() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let url = URL(string: "https://example.invalid/authorize")!
        let task = Task { await view.redirectURL(title: "Sign in", authorizationURL: url) }
        defer { task.cancel(); view.dispose() }
        for _ in 0..<100 {
            if stripTerminalSequences(view.render(width: 160).joined()).contains(url.absoluteString) { break }
            await Task.yield()
        }
        let rendered = view.render(width: 160).joined(separator: "\n")
        #if os(macOS)
        let hint = "Cmd+click to open"
        #else
        let hint = "Ctrl+click to open"
        #endif
        #expect(rendered.contains(hyperlink(url.absoluteString, url: url.absoluteString)))
        #expect(rendered.contains(hyperlink(hint, url: url.absoluteString)))
        #expect(stripTerminalSequences(rendered).contains(hint))
        view.handleInput("\u{001B}")
        #expect(await task.value == nil)
    }

    @Test func quietStartupSettingsRowCyclesAllThreeValuesAndPersists() {
        let settings = SettingsManager.inMemory()
        var changes: [QuietStartup] = []
        let callbacks = SettingsCallbacks(onAutoCompactChange: { _ in }, onShowImagesChange: { _ in },
            onAutoResizeImagesChange: { _ in }, onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in },
            onSteeringModeChange: { _ in }, onFollowUpModeChange: { _ in }, onTransportChange: { _ in },
            onThinkingLevelChange: { _ in }, onThemeChange: { _ in }, onHideThinkingBlockChange: { _ in },
            onShowCacheMissNoticesChange: { _ in }, onCollapseChangelogChange: { _ in },
            onQuietStartupChange: { value in changes.append(value); settings.setQuietStartup(value) },
            onDoubleEscapeActionChange: { _ in }, onEditorPaddingXChange: { _ in },
            onAutocompleteMaxVisibleChange: { _ in }, onTuiModeChange: { _ in }, onFullscreenScrollbarChange: { _ in },
            onMouseWheelStepChange: { _ in }, onMermaidEnabledChange: { _ in },
            onMermaidRenderWhileStreamingChange: { _ in }, onLatexEnabledChange: { _ in }, onOutputPadChange: { _ in }, onCancel: {})
        let config = SettingsConfig(autoCompact: true, showImages: true, autoResizeImages: true, blockImages: false,
            enableSkillCommands: true, steeringMode: "all", followUpMode: "all", transport: .sse,
            thinkingLevel: .off, availableThinkingLevels: [.off], availableThemes: ["dark"], hideThinkingBlock: false,
            showCacheMissNotices: true, collapseChangelog: false, quietStartup: .off, doubleEscapeAction: "tree",
            editorPaddingX: 0, autocompleteMaxVisible: 5, tuiMode: .fullscreen, fullscreenScrollbar: .auto,
            mouseWheelStep: 1, mermaidEnabled: true, mermaidRenderWhileStreaming: true, latexEnabled: false, outputPad: 1)
        let selector = SettingsSelectorComponent(config: config, callbacks: callbacks)
        let list = selector.getSettingsList()
        list.selectItem(id: "quiet-startup")
        #expect(stripTerminalSequences(list.render(width: 160).joined()).contains("header: keep only the startup header"))
        for expected in [QuietStartup.on, .header, .off] {
            list.handleInput("\r")
            #expect(settings.getQuietStartup() == expected)
        }
        #expect(changes == [.on, .header, .off])
        list.selectItem(id: "tui-mode")
        #expect(stripTerminalSequences(list.render(width: 160).joined()).contains("regular mode uses the terminal's normal scrollback"))
    }

    @Test(arguments: [false, true]) func reloadReadsHostSettingsAndKeepsExplicitMode(_ override: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-v100-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsManager.create(root.path, root.path, projectTrusted: false)
        settings.setTuiMode("regular")
        settings.setQuietStartup(.off)
        let host = V100Host(settings: settings, override: override ? .regular : nil)
        defer { host.close() }
        let updated: [String: Any] = ["tuiMode": "fullscreen", "quietStartup": "header", "editorPaddingX": 3,
            "autocompleteMaxVisible": 15, "hideThinkingBlock": true, "showImages": false, "images": ["autoResize": false, "blockImages": true], "enableSkillCommands": false, "outputPad": 0, "fullscreenScrollbar": "hidden",
            "fullscreenWheelScrollLines": 7, "markdown": ["mermaidEnabled": false, "mermaidRenderWhileStreaming": false, "latexEnabled": true]]
        try JSONSerialization.data(withJSONObject: updated).write(to: root.appendingPathComponent("settings.json"))
        await host.mode.handleReloadCommand()
        #expect(host.events.entries == ["resources", "extensions"])
        #expect(host.mode.tuiConfiguration.mode == (override ? .regular : .fullscreen))
        #expect(host.mode.tuiConfiguration.scrollbar == .hidden)
        #expect(host.mode.tuiConfiguration.fullscreenWheelScrollLines == .lines(7))
        #expect(!host.mode.tuiConfiguration.mermaidEnabled)
        #expect(!host.mode.tuiConfiguration.mermaidRenderWhileStreaming)
        #expect(host.mode.tuiConfiguration.latexEnabled)
        #expect(host.mode.tuiConfiguration.outputPad == 0)
        #expect(host.editor.getPaddingX() == 3)
        #expect(host.editor.getAutocompleteMaxVisible() == 15)
        #expect(host.mode.hideThinkingBlock)
        let header = try #require(host.mode.builtInHeader)
        #expect(!stripTerminalSequences(header.render(width: 160).joined()).contains("and loaded resources"))
        #expect(settings.getBlockImages())
        #expect(!settings.getAutoResizeImages())
        #expect(!settings.getEnableSkillCommands())
    }

    // 5943-session-start-notify.test.ts: the fake context now allows startup details.
    @Test func loadedResourcesPrecedeRestoredMessagesAndKeepStartupNotification() async {
        let host = V100Host(settings: .inMemory())
        defer { host.close() }
        host.mode.loadedResourcesContainer.addChild(Text("stale resources", paddingX: 0, paddingY: 0))
        host.mode.chatContainer.addChild(Text("restored message", paddingX: 0, paddingY: 0))
        host.mode.showLoadedResources(.init(extensionPaths: [], force: false))
        await host.mode.initializeHooksAndCustomTools()
        host.session.hookRunner?.getUIContext().notify("Hello Error", .error)
        for _ in 0..<100 {
            if host.mode.chatContainer.render(width: 160).joined().contains("Hello Error") { break }
            await Task.yield()
        }
        let root = Container()
        root.addChild(host.mode.loadedResourcesContainer)
        root.addChild(host.mode.chatContainer)
        let text = stripTerminalSequences(root.render(width: 160).joined(separator: "\n"))
        #expect(!text.contains("stale resources"))
        #expect(text.contains("Hello Error"))
        #expect(text.contains("restored message"))
        if let context = text.range(of: "[Context]"), let restored = text.range(of: "restored message") {
            #expect(context.lowerBound < restored.lowerBound)
        } else { Issue.record("Missing context or restored message") }
    }
}
