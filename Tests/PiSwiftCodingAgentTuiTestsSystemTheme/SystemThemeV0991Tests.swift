import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftAgent
import PiSwiftAI
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
private final class ThemeTestUI: ThemeControllerUI {
    var nextColors = MiniTui.TerminalColors()
    var holdQuery = false
    var answer: CheckedContinuation<MiniTui.TerminalColors, Never>?
    var lateReply: (@MainActor (MiniTui.TerminalColors) -> Void)?
    var listener: ((TerminalColorScheme) -> Void)?
    var notifications: [Bool] = []
    var queries = 0
    var renders = 0
    var invalidations = 0
    var unsubscribes = 0

    func queryTerminalColors(timeoutMs: Int, onLateReply: (@MainActor (MiniTui.TerminalColors) -> Void)?) async -> MiniTui.TerminalColors {
        #expect(timeoutMs == 100)
        queries += 1
        lateReply = onLateReply
        if holdQuery { return await withCheckedContinuation { answer = $0 } }
        return nextColors
    }
    func invalidate() { invalidations += 1 }
    func requestRender(force: Bool) { renders += 1 }
    func setTerminalColorSchemeNotifications(_ enabled: Bool) { notifications.append(enabled) }
    func onTerminalColorSchemeChange(_ listener: @escaping (TerminalColorScheme) -> Void) -> () -> Void {
        self.listener = listener
        return { self.unsubscribes += 1; self.listener = nil }
    }
}

private let darkTerminalColors = MiniTui.TerminalColors(
    foreground: RgbColor(r: 248, g: 248, b: 242), background: RgbColor(r: 40, g: 42, b: 54)
)
private let lightTerminalColors = MiniTui.TerminalColors(
    foreground: RgbColor(r: 30, g: 30, b: 30), background: RgbColor(r: 250, g: 250, b: 250)
)

@MainActor
private func resetTerminalThemeState() {
    PiSwiftCodingAgent.setTerminalColors(PiSwiftCodingAgent.TerminalColors())
    PiSwiftCodingAgent.setTerminalColorScheme(nil)
    PiSwiftCodingAgent.setTerminalColorMode(.truecolor)
    setCapabilityOverrides(MiniTui.TerminalCapabilityOverrides())
    initTheme("dark")
    stopThemeWatcher()
}

@MainActor @Suite(.serialized)
struct SystemThemeV0991Tests {
    init() { resetTerminalThemeState() }

    @Test func initialOverrideDoesNotPersistAndStillQueriesColors() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        var settings = Settings(); settings.theme = "dark"
        let manager = SettingsManager.inMemory(settings)
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {}, initialThemeSetting: "light")
        defer { controller.dispose() }
        #expect(theme.name == "light")
        controller.applyFromSettings()
        await controller.waitForTerminalColors()
        #expect(ui.queries == 1)
        #expect(manager.getTheme() == "dark")
    }

    @Test func appliesSystemAtOnceAndWaitsForTheLatestQuery() async throws {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI(); ui.holdQuery = true
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings()
        #expect(theme.name == "system")
        #expect(theme.getFgAnsi(.error) == "\u{001B}[39m")
        await Task.yield()
        let answer = try #require(ui.answer)
        answer.resume(returning: darkTerminalColors)
        await controller.waitForTerminalColors()
        #expect(theme.getFgAnsi(.error).hasPrefix("\u{001B}[38;"))
        #expect(manager.getTheme() == nil)
        ui.holdQuery = false; ui.nextColors = lightTerminalColors
        controller.applyFromSettings()
        await controller.waitForTerminalColors()
        #expect(ui.queries == 2)
        #expect(controller.getTerminalTheme() == .light)
    }

    @Test func timeoutUsesPaletteThenAcceptsLateColors() async throws {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings()
        await controller.waitForTerminalColors()
        #expect(theme.getFgAnsi(.error) == "\u{001B}[38;5;1m")
        let late = try #require(ui.lateReply)
        late(darkTerminalColors)
        if case .rgb = theme.colors["error"] { } else { Issue.record("Expected an RGB error color") }
        #expect(manager.getTheme() == nil)
    }

    @Test func appearanceReportQueriesAgainAndBackgroundWins() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI(); ui.nextColors = lightTerminalColors
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {}, initialThemeSetting: "light/dark")
        defer { controller.dispose() }
        controller.applyFromSettings()
        await controller.waitForTerminalColors()
        #expect(ui.notifications.last == true)
        #expect(theme.name == "light")
        ui.nextColors = darkTerminalColors
        ui.listener?(.light)
        await controller.waitForTerminalColors()
        #expect(ui.queries == 2)
        #expect(theme.name == "dark")
    }

    @Test func reportedSchemeUpdatesSystemWithoutColors() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings()
        await controller.waitForTerminalColors()
        ui.listener?(.light)
        #expect(theme.appearance == .light)
        #expect(controller.getTerminalTheme() == .light)
        await controller.waitForTerminalColors()
    }

    @Test func keepsKnownColorsAndDeduplicatesReplies() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI(); ui.nextColors = darkTerminalColors
        var settings = Settings(); settings.theme = "dark"
        let manager = SettingsManager.inMemory(settings)
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        ui.nextColors = MiniTui.TerminalColors()
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        ui.nextColors = darkTerminalColors
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        #expect(ui.renders == 1)
        #expect(controller.getTerminalTheme() == .dark)
    }

    @Test func mergesForegroundBackgroundAndAllPaletteEntries() async throws {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        ui.nextColors = MiniTui.TerminalColors(background: darkTerminalColors.background)
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        let late = try #require(ui.lateReply)
        late(MiniTui.TerminalColors(foreground: darkTerminalColors.foreground))
        let palette = (0..<16).map { RgbColor(r: $0 * 15, g: 100, b: 200) }
        late(MiniTui.TerminalColors(palette: palette))
        let bridged = MiniTui.TerminalColors(foreground: darkTerminalColors.foreground, background: darkTerminalColors.background, palette: palette).codingAgentColors
        let actual = theme.colors
        PiSwiftCodingAgent.setTerminalColors(bridged)
        let expected = try loadTheme("system")
        #expect(actual == expected.colors)
        #expect(bridged.palette?.count == 16)
        for index in 0..<16 {
            #expect(bridged.palette?[index].r == Double(index * 15))
            #expect(bridged.palette?[index].g == 100)
            #expect(bridged.palette?[index].b == 200)
        }
        #expect(ui.renders == 3)
        late(MiniTui.TerminalColors())
        #expect(ui.renders == 3)
    }

    @Test func disposeDisablesNotificationsAndRemovesListener() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {}, initialThemeSetting: "light/dark")
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        controller.dispose()
        #expect(ui.notifications.last == false)
        #expect(ui.unsubscribes == 1)
        #expect(ui.listener == nil)
    }

    @Test func explicitSelectionReplacesInitialOverride() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let first = SettingsManager.inMemory(); first.setTheme("dark")
        let second = SettingsManager.inMemory(); second.setTheme("light")
        var manager = first
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {}, initialThemeSetting: "light")
        defer { controller.dispose() }
        controller.applyFromSettings()
        #expect(controller.setThemeName("dark").success)
        manager = second
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        #expect(controller.getThemeSelection() == "dark")
        #expect(theme.name == "dark")
    }

    @Test func reloadsSettingsWhenThereIsNoOverride() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let first = SettingsManager.inMemory(); first.setTheme("dark")
        let second = SettingsManager.inMemory(); second.setTheme("light")
        var manager = first
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        var overrides = Settings(); overrides.theme = "light"
        first.applyOverrides(overrides)
        controller.applyFromSettings()
        #expect(theme.name == "light")
        overrides.theme = "dark"; second.applyOverrides(overrides); manager = second
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        #expect(theme.name == "dark")
    }

    @Test func failedThemeFallsBackToSystemWithTheUpstreamMessage() async {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let manager = SettingsManager.inMemory()
        var errors: [String] = []
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { errors.append($0) }, onChanged: {}, initialThemeSetting: "does-not-exist-t2")
        defer { controller.dispose() }
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        #expect(theme.name == "system")
        #expect(errors.first?.hasSuffix("Fell back to the system theme.") == true)
        #expect(manager.getTheme() == nil)
    }

    @Test func inMemoryThemeIsNotReplacedByColorReplies() async throws {
        defer { resetTerminalThemeState() }
        let ui = ThemeTestUI()
        let manager = SettingsManager.inMemory()
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { manager }, showError: { _ in }, onChanged: {})
        defer { controller.dispose() }
        controller.applyFromSettings(); await controller.waitForTerminalColors()
        #expect(controller.setThemeInstance(try loadTheme("light")).success)
        ui.lateReply?(darkTerminalColors)
        #expect(theme.name == "light")
        #expect(ui.notifications.last == false)
    }

    @Test func themedTextBuildsLazilyAndRebuildsAfterInvalidation() {
        defer { resetTerminalThemeState() }
        var builds = 0
        let text = ThemedText({ builds += 1; return theme.fg(.accent, "themed") }, paddingX: 0, paddingY: 0)
        #expect(builds == 0)
        let dark = text.render(width: 40)
        initTheme("light")
        #expect(text.render(width: 40) == dark)
        text.invalidate()
        let light = text.render(width: 40)
        #expect(light != dark)
        #expect(light.first?.contains(theme.getFgAnsi(.accent)) == true)
        _ = text.render(width: 50)
        #expect(builds == 2)
    }

    @Test func firstSetupStartsWithSystemAndReturnsAThemeName() {
        defer { resetTerminalThemeState() }
        var previews: [String] = []
        var result: FirstTimeSetupResult?
        let setup = FirstTimeSetupComponent(onThemePreview: { previews.append($0) }, onSubmit: { result = $0 }, onCancel: {})
        let text = setup.render(width: 100).map(stripAnsi).joined(separator: "\n")
        #expect(text.contains("→ System (matches your terminal colors)"))
        #expect(!text.contains("Detected system appearance"))
        #expect(text.range(of: "System")!.lowerBound < text.range(of: "Dark")!.lowerBound)
        setup.handleInput("j"); setup.handleInput("k")
        #expect(previews == ["dark", "system"])
        setup.handleInput("\r"); setup.handleInput("\r")
        #expect(result == FirstTimeSetupResult(themeName: "system", shareAnalytics: true))
    }

    @Test func firstSetupRebuildsBothStepsOnInvalidation() {
        defer { resetTerminalThemeState() }
        let setup = FirstTimeSetupComponent(onThemePreview: { _ in }, onSubmit: { _ in }, onCancel: {})
        let before = setup.render(width: 100)
        initTheme("light"); setup.invalidate()
        #expect(setup.render(width: 100) != before)
        #expect(setup.render(width: 100).joined().contains(theme.getFgAnsi(.accent)))
        setup.handleInput("\r")
        let analytics = setup.render(width: 100)
        initTheme("dark"); setup.invalidate()
        #expect(setup.render(width: 100) != analytics)
    }

    @Test func logoUsesFixedBrandColorsAndTheEffectiveMode() {
        defer { resetTerminalThemeState() }
        initTheme("dark")
        let dark = piLogoLines()
        #expect(visibleWidth(dark.top) == 4)
        #expect(visibleWidth(dark.bottom) == 4)
        #expect(dark.top.contains("\u{001B}[38;2;228;138;122m"))
        #expect(dark.top.contains("\u{001B}[48;2;79;142;179m"))
        #expect(dark.bottom.contains("\u{001B}[38;2;234;182;93m"))
        initTheme("light")
        #expect(piLogoLines().top == dark.top)
        PiSwiftCodingAgent.setTerminalColorMode(.color256); initTheme("light")
        #expect(piLogoLines().top.contains("\u{001B}[38;5;"))
        #expect(!piLogoLines().top.contains("38;2;"))
    }

    @Test func compactAndExpandedHeaderFollowExpansionAndThemeChanges() {
        defer { resetTerminalThemeState() }
        let keys = KeybindingsManager.inMemory()
        let header = ExpandableText(
            collapsed: { buildStartupHeader(version: "0.99.1", keybindings: keys, expanded: false) },
            expanded: { buildStartupHeader(version: "0.99.1", keybindings: keys, expanded: true) }
        )
        let collapsed = header.render(width: 200)
        let plain = collapsed.map(stripAnsi).joined(separator: "\n")
        #expect(plain.contains("v0.99.1"))
        #expect(plain.contains("interrupt ·"))
        #expect(plain.contains("clear/exit"))
        #expect(plain.contains("show full startup help and loaded resources"))
        #expect(plain.contains("Pi can explain its own features"))
        header.setExpanded(true)
        let expanded = header.render(width: 200).map(stripAnsi).joined(separator: "\n")
        #expect(expanded.contains("!! to run bash (no context)"))
        #expect(expanded.contains("drop files to attach"))
        #if os(macOS)
        #expect(expanded.contains("option+enter to queue follow-up"))
        #endif
        #expect(!expanded.contains("show full startup help"))
        initTheme("light"); header.invalidate(); header.setExpanded(false)
        #expect(header.render(width: 200) != collapsed)
    }

    @Test func expansionUpdatesActiveHeaderResourcesAndChat() {
        defer { resetTerminalThemeState() }
        let mode = InteractiveMode(chatContainer: Container(), ui: ThemeRenderUI())
        func section() -> ExpandableText { ExpandableText(collapsed: { "short" }, expanded: { "full" }) }
        let header = section(); let resources = section(); let chat = section()
        mode.builtInHeader = header
        mode.loadedResourcesContainer.addChild(resources)
        mode.chatContainer.addChild(chat)
        mode.setToolsExpanded(true)
        for text in [header, resources, chat] { #expect(text.render(width: 20).first?.contains("full") == true) }
        #expect(mode.chatContainer.render(width: 80).map(stripAnsi).joined().contains("Tool output: expanded"))
        mode.setToolsExpanded(false)
        for text in [header, resources, chat] { #expect(text.render(width: 20).first?.contains("short") == true) }
    }

    @Test func settingsPutsSystemFirstAndUsesLowercaseAutomatic() {
        defer { resetTerminalThemeState() }
        let list = SettingsSelectorComponent(config: systemSettingsConfig(), callbacks: systemSettingsCallbacks()).getSettingsList()
        list.selectItem(id: "theme"); list.handleInput("\r")
        let text = list.render(width: 160).map(stripAnsi).joined(separator: "\n")
        #expect(text.contains("→ ✓ system"))
        #expect(text.contains("Theme created from your terminal's colors"))
        #expect(text.range(of: "✓ system")!.lowerBound < text.range(of: "  automatic")!.lowerBound)
        #expect(!text.contains("Automatic"))
    }

    @Test func settingsKeepsFixedAndAutomaticMarkersWhileBrowsing() {
        defer { resetTerminalThemeState() }
        var config = systemSettingsConfig(); config.currentTheme = "dark"
        let fixed = SettingsSelectorComponent(config: config, callbacks: systemSettingsCallbacks()).getSettingsList()
        fixed.selectItem(id: "theme"); fixed.handleInput("\r")
        #expect(fixed.render(width: 160).map(stripAnsi).joined().contains("→ ✓ dark"))
        fixed.handleInput("\u{001B}[B")
        let text = fixed.render(width: 160).map(stripAnsi).joined()
        #expect(text.contains("  ✓ dark")); #expect(text.contains("→   light"))
        config.currentTheme = "light/dark"
        let automatic = SettingsSelectorComponent(config: config, callbacks: systemSettingsCallbacks()).getSettingsList()
        automatic.selectItem(id: "theme"); automatic.handleInput("\r"); automatic.handleInput("\r")
        #expect(automatic.render(width: 160).map(stripAnsi).joined().contains("→ ✓ light"))
        automatic.handleInput("\u{001B}[B")
        let automaticText = automatic.render(width: 160).map(stripAnsi).joined()
        #expect(automaticText.contains("  ✓ light")); #expect(automaticText.contains("→   other"))
    }

    @Test func loadedResourcesRecolorExpandAndKeepOnlyThemeDiagnostics() {
        defer { resetTerminalThemeState() }
        let settings = SettingsManager.inMemory()
        let session = AgentSession(config: AgentSessionConfig(
            agent: Agent(), sessionManager: .inMemory("/tmp/theme-project"), settingsManager: settings,
            resourceLoader: ThemeResourceLoader(),
            modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        ))
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "0.99.1")
        mode.showLoadedResources(InteractiveMode.ResourceDisplayOptions(extensionPaths: ["/tmp/theme-project/extension.swift"], force: true))
        let before = mode.loadedResourcesContainer.render(width: 120)
        let compact = before.map(stripAnsi).joined(separator: "\n")
        #expect(!compact.contains("[Themes]"))
        #expect(compact.contains("[Theme conflicts]"))
        #expect(compact.contains("theme conflict test"))
        #expect(compact.contains("alpha, zeta"))
        #expect(!compact.contains("alpha/SKILL.md"))
        mode.setToolsExpanded(true)
        #expect(mode.loadedResourcesContainer.render(width: 120).map(stripAnsi).joined().contains("alpha/SKILL.md"))
        mode.setToolsExpanded(false)
        initTheme("light"); mode.loadedResourcesContainer.invalidate()
        let after = mode.loadedResourcesContainer.render(width: 120)
        #expect(after != before)
        #expect(after.map(stripAnsi) == before.map(stripAnsi))
        mode.showLoadedResources(InteractiveMode.ResourceDisplayOptions(extensionPaths: ["/tmp/theme-project/extension.swift"], force: true))
        #expect(mode.loadedResourcesContainer.render(width: 120) == after)
    }

    @Test func noticesRecolorAfterInvalidationAndKeepTheirContent() {
        defer { resetTerminalThemeState() }
        let mode = InteractiveMode(chatContainer: Container(), ui: ThemeRenderUI())
        mode.showStatus("saved status"); mode.showError("saved error"); mode.showWarning("saved warning")
        let before = mode.chatContainer.render(width: 100)
        initTheme("light"); mode.chatContainer.invalidate()
        let after = mode.chatContainer.render(width: 100)
        #expect(before != after)
        #expect(before.map(stripAnsi) == after.map(stripAnsi))
        #expect(after.joined().contains(theme.getFgAnsi(.error)))
    }
}

@MainActor
private final class ThemeRenderUI: RenderRequesting {
    func requestRender() {}
}

private func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

@MainActor
private func systemSettingsConfig() -> SettingsConfig {
    SettingsConfig(autoCompact: true, showImages: true, autoResizeImages: true, blockImages: false,
        enableSkillCommands: true, steeringMode: "one-at-a-time", followUpMode: "one-at-a-time", transport: .sse,
        thinkingLevel: .high, availableThinkingLevels: [.off, .high],
        availableThemes: ["dark", "light", "other", "system"], hideThinkingBlock: false,
        // Upstream v1.0.0: quietStartup now uses QuietStartup.
        showCacheMissNotices: true, collapseChangelog: false, quietStartup: .off, doubleEscapeAction: "tree",
        editorPaddingX: 0, autocompleteMaxVisible: 5, tuiMode: .regular, fullscreenScrollbar: .auto,
        mouseWheelStep: 1, mermaidEnabled: true, mermaidRenderWhileStreaming: true, latexEnabled: false, outputPad: 1)
}

@MainActor
private func systemSettingsCallbacks() -> SettingsCallbacks {
    SettingsCallbacks(onAutoCompactChange: { _ in }, onShowImagesChange: { _ in }, onAutoResizeImagesChange: { _ in },
        onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in }, onSteeringModeChange: { _ in },
        onFollowUpModeChange: { _ in }, onTransportChange: { _ in }, onThinkingLevelChange: { _ in },
        onThemeChange: { _ in }, onHideThinkingBlockChange: { _ in }, onShowCacheMissNoticesChange: { _ in },
        onCollapseChangelogChange: { _ in }, onQuietStartupChange: { _ in }, onDoubleEscapeActionChange: { _ in },
        onEditorPaddingXChange: { _ in }, onAutocompleteMaxVisibleChange: { _ in }, onTuiModeChange: { _ in },
        onFullscreenScrollbarChange: { _ in }, onMouseWheelStepChange: { _ in }, onMermaidEnabledChange: { _ in },
        onMermaidRenderWhileStreamingChange: { _ in }, onLatexEnabledChange: { _ in }, onOutputPadChange: { _ in }, onCancel: {})
}

private final class ThemeResourceLoader: ResourceLoader {
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) {
        (["zeta", "alpha"].map { name in
            Skill(name: name, description: name, filePath: "/tmp/theme-project/skills/\(name)/SKILL.md", baseDir: "/tmp/theme-project/skills/\(name)", source: "project")
        }, [])
    }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) {
        ([HookThemeInfo(name: "custom-theme", path: "/tmp/theme-project/custom-theme.json")],
         [ResourceDiagnostic(type: "warning", message: "theme conflict test")])
    }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}
