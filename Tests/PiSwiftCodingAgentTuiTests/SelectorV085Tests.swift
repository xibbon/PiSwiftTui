import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private typealias ThinkingLevel = PiSwiftAgent.ThinkingLevel

private func selectorModel(_ id: String, provider: String = "test", reasoning: Bool = true) -> Model {
    Model(id: id, name: id, api: .openAIResponses, provider: provider,
          baseUrl: "https://example.invalid", reasoning: reasoning, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128_000, maxTokens: 16_384)
}

@MainActor
private func selectorText(_ component: any Component, width: Int = 120) -> String {
    component.render(width: width).joined(separator: "\n")
        .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

private final class SelectorTerminal: Terminal {
    var columns = 120
    var rows = 40
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

@MainActor
private func selectorConfig() -> SettingsConfig {
    SettingsConfig(autoCompact: true, showImages: true, autoResizeImages: true, blockImages: false,
        enableSkillCommands: true, steeringMode: "one-at-a-time", followUpMode: "one-at-a-time", transport: .sse,
        thinkingLevel: .high, availableThinkingLevels: [.off, .minimal, .low, .medium, .high, .xhigh, .max],
        currentTheme: "dark", availableThemes: ["dark", "light", "other"], hideThinkingBlock: false,
        showCacheMissNotices: true, collapseChangelog: false, quietStartup: false, doubleEscapeAction: "tree",
        editorPaddingX: 0, autocompleteMaxVisible: 5, tuiMode: .regular, fullscreenScrollbar: .auto,
        mouseWheelStep: 1, mermaidEnabled: true, mermaidRenderWhileStreaming: true, latexEnabled: false, outputPad: 1)
}

@MainActor
private func selectorCallbacks() -> SettingsCallbacks {
    SettingsCallbacks(onAutoCompactChange: { _ in }, onShowImagesChange: { _ in }, onAutoResizeImagesChange: { _ in },
        onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in }, onSteeringModeChange: { _ in },
        onFollowUpModeChange: { _ in }, onTransportChange: { _ in }, onThinkingLevelChange: { _ in },
        onThemeChange: { _ in }, onHideThinkingBlockChange: { _ in }, onShowCacheMissNoticesChange: { _ in },
        onCollapseChangelogChange: { _ in }, onQuietStartupChange: { _ in }, onDoubleEscapeActionChange: { _ in },
        onEditorPaddingXChange: { _ in }, onAutocompleteMaxVisibleChange: { _ in }, onTuiModeChange: { _ in },
        onFullscreenScrollbarChange: { _ in }, onMouseWheelStepChange: { _ in }, onMermaidEnabledChange: { _ in },
        onMermaidRenderWhileStreamingChange: { _ in }, onLatexEnabledChange: { _ in }, onOutputPadChange: { _ in }, onCancel: {})
}

@MainActor
@Suite("v0.85 selectors", .serialized)
struct SelectorV085Tests {
    init() { setKeybindings(TUIKeybindingsManager()) }

    @Test func thinkingKeepsCurrentMarkerWhileBrowsing() {
        let selector = ThinkingSelectorComponent(currentLevel: .medium, availableLevels: [.medium, .high], onSelect: { _ in }, onCancel: {})
        #expect(selector.getSelectList().getSelectedItem()?.label == "✓ medium")
        #expect(selectorText(selector).contains("→ ✓ medium"))
        selector.handleInput("\u{001B}[B")
        #expect(selectorText(selector).contains("  ✓ medium"))
        #expect(selectorText(selector).contains("→   high"))
    }

    @Test func thinkingSeparatesSessionSelectionFromDefaultSelection() {
        var selected: [ThinkingLevel] = [], defaults: [ThinkingLevel] = []
        let selector = ThinkingSelectorComponent(currentLevel: .medium, availableLevels: [.medium, .high],
            onSelect: { selected.append($0) }, onCancel: {}, onSelectAsDefault: { defaults.append($0) }, defaultThinkingLevel: .high)
        selector.handleInput("\r")
        #expect(selected == [.medium]); #expect(defaults.isEmpty)
        selector.handleInput("\u{001B}[B"); selector.handleInput("\u{0013}")
        #expect(defaults == [.high]); #expect(selected == [.medium])
        #expect(selectorText(selector).contains("· default"))
    }

    @Test func thinkingFiltersDescriptionsAndForwardsFocus() {
        var selected: ThinkingLevel?
        let selector = ThinkingSelectorComponent(currentLevel: .off, availableLevels: [.off, .low, .high], onSelect: { selected = $0 }, onCancel: {})
        selector.focused = true
        #expect(selector.focused)
        for character in "Deep" { selector.handleInput(String(character)) }
        #expect(selector.getSelectList().getSelectedItem()?.value == "high")
        selector.handleInput("\r")
        #expect(selected == .high)
    }

    @Test func thinkingInputClickRetainsSelectorKeyboardFocus() {
        let selector = ThinkingSelectorComponent(currentLevel: .off, availableLevels: [.off, .high], onSelect: { _ in }, onCancel: {})
        let lines = selector.render(width: 120)
        let result = dispatchMouseEvent(selector, TuiMouseEvent(type: .press, button: .left, x: 2, y: 6,
            screenX: 2, screenY: 6, width: 120, height: lines.count))
        #expect(result?.focusTarget === selector)
    }

    @Test func thinkingNoMatchDoesNotSelectAndEscapeCancels() {
        var selected = false, cancelled = false
        let selector = ThinkingSelectorComponent(currentLevel: .off, availableLevels: [.off], onSelect: { _ in selected = true }, onCancel: { cancelled = true }, onSelectAsDefault: { _ in selected = true })
        selector.handleInput("zzzz"); selector.handleInput("\r"); selector.handleInput("\u{0013}")
        #expect(!selected)
        selector.handleInput("\u{001B}")
        #expect(cancelled)
    }

    private func modelSelector(models: [Model], current: Model?, defaultModel: ModelSelection? = nil,
                               onSelect: @escaping (Model) -> Void = { _ in }, onDefault: ((Model) -> Void)? = nil) -> ModelSelectorComponent {
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        return ModelSelectorComponent(tui: TUI(terminal: SelectorTerminal()), currentModel: current,
            defaultModel: defaultModel, modelRegistry: registry, scopedModels: models.map { ScopedModel(model: $0) },
            onSelect: onSelect, onCancel: {}, onSelectAsDefault: onDefault)
    }

    @Test func modelCurrentMarkerStaysWhileBrowsing() {
        let current = selectorModel("current"), browsed = selectorModel("browsed")
        let selector = modelSelector(models: [current, browsed], current: current)
        defer { selector.closeSelector() }
        #expect(selectorText(selector).contains("→ ✓ current [test]"))
        selector.handleInput("\u{001B}[B")
        #expect(selectorText(selector).contains("  ✓ current [test]"))
        #expect(selectorText(selector).contains("→   browsed [test]"))
    }

    @Test func modelDefaultPrefixSelectsConfiguredDefault() {
        let current = selectorModel("current"), model = selectorModel("other")
        var defaults: [String] = [], selected: [String] = []
        let selector = modelSelector(models: [current, model], current: current,
            defaultModel: ModelSelection(provider: "test", id: "other"), onSelect: { selected.append($0.id) }, onDefault: { defaults.append($0.id) })
        defer { selector.closeSelector() }
        for character in "def" { selector.handleInput(String(character)) }
        #expect(selectorText(selector).contains("→   other [test] · default"))
        selector.handleInput("\u{0013}")
        #expect(defaults == ["other"]); #expect(selected.isEmpty)
    }

    @Test func modelEnterUsesOnlySessionCallback() {
        let current = selectorModel("current")
        var selected = false, persisted = false
        let selector = modelSelector(models: [current], current: current, onSelect: { _ in selected = true }, onDefault: { _ in persisted = true })
        selector.handleInput("\r")
        #expect(selected); #expect(!persisted)
    }

    @Test func modelQueryResetsSelectionToFirstMatch() {
        let models = [selectorModel("alpha-1"), selectorModel("alpha-2"), selectorModel("alpha-3"), selectorModel("beta")]
        let selector = modelSelector(models: models, current: models[0])
        defer { selector.closeSelector() }
        selector.handleInput("\u{001B}[B"); selector.handleInput("\u{001B}[B")
        for character in "alpha" { selector.handleInput(String(character)) }
        #expect(selectorText(selector).contains("→ ✓ alpha-1 [test]"))
        #expect(!selectorText(selector).contains("beta [test]"))
    }

    @Test func modelScopePreservesOrderAndSelectsCurrent() throws {
        let models = [selectorModel("second"), selectorModel("current"), selectorModel("third")]
        let selector = modelSelector(models: models, current: models[1])
        defer { selector.closeSelector() }
        let rows = selectorText(selector).components(separatedBy: "\n").filter { $0.contains("[test]") }
        try #require(rows.count == 3)
        #expect(rows[0].contains("second [test]")); #expect(rows[1].contains("→ ✓ current [test]")); #expect(rows[2].contains("third [test]"))
    }

    @Test func modelAllScopeSortsCurrentThenDefaultThenProvider() async throws {
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        for (provider, id) in [("a-provider", "ordinary"), ("z-provider", "current"), ("y-provider", "default-model")] {
            registry.registerProvider(HookProviderConfig(provider: provider, api: .openAIResponses, baseUrl: "https://example.invalid", apiKey: "test-key", models: [HookProviderModel(id: id)]), sourceId: "selector-tests")
        }
        let current = try #require(registry.find("z-provider", "current"))
        let selector = ModelSelectorComponent(tui: TUI(terminal: SelectorTerminal()), currentModel: current,
            defaultModel: ModelSelection(provider: "y-provider", id: "default-model"), modelRegistry: registry,
            scopedModels: [], onSelect: { _ in }, onCancel: {})
        defer { selector.closeSelector() }
        for _ in 0..<200 {
            if selectorText(selector).contains("ordinary [a-provider]") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let rows = selectorText(selector).components(separatedBy: "\n").filter { $0.contains("-provider]") }
        try #require(rows.count == 3)
        #expect(rows[0].contains("current [z-provider]"))
        #expect(rows[1].contains("default-model [y-provider] · default"))
        #expect(rows[2].contains("ordinary [a-provider]"))
    }

    @Test func scopedReorderPublishesOrderedIds() {
        var changes: [[String]?] = []
        let selector = ScopedModelsSelectorComponent(config: ModelsConfig(allModels: [selectorModel("a"), selectorModel("b"), selectorModel("c")], enabledModelIds: ["test/a", "test/b", "test/c"], hasEnabledModelsFilter: true),
            callbacks: ModelsCallbacks(onChange: { changes.append($0) }, onPersist: { _ in }, onCancel: {}))
        selector.handleInput("\u{001B}[1;3B")
        #expect(changes == [["test/b", "test/a", "test/c"]])
    }

    @Test func scopedEnableAllAndToggleOnlySelectedModel() {
        let models = [selectorModel("a"), selectorModel("b"), selectorModel("c")]
        var changes: [[String]?] = []
        let selector = ScopedModelsSelectorComponent(config: ModelsConfig(allModels: models, enabledModelIds: ["test/a"], hasEnabledModelsFilter: true),
            callbacks: ModelsCallbacks(onChange: { changes.append($0) }, onPersist: { _ in }, onCancel: {}))
        selector.handleInput("\u{0001}")
        #expect(changes.count == 1 && changes[0] == nil)
        #expect(selectorText(selector).contains("✓ a [test]"))
        #expect(selectorText(selector).contains("✓ b [test]"))
        #expect(selectorText(selector).contains("✓ c [test]"))
        selector.handleInput("\r")
        #expect(changes.last! == ["test/b", "test/c"])
        #expect(!selectorText(selector).contains("✓ a [test]"))
        selector.handleInput("\u{001B}[B"); selector.handleInput("\u{001B}[B"); selector.handleInput("\r")
        #expect(changes.count == 3 && changes[2] == nil)
        #expect(selectorText(selector).contains("all enabled"))
    }

    @Test func scopedClearAllThenEnableOnlySelected() {
        var latest: [String]?
        let selector = ScopedModelsSelectorComponent(config: ModelsConfig(allModels: [selectorModel("a"), selectorModel("b")], enabledModelIds: [], hasEnabledModelsFilter: false),
            callbacks: ModelsCallbacks(onChange: { latest = $0 }, onPersist: { _ in }, onCancel: {}))
        selector.handleInput("\u{0018}"); #expect(latest == [])
        selector.handleInput("\r"); #expect(latest == ["test/a"])
    }

    @Test func scopedRefreshKeepsUnavailableEnabledModelsAndSelection() {
        let selector = ScopedModelsSelectorComponent(config: ModelsConfig(allModels: [selectorModel("a"), selectorModel("b")], enabledModelIds: ["test/a", "test/b"], hasEnabledModelsFilter: true),
            callbacks: ModelsCallbacks(onChange: { _ in }, onPersist: { _ in }, onCancel: {}))
        selector.handleInput("\u{001B}[B")
        selector.updateModels([selectorModel("a")])
        let output = selectorText(selector)
        #expect(output.contains("→   test/b [unavailable]"))
        #expect(output.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).contains("1 unavailable"))
        #expect(selector.render(width: 120).joined().contains("\u{001B}[9m"))
        selector.closeSelector()
        #expect(selector.refreshSignal.isCancelled)
    }

    @Test func scopedPersistRetainsAllEnabledSentinel() {
        var persisted: [[String]?] = []
        let selector = ScopedModelsSelectorComponent(config: ModelsConfig(allModels: [selectorModel("a")], enabledModelIds: [], hasEnabledModelsFilter: false),
            callbacks: ModelsCallbacks(onChange: { _ in }, onPersist: { persisted.append($0) }, onCancel: {}))
        selector.handleInput("\u{0013}")
        #expect(persisted.count == 1 && persisted[0] == nil)
    }

    @Test func settingsCyclesFullscreenValues() {
        var exits: [FullscreenExitOutput] = [], scrollbars: [FullscreenScrollbarMode] = [], copies: [Bool] = []
        var callbacks = selectorCallbacks()
        callbacks.onFullscreenExitOutputChange = { exits.append($0) }
        callbacks.onFullscreenScrollbarChange = { scrollbars.append($0) }
        callbacks.onFullscreenCopyOnSelectChange = { copies.append($0) }
        let list = SettingsSelectorComponent(config: selectorConfig(), callbacks: callbacks).getSettingsList()
        list.selectItem(id: "fullscreen-exit-output"); list.handleInput("\r"); list.handleInput("\r")
        list.selectItem(id: "fullscreen-scrollbar"); list.handleInput("\r"); list.handleInput("\r"); list.handleInput("\r")
        list.selectItem(id: "fullscreen-copy-on-select"); list.handleInput("\r"); list.handleInput("\r")
        #expect(exits == [.resumeHint, .transcript]); #expect(scrollbars == [.always, .hidden, .auto]); #expect(copies == [false, true])
    }

    @Test func settingsFixedThemeKeepsActiveMarker() {
        let list = SettingsSelectorComponent(config: selectorConfig(), callbacks: selectorCallbacks()).getSettingsList()
        list.selectItem(id: "theme"); list.handleInput("\r")
        #expect(selectorText(list).contains("    Automatic"))
        #expect(selectorText(list).contains("→ ✓ dark"))
        list.handleInput("\u{001B}[B")
        #expect(selectorText(list).contains("  ✓ dark")); #expect(selectorText(list).contains("→   light"))
    }

    @Test func settingsAutomaticThemeKeepsActiveMarker() {
        var config = selectorConfig(); config.currentTheme = "light/dark"
        let list = SettingsSelectorComponent(config: config, callbacks: selectorCallbacks()).getSettingsList()
        list.selectItem(id: "theme"); list.handleInput("\r"); list.handleInput("\r")
        #expect(selectorText(list).contains("→ ✓ light"))
        list.handleInput("\u{001B}[B")
        #expect(selectorText(list).contains("  ✓ light")); #expect(selectorText(list).contains("→   other"))
    }

    @Test func settingsPerModelOverrideMarkerLoopAndClear() {
        var config = selectorConfig()
        config.availableDefaultModels = [selectorModel("thinking")]
        config.modelThinkingLevels = ["test/thinking": .medium]
        var callbacks = selectorCallbacks()
        var changed: ThinkingLevel?, removed = false
        callbacks.onModelThinkingLevelChange = { provider, id, level in
            #expect(provider == "test" && id == "thinking"); changed = level
        }
        callbacks.onModelThinkingLevelRemove = { provider, id in #expect(provider == "test" && id == "thinking"); removed = true }
        let list = SettingsSelectorComponent(config: config, callbacks: callbacks).getSettingsList()
        list.selectItem(id: "model-thinking"); list.handleInput("\r"); list.handleInput("\r")
        #expect(selectorText(list).contains("→ ✓ medium"))
        list.handleInput("\u{001B}[B")
        #expect(selectorText(list).contains("  ✓ medium")); #expect(selectorText(list).contains("→   high"))
        list.handleInput("\r")
        #expect(changed == .high); #expect(selectorText(list).contains("Select a model to configure"))
        list.handleInput("\r")
        // Navigate to the clear row using the list's wrap-around rule.
        for _ in 0..<10 {
            if selectorText(list).contains("→   (clear override)") { break }
            list.handleInput("\u{001B}[B")
        }
        #expect(selectorText(list).contains("Revert to global default (high)"))
        list.handleInput("\r"); #expect(removed)
        list.handleInput("\u{001B}")
        #expect(selectorText(list).contains("none"))
    }

    @Test func settingsNoModelsShowsPlaceholder() {
        let list = SettingsSelectorComponent(config: selectorConfig(), callbacks: selectorCallbacks()).getSettingsList()
        list.selectItem(id: "model-thinking"); list.handleInput("\r")
        #expect(selectorText(list).contains("No models available"))
    }

    @Test func searchableSubmenuFiltersDescriptionAndSelects() {
        var selected = ""
        let menu = SelectSubmenu(title: "Pick", description: "", options: [SelectItem(value: "a", label: "A", description: "first"), SelectItem(value: "b", label: "B", description: "second")], currentValue: "a", onSelect: { selected = $0 }, onCancel: {}, searchable: true)
        for character in "second" { menu.handleInput(String(character)) }
        menu.handleInput("\r")
        #expect(selected == "b")
        #expect(selectorText(menu).contains("Type to filter · Enter to select · Esc to go back"))
    }

    @Test func steppedSubmenuBackAndLoopKeepContext() {
        var completed: [[String: String]] = [], cancelled = false
        let menu = SteppedSubmenu(steps: [
            SteppedSubmenuStep(key: "first", title: { _ in "First" }, description: { _ in "Choose" }, options: { _ in [SelectItem(value: "a", label: "A")] }),
            SteppedSubmenuStep(key: "second", title: { _ in "Second" }, description: { _ in "Choose" }, options: { context in [SelectItem(value: context["first"]! + "b", label: "B")] })
        ], onComplete: { completed.append($0) }, onCancel: { cancelled = true }, loop: true)
        menu.handleInput("\r"); #expect(selectorText(menu).contains("Step 2/2"))
        menu.handleInput("\u{001B}"); #expect(selectorText(menu).contains("Step 1/2")); #expect(!cancelled)
        menu.handleInput("\r"); menu.handleInput("\r")
        #expect(completed == [["first": "a", "second": "ab"]]); #expect(selectorText(menu).contains("Step 1/2"))
        menu.handleInput("\u{001B}"); #expect(cancelled)
    }

    @Test func trustSavedMarkerStaysWhileBrowsing() {
        let options = [ProjectTrustOption(label: "Trust", trusted: true, updates: [], savedPath: "/test"), ProjectTrustOption(label: "Do not trust", trusted: false, updates: [], savedPath: "/test")]
        let selector = ProjectTrustSelectorComponent(cwd: "/test", options: options, onSelect: { _ in }, onCancel: {}, savedDecision: ProjectTrustUpdate(path: "/test", decision: true))
        #expect(selectorText(selector).contains("→ ✓ Trust"))
        selector.handleInput("\u{001B}[B")
        #expect(selectorText(selector).contains("  ✓ Trust")); #expect(selectorText(selector).contains("→   Do not trust"))
    }
}
